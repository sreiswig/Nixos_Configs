#!/usr/bin/env bash
# Ethernet / WiFi / Tailscale self-heal check.
#
# One implementation, two hosts:
# - Spark (Ubuntu): installed to /usr/local/sbin/network-self-heal-check
# - AIServer (NixOS): modules/services/network-self-heal.nix inlines this file
#   and exports the services.my-network-self-heal settings first.
#
# Healthy: Tailscale is online. A failed ICMP probe (WAN 1.1.1.1 or the LAN
# gateway) is only a warning in that case, so a reachable box is not rebooted.
# Hard outage: Tailscale is offline (after `tailscale up`). Link loss restarts
# NetworkManager and, if it is actually enabled or active, systemd-networkd,
# then tailscaled. Nine failures at a 2 minute cadence is about 16 minutes;
# then a cooldown-gated reboot. NeedsLogin does not reboot.
#
# No SSIDs, PSKs, or Tailscale auth keys. NET_SYSFS is /sys/class/net
# (overridden only by scripts/spark/test-network-self-heal.sh).

set -euo pipefail

STATE_DIR="${STATE_DIR:-/var/lib/network-self-heal}"
PING_TARGET="${PING_TARGET:-1.1.1.1}"
PING_MODE="${PING_MODE:-hard}"
REQUIRE_TS="${REQUIRE_TS:-1}"
WIFI_IFACE="${WIFI_IFACE:-}"
DISABLE_PS="${DISABLE_PS:-1}"
ESCALATE_REBOOT="${ESCALATE_REBOOT:-1}"
TH_NET="${TH_NET:-2}"
TH_TS="${TH_TS:-4}"
TH_REBOOT="${TH_REBOOT:-9}"
COOLDOWN_SEC="${COOLDOWN_SEC:-3600}"
LAN_GATEWAY="${LAN_GATEWAY:-}"
NET_SYSFS="${NET_SYSFS:-/sys/class/net}"

mkdir -p "$STATE_DIR"

FAILURES_FILE="$STATE_DIR/failures"
LAST_REBOOT_FILE="$STATE_DIR/last_reboot"
LINK_FILE="$STATE_DIR/link_down"

restarted_net=0
restarted_ts=0

log() {
  echo "network-self-heal: $*"
}

read_failures() {
  local n=""
  if [[ -f "$FAILURES_FILE" ]]; then
    n="$(tr -cd '0-9' < "$FAILURES_FILE" || true)"
  fi
  if [[ -z "$n" ]]; then
    printf '%s\n' 0
  else
    printf '%s\n' "$n"
  fi
}

write_failures() {
  printf '%s\n' "$1" > "$FAILURES_FILE"
}

note_watchdog() {
  if [[ -c /dev/watchdog || -c /dev/watchdog0 ]]; then
    return 0
  fi
  if [[ -f "$STATE_DIR/watchdog_absent" ]]; then
    return 0
  fi
  log "no /dev/watchdog; RuntimeWatchdogSec has no effect until a hardware watchdog device exists"
  : > "$STATE_DIR/watchdog_absent"
}

in_cgnat() {
  local ip="$1" o1 o2 rest
  IFS=. read -r o1 o2 _ <<< "$ip"
  [[ "$o1" == "100" ]] || return 1
  [[ "$o2" =~ ^[0-9]+$ ]] || return 1
  o2=$((10#$o2))
  (( o2 >= 64 && o2 <= 127 ))
}

default_route_fields() {
  ip -4 route show default 2>/dev/null | awk '
    BEGIN { found = 0; bestm = 0 }
    {
      via = ""
      dev = ""
      metric = ""
      for (i = 1; i <= NF; i++) {
        if ($i == "via") via = $(i + 1)
        else if ($i == "dev") dev = $(i + 1)
        else if ($i == "metric") metric = $(i + 1)
      }
      if (via == "") next
      m = (metric == "" ? 0 : metric + 0)
      if (!found || m < bestm) {
        found = 1
        bestm = m
        best = via
        bestdev = dev
      }
    }
    END { if (found) print best, bestdev }
  ' || true
}

default_route_dev() {
  local line gw dev
  line="$(default_route_fields)"
  [[ -n "$line" ]] || return 1
  read -r gw dev <<< "$line"
  [[ -n "$dev" ]] || return 1
  printf '%s\n' "$dev"
}

detected_gateway() {
  local line gw dev
  if [[ -n "$LAN_GATEWAY" ]]; then
    printf '%s\n' "$LAN_GATEWAY"
    return 0
  fi
  line="$(default_route_fields)"
  [[ -n "$line" ]] || return 1
  read -r gw dev <<< "$line"
  [[ -n "$gw" ]] || return 1
  if in_cgnat "$gw"; then
    return 1
  fi
  printf '%s\n' "$gw"
}

iface_exists() {
  local iface="$1"
  [[ -n "$iface" ]] && ip link show "$iface" >/dev/null 2>&1
}

iface_has_carrier() {
  local iface="$1" oper carrier
  [[ -e "$NET_SYSFS/$iface" ]] || return 1
  oper="$(cat "$NET_SYSFS/$iface/operstate" 2>/dev/null || true)"
  case "$oper" in
    up|unknown) return 0 ;;
  esac
  if [[ -r "$NET_SYSFS/$iface/carrier" ]]; then
    carrier="$(cat "$NET_SYSFS/$iface/carrier" 2>/dev/null || true)"
    [[ "$carrier" == "1" ]]
    return
  fi
  return 1
}

physical_ifaces() {
  local path name
  for path in "$NET_SYSFS"/*; do
    [[ -d "$path" ]] || continue
    [[ -e "$path/device" ]] || continue
    name="${path##*/}"
    case "$name" in
      lo|tailscale*|docker*|veth*|br-*|virbr*|zt*|wg*) continue ;;
    esac
    printf '%s\n' "$name"
  done
}

all_physical_down() {
  local dev any=0
  while IFS= read -r dev; do
    [[ -z "$dev" ]] && continue
    any=1
    if iface_has_carrier "$dev"; then
      return 1
    fi
  done < <(physical_ifaces)
  [[ "$any" == "1" ]]
}

default_dev_no_carrier() {
  local dev
  dev="$(default_route_dev || true)"
  [[ -n "$dev" ]] || return 1
  [[ -e "$NET_SYSFS/$dev" ]] || return 1
  if iface_has_carrier "$dev"; then
    return 1
  fi
  return 0
}

detect_wifi_iface() {
  local dev typ a b
  if command -v nmcli >/dev/null 2>&1; then
    while IFS=: read -r dev typ _; do
      if [[ "$typ" == "wifi" && -n "$dev" ]]; then
        printf '%s\n' "$dev"
        return 0
      fi
    done < <(nmcli -t -f DEVICE,TYPE device status 2>/dev/null || true)
  fi
  while read -r a b; do
    if [[ "$a" == "Interface" && -n "$b" ]]; then
      printf '%s\n' "$b"
      return 0
    fi
  done < <(iw dev 2>/dev/null || true)
  return 1
}

resolve_wifi_iface() {
  local detected=""
  if [[ -n "$WIFI_IFACE" ]]; then
    if iface_exists "$WIFI_IFACE"; then
      return 0
    fi
    log "configured wifiInterface=$WIFI_IFACE not present; auto-detecting"
    WIFI_IFACE=""
  fi
  detected="$(detect_wifi_iface || true)"
  if [[ -n "$detected" ]]; then
    WIFI_IFACE="$detected"
    log "auto-detected wifi iface $WIFI_IFACE"
  fi
}

wifi_associated() {
  local iface="$1" st
  [[ -z "$iface" ]] && return 1
  if command -v nmcli >/dev/null 2>&1; then
    st="$(nmcli -t -f GENERAL.STATE device show "$iface" 2>/dev/null | head -n1 || true)"
    if [[ "$st" == *":100 (connected)"* ]]; then
      return 0
    fi
  fi
  if command -v iw >/dev/null 2>&1 \
    && iw dev "$iface" link 2>/dev/null | grep -q "Connected to"; then
    return 0
  fi
  return 1
}

reconnect_wifi() {
  local iface="$1" name typ
  log "attempt: WiFi reconnect ($iface)"

  if command -v nmcli >/dev/null 2>&1; then
    nmcli radio wifi on >/dev/null 2>&1 || true
    nmcli networking on >/dev/null 2>&1 || true

    if [[ -n "$iface" ]]; then
      if timeout 20 nmcli device connect "$iface" >/dev/null 2>&1; then
        log "nmcli device connect $iface succeeded"
        return 0
      fi
      log "nmcli device connect $iface failed; trying saved WiFi connections"
    fi

    while IFS=: read -r name typ; do
      [[ -z "$name" ]] && continue
      if [[ "$typ" != "802-11-wireless" ]]; then
        continue
      fi
      log "attempt: nmcli connection up $name"
      if timeout 20 nmcli connection up "$name" >/dev/null 2>&1; then
        log "nmcli connection up $name succeeded"
        return 0
      fi
    done < <(nmcli -t -f NAME,TYPE connection show 2>/dev/null || true)

    log "WiFi reconnect via NetworkManager failed"
    return 1
  fi

  if [[ -n "$iface" ]]; then
    log "attempt: bounce iface $iface (no nmcli)"
    ip link set "$iface" down || true
    sleep 2
    ip link set "$iface" up || true
    return 0
  fi

  log "no NetworkManager and no wifi iface; cannot reconnect WiFi"
  return 1
}

connect_disconnected_ethernet() {
  local dev typ state
  command -v nmcli >/dev/null 2>&1 || return 0
  while IFS=: read -r dev typ state; do
    [[ "$typ" == "ethernet" && -n "$dev" ]] || continue
    [[ "$state" == "connected" ]] && continue
    log "attempt: nmcli device connect $dev (prefer wired)"
    timeout 10 nmcli device connect "$dev" >/dev/null 2>&1 || true
  done < <(nmcli -t -f DEVICE,TYPE,STATE device status 2>/dev/null || true)
}

disable_wifi_powersave() {
  if [[ -n "$WIFI_IFACE" && "$DISABLE_PS" == "1" ]]; then
    if iw dev "$WIFI_IFACE" info >/dev/null 2>&1; then
      iw dev "$WIFI_IFACE" set power_save off 2>/dev/null || true
    fi
  fi
}

bring_up_tailscale() {
  log "attempt: tailscale up"
  if command -v timeout >/dev/null 2>&1; then
    if timeout 25 tailscale up; then
      log "tailscale up succeeded"
      return 0
    fi
  elif tailscale up; then
    log "tailscale up succeeded"
    return 0
  fi
  log "tailscale up failed (not logged in, or daemon not ready)"
  return 1
}

tailscale_backend() {
  local raw
  command -v tailscale >/dev/null 2>&1 || return 1
  raw="$(tailscale status --json 2>/dev/null || true)"
  [[ -n "$raw" ]] || return 1
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$raw" | jq -r '.BackendState // empty' 2>/dev/null || true
    return 0
  fi
  return 1
}

tailscale_online() {
  command -v tailscale >/dev/null 2>&1 || return 1
  if command -v jq >/dev/null 2>&1; then
    if tailscale status --json 2>/dev/null | jq -e '.Self.Online == true' >/dev/null 2>&1; then
      return 0
    fi
  fi
  [[ -n "$(tailscale ip -4 2>/dev/null || true)" ]]
}

check_default_route() {
  ip -4 route show default 2>/dev/null | grep -q .
}

check_ping() {
  ping -c 1 -W 3 "$PING_TARGET" >/dev/null 2>&1
}

manager_in_use() {
  local unit="$1"
  if systemctl is-active "$unit" >/dev/null 2>&1; then
    return 0
  fi
  if systemctl is-enabled "$unit" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

restart_network_managers() {
  local bounced=0
  if manager_in_use NetworkManager.service; then
    log "escalation: restarting NetworkManager"
    systemctl restart NetworkManager.service || true
    sleep 3
    connect_disconnected_ethernet
    bounced=1
  fi
  if manager_in_use systemd-networkd.service; then
    log "escalation: restarting systemd-networkd"
    systemctl restart systemd-networkd.service || true
    sleep 2
    bounced=1
  fi
  if [[ "$bounced" == "0" && -n "$WIFI_IFACE" ]]; then
    log "escalation: bouncing iface $WIFI_IFACE"
    ip link set "$WIFI_IFACE" down || true
    sleep 2
    ip link set "$WIFI_IFACE" up || true
  elif [[ "$bounced" == "0" ]]; then
    log "escalation: neither NetworkManager nor systemd-networkd is in use; skipping manager restart"
  fi
  if [[ -n "$WIFI_IFACE" ]]; then
    reconnect_wifi "$WIFI_IFACE" || true
  fi
  restarted_net=1
}

restart_tailscale() {
  log "escalation: restarting tailscaled"
  systemctl restart tailscaled.service || true
  sleep 2
  bring_up_tailscale || true
  restarted_ts=1
}

should_restart_for_link() {
  if all_physical_down; then
    log "link loss: no physical NIC has carrier"
    return 0
  fi
  if default_dev_no_carrier && ! tailscale_online; then
    log "link loss: default-route NIC has no carrier and Tailscale is offline"
    return 0
  fi
  return 1
}

maybe_reboot() {
  local now last elapsed
  if [[ "$ESCALATE_REBOOT" != "1" ]]; then
    log "escalation: reboot disabled (escalateToReboot=false)"
    return 0
  fi
  now="$(date +%s)"
  last=0
  if [[ -f "$LAST_REBOOT_FILE" ]]; then
    last="$(tr -cd '0-9' < "$LAST_REBOOT_FILE" || true)"
    [[ -n "$last" ]] || last=0
  fi
  elapsed=$(( now - last ))
  if [[ "$last" != "0" && "$elapsed" -lt "$COOLDOWN_SEC" ]]; then
    log "escalation: reboot suppressed (cooldown ${COOLDOWN_SEC}s, elapsed ${elapsed}s)"
    return 0
  fi
  log "escalation: controlled reboot after sustained Tailscale outage; OOB KVM still recommended"
  printf '%s\n' "$now" > "$LAST_REBOOT_FILE"
  sync || true
  systemctl reboot || reboot || true
  exit 0
}

note_watchdog
resolve_wifi_iface
disable_wifi_powersave

if should_restart_for_link; then
  if [[ ! -f "$LINK_FILE" ]]; then
    log "link loss: restarting network manager(s) and tailscaled"
    restart_network_managers
    restart_tailscale
    : > "$LINK_FILE"
  else
    log "link loss: stack already restarted for this outage"
  fi
else
  rm -f "$LINK_FILE"
fi

if [[ -n "$WIFI_IFACE" ]] && ! wifi_associated "$WIFI_IFACE"; then
  log "WiFi not associated on $WIFI_IFACE"
  reconnect_wifi "$WIFI_IFACE" || true
  sleep 3
  disable_wifi_powersave
fi

if [[ "$REQUIRE_TS" == "1" ]] && ! command -v tailscale >/dev/null 2>&1; then
  log "tailscale binary missing; not escalating to reboot"
  exit 0
fi

if [[ "$REQUIRE_TS" == "1" ]] && ! tailscale_online; then
  bring_up_tailscale || true
  sleep 2
fi

if [[ "$REQUIRE_TS" == "1" ]]; then
  backend="$(tailscale_backend || true)"
  case "$backend" in
    NeedsLogin|NeedsMachineAuth)
      log "Tailscale ${backend}; skipping failure ladder (one-time tailscale up / admin approval required)"
      write_failures 0
      exit 0
      ;;
  esac
fi

ts_online=0
if tailscale_online; then
  ts_online=1
fi

hard=0
route_ok=0
gw_ok=0
GW="$(detected_gateway || true)"

if check_default_route; then
  route_ok=1
fi

if [[ -n "$GW" ]] && ping -c 1 -W 3 "$GW" >/dev/null 2>&1; then
  gw_ok=1
fi

if [[ "$route_ok" == "0" || "$gw_ok" == "0" ]]; then
  if [[ "$ts_online" == "1" ]]; then
    log "WARN: LAN uplink not usable (route_ok=$route_ok gateway=${GW:-none}) but Tailscale is online; not escalating"
  else
    log "FAIL: no usable LAN gateway (route_ok=$route_ok gateway=${GW:-none}) and Tailscale is offline"
    hard=1
  fi
fi

if [[ "$REQUIRE_TS" == "1" && "$ts_online" == "0" ]]; then
  log "FAIL: Tailscale not online / no IPv4"
  hard=1
fi

if [[ "$PING_MODE" == "off" ]]; then
  :
elif ! check_ping; then
  if [[ "$PING_MODE" == "soft" && "$ts_online" == "1" ]]; then
    log "WARN: soft ping fail to $PING_TARGET (Tailscale online; not escalating)"
  else
    log "FAIL: ping $PING_TARGET"
    hard=1
  fi
fi

if [[ "$hard" == "0" ]]; then
  prev="$(read_failures)"
  if [[ "$prev" != "0" ]]; then
    log "OK: uplink+tailscale healthy; resetting failure counter (was $prev; gateway=${GW:-none})"
  else
    log "OK: uplink+tailscale healthy (gateway=${GW:-none})"
  fi
  write_failures 0
  exit 0
fi

failures=$(( $(read_failures) + 1 ))
write_failures "$failures"
log "consecutive failures=$failures (net@$TH_NET ts@$TH_TS reboot@$TH_REBOOT)"

if [[ "$failures" -eq "$TH_NET" && "$restarted_net" == "0" ]]; then
  restart_network_managers
elif [[ "$failures" -eq "$TH_TS" && "$restarted_ts" == "0" ]]; then
  restart_tailscale
elif [[ "$failures" -ge "$TH_REBOOT" ]]; then
  maybe_reboot
else
  log "no escalation action at this failure count"
fi

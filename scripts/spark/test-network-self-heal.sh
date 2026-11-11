#!/usr/bin/env bash
# Stubbed checks for scripts/spark/network-self-heal.sh. No root, no network.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$ROOT/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

STUB_DIR="$TMP/stub-data"
BIN="$TMP/bin"
NET_SYSFS="$TMP/sys"
STATE_DIR="$TMP/state"
mkdir -p "$STUB_DIR" "$BIN" "$STATE_DIR"

export STUB_DIR NET_SYSFS STATE_DIR
export PATH="$BIN:$PATH"

fail() {
  echo "FAIL: $*" >&2
  echo "--- output ---" >&2
  printf '%s\n' "${out:-}" >&2
  echo "--- actions ---" >&2
  cat "$STUB_DIR/actions" >&2 || true
  exit 1
}

assert() {
  local msg="$1"
  shift
  if ! "$@"; then
    fail "$msg"
  fi
}

cat > "$BIN/ip" <<'EOF'
#!/bin/bash
set -euo pipefail
if [[ "${1:-}" == "-4" && "${2:-}" == "route" ]]; then
  cat "$STUB_DIR/route"
  exit 0
fi
if [[ "${1:-}" == "link" && "${2:-}" == "show" ]]; then
  if [[ -e "$NET_SYSFS/${3:-}" ]]; then
    exit 0
  fi
  exit 1
fi
if [[ "${1:-}" == "link" && "${2:-}" == "set" ]]; then
  exit 0
fi
echo "unexpected ip: $*" >&2
exit 1
EOF

cat > "$BIN/ping" <<'EOF'
#!/bin/bash
set -euo pipefail
target="${!#}"
if [[ -f "$STUB_DIR/ping_fail" ]] && grep -qx "$target" "$STUB_DIR/ping_fail"; then
  exit 1
fi
exit 0
EOF

cat > "$BIN/tailscale" <<'EOF'
#!/bin/bash
set -euo pipefail
if [[ "${1:-}" == "status" && "${2:-}" == "--json" ]]; then
  cat "$STUB_DIR/status.json"
  exit 0
fi
if [[ "${1:-}" == "ip" ]]; then
  if [[ -s "$STUB_DIR/ts_ip" ]]; then
    cat "$STUB_DIR/ts_ip"
  fi
  exit 0
fi
if [[ "${1:-}" == "up" ]]; then
  exit 0
fi
echo "unexpected tailscale: $*" >&2
exit 1
EOF

cat > "$BIN/systemctl" <<'EOF'
#!/bin/bash
set -euo pipefail
cmd="${1:-}"
unit="${2:-}"
case "$cmd" in
  is-active|is-enabled|cat)
    if grep -qx "$unit" "$STUB_DIR/units"; then
      exit 0
    fi
    exit 1
    ;;
  restart)
    printf '%s\n' "systemctl $*" >> "$STUB_DIR/actions"
    exit 0
    ;;
  reboot)
    printf '%s\n' reboot >> "$STUB_DIR/reboots"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF

cat > "$BIN/nmcli" <<'EOF'
#!/bin/bash
exit 0
EOF

cat > "$BIN/iw" <<'EOF'
#!/bin/bash
exit 0
EOF

cat > "$BIN/timeout" <<'EOF'
#!/bin/bash
shift
if [[ "$#" -eq 0 ]]; then
  exit 0
fi
exec "$@"
EOF

cat > "$BIN/sleep" <<'EOF'
#!/bin/bash
exit 0
EOF

chmod +x "$BIN"/*

printf '%s\n' NetworkManager.service tailscaled.service > "$STUB_DIR/units"
: > "$STUB_DIR/actions"
: > "$STUB_DIR/reboots"
: > "$STUB_DIR/ping_fail"
printf '%s\n' 'default via 192.168.8.1 dev enp1 metric 100' > "$STUB_DIR/route"

setup_link() {
  local oper="$1" carrier="$2"
  rm -rf "$NET_SYSFS"
  mkdir -p "$NET_SYSFS/enp1/device"
  printf '%s\n' "$oper" > "$NET_SYSFS/enp1/operstate"
  printf '%s\n' "$carrier" > "$NET_SYSFS/enp1/carrier"
}

add_iface() {
  local name="$1" oper="$2" carrier="$3"
  mkdir -p "$NET_SYSFS/$name/device"
  printf '%s\n' "$oper" > "$NET_SYSFS/$name/operstate"
  printf '%s\n' "$carrier" > "$NET_SYSFS/$name/carrier"
}

set_ts() {
  local backend="$1" online="$2" ip="$3"
  printf '{"BackendState":"%s","Self":{"Online":%s}}\n' "$backend" "$online" > "$STUB_DIR/status.json"
  printf '%s' "$ip" > "$STUB_DIR/ts_ip"
}

set_ping_fail() {
  : > "$STUB_DIR/ping_fail"
  local t
  for t in "$@"; do
    printf '%s\n' "$t" >> "$STUB_DIR/ping_fail"
  done
}

fresh_state() {
  rm -rf "$STATE_DIR"
  mkdir -p "$STATE_DIR"
  : > "$STUB_DIR/actions"
  : > "$STUB_DIR/reboots"
}

run_check() {
  set +e
  out="$("$ROOT/network-self-heal.sh" 2>&1)"
  rc=$?
  set -e
}

out=""
rc=0
checks=0

begin_check() {
  checks=$((checks + 1))
  echo "$1"
}

begin_check "static: defaults encode a ~16 minute reboot window"
assert "TH_REBOOT default is 9" grep -q 'TH_REBOOT:-9' "$ROOT/network-self-heal.sh"
assert "PING_MODE default is soft" grep -q 'PING_MODE:-soft' "$ROOT/network-self-heal.sh"
assert "COOLDOWN_SEC default is 3600" grep -q 'COOLDOWN_SEC:-3600' "$ROOT/network-self-heal.sh"
assert "timer interval is 2min" grep -q 'OnUnitActiveSec=2min' "$ROOT/network-self-heal.timer"
assert "nix module inlines the spark script" grep -q 'scripts/spark/network-self-heal.sh' "$REPO/modules/services/network-self-heal.nix"
assert "nix module sets RuntimeWatchdogSec" grep -q 'RuntimeWatchdogSec' "$REPO/modules/services/network-self-heal.nix"
assert "nix checkInterval default is 2min" grep -q 'default = "2min"' "$REPO/modules/services/network-self-heal.nix"
assert "nix pingMode default is soft" grep -q 'default = "soft"' "$REPO/modules/services/network-self-heal.nix"
assert "nix reboot threshold default is 9" grep -q 'default = 9' "$REPO/modules/services/network-self-heal.nix"
assert "nix reboot cooldown default is 1h" grep -q 'default = "1h"' "$REPO/modules/services/network-self-heal.nix"
assert "check script gates the watchdog on the device node" grep -F -q '[[ -c /dev/watchdog || -c /dev/watchdog0 ]]' "$ROOT/network-self-heal.sh"
assert "installer arms the watchdog only when the device exists" grep -F -q '[[ -c /dev/watchdog || -c /dev/watchdog0 ]]' "$ROOT/install-remote-access.sh"

begin_check "test: Tailscale online ignores WAN ICMP failure"
fresh_state
setup_link up 1
set_ts Running true "100.75.1.1"
set_ping_fail "1.1.1.1"
unset TH_NET TH_TS TH_REBOOT || true
run_check
assert "rc 0 (soft wan)" test "$rc" -eq 0
assert "soft ping warned" grep -q 'soft ping fail' <<< "$out"
assert "healthy" grep -q 'OK: uplink+tailscale healthy' <<< "$out"
assert "counter cleared" grep -qx '0' "$STATE_DIR/failures"
assert "no manager restart" test ! -s "$STUB_DIR/actions"

begin_check "test: Tailscale online ignores a dead LAN gateway"
fresh_state
setup_link up 1
set_ts Running true "100.75.1.1"
set_ping_fail "192.168.8.1"
run_check
assert "rc 0 (gateway warn)" test "$rc" -eq 0
assert "gateway warn" grep -q 'not escalating' <<< "$out"
assert "counter cleared" grep -qx '0' "$STATE_DIR/failures"
assert "no manager restart while reachable" test ! -s "$STUB_DIR/actions"

begin_check "test: NeedsLogin does not arm the reboot ladder"
fresh_state
setup_link up 1
set_ts NeedsLogin false ""
set_ping_fail
run_check
assert "rc 0 (needs login)" test "$rc" -eq 0
assert "login message" grep -q 'NeedsLogin' <<< "$out"
assert "counter cleared" grep -qx '0' "$STATE_DIR/failures"
assert "no reboot" test ! -s "$STUB_DIR/reboots"

begin_check "test: Tailscale offline reboots on the 9th check and then honors cooldown"
fresh_state
setup_link up 1
set_ts Running false ""
set_ping_fail
i=0
ninth=""
while [[ "$i" -lt 9 ]]; do
  i=$((i + 1))
  run_check
  assert "check $i rc 0" test "$rc" -eq 0
  if [[ "$i" == "9" ]]; then
    ninth="$out"
  fi
done
assert "ninth check reboots" grep -q 'controlled reboot' <<< "$ninth"
assert "one reboot" test "$(wc -l < "$STUB_DIR/reboots" | tr -d ' ')" -eq 1
assert "restarted NetworkManager once" test "$(grep -c 'restart NetworkManager' "$STUB_DIR/actions")" -eq 1
assert "restarted tailscaled once" test "$(grep -c 'restart tailscaled' "$STUB_DIR/actions")" -eq 1
assert "did not restart networkd when it is not in use" test "$(grep -c 'restart systemd-networkd' "$STUB_DIR/actions" || true)" -eq 0
run_check
assert "cooldown suppress" grep -q 'reboot suppressed' <<< "$out"
assert "cooldown is 3600s" grep -q 'cooldown 3600s' <<< "$out"
assert "still one reboot" test "$(wc -l < "$STUB_DIR/reboots" | tr -d ' ')" -eq 1

begin_check "test: recovery clears the failure counter"
fresh_state
setup_link up 1
set_ts Running false ""
set_ping_fail
run_check
run_check
set_ts Running true "100.75.1.1"
run_check
assert "reset log" grep -q 'resetting failure counter' <<< "$out"
assert "counter cleared" grep -qx '0' "$STATE_DIR/failures"

begin_check "test: link loss restarts NM, networkd, and tailscaled once per outage"
fresh_state
printf '%s\n' NetworkManager.service systemd-networkd.service tailscaled.service > "$STUB_DIR/units"
setup_link down 0
set_ts Running false ""
set_ping_fail "192.168.8.1"
export TH_NET=8 TH_TS=8 TH_REBOOT=9
run_check
assert "link loss logged" grep -q 'link loss' <<< "$out"
assert "restarted NetworkManager" grep -q 'restart NetworkManager' "$STUB_DIR/actions"
assert "restarted systemd-networkd" grep -q 'restart systemd-networkd' "$STUB_DIR/actions"
assert "restarted tailscaled" grep -q 'restart tailscaled' "$STUB_DIR/actions"
: > "$STUB_DIR/actions"
run_check
assert "no second restart while the outage continues" test ! -s "$STUB_DIR/actions"
unset TH_NET TH_TS TH_REBOOT

begin_check "test: Tailscale online does not restart when another NIC still has carrier"
fresh_state
setup_link down 0
add_iface wlp1 up 1
set_ts Running true "100.75.1.1"
set_ping_fail
run_check
assert "no restart with a live tailnet and a live NIC" test ! -s "$STUB_DIR/actions"

begin_check "test: a Tailscale CGNAT next hop is not treated as the LAN gateway"
fresh_state
setup_link up 1
set_ts Running false ""
printf '%s\n' 'default via 100.64.0.1 dev tailscale0 metric 0' > "$STUB_DIR/route"
set_ping_fail
run_check
assert "cgnat via is not a lan gateway" grep -q 'gateway=none' <<< "$out"
assert "offline tailscale still counts" grep -qx '1' "$STATE_DIR/failures"

begin_check "test: all-down carrier restarts even if Tailscale still reports online"
fresh_state
setup_link down 0
set_ts Running true "100.75.1.1"
set_ping_fail
run_check
assert "stale online still restarts on total link loss" grep -q 'restart NetworkManager' "$STUB_DIR/actions"

begin_check "test: NeedsMachineAuth does not reboot"
fresh_state
setup_link up 1
set_ts NeedsMachineAuth false ""
set_ping_fail
run_check
assert "rc 0 (needs machine auth)" test "$rc" -eq 0
assert "machine auth message" grep -q 'NeedsMachineAuth' <<< "$out"
assert "counter cleared" grep -qx '0' "$STATE_DIR/failures"
assert "no reboot" test ! -s "$STUB_DIR/reboots"

begin_check "test: pingMode=hard escalates a WAN ping failure while Tailscale is online"
fresh_state
setup_link up 1
set_ts Running true "100.75.1.1"
set_ping_fail "1.1.1.1"
export PING_MODE=hard
export TH_REBOOT=1
run_check
assert "rc 0 (hard ping reboot)" test "$rc" -eq 0
assert "hard ping failure" grep -q 'FAIL: ping 1.1.1.1' <<< "$out"
assert "hard ping reboots" grep -q 'controlled reboot' <<< "$out"
assert "one reboot" test "$(wc -l < "$STUB_DIR/reboots" | tr -d ' ')" -eq 1
unset PING_MODE TH_REBOOT

begin_check "test: pingMode=off skips the WAN probe"
fresh_state
setup_link up 1
set_ts Running true "100.75.1.1"
set_ping_fail "1.1.1.1"
export PING_MODE=off
run_check
assert "rc 0 (ping off)" test "$rc" -eq 0
assert "no wan failure" test "$(grep -c 'FAIL: ping' <<< "$out" || true)" -eq 0
assert "no soft-ping warning" test "$(grep -c 'soft ping fail' <<< "$out" || true)" -eq 0
assert "healthy" grep -q 'OK: uplink+tailscale healthy' <<< "$out"
assert "counter cleared" grep -qx '0' "$STATE_DIR/failures"
unset PING_MODE

begin_check "test: CGNAT 100.64.0.0/10 upper bound is not a LAN gateway and 100.128 is"
fresh_state
setup_link up 1
set_ts Running false ""
printf '%s\n' 'default via 100.127.255.1 dev tailscale0 metric 0' > "$STUB_DIR/route"
set_ping_fail
run_check
assert "upper cgnat via is not a lan gateway" grep -q 'gateway=none' <<< "$out"
fresh_state
setup_link up 1
set_ts Running true "100.75.1.1"
printf '%s\n' 'default via 100.128.0.1 dev enp1 metric 100' > "$STUB_DIR/route"
set_ping_fail "100.128.0.1"
run_check
assert "address above the CGNAT range is the gateway" grep -q 'gateway=100.128.0.1' <<< "$out"
assert "that gateway failure does not escalate while Tailscale is online" grep -q 'not escalating' <<< "$out"
assert "counter cleared" grep -qx '0' "$STATE_DIR/failures"

begin_check "test: a missing watchdog device is noted once and does not fail the check"
fresh_state
setup_link up 1
set_ts Running true "100.75.1.1"
set_ping_fail
run_check
if [[ -c /dev/watchdog || -c /dev/watchdog0 ]]; then
  assert "no absence note when a device exists" test "$(grep -c 'no /dev/watchdog' <<< "$out" || true)" -eq 0
  assert "no absence marker when a device exists" test ! -f "$STATE_DIR/watchdog_absent"
else
  assert "absence noted" grep -q 'no /dev/watchdog' <<< "$out"
  assert "absence marker" test -f "$STATE_DIR/watchdog_absent"
  assert "still healthy" grep -q 'OK: uplink+tailscale healthy' <<< "$out"
  run_check
  assert "absence noted only once" test "$(grep -c 'no /dev/watchdog' <<< "$out" || true)" -eq 0
fi

echo "all network-self-heal stub checks passed (${checks} checks)"

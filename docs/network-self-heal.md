# Network self-heal (WiFi / Tailscale watchdog)

Conservative watchdog that checks **default IPv4 route**, **ping to an uplink
target** (default `1.1.1.1`, not the LAN gateway), and optionally **Tailscale
online** (`tailscale status --json` → `Self.Online`, or a non-empty
`tailscale ip -4`). On sustained **hard** failure it escalates:

1. Restart **NetworkManager** (or bounce `wifiInterface` if NM is absent)
2. Restart **tailscaled**
3. Controlled **reboot** (high threshold + cooldown under
   `/var/lib/network-self-heal` so boxes do not reboot-loop)

### Soft ping vs hard escalation

`pingMode` (default `"soft"`) controls whether a failed ICMP probe increments the
failure ladder:

| Situation | Ping fail behavior |
|-----------|--------------------|
| Tailscale online + default route OK (`pingMode = "soft"`) | **Soft**: journal `WARN` only — no NM / `tailscaled` / reboot |
| Tailscale down, or `requireTailscale = false` | **Hard**: counts toward escalation (WAN probe when TS can't prove connectivity) |
| `pingMode = "hard"` | Always hard |
| `pingMode = "off"` | Ping skipped |

Apartment WiFi often blocks ICMP to `1.1.1.1` while Tailscale still works; soft
mode avoids reboot loops in that case.

Apartment LAN (Beryl in client/WISP → GS108 switch, who is wired vs not) is
documented in [inventory.md](./inventory.md#apartment-lan-locked). That page is
docs only and does not require a rebuild.

This does **not** help if the machine is fully powered off or the kernel is
hard-locked. Prefer **ethernet over WiFi**, and keep **OOB KVM** (or equivalent)
for total radio / NIC death.

---

## AIServer (NixOS flake)

Module: [`modules/services/network-self-heal.nix`](../modules/services/network-self-heal.nix)  
Option namespace: `services.my-network-self-heal` (matches other `services.my-*` modules).

Enabled on AIServer in [`hosts/AIServer/default.nix`](../hosts/AIServer/default.nix)
with Tailscale required, reboot escalation on, and default `pingMode = "soft"`
(apartment-WiFi safe). **`wifiInterface` is left unset** until the iface name
is known — Tailscale + default-route healing still runs (NM / `tailscaled` /
reboot).

### Apply

On AIServer (or any mapped host via the Makefile):

```bash
# from a checkout of this flake
sudo nixos-rebuild switch --flake .#AIServer
# or: make switch   # when /etc/hostname maps to AIServer
```

### Optional: set WiFi iface once known

```bash
ip -br link
# journalctl -u NetworkManager -b | rg -i wlan
```

Then in `hosts/AIServer/default.nix`:

```nix
services.my-network-self-heal = {
  enable = true;
  wifiInterface = "WLAN_IFACE_NAME"; # e.g. wlp… / wlan0
  requireTailscale = true;
  escalateToReboot = true;
};
```

When `wifiInterface` is set, `disableWifiPowersave` (default `true`) runs
`iw dev <iface> set power_save off` each check.

### Useful options

| Option | Default | Notes |
|--------|---------|-------|
| `checkInterval` | `"2min"` | systemd `OnUnitActiveSec` |
| `pingTarget` | `"1.1.1.1"` | Cloudflare DNS; detects WAN loss better than gateway ping |
| `pingMode` | `"soft"` | `"soft"` / `"hard"` / `"off"` — see Soft ping vs hard escalation |
| `requireTailscale` | `true` | JSON `Self.Online` or `tailscale ip -4` |
| `failuresBeforeNetworkRestart` | `2` | NM restart / iface bounce |
| `failuresBeforeTailscaleRestart` | `4` | `systemctl restart tailscaled` |
| `failuresBeforeReboot` | `8` | only if `escalateToReboot` |
| `rebootCooldown` | `"1h"` | persisted in `/var/lib/network-self-heal/last_reboot` |

### Logs / state

```bash
journalctl -u network-self-heal.service -u network-self-heal.timer -b
systemctl status network-self-heal.timer
ls -l /var/lib/network-self-heal/
```

---

## Spark (Ubuntu / generic Linux — not in flake)

Spark is **not** a flake host ([inventory](./inventory.md)). Equivalent
behavior can be installed as a oneshot + timer. Replace placeholders:

- `WIFI_IFACE` — e.g. from `ip -br link` (leave empty to skip WiFi actions)
- Adjust thresholds / cooldown if desired

### `/usr/local/sbin/network-self-heal-check`

```bash
#!/usr/bin/env bash
set -euo pipefail

STATE_DIR=/var/lib/network-self-heal
mkdir -p "$STATE_DIR"

PING_TARGET="${PING_TARGET:-1.1.1.1}"
PING_MODE="${PING_MODE:-soft}"
REQUIRE_TS="${REQUIRE_TS:-1}"
WIFI_IFACE="${WIFI_IFACE:-}"          # e.g. wlan0 — leave empty if unknown
DISABLE_PS="${DISABLE_PS:-1}"
ESCALATE_REBOOT="${ESCALATE_REBOOT:-1}"
TH_NET="${TH_NET:-2}"
TH_TS="${TH_TS:-4}"
TH_REBOOT="${TH_REBOOT:-8}"
COOLDOWN_SEC="${COOLDOWN_SEC:-3600}"

FAILURES_FILE="$STATE_DIR/failures"
LAST_REBOOT_FILE="$STATE_DIR/last_reboot"

log() { echo "network-self-heal: $*"; logger -t network-self-heal "$*" || true; }

read_failures() { [[ -f "$FAILURES_FILE" ]] && cat "$FAILURES_FILE" || echo 0; }
write_failures() { echo "$1" > "$FAILURES_FILE"; }

if [[ -n "$WIFI_IFACE" && "$DISABLE_PS" == "1" ]]; then
  iw dev "$WIFI_IFACE" set power_save off 2>/dev/null || true
fi

hard=0
route_ok=1
if ! ip -4 route show default | grep -q .; then
  log "FAIL: no default IPv4 route"; route_ok=0; hard=1
fi

ts_online=0
if command -v tailscale >/dev/null 2>&1; then
  if tailscale status --json 2>/dev/null | jq -e '.Self.Online == true' >/dev/null 2>&1 \
     || [[ -n "$(tailscale ip -4 2>/dev/null || true)" ]]; then
    ts_online=1
  fi
fi

if [[ "$REQUIRE_TS" == "1" && "$ts_online" != "1" ]]; then
  log "FAIL: Tailscale not online / no IPv4"; hard=1
fi

if [[ "$PING_MODE" != "off" ]] && ! ping -c 1 -W 3 "$PING_TARGET" >/dev/null 2>&1; then
  if [[ "$PING_MODE" == "soft" && "$REQUIRE_TS" == "1" && "$route_ok" == "1" && "$ts_online" == "1" ]]; then
    log "WARN: soft ping fail to $PING_TARGET (Tailscale online + default route OK; not escalating)"
  else
    log "FAIL: ping $PING_TARGET"; hard=1
  fi
fi

if [[ "$hard" == "0" ]]; then
  log "OK: uplink+tailscale healthy"
  write_failures 0
  exit 0
fi

failures=$(( $(read_failures) + 1 ))
write_failures "$failures"
log "consecutive failures=$failures"

if [[ "$failures" -eq "$TH_NET" ]]; then
  if systemctl cat NetworkManager.service >/dev/null 2>&1; then
    log "escalation: restarting NetworkManager"
    systemctl restart NetworkManager.service || true
  elif [[ -n "$WIFI_IFACE" ]]; then
    log "escalation: bouncing $WIFI_IFACE"
    ip link set "$WIFI_IFACE" down || true; sleep 2; ip link set "$WIFI_IFACE" up || true
  fi
elif [[ "$failures" -eq "$TH_TS" ]]; then
  log "escalation: restarting tailscaled"
  systemctl restart tailscaled.service || true
elif [[ "$failures" -ge "$TH_REBOOT" && "$ESCALATE_REBOOT" == "1" ]]; then
  now=$(date +%s); last=0
  [[ -f "$LAST_REBOOT_FILE" ]] && last=$(cat "$LAST_REBOOT_FILE" || echo 0)
  if [[ "$last" != "0" && $(( now - last )) -lt "$COOLDOWN_SEC" ]]; then
    log "escalation: reboot suppressed (cooldown)"
  else
    log "escalation: controlled reboot"
    echo "$now" > "$LAST_REBOOT_FILE"
    sync || true
    systemctl reboot || reboot
  fi
fi
```

```bash
sudo install -m 0755 network-self-heal-check /usr/local/sbin/network-self-heal-check
# optional drop-in env: WIFI_IFACE=… in the service unit below
```

### `/etc/systemd/system/network-self-heal.service`

```ini
[Unit]
Description=WiFi/Tailscale network self-heal check
After=network-pre.target NetworkManager.service tailscaled.service
Wants=network-pre.target

[Service]
Type=oneshot
# Environment=WIFI_IFACE=wlan0
# Environment=PING_TARGET=1.1.1.1
ExecStart=/usr/local/sbin/network-self-heal-check
```

### `/etc/systemd/system/network-self-heal.timer`

```ini
[Unit]
Description=Periodic WiFi/Tailscale network self-heal watchdog

[Timer]
OnBootSec=3min
OnUnitActiveSec=2min
AccuracySec=30s
Persistent=true
Unit=network-self-heal.service

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now network-self-heal.timer
journalctl -u network-self-heal.service -b -f
```

### Packages (Ubuntu example)

```bash
sudo apt-get update
sudo apt-get install -y iproute2 iputils-ping jq iw tailscale
# NetworkManager optional but preferred for the first escalation rung
```

---

## Limits (read me)

- **Ethernet > WiFi** for anything you care about staying up.
- **OOB KVM** (or smart PDU + console) is still the right answer for total
  radio/NIC death — this watchdog only helps soft failures.
- No help when the host is **powered off** or **kernel hard-locked**.
- Reboot is gated by a high failure count **and** a cooldown file under
  `/var/lib/network-self-heal`; do not disable that lightly.

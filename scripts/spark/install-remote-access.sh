#!/usr/bin/env bash
# Install Spark (Ubuntu) remote-access hardening. Not part of the NixOS flake.
# Run on the Spark box as root, from a copy of scripts/spark/:
#   sudo bash install-remote-access.sh
# No SSIDs, PSKs, or Tailscale auth keys.

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DEBIAN_FRONTEND=noninteractive

echo "network-self-heal: installing base packages"
apt-get update
apt-get install -y \
  iproute2 \
  iputils-ping \
  jq \
  iw \
  gawk \
  curl \
  ca-certificates \
  openssh-server

install -m 0755 "$SCRIPT_DIR/network-self-heal.sh" /usr/local/sbin/network-self-heal-check
install -m 0644 "$SCRIPT_DIR/network-self-heal.service" /etc/systemd/system/network-self-heal.service
install -m 0644 "$SCRIPT_DIR/network-self-heal.timer" /etc/systemd/system/network-self-heal.timer

if [[ ! -f /etc/default/network-self-heal ]]; then
  cat > /etc/default/network-self-heal <<'EOF'
# Optional overrides for /usr/local/sbin/network-self-heal-check.
# systemd EnvironmentFile syntax (KEY=value). Leave unset to auto-detect.
# WIFI_IFACE=
# LAN_GATEWAY=
# PING_TARGET=1.1.1.1
# PING_MODE=soft
# TH_NET=2
# TH_TS=4
# TH_REBOOT=9
# COOLDOWN_SEC=3600
EOF
  chmod 0644 /etc/default/network-self-heal
fi

systemctl daemon-reload
systemctl enable network-self-heal.service
systemctl enable --now network-self-heal.timer

echo "network-self-heal: disabling sleep and suspend"
mkdir -p /etc/systemd/logind.conf.d /etc/systemd/sleep.conf.d
cat > /etc/systemd/logind.conf.d/no-sleep.conf <<'EOF'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
IdleAction=ignore
EOF
cat > /etc/systemd/sleep.conf.d/no-sleep.conf <<'EOF'
[Sleep]
AllowSuspend=no
AllowHibernation=no
AllowHybridSleep=no
AllowSuspendThenHibernate=no
EOF
systemctl mask --now sleep.target suspend.target hibernate.target hybrid-sleep.target

if command -v nmcli >/dev/null 2>&1; then
  echo "network-self-heal: preferring wired Ethernet over WiFi (WiFi stays as fallback)"
  nmcli_out="$(mktemp)"
  nmcli -t -f UUID,TYPE connection show >"$nmcli_out" || true
  while IFS=: read -r uuid typ; do
    [[ -n "$uuid" ]] || continue
    case "$typ" in
      802-3-ethernet)
        nmcli connection modify "$uuid" connection.autoconnect yes \
          connection.autoconnect-priority 100 \
          connection.autoconnect-retries 0 || true
        ;;
      802-11-wireless)
        nmcli connection modify "$uuid" connection.autoconnect yes \
          connection.autoconnect-priority 0 \
          connection.autoconnect-retries 0 || true
        ;;
    esac
  done < "$nmcli_out"
  rm -f "$nmcli_out"
  if command -v iw >/dev/null 2>&1; then
    for path in /sys/class/net/*; do
      [[ -e "$path/phy80211" ]] || continue
      iw dev "${path##*/}" set power_save off 2>/dev/null || true
    done
  fi
else
  echo "network-self-heal: nmcli not installed; not changing connection priority (netplan/networkd left as-is)"
fi

echo "network-self-heal: enabling OpenSSH"
systemctl enable --now ssh

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
  ufw allow in on tailscale0 to any port 22 proto tcp comment 'OpenSSH over Tailscale' || true
fi

if [[ -c /dev/watchdog || -c /dev/watchdog0 ]]; then
  echo "network-self-heal: arming systemd hardware watchdog (takes effect on reboot)"
  mkdir -p /etc/systemd/system.conf.d
  cat > /etc/systemd/system.conf.d/hardware-watchdog.conf <<'EOF'
[Manager]
RuntimeWatchdogSec=60s
RebootWatchdogSec=10min
EOF
else
  echo "network-self-heal: no /dev/watchdog; not setting RuntimeWatchdogSec (systemd would ignore it)"
fi

install_tailscale() {
  if command -v tailscale >/dev/null 2>&1; then
    systemctl enable --now tailscaled
    return 0
  fi
  local codename=""
  if [[ -r /etc/os-release ]]; then
    codename="$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release | tr -d '"' | head -n1)"
  fi
  if [[ -z "$codename" ]]; then
    echo "Could not read VERSION_CODENAME. Install Tailscale from https://tailscale.com/download/linux" >&2
    return 1
  fi
  echo "network-self-heal: installing Tailscale for Ubuntu $codename"
  install -d /usr/share/keyrings /etc/apt/sources.list.d
  curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${codename}.noarmor.gpg" \
    -o /usr/share/keyrings/tailscale-archive-keyring.gpg
  curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${codename}.tailscale-keyring.list" \
    -o /etc/apt/sources.list.d/tailscale.list
  apt-get update
  apt-get install -y tailscale
  systemctl enable --now tailscaled
}

ts_ok=0
if install_tailscale; then
  ts_ok=1
fi

echo
echo "Installed. Still do these by hand on Spark:"
echo "  1. If 'tailscale status' is not online: sudo tailscale up   (one time; approve the node in the admin console)"
echo "  2. Disable key expiry for this node in the Tailscale admin console."
echo "  3. Confirm Ethernet is the default route (not WiFi):"
echo "       ip -br link"
echo "       ip -4 route show default"
echo "  4. BIOS: power on after AC loss."
echo "  5. Reboot once so logind/sleep settings and RuntimeWatchdogSec (if a watchdog exists) are armed."
echo "  6. From another tailnet node: ssh <user>@spark-48e5.tail93ec7d.ts.net"
if [[ "$ts_ok" != "1" ]]; then
  echo "Tailscale is not installed; the timer is enabled and will heal after tailscale exists." >&2
  exit 1
fi

if command -v tailscale >/dev/null 2>&1; then
  backend="$(tailscale status --json 2>/dev/null | jq -r '.BackendState // empty' 2>/dev/null || true)"
  case "$backend" in
    Running) echo "Tailscale BackendState=Running." ;;
    *) echo "Tailscale BackendState=${backend:-unknown}. A one-time 'sudo tailscale up' is still required if this is not Running." ;;
  esac
fi

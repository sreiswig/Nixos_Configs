# Network self-heal (uplink / Tailscale watchdog)

Conservative watchdog. The check script is
[`scripts/spark/network-self-heal.sh`](../scripts/spark/network-self-heal.sh).
The NixOS module inlines that file so AIServer and Spark stay on one implementation.
Hand checklist for all three machines: [remote-access/README.md](./remote-access/README.md).

Each tick it looks at:

- physical link (carrier)
- default IPv4 route and the **LAN gateway** (lowest-metric `via`, ignoring a Tailscale CGNAT next hop)
- optional **WAN ping** (default `1.1.1.1`)
- **Tailscale** online (`tailscale status --json` → `Self.Online`, or a non-empty `tailscale ip -4`)

**Every tick** (before counting a hard failure) it tries a light reconnect:

1. If a WiFi iface is unassociated: `nmcli radio wifi on`, then `nmcli device connect` / saved `802-11-wireless` profiles. No SSID or password lives in this flake.
2. If Tailscale is down: `tailscale up` (existing node login; no auth key).

**Link loss** (no physical NIC has carrier, or the default-route NIC has no carrier while Tailscale is offline) restarts, once per outage:

1. **NetworkManager**, if that unit is active or enabled, then connects disconnected Ethernet devices
2. **systemd-networkd**, only if that unit is active or enabled (it is not started just because the unit file exists)
3. **tailscaled**, then `tailscale up` again

On a sustained **hard** failure the timer then escalates:

1. Restart NetworkManager / systemd-networkd (same rule) at 2 failures
2. Restart **tailscaled** at 4 failures
3. Controlled **reboot** at 9 failures (~16 minutes at a 2 minute cadence; 1 hour cooldown under `/var/lib/network-self-heal`)

`NeedsLogin` / `NeedsMachineAuth` resets the counter and does **not** reboot. A missing `tailscale` binary does not reboot.

### Soft ping vs hard escalation

| Situation | Behavior |
|-----------|----------|
| Tailscale online, WAN ping fails (`pingMode = "soft"`) | **Warn** only |
| Tailscale online, LAN gateway or default route unusable | **Warn** only — a reachable box is not rebooted |
| Tailscale offline | **Hard**, including a missing LAN gateway |
| `pingMode = "hard"` | WAN ping failure is always hard |
| `pingMode = "off"` | WAN ping skipped |
| `BackendState` is `NeedsLogin` or `NeedsMachineAuth` | No reboot |

Apartment WiFi often blocks ICMP to `1.1.1.1` while Tailscale still works. Soft mode, and the gateway warn, avoid reboot loops in that case.

Apartment LAN (Beryl in client/WISP → GS108 switch) is documented in [inventory.md](./inventory.md#apartment-lan-locked).

This does **not** help if the machine is fully powered off or the kernel is hard-locked. Prefer **ethernet**, and keep an **IP KVM plus a smart plug** (priced separately). See the [remote-access checklist](./remote-access/README.md).

---

## AIServer (NixOS flake)

Module: [`modules/services/network-self-heal.nix`](../modules/services/network-self-heal.nix)  
Option namespace: `services.my-network-self-heal`.

Enabled on AIServer in [`hosts/AIServer/default.nix`](../hosts/AIServer/default.nix) with Tailscale required and reboot escalation on. `wifiInterface = "wlp38s0"`. If that name is missing at runtime the check auto-detects via `nmcli` / `iw dev`.

When the module is on it also:

- requires `services.tailscale.enable` (assertion). The NixOS module wants `tailscaled` from `multi-user.target`, so it starts at boot
- sets `systemd.settings.Manager.RuntimeWatchdogSec` (default `60s`) if `hardwareWatchdog` is true. systemd ignores this when no hardware watchdog exists. No watchdog kernel module is loaded
- keeps sshd enabled, not socket-activated, and allows **TCP 22 and 3389 on `tailscale0`**. AIServer already runs xrdp and OpenSSH; LAN firewall openings are unchanged

### Apply

On AIServer (or any mapped host via the Makefile):

```bash
sudo nixos-rebuild switch --flake .#AIServer
# or: make switch   # when /etc/hostname maps to AIServer
```

Merging the flake does not switch the live host.

### WiFi iface

AIServer is set to `wlp38s0`. Confirm with:

```bash
ip -br link
```

Override in `hosts/AIServer/default.nix` if the name changes:

```nix
services.my-network-self-heal = {
  enable = true;
  wifiInterface = "WLAN_IFACE_NAME"; # e.g. wlp… / wlan0
  requireTailscale = true;
  escalateToReboot = true;
};
```

First-time WiFi still needs a manual NetworkManager profile on the box. First-time Tailscale still needs a one-time `tailscale up`.

### Useful options

| Option | Default | Notes |
|--------|---------|-------|
| `checkInterval` | `"2min"` | systemd `OnUnitActiveSec` |
| `pingTarget` | `"1.1.1.1"` | WAN probe |
| `pingMode` | `"soft"` | `"soft"` / `"hard"` / `"off"` |
| `lanGateway` | `null` | auto-detect; set to force a gateway address |
| `requireTailscale` | `true` | also `tailscale up` each tick when down |
| `wifiInterface` | `null` (AIServer: `wlp38s0`) | auto-detects if unset/missing |
| `failuresBeforeNetworkRestart` | `2` | NM / networkd-if-in-use; link loss is immediate |
| `failuresBeforeTailscaleRestart` | `4` | `systemctl restart tailscaled` |
| `failuresBeforeReboot` | `9` | ~16 minutes at 2min; only if `escalateToReboot` |
| `rebootCooldown` | `"1h"` | `/var/lib/network-self-heal/last_reboot` |
| `hardwareWatchdog` | `true` | `RuntimeWatchdogSec`, no effect without hardware |
| `watchdogRuntimeTime` | `"60s"` | PID 1 pings at half this interval |

Timer `AccuracySec` is 15s so the 9×2min window stays inside about 15–20 minutes.

### Logs / state

```bash
journalctl -u network-self-heal.service -u network-self-heal.timer -b
systemctl status network-self-heal.timer
ls -l /var/lib/network-self-heal/
```

After a switch, `journalctl -b | rg -i watchdog` should show either a live hardware watchdog or that the device is absent. Absence is not a failed boot.

---

## Spark (Ubuntu)

Not a flake host. Install steps: [remote-access/spark.md](./remote-access/spark.md).

```bash
sudo bash scripts/spark/install-remote-access.sh
bash scripts/spark/test-network-self-heal.sh   # stub test, no root
```

---

## Windows

Not a flake host. [remote-access/windows-server.md](./remote-access/windows-server.md).

---

## Limits

- **Ethernet > WiFi** for anything that must stay up.
- **IP KVM + smart plug** is still required for power-off and hard lock. Software cannot press the power button.
- **Key expiry** in the Tailscale admin console is a hand step. This repo has no API token.
- Reboot is gated by a high failure count **and** a cooldown file under `/var/lib/network-self-heal`.
- Do not load a random watchdog kernel module. A wrong driver can reset the box in a loop.

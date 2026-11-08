# Spark (Ubuntu DGX) remote access

Spark is **not** a NixOS host. Copy `scripts/spark/` to the box (scp, USB) and install there. Do not commit Tailscale auth keys, SSIDs, or passwords.

MagicDNS: `spark-48e5.tail93ec7d.ts.net`.

## Install

```bash
sudo bash install-remote-access.sh
```

The installer is idempotent. It:

- Installs `iproute2`, `iputils-ping`, `jq`, `iw`, `gawk`, `curl`, OpenSSH, and Tailscale (Ubuntu apt repo for `/etc/os-release` `VERSION_CODENAME`, or uses an existing `tailscale` binary)
- Installs [`network-self-heal.sh`](../../scripts/spark/network-self-heal.sh) to `/usr/local/sbin/network-self-heal-check` plus the matching [service](../../scripts/spark/network-self-heal.service) and [timer](../../scripts/spark/network-self-heal.timer) (every 2 minutes; also once at boot)
- Enables `tailscaled` at boot
- Masks sleep, suspend, hibernate, and hybrid-sleep; writes logind and `sleep.conf` drop-ins
- Prefers saved **Ethernet** NetworkManager profiles (autoconnect priority 100) over Wi-Fi (priority 0). Wi-Fi stays as a fallback
- Enables OpenSSH (`ssh`). If `ufw` is already active, allows TCP 22 on `tailscale0`
- If `/dev/watchdog` or `/dev/watchdog0` exists, writes `RuntimeWatchdogSec=60s` under `/etc/systemd/system.conf.d/`. It does **not** install the `watchdog` apt package (that userspace daemon fights systemd for the device) and does **not** load a kernel module

Optional overrides (only created if missing, so a re-run will not clobber them): `/etc/default/network-self-heal`.

The check script is the same file the AIServer NixOS module inlines. Behavior is the [outage rule](./README.md#outage-rule-all-three) in the checklist. Stub test, from a checkout:

```bash
bash scripts/spark/test-network-self-heal.sh
```

## Hand steps

1. If Tailscale is not already up: `sudo tailscale up` once, then approve the node. The installer does not pass an auth key.
2. Disable **key expiry** for this node in the Tailscale admin console.
3. Confirm the cable is the path that matters:

   ```bash
   ip -br link
   ip -4 route show default
   ```

   The `dev` on the default route should be the Ethernet NIC, not a `wl*` interface. Inventory still has Spark off the GS108 until this is true.
4. BIOS: **power on after AC loss**.
5. **Reboot once.** Sleep masks are immediate; the logind drop-in and `RuntimeWatchdogSec` arm on the next boot. If `ls /dev/watchdog*` is empty, systemd's watchdog setting has no effect — re-run the installer after a device node exists. Do not guess a watchdog kernel module.
6. From another tailnet node: `ssh <user>@spark-48e5.tail93ec7d.ts.net`. The DGX login is often `nvidia`; this repo does not set it.

xrdp on Spark, if it is already installed, can stay. This installer does not reconfigure it. Reach it at `spark-48e5.tail93ec7d.ts.net:3389` over Tailscale.

Logs:

```bash
systemctl status network-self-heal.timer
journalctl -u network-self-heal.service -b
```

State: `/var/lib/network-self-heal/` (`failures`, `last_reboot`).

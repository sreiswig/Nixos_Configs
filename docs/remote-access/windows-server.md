# Windows server remote access

The Windows server is **not** Nix-managed. Copy `scripts/windows/remote-hardening.ps1` to the box and run it **once** from an elevated PowerShell. No passwords, Tailscale auth keys, or SSIDs.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\remote-hardening.ps1
```

Re-running is safe. The script copies itself to `C:\ProgramData\remote-self-heal\remote-hardening.ps1` and registers the SYSTEM task `RemoteNetworkSelfHeal`, which runs that copy with `-Check` every 2 minutes whether or not anyone is logged in.

## What the script changes

- **Tailscale** service set to Automatic (not delayed) so it starts at boot, before login. Runs `tailscale up --unattended` with a 25s cap. If that times out, the node is not logged in yet.
- **Power:** every power scheme's sleep, hibernate, and hybrid sleep set to never; disk timeout never; USB selective suspend and PCIe ASPM off; High performance activated when that scheme exists. `powercfg /hibernate off` also disables Fast Startup so a power-loss boot is a full boot.
- **Physical NICs:** `Disable-NetAdapterPowerManagement`, energy-efficient Ethernet / green-ethernet advanced properties where the driver has them, and `PnPCapabilities = 24` (do not power the device off).
- **RDP** enabled, NLA left on (the Windows account, not a password in this repo).
- **OpenSSH Server** capability installed when the image provides it, service Automatic.
- **Firewall:** TCP 3389 and 22 allowed from Tailscale CGNAT `100.64.0.0/10`. The wide-open Remote Desktop and OpenSSH rules are disabled **only if** `tailscale ip -4` is already a CGNAT address, so a first run cannot lock out the LAN before Tailscale works. Re-run the script after `tailscale up --unattended` to apply the limit.
- **Scheduled task:** pings the LAN gateway (default route, skipping the Tailscale adapter and CGNAT next hops) and reads `tailscale status` (`Self.Online`, with an IPv4 fallback). It does not ICMP a peer, so one box being off does not reboot the others. While Tailscale is offline it resets physical adapters and restarts the Tailscale service. After **9** failures (~16 minutes) it reboots, then waits **1 hour** before another reboot. `NeedsLogin` does not reboot.
- **Windows Update:** active hours **08:00–02:00** (18h, the maximum span) and `NoAutoRebootWithLoggedOnUsers=1`. Updates stay enabled. A reboot for updates can still happen in the 02:00–08:00 window when nobody is logged on.

Log: `C:\ProgramData\remote-self-heal\self-heal.log`.

## Auto-login (off)

The script does **not** enable auto-login.

Tailscale, RDP, and OpenSSH run as services at the login screen. BIOS **power on after AC loss** is what brings the machine back; a desktop session is not required.

`AutoAdminLogon` stores the account password in the registry in a recoverable form, and anyone at the keyboard gets a session. It also fights the update policy: a user who is always logged on blocks Windows Update reboots overnight (`NoAutoRebootWithLoggedOnUsers`). Set it locally only if a GUI program must already be running after power loss. Never put that password in git.

## Hand steps

1. Install Tailscale for Windows if the script warned that it is missing: <https://tailscale.com/download/windows>
2. If it is not online: `tailscale up --unattended`, approve the node, then **re-run** `remote-hardening.ps1` so RDP and SSH are limited to the tailnet.
3. Disable **key expiry** for this node in the Tailscale admin console.
4. Confirm Ethernet, not Wi-Fi. Inventory still has this machine off the GS108 until this is true:

   ```powershell
   Get-NetAdapter -Physical | Format-Table Name, Status, LinkSpeed, MediaType
   Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Format-Table InterfaceAlias, NextHop, RouteMetric
   ```

5. BIOS: **power on after AC loss**.
6. Optional: install your SSH public key into the Windows `authorized_keys` (or `C:\ProgramData\ssh\administrators_authorized_keys` for admins). Do not commit the key. Password SSH over the tailnet still works if you skip this; the firewall limit is what keeps it off the LAN.
7. From another tailnet node, test RDP to the machine's Tailscale name and SSH to port 22 before you walk away.

There is no hardware watchdog setting in this script. Windows reboot-on-outage is the scheduled task. An IP KVM and a smart plug are still the answer for a powered-off box ([checklist](./README.md)).

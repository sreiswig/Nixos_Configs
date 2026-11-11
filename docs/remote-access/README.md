# Remote access

Sam reaches **AIServer** (NixOS, this flake), **Spark** (Ubuntu, not Nix), and the **Windows server** over Tailscale when he is away. Walking over with a monitor is the failure this is meant to avoid.

| Machine | What to apply | Detail |
|---------|---------------|--------|
| AIServer | `nh os switch` / `nixos-rebuild switch --flake .#AIServer` on the host | [network-self-heal.md](../network-self-heal.md) |
| Spark | `sudo bash scripts/spark/install-remote-access.sh` on the Ubuntu box | [spark.md](./spark.md) |
| Windows | elevated `remote-hardening.ps1` | [windows-server.md](./windows-server.md) |

Merging a PR does not change a live machine.

## Checklist (by hand)

Do these for **AIServer, Spark, and the Windows server**. Nothing in this repo can do them.

1. **Tailscale admin → Machines → disable key expiry** on all three nodes. An expired node key looks like the machine is offline. This repo does not store an API token.
2. **BIOS: power on after AC loss.** Wording varies (Restore on AC Power Loss, After Power Loss, AC Back, Always On). A watchdog cannot turn the PSU back on.
3. **Confirm Spark and Windows are actually on Ethernet.** [inventory](../inventory.md#apartment-lan-locked) still has both **off** the Netgear GS108. Apartment WiFi → GL.iNet Beryl (WISP/client) → GS108 → servers. The default route should be the wired NIC, not Wi-Fi.
4. **Out-of-band IP KVM plus a smart plug** is still the right answer when the machine is powered off or the kernel is hard-locked. Hardware is being priced separately; this doc is not a shopping list.
5. Apply the per-machine steps, then from another tailnet node confirm SSH (and RDP where it is installed) before relying on it.

No SSIDs, passwords, or Tailscale auth keys belong in this repo.

## Outage rule (all three)

Checks run every **2 minutes**.

- **Tailscale online:** the box is reachable, so it is not rebooted. Spark and AIServer default to `pingMode` **soft**: a failed ping to `1.1.1.1` or to the LAN gateway is a warning only. Windows probes the LAN gateway only; a failed gateway ping is a warning only.
- **Tailscale offline:** that is a hard outage. On Spark and AIServer, link loss restarts the network stack (NetworkManager and, if it is actually in use, systemd-networkd) and Tailscale. On Windows, each offline check resets the physical adapters and the Tailscale service.
- **About 16 minutes** of Tailscale being offline (9 checks) triggers a reboot, then a **1 hour** cooldown so it cannot reboot-loop. That sits in the 15–20 minute window.
- **`NeedsLogin` / `NeedsMachineAuth`** does not reboot. Someone still has to run `tailscale up` once on the console.

On AIServer, `RuntimeWatchdogSec=60s` is set with the module, and systemd ignores it when no hardware watchdog exists. On Spark, that setting is written only if `/dev/watchdog` or `/dev/watchdog0` already exists. No watchdog kernel module is loaded; a guessed module can reset the machine in a loop. The Windows script leaves the hardware watchdog unset.

# Homelab inventory

Human-facing fleet table. Fill PCI/SMBIOS and Tailscale fields from
**nixos-facter** / `lshw -json` (or the host) when available — see
[hardware-inventory.md](./hardware-inventory.md).

External machines (Spark, Windows) live here only until they have a flake host.

| Host | Flake attr | Hostname / MagicDNS | Platform | SMBIOS product / key PCI | Role | Notes |
|------|------------|---------------------|----------|--------------------------|------|-------|
| AIServer | `AIServer` | `AI_Server` / `aiserver.tail93ec7d.ts.net` | NixOS | _TBD (facter)_ | App/services hub | Caddy, Vault, Gitea, Attic, monitoring, K3s, [network self-heal](./network-self-heal.md), … |
| sam_main | `sam-main` | `sam_nixos` | NixOS | _TBD_ | Primary workstation | Hyprland/Plasma, NVIDIA |
| framework13 | `framework13` | `framework13` | NixOS | _TBD_ | Laptop |
| dad_nas | `dad_nas` | `queennas` / `queennas.tail93ec7d.ts.net` | NixOS | _TBD_ | Media NAS | Jellyfin, Immich; TS IP `100.74.70.2` in Caddy |
| asus_rog_1070 | `asus_rog_1070` | `asus-rog-1070` | NixOS | _TBD_ | Secondary GPU desktop | Ollama CUDA |
| Spark | — | `spark-48e5` / `spark-48e5.tail93ec7d.ts.net` | non-NixOS (Ubuntu) | _TBD_ | Primary LLM (vLLM) | Not in flake; TS IP `100.75.241.49`; xrdp :3389 over Tailscale |
| Windows | — | _TBD_ | Windows | _TBD_ | Client | Not in flake |

## Hostname ↔ flake attr

See root `Makefile` for rebuild mapping (`AI_Server` → `AIServer`, `queennas` → `dad_nas`, etc.).

## Apartment LAN (locked)

Docs only. This section does not change Nix, and merging it does **not** require a
`nixos-rebuild`. Merged flake work is still not live until Sam rebuilds on the host.

No SSIDs, passwords, or other secrets belong in this file.

### Path

Apartment WiFi → **Gl.iNet Beryl** (client / WISP mode) → **Netgear GS108**
(8-port unmanaged switch).

### Who is on the switch

| Device | On GS108 today | Notes |
|--------|----------------|-------|
| sam_main | yes | Primary workstation |
| Raspberry Pi | yes | Not a flake host; no further identity recorded here |
| AIServer | yes | Services hub |
| Windows | no | Still off the switch |
| Spark | no | Still off the switch. MagicDNS `spark-48e5.tail93ec7d.ts.net`; vLLM `served-model-name` is Sam-only — leave TBD |

### Preferred wiring

Wire **AIServer**, **Spark**, and **OOB KVM** to the GS108. Do not put servers on
WiFi directly. The Beryl is the apartment-WiFi client; hosts that matter should
sit on the switch behind it.

Related: [network self-heal](./network-self-heal.md) (soft WAN ping when Tailscale
is up; ethernet + OOB KVM for radio / NIC death).

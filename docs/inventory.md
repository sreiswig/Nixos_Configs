# Homelab inventory

Human-facing fleet table. Fill PCI/SMBIOS and Tailscale fields from
**nixos-facter** / `lshw -json` (or the host) when available — see
[hardware-inventory.md](./hardware-inventory.md).

External machines (Spark, Windows) live here only until they have a flake host.

| Host | Flake attr | Hostname / MagicDNS | Platform | SMBIOS product / key PCI | Role | Notes |
|------|------------|---------------------|----------|--------------------------|------|-------|
| AIServer | `AIServer` | `AI_Server` / `aiserver.tail93ec7d.ts.net` | NixOS | _TBD (facter)_ | App/services hub | Caddy, Vault, Gitea, Attic, monitoring, K3s, … |
| sam_main | `sam-main` | `sam_nixos` | NixOS | _TBD_ | Primary workstation | Hyprland/Plasma, NVIDIA |
| framework13 | `framework13` | `framework13` | NixOS | _TBD_ | Laptop | |
| dad_nas | `dad_nas` | `queennas` / `queennas.tail93ec7d.ts.net` | NixOS | _TBD_ | Media NAS | Jellyfin, Immich; TS IP `100.74.70.2` in Caddy |
| asus_rog_1070 | `asus_rog_1070` | `asus-rog-1070` | NixOS | _TBD_ | Secondary GPU desktop | Ollama CUDA |
| Spark | — | _TBD MagicDNS_ | non-NixOS | _TBD_ | Primary LLM (vLLM) | Not in flake |
| Windows | — | _TBD_ | Windows | _TBD_ | Client | Not in flake |

## Hostname ↔ flake attr

See root `Makefile` for rebuild mapping (`AI_Server` → `AIServer`, `queennas` → `dad_nas`, etc.).

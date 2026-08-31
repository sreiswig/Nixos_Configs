# Hardware inventory convention

How we describe exact hardware in this repo. **Docs-first** for now;
per-host `facter.json` and thin `hardware.nix` come later when Sam asks
and someone can run a probe on the box.

## Layers

| Layer | What | Status |
|-------|------|--------|
| `docs/inventory.md` | Fleet roles, MagicDNS, platform, key IDs | **This PR** |
| `hosts/<name>/hardware-configuration.nix` | Generated FS/boot (`nixos-generate-config`) | Existing — keep |
| `hosts/<name>/facter.json` (or `lshw.json`) | Committed probe: SMBIOS + PCI IDs | **Not yet** (needs host access) |
| `hosts/<name>/hardware.nix` | Intentional enables only (which GPU modules, host kernel bits) | **Hold** — no refactor in this PR |
| `modules/hardware/gpu/*.nix` | Shared GPU stacks | Existing |

## Rules (when we implement facter / hardware.nix)

1. Prefer **SMBIOS product/serial** and **PCI vendor:device IDs** as identifiers.
2. Commit a probe JSON per NixOS host after review (no secrets).
3. Import GPU (and other) hardware modules **only** when the probe shows that device — do not blindly import amd+nvidia+intel on AIServer.
4. Spark / Windows: document in `inventory.md` only until NixOS’d.

## Capture (later, on the host)

```bash
# Preferred
nix run nixpkgs#nixos-facter -- -o hosts/AIServer/facter.json

# Fallback
sudo lshw -json > hosts/AIServer/lshw.json
```

Regenerate in a dedicated PR when hardware changes.

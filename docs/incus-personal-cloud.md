# Incus personal cloud (plan)

Status: **Slice A on AIServer (Sam override 2026-09-19) — AI workloads** — `services.my-incus-host.enable = true` on `hosts/AIServer`. Placeholder `hosts/incus_cloud` is an **unused template** (module off). Merged to main; **Sam** runs `nh os switch`. Agents do not switch.

**Workload intent:** Incus for **AI** system containers/VMs (nicer deploys), not a generic VM farm. **Dispatch** stays compose+Caddy on the host. **Spark** stays primary vLLM (no Incus on Spark).

**Coexistence risks (accepted by Sam):**
- AIServer still runs `services.my-k3s` (Docker + nvidia), desktop/xrdp, Dispatch compose + Caddy, Vault/Gitea/Attic/Ollama
- Incus bridges (`incusbr0`) + required `networking.nftables` can interact badly with k3s CNI / Docker iptables-legacy assumptions — validate after first switch (`incus network list`, pod networking, Dispatch loopback)
- Preseed creates/updates only; it does **not** delete leftover networks/pools
- Do **not** enable on Spark

**Sam still fills / verifies after rebuild:**
1. Confirm `incus admin waitready` / `incus profile show default` after switch
2. Optional dedicated disk for `services.my-incus-host.poolSource` (default dir under `/var/lib/incus`)
3. Watch nftables + k3s + Docker after enable

**Module:** `modules/services/incus-host.nix` → `services.my-incus-host`


Locks (Chief of Staff / Sam, 2026-09-19):

- **Incus** (not libvirt-first) for new cloud-shaped compute
- **NixOS** hosts the Incus daemon (prefer this repo)
- **OpenTofu** + official [lxc/incus](https://registry.terraform.io/providers/lxc/incus/latest/docs) provider declares projects / networks / instances / ACLs
- **AI Dispatch** = portal / tools control plane only — no virt business logic in the Python dispatcher; Rust harness drivers talk to host APIs later
- **Tailscale** = VPC path in
- **No VMs on Spark** (Spark stays vLLM)
- Free-tier GitHub only; no Jenkins / K8s for this path
- Single-host **AIServer** stays compose + Caddy for Dispatch; Incus is **adjacent** compute, not a reason to invent Kubernetes

NixOS reference: [wiki.nixos.org/wiki/Incus](https://wiki.nixos.org/wiki/Incus)

---


## Workload intent & k8s coexistence (Sam, 2026-09-19)

Incus on AIServer is for **AI workloads** — system containers / VMs with nicer deploy/lifecycle — not a generic desktop-VM farm.

**Dispatch** stays **compose + Caddy on the AIServer host** (do not migrate to k8s/Incus in Slice A).

**Spark** remains primary **vLLM**. No Incus on Spark; do not move that role onto AIServer Incus.

### Coexistence with host `my-k3s` / Docker / nvidia

| Model | What | When |
|-------|------|------|
| **A (default)** | Keep **host k3s** for current K8s apps (Docker+nvidia as today). **Incus** runs AI containers/VMs beside it. OpenTofu later for instance lifecycle. | Now |
| **B (optional later)** | Shrink/remove host k3s; run Kubernetes only inside Incus VMs. | Only after A is stable and Sam asks |

**Default: A.** Do not disable `services.my-k3s` in Slice A.

### GPU / nvidia (AI instances)

- Leave the host nvidia + Docker/k3s GPU path alone for existing workloads.
- Incus containers needing GPU: nvidia CDI / GPU devices per current Incus docs — validate with a throwaway CUDA container **after** Sam’s rebuild.
- Incus VMs needing GPU: PCI passthrough (IOMMU) — follow-up, not Slice A preseed.
- Do not take GPUs from Spark’s vLLM role.

### OpenTofu

Instance lifecycle = **Slice B** after A is live. Nix preseed only: bridge + default dir pool + default profile.


## 1. Architecture note

### Where the daemon lives (Slice A recommendation)

| Option | Verdict | Why |
|--------|---------|-----|
| **Dedicated NixOS Incus host** (new box, or Sam-approved repurpose of `asus_rog_1070`) | **Recommended** | Clean nftables / bridge story; no fight with k3s CNI or Dispatch compose; matches “adjacent compute” |
| **AIServer** | **Not Slice A** (Plan B only) | Live flake still enables `services.my-k3s` (Docker + nvidia), desktop + xrdp, Caddy/Dispatch, Vault, Gitea, Attic, Ollama, monitoring. High coexistence risk |
| **Spark** | Forbidden | Stays vLLM; no VMs |
| **sam_main / framework13** | Unsuitable | Workstation / laptop; not always-on cloud plane |
| **dad_nas** | Unsuitable | Media NAS role |

**Recommendation (original):** dedicated NixOS host. **Sam override (2026-09-19):** Slice A enabled on **AIServer** anyway — see status banner. Daemon is enabled on AIServer in flake; Sam applies with `nh os switch`. `asus_rog_1070` remains an optional future move-off-host if coexistence hurts.

AIServer remains the **services hub** (Dispatch compose on loopback, Caddy on Tailscale). Incus does not migrate Dispatch into containers in Slice A–B.

### Network model v1

- **Host ingress:** Tailscale (MagicDNS TBD for the new host) — admin and OpenTofu remote over Tailnet only; no public WAN bind of the Incus API
- **Instance fabric:** bridge `incusbr0` with RFC1918 (example `10.0.100.0/24`) + NAT
- **Firewall:** `networking.nftables.enable = true` (required with Incus on NixOS). Trust `incusbr0` **or** allow UDP/TCP 53 and UDP 67 on that interface so DHCP/DNS work ([wiki](https://wiki.nixos.org/wiki/Incus))
- **OVN + ACLs:** Slice C when bridge + host firewall is too coarse (SG-shaped rules)

Tailscale is the human/VPC path to the **host**, not hairpin into every instance in v1.

### State directories

| Path | Role |
|------|------|
| `/var/lib/incus` | Daemon state |
| `/var/lib/incus/storage-pools/default` (dir driver) | v1 pool — simple; ZFS/Btrfs later |
| OpenTofu state | Slice B — local or remote backend under `infra/incus/` (no secrets in git) |

### Backup (v1)

- Snapshot / restic (or Attic later) of `/var/lib/incus` on the Incus host
- `incus export` for critical instances before risky applies
- Do **not** park Incus backups on dad_nas / queennas unless Sam asks
- Preseed **never deletes** resources — treat pool/network renames as additive drift, not cleanup

### Cloud mapping (implement toward)

| Cloud idea | Incus / home equivalent |
|------------|-------------------------|
| Accounts | Projects + quotas |
| VPC | Bridge v1 → OVN later |
| Security groups | ACLs (Slice C) |
| Compute | Instances (container \| VM) |
| Launch templates | Profiles |
| Disks | Pools / volumes |
| LB | Later |
| IaC | OpenTofu |
| Console mutations | Dispatch tools later (approve-gated), via Rust harness — not Python dispatcher |

---

## 2. Slice A — NixOS module / PR plan

**Do not merge an enablement PR without Sam.**

### Proposed module

`modules/services/incus-host.nix` (name flexible), gated `services.my-incus-host.enable` **default false**:

- `virtualisation.incus.enable = true`
- `networking.nftables.enable = true`
- `virtualisation.incus.preseed` — bridge `incusbr0`, dir pool `default`, default profile with eth0 + root disk
- Firewall: `trustedInterfaces` includes `incusbr0` **or** allow 53/67 on that interface
- `users.users.sam.extraGroups = [ "incus-admin" ]` when enabled
- Document: preseed does not remove old networks/pools/profiles

### Host wiring

- Placeholder `hosts/incus_cloud/default.nix` imports the module with `enable = true` (stub hardware until Sam assigns a box)
- **Do not** import/enable on `hosts/AIServer` in Slice A

### Plan B (AIServer) — only if Sam insists

1. Disable / remove `services.my-k3s` first
2. Audit Docker vs Incus bridge + nftables (`system.stateVersion`, flush behavior)
3. Keep Dispatch on `127.0.0.1` + Caddy Tailscale vhost
4. Separate enablement PR with Security review

### Follow-up enablement PR checklist

- [ ] Host choice confirmed by Sam
- [ ] Module + host import only
- [ ] CI flake check green
- [ ] Security glance (nftables, no WAN Incus API)
- [ ] Sam merges + `nh os switch` on that host (agents do not switch)

---

## 3. Slice B — OpenTofu layout

**v1 home:** `infra/incus/` **inside this repo** (one free-tier repo, same PR hygiene as Nix). Split to a private `homelab-incus` repo later if remote state / credentials grow.

```
infra/incus/
  README.md
  versions.tf       # opentofu + lxc/incus provider
  providers.tf      # remote to daemon over Tailscale HTTPS (or local)
  projects.tf       # one project ≈ account
  networks.tf       # optional; prefer Nix preseed for v1 bridge, tofu for extras
  profiles.tf
  instances_test.tf # one throwaway test instance
  acl.tf            # stub → Slice C
```

Notes:

- nixpkgs has **no** declarative instances yet — OpenTofu owns instances; CLI creates are drift
- Provider: [registry.terraform.io/providers/lxc/incus](https://registry.terraform.io/providers/lxc/incus/latest/docs)
- No real secrets in git; use env / Tailscale-only remote
- Do not `tofu apply` from agents without Sam

---

## 4. Slices C / D (brief)

| Slice | What | Gate |
|-------|------|------|
| C | OVN + ACLs when bridge is too small | After A+B stable |
| D | Dispatch `incus_*` tools via Rust harness | Coordinate Software Architect; **after** A+B; no Python virt logic |

---

## 5. Risks

- **AIServer coexistence:** leftover k3s + Docker + desktop vs Incus bridges/nftables — avoid for Slice A
- **Preseed never deletes** — renames leave orphans; clean with explicit `incus` CLI / tofu destroy
- **No declarative instances in nixpkgs** — dual source of truth if someone uses CLI without tofu
- **nftables flush / older `stateVersion` patterns** — can wipe Incus rules; follow current wiki guidance
- **GPU passthrough** — out of Slice A
- **libvirt** — not introduce alongside Incus; Incus is the locked plane

---

## 6. Immediate next actions

1. Sam picks Slice A host: **new dedicated** (preferred) vs **repurpose `asus_rog_1070`**
2. Enablement PR: module + host import only (this plan PR stays docs)
3. After switch: OpenTofu root + one test instance (Slice B)
4. Hold Dispatch Incus tools until A+B exist

Contact: DevOps owns plan + first slices; escalate cost / WAN / destructive to Chief of Staff / Sam.

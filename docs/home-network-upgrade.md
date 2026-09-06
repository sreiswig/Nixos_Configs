# Home network upgrade (apartment)

Shopping / wiring shortlist for the locked apartment LAN. Docs only — no
secrets, SSIDs, or passwords.

Related: [inventory.md](./inventory.md) (topology), [network-self-heal.md](./network-self-heal.md).

## Current bottleneck

Path: Apartment WiFi → **Gl.iNet Beryl** (client / WISP) → **Netgear GS108** → hosts.

Everything behind the switch shares the Beryl’s **WiFi uplink**. The GS108 is
fine; do not replace the switch to “fix WiFi.” Finish wiring and improve the
uplink first.

## Tier A — this week (~$15–40)

- 2× Cat6 patch cables: **Spark** + **Windows** → GS108 (~$10–20)
- Optional: short Cat6 Beryl LAN → switch if the current cable is suspect (~$5–10)
- Skip a new switch / AP until these are done

Servers (AIServer, Spark, OOB KVM) belong on the switch, not as WiFi clients.

## Tier B — stuck on WiFi uplink (~$100–130)

Keep the same shape: one strong WiFi **client** near the apartment AP → ethernet
down to the GS108.

- **GL.iNet Slate AX (GL-AXT1800)** ~$120 — solid travel/bridge option with more
  ports than the pocket Beryl
- Or keep the Beryl after better placement if speedtests look good enough

Do **not** buy consumer mesh “for the lab.”

## Tier C — do-it-once (~$170)

- **GL.iNet Flint 2 (GL-MT6000)** ~$170 — stronger radios, dual 2.5G ports, same
  OpenWrt-ish admin family
- Run it as client/repeater (or WAN-from-WiFi) feeding the GS108
- Keep the Beryl as the travel router

Worth it if this apartment is home for a while and the Beryl radio is the daily pain.

## Only if the building allows

- Working **ethernet wall jack** → use as Beryl/Flint WAN (biggest win, $0 hardware)
- **MoCA 2.5** adapters (~$100–150/pair) if live coax runs between rooms
- Powerline: last resort only (noisy apartments eat it)

## Don’t buy

- New unmanaged switch (GS108 is enough)
- Mesh for servers
- 10 GbE NIC/switch for this apartment (Spark’s 10G still lands at 1G on the GS108)

## Suggested cart

1. Cables now
2. If still slow after placement + wiring: Flint 2 (keep Beryl for trips)
3. MoCA only if coax is real

Prices are ballpark street/list; check current listings before ordering.

## AIServer always-on

`hosts/AIServer/default.nix` already disables suspend/hibernate (logind + systemd
sleep settings) and masks sleep targets. If the live box still sleeps, rebuild on
the host (`nh os switch` / equivalent) — merging this repo does not change the
machine by itself.

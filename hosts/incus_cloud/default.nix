# PLACEHOLDER dedicated Incus host (Slice A).
# Sam must fill before first real deploy:
#   - networking.hostName / Tailscale MagicDNS name
#   - hardware-configuration.nix from nixos-generate-config (replace stub)
#   - uplink NIC (NAT goes out the default route; pin with networking if needed)
#   - dedicated disk path for services.my-incus-host.poolSource (optional; dir on root works for bring-up)
# Do NOT copy this enablement onto AIServer or Spark.
{ config, pkgs, lib, ... }:

{
  imports = [
    ../../modules/common
    ../../modules/services/incus-host.nix
    ./hardware-configuration.nix
  ];

  networking.hostName = "incus-cloud"; # TODO(Sam): final hostname / MagicDNS

  services.my-incus-host = {
    enable = true;
    # bridgeName = "incusbr0";
    # ipv4 = "10.0.100.1/24";
    # poolSource = "/var/lib/incus/storage-pools/default";
  };

  # Always-on cloud plane expectations (adjust when hardware is known).
  services.tailscale.enable = true;

  # No desktop / k3s / Dispatch here — adjacent compute only.
  system.stateVersion = "24.11";
}

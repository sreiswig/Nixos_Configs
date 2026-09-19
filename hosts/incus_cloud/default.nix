# UNUSED TEMPLATE — Sam override 2026-09-19: Incus Slice A runs on AIServer instead.
# Keep this tree as a starting point if Incus later moves to a dedicated box.
# Do NOT add this host to the live fleet without Sam; flake attr may remain for eval.
{ config, pkgs, lib, ... }:

{
  imports = [
    ../../modules/common
    ../../modules/services/incus-host.nix
    ./hardware-configuration.nix
  ];

  networking.hostName = "incus-cloud";

  # Intentionally off while AIServer carries Slice A.
  services.my-incus-host.enable = false;

  services.tailscale.enable = true;
  system.stateVersion = "24.11";
}

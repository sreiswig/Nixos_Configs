{ config, lib, pkgs, ... }:

{
  virtualisation.docker.enable = true;
  virtualisation.docker.enableOnBoot = true;

  # Nvidia Docker
  hardware.nvidia-container-toolkit.enable = true;

  virtualisation.vmVariant = {
    hardware.nvidia-container-toolkit.enable = lib.mkForce false;
  };
}

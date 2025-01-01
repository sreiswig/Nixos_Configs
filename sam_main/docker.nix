{ config, lib, pkgs, ... }:

{
  virtualisation.docker.enable = true;
  virtualisation.docker.enableOnBoot = true;

  # Nvidia Docker
  hardware.nvidia-container-toolkit.enable = true;
  # libnvidia-container does not support cgroups v2 (prior to 1.8.0)
  # https://github.com/NVIDIA/nvidia-docker/issues/1447
}

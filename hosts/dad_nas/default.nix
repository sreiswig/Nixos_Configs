{ config, pkgs, ... }:

{
  imports = [
    ../../modules/common
    ./configuration.nix
    ../../modules/services/opentelemetry.nix
    ../../modules/services/ceph.nix
  ];

  # Disabled until the Cyber-SOC pipeline is actually wired (AI Server + Loki/LLM).
  services.my-opentelemetry.enable = false;
  services.my-opentelemetry.role = "agent";

  services.homelab-ceph = {
    enable = false; # Temporarily disabled due to upstream build error with sphinx/python3.11
    role = "server";
  };
}

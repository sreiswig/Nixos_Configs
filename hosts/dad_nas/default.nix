{ config, pkgs, ... }:

{
  imports = [
    ../../modules/common
    ./configuration.nix
    ../../modules/services/opentelemetry.nix
    ../../modules/services/ceph.nix
  ];

  services.my-opentelemetry.enable = true;
  services.my-opentelemetry.role = "agent";

  services.homelab-ceph = {
    enable = false; # Temporarily disabled due to upstream build error with sphinx/python3.11
    role = "server";
  };
}

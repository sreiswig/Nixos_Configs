{ config, pkgs, ... }:

{
  imports = [
    ./configuration.nix
    ../../modules/services/opentelemetry.nix
    ../../modules/services/ceph.nix
  ];

  services.my-opentelemetry.enable = true;
  services.my-opentelemetry.role = "agent";

  services.homelab-ceph = {
    enable = true;
    role = "server";
  };
}

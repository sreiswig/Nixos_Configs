{ config, pkgs, ... }:

{
  imports = [
    ./configuration.nix
    ../../modules/services/opentelemetry.nix
  ];

  services.my-opentelemetry.enable = true;
  services.my-opentelemetry.role = "agent";
}

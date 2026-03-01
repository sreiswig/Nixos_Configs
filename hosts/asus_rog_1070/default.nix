{ config, pkgs, ... }:

{
  imports = [
    ../../modules/common
    ../../modules/hardware/gpu/nvidia_gpu.nix
    ./configuration.nix
    ./ollama.nix
    ../../modules/services/opentelemetry.nix
  ];

  services.my-opentelemetry.enable = true;
  services.my-opentelemetry.role = "agent";
}

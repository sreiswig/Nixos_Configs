{ config, pkgs, ... }:

{
  imports = [
    ../../modules/common
    ../../modules/hardware/gpu/nvidia_gpu.nix
    ./configuration.nix
    ./ollama.nix
    ../../modules/services/opentelemetry.nix
  ];

  # Disabled until the Cyber-SOC pipeline is actually wired (AI Server + Loki/LLM).
  services.my-opentelemetry.enable = false;
  services.my-opentelemetry.role = "agent";
}

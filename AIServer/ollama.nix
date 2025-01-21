{ config, pkgs, ... }:
{
  services.ollama = {
    enable = true;
    acceleration = "rocm";
    environmentVariables = {
      ENABLE_INTEL_GPU = "true";
    };
  };
}

{ config, pkgs, ... }:
{
  services.ollama = {
    enable = true;
    acceleration = "cuda";
    environmentVariables = {
      HCC_AMDGPU_TARGET = "gfx1030";
      OLLAMA_INTEL_GPU = "true";
    };
    rocmOverrideGfx = "10.3.0";
  };
}

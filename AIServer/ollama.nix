{ config, pkgs, ... }:
{
  services.ollama = {
    enable = true;
    acceleration = "rocm";
    loadModels = [ "phi4" ];
  };
}

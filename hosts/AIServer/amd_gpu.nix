{ config, pkgs, ...}:
{
  services.xserver.videoDrivers = [ "amdgpu" ];
  hardware.graphics.extraPackages = with pkgs; [
    rocmPackages.clr.icd
  ];
}

{ config, pkgs, ...}:
{
  services.xserver.videoDrivers = [ "amdgpu" ];
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  hardware.graphics.extraPackages = with pkgs; [
    rocmPackages.clr.icd
  ];
}

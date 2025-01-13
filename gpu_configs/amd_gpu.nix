{ config, pkgs, ...}:

{
  services.xserver.videoDrivers = [ "amdgpu" ];

  hardware.opengl.extraPackages = with pkgs; [
    rocmPackages.clr.icd
  ];
}

{ config, pkgs, ...}:

{
  services.xserver.videoDrivers = [ "intel" ];

  boot.initrd.kernelModules = [ "i915" ];
  boot.kernelPackages = pkgs.linuxPackages_latest;

}

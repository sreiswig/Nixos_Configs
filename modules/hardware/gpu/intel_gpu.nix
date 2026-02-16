{ config, pkgs, ...}:

{
  boot.initrd.kernelModules = [ "i915" ];
  boot.kernelPackages = pkgs.linuxPackages_latest;
  
  hardware.graphics.extraPackages = with pkgs; [
    intel-compute-runtime
  ];
}

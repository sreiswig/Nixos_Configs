{ config, libs, pkgs, ...}:

{
  environment.systemPackages = with pkgs; [
    nmap
    ghidra
  ];
}

{ config, pkgs, ... }:

{
  home.packages = with pkgs; [
  ];

  programs.home-manager.enable = true;
}

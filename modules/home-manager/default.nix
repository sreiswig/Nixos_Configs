{ config, pkgs, ... }:

{
  home.username = "sam";
  home.homeDirectory = "/home/sam";

  home.stateVersion = "24.11"; # Keeping it compatible with recent stable
  
  programs.home-manager.enable = true;
}
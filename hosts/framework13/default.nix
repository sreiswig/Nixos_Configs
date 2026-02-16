{ config, pkgs, ... }:

{
  imports = [
    # Shared Modules
    ../../modules/common
    ../../modules/desktop

    # Local Configuration
    ./hardware-configuration.nix
  ];

  networking.hostName = "framework13";

  # Specific Services
  services.printing.enable = true;
  services.fprintd.enable = true;
  virtualisation.docker.enable = true;
  environment.sessionVariables.NIXOS_OZONE_WL = "1";

  # User Packages specific to this host
  users.users.sam.extraGroups = [ "docker" ];
  users.users.sam.packages = with pkgs; [
     fprintd
     yazi
     zulip
     cbmc
     tailscale
     kdePackages.konsole
     gh
     gopass
     hugo
     vscode-fhs
     steam
     obsidian
     kdePackages.dolphin
     kdePackages.krohnkite
     lynx
     conda
     catppuccin-sddm
     discord
     kdePackages.qtwayland
     zellij
     zoom-us
  ];
  
  system.stateVersion = "23.11";
}

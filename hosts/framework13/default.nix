{ config, pkgs, ... }:

{
  imports = [
    # Shared Modules
    ../../modules/common
    ../../modules/desktop
    ../../modules/services/opentelemetry.nix

    # Local Configuration
    ./hardware-configuration.nix
  ];

  services.my-opentelemetry.enable = true;
  services.my-opentelemetry.role = "agent";

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
     cbmc
     kdePackages.konsole
     hugo
     remmina
     vscode-fhs
     kdePackages.dolphin
     kdePackages.krohnkite
     lynx
     conda
     catppuccin-sddm
     kdePackages.qtwayland
     zoom-us
  ];
  
  system.stateVersion = "23.11";
}

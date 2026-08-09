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

  # Disabled until the Cyber-SOC pipeline is actually wired (AI Server + Loki/LLM).
  services.my-opentelemetry.enable = false;
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
     grok-build
  ];
  
  system.stateVersion = "23.11";
}

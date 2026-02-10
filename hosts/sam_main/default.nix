{ config, pkgs, ... }:

{
  imports = [
    # Shared Modules
    ../../modules/common
    ../../modules/desktop
    ../../modules/hardware/gpu/nvidia_gpu.nix

    # Local Configuration
    ./hardware-configuration.nix
    ./docker.nix
  ];

  networking.hostName = "sam_nixos";

  # Hyprland
  programs.hyprland.enable = true;
  environment.sessionVariables.NIXOS_OZONE_WL = "1";

  # Specific Services
  services.printing.enable = true;
  services.tailscale.enable = true;
  virtualisation.waydroid.enable = true;

  # Gaming & Entertainment
  programs.steam.enable = true; # Already in desktop, but harmless to re-enable
  
  # User Packages specific to this host
  users.users.sam.packages = with pkgs; [
    blender
    mermaid-cli
    fprintd
    zulip
    hugo
    kitty
    nixfmt-rfc-style
    vscode-fhs
    antigravity-fhs
    minikube
    deja-dup
    xwayland
    kdePackages.kdenlive
    kdePackages.krdc
    kdePackages.krohnkite
    kdePackages.partitionmanager
    kdePackages.ksystemlog
    kdePackages.sddm-kcm
    wayland-utils
    obs-studio
    gimp
    gnupg
    gopass
    vulkan-tools
    impala
    yazi
    zellij
    prismlauncher
    (retroarch.withCores (cores: with cores; [
      vba-m
    ]))
    archipelago
    github-copilot-cli
    gemini-cli
  ];

  # Fonts
  fonts.packages = with pkgs; [
    nerd-fonts.fira-code
    noto-fonts-cjk-sans
    noto-fonts-cjk-serif
  ];

  # Garbage Collection (Override common if needed, but defaults are fine)
  nix.gc = {
    automatic = true;
    randomizedDelaySec = "14m";
    options = "--delete-older-than 10d";
  };
  
  system.stateVersion = "23.11";
}

{ config, pkgs, ... }:

{
  imports = [
    # Shared Modules
    ../../modules/common
    ../../modules/desktop
    ../../modules/hardware/gpu/nvidia_gpu.nix
    ../../modules/hardware/gpu/intel_gpu.nix
    ../../modules/services/opentelemetry.nix

    # Local Configuration
    ./hardware-configuration.nix
    ./docker.nix
  ];

  # Disabled until the Cyber-SOC pipeline is actually wired (AI Server + Loki/LLM).
  # Module kept at modules/services/opentelemetry.nix for later.
  services.my-opentelemetry.enable = false;
  services.my-opentelemetry.role = "agent";

  networking.hostName = "sam_nixos";

  # Hyprland
  programs.hyprland.enable = true;
  environment.sessionVariables = {
    NIXOS_OZONE_WL = "1";
    LIBVA_DRIVER_NAME = "nvidia";
    GBM_BACKEND = "nvidia-drm";
    __GLX_VENDOR_LIBRARY_NAME = "nvidia";
    WLR_NO_HARDWARE_CURSORS = "1"; # Often needed for NVIDIA
  };

  # Specific Services
  services.printing = {
    enable = true;
    drivers = [ pkgs.canon-cups-ufr2 pkgs.cups-filters ];
  };
  services.ipp-usb.enable = true;
  environment.systemPackages = with pkgs; [ ipp-usb cups ];
  services.harmonia.cache.enable = true;
  virtualisation.waydroid.enable = true;

  # QEMU/KVM via libvirt (virt-manager GUI)
  virtualisation.libvirtd.enable = true;
  virtualisation.libvirtd.qemu.swtpm.enable = true;
  virtualisation.spiceUSBRedirection.enable = true;
  programs.virt-manager.enable = true;

  # Gaming & Entertainment
  # programs.steam.enable = true; # Handled by desktop module
  
  # User Packages specific to this host
  users.users.sam.extraGroups = [ "kvm" "libvirtd" ];
  users.users.sam.packages = with pkgs; [
    blender
    mermaid-cli
    fprintd
    hugo
    kitty
    nixfmt
    vscode-fhs
    minikube
    deja-dup
    xwayland
    kdePackages.kdenlive
    vlc
    mpv
    remmina
    kdePackages.krdc
    kdePackages.krohnkite
    kdePackages.partitionmanager
    kdePackages.ksystemlog
    kdePackages.sddm-kcm
    wayland-utils
    obs-studio
    gimp
    gnupg
    vulkan-tools
    impala
    prismlauncher
    qemu
    (retroarch.withCores (cores: with cores; [
      vba-m
    ]))
    archipelago
    github-copilot-cli
    grok-build
    grok-bot
    git-lfs
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
  
  virtualisation.vmVariant = {
    virtualisation.cores = 4;
    virtualisation.memorySize = 8192;
    users.mutableUsers = false;
    users.users.sam.password = "nixos";
  };

  system.stateVersion = "23.11";
}

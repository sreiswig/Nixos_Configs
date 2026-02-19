{ pkgs, lib, ... }:

{
  # Bootloader.
  boot.loader.systemd-boot.enable = lib.mkDefault true;
  boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;

  # Networking
  networking.networkmanager.enable = lib.mkDefault true;

  # Time & Locale
  time.timeZone = "America/Chicago";
  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "en_US.UTF-8";
    LC_IDENTIFICATION = "en_US.UTF-8";
    LC_MEASUREMENT = "en_US.UTF-8";
    LC_MONETARY = "en_US.UTF-8";
    LC_NAME = "en_US.UTF-8";
    LC_NUMERIC = "en_US.UTF-8";
    LC_PAPER = "en_US.UTF-8";
    LC_TELEPHONE = "en_US.UTF-8";
    LC_TIME = "en_US.UTF-8";
  };

  # Sound
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # Nix Settings
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nixpkgs.config.allowUnfree = true;

  # Common Environment
  environment.variables.EDITOR = "lvim";
  environment.variables.VAULT_ADDR = "https://aiserver.tail93ec7d.ts.net/vault";

  # Common Services
  services.tailscale.enable = lib.mkDefault true;
  services.openssh = {
    enable = lib.mkDefault true;
    settings.PasswordAuthentication = lib.mkDefault false;
    settings.PermitRootLogin = lib.mkDefault "no";
  };
  
  environment.systemPackages = with pkgs; [
    git
    lunarvim
    btop
    ripgrep
    wget
    curl
    fastfetch
    zoxide
    eza
    lazygit
    lazydocker
    direnv
    nix-direnv
    nh # Nice to have for flake management
    yazi
    zellij
    vault
    gh
    gemini-cli
  ];

  # Basic User (Sam)
  users.users.sam = {
    isNormalUser = true;
    description = "Sam";
    extraGroups = [ "networkmanager" "wheel" ];
    shell = pkgs.bash; # Default to bash, can be changed
  };
}

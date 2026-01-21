# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, lib, ... }:

{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
      ./docker.nix
      ./ollama.nix
      ./gpu_configs/amd_gpu.nix
      ./gpu_configs/nvidia_gpu.nix
      ./gpu_configs/intel_gpu.nix
    ];

  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.initrd.kernelModules = [ "amdgpu" ];

  networking.hostName = "AI_Server"; # Define your hostname.
  # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.
  # networking.wireless.userControlled.enable = true; # Enables use of wpa_gui and wpa_cli

  # Configure network proxy if necessary
  # networking.proxy.default = "http://user:password@proxy:port/";
  # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

  # Enable networking
  networking.networkmanager.enable = true;

  # Set your time zone.
  time.timeZone = "America/Chicago";

  # Select internationalisation properties.
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

  services.xrdp.enable = true;
  services.xrdp.defaultWindowManager = "startplasma-x11";

  # Enable the X11 windowing system.
  # You can disable this if you're only using the Wayland session.
  services.xserver.enable = true;

  # Enable the KDE Plasma Desktop Environment.
  services.displayManager.sddm.enable = true;
  services.desktopManager.plasma6.enable = true;

  # Configure keymap in X11
  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };

  # Enable CUPS to print documents.
  services.printing.enable = false;

  # Enable sound with pipewire.
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    # If you want to use JACK applications, uncomment this
    #jack.enable = true;

    # use the example session manager (no others are packaged yet so this is enabled by default,
    # no need to redefine it in your config for now)
    #media-session.enable = true;
  };

  # Caddy
  services.caddy = {
    enable = true;
    virtualHosts = {
      "aiserver.tail93ec7d.ts.net" = {
        extraConfig = ''
          # Proxy for n8n
          reverse_proxy 127.0.0.1:5678

          # Proxy for Gitea
          handle_path /git* {
            reverse_proxy 127.0.0.1:3001
          }

          # Proxy for Ollama
          handle_path /ollama* {
            reverse_proxy 127.0.0.1:11434
          }
        '';
      };
      "queennas.tail93ec7d.ts.net" = {
        extraConfig = "reverse_proxy 100.74.70.2:8096";
      };
      "immich.tail93ec7d.ts.net" = {
        extraConfig = "reverse_proxy 100.74.70.2:1112";
      };
    };
  };

  # Enable n8n
  services.n8n = {
    enable = true;
  };

  # Overlay to override n8n with the version from nixos-unstable
  nixpkgs.overlays = [
    (final: prev: {
      n8n = (import (builtins.fetchTarball {
        url = "https://github.com/nixos/nixpkgs/archive/80e4adbcf8992d3fd27ad4964fbb84907f9478b0.tar.gz";
        # TODO: Run 'sudo nixos-rebuild switch', it will fail with "got: sha256-..."
        # Copy that hash and replace the zeros below.
        sha256 = "0hx09ar14njl4vgarsy79vlykwswg7rbxak7c7qm1n8r0szy6r0b";
      }) { inherit (final) system; }).n8n;
    })
  ];

  systemd.services.n8n.environment = {
    N8N_PROTOCOL = "https";
    N8N_HOST = "aiserver.tail93ec7d.ts.net";
    N8N_SECURE_COOKIE = "true";
    # mkForce is required because the n8n module defines an internal default for this
    WEBHOOK_URL = lib.mkForce "https://aiserver.tail93ec7d.ts.net";
  };

  # Enable tailscale
  services.tailscale.enable = true;
  services.tailscale.permitCertUid = "caddy";

  services.gitea = {
    enable = true;
    appName = "AIServer Code Hub";
    database.type = "sqlite3";

    settings.server = {
      DOMAIN = "aiserver.tail93ec7d.ts.net";
      ROOT_URL = "https://aiserver.tail93ec7d.ts.net/git/";
      HTTP_ADDR = "127.0.0.1";
      HTTP_PORT = 3001;
    };

    settings.service.DISABLE_REGISTRATION = true;
  };

  # Enable touchpad support (enabled default in most desktopManager).
  # services.xserver.libinput.enable = true;

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.sam = {
    isNormalUser = true;
    description = "Sam";
    extraGroups = [ "networkmanager" "wheel" ];
    packages = with pkgs; [
      kdePackages.kate
    ];
  };

  # Enable flakes
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    git
    gnome-disk-utility
    google-chrome
    lunarvim
    devenv
    direnv
    nix-direnv
    lazygit
    lazydocker
    btop
    fastfetch
    zoxide
#    clinfo
#    amdgpu_top
  ];

  environment.variables.EDITOR = "lvim";

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  # List services that you want to enable:

  # Enable the OpenSSH daemon.
  services.openssh = {
    enable = true;
    openFirewall = false;
    settings = {
      PasswordAuthentication = true;
      AllowUsers = null;
      UseDns = false;
      X11Forwarding = false;
      PermitRootLogin = "prohibit-password";
    };
  };

  # Open ports in the firewall.
  networking.firewall.interfaces."enp37s0f1np1".allowedTCPPorts = [ 3389 22 8000 ];
  networking.firewall.trustedInterfaces = [ "tailscale0" ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "24.11"; # Did you read the comment?

}

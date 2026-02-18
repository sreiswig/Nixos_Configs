{ config, pkgs, lib, ... }:

{
  imports = [
    # Shared Modules
    ../../modules/common
    ../../modules/desktop
    
    # GPU Modules
    ../../modules/hardware/gpu/amd_gpu.nix
    ../../modules/hardware/gpu/nvidia_gpu.nix
    ../../modules/hardware/gpu/intel_gpu.nix
    ../../modules/services/opentelemetry.nix

    # Local Configuration
    ./hardware-configuration.nix
    # ./ollama.nix # Commented out in original
  ];

  services.my-opentelemetry.enable = true;
  services.my-opentelemetry.role = "server";

  networking.hostName = "AI_Server";
  boot.initrd.kernelModules = [ "amdgpu" ];

  # XRDP & Headless-ish Setup
  services.xrdp.enable = true;
  services.xrdp.defaultWindowManager = "startplasma-x11";
  
  # Services from original configuration.nix
  services.caddy = {
    enable = true;
    virtualHosts = {
      "aiserver.tail93ec7d.ts.net" = {
        extraConfig = ''
          handle_path /git* { reverse_proxy 127.0.0.1:3001 }
          handle_path /ollama* { reverse_proxy 127.0.0.1:11434 }
          handle_path /vault* { reverse_proxy 127.0.0.1:8200 }
          handle /ui* { reverse_proxy 127.0.0.1:8200 }
          handle { reverse_proxy 127.0.0.1:5678 }
        '';
      };
      # Duplicate entry in original, merging logical intention?
      # The original had: "aiserver.tail93ec7d.ts.net" = { extraConfig = "reverse_proxy 127.0.0.1:7474"; };
      # This conflicts with the above block for the same domain. Caddy doesn't support duplicate keys in Nix usually?
      # I'll comment this one out as it looks like a copy-paste error or override that might break the first one.
      # "aiserver.tail93ec7d.ts.net" = { extraConfig = "reverse_proxy 127.0.0.1:7474"; };
      
      "queennas.tail93ec7d.ts.net" = { extraConfig = "reverse_proxy 100.74.70.2:8096"; };
      "immich.tail93ec7d.ts.net" = { extraConfig = "reverse_proxy 100.74.70.2:1112"; };
    };
  };

  services.vault = {
    enable = true;
    package = pkgs.vault-bin;
    address = "127.0.0.1:8200";
    storageBackend = "file";
    storagePath = "/var/lib/vault";
    extraConfig = ''
      ui = true
      api_addr = "https://aiserver.tail93ec7d.ts.net/vault"
    '';
  };
  environment.variables.VAULT_ADDR = "https://aiserver.tail93ec7d.ts.net/vault";

  services.n8n.enable = true;
  
  # n8n Overlay/Override
  nixpkgs.overlays = [
    (final: prev: {
      n8n = (import (builtins.fetchTarball {
        url = "https://github.com/nixos/nixpkgs/archive/80e4adbcf8992d3fd27ad4964fbb84907f9478b0.tar.gz";
        sha256 = "0hx09ar14njl4vgarsy79vlykwswg7rbxak7c7qm1n8r0szy6r0b";
      }) {
        inherit (final) system;
        config.allowUnfree = true;
      }).n8n;
    })
  ];

  systemd.services.n8n.environment = {
    N8N_PROTOCOL = "https";
    N8N_HOST = "aiserver.tail93ec7d.ts.net";
    N8N_SECURE_COOKIE = "true";
    WEBHOOK_URL = lib.mkForce "https://aiserver.tail93ec7d.ts.net";
  };

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

  services.neo4j = {
    enable = true;
    package = pkgs.neo4j;
    http.listenAddress = "127.0.0.1:7474";
    bolt.listenAddress = "0.0.0.0:7687";
    extraServerConfig = ''
      server.memory.heap.initial_size=4G
      server.memory.heap.max_size=8G
      server.memory.pagecache.size=2G
      dbms.connector.bolt.listen_address=0.0.0.0:7687
    '';
  };

  services.openssh = {
    enable = true;
    openFirewall = false;
    settings = {
      PasswordAuthentication = true;
      UseDns = false;
      X11Forwarding = false;
      PermitRootLogin = "prohibit-password";
    };
  };

  networking.firewall.interfaces."enp37s0f1np1".allowedTCPPorts = [ 3389 22 8000 ];
  networking.firewall.trustedInterfaces = [ "tailscale0" ];

  users.users.sam.packages = with pkgs; [
    gnome-disk-utility
    devenv
    direnv
    nix-direnv
    vault
  ];

  system.stateVersion = "24.11";
}
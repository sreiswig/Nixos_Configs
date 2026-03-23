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
    ../../modules/services/monitoring.nix
    ../../modules/services/kubernetes.nix
    ../../modules/services/authentik.nix

    # Local Configuration
    ./hardware-configuration.nix
    ./ollama.nix
    ./docker.nix
  ];

  services.my-opentelemetry.enable = true;
  services.my-opentelemetry.role = "server";

  services.my-monitoring = {
    enable = true;
    grafanaEnvFile = "/var/lib/grafana/grafana.env";
  };
  
  services.my-authentik = {
    enable = true;
    environmentFile = "/var/lib/authentik/authentik.env";
  };

  services.my-k3s = {
    enable = true;
    role = "server";
    useDocker = true; # Using Docker for easier GPU access via nvidia-container-toolkit
    disableTraefik = true; # Let Caddy handle routing
    nvidiaSupport = true;
  };

  networking.hostName = "AI_Server";
  boot.initrd.kernelModules = [ "amdgpu" ];

  # XRDP & Headless-ish Setup
  services.xrdp.enable = true;
  services.xrdp.defaultWindowManager = "startplasma-x11";
  
  # Services from original configuration.nix
  services.caddy = {
    enable = true;
    virtualHosts = {
      "auth.tail93ec7d.ts.net" = {
        extraConfig = ''
          reverse_proxy 127.0.0.1:9000
          reverse_proxy /outpost.goauthentik.io/* 127.0.0.1:9000
        '';
      };
      "aiserver.tail93ec7d.ts.net" = {
        extraConfig = ''
          # Proxy for Gitea
          handle_path /git* {
            reverse_proxy 127.0.0.1:3001
          }

          # Proxy for Ollama
          handle_path /ollama* {
            reverse_proxy 127.0.0.1:11434
          }

          # Proxy for Grafana
          handle_path /grafana* {
            reverse_proxy 127.0.0.1:3000
          }

          # Proxy for Vault
          handle_path /vault* {
            reverse_proxy 127.0.0.1:8200
          }

          # Vault static assets
          handle /ui* {
            reverse_proxy 127.0.0.1:8200
          }

          # Proxy for Attic
          handle_path /attic* {
            reverse_proxy 127.0.0.1:8080
          }

          # Proxy for n8n (Default catch-all)
          handle {
            reverse_proxy 127.0.0.1:5678
          }
        '';
      };
      "aiserver.tail93ec7d.ts.net:8474" = {
        extraConfig = "reverse_proxy 127.0.0.1:7474";
      };
      "aiserver.tail93ec7d.ts.net:7687" = {
        extraConfig = "reverse_proxy 127.0.0.1:7688";
      };
      "queennas.tail93ec7d.ts.net" = {
        extraConfig = "reverse_proxy 100.74.70.2:8096";
      };
      "immich.tail93ec7d.ts.net" = {
        extraConfig = "reverse_proxy 100.74.70.2:1112";
      };
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

  services.n8n = {
    enable = true;
    environment = {
      N8N_PROTOCOL = "https";
      N8N_HOST = "aiserver.tail93ec7d.ts.net";
      N8N_SECURE_COOKIE = "true";
      WEBHOOK_URL = lib.mkForce "https://aiserver.tail93ec7d.ts.net";
      N8N_RUNNERS_AUTH_TOKEN_FILE = "/var/lib/n8n/auth-token";
    };
  };
  
  # n8n Overlay/Override

  services.tailscale.permitCertUid = "caddy";

  # SSH Overrides for AI Server
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = true;
      PermitRootLogin = "prohibit-password";
      UseDns = false;
      X11Forwarding = false;
    };
  };

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
    https.enable = false;

    bolt = {
      listenAddress = "127.0.0.1:7688";
      advertisedAddress = "aiserver.tail93ec7d.ts.net:7687";
      tlsLevel = "DISABLED";
    };

    extraServerConfig = ''
      server.memory.heap.initial_size=4G
      server.memory.heap.max_size=8G
      server.memory.pagecache.size=2G
    '';
  };

  # Attic Server
  services.atticd = {
    enable = true;

    # You will need to create this file with ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64
    environmentFile = "/var/lib/atticd/atticd.env";

    # Basic settings
    settings = {
      listen = "[::]:8080";
      database.url = "postgresql:///atticd?host=/run/postgresql";
      
      # Storage settings (local filesystem by default)
      storage = {
        type = "local";
        path = "/var/lib/atticd/storage";
      };

      chunking = {
        # The minimum NAR size (in bytes) that will be chunked
        nar-size-threshold = 64 * 1024; # 64 KiB
        # The preferred chunk size (in bytes)
        min-size = 16 * 1024; # 16 KiB
        avg-size = 64 * 1024; # 64 KiB
        max-size = 256 * 1024; # 256 KiB
      };
    };
  };

  # PostgreSQL for Attic
  services.postgresql = {
    enable = true;
    ensureDatabases = [ "atticd" ];
    ensureUsers = [{
      name = "atticd";
      ensureDBOwnership = true;
    }];
  };

  networking.firewall.interfaces."enp37s0f1np1".allowedTCPPorts = [ 3389 22 8000 ];
  networking.firewall.trustedInterfaces = [ "tailscale0" ];

  users.users.sam.packages = with pkgs; [
    gnome-disk-utility
    devenv
    google-chrome
    kdePackages.kate
  ];

  system.stateVersion = "24.11";
}
{ config, pkgs, lib, ... }:
let
  wifiInterface = "wlp38s0";
in {

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
    ../../modules/services/ai-dispatch-caddy.nix
    ../../modules/services/network-self-heal.nix
    # ../../modules/services/authentik.nix

    # Local Configuration
    ./hardware-configuration.nix
    ./ollama.nix
    ./docker.nix
  ];

  # Disabled until the Cyber-SOC pipeline is actually wired (collectors → Loki/LLM).
  # Module kept at modules/services/opentelemetry.nix for later.
  services.my-opentelemetry.enable = false;
  services.my-opentelemetry.role = "server";

  services.my-monitoring = {
    enable = true;
    grafanaEnvFile = "/var/lib/grafana/grafana.env";
  };

  # Every 2min: reconnect WiFi if unassociated, `tailscale up` if offline.
  # wifiInterface from nixos-generate-config; script auto-detects if the name is gone.
  # Ethernet (enp37s0f1np1) is still preferred; OOB KVM for total radio/NIC death.
  # pingMode defaults to "soft": ICMP fail is WARN-only while Tailscale is online.
  services.my-network-self-heal = {
    enable = true;
    inherit wifiInterface;
    requireTailscale = true;
    escalateToReboot = true;
    # defaults: ping 1.1.1.1 soft; escalate NM@2 → tailscaled@4 → reboot@8 (1h cooldown)
  };

  # Always-on: WiFi + Tailscale at boot, no sleep, SSH on the tailnet.
  # WiFi SSID/PSK stay in NetworkManager system connections (not this flake).
  networking.networkmanager.wifi = {
    powersave = false;
    scanRandMacAddress = false;
    macAddress = "preserve";
  };
  networking.networkmanager.connectionConfig."connection.autoconnect-retries" = 0;
  networking.networkmanager.dispatcherScripts = [
    {
      type = "basic";
      source = pkgs.writeShellScript "tailscale-up-on-nm" ''
        case "$2" in
          up|connectivity-change)
            ${lib.getExe pkgs.tailscale} up >/dev/null 2>&1 || true
            ;;
        esac
      '';
    }
  ];

  systemd.sleep.settings.Sleep = {
    AllowSuspend = "no";
    AllowHibernation = "no";
    AllowHybridSleep = "no";
    AllowSuspendThenHibernate = "no";
  };
  services.logind.settings.Login = {
    HandleLidSwitch = "ignore";
    HandleLidSwitchExternalPower = "ignore";
    HandleLidSwitchDocked = "ignore";
    HandleSuspendKey = "ignore";
    HandleHibernateKey = "ignore";
    IdleAction = "ignore";
  };
  # Belt-and-suspenders: even if Plasma/PowerDevil requests sleep, targets stay off.
  # Live effect needs `nh os switch` (or equivalent) on AIServer — merge alone is not enough.
  systemd.targets.sleep.enable = false;
  systemd.targets.suspend.enable = false;
  systemd.targets.hibernate.enable = false;
  systemd.targets.hybrid-sleep.enable = false;

  systemd.services.wifi-autoconnect = {
    description = "Enable WiFi radio and connect saved NetworkManager profiles";
    after = [ "NetworkManager.service" ];
    wants = [ "NetworkManager.service" ];
    wantedBy = [ "multi-user.target" ];
    path = with pkgs; [ networkmanager coreutils iproute2 iw gnugrep ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      TimeoutStartSec = "60s";
    };
    script = ''
      set -u
      nmcli radio wifi on || true
      nmcli networking on || true

      i=0
      while [ "$i" -lt 10 ]; do
        if nmcli -t -f DEVICE,TYPE device status 2>/dev/null | grep -q ':wifi$'; then
          break
        fi
        i=$((i + 1))
        sleep 1
      done

      nmcli -t -f UUID,TYPE connection show 2>/dev/null | while IFS=: read -r uuid typ; do
        [ "$typ" = "802-11-wireless" ] || continue
        [ -n "$uuid" ] || continue
        nmcli connection modify "$uuid" connection.autoconnect yes || true
        nmcli connection modify "$uuid" connection.permissions "" || true
      done

      iface="${wifiInterface}"
      if [ -n "$iface" ] && ip link show "$iface" >/dev/null 2>&1; then
        iw dev "$iface" set power_save off 2>/dev/null || true
        state="$(nmcli -t -f GENERAL.STATE device show "$iface" 2>/dev/null | head -n1 || true)"
        case "$state" in
          *":100 (connected)"*) exit 0 ;;
        esac
        timeout 25 nmcli device connect "$iface" || true
      fi
    '';
  };

  systemd.services.tailscale-up = {
    description = "Bring Tailscale online using the existing node login";
    after = [ "tailscaled.service" "wifi-autoconnect.service" "NetworkManager.service" ];
    requires = [ "tailscaled.service" ];
    wants = [ "wifi-autoconnect.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.tailscale pkgs.coreutils ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      TimeoutStartSec = "90s";
    };
    script = ''
      set -u
      i=0
      while [ "$i" -lt 5 ]; do
        if timeout 10 tailscale up; then
          exit 0
        fi
        i=$((i + 1))
        sleep 2
      done
      echo "tailscale up failed after retries (not logged in, or no uplink yet)" >&2
      exit 1
    '';
  };

  services.tailscale.openFirewall = true;

  # services.my-authentik = {
  #   enable = true;
  #   environmentFile = "/var/lib/authentik/authentik.env";
  # };

  services.my-k3s = {
    enable = true;
    role = "server";
    useDocker = true; # Using Docker for easier GPU access via nvidia-container-toolkit
    disableTraefik = true; # Let Caddy handle routing
    nvidiaSupport = true;
  };

  networking.hostName = "AI_Server";
  boot.initrd.kernelModules = [ "amdgpu" ];

  # XRDP for Remmina (Plasma X11 session; separate from any local SDDM login).
  services.xrdp = {
    enable = true;
    openFirewall = true;
    defaultWindowManager = "startplasma-x11";
  };

  # Services from original configuration.nix
  services.caddy = {
    enable = true;
    virtualHosts = {
      # "auth.tail93ec7d.ts.net" = {
      #   extraConfig = ''
      #     reverse_proxy 127.0.0.1:9000
      #     reverse_proxy /outpost.goauthentik.io/* 127.0.0.1:9000
      #   '';
      # };
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

          # No catch-all (n8n removed). Unmatched paths get Caddy's default response.
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

  services.tailscale.permitCertUid = "caddy";

  # SSH on all interfaces (firewall opens 22). tailscale0 is trusted below,
  # so MagicDNS / Tailscale IP SSH works once tailscale-up has succeeded.
  # Keys only: PasswordAuthentication=false matches modules/common (mkDefault).
  # Do not re-enable password SSH on a LAN-adjacent always-on box.
  services.openssh = {
    enable = true;
    startWhenNeeded = false;
    openFirewall = true;
    settings = {
      PasswordAuthentication = false;
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

  # 22/3389 are opened globally by OpenSSH/xrdp.openFirewall.
  # Dispatch API stays on 127.0.0.1:8000; reach it via Caddy on the Tailnet
  # (https://dispatch.tail93ec7d.ts.net/api) — do not open :8000 on LAN ethernet.
  # trustedInterfaces: tailscale0 is the trusted path until Dispatch has real auth.
  networking.firewall.trustedInterfaces = [ "tailscale0" ];

  users.users.sam.packages = with pkgs; [
    gnome-disk-utility
    devenv
    google-chrome
    kdePackages.kate
    grok-build
    git-lfs
  ];

  system.stateVersion = "24.11";
}

{ config, pkgs, ... }:

{
  imports = [
    ./neovim.nix
    ./plasma.nix
  ];

  home.username = "sam";
  home.homeDirectory = "/home/sam";

  home.stateVersion = "24.11"; # Keeping it compatible with recent stable

  # Remmina → AI Server over Tailscale MagicDNS (xrdp :3389, self-signed TLS).
  xdg.dataFile."remmina/group_rdp_ai-server_aiserver-tail93ec7d-ts-net.remmina".text = ''
    [remmina]
    protocol=RDP
    name=AI Server
    group=Homelab
    server=aiserver.tail93ec7d.ts.net
    username=sam
    ignore-tls-errors=1
    cert_ignore=1
    security=tls
    colordepth=32
    quality=9
    resolution_mode=2
    window_maximize=1
    sound=off
    disableclipboard=0
    network=lan
    preferipv6=0
    gateway_usage=0
    disablepasswordstoring=0
  '';

  # OpenCode configuration
  programs.opencode = {
    enable = true;
    settings = {
      # Configure Ollama as a custom provider
      provider = {
        ollama = {
          npm = "@ai-sdk/openai-compatible";
          options = {
            baseURL = "http://localhost:11434/v1";
          };
          models = {
            # Add Ollama models you want to use
            "llama3.2" = { };
            "codellama" = { };
            "mistral" = { };
          };
        };
      };
    };
  };

  # For Ollama, no API key is typically needed, but if you need to set environment variables:
  # home.sessionVariables = {
  #   OPENCODE_API_KEY = "ollama"; # or whatever your setup requires
  # };

  programs.starship = {
    enable = true;
    enableBashIntegration = true;
  };

  programs.zoxide = {
    enable = true;
    enableBashIntegration = true;
  };

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
    enableBashIntegration = true;
  };

  programs.bash = {
    enable = true;
    shellAliases = {
      sl = "ls";
    };
    initExtra = ''
      case $(( RANDOM % 4 )) in
        0)
          echo -e "\033[48;5;18;97m* * * * * * * *\033[0m \033[31m==============================\033[0m"
          echo -e "\033[48;5;18;97m * * * * * * * \033[0m \033[97m==============================\033[0m"
          echo -e "\033[48;5;18;97m* * * * * * * *\033[0m \033[31m==============================\033[0m"
          echo -e "\033[48;5;18;97m * * * * * * * \033[0m \033[97m==============================\033[0m"
          echo -e "\033[48;5;18;97m* * * * * * * *\033[0m \033[31m==============================\033[0m"
          echo -e "\033[48;5;18;97m * * * * * * * \033[0m \033[97m==============================\033[0m"
          echo -e "\033[48;5;18;97m* * * * * * * *\033[0m \033[31m==============================\033[0m"
          echo -e "\033[97m==============================================\033[0m"
          echo -e "\033[31m==============================================\033[0m"
          echo -e "\033[97m==============================================\033[0m"
          echo -e "\033[31m==============================================\033[0m"
          echo -e "\033[97m==============================================\033[0m"
          echo -e "\033[31m==============================================\033[0m"
          echo -e "\n                \033[1;97mSam's Homelab\033[0m"
          ;;
        1)
          echo -e "\033[1;33m            _________\033[0m"
          echo -e "\033[1;33m           (_________)\033[0m"
          echo -e "                            \033[1;35mzZz\033[0m"
          echo -e "\033[1;35m            _________\033[0m"
          echo -e "\033[1;35m         .-'         '-.\033[0m"
          echo -e "\033[1;35m      _ /               \\ _\033[0m"
          echo -e "\033[1;35m     ( /   -         -   \\ )\033[0m"
          echo -e "\033[1;35m      /        _n_        \\\ \033[0m"
          echo -e "\033[1;35m     |                     |\033[0m"
          echo -e "\033[1;35m      \\                   /\033[0m"
          echo -e "\033[1;35m       '._             _.'\033[0m"
          echo -e "\033[1;35m         \\_/ \\_/ \\_/ \\_/\033[0m"
          echo -e "\n              \033[1;35mWAH!\033[0m"
          ;;
        2)
          echo -e "\033[1;37m         /\\_/\\          \033[0m"
          echo -e "\033[1;37m        ( o.o )         \033[0m"
          echo -e "\033[1;33m         > ^ <          \033[0m"
          echo -e "\n        \033[1;37mmeow\033[0m"
          ;;
        3)
          echo -e "\033[1;35m          _.._\033[0m"
          echo -e "\033[1;35m        .'    \`.\033[0m"
          echo -e "\033[1;35m       /   __   \\\033[0m"
          echo -e "\033[1;35m    ,  |  (  )  |  ,\033[0m"
          echo -e "\033[1;35m    \\'. \\  --  / .'/ \033[0m"
          echo -e "\033[1;35m     '._\`------'_.'\033[0m"
          echo -e "\033[1;35m        \`------'\033[0m"
          echo -e "\n \033[1;37m\"Never perfect, perfection goal that changes, never stops moving, can chase, cannot catch.\"\033[0m"
          ;;
      esac
    '';
  };

  programs.home-manager.enable = true;
}

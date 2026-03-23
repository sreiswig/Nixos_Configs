{ config, pkgs, lib, ... }:

let
  cfg = config.services.my-authentik;
in
{
  options.services.my-authentik = {
    enable = lib.mkEnableOption "Authentik Identity Provider";
    
    domain = lib.mkOption {
      type = lib.types.str;
      default = "auth.tail93ec7d.ts.net";
      description = "Domain for Authentik";
    };

    environmentFile = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/authentik/authentik.env";
      description = "Path to environment file containing AUTHENTIK_SECRET_KEY, AUTHENTIK_POSTGRESQL__PASSWORD, etc.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.authentik = {
      enable = true;
      environmentFile = cfg.environmentFile;
      settings = {
        email = {
          host = "smtp.example.com";
          port = 587;
          username = "authentik@example.com";
          use_tls = true;
          from = "authentik@example.com";
        };
        disable_startup_analytics = true;
        avatars = "gravatar";
      };
      nginx.enable = false; # We use Caddy
      nginx.enablePxh = false;
    };

    services.redis.servers.authentik = {
      enable = true;
      port = 6379;
    };

    services.postgresql = {
      enable = true;
      ensureDatabases = [ "authentik" ];
      ensureUsers = [{
        name = "authentik";
        ensureDBOwnership = true;
      }];
    };

    # Open firewall for Caddy to talk to Authentik (if needed locally)
    # Authentik listens on localhost:9000 by default in the NixOS module
  };
}

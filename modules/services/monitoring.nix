{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.my-monitoring;
in
{
  options.services.my-monitoring = {
    enable = mkEnableOption "Central Monitoring Stack (Prometheus + Grafana)";
    
    grafanaDomain = mkOption {
      type = types.str;
      default = "aiserver.tail93ec7d.ts.net";
      description = "Domain for Grafana";
    };
  };

  config = mkIf cfg.enable {
    services.prometheus = {
      enable = true;
      port = 9090;
      scrapeConfigs = [
        {
          job_name = "otel-collector";
          static_configs = [{
            targets = [ "127.0.0.1:8889" ];
          }];
        }
      ];
    };

    services.loki = {
      enable = true;
      configFile = pkgs.writeText "loki.yaml" (builtins.toJSON {
        auth_enabled = false;
        server = {
          http_listen_port = 3100;
        };
        common = {
          ring = {
            instance_addr = "127.0.0.1";
            kvstore.store = "inmemory";
          };
          replication_factor = 1;
          path_prefix = "/var/lib/loki";
          storage.filesystem = {
            chunks_directory = "/var/lib/loki/chunks";
            rules_directory = "/var/lib/loki/rules";
          };
        };
        schema_config.configs = [{
          from = "2020-10-24";
          store = "tsdb";
          object_store = "filesystem";
          schema = "v13";
          index = {
            prefix = "index_";
            period = "24h";
          };
        }];
        limits_config = {
          allow_structured_metadata = true;
          reject_old_samples = true;
          reject_old_samples_max_age = "168h";
        };
      });
    };

    services.grafana = {
      enable = true;
      settings = {
        server = {
          http_addr = "127.0.0.1";
          http_port = 3000;
          domain = cfg.grafanaDomain;
          root_url = "https://${cfg.grafanaDomain}/grafana/";
          serve_from_sub_path = true;
        };
      };
      provision = {
        enable = true;
        datasources.settings.datasources = [
          {
            name = "Prometheus";
            type = "prometheus";
            url = "http://127.0.0.1:9090";
            isDefault = true;
          }
          {
            name = "Loki";
            type = "loki";
            url = "http://127.0.0.1:3100";
          }
        ];
      };
    };
  };
}

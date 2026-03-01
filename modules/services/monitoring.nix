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
        ];
      };
    };
  };
}

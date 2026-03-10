{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.my-opentelemetry;
in
{
  options.services.my-opentelemetry = {
    enable = mkEnableOption "OpenTelemetry Collector";

    role = mkOption {
      type = types.enum [ "agent" "server" ];
      default = "agent";
      description = "Role of the collector: 'agent' (send to server) or 'server' (receive from agents).";
    };

    serverAddress = mkOption {
      type = types.str;
      default = "aiserver.tail93ec7d.ts.net";
      description = "Address of the central OpenTelemetry server (for agents).";
    };
  };

  config = mkIf cfg.enable {
    services.opentelemetry-collector = {
      enable = true;
      settings = if cfg.role == "agent" then {
        receivers = {
          otlp.protocols = {
            grpc.endpoint = "127.0.0.1:4317";
            http.endpoint = "127.0.0.1:4318";
          };
          hostmetrics = {
            collection_interval = "30s";
            scrapers = {
              cpu = {};
              memory = {};
              disk = {};
              filesystem = {};
              network = {};
            };
          };
          journald = {
            operators = [{
              type = "add";
              field = "attributes.host";
              value = config.networking.hostName;
            }];
          };
        };
        processors = {
          batch = {};
        };
        exporters = {
          otlp = {
            endpoint = "http://${cfg.serverAddress}:4317";
            tls.insecure = true;
          };
        };
        service = {
          pipelines = {
            metrics = {
              receivers = [ "otlp" "hostmetrics" ];
              processors = [ "batch" ];
              exporters = [ "otlp" ];
            };
            traces = {
              receivers = [ "otlp" ];
              processors = [ "batch" ];
              exporters = [ "otlp" ];
            };
            logs = {
              receivers = [ "otlp" "journald" ];
              processors = [ "batch" ];
              exporters = [ "otlp" ];
            };
          };
        };
      } else { # role == "server"
        receivers = {
          otlp.protocols = {
            grpc.endpoint = "0.0.0.0:4317";
            http.endpoint = "0.0.0.0:4318";
          };
        };
        processors = {
          batch = {};
        };
        exporters = {
          debug = {
            verbosity = "detailed";
          };
          prometheus = {
            endpoint = "127.0.0.1:8889";
          };
          loki = {
            endpoint = "http://127.0.0.1:3100/loki/api/v1/push";
          };
        };
        service = {
          pipelines = {
            metrics = {
              receivers = [ "otlp" ];
              processors = [ "batch" ];
              exporters = [ "debug" "prometheus" ];
            };
            traces = {
              receivers = [ "otlp" ];
              processors = [ "batch" ];
              exporters = [ "debug" ];
            };
            logs = {
              receivers = [ "otlp" ];
              processors = [ "batch" ];
              exporters = [ "debug" "loki" ];
            };
          };
        };
      };
    };

    # Open firewall ports if server
    networking.firewall.allowedTCPPorts = mkIf (cfg.role == "server") [ 4317 4318 ];
  };
}

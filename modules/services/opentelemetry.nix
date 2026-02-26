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
              receivers = [ "otlp" ];
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
          # Here we could add prometheus, loki, tempo, etc.
        };
        service = {
          pipelines = {
            metrics = {
              receivers = [ "otlp" ];
              processors = [ "batch" ];
              exporters = [ "debug" ];
            };
            traces = {
              receivers = [ "otlp" ];
              processors = [ "batch" ];
              exporters = [ "debug" ];
            };
            logs = {
              receivers = [ "otlp" ];
              processors = [ "batch" ];
              exporters = [ "debug" ];
            };
          };
        };
      };
    };

    # Open firewall ports if server
    networking.firewall.allowedTCPPorts = mkIf (cfg.role == "server") [ 4317 4318 ];
  };
}

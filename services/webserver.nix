{ config, pkgs, ... }: {
  options.services.nginx = {
    enable = mkEnableOption "Enable the Nginx web server";
    port = mkOption {
      type = types.int;
      default = 80;
      description = "Port to listen on";
    };
    package = mkOption {
      type = types.package;
      default = pkgs.nginx;
      description = "Nginx package to use";
    };
    extraConfig = mkOption {
      type = types.lines;
      default = "";
      description = "Extra configuration to add to the Nginx configuration file";
    };
  };

  config = mkIf config.services.nginx.enable {
    services.nginx = {
      enable = true;
      package = config.services.nginx.package;
      listenAddress = "*"; # Listen on all interfaces
      listenPort = config.services.nginx.port;
      virtualHosts."example.com" = {
        root = "/var/www/example.com";
        extraConfig = config.services.nginx.extraConfig;
      };
    };
  };
}

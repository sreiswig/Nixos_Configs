# Incus personal-cloud daemon (Slice A).
# Default off. Enable only on the dedicated host (hosts/incus_cloud) — never AIServer / Spark.
# Preseed creates/updates entities but does NOT delete (nixpkgs / Incus behavior).
{ config, lib, pkgs, ... }:

let
  cfg = config.services.my-incus-host;
  bridge = cfg.bridgeName;
in
{
  options.services.my-incus-host = {
    enable = lib.mkEnableOption "Incus host daemon (personal-cloud compute plane)";

    bridgeName = lib.mkOption {
      type = lib.types.str;
      default = "incusbr0";
      description = "Incus managed bridge for instance fabric (v1; OVN later).";
    };

    ipv4 = lib.mkOption {
      type = lib.types.str;
      default = "10.0.100.1/24";
      description = "Bridge IPv4 CIDR (RFC1918). Instances get DHCP from Incus dnsmasq.";
    };

    poolSource = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/incus/storage-pools/default";
      description = ''
        Directory storage pool path (dir driver). Replace with a dedicated disk
        mount path once Sam assigns hardware — keep the same pool name "default"
        or update OpenTofu accordingly.
      '';
    };

    defaultRootSize = lib.mkOption {
      type = lib.types.str;
      default = "35GiB";
      description = "Default profile root disk size.";
    };

    adminUser = lib.mkOption {
      type = lib.types.str;
      default = "sam";
      description = "Local user added to incus-admin when the module is enabled.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Required companion to Incus on NixOS (iptables path is unsupported).
    networking.nftables.enable = true;

    # DHCP/DNS from the Incus bridge must not be blocked by the host firewall.
    networking.firewall.trustedInterfaces = lib.mkAfter [ bridge ];

    virtualisation.incus = {
      enable = true;
      preseed = {
        networks = [
          {
            name = bridge;
            type = "bridge";
            config = {
              "ipv4.address" = cfg.ipv4;
              "ipv4.nat" = "true";
            };
          }
        ];
        storage_pools = [
          {
            name = "default";
            driver = "dir";
            config = {
              source = cfg.poolSource;
            };
          }
        ];
        profiles = [
          {
            name = "default";
            devices = {
              eth0 = {
                name = "eth0";
                network = bridge;
                type = "nic";
              };
              root = {
                path = "/";
                pool = "default";
                size = cfg.defaultRootSize;
                type = "disk";
              };
            };
          }
        ];
      };
    };

    users.users.${cfg.adminUser} = {
      extraGroups = [ "incus-admin" ];
    };

    # Keep the Incus API on the host; reach admin over Tailscale only (no WAN bind here).
    environment.systemPackages = [ pkgs.incus ];
  };
}

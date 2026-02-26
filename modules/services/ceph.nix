{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.homelab-ceph;
in
{
  options.services.homelab-ceph = {
    enable = mkEnableOption "Homelab CephFS Setup";

    role = mkOption {
      type = types.enum [ "server" "client" ];
      default = "client";
      description = "Role of this node: server (Mon/Mgr/MDS/OSD) or client";
    };

    osdIds = mkOption {
      type = types.listOf types.int;
      default = [];
      description = "List of OSD IDs to enable on this host";
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = with pkgs; [ ceph ] ++ lib.optional (cfg.role == "server") (pkgs.writeScriptBin "setup-ceph-osd-loopback" ''
        #!/bin/sh
        if [ "$EUID" -ne 0 ]; then
          echo "Please run as root"
          exit 1
        fi
        echo "Setting up a 10G loopback OSD at /var/lib/ceph/osd.img..."
        if [ -f /var/lib/ceph/osd.img ]; then
          echo "Error: /var/lib/ceph/osd.img already exists."
          exit 1
        fi
        mkdir -p /var/lib/ceph
        truncate -s 10G /var/lib/ceph/osd.img
        LOOPDEV=$(losetup --show -f /var/lib/ceph/osd.img)
        echo "Loop device created at $LOOPDEV"
        # We need to ensure the loop device persists or is recreated on boot, 
        # but for a quick setup this works for the current session.
        # For persistence, one should add it to hardware-configuration.nix or similar.
        
        echo "Running ceph-volume..."
        ceph-volume lvm create --data $LOOPDEV
      '');

    # Firewall ports for Ceph
    networking.firewall.allowedTCPPorts = mkIf (cfg.role == "server") [
      3300  # Ceph Mon (v2)
      6789  # Ceph Mon (v1)
      6800 6801 6802 6803 # OSD/MDS range
    ];

    services.ceph = mkIf (cfg.role == "server") {
      enable = true;
      global = {
        fsid = "a7f64266-0894-4f1e-a635-d0aeaca0e993"; # Generated static UUID
        monInitialMembers = "queennas";
        monHost = "100.74.70.2"; # Tailscale IP of dad_nas (queennas)
        
        # Network configuration - assuming Tailscale (100.x.x.x)
        clusterNetwork = "100.64.0.0/10";
        publicNetwork = "100.64.0.0/10";
      };

      mon = {
        enable = true;
        daemons = [ "queennas" ]; 
      };

      mgr = {
        enable = true;
        daemons = [ "queennas" ];
      };

      mds = {
        enable = true;
        daemons = [ "queennas" ];
        extraConfig = {
          "mds_cache_memory_limit" = "2G";
        };
      };
      
      # OSD Configuration
      # NOTE: This assumes manual OSD provisioning or user configuration.
      # For a homelab with no spare disks, one might use a loopback device.
      # Instructions: 
      # 1. Create a 10G file: fallocate -l 10G /var/lib/ceph/osd.img
      # 2. Setup loop device: losetup /dev/loop0 /var/lib/ceph/osd.img
      # 3. Zap and create OSD: ceph-volume lvm create --data /dev/loop0
      osd = {
        enable = cfg.osdIds != [];
        daemons = cfg.osdIds; 
      };
    };

    # Client Configuration
    environment.etc."ceph/ceph.conf".text = mkIf (cfg.role == "client") ''
      [global]
      fsid = a7f64266-0894-4f1e-a635-d0aeaca0e993
      mon_initial_members = queennas
      mon_host = 100.74.70.2
    '';

    # Mount helper for client
    systemd.mounts = mkIf (cfg.role == "client") [{
      what = "queennas:6789:/";
      where = "/mnt/cephfs";
      type = "ceph";
      options = "name=admin,secretfile=/etc/ceph/admin.secret,noatime,_netdev";
      # Note: The secret file needs to be manually placed at /etc/ceph/admin.secret 
      # after retrieving it from the server: ceph auth get-key client.admin
    }];

    systemd.automounts = mkIf (cfg.role == "client") [{
      wantedBy = [ "multi-user.target" ];
      automountConfig = {
        TimeoutIdleSec = "600";
      };
      where = "/mnt/cephfs";
    }];
  };
}

# Conservative uplink / Tailscale self-heal watchdog.
# The check itself is scripts/spark/network-self-heal.sh (also installed on Spark).
# Each tick: reconnect WiFi if unassociated, `tailscale up` if offline.
# Link loss restarts NetworkManager and, when it is enabled or active,
# systemd-networkd, then tailscaled. Escalates to a cooldown-gated reboot
# after a sustained Tailscale outage (~16 minutes at the default cadence).
# Does NOT help if the machine is powered off or hard-locked; keep OOB KVM.
{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.my-network-self-heal;
  stateDir = "/var/lib/network-self-heal";
  tsIf = config.services.tailscale.interfaceName;

  # Map simple duration strings (30m, 1h, 3600) onto seconds for the script.
  rebootCooldownSec =
    let
      raw = cfg.rebootCooldown;
    in
      if builtins.match "[0-9]+h" raw != null then
        (toInt (removeSuffix "h" raw)) * 3600
      else if builtins.match "[0-9]+m" raw != null then
        (toInt (removeSuffix "m" raw)) * 60
      else if builtins.match "[0-9]+s" raw != null then
        toInt (removeSuffix "s" raw)
      else if builtins.match "[0-9]+" raw != null then
        toInt raw
      else
        throw "services.my-network-self-heal.rebootCooldown: unsupported value '${raw}' (use e.g. 1h, 30m, 3600)";

  checkScript = pkgs.writeShellApplication {
    name = "network-self-heal-check";
    runtimeInputs = with pkgs; [
      coreutils
      iproute2
      iputils
      jq
      systemd
      iw
      tailscale
      gnugrep
      gawk
      networkmanager
    ];
    text = concatStringsSep "\n" [
      ''
        export STATE_DIR=${escapeShellArg stateDir}
        export PING_TARGET=${escapeShellArg cfg.pingTarget}
        export PING_MODE=${escapeShellArg cfg.pingMode}
        export REQUIRE_TS=${if cfg.requireTailscale then "1" else "0"}
        export WIFI_IFACE=${escapeShellArg (if cfg.wifiInterface != null then cfg.wifiInterface else "")}
        export DISABLE_PS=${if cfg.disableWifiPowersave then "1" else "0"}
        export ESCALATE_REBOOT=${if cfg.escalateToReboot then "1" else "0"}
        export TH_NET=${toString cfg.failuresBeforeNetworkRestart}
        export TH_TS=${toString cfg.failuresBeforeTailscaleRestart}
        export TH_REBOOT=${toString cfg.failuresBeforeReboot}
        export COOLDOWN_SEC=${toString rebootCooldownSec}
        export LAN_GATEWAY=${escapeShellArg (if cfg.lanGateway != null then cfg.lanGateway else "")}
      ''
      (builtins.readFile ../../scripts/spark/network-self-heal.sh)
    ];
  };
in
{
  options.services.my-network-self-heal = {
    enable = mkEnableOption "uplink/Tailscale self-heal watchdog";

    checkInterval = mkOption {
      type = types.str;
      default = "2min";
      description = ''
        systemd timer OnUnitActiveSec interval between checks.
        With the default failuresBeforeReboot of 9 this is about 16 minutes
        from the first failed check to a reboot (8 gaps × 2min).
      '';
    };

    onBootSec = mkOption {
      type = types.str;
      default = "30s";
      description = ''
        systemd timer OnBootSec delay before the first post-boot check.
        The check unit is also wantedBy multi-user.target so it runs as soon
        as NetworkManager/tailscaled are up; this timer is a second pass.
      '';
    };

    pingTarget = mkOption {
      type = types.str;
      default = "1.1.1.1";
      description = ''
        ICMP target for the WAN probe. Defaults to Cloudflare DNS (1.1.1.1).
        The LAN gateway is probed separately (see lanGateway). See pingMode
        for whether a failed probe increments the hard-failure ladder.
      '';
    };

    pingMode = mkOption {
      type = types.enum [ "soft" "hard" "off" ];
      default = "soft";
      description = ''
        How ICMP to pingTarget affects the hard-failure ladder:
        - "soft" (default): if Tailscale is online (Self.Online / IPv4), ping
          failure is journal-warned only and does not escalate. When Tailscale
          is offline, ping failure counts as a hard failure. Safe default for
          apartment WiFi that blocks ICMP while Tailscale still works.
        - "hard": ping failure always increments the failure counter.
        - "off": skip the WAN ping probe entirely.
        A failed LAN-gateway probe is also warn-only while Tailscale is online.
      '';
    };

    lanGateway = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "192.168.8.1";
      description = ''
        LAN gateway to probe. null detects the lowest-metric default-route
        via address, ignoring a Tailscale CGNAT next hop (100.64.0.0/10).
        Unreachable gateway is a hard failure only when Tailscale is offline.
      '';
    };

    requireTailscale = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Require Tailscale Self.Online (or a non-empty tailscale IPv4). When
        Tailscale is down, run `tailscale up` each check (uses the existing
        node login; does not pass an auth key). BackendState NeedsLogin or
        NeedsMachineAuth does not count toward reboot.
      '';
    };

    wifiInterface = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "wlan0";
      description = ''
        Optional WiFi interface name. When null/empty or the named iface is
        missing, the check auto-detects via nmcli / `iw dev`. Unassociated
        WiFi is reconnected each tick from saved NetworkManager profiles
        (no SSID/password in this flake).
      '';
    };

    disableWifiPowersave = mkOption {
      type = types.bool;
      default = true;
      description = "When a WiFi iface is known, run `iw set power_save off` each check.";
    };

    escalateToReboot = mkOption {
      type = types.bool;
      default = true;
      description = "Allow a controlled reboot after failuresBeforeReboot (subject to cooldown).";
    };

    failuresBeforeNetworkRestart = mkOption {
      type = types.ints.positive;
      default = 2;
      description = ''
        Consecutive failed checks before restarting NetworkManager and, if
        enabled or active, systemd-networkd. Link loss restarts them once
        immediately as well.
      '';
    };

    failuresBeforeTailscaleRestart = mkOption {
      type = types.ints.positive;
      default = 4;
      description = "Consecutive failed checks before `systemctl restart tailscaled` (also once on link loss).";
    };

    failuresBeforeReboot = mkOption {
      type = types.ints.positive;
      default = 9;
      description = ''
        Consecutive failed checks before a controlled reboot (if escalateToReboot).
        At checkInterval "2min" this is about 16 minutes after the first failure,
        inside a 15–20 minute sustained Tailscale outage. Timer AccuracySec is 15s
        so batching does not stretch the window much past 20 minutes.
      '';
    };

    rebootCooldown = mkOption {
      type = types.str;
      default = "1h";
      description = ''
        Minimum time between automatic reboots (human-readable: 30m, 1h, 2h).
        Persisted under ${stateDir}/last_reboot to avoid reboot loops.
      '';
    };

    hardwareWatchdog = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Set systemd.settings.Manager.RuntimeWatchdogSec. systemd-system.conf(5)
        says these settings have no effect when no hardware watchdog is
        available, so this does not change boot on machines without one.
        Does not load a watchdog kernel module (a guessed module can reset
        the box in a loop).
      '';
    };

    watchdogRuntimeTime = mkOption {
      type = types.str;
      default = "60s";
      example = "60s";
      description = ''
        RuntimeWatchdogSec when hardwareWatchdog is true. PID 1 pings the
        device at half this interval. RebootWatchdogSec is left at the
        systemd default (10min) so a heavy shutdown is not cut short.
      '';
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      assertions = [
        {
          assertion = cfg.failuresBeforeNetworkRestart
            < cfg.failuresBeforeTailscaleRestart
            && cfg.failuresBeforeTailscaleRestart
            < cfg.failuresBeforeReboot;
          message = "my-network-self-heal: expect failuresBeforeNetworkRestart < failuresBeforeTailscaleRestart < failuresBeforeReboot";
        }
        {
          assertion = config.services.tailscale.enable;
          message = "services.my-network-self-heal requires services.tailscale.enable so tailscaled is installed and wanted by multi-user.target (starts at boot).";
        }
      ];

      # tailscaled.service is wantedBy multi-user.target in the NixOS module
      # when this is true, so it starts at boot without a logged-in user.
      services.tailscale.enable = mkDefault true;
      services.tailscale.openFirewall = mkDefault true;

      # sshd listens (not socket-activated) and stays allowed on the tailnet.
      # xrdp is host-specific; AIServer already enables it. TCP 3389 is opened
      # on the Tailscale interface below so RDP stays reachable there.
      services.openssh.enable = mkDefault true;
      services.openssh.startWhenNeeded = mkDefault false;
      services.openssh.openFirewall = mkDefault true;

      systemd.services.network-self-heal = {
        description = "Link/gateway/Tailscale network self-heal check";
        after = [ "network-pre.target" "NetworkManager.service" "systemd-networkd.service" "tailscaled.service" ];
        wants = [ "network-pre.target" "NetworkManager.service" "tailscaled.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = getExe checkScript;
          # State for failure counters + reboot cooldown (/var/lib/network-self-heal).
          StateDirectory = "network-self-heal";
          # Link-loss restarts, tailscale up, and pings. Reboot is last-resort.
          TimeoutStartSec = "120s";
        };
      };

      systemd.timers.network-self-heal = {
        description = "Periodic link/gateway/Tailscale network self-heal watchdog";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = cfg.onBootSec;
          OnUnitActiveSec = cfg.checkInterval;
          AccuracySec = "15s";
          Persistent = true;
          Unit = "network-self-heal.service";
        };
      };
    }
    (mkIf cfg.hardwareWatchdog {
      systemd.settings.Manager.RuntimeWatchdogSec = cfg.watchdogRuntimeTime;
    })
    (mkIf (tsIf != "userspace-networking") {
      networking.firewall.interfaces.${tsIf}.allowedTCPPorts = [ 22 3389 ];
    })
  ]);
}

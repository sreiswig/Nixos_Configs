# Conservative WiFi / default-route / Tailscale self-heal watchdog.
# Escalates: NetworkManager (or iface bounce) → tailscaled → optional reboot.
# Does NOT help if the machine is powered off or hard-locked; keep OOB KVM.
{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.my-network-self-heal;
  stateDir = "/var/lib/network-self-heal";

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
    ];
    text = ''
      set -euo pipefail

      STATE_DIR="${stateDir}"
      mkdir -p "$STATE_DIR"

      PING_TARGET="${cfg.pingTarget}"
      REQUIRE_TS="${if cfg.requireTailscale then "1" else "0"}"
      WIFI_IFACE="${if cfg.wifiInterface != null then cfg.wifiInterface else ""}"
      DISABLE_PS="${if cfg.disableWifiPowersave then "1" else "0"}"
      ESCALATE_REBOOT="${if cfg.escalateToReboot then "1" else "0"}"
      TH_NET="${toString cfg.failuresBeforeNetworkRestart}"
      TH_TS="${toString cfg.failuresBeforeTailscaleRestart}"
      TH_REBOOT="${toString cfg.failuresBeforeReboot}"
      COOLDOWN_SEC="${toString rebootCooldownSec}"

      FAILURES_FILE="$STATE_DIR/failures"
      LAST_REBOOT_FILE="$STATE_DIR/last_reboot"

      log() {
        echo "network-self-heal: $*"
      }

      read_failures() {
        if [[ -f "$FAILURES_FILE" ]]; then
          cat "$FAILURES_FILE"
        else
          echo 0
        fi
      }

      write_failures() {
        echo "$1" > "$FAILURES_FILE"
      }

      # Optional: keep WiFi out of powersave (common flaky-AP cause).
      if [[ -n "$WIFI_IFACE" && "$DISABLE_PS" == "1" ]]; then
        if iw dev "$WIFI_IFACE" info >/dev/null 2>&1; then
          iw dev "$WIFI_IFACE" set power_save off 2>/dev/null || true
        fi
      fi

      check_default_route() {
        ip -4 route show default | grep -q .
      }

      check_ping() {
        # One short probe; timer interval provides persistence.
        ping -c 1 -W 3 "$PING_TARGET" >/dev/null 2>&1
      }

      check_tailscale() {
        if [[ "$REQUIRE_TS" != "1" ]]; then
          return 0
        fi
        # Prefer JSON Self.Online; fall back to non-empty IPv4.
        if command -v tailscale >/dev/null 2>&1; then
          if tailscale status --json 2>/dev/null | jq -e '.Self.Online == true' >/dev/null 2>&1; then
            return 0
          fi
          if [[ -n "$(tailscale ip -4 2>/dev/null || true)" ]]; then
            return 0
          fi
          return 1
        fi
        log "tailscale binary missing but requireTailscale=true"
        return 1
      }

      healthy=1
      if ! check_default_route; then
        log "FAIL: no default IPv4 route"
        healthy=0
      elif ! check_ping; then
        log "FAIL: ping $PING_TARGET"
        healthy=0
      elif ! check_tailscale; then
        log "FAIL: Tailscale not online / no IPv4"
        healthy=0
      fi

      if [[ "$healthy" == "1" ]]; then
        prev="$(read_failures)"
        if [[ "$prev" != "0" ]]; then
          log "OK: uplink+tailscale healthy; resetting failure counter (was $prev)"
        else
          log "OK: uplink+tailscale healthy"
        fi
        write_failures 0
        exit 0
      fi

      failures=$(( $(read_failures) + 1 ))
      write_failures "$failures"
      log "consecutive failures=$failures (net@$TH_NET ts@$TH_TS reboot@$TH_REBOOT)"

      restart_network() {
        if systemctl list-unit-files NetworkManager.service >/dev/null 2>&1 \
          && systemctl cat NetworkManager.service >/dev/null 2>&1; then
          log "escalation: restarting NetworkManager"
          systemctl restart NetworkManager.service || true
        elif [[ -n "$WIFI_IFACE" ]]; then
          log "escalation: bouncing iface $WIFI_IFACE"
          ip link set "$WIFI_IFACE" down || true
          sleep 2
          ip link set "$WIFI_IFACE" up || true
        else
          log "escalation: no NetworkManager and no wifiInterface; skipping L2/L3 bounce"
        fi
      }

      restart_tailscale() {
        log "escalation: restarting tailscaled"
        systemctl restart tailscaled.service || true
      }

      maybe_reboot() {
        if [[ "$ESCALATE_REBOOT" != "1" ]]; then
          log "escalation: reboot disabled (escalateToReboot=false)"
          return 0
        fi
        now="$(date +%s)"
        last=0
        if [[ -f "$LAST_REBOOT_FILE" ]]; then
          last="$(cat "$LAST_REBOOT_FILE" || echo 0)"
        fi
        elapsed=$(( now - last ))
        if [[ "$last" != "0" && "$elapsed" -lt "$COOLDOWN_SEC" ]]; then
          log "escalation: reboot suppressed (cooldown ''${COOLDOWN_SEC}s, elapsed ''${elapsed}s)"
          return 0
        fi
        log "escalation: controlled reboot (cooldown gate passed); physical OOB/KVM still recommended"
        echo "$now" > "$LAST_REBOOT_FILE"
        # Give journal a moment to flush.
        sync || true
        systemctl reboot || reboot
      }

      # Stepwise ladder. Soft rungs fire once at their threshold; reboot
      # retries on later ticks so a cooldown suppress can succeed later.
      if [[ "$failures" -eq "$TH_NET" ]]; then
        restart_network
      elif [[ "$failures" -eq "$TH_TS" ]]; then
        restart_tailscale
      elif [[ "$failures" -ge "$TH_REBOOT" ]]; then
        maybe_reboot
      else
        log "no escalation action at this failure count"
      fi
    '';
  };
in
{
  options.services.my-network-self-heal = {
    enable = mkEnableOption "WiFi/default-route/Tailscale self-heal watchdog";

    checkInterval = mkOption {
      type = types.str;
      default = "2min";
      description = ''
        systemd timer OnUnitActiveSec interval between checks.
        Also used as a human-readable cadence (default ~2 minutes).
      '';
    };

    pingTarget = mkOption {
      type = types.str;
      default = "1.1.1.1";
      description = ''
        ICMP target for uplink checks. Defaults to Cloudflare DNS (1.1.1.1)
        rather than the LAN gateway so we detect true WAN/uplink loss, not
        merely a missing local router advertisement.
      '';
    };

    requireTailscale = mkOption {
      type = types.bool;
      default = true;
      description = "Also require Tailscale Self.Online (or a non-empty tailscale IPv4).";
    };

    wifiInterface = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "wlan0";
      description = ''
        Optional WiFi interface name. When null/empty, WiFi-specific actions
        (powersave off, iface bounce) are skipped; NetworkManager restart and
        Tailscale/reboot escalation still apply.
      '';
    };

    disableWifiPowersave = mkOption {
      type = types.bool;
      default = true;
      description = "When wifiInterface is set, run `iw set power_save off` each check.";
    };

    escalateToReboot = mkOption {
      type = types.bool;
      default = true;
      description = "Allow a controlled reboot after failuresBeforeReboot (subject to cooldown).";
    };

    failuresBeforeNetworkRestart = mkOption {
      type = types.ints.positive;
      default = 2;
      description = "Consecutive failed checks before restarting NetworkManager (or bouncing wifiInterface).";
    };

    failuresBeforeTailscaleRestart = mkOption {
      type = types.ints.positive;
      default = 4;
      description = "Consecutive failed checks before `systemctl restart tailscaled`.";
    };

    failuresBeforeReboot = mkOption {
      type = types.ints.positive;
      default = 8;
      description = "Consecutive failed checks before a controlled reboot (if escalateToReboot).";
    };

    rebootCooldown = mkOption {
      type = types.str;
      default = "1h";
      description = ''
        Minimum time between automatic reboots (human-readable: 30m, 1h, 2h).
        Persisted under ${stateDir}/last_reboot to avoid reboot loops.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.failuresBeforeNetworkRestart
          < cfg.failuresBeforeTailscaleRestart
          && cfg.failuresBeforeTailscaleRestart
          < cfg.failuresBeforeReboot;
        message = "my-network-self-heal: expect failuresBeforeNetworkRestart < failuresBeforeTailscaleRestart < failuresBeforeReboot";
      }
    ];

    systemd.services.network-self-heal = {
      description = "WiFi/Tailscale network self-heal check";
      after = [ "network-pre.target" "NetworkManager.service" "tailscaled.service" ];
      wants = [ "network-pre.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = getExe checkScript;
        # State for failure counters + reboot cooldown (/var/lib/network-self-heal).
        StateDirectory = "network-self-heal";
        # Root needed for NM/iface/tailscaled/reboot.
      };
    };

    systemd.timers.network-self-heal = {
      description = "Periodic WiFi/Tailscale network self-heal watchdog";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "3min";
        OnUnitActiveSec = cfg.checkInterval;
        AccuracySec = "30s";
        Persistent = true;
        Unit = "network-self-heal.service";
      };
    };
  };
}

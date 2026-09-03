# Conservative WiFi / default-route / Tailscale self-heal watchdog.
# Each tick: reconnect WiFi if unassociated, `tailscale up` if offline.
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
      networkmanager
    ];
    text = ''
      set -euo pipefail

      STATE_DIR="${stateDir}"
      mkdir -p "$STATE_DIR"

      PING_TARGET="${cfg.pingTarget}"
      PING_MODE="${cfg.pingMode}"
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

      iface_exists() {
        local iface="$1"
        [[ -n "$iface" ]] && ip link show "$iface" >/dev/null 2>&1
      }

      detect_wifi_iface() {
        local dev typ rest
        if command -v nmcli >/dev/null 2>&1; then
          while IFS=: read -r dev typ rest; do
            if [[ "$typ" == "wifi" && -n "$dev" ]]; then
              echo "$dev"
              return 0
            fi
          done < <(nmcli -t -f DEVICE,TYPE device status 2>/dev/null || true)
        fi
        local a b
        while read -r a b; do
          if [[ "$a" == "Interface" && -n "$b" ]]; then
            echo "$b"
            return 0
          fi
        done < <(iw dev 2>/dev/null || true)
        return 1
      }

      resolve_wifi_iface() {
        if [[ -n "$WIFI_IFACE" ]]; then
          if iface_exists "$WIFI_IFACE"; then
            return 0
          fi
          log "configured wifiInterface=$WIFI_IFACE not present; auto-detecting"
          WIFI_IFACE=""
        fi
        local detected
        detected="$(detect_wifi_iface || true)"
        if [[ -n "$detected" ]]; then
          WIFI_IFACE="$detected"
          log "auto-detected wifi iface $WIFI_IFACE"
        fi
      }

      wifi_associated() {
        local iface="$1"
        local st
        [[ -z "$iface" ]] && return 1
        if command -v nmcli >/dev/null 2>&1; then
          st="$(nmcli -t -f GENERAL.STATE device show "$iface" 2>/dev/null | head -n1 || true)"
          if [[ "$st" == *":100 (connected)"* ]]; then
            return 0
          fi
        fi
        if command -v iw >/dev/null 2>&1 \
          && iw dev "$iface" link 2>/dev/null | grep -q "Connected to"; then
          return 0
        fi
        return 1
      }

      reconnect_wifi() {
        local iface="$1"
        local name typ
        log "attempt: WiFi reconnect ($iface)"

        if command -v nmcli >/dev/null 2>&1; then
          nmcli radio wifi on >/dev/null 2>&1 || true
          nmcli networking on >/dev/null 2>&1 || true

          if [[ -n "$iface" ]]; then
            if timeout 20 nmcli device connect "$iface" >/dev/null 2>&1; then
              log "nmcli device connect $iface succeeded"
              return 0
            fi
            log "nmcli device connect $iface failed; trying saved WiFi connections"
          fi

          while IFS=: read -r name typ; do
            [[ -z "$name" ]] && continue
            if [[ "$typ" != "802-11-wireless" ]]; then
              continue
            fi
            log "attempt: nmcli connection up $name"
            if timeout 20 nmcli connection up "$name" >/dev/null 2>&1; then
              log "nmcli connection up $name succeeded"
              return 0
            fi
          done < <(nmcli -t -f NAME,TYPE connection show 2>/dev/null || true)

          log "WiFi reconnect via NetworkManager failed"
          return 1
        fi

        if [[ -n "$iface" ]]; then
          log "attempt: bounce iface $iface (no nmcli)"
          ip link set "$iface" down || true
          sleep 2
          ip link set "$iface" up || true
          return 0
        fi

        log "no NetworkManager and no wifi iface; cannot reconnect WiFi"
        return 1
      }

      bring_up_tailscale() {
        log "attempt: tailscale up"
        if timeout 25 tailscale up; then
          log "tailscale up succeeded"
          return 0
        fi
        log "tailscale up failed (not logged in, or daemon not ready)"
        return 1
      }

      # Optional: keep WiFi out of powersave (common flaky-AP cause).
      disable_wifi_powersave() {
        if [[ -n "$WIFI_IFACE" && "$DISABLE_PS" == "1" ]]; then
          if iw dev "$WIFI_IFACE" info >/dev/null 2>&1; then
            iw dev "$WIFI_IFACE" set power_save off 2>/dev/null || true
          fi
        fi
      }

      check_default_route() {
        ip -4 route show default | grep -q .
      }

      check_ping() {
        # One short probe; timer interval provides persistence.
        ping -c 1 -W 3 "$PING_TARGET" >/dev/null 2>&1
      }

      # Actual Tailscale online probe (ignores requireTailscale).
      tailscale_online() {
        if command -v tailscale >/dev/null 2>&1; then
          if tailscale status --json 2>/dev/null | jq -e '.Self.Online == true' >/dev/null 2>&1; then
            return 0
          fi
          if [[ -n "$(tailscale ip -4 2>/dev/null || true)" ]]; then
            return 0
          fi
          return 1
        fi
        return 1
      }

      check_tailscale() {
        if [[ "$REQUIRE_TS" != "1" ]]; then
          return 0
        fi
        if tailscale_online; then
          return 0
        fi
        if ! command -v tailscale >/dev/null 2>&1; then
          log "tailscale binary missing but requireTailscale=true"
        fi
        return 1
      }

      resolve_wifi_iface
      disable_wifi_powersave

      # Light heal first: associate WiFi and bring Tailscale up before counting
      # a hard failure. Uses saved NM connections / existing tailscale login;
      # no SSIDs, passwords, or auth keys in this flake.
      if [[ -n "$WIFI_IFACE" ]] && ! wifi_associated "$WIFI_IFACE"; then
        log "WiFi not associated on $WIFI_IFACE"
        reconnect_wifi "$WIFI_IFACE" || true
        sleep 3
        disable_wifi_powersave
      fi

      if [[ "$REQUIRE_TS" == "1" ]] && ! tailscale_online; then
        bring_up_tailscale || true
        sleep 2
      fi

      # Hard failures drive the escalation ladder. Soft ping (default) only
      # warns when Tailscale proves connectivity and a default route exists —
      # apartment WiFi often blocks ICMP to 1.1.1.1 while TS still works.
      hard=0
      route_ok=1
      if ! check_default_route; then
        log "FAIL: no default IPv4 route"
        route_ok=0
        hard=1
      fi

      ts_ok=1
      if ! check_tailscale; then
        log "FAIL: Tailscale not online / no IPv4"
        ts_ok=0
        hard=1
      fi

      if [[ "$PING_MODE" == "off" ]]; then
        : # skip ICMP probe
      elif ! check_ping; then
        if [[ "$PING_MODE" == "soft" && "$REQUIRE_TS" == "1" && "$route_ok" == "1" ]] \
          && tailscale_online; then
          log "WARN: soft ping fail to $PING_TARGET (Tailscale online + default route OK; not escalating)"
        else
          log "FAIL: ping $PING_TARGET"
          hard=1
        fi
      fi

      if [[ "$hard" == "0" ]]; then
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
          sleep 3
          if [[ -n "$WIFI_IFACE" ]]; then
            reconnect_wifi "$WIFI_IFACE" || true
          fi
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
        sleep 2
        bring_up_tailscale || true
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
        merely a missing local router advertisement. See pingMode for whether
        a failed probe increments the hard-failure ladder.
      '';
    };

    pingMode = mkOption {
      type = types.enum [ "soft" "hard" "off" ];
      default = "soft";
      description = ''
        How ICMP to pingTarget affects the hard-failure ladder:
        - "soft" (default): if Tailscale is online (Self.Online / IPv4) and a
          default route exists, ping failure is journal-warned only and does
          not escalate. When Tailscale is down or requireTailscale=false, ping
          failure still counts as a hard failure (useful WAN probe when TS
          cannot prove connectivity). Safe default for apartment WiFi that
          blocks ICMP while Tailscale still works.
        - "hard": ping failure always increments the failure counter.
        - "off": skip the ping probe entirely.
      '';
    };

    requireTailscale = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Require Tailscale Self.Online (or a non-empty tailscale IPv4). When
        Tailscale is down, run `tailscale up` each check (uses the existing
        node login; does not pass an auth key).
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
        # Light reconnects + NM/tailscaled restarts need time; reboot is last-resort.
        TimeoutStartSec = "90s";
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

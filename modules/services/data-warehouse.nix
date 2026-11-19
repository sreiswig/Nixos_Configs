# Personal warehouse on AIServer.
# Parquet under dataDir/raw, dbt-duckdb builds warehouse.duckdb, restic is off
# until Sam sets a repository. Nothing listens. Query with SSH over Tailscale
# and `duckdb -readonly`.
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.dataWarehouse;

  # See the overlay in flake.nix: Python 3.13 plus dbt-duckdb 1.11.1
  # against this nixpkgs' dbt-core and duckdb.
  warehousePython = pkgs.warehouse-python;

  stateDirectory =
    if hasPrefix "/var/lib/" cfg.dataDir
    then removePrefix "/var/lib/" cfg.dataDir
    else null;

  dbtProject = lib.cleanSourceWith {
    src = ../../warehouse/dbt;
    filter = path: _type:
      let
        blocked = [ "target" "logs" "dbt_packages" ".user.yml" ];
      in
      !lib.any (part: elem part blocked) (lib.splitString "/" path);
  };

  profilesFile = pkgs.writeText "warehouse-profiles.yml" ''
    warehouse:
      target: prod
      outputs:
        prod:
          type: duckdb
          path: ${cfg.dataDir}/warehouse.duckdb
          threads: 1
          schema: main
          settings:
            TimeZone: UTC
  '';

  hardened = {
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    NoNewPrivileges = true;
    CapabilityBoundingSet = [ "" ];
    SystemCallFilter = [ "@system-service" ];
    UMask = "0027";
    TimeoutStartSec = "30min";
    ReadWritePaths = [ cfg.dataDir ];
    PrivateDevices = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectKernelLogs = true;
    ProtectControlGroups = true;
    ProtectClock = true;
    ProtectHostname = true;
    ProtectProc = "invisible";
    RestrictNamespaces = true;
    RestrictSUIDSGID = true;
    LockPersonality = true;
    RestrictRealtime = true;
    SystemCallArchitectures = "native";
  };

  # Local readers and the dbt unit. A loader sets network = true to opt in.
  offlineNet = {
    PrivateNetwork = true;
    RestrictAddressFamilies = [ "AF_UNIX" ];
  };

  onlineNet = {
    RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
  };

  # ExecCondition: 1-254 skips the unit and leaves it inactive.
  # 255 marks the unit failed. Use 1 when there is nothing to build.
  dbtHasRawParquet = pkgs.writeShellScript "warehouse-dbt-has-parquet" ''
    set -eu
    raw="${cfg.dataDir}/raw"
    if [ ! -d "$raw" ]; then
      echo "warehouse-dbt: $raw is missing; skipping"
      exit 1
    fi
    if ! ${pkgs.findutils}/bin/find "$raw" -type f -name '*.parquet' -print -quit \
      | ${pkgs.gnugrep}/bin/grep -q .; then
      echo "warehouse-dbt: no parquet under raw/; skipping build"
      exit 1
    fi
  '';

  # Exit 1 skips. Exit 255 would mark the unit failed.
  # Placeholder means: missing, empty, whitespace-only, any quoted value,
  # or the whole token PLACEHOLDER or TODO in any case.
  resticRepoReady = pkgs.writeShellScript "warehouse-restic-ready" ''
    set -eu
    exec ${pkgs.python3}/bin/python3 - ${lib.escapeShellArg cfg.backup.repositoryFile} ${lib.escapeShellArg cfg.backup.passwordFile} <<'PY'
    import pathlib, sys
    repo, pw = sys.argv[1], sys.argv[2]
    path = pathlib.Path(repo)
    if not path.is_file():
        print("warehouse restic: repository file missing; skipping", file=sys.stderr)
        sys.exit(1)
    text = path.read_text(errors="replace").replace("\r", "").strip()
    if not text:
        print("warehouse restic: repository file empty or whitespace; skipping", file=sys.stderr)
        sys.exit(1)
    if len(text) >= 2 and text[0] == text[-1] and text[0] in ("'", '"'):
        print("warehouse restic: repository file is a quoted placeholder; skipping", file=sys.stderr)
        sys.exit(1)
    if text.lower() in ("placeholder", "todo"):
        print("warehouse restic: repository file is still a placeholder; skipping", file=sys.stderr)
        sys.exit(1)
    secret = pathlib.Path(pw)
    if not secret.is_file() or secret.stat().st_size == 0:
        print("warehouse restic: password file missing or empty; skipping", file=sys.stderr)
        sys.exit(1)
    PY
  '';

  # Runs only after the repo check passes. A bad mode fails the unit
  # (ExecStartPre), it does not use exit 255.
  resticPasswordMode = pkgs.writeShellScript "warehouse-restic-password-mode" ''
    set -eu
    pass="${cfg.backup.passwordFile}"
    if [ ! -e "$pass" ]; then
      echo "warehouse restic: password file $pass is missing" >&2
      exit 1
    fi
    owner=$(${pkgs.coreutils}/bin/stat -c '%u' "$pass")
    mode=$(${pkgs.coreutils}/bin/stat -c '%a' "$pass")
    case "$mode" in
      400|600|0400|0600) ok=1 ;;
      *) ok=0 ;;
    esac
    if [ "$owner" != "0" ] || [ "$ok" != "1" ]; then
      echo "warehouse restic: $pass must be root-owned mode 0400 or 0600 (owner $owner mode $mode)" >&2
      exit 1
    fi
  '';

  stateDirConfig = optionalAttrs (stateDirectory != null) {
    StateDirectory = stateDirectory;
    StateDirectoryMode = "0750";
  };

  loaderServices = mapAttrs' (name: loader:
    nameValuePair "warehouse-load-${name}" {
      description = "Warehouse loader ${name}";
      after = [ "systemd-tmpfiles-setup.service" ];
      wants = [ "systemd-tmpfiles-setup.service" ];
      unitConfig.OnSuccess = [ "warehouse-dbt.service" ];
      path = [ pkgs.util-linux pkgs.coreutils ];
      environment = {
        WAREHOUSE_DATA_DIR = cfg.dataDir;
        HOME = "${cfg.dataDir}/home";
      } // loader.environment;
      serviceConfig = hardened // stateDirConfig // (if loader.network then onlineNet else offlineNet) // {
        Type = "oneshot";
        User = "warehouse";
        Group = "warehouse";
        # Private directory for the SQLite copy. Removed by
        # systemd when the unit stops, including after SIGKILL.
        # RuntimeDirectoryPreserve is left unset on purpose.
        RuntimeDirectory = "warehouse-load-${name}";
        RuntimeDirectoryMode = "0700";
        # Rust loader. Leave this off the Python dbt unit.
        MemoryDenyWriteExecute = true;
      } // optionalAttrs (loader.environmentFile != null) {
        EnvironmentFile = loader.environmentFile;
      };
      script = ''
        set -eu
        mkdir -p ${cfg.dataDir}/home
        exec flock -w 1800 ${cfg.dataDir}/.write.lock ${loader.script}
      '';
    }
  ) cfg.loaders;

  loaderTimers = mapAttrs' (name: loader:
    nameValuePair "warehouse-load-${name}" {
      description = "Timer for warehouse loader ${name}";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = loader.onCalendar;
        Persistent = true;
        RandomizedDelaySec = "5m";
      };
    }
  ) cfg.loaders;
in
{
  options.services.dataWarehouse = {
    enable = mkEnableOption "personal Parquet warehouse (DuckDB + dbt, no listener)";

    dataDir = mkOption {
      type = types.str;
      default = "/var/lib/warehouse";
      description = ''
        Warehouse state directory. Default matches systemd StateDirectory=warehouse.
        Raw Parquet, the dbt project copy, and warehouse.duckdb live here.
      '';
    };

    loaders = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          script = mkOption {
            type = types.str;
            description = ''
              Absolute path of the loader executable. Pass `lib.getExe` of a
              package. This string is not copied into the Nix store again.
            '';
          };

          onCalendar = mkOption {
            type = types.str;
            example = "*-*-* 02:15:00";
            description = "systemd OnCalendar for this loader.";
          };

          environmentFile = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = ''
              Host path of a root-owned mode 0400 EnvironmentFile
              (for example /etc/warehouse/<loader>.env). Create it on the
              machine. Do not commit it and do not point this at a file in
              the repo, or Nix will try to store the secrets.
            '';
          };

          environment = mkOption {
            type = types.attrsOf types.str;
            default = { };
            description = ''
              Extra environment variables for the loader unit.
              WAREHOUSE_DATA_DIR is always set. An environmentFile overrides
              keys it defines. Never put secrets here; they are copied into
              the world-readable unit file. Use environmentFile on the host.
            '';
          };

          network = mkOption {
            type = types.bool;
            default = false;
            description = ''
              Allow this loader to open network sockets. Default is off:
              PrivateNetwork and RestrictAddressFamilies=AF_UNIX.
              Set true for a loader that fetches, such as a future
              AI_Dispatch Postgres reader.
            '';
          };
        };
      });
      default = { };
      description = "One oneshot service and timer per loader.";
    };

    dbt.onCalendar = mkOption {
      type = types.str;
      default = "*-*-* 02:45:00";
      description = ''
        When warehouse-dbt.service runs on its own timer. Each loader also
        starts this unit with OnSuccess.
      '';
    };

    backup = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Turn on services.restic.backups.warehouse. Leave this false until
          the repository file and the password file exist on the host.
        '';
      };

      repositoryFile = mkOption {
        type = types.str;
        default = "/etc/restic/warehouse-repo";
        description = ''
          Root-owned mode 0400 file whose contents are the restic repository
          URL. When backup.enable is true, tmpfiles creates this file with
          the text PLACEHOLDER if it is absent, and does not overwrite it.
          Replace that text on the host. The file is not read from the Nix store.
        '';
      };

      passwordFile = mkOption {
        type = types.str;
        default = "/etc/restic/warehouse-password";
        description = ''
          Root-owned file containing the restic password, mode 0400 or 0600.
          Create it on the host. This module does not write it. ExecStartPre
          refuses to run when the owner is not root or the mode is anything else.
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion =
          !(hasPrefix builtins.storeDir cfg.backup.passwordFile)
          && !(hasPrefix builtins.storeDir cfg.backup.repositoryFile);
        message = ''
          services.dataWarehouse backup repositoryFile and passwordFile must be
          host paths outside the Nix store. A Nix path or ''${./file} interpolation
          would copy the secret into the world-readable store.
        '';
      }
    ] ++ mapAttrsToList (name: loader: {
      assertion = builtins.match "[a-z][a-z0-9_-]*" name != null;
      message = "services.dataWarehouse.loaders.${name} must match [a-z][a-z0-9_-]*";
    }) cfg.loaders
    ++ mapAttrsToList (name: loader: {
      assertion = loader.environmentFile == null
        || !(hasPrefix builtins.storeDir loader.environmentFile);
      message = ''
        services.dataWarehouse.loaders.${name}.environmentFile must be a host
        path outside the Nix store.
      '';
    }) cfg.loaders;

    users.users.warehouse = {
      isSystemUser = true;
      group = "warehouse";
      createHome = false;
    };
    users.groups.warehouse = { };
    users.users.sam.extraGroups = [ "warehouse" ];

    environment.systemPackages = [
      pkgs.duckdb
      pkgs.warehouse-load-health
      warehousePython
    ];

    # Layout. inbox/health is owned by sam, the writer. Mode 3750 is
    # setgid, sticky, owner rwx, group rx. New files inherit group
    # warehouse, so a 0640 file sam creates is readable by the loader.
    # The loader does not need write access.
    # raw/ stays 0750. UMask=0027 on the units makes new files 0640.
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 warehouse warehouse - -"
      "d ${cfg.dataDir}/raw 0750 warehouse warehouse - -"
      "d ${cfg.dataDir}/raw/health 0750 warehouse warehouse - -"
      "d ${cfg.dataDir}/inbox 0750 warehouse warehouse - -"
      "d ${cfg.dataDir}/inbox/health 3750 sam warehouse - -"
      "d ${cfg.dataDir}/dbt 0750 warehouse warehouse - -"
      "d ${cfg.dataDir}/dbt/target 0750 warehouse warehouse - -"
      "d ${cfg.dataDir}/home 0750 warehouse warehouse - -"
      "d ${cfg.dataDir}/export 0750 warehouse warehouse - -"
      "d /etc/warehouse 0750 root root - -"
    ] ++ optionals cfg.backup.enable [
      "d /etc/restic 0750 root root - -"
      "f ${cfg.backup.repositoryFile} 0400 root root - PLACEHOLDER"
    ];

    systemd.services = loaderServices // {
      warehouse-dbt = {
        description = "dbt build and source freshness for the personal warehouse";
        after = [ "systemd-tmpfiles-setup.service" ]
          ++ map (name: "warehouse-load-${name}.service") (attrNames cfg.loaders);
        wants = [ "systemd-tmpfiles-setup.service" ];
        path = [
          pkgs.util-linux
          pkgs.coreutils
          pkgs.bash
          pkgs.duckdb
          warehousePython
        ];
        environment = {
          WAREHOUSE_DATA_DIR = cfg.dataDir;
          HOME = "${cfg.dataDir}/home";
          XDG_CACHE_HOME = "${cfg.dataDir}/home/cache";
          WAREHOUSE_RAW_HEALTH_GLOB = "${cfg.dataDir}/raw/health/**/*.parquet";
          DBT_SEND_ANONYMOUS_USAGE_STATS = "false";
          DO_NOT_TRACK = "1";
        };
        serviceConfig = hardened // stateDirConfig // offlineNet // {
          Type = "oneshot";
          User = "warehouse";
          Group = "warehouse";
          ExecCondition = dbtHasRawParquet;
        };
        script = ''
          set -eu
          data="${cfg.dataDir}"
          mkdir -p "$data/home/cache" "$data/dbt/target" "$data/raw/health" \
            "$data/inbox/health" "$data/export"
          # A previous run may have copied the Nix store tree with mode 555/444.
          # chmod before rm, and do not preserve those modes on the new copy.
          if [ -e "$data/dbt/project" ]; then
            chmod -R u+w "$data/dbt/project" || true
            rm -rf "$data/dbt/project"
          fi
          mkdir -p "$data/dbt/project" "$data/dbt/logs" "$data/dbt/target"
          cp -a --no-preserve=mode ${dbtProject}/. "$data/dbt/project/"
          chmod -R u+w "$data/dbt/project"
          install -m 0640 ${profilesFile} "$data/dbt/profiles.yml"
          export WAREHOUSE_DBT_PROJECT="$data/dbt/project"
          export WAREHOUSE_DBT_PROFILES="$data/dbt"
          export WAREHOUSE_DBT_TARGET="$data/dbt/target"
          export WAREHOUSE_DBT_LOGS="$data/dbt/logs"
          flock -w 1800 "$data/.write.lock" bash -c '
            set -eu
            dbt build \
              --project-dir "$WAREHOUSE_DBT_PROJECT" \
              --profiles-dir "$WAREHOUSE_DBT_PROFILES" \
              --target-path "$WAREHOUSE_DBT_TARGET" \
              --log-path "$WAREHOUSE_DBT_LOGS" \
              --target prod
            dbt source freshness \
              --project-dir "$WAREHOUSE_DBT_PROJECT" \
              --profiles-dir "$WAREHOUSE_DBT_PROFILES" \
              --target-path "$WAREHOUSE_DBT_TARGET" \
              --log-path "$WAREHOUSE_DBT_LOGS" \
              --target prod
          '
          if [ -f "$data/warehouse.duckdb" ]; then
            chmod 0640 "$data/warehouse.duckdb"
          fi
          for extra in "$data"/warehouse.duckdb.*; do
            if [ -e "$extra" ]; then
              chmod 0640 "$extra"
            fi
          done
        '';
      };
    } // optionalAttrs cfg.backup.enable {
      restic-backups-warehouse = {
        serviceConfig = {
          ExecCondition = resticRepoReady;
          ExecStartPre = resticPasswordMode;
        };
      };
      warehouse-restic-check = {
        description = "Monthly restic check of the warehouse repository";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        serviceConfig = hardened // onlineNet // {
          Type = "oneshot";
          User = "root";
          CacheDirectory = "restic-backups-warehouse";
          ExecCondition = resticRepoReady;
          ExecStartPre = resticPasswordMode;
          ExecStart = "${lib.getExe pkgs.restic} check";
          Environment = [
            "RESTIC_PASSWORD_FILE=${cfg.backup.passwordFile}"
            "RESTIC_REPOSITORY_FILE=${cfg.backup.repositoryFile}"
            "RESTIC_CACHE_DIR=/var/cache/restic-backups-warehouse"
          ];
        };
      };
    };

    systemd.timers = loaderTimers // {
      warehouse-dbt = {
        description = "Timer for warehouse dbt build";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.dbt.onCalendar;
          Persistent = true;
        };
      };
    } // optionalAttrs cfg.backup.enable {
      warehouse-restic-check = {
        description = "Monthly restic check of the warehouse repository";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "monthly";
          Persistent = true;
          RandomizedDelaySec = "1h";
        };
      };
    };

    # Raw Parquet and the copied dbt project. warehouse.duckdb is rebuildable
    # with `dbt build`, so it is not in paths. initialize stays false.
    # restic-backups-warehouse skips (ExecCondition exit 1) while the repo
    # file is missing, empty, whitespace, quoted, or PLACEHOLDER/TODO in
    # any case, or the password file is missing. Exit 255 would fail the unit.
    # ExecStartPre then requires the password file to be root and 0400/0600.
    services.restic.backups = optionalAttrs cfg.backup.enable {
      warehouse = {
        initialize = false;
        repositoryFile = cfg.backup.repositoryFile;
        passwordFile = cfg.backup.passwordFile;
        paths = [
          "${cfg.dataDir}/raw"
          "${cfg.dataDir}/dbt"
        ];
        exclude = [
          "${cfg.dataDir}/dbt/target"
          "${cfg.dataDir}/dbt/project/logs"
          "${cfg.dataDir}/dbt/project/target"
          "${cfg.dataDir}/dbt/project/dbt_packages"
          "${cfg.dataDir}/warehouse.duckdb"
          "${cfg.dataDir}/warehouse.duckdb.*"
          # Loader publishes via .<run_id>.parquet.partial, then rename.
          "${cfg.dataDir}/raw/**/.*.partial"
        ];
        timerConfig = {
          OnCalendar = "03:30";
          Persistent = true;
          RandomizedDelaySec = "15m";
        };
        pruneOpts = [
          "--keep-daily 7"
          "--keep-weekly 4"
          "--keep-monthly 6"
        ];
      };
    };
  };
}

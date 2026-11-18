# Personal warehouse on AIServer.
# Parquet under dataDir/raw, dbt-duckdb builds warehouse.duckdb, restic is off
# until Sam sets a repository. Nothing listens. Query with SSH over Tailscale
# and `duckdb -readonly`.
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.dataWarehouse;

  # Same nixpkgs as pkgs.duckdb. dbt-duckdb is optional until nixpkgs has it;
  # see the warning below. Do not vendor a second DuckDB.
  dbtDuckdbAvailable = pkgs.python3Packages ? "dbt-duckdb";
  warehousePython = pkgs.python3.withPackages (ps:
    [ ps.duckdb ]
    ++ lib.optional (ps ? "dbt-duckdb") ps."dbt-duckdb"
  );

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
    RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
    SystemCallFilter = [ "@system-service" ];
    UMask = "0027";
    TimeoutStartSec = "30min";
    ReadWritePaths = [ cfg.dataDir ];
  };

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
      serviceConfig = hardened // stateDirConfig // {
        Type = "oneshot";
        User = "warehouse";
        Group = "warehouse";
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
              keys it defines.
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
          URL. The module creates it with the text PLACEHOLDER when missing.
          Replace that text on the host. The file is not read from the Nix store.
        '';
      };

      passwordFile = mkOption {
        type = types.str;
        default = "/etc/restic/warehouse-password";
        description = ''
          Root-owned mode 0400 file containing the restic password.
          Create it on the host. This module does not write it.
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    warnings = optional (!dbtDuckdbAvailable) ''
      services.dataWarehouse: python3Packages.dbt-duckdb is not in this nixpkgs
      (python3Packages.dbt-core and python3Packages.duckdb are).
      warehouse-dbt.service will exit until dbt-duckdb is packaged against those
      two attributes so the DuckDB file format matches pkgs.duckdb.
      Smallest fix: add pkgs/development/python-modules/dbt-duckdb
      (buildPythonPackage, same version line as dbt-core). Do not vendor DuckDB.
    '';

    assertions = mapAttrsToList (name: _: {
      assertion = builtins.match "[a-z][a-z0-9_-]*" name != null;
      message = "services.dataWarehouse.loaders.${name} must match [a-z][a-z0-9_-]*";
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

    # Layout. inbox/health is group-writable so sam can drop data.db.
    # raw/ stays 0750. UMask=0027 on the units makes new files 0640.
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 warehouse warehouse - -"
      "d ${cfg.dataDir}/raw 0750 warehouse warehouse - -"
      "d ${cfg.dataDir}/raw/health 0750 warehouse warehouse - -"
      "d ${cfg.dataDir}/inbox 0750 warehouse warehouse - -"
      "d ${cfg.dataDir}/inbox/health 2770 warehouse warehouse - -"
      "d ${cfg.dataDir}/dbt 0750 warehouse warehouse - -"
      "d ${cfg.dataDir}/dbt/target 0750 warehouse warehouse - -"
      "d ${cfg.dataDir}/home 0750 warehouse warehouse - -"
      "d ${cfg.dataDir}/export 0750 warehouse warehouse - -"
      "d /etc/warehouse 0750 root root - -"
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
        };
        serviceConfig = hardened // stateDirConfig // {
          Type = "oneshot";
          User = "warehouse";
          Group = "warehouse";
        };
        script = ''
          set -eu
          data="${cfg.dataDir}"
          mkdir -p "$data/home/cache" "$data/dbt/target" "$data/raw/health" \
            "$data/inbox/health" "$data/export"
          rm -rf "$data/dbt/project"
          mkdir -p "$data/dbt/project"
          cp -a ${dbtProject}/. "$data/dbt/project/"
          install -m 0640 ${profilesFile} "$data/dbt/profiles.yml"
          if ! command -v dbt >/dev/null 2>&1; then
            echo "warehouse-dbt: dbt is not on PATH." >&2
            echo "python3Packages.dbt-duckdb is missing from this nixpkgs." >&2
            echo "Package it against the existing dbt-core and python3Packages.duckdb." >&2
            exit 1
          fi
          export WAREHOUSE_DBT_PROJECT="$data/dbt/project"
          export WAREHOUSE_DBT_PROFILES="$data/dbt"
          export WAREHOUSE_DBT_TARGET="$data/dbt/target"
          flock -w 1800 "$data/.write.lock" bash -c '
            set -eu
            dbt build \
              --project-dir "$WAREHOUSE_DBT_PROJECT" \
              --profiles-dir "$WAREHOUSE_DBT_PROFILES" \
              --target-path "$WAREHOUSE_DBT_TARGET" \
              --target prod
            dbt source freshness \
              --project-dir "$WAREHOUSE_DBT_PROJECT" \
              --profiles-dir "$WAREHOUSE_DBT_PROFILES" \
              --target-path "$WAREHOUSE_DBT_TARGET" \
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
      warehouse-restic-check = {
        description = "Monthly restic check of the warehouse repository";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          Type = "oneshot";
          User = "root";
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

{
  description = "NixOS Configuration Flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    plasma-manager = {
      url = "github:pjones/plasma-manager";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
  };

  outputs = { self, nixpkgs, home-manager, plasma-manager, ... }@inputs:
    let
      system = "x86_64-linux";
      
      # Helper to create hosts with standard inputs and modules
      mkHost = { hostname, modules ? [], ... }:
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = { inherit inputs; };
          modules = [
            ./hosts/${hostname} # Automatically imports default.nix in this dir

            # Local packages (available as pkgs.<name>; only installed where referenced)
            {
              nixpkgs.overlays = [ (import ./overlays/default.nix) ];
            }
            
            # Home Manager Integration
            home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.backupFileExtension = "backup";
              home-manager.users.sam = {
                imports = [ 
                  ./modules/home-manager 
                  plasma-manager.homeModules.plasma-manager
                ] ++ (if builtins.pathExists (./hosts + "/${hostname}/home.nix") then [ (./hosts + "/${hostname}/home.nix") ] else []);
              };
              home-manager.extraSpecialArgs = { inherit inputs; };
            }
          ] ++ modules;
        };
    in
    {
      nixosConfigurations = {
        sam-main = mkHost {
          hostname = "sam_main";
        };

        framework13 = mkHost {
          hostname = "framework13";
        };

        AIServer = mkHost {
          hostname = "AIServer";
        };

        asus_rog_1070 = mkHost {
          hostname = "asus_rog_1070";
        };

        # Dedicated Incus personal-cloud plane (Slice A). Stub hardware until Sam assigns a box.
        # Not in CI build matrix yet — replace hardware-configuration.nix before first switch.
        incus_cloud = mkHost {
          hostname = "incus_cloud";
        };

        dad_nas = mkHost {
          hostname = "dad_nas";
        };
      };

      checks.x86_64-linux.warehouse =
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ (import ./overlays/default.nix) ];
            config.allowUnfree = true;
          };
        in
        pkgs.testers.nixosTest {
          name = "warehouse";
          nodes.machine = { lib, ... }: {
            imports = [ ./modules/services/data-warehouse.nix ];
            nixpkgs.pkgs = lib.mkForce pkgs;
            services.dataWarehouse = {
              enable = true;
              backup.enable = true;
              loaders.health = {
                script = lib.getExe pkgs.warehouse-load-health;
                onCalendar = "daily";
              };
            };
            users.users.sam = {
              isNormalUser = true;
              uid = 1000;
            };
            environment.systemPackages = [ pkgs.sqlite ];
            virtualisation.memorySize = 2048;
            system.stateVersion = "24.11";
          };
          testScript = ''
            machine.wait_for_unit("multi-user.target")

            # Empty raw tree: ExecCondition exit 1 skips, unit is not failed.
            machine.succeed("systemctl start warehouse-dbt.service")
            machine.fail("systemctl is-failed warehouse-dbt.service")
            machine.succeed("test \"$(systemctl show -p Result --value warehouse-dbt.service)\" = exec-condition")

            # Placeholder repo and missing password: backup and check skip.
            machine.succeed("test -s /etc/restic/warehouse-repo")
            machine.succeed("grep -qx PLACEHOLDER /etc/restic/warehouse-repo")
            machine.succeed("systemctl start restic-backups-warehouse.service")
            machine.succeed("systemctl start warehouse-restic-check.service")
            machine.fail("systemctl is-failed restic-backups-warehouse.service")
            machine.fail("systemctl is-failed warehouse-restic-check.service")
            machine.succeed("test \"$(systemctl show -p Result --value restic-backups-warehouse.service)\" = exec-condition")
            machine.succeed("test \"$(systemctl show -p Result --value warehouse-restic-check.service)\" = exec-condition")

            machine.succeed("install -d -o warehouse -g warehouse -m 2770 /var/lib/warehouse/inbox/health")
            machine.succeed(
                "sqlite3 /var/lib/warehouse/inbox/health/data.db "
                + "\"CREATE TABLE metrics (id TEXT PRIMARY KEY, kind TEXT NOT NULL, category TEXT NOT NULL, recorded_at TEXT NOT NULL, day TEXT NOT NULL, value REAL NOT NULL, unit TEXT NOT NULL, source TEXT NOT NULL, raw_name TEXT, notes TEXT);\""
            )
            machine.succeed(
                "sqlite3 /var/lib/warehouse/inbox/health/data.db "
                + "\"INSERT INTO metrics VALUES ('11111111-1111-4111-8111-111111111111', 'resting_heart_rate_bpm', 'heart', '2026-07-21T15:00:00+00:00', '2026-07-21', 58, 'beats per minute', 'Apple Watch', 'Apple Watch', 'route a/b');\""
            )
            machine.succeed(
                "sqlite3 /var/lib/warehouse/inbox/health/data.db "
                + "\"INSERT INTO metrics VALUES ('22222222-2222-4222-8222-222222222222', 'body_fat_pct', 'body', '2026-07-21T15:00:00+00:00', '2026-07-21', 0, '%', 'scale', 'scale', NULL);\""
            )
            machine.succeed(
                "sqlite3 /var/lib/warehouse/inbox/health/data.db "
                + "\"INSERT INTO metrics VALUES ('33333333-3333-4333-8333-333333333333', 'sleep_efficiency_pct', 'sleep', '2026-07-21T15:00:00+00:00', '2026-07-21', 1, '%', 'band', 'band', NULL);\""
            )
            machine.succeed(
                "sqlite3 /var/lib/warehouse/inbox/health/data.db "
                + "\"INSERT INTO metrics VALUES ('44444444-4444-4444-8444-444444444444', 'spo2_pct', 'body', '2026-07-21T15:00:00+00:00', '2026-07-21', 98, '%', 'band', 'band', NULL);\""
            )
            machine.succeed(
                "sqlite3 /var/lib/warehouse/inbox/health/data.db "
                + "\"PRAGMA journal_mode=WAL; PRAGMA wal_checkpoint(TRUNCATE);\""
            )
            machine.succeed("rm -f /var/lib/warehouse/inbox/health/data.db-wal /var/lib/warehouse/inbox/health/data.db-shm")
            machine.succeed("chown warehouse:warehouse /var/lib/warehouse/inbox/health/data.db")
            machine.succeed("chmod 0640 /var/lib/warehouse/inbox/health/data.db")
            machine.succeed("systemctl start warehouse-load-health.service")
            machine.succeed("test \"$(systemctl show -p Result --value warehouse-load-health.service)\" = success")
            machine.succeed("test ! -e /var/lib/warehouse/inbox/health/data.db-wal")
            machine.succeed("test ! -e /var/lib/warehouse/inbox/health/data.db-shm")
            machine.succeed("systemctl start warehouse-load-health.service")
            machine.succeed("test \"$(systemctl show -p Result --value warehouse-load-health.service)\" = success")
            machine.succeed("test ! -e /var/lib/warehouse/inbox/health/data.db-wal")
            machine.succeed("test ! -e /var/lib/warehouse/inbox/health/data.db-shm")
            machine.succeed("install -o warehouse -g warehouse -m 0640 /dev/null /var/lib/warehouse/inbox/health/data.db-wal")
            machine.succeed("systemctl start warehouse-load-health.service")
            machine.succeed("test \"$(systemctl show -p Result --value warehouse-load-health.service)\" = success")
            machine.succeed("test -f /var/lib/warehouse/inbox/health/data.db-wal")
            machine.succeed("test ! -s /var/lib/warehouse/inbox/health/data.db-wal")
            machine.succeed("test ! -e /var/lib/warehouse/inbox/health/data.db-shm")
            machine.succeed("systemctl start warehouse-dbt.service")
            machine.succeed("systemctl start warehouse-dbt.service")
            machine.fail("systemctl is-failed warehouse-dbt.service")
            machine.succeed("test \"$(systemctl show -p Result --value warehouse-dbt.service)\" = success")

            # Placeholder variants skip (exit 1, Result=exec-condition).
            # A real repo plus a bad password mode fails the unit.
            # Root and mode 0400 or 0600 pass the guard scripts.
            machine.succeed(
                r"""
                set -eu
                repo=/etc/restic/warehouse-repo
                pass=/etc/restic/warehouse-password
                install -d -m 0700 /etc/restic
                install -m 0600 /dev/null "$pass"
                printf '%s\n' secret > "$pass"
                chmod 0400 "$pass"
                chown root:root "$pass"
                skip_case() {
                  systemctl reset-failed restic-backups-warehouse.service warehouse-restic-check.service || true
                  systemctl start restic-backups-warehouse.service
                  systemctl start warehouse-restic-check.service
                  test "$(systemctl show -p Result --value restic-backups-warehouse.service)" = exec-condition
                  test "$(systemctl show -p Result --value warehouse-restic-check.service)" = exec-condition
                  if systemctl is-failed restic-backups-warehouse.service; then
                    echo "backup unit failed on a placeholder"
                    exit 1
                  fi
                  if systemctl is-failed warehouse-restic-check.service; then
                    echo "check unit failed on a placeholder"
                    exit 1
                  fi
                }
                : > "$repo"
                skip_case
                printf ' \t \n' > "$repo"
                skip_case
                printf '""\n' > "$repo"
                skip_case
                printf "'PLACEHOLDER'\n" > "$repo"
                skip_case
                printf '"placeholder"\n' > "$repo"
                skip_case
                printf 'todo\n' > "$repo"
                skip_case
                printf 'TODO\n' > "$repo"
                skip_case
                printf '  ToDo  \n' > "$repo"
                skip_case
                printf 'placeholder\n' > "$repo"
                skip_case
                printf '%s\n' 'sftp:backup@host.example:/warehouse' > "$repo"
                chmod 0644 "$pass"
                chown root:root "$pass"
                systemctl reset-failed restic-backups-warehouse.service || true
                if systemctl start restic-backups-warehouse.service; then
                  echo "mode 0644 was accepted"
                  exit 1
                fi
                systemctl is-failed restic-backups-warehouse.service
                journalctl -u restic-backups-warehouse.service --no-pager | grep -F '0400 or 0600'
                chmod 0600 "$pass"
                chown 1000:0 "$pass"
                systemctl reset-failed restic-backups-warehouse.service || true
                if systemctl start restic-backups-warehouse.service; then
                  echo "non-root password file was accepted"
                  exit 1
                fi
                systemctl is-failed restic-backups-warehouse.service
                journalctl -u restic-backups-warehouse.service --no-pager | grep -F 'must be root-owned'
                chown root:root "$pass"
                chmod 0400 "$pass"
                cond=$(systemctl cat restic-backups-warehouse.service | awk -F= '/^ExecCondition=/ { print $2; exit }')
                pre=$(systemctl cat restic-backups-warehouse.service | awk -F= '/^ExecStartPre=.*password-mode/ { print $2; exit }')
                echo "cond=$cond"
                echo "pre=$pre"
                test -x "$cond"
                test -x "$pre"
                "$cond"
                "$pre"
                chmod 0600 "$pass"
                "$cond"
                "$pre"
                """
            )

            # A symlinked inbox database is refused and does not publish Parquet.
            machine.succeed(
                "sqlite3 /tmp/secret.db "
                + "\"CREATE TABLE metrics (id TEXT PRIMARY KEY, kind TEXT NOT NULL, category TEXT NOT NULL, recorded_at TEXT NOT NULL, day TEXT NOT NULL, value REAL NOT NULL, unit TEXT NOT NULL, source TEXT NOT NULL, raw_name TEXT, notes TEXT);\""
            )
            machine.succeed(
                "sqlite3 /tmp/secret.db "
                + "\"INSERT INTO metrics VALUES ('secret-0', 'steps', 'activity', '2026-07-21T15:00:00+00:00', '2026-07-21', 1, 'count', 'secret', NULL, NULL);\""
            )
            machine.succeed("ln -sfn /tmp/secret.db /var/lib/warehouse/inbox/health/secret-link.db")
            machine.succeed(
                r"""
                set -eu
                set +e
                out=$(warehouse-load-health --sqlite /var/lib/warehouse/inbox/health/secret-link.db --raw-root /tmp/wh-sym-raw --source health 2>&1)
                rc=$?
                set -e
                test "$rc" -ne 0
                printf '%s\n' "$out" | grep -F symlink
                test ! -e /tmp/wh-sym-raw/health
                """
            )
          '';
        };

      # Eval-time check: a store path in a secret option must fail an assertion.
      # The happy path is the warehouse VM test above (host paths under /etc).
      checks.x86_64-linux.warehouse-secret-paths =
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };
          evalBad = nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [
              ./modules/services/data-warehouse.nix
              ({ ... }: {
                boot.isContainer = true;
                system.stateVersion = "24.11";
                users.users.sam.isNormalUser = true;
                nixpkgs.overlays = [ (import ./overlays/default.nix) ];
                services.dataWarehouse = {
                  enable = true;
                  backup.passwordFile = builtins.storeDir + "/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-secret";
                  backup.repositoryFile = builtins.storeDir + "/ffffffffffffffffffffffffffffffff-repo";
                  loaders.health = {
                    script = "/bin/true";
                    environmentFile = builtins.storeDir + "/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-env";
                  };
                };
              })
            ];
          };
          failed = builtins.filter (a: !a.assertion) evalBad.config.assertions;
          msgs = nixpkgs.lib.concatMapStringsSep "\n" (a: a.message) failed;
        in
        pkgs.runCommand "warehouse-secret-paths" { inherit msgs; } ''
          printf '%s\n' "$msgs" | grep -F 'Nix store' >/dev/null
          printf '%s\n' "$msgs" | grep -F 'passwordFile' >/dev/null
          printf '%s\n' "$msgs" | grep -F 'environmentFile' >/dev/null
          echo ok > "$out"
        '';
    };
}
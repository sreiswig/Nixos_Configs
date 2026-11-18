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
            machine.succeed("chown warehouse:warehouse /var/lib/warehouse/inbox/health/data.db")
            machine.succeed("chmod 0640 /var/lib/warehouse/inbox/health/data.db")
            machine.succeed("systemctl start warehouse-load-health.service")
            machine.succeed("systemctl start warehouse-dbt.service")
            machine.succeed("systemctl start warehouse-dbt.service")
            machine.fail("systemctl is-failed warehouse-dbt.service")
            machine.succeed("test \"$(systemctl show -p Result --value warehouse-dbt.service)\" = success")
          '';
        };
    };
}
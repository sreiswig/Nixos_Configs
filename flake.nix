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
              nixpkgs.overlays = [
                (final: prev:
                  let
                    # Default python3 is 3.14. dbt-semantic-interfaces (pulled in
                    # by dbt-core) is disabled there because it uses pydantic v1.
                    # Python 3.13 is the newest interpreter in this pin that can
                    # build the stack. duckdb is python313.pkgs.duckdb, built
                    # from pkgs.duckdb.
                    #
                    # dbt-common in this pin requires pathspec<1.1 and the set
                    # has pathspec 1.1.1. Relax that one bound on the existing
                    # package so the build can use it.
                    warehousePythonPkgs = final.python313.override {
                      packageOverrides = pyFinal: pyPrev: {
                        dbt-common = pyPrev.dbt-common.overridePythonAttrs (old: {
                          pythonRelaxDeps = (old.pythonRelaxDeps or [ ]) ++ [ "pathspec" ];
                        });
                      };
                    };
                    dbtDuckdb = warehousePythonPkgs.pkgs.callPackage ./pkgs/dbt-duckdb { };
                  in
                  {
                    grok-bot = final.callPackage ./pkgs/grok-bot { };
                    warehouse-load-health = final.callPackage ./pkgs/warehouse-load-health { };
                    dbt-duckdb = dbtDuckdb;
                    # withAdapters sets ignoreCollisions. dbt-core and the
                    # adapters each ship namespace __init__.py files under dbt/.
                    warehouse-python = warehousePythonPkgs.pkgs.dbt-core.withAdapters (
                      _adapters: [ dbtDuckdb ]
                    );
                  })
              ];
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
    };
}
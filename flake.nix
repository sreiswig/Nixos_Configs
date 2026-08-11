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
                (final: prev: {
                  grok-bot = final.callPackage ./pkgs/grok-bot { };
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

        dad_nas = mkHost {
          hostname = "dad_nas";
        };
      };
    };
}
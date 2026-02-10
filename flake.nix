{
  description = "NixOS Configuration Flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, home-manager, ... }@inputs:
    let
      system = "x86_64-linux";
      
      # Helper to create hosts with standard inputs and modules
      mkHost = { hostname, modules ? [], ... }:
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = { inherit inputs; };
          modules = [
            ./hosts/${hostname} # Automatically imports default.nix in this dir
            
            # Home Manager Integration
            home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.users.sam = import ./modules/home-manager;
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
      };
    };
}
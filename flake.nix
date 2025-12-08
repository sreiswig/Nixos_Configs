{
  description = "Main Flake for Main, Laptop, AI Server configuration (uses overlays flake)";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    home-manager.url = "github:nix-community/home-manager";
  };

  outputs = { self, nixpkgs, overlays, home-manager, ... }@inputs: let
    # Collect overlay functions from the overlays flake
    overlayFns = [ overlays.overlays.antigravity ];
    mkPkgs = system: import nixpkgs { inherit system; overlays = overlayFns; };
  in {
    nixosConfigurations = {
      # Main
      sam-main = let pkgs = mkPkgs "x86_64-linux"; in pkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [ ./hosts/sam_main ];
        specialArgs = { inherit home-manager; };
      };

      # Laptop
      framework13 = let pkgs = mkPkgs "x86_64-linux"; in pkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [ ./hosts/framework13 ];
        specialArgs = { inherit home-manager; };
      };

      # Server
      AIServer = let pkgs = mkPkgs "x86_64-linux"; in pkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [ ./hosts/AIServer ];
        specialArgs = { inherit home-manager; };
      };
    };

    # Re-export overlays so other flakes can depend on them easily
    overlays = overlays.overlays;
  };
}

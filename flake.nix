{
  description = "Main Flake for Main, Laptop, AI Server configuration";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs = { self, nixpkgs, ... }@inputs: {
    nixosConfigurations = {
      # Main
      sam-main = nixpkgs.lib.nixosSystem {
        modules = [./hosts/sam_main];
      };
      # Laptop
      framework13 = nixpkgs.lib.nixosSystem {
        modules = [./hosts/framework13];
      };
      # Server
      AIServer = nixpkgs.lib.nixosSystem {
        modules = [./hosts/AIServer];
      };
    };
  };
}

{
  description = "OneAPI flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs = { self, nixpkgs }: {
    devShells.default = with import nixpkgs { system = "x86_64-linux"; }; mkshell {
      name = "oneapi-shell";

      buildInputs = [
        # Essential tools and libraries for oneAPI
        "bash"
        "coreutils"
        "gcc"
        "glibc"
        "libstdc++"
        "buildFHSUserEnv"
      ];

      # FHS User Environment for oneAPI
      shellHook = ''
        # Create FHS environment
        export ONEAPI_ENV="$(buildFHSUserEnv {
          name = "fhs-oneapi";
          targetPkgs = pkgs: with pkgs; [
            "bash"
            "coreutils"
            "glibc"
            "gcc"
            "libstdc++"
          ];
        })"
        echo "Entering FHS environment for oneAPI..."
        $ONEAPI_ENV
      '';
    };
  };
}

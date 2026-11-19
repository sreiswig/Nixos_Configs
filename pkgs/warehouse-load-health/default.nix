{
  lib,
  rustPlatform,
}:

rustPlatform.buildRustPackage (finalAttrs: {
  pname = "warehouse-load-health";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./Cargo.toml
      ./Cargo.lock
      ./src
    ];
  };

  cargoLock.lockFile = ./Cargo.lock;

  meta = {
    description = "Append-only Parquet loader for personal_groktor health metrics";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "warehouse-load-health";
  };
})

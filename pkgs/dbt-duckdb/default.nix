# dbt adapter for DuckDB. Depends on python3Packages.dbt-core and
# python3Packages.duckdb from the same nixpkgs. python3Packages.duckdb is
# built from pkgs.duckdb, so the CLI and dbt share one file format.
{
  lib,
  buildPythonPackage,
  fetchPypi,
  pbr,
  setuptools,
  dbt-adapters,
  dbt-common,
  dbt-core,
  duckdb,
}:

buildPythonPackage rec {
  pname = "dbt-duckdb";
  version = "1.11.1";
  pyproject = true;

  src = fetchPypi {
    pname = "dbt_duckdb";
    inherit version;
    hash = "sha256-T+VMGuqEDM9HJaAYUQSb4rvi1MAj+qrQRMYWUFx4C0U=";
  };

  # The sdist ships setup.cfg plus setup.py (pbr). PEP 517 wants pyproject.toml.
  postPatch = ''
    cat > pyproject.toml <<'EOF'
    [build-system]
    requires = ["setuptools>=61.2", "pbr>=1.9"]
    build-backend = "setuptools.build_meta"
    EOF
  '';

  build-system = [
    pbr
    setuptools
  ];

  env.PBR_VERSION = version;

  dependencies = [
    dbt-adapters
    dbt-common
    dbt-core
    duckdb
  ];

  # Upstream tests need MotherDuck, S3, and the adapter harness.
  doCheck = false;

  # dbt-core and dbt-adapters already ship these namespace __init__.py files.
  pythonNamespaces = [
    "dbt"
    "dbt.adapters"
    "dbt.include"
  ];

  pythonImportsCheck = [ "dbt.adapters.duckdb" ];

  meta = {
    description = "DuckDB adapter for dbt";
    homepage = "https://github.com/duckdb/dbt-duckdb";
    changelog = "https://github.com/duckdb/dbt-duckdb/blob/v${version}/CHANGELOG.md";
    license = lib.licenses.asl20;
  };
}

# Local packages. dbt-duckdb is built with python313 against this nixpkgs'
# dbt-core and duckdb (pkgs.duckdb). Default python3 is 3.14, where
# dbt-semantic-interfaces is disabled (pydantic v1). dbt-common's
# pathspec<1.1 bound is relaxed because the pin ships pathspec 1.1.1.
final: prev:
let
  warehousePythonPkgs = final.python313.override {
    packageOverrides = pyFinal: pyPrev: {
      dbt-common = pyPrev.dbt-common.overridePythonAttrs (old: {
        pythonRelaxDeps = (old.pythonRelaxDeps or [ ]) ++ [ "pathspec" ];
      });
    };
  };
  dbtDuckdb = warehousePythonPkgs.pkgs.callPackage ../pkgs/dbt-duckdb { };
in
{
  grok-bot = final.callPackage ../pkgs/grok-bot { };
  warehouse-load-health = final.callPackage ../pkgs/warehouse-load-health { };
  dbt-duckdb = dbtDuckdb;
  # withAdapters sets ignoreCollisions. dbt-core and the adapters each
  # ship namespace __init__.py files under dbt/.
  warehouse-python = warehousePythonPkgs.pkgs.dbt-core.withAdapters (
    _adapters: [ dbtDuckdb ]
  );
}

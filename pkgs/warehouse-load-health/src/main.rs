use std::env;
use std::process::ExitCode;

use warehouse_load_health::LoadConfig;

fn main() -> ExitCode {
    let mut args: Vec<String> = env::args().skip(1).collect();
    if args.iter().any(|a| a == "--help" || a == "-h") {
        println!(
            "\
warehouse-load-health

Read personal_groktor's SQLite metrics table (read-only) and append Parquet
under <raw-root>/<source>/dt=YYYY-MM-DD/<run_id>.parquet.
A rerun writes a new run_id. Existing raw files stay in place.

  --sqlite PATH     SQLite file (default: $WAREHOUSE_DATA_DIR/inbox/health/data.db)
  --raw-root PATH   raw directory (default: $WAREHOUSE_DATA_DIR/raw)
  --source NAME     source folder name (default: health)
  --data-dir PATH   used when the paths above are omitted (default: /var/lib/warehouse)

The inbox file must be one rollback-journal SQLite snapshot. A WAL-mode
file, or a data.db-wal, data.db-shm, or data.db-journal beside it, is
refused. Dotfiles in the inbox are ignored.

Environment: WAREHOUSE_SQLITE_PATH, WAREHOUSE_RAW_ROOT, WAREHOUSE_SOURCE,
WAREHOUSE_DATA_DIR.
Flags win over environment variables.
"
        );
        return ExitCode::SUCCESS;
    }
    args.retain(|a| a != "--help");

    let config = match LoadConfig::from_args_and_env(&args) {
        Ok(config) => config,
        Err(err) => {
            eprintln!("warehouse-load-health: {err}");
            return ExitCode::from(2);
        }
    };

    match warehouse_load_health::load(&config) {
        Ok(report) => {
            println!(
                "warehouse-load-health: run_id={} rows={} files={} source={}",
                report.run_id,
                report.rows,
                report.files.len(),
                config.source
            );
            ExitCode::SUCCESS
        }
        Err(err) => {
            eprintln!("warehouse-load-health: {err}");
            ExitCode::from(1)
        }
    }
}

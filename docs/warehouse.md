# Personal warehouse (AIServer)

Status: module on, backup off, review only. Sam runs `nh os switch` on AIServer. Agents do not switch and do not merge this.

Host: flake attr `AIServer`, hostname `AI_Server`, MagicDNS `aiserver.tail93ec7d.ts.net`. Module: `modules/services/data-warehouse.nix` (`services.dataWarehouse.enable = true` in `hosts/AIServer/default.nix`).

The warehouse opens no port and changes no firewall rule. Reach it by SSH over Tailscale, then the DuckDB CLI on the box.

## Layout

State directory: `/var/lib/warehouse` (`services.dataWarehouse.dataDir`).

```text
/var/lib/warehouse/
  raw/health/dt=YYYY-MM-DD/<run_id>.parquet   # append-only
  inbox/health/data.db                         # personal_groktor SQLite drop
  dbt/project/                                 # copy of warehouse/dbt each build
  dbt/profiles.yml                             # generated, points at warehouse.duckdb
  dbt/target/                                  # dbt artifacts
  warehouse.duckdb                             # rebuildable with dbt build
  export/                                      # empty; optional faster-restore dump
  home/                                        # HOME for the warehouse user
  .write.lock                                  # flock for the single DuckDB writer
```

| Path | Mode | Owner |
|------|------|--------|
| `/var/lib/warehouse` | `0750` | `warehouse:warehouse` |
| `raw/` | `0750` | `warehouse:warehouse` |
| `inbox/health/` | `2770` | `warehouse:warehouse` (sam can drop a file) |
| `warehouse.duckdb` | `0640` | created by the dbt unit (`UMask=0027`) |

`sam` is in group `warehouse`, so `sam` can read the data dir and write the inbox. Raw files stay immutable: the loader never rewrites or deletes an existing Parquet file. A second run writes a new `<run_id>.parquet` under the same `dt=` directory. Staging dedupes.

`dt` is the America/Chicago calendar date of `recorded_at` (the host timezone in `modules/common`). The SQLite `day` column is kept as `source_day` and can differ when the UTC instant falls on the previous Chicago date.

Every raw row carries `_loaded_at` (UTC, one value per run), `_run_id`, `_source_file` (canonical SQLite path), and `_loader_version`.

DuckDB schemas, one per domain: `health`, `portfolio`, `ops`. This change fills `health` only. There is one `warehouse.duckdb`. `dbt build` can rebuild it from `raw/` plus the dbt project.

## Health source (implemented)

Loader: `pkgs.warehouse-load-health` (`pkgs/warehouse-load-health`).

It opens personal_groktor's SQLite database read-only (`SQLITE_OPEN_READ_ONLY` and `query_only`) and reads the `metrics` table. Column list checked against `sreiswig/personal_groktor` `src/store.rs`:

| SQLite column | Parquet column | Notes |
|---------------|----------------|--------|
| `id` | `id` | UUID text, primary key |
| `kind` | `kind` | canonical name (`steps`, `resting_heart_rate_bpm`, ...) |
| `category` | `category` | `sleep`, `heart`, `activity`, `body`, `recovery`, `other` |
| `recorded_at` | `recorded_at` | RFC3339, stored as UTC timestamp |
| `day` | `source_day` | `YYYY-MM-DD` from groktor |
| `value` | `value` | finite float |
| `unit` | `unit` | groktor default units, including `%` |
| `source` | `source` | for example `gadgetbridge:amazfit` |
| `raw_name` | `raw_name` | nullable |
| `notes` | `notes` | nullable |

The loader rejects a missing file, a missing `metrics` table, a missing column, a non-finite value, a bad date, or a path-shaped token. On validation failure it publishes nothing for that run. Writes go to `.<run_id>.parquet.partial`, then `fsync`, then `rename` in the same directory.

Default SQLite path: `/var/lib/warehouse/inbox/health/data.db`.

Place a copy (synthetic example):

```bash
install -m 0640 -o warehouse -g warehouse \
  /path/to/data.db /var/lib/warehouse/inbox/health/data.db
```

Override the path without putting secrets in the repo. On AIServer, as root:

```bash
install -d -m 0750 /etc/warehouse
install -m 0400 /dev/null /etc/warehouse/health.env
# then edit the file, still mode 0400, for example:
# WAREHOUSE_SQLITE_PATH=/var/lib/warehouse/inbox/health/data.db
```

Point the loader at it with `services.dataWarehouse.loaders.health.environmentFile = "/etc/warehouse/health.env";`. systemd reads that file as root. The unit runs as user `warehouse`.

Manual run (holds the same lock as the timer):

```bash
sudo flock /var/lib/warehouse/.write.lock \
  -c 'systemd-run --uid=warehouse --gid=warehouse --pipe --wait \
      -p ProtectSystem=strict -p PrivateTmp=yes \
      -- warehouse-load-health'
```

The supported path is the systemd unit, which already applies the lock and the sandbox:

```bash
sudo systemctl start warehouse-load-health.service
```

### Models

| Model | Materialization | Grain |
|-------|-----------------|--------|
| `stg_health__metrics` | view in schema `health` | one row per `metrics.id`, latest `_loaded_at` |
| `fct_health_daily` | table in schema `health` | one row per `local_date` and `kind` |
| `dim_metric_kind` | table in schema `health` | one row per `kind` |

Tests on the models: `unique` and `not_null` on keys, `accepted_values` on `kind`, `category`, and `unit` (the lists from personal_groktor's `MetricKind` and `default_unit`), `relationships` from the fact to the dimension, and a singular test that `local_date` equals the hive `dt`. Source `health.metrics` has freshness on `_loaded_at` (warn after 36 hours, error after 72). `warehouse-dbt.service` runs `dbt build` and then `dbt source freshness`.

`fct_health_daily` keeps the latest `recorded_at` when several sources share a day and a kind.

## Schedules

| Unit | Calendar | Notes |
|------|----------|--------|
| `warehouse-load-health.timer` | `02:15` America/Chicago | `Persistent=true`, `RandomizedDelaySec=5m` |
| `warehouse-dbt.timer` | `02:45` | also started `OnSuccess` of each loader |
| `restic-backups-warehouse.timer` | `03:30` | only if `backup.enable = true`; random delay 15m |
| `warehouse-restic-check.timer` | monthly | only if `backup.enable = true` |

DuckDB has one writer. Loader and dbt both take `flock /var/lib/warehouse/.write.lock`.

These clocks are defaults. See open questions.

## Add a source

1. Add a Rust loader crate under `pkgs/`, package it with `rustPlatform.buildRustPackage`, and expose it from the overlay in `flake.nix`.
2. Write Parquet to `raw/<source>/dt=YYYY-MM-DD/<run_id>.parquet` with `_loaded_at`, `_run_id`, `_source_file`, and `_loader_version`. Publish by temp file, `fsync`, and `rename`. Leave older files in place.
3. Register it on the host:

```nix
services.dataWarehouse.loaders.<name> = {
  script = lib.getExe pkgs.<loader>;
  onCalendar = "*-*-* 02:20:00";
  # environmentFile = "/etc/warehouse/<name>.env";
};
```

4. Add a staging view `stg_<source>__<entity>` (rename, cast, dedupe on the natural key, keep the latest `_loaded_at`), then `int_<topic>` for joins and `fct_<event>` / `dim_<thing>` marts. Put the DuckDB schema on the domain (`health`, `portfolio`, or `ops`).
5. Add `unique` and `not_null` on keys, `accepted_values` on kinds and units, and source freshness on `_loaded_at`.

The loader unit template is `warehouse-load-<name>.service`: user `warehouse`, `ProtectSystem=strict`, `ReadWritePaths` limited to the data dir, `ProtectHome`, `PrivateTmp`, `NoNewPrivileges`, empty `CapabilityBoundingSet`, `UMask=0027`. Fetching loaders may use the network. The health loader reads a local file.

## Query over Tailscale

```bash
ssh sam@aiserver.tail93ec7d.ts.net
duckdb -readonly /var/lib/warehouse/warehouse.duckdb
```

```sql
select local_date, kind, value, unit
from health.fct_health_daily
order by local_date desc
limit 20;
```

`duckdb -readonly` does not take the write lock. A build can still replace the file when it finishes, so rerun the query if DuckDB reports the file changed.

Raw files, before dbt has built:

```sql
select *
from read_parquet(
  '/var/lib/warehouse/raw/health/**/*.parquet',
  hive_partitioning = true
)
where dt >= DATE '2026-07-01';
```

A future UI or `dbt docs` site would bind `127.0.0.1` on a free port and sit behind a Caddy vhost such as `warehouse.tail93ec7d.ts.net`, the same pattern as `modules/services/ai-dispatch-caddy.nix`. Ports 8000 (Dispatch API), 8080 (Attic), and 8081 (Dispatch UI) are taken. Bind loopback only. `tailscale0` is a trusted firewall interface, so a socket on `0.0.0.0` would be reachable on the tailnet and, if a port were opened, on the LAN.

## Backups

`services.dataWarehouse.backup.enable` defaults to **false**.

When Sam turns it on, `services.restic.backups.warehouse` backs up:

- `/var/lib/warehouse/raw`
- `/var/lib/warehouse/dbt` (dbt `target/`, logs, and `dbt_packages` excluded)

`warehouse.duckdb` is left out. Rebuild it with `dbt build` after a restore. The NixOS restic module would run `checkOpts` on the same daily timer, so the monthly `restic check` is a separate unit, `warehouse-restic-check.service`.

| Setting | Value |
|---------|--------|
| Repository file | `/etc/restic/warehouse-repo` (root, mode `0400`) |
| Password file | `/etc/restic/warehouse-password` (root, mode `0400`, create this yourself) |
| `initialize` | `false` (a wrong target fails instead of creating a repo) |
| Keep | 7 daily, 4 weekly, 6 monthly |
| Check | monthly, only after `backup.enable = true` |

The module creates the repository file with the single line `PLACEHOLDER` if the file is absent, and it will not overwrite a file that is already there. Replace that line with the restic URL on the host. Create the password file on the host. Neither file belongs in git.

```bash
sudo install -m 0400 /dev/null /etc/restic/warehouse-password
# edit it, then:
# services.dataWarehouse.backup.enable = true;
```

Faster restores are optional and not wired up. A prepare step can `flock` and run:

```sql
EXPORT DATABASE '/var/lib/warehouse/export' (FORMAT parquet);
```

`export/` exists for that. Add it to the restic paths only if you decide the dump is worth the extra write.

Postgres is a later step, and only if several writers need to run at once. Today one flock covers the single DuckDB writer. This module does not install a warehouse database server. (AIServer already runs Postgres for Attic. That cluster is separate.)

## dbt-duckdb on this nixpkgs

Pinned nixpkgs (`flake.lock`, `34ab99075ac4f7e40cf037eef32cb1c360bb85e9`) has `pkgs.duckdb`, `python3Packages.duckdb`, and `python3Packages.dbt-core` 1.11.2. It has no `python3Packages.dbt-duckdb` (adapters present include postgres, bigquery, snowflake, redshift).

The module installs `python3.withPackages` with `duckdb`, and adds `dbt-duckdb` when the attribute exists. Until then `warehouse-dbt.service` exits with a message and the loader can still write Parquet.

Smallest fix: add `pkgs/development/python-modules/dbt-duckdb` as a `buildPythonPackage` on the same version line as `dbt-core` 1.11.2, depending on the existing `dbt-core` and `python3Packages.duckdb` (that Python package is built from `pkgs.duckdb`). That keeps one DuckDB file format for the CLI and for dbt. Do not vendor a second DuckDB.

## After `nh os switch`

```bash
systemctl list-timers 'warehouse-*'
systemctl list-timers 'restic-backups-warehouse*'
ss -tlnp | awk 'NR==1 || /LISTEN/'
ls -ld /var/lib/warehouse /var/lib/warehouse/raw /var/lib/warehouse/inbox/health
```

Expect the health and dbt timers. Expect no restic timer while `backup.enable` is false. `ss` should show the same listeners as before this module (no new warehouse port). `ls` should show `drwxr-x---` for the data dir and `drwxrws---` for `inbox/health`.

Until `/var/lib/warehouse/inbox/health/data.db` exists, `warehouse-load-health.service` fails on purpose. Until `dbt-duckdb` is packaged, `warehouse-dbt.service` fails on purpose.

## Rollback

Set `services.dataWarehouse.enable = false` and switch, or boot the previous NixOS generation. `/var/lib/warehouse` stays on disk either way. Turning the module off stops the timers and leaves the user, group, and files in place.

## Next sources (documented only)

### Portfolio

Intake is still an open question (manual Fidelity CSV into an inbox is the likely start).

Raw folders: `raw/portfolio_positions`, `raw/portfolio_transactions`.

Models to add later: `fct_position_snapshot`, `fct_transaction`, `dim_security`. In staging, mask account numbers to the last 4 characters.

### Ops

AI_Dispatch Postgres tables `token_usage` and `ai_requests`, via a read-only role. Incremental on `id` / `created_at`. Drop payload JSON. Model: `fct_llm_usage_daily`. Later: `fct_job_run`.

## Open questions for Sam

1. Health SQLite arrival: pull `data.db` from the laptop over Tailscale into `/var/lib/warehouse/inbox/health/data.db`, or run personal_groktor on AIServer?
2. Portfolio intake: manual Fidelity CSV dropped in an inbox, or something else? Account numbers get masked to the last 4 in staging when that loader exists.
3. Restic off-box target, and where the repo key lives. A second disk is the free option. The repo file is `/etc/restic/warehouse-repo` (currently the placeholder). The password file is `/etc/restic/warehouse-password` (you create it, mode `0400`).
4. Raw Parquet retention: keep forever, or prune after N years? Backups, once enabled, keep 7 daily / 4 weekly / 6 monthly. Say if that keep policy should change.
5. One `warehouse.duckdb` for health and later portfolio, or a separate file for health before portfolio lands? This module uses one file.
6. Should `dbt docs` or a query UI be reachable on the tailnet? If yes, loopback plus a Caddy vhost. 8000, 8080, and 8081 are taken.
7. Confirm the timer clocks (loader 02:15, dbt 02:45, restic 03:30, restic check monthly).
8. AIServer is the host (`hosts/AIServer`). Say if the warehouse should live somewhere else.
9. `accepted_values` for `kind` and `unit` follow personal_groktor's canonical list. An Amazfit row whose kind falls through to `MetricKind::Other` will fail `dbt build` until the list grows. Is that the list you want?
10. Source freshness is 36h warn / 72h error on `_loaded_at`. Adjust if the watch syncs less often.
11. `dbt-duckdb` is missing on the pinned nixpkgs. OK to add that one package in a follow-up (see above)?

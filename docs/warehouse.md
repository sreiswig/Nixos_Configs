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
| `inbox/health/` | `3750` | `sam:warehouse` (setgid and sticky; writer owns it; loader group can read and traverse) |
| `warehouse.duckdb` | `0640` | created by the dbt unit (`UMask=0027`) |

`sam` is in group `warehouse`, so `sam` can read the data dir. `sam` owns `inbox/health` and is the only user who can create or rename files there. The directory is mode `3750`: setgid so a file `sam` creates inherits group `warehouse`, sticky so only `sam` can replace `data.db`, and group read plus execute so the loader can traverse it. The loader runs as `warehouse` and only needs to read the snapshot. Raw files stay immutable: the loader never rewrites or deletes an existing Parquet file. A second run writes a new `<run_id>.parquet` under the same `dt=` directory. Staging dedupes.

`dt` is the America/Chicago calendar date of `recorded_at` (the host timezone in `modules/common`). The daily fact buckets on groktor's `metrics.day`, stored as `source_day`. `local_date` stays on the row. Overnight sleep can make `source_day` and `local_date` disagree in either direction (the Chicago date of `recorded_at` can fall on the day before or the day after groktor's `day`). A warn-severity test flags those rows.

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

The loader rejects a missing file, a missing `metrics` table, a missing column, a non-finite value, a bad date, or a path-shaped token. It also rejects a symlink or any non-regular `data.db`. On validation failure it publishes nothing for that run. Writes go to `.<run_id>.parquet.partial`, then `fsync`, then `rename` in the same directory.

The inbox file is a snapshot, not groktor's live database. Groktor keeps its own database in WAL mode. The export runs as `sam`, the only writer, and is the change in [personal_groktor PR #49](https://github.com/sreiswig/personal_groktor/pull/49). It builds one rollback-journal SQLite file at `.data.db.<random>.tmp` in `inbox/health`, mode `0640`, fsyncs it, then renames it to `data.db`. Setgid on the directory gives that file group `warehouse`, so the loader can read it. A later export renames a new temp file over the existing `data.db`. The loader never reads or deletes dotfiles or `.tmp` files.

The loader is read-only on the inbox. It `lstat`s `data.db`, opens it with `O_NOFOLLOW`, and checks that the fd is the same regular file and the same owner. Header bytes 18 and 19 must both be `1` (rollback journal). `2` is WAL mode and fails the load. If `data.db-wal`, `data.db-shm`, or `data.db-journal` exists beside `data.db`, the load fails and publishes nothing. The loader copies the verified fd into a mode `0600` file in a mode `0700` directory (`RUNTIME_DIRECTORY` when the unit sets one, otherwise a private temp directory) and opens only that copy with `immutable=1` and `SQLITE_OPEN_READ_ONLY`. SQLite reopens by path, so it must not be given the inbox path. After the copy, the loader `fstat`s the source fd again and fails if the inode, size, or mtime changed. `PRAGMA schema_version` and `PRAGMA integrity_check` then have to succeed. Anything other than `integrity_check` = `ok` fails the load and publishes nothing.

The private copy is removed when the load returns, including a Rust error. `SIGKILL` does not run that cleanup, and neither does `SIGTERM` if the process is killed before `Drop` runs. The unit does not set `RuntimeDirectoryPreserve`, so when `warehouse-load-health` stops, including after `SIGKILL`, systemd deletes `/run/warehouse-load-health` and any snapshot still in it. A manual run uses the temp directory, and those `warehouse-sqlite-*` directories stay until you remove them. At the start of a load, if `RUNTIME_DIRECTORY` is set, the loader deletes leftover direct children of that directory whose names start with `warehouse-sqlite-`, but only when `lstat` shows a real directory owned by the loader user and `O_NOFOLLOW` opens that same inode. A symlink, a regular file, another user's directory, or any other name is left in place.

Default SQLite path: `/var/lib/warehouse/inbox/health/data.db`.

Place a copy (synthetic example):

```bash
install -m 0640 -o sam -g warehouse \
  /path/to/rollback-snapshot.db /var/lib/warehouse/inbox/health/data.db
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
| `int_health__metrics_accepted` | view in schema `health` | staging rows inside the seed percent range |
| `fct_health_daily` | table in schema `health` | one row per `source_day` and `kind` |
| `dim_metric_kind` | table in schema `health` | one row per `kind` |

`fct_health_daily` does not keep a single latest row for every kind. groktor inserts with `INSERT OR IGNORE` on the UUID, so samples during a day and re-ingests are separate rows after dedupe on `id`. The seed `health_kind_agg` maps each kind to a rule:

- `sum` for additive kinds (`steps`, `active_calories_kcal`, `exercise_minutes`, plus distance, floors, and sleep durations)
- `latest` for point-in-time kinds (resting heart rate, HRV, heart rate, weight, percentages, scores). `value`, `unit`, and `_loaded_at` come from one row: latest `recorded_at`, then latest `_loaded_at`, then `metric_id`. `value_avg`, `value_min`, and `value_max` are stored for every kind.

A test fails the build when a staged kind has no seed row, and when a kind from the `accepted_values` list has no seed row. Staging renames unit aliases and converts the value into the kind's canonical unit when the factor is known: time (`s`, `min`, `hours`, alias `h`), length (`m`, `km`, `mile`, alias `mi`), energy (`kJ` to `kcal`, aliases `kcals` and capital `Cal`), and mass (`g`, `kg`, alias `kgs`, `lb`). `beats per minute`, `beats/minute`, and `beats/min` become `bpm`. `msec` becomes `ms`. `percent`, `pct`, and `percentage` become `%`. Lowercase `cal` is not an alias. Anything else stays as written, and an error-severity test fails the build when a row's unit still differs from the seed, so it is not summed into `fct_health_daily` unnoticed. `dim_metric_kind` keeps only rows whose unit is that canonical unit, and `assert_dim_metric_kind_unit` fails the build if a mismatched unit is stored on the dimension. A second test fails when one `source_day` and kind still has more than one unit. `accepted_values` on `kind` and `unit` is severity `warn` until an Amazfit or Zepp parser lands. There is no `unknown` unit.

Percent kinds (`canonical_unit` `%`) use a per-kind range on the seed `health_kind_agg` (`percent_min`, `percent_max`, `percent_allow_zero`, `percent_min_exclusive`). The build does not multiply a fraction by 100. `body_fat_pct` and `sleep_efficiency_pct` accept `0` (no reading) and every value from `1` through `100`. A value strictly between `0` and `1`, such as `0.2` or `0.93`, is out of range for those kinds. `spo2_pct` accepts only values greater than `1` and at most `100`, so `0`, `1`, and `0.2` all fail. `assert_stg_health_percent_scale` is the alarm: it fails `dbt build` when staging still has an out-of-range percent. Those rows stay in `stg_health__metrics` and are left out of `int_health__metrics_accepted`, which is what `fct_health_daily` and `dim_metric_kind` read. A plain `dbt run` without tests therefore does not publish them.

Other tests: `unique` and `not_null` on keys, `accepted_values` on `category`, `relationships` from the fact to the dimension, and a singular test that `local_date` equals the hive `dt`. Source `health.metrics` has freshness on `_loaded_at` (warn after 36 hours, error after 72). `warehouse-dbt.service` runs `dbt build` and then `dbt source freshness` when at least one Parquet file exists. `ExecCondition` exits 1 otherwise. Exit codes 1 through 254 skip the unit and leave it inactive. Exit 255 would mark it failed, so the guard does not use 255. An empty loader run (zero files) still has `OnSuccess`, and that condition skips dbt.

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

The loader unit template is `warehouse-load-<name>.service`, user `warehouse`. Sandbox on every warehouse unit: `ProtectSystem=strict`, `ReadWritePaths` limited to the data dir, `ProtectHome`, `PrivateTmp`, `NoNewPrivileges`, empty `CapabilityBoundingSet`, `SystemCallFilter=@system-service`, `UMask=0027`, `PrivateDevices`, `ProtectKernelTunables`, `ProtectKernelModules`, `ProtectKernelLogs`, `ProtectControlGroups`, `ProtectClock`, `ProtectHostname`, `ProtectProc=invisible`, `RestrictNamespaces`, `RestrictSUIDSGID`, `LockPersonality`, `RestrictRealtime`, `SystemCallArchitectures=native`. `MemoryDenyWriteExecute` is on loaders only. The dbt unit uses the same sandbox without that flag. Network is off unless the loader sets `network = true` (`PrivateNetwork` and `RestrictAddressFamilies=AF_UNIX` otherwise). The health loader reads a local file and leaves `network` at the default. A future AI_Dispatch Postgres loader would set `network = true`.

## Query over Tailscale

```bash
ssh sam@aiserver.tail93ec7d.ts.net
duckdb -readonly /var/lib/warehouse/warehouse.duckdb
```

```sql
select source_day, kind, value, unit
from health.fct_health_daily
order by source_day desc
limit 20;
```

A `duckdb -readonly` session fails while `warehouse-dbt.service` holds `/var/lib/warehouse/.write.lock`. That window is the 02:45 timer, usually finished by 03:00, plus the short run that starts when the 02:15 loader succeeds. Retry after the unit exits.

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

- `/var/lib/warehouse/raw` (in-progress `.<run_id>.parquet.partial` files excluded)
- `/var/lib/warehouse/dbt` (dbt `target/`, logs, and `dbt_packages` excluded)

`warehouse.duckdb` is left out. Rebuild it with `dbt build` after a restore. The NixOS restic module would run `checkOpts` on the same daily timer, so the monthly `restic check` is a separate unit, `warehouse-restic-check.service`.

| Setting | Value |
|---------|--------|
| Repository file | `/etc/restic/warehouse-repo` (root, mode `0400`) |
| Password file | `/etc/restic/warehouse-password` (root, mode `0400` or `0600`, create this yourself) |
| `initialize` | `false` (a wrong target fails instead of creating a repo) |
| Keep | 7 daily, 4 weekly, 6 monthly |
| Check | monthly, only after `backup.enable = true` |

The placeholder file is created only when `backup.enable` is true, and only if `/etc/restic/warehouse-repo` is absent. tmpfiles writes the single line `PLACEHOLDER` and does not overwrite a file that is already there. Replace that line with the restic URL on the host. Create the password file on the host. Neither file belongs in git. With `backup.enable` left false, that path is not created.

Turning `backup.enable` on still installs the restic timer. `restic-backups-warehouse` and `warehouse-restic-check` skip (`ExecCondition` exit 1, unit stays inactive) while the repository file is missing, empty, or whitespace-only, while the whole file is a quoted value (`""`, `'PLACEHOLDER'`, `"placeholder"`), or while the trimmed text is `PLACEHOLDER` or `TODO` in any case. A real repository string still passes that check. The same skip applies when the password file is missing or empty. Exit 255 is not used. Once the repository file is a real URL, `ExecStartPre` refuses to run unless the password file is owned by root and its mode is `0400` or `0600`. A wrong owner or mode `0644` fails that guard with a message and does not start restic. After you replace the placeholder and create the password file with those permissions, the next timer run performs the backup.

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

## dbt-duckdb

`pkgs/dbt-duckdb` is `dbt-duckdb` 1.11.1 from the PyPI sdist, built with `python313.pkgs.buildPythonPackage` against this nixpkgs' `dbt-core` 1.11.2 and `duckdb` 1.5.5. `python313Packages.duckdb` is built from `pkgs.duckdb` 1.5.5, so the CLI and dbt share one DuckDB. The adapter's own requirement is `duckdb>=1.0.0` and `dbt-core>=1.8.0`. Its `md` extra pins `duckdb==1.5.5`, the same version already in the pin. The module does not install a second DuckDB.

The default `python3` in this pin is 3.14. `dbt-semantic-interfaces`, which `dbt-core` depends on, is disabled on 3.14 because it uses pydantic v1. The warehouse Python environment is Python 3.13, the newest interpreter here that can build that stack. `dbt-common` in this pin requires `pathspec<1.1` while the set has pathspec 1.1.1, so the overlay relaxes that one bound on the existing `dbt-common` package.

`warehouse-dbt.service` sets `DBT_SEND_ANONYMOUS_USAGE_STATS=false` and `DO_NOT_TRACK=1`, and it runs with `PrivateNetwork=true` and `RestrictAddressFamilies=AF_UNIX`. The health loader uses the same network sandbox.

## After `nh os switch`

Start dbt once by hand before trusting the timer. That run imports `dbt-common` inside the unit, which is the check that the pathspec relax in the overlay is enough (the package import check does not load dbt's runtime deps the same way):

```bash
sudo systemctl start warehouse-dbt
journalctl -u warehouse-dbt -n 80 --no-pager
```

If `raw/` has no Parquet yet, the journal shows the skip line. `ExecCondition` exits 1, so systemd leaves the unit inactive and does not mark it failed. Put `data.db` in the inbox, start `warehouse-load-health`, then start `warehouse-dbt` again and confirm the journal shows `dbt build` finishing.

```bash
systemctl list-timers 'warehouse-*'
systemctl list-timers 'restic-backups-warehouse*'
ss -tlnp | awk 'NR==1 || /LISTEN/'
ls -ld /var/lib/warehouse /var/lib/warehouse/raw /var/lib/warehouse/inbox/health
systemd-analyze security warehouse-dbt
systemd-analyze security warehouse-load-health
```

Expect the health and dbt timers. Expect no restic timer while `backup.enable` is false. `ss` should show the same listeners as before this module (no new warehouse port). `ls` should show `drwxr-x---` for the data dir and `drwxrws---` for `inbox/health`. `systemd-analyze security` is the sandbox report for the dbt unit and the health loader.

Until `/var/lib/warehouse/inbox/health/data.db` exists, `warehouse-load-health.service` fails on purpose. With no Parquet under `raw/`, `warehouse-dbt.service` is skipped (`ExecCondition` exit 1) and stays inactive. Exit 255 would fail the unit.

## Rollback

Set `services.dataWarehouse.enable = false` and switch, or boot the previous NixOS generation. Either way `/var/lib/warehouse` persists. Turning the module off stops the timers and leaves the user, group, and files in place.

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
3. Restic off-box target, and where the repo key lives. A second disk is the free option. The repo file path is `/etc/restic/warehouse-repo`. tmpfiles writes `PLACEHOLDER` there only after `backup.enable = true`, and only if the file is absent. The password file is `/etc/restic/warehouse-password` (you create it, root, mode `0400` or `0600`). Do not point either path at a Nix store path.
4. Raw Parquet retention: keep forever, or prune after N years? Backups, once enabled, keep 7 daily / 4 weekly / 6 monthly. Say if that keep policy should change.
5. One `warehouse.duckdb` for health and later portfolio, or a separate file for health before portfolio lands? This module uses one file.
6. Should `dbt docs` or a query UI be reachable on the tailnet? If yes, loopback plus a Caddy vhost. 8000, 8080, and 8081 are taken.
7. Confirm the timer clocks (loader 02:15, dbt 02:45, restic 03:30, restic check monthly).
8. AIServer is the host (`hosts/AIServer`). Say if the warehouse should live somewhere else.
9. `accepted_values` for `kind` and `unit` warn until a device parser lands. A kind with no `health_kind_agg` row still fails `dbt build`. Are the seed rules and the warn lists what you want once Amazfit names show up?
10. Source freshness is 36h warn / 72h error on `_loaded_at`. Adjust if the watch syncs less often.
11. A re-ingest that mints a new UUID for the same observation double-counts summed kinds. personal_groktor has no unique key on `(kind, day, source)` (`INSERT OR IGNORE` is on `id` only). That fix belongs in groktor if you want it.

The aggregation rules per kind (seed `health_kind_agg`) and the daily grain (`source_day`, groktor's `metrics.day`) are Data Architect recommendations. Sam can override either one.

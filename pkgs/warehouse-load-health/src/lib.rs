//! Read personal_groktor's SQLite `metrics` table and append immutable Parquet.
//!
//! Layout: `<raw_root>/<source>/dt=YYYY-MM-DD/<run_id>.parquet`.
//! A rerun always uses a new `run_id`. Existing raw files are left in place.
//! `dt` is the America/Chicago calendar date of `recorded_at`.

use std::collections::{BTreeMap, HashSet};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

/// Linux `O_NOFOLLOW`. Opening the inbox must not follow a symlink.
const O_NOFOLLOW: i32 = 0o400000;

use arrow_array::{Date32Array, Float64Array, RecordBatch, StringArray, TimestampMicrosecondArray};
use arrow_schema::{DataType, Field, Schema, TimeUnit};
use chrono::{DateTime, Datelike, NaiveDate, Utc};
use chrono_tz::America::Chicago;
use parquet::arrow::ArrowWriter;
use parquet::basic::Compression;
use parquet::file::properties::WriterProperties;
use rusqlite::backup::{Backup, StepResult};
use rusqlite::{Connection, OpenFlags};

pub const LOADER_VERSION: &str = env!("CARGO_PKG_VERSION");
pub const SOURCE_DEFAULT: &str = "health";

const EXPECTED_COLUMNS: &[&str] = &[
    "id",
    "kind",
    "category",
    "recorded_at",
    "day",
    "value",
    "unit",
    "source",
    "raw_name",
    "notes",
];

#[derive(Debug)]
pub struct LoadError {
    message: String,
}

impl LoadError {
    fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }
}

impl std::fmt::Display for LoadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for LoadError {}

pub type LoadResult<T> = Result<T, LoadError>;

#[derive(Debug, Clone)]
pub struct LoadConfig {
    pub sqlite_path: PathBuf,
    pub raw_root: PathBuf,
    pub source: String,
}

impl LoadConfig {
    /// Flags override environment variables. `WAREHOUSE_DATA_DIR` fills in the
    /// sqlite inbox and raw root when those are not set on their own.
    pub fn from_args_and_env(args: &[String]) -> LoadResult<Self> {
        let data_dir = take_flag(args, "--data-dir")?
            .or_else(|| std::env::var("WAREHOUSE_DATA_DIR").ok())
            .unwrap_or_else(|| "/var/lib/warehouse".to_string());
        let data_dir = PathBuf::from(data_dir);

        let sqlite_path = take_flag(args, "--sqlite")?
            .or_else(|| std::env::var("WAREHOUSE_SQLITE_PATH").ok())
            .map(PathBuf::from)
            .unwrap_or_else(|| data_dir.join("inbox/health/data.db"));

        let raw_root = take_flag(args, "--raw-root")?
            .or_else(|| std::env::var("WAREHOUSE_RAW_ROOT").ok())
            .map(PathBuf::from)
            .unwrap_or_else(|| data_dir.join("raw"));

        let source = take_flag(args, "--source")?
            .or_else(|| std::env::var("WAREHOUSE_SOURCE").ok())
            .unwrap_or_else(|| SOURCE_DEFAULT.to_string());

        reject_unknown_flags(args)?;
        Ok(Self {
            sqlite_path,
            raw_root,
            source,
        })
    }
}

fn take_flag(args: &[String], name: &str) -> LoadResult<Option<String>> {
    let Some(idx) = args.iter().position(|arg| arg == name) else {
        return Ok(None);
    };
    match args.get(idx + 1) {
        Some(value) if !value.starts_with("--") => Ok(Some(value.clone())),
        _ => Err(LoadError::new(format!("missing value for {name}"))),
    }
}

fn reject_unknown_flags(args: &[String]) -> LoadResult<()> {
    let known = ["--sqlite", "--raw-root", "--source", "--data-dir", "--help"];
    let mut i = 0;
    while i < args.len() {
        let arg = &args[i];
        if arg == "--help" {
            i += 1;
            continue;
        }
        if let Some(name) = arg.strip_prefix("--") {
            if !known.contains(&arg.as_str()) {
                return Err(LoadError::new(format!("unknown argument --{name}")));
            }
            i += 2;
            continue;
        }
        return Err(LoadError::new(format!("unexpected argument {arg}")));
    }
    Ok(())
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LoadReport {
    pub run_id: String,
    pub rows: usize,
    pub files: Vec<PathBuf>,
}

#[derive(Debug, Clone)]
struct MetricRow {
    id: String,
    kind: String,
    category: String,
    recorded_at: DateTime<Utc>,
    source_day: NaiveDate,
    local_date: NaiveDate,
    value: f64,
    unit: String,
    source: String,
    raw_name: Option<String>,
    notes: Option<String>,
}

/// Load `metrics` and publish one Parquet file per Chicago-local date.
///
/// Files are written to a sibling temp name, fsynced, then renamed. Nothing
/// already present under `raw_root` is replaced or removed.
pub fn load(config: &LoadConfig) -> LoadResult<LoadReport> {
    validate_source_name(&config.source)?;
    let sqlite_path = require_sqlite(&config.sqlite_path)?;
    let rows = read_metrics(&sqlite_path)?;
    let run_id = new_run_id()?;
    let loaded_at = Utc::now();

    if rows.is_empty() {
        return Ok(LoadReport {
            run_id,
            rows: 0,
            files: Vec::new(),
        });
    }

    let mut by_date: BTreeMap<NaiveDate, Vec<MetricRow>> = BTreeMap::new();
    for row in rows {
        by_date.entry(row.local_date).or_default().push(row);
    }

    let source_root = config.raw_root.join(&config.source);
    fs::create_dir_all(&source_root).map_err(|e| {
        LoadError::new(format!(
            "create {}: {e}",
            source_root.display()
        ))
    })?;

    let mut staged: Vec<Staged> = Vec::new();
    let row_count = by_date.values().map(Vec::len).sum();
    for (local_date, group) in by_date {
        let dir = source_root.join(format!("dt={local_date}"));
        fs::create_dir_all(&dir).map_err(|e| {
            LoadError::new(format!("create {}: {e}", dir.display()))
        })?;
        let final_path = dir.join(format!("{run_id}.parquet"));
        if final_path.exists() {
            cleanup_temps(&staged);
            return Err(LoadError::new(format!(
                "refusing to overwrite {}",
                final_path.display()
            )));
        }
        let tmp_path = dir.join(format!(".{run_id}.parquet.partial"));
        if let Err(e) = write_group(
            &tmp_path,
            &group,
            &run_id,
            loaded_at,
            &sqlite_path,
        ) {
            cleanup_temps(&staged);
            let _ = fs::remove_file(&tmp_path);
            return Err(e);
        }
        staged.push(Staged {
            tmp_path,
            final_path,
            dir,
        });
    }

    let files = publish(staged)?;
    Ok(LoadReport {
        run_id,
        rows: row_count,
        files,
    })
}

struct Staged {
    tmp_path: PathBuf,
    final_path: PathBuf,
    dir: PathBuf,
}

fn cleanup_temps(staged: &[Staged]) {
    for staged in staged {
        let _ = fs::remove_file(&staged.tmp_path);
    }
}

fn publish(staged: Vec<Staged>) -> LoadResult<Vec<PathBuf>> {
    let mut published: Vec<Staged> = Vec::new();
    for file in staged {
        if file.final_path.exists() {
            let _ = fs::remove_file(&file.tmp_path);
            abort_publish(&published);
            return Err(LoadError::new(format!(
                "refusing to overwrite {}",
                file.final_path.display()
            )));
        }
        if let Err(e) = fs::rename(&file.tmp_path, &file.final_path) {
            abort_publish(&published);
            return Err(LoadError::new(format!(
                "rename {} -> {}: {e}",
                file.tmp_path.display(),
                file.final_path.display()
            )));
        }
        let _ = fsync_dir(&file.dir);
        published.push(file);
    }
    Ok(published.into_iter().map(|file| file.final_path).collect())
}

/// Drop files this call just renamed. Previous runs are not touched.
fn abort_publish(published: &[Staged]) {
    for file in published {
        let _ = fs::remove_file(&file.final_path);
    }
}

fn fsync_dir(path: &Path) -> std::io::Result<()> {
    let dir = File::open(path)?;
    dir.sync_all()
}

fn validate_source_name(source: &str) -> LoadResult<()> {
    let ok = !source.is_empty()
        && source.len() <= 64
        && source
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_')
        && source.chars().next().is_some_and(|c| c.is_ascii_lowercase());
    if ok {
        Ok(())
    } else {
        Err(LoadError::new(
            "source name must match [a-z][a-z0-9_]{0,63}",
        ))
    }
}

fn lexical_absolute(path: &Path) -> PathBuf {
    if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()
            .unwrap_or_else(|_| PathBuf::from("."))
            .join(path)
    }
}

/// Open a regular inbox file without following a symlink.
///
/// `lstat` rejects a symlink or anything that is not a regular file.
/// `O_NOFOLLOW` repeats that on the open, and `fstat` checks the fd is
/// still the same inode. Callers copy bytes from this fd. They do not
/// hand the path, or `/proc/self/fd/N`, to SQLite: bundled SQLite resolves
/// that link and opens the name again.
fn open_inbox_file(path: &Path) -> LoadResult<File> {
    let listed = match fs::symlink_metadata(path) {
        Ok(meta) => meta,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return Err(LoadError::new(format!(
                "sqlite file not found: {} (copy personal_groktor's data.db to the inbox path, or set WAREHOUSE_SQLITE_PATH)",
                path.display()
            )));
        }
        Err(e) => {
            return Err(LoadError::new(format!("stat {}: {e}", path.display())));
        }
    };
    if listed.file_type().is_symlink() {
        return Err(LoadError::new(format!(
            "refusing to follow symlink {} (inbox entries must be regular files)",
            path.display()
        )));
    }
    if !listed.file_type().is_file() {
        return Err(LoadError::new(format!(
            "refusing non-regular file {} (inbox entries must be regular files)",
            path.display()
        )));
    }
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(O_NOFOLLOW)
        .open(path)
        .map_err(|e| {
            LoadError::new(format!(
                "open {} without following links: {e}",
                path.display()
            ))
        })?;
    let opened = file.metadata().map_err(|e| {
        LoadError::new(format!("fstat {}: {e}", path.display()))
    })?;
    if opened.file_type().is_symlink() || !opened.file_type().is_file() {
        return Err(LoadError::new(format!(
            "refusing {} after open (not a regular file)",
            path.display()
        )));
    }
    if opened.dev() != listed.dev() || opened.ino() != listed.ino() {
        return Err(LoadError::new(format!(
            "refusing {} because the opened file does not match the directory entry",
            path.display()
        )));
    }
    Ok(file)
}

fn require_sqlite(path: &Path) -> LoadResult<PathBuf> {
    let _file = open_inbox_file(path)?;
    Ok(lexical_absolute(path))
}

/// Private copy of a verified inbox database. Dropped on every exit path,
/// including errors, so the temp files do not linger.
struct SqliteSnapshot {
    dir: PathBuf,
    db_path: PathBuf,
}

impl Drop for SqliteSnapshot {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn snapshot_base() -> PathBuf {
    if let Some(raw) = std::env::var_os("RUNTIME_DIRECTORY") {
        let text = raw.to_string_lossy();
        if let Some(first) = text.split(':').next() {
            if !first.is_empty() {
                return PathBuf::from(first);
            }
        }
    }
    std::env::temp_dir()
}

fn sidecar_path(path: &Path, suffix: &str) -> PathBuf {
    let mut name = path.as_os_str().to_os_string();
    name.push(suffix);
    PathBuf::from(name)
}

fn copy_fd_to(mut src: &File, dest: &Path) -> LoadResult<()> {
    let mut out = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(dest)
        .map_err(|e| LoadError::new(format!("create {}: {e}", dest.display())))?;
    io::copy(&mut src, &mut out)
        .map_err(|e| LoadError::new(format!("copy into {}: {e}", dest.display())))?;
    out.flush()
        .map_err(|e| LoadError::new(format!("flush {}: {e}", dest.display())))?;
    out.sync_all()
        .map_err(|e| LoadError::new(format!("fsync {}: {e}", dest.display())))?;
    Ok(())
}

struct WalIdentity {
    dev: u64,
    ino: u64,
}

/// Remove leftover snapshot directories in the systemd runtime dir.
/// SIGKILL cannot run Drop. systemd deletes the runtime dir when the unit
/// stops; this covers a retry that starts before that removal, and only when
/// RUNTIME_DIRECTORY is set so parallel tests do not share the sweep.
fn sweep_runtime_snapshots() {
    let raw = match std::env::var_os("RUNTIME_DIRECTORY") {
        Some(raw) => raw,
        None => return,
    };
    let text = raw.to_string_lossy();
    let Some(first) = text.split(':').next() else {
        return;
    };
    if first.is_empty() {
        return;
    }
    let Ok(entries) = fs::read_dir(first) else {
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if name.starts_with("warehouse-sqlite-") {
            let _ = fs::remove_dir_all(entry.path());
        }
    }
}

fn read_db_page_size(file: &mut File) -> LoadResult<u32> {
    file.seek(SeekFrom::Start(0))
        .map_err(|e| LoadError::new(format!("seek database header: {e}")))?;
    let mut hdr = [0u8; 100];
    file.read_exact(&mut hdr)
        .map_err(|e| LoadError::new(format!("read database header: {e}")))?;
    file.seek(SeekFrom::Start(0))
        .map_err(|e| LoadError::new(format!("rewind database: {e}")))?;
    if &hdr[0..16] != b"SQLite format 3\0" {
        return Err(LoadError::new(
            "inbox file is not a SQLite database",
        ));
    }
    let raw = u16::from_be_bytes([hdr[16], hdr[17]]) as u32;
    Ok(if raw == 1 { 65536 } else { raw })
}

/// SQLite WAL header checksum over the first 24 bytes.
/// `little_endian` selects the byte order of the input words.
fn wal_header_checksum(header24: &[u8], little_endian: bool) -> (u32, u32) {
    let mut s0 = 0u32;
    let mut s1 = 0u32;
    for chunk in header24.chunks_exact(8) {
        let (x0, x1) = if little_endian {
            (
                u32::from_le_bytes(chunk[0..4].try_into().unwrap()),
                u32::from_le_bytes(chunk[4..8].try_into().unwrap()),
            )
        } else {
            (
                u32::from_be_bytes(chunk[0..4].try_into().unwrap()),
                u32::from_be_bytes(chunk[4..8].try_into().unwrap()),
            )
        };
        s0 = s0.wrapping_add(x0.wrapping_add(s1));
        s1 = s1.wrapping_add(x1.wrapping_add(s0));
    }
    (s0, s1)
}

fn validate_wal_header(file: &mut File, db_page_size: u32) -> LoadResult<()> {
    file.seek(SeekFrom::Start(0))
        .map_err(|e| LoadError::new(format!("seek wal header: {e}")))?;
    let mut hdr = [0u8; 32];
    file.read_exact(&mut hdr)
        .map_err(|e| LoadError::new(format!("read wal header: {e}")))?;
    let magic = u32::from_be_bytes(hdr[0..4].try_into().unwrap());
    // 0x377f0682: checksum words are little-endian. 0x377f0683: big-endian.
    // The checksum itself is always stored big-endian (sqlite3Put4byte).
    let little_endian = match magic {
        0x377f_0682 => true,
        0x377f_0683 => false,
        _ => {
            return Err(LoadError::new(
                "wal header magic is not a SQLite wal",
            ));
        }
    };
    let version = u32::from_be_bytes(hdr[4..8].try_into().unwrap());
    if version != 3007000 {
        return Err(LoadError::new(format!(
            "wal header version {version} is not 3007000"
        )));
    }
    let page_size = u32::from_be_bytes(hdr[8..12].try_into().unwrap());
    if page_size != db_page_size {
        return Err(LoadError::new(format!(
            "wal page size {page_size} does not match the database page size {db_page_size}"
        )));
    }
    let (s0, s1) = wal_header_checksum(&hdr[..24], little_endian);
    // sqlite3Put4byte always stores the checksum big-endian.
    let stored0 = u32::from_be_bytes(hdr[24..28].try_into().unwrap());
    let stored1 = u32::from_be_bytes(hdr[28..32].try_into().unwrap());
    if s0 != stored0 || s1 != stored1 {
        return Err(LoadError::new(
            "wal header checksum does not match its salt",
        ));
    }
    Ok(())
}

fn sqlite_holds_inode(dev: u64, ino: u64) -> LoadResult<()> {
    let entries = fs::read_dir("/proc/self/fd").map_err(|e| {
        LoadError::new(format!("read /proc/self/fd: {e}"))
    })?;
    for entry in entries.flatten() {
        let fd_path = entry.path();
        let Ok(file) = File::open(&fd_path) else {
            continue;
        };
        let Ok(meta) = file.metadata() else {
            continue;
        };
        if meta.dev() == dev && meta.ino() == ino {
            return Ok(());
        }
    }
    Err(LoadError::new(
        "sqlite is not holding the verified inbox inode; refusing to publish",
    ))
}

fn recheck_wal(path: &Path, expected: &Option<WalIdentity>) -> LoadResult<()> {
    match (expected, fs::symlink_metadata(path)) {
        (None, Err(e)) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        (None, Ok(_)) => Err(LoadError::new(
            "wal appeared after the inbox database was verified; refusing to publish",
        )),
        (Some(_), Err(e)) if e.kind() == std::io::ErrorKind::NotFound => Err(LoadError::new(
            "wal disappeared during the read; refusing to publish",
        )),
        (Some(expected), Ok(meta)) => {
            if meta.file_type().is_symlink() || !meta.file_type().is_file() {
                return Err(LoadError::new(
                    "wal changed to a non-regular file during the read; refusing to publish",
                ));
            }
            if meta.dev() != expected.dev || meta.ino() != expected.ino {
                return Err(LoadError::new(
                    "wal inode changed during the read; refusing to publish",
                ));
            }
            Ok(())
        }
        (None, Err(e)) | (Some(_), Err(e)) => {
            Err(LoadError::new(format!("stat {}: {e}", path.display())))
        }
    }
}

fn metric_ids(conn: &Connection) -> Option<HashSet<String>> {
    let mut stmt = conn.prepare("SELECT id FROM metrics").ok()?;
    let rows = stmt.query_map([], |row| row.get::<_, String>(0)).ok()?;
    let mut ids = HashSet::new();
    for id in rows {
        ids.insert(id.ok()?);
    }
    Some(ids)
}

fn backup_consistent(src: &Connection, dest: &Path) -> LoadResult<()> {
    OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(dest)
        .map_err(|e| LoadError::new(format!("create {}: {e}", dest.display())))?;
    let mut dst = Connection::open(dest).map_err(|e| {
        LoadError::new(format!("open snapshot destination: {e}"))
    })?;
    let backup = Backup::new(src, &mut dst).map_err(|e| {
        LoadError::new(format!("start sqlite backup: {e}"))
    })?;
    let mut tries = 0u32;
    loop {
        match backup.step(-1).map_err(|e| {
            LoadError::new(format!("sqlite backup failed: {e}"))
        })? {
            StepResult::Done => break,
            StepResult::More => continue,
            StepResult::Busy | StepResult::Locked => {
                tries += 1;
                if tries > 50 {
                    return Err(LoadError::new(
                        "sqlite backup stayed busy; refusing to publish",
                    ));
                }
                std::thread::sleep(Duration::from_millis(20));
            }
            _ => {
                return Err(LoadError::new(
                    "sqlite backup returned an unexpected status; refusing to publish",
                ));
            }
        }
    }
    drop(backup);
    let mut stmt = dst.prepare("PRAGMA integrity_check").map_err(|e| {
        LoadError::new(format!("integrity_check prepare: {e}"))
    })?;
    let mut rows = stmt.query([]).map_err(|e| {
        LoadError::new(format!("integrity_check: {e}"))
    })?;
    let mut messages = Vec::new();
    while let Some(row) = rows.next().map_err(|e| {
        LoadError::new(format!("integrity_check: {e}"))
    })? {
        let message: String = row.get(0).map_err(|e| {
            LoadError::new(format!("integrity_check: {e}"))
        })?;
        messages.push(message);
    }
    if messages.as_slice() != ["ok"] {
        return Err(LoadError::new(format!(
            "integrity_check failed: {}",
            messages.join("; ")
        )));
    }
    Ok(())
}

/// Snapshot the inbox database with the SQLite backup API.
///
/// The inbox path is checked with lstat and O_NOFOLLOW first. SQLite then
/// opens that path with SQLITE_OPEN_READONLY and SQLITE_OPEN_NOFOLLOW, inside
/// a read transaction. The fd SQLite holds must still be the verified inode,
/// and the -wal inode must be unchanged. The backup writes one consistent
/// database into the private directory. immutable=1 is not used, because it
/// ignores a live -wal. A WAL read creates or updates the inbox -shm, so the
/// inbox directory has to be writable by this user.
///
/// A -wal is rejected when it is not a regular file, its owner differs from
/// data.db, its header magic, version, page size, or checksum is wrong, or
/// replaying it drops a row id that is already in the checkpointed database
/// file. That last rule is what stops a foreign -wal: SQLite would otherwise
/// apply any well-formed wal with the same page size.
fn snapshot_sqlite(db: &Path) -> LoadResult<SqliteSnapshot> {
    sweep_runtime_snapshots();
    let mut verified = open_inbox_file(db)?;
    let vmeta = verified.metadata().map_err(|e| {
        LoadError::new(format!("fstat {}: {e}", db.display()))
    })?;
    let dev = vmeta.dev();
    let ino = vmeta.ino();
    let uid = vmeta.uid();
    let page_size = read_db_page_size(&mut verified)?;

    let wal = sidecar_path(db, "-wal");
    let wal_id = match fs::symlink_metadata(&wal) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
        Err(e) => {
            return Err(LoadError::new(format!("stat {}: {e}", wal.display())));
        }
        Ok(meta) => {
            if meta.file_type().is_symlink() {
                return Err(LoadError::new(format!(
                    "refusing to follow symlink {} (wal sidecar must be a regular file)",
                    wal.display()
                )));
            }
            if !meta.file_type().is_file() {
                return Err(LoadError::new(format!(
                    "refusing non-regular file {} (wal sidecar must be a regular file)",
                    wal.display()
                )));
            }
            if meta.uid() != uid {
                return Err(LoadError::new(format!(
                    "wal owner {} does not match data.db owner {uid}",
                    meta.uid()
                )));
            }
            let mut wal_file = open_inbox_file(&wal)?;
            validate_wal_header(&mut wal_file, page_size).map_err(|e| {
                LoadError::new(format!("{}: {e}", wal.display()))
            })?;
            Some(WalIdentity {
                dev: meta.dev(),
                ino: meta.ino(),
            })
        }
    };

    let shm = sidecar_path(db, "-shm");
    if let Ok(meta) = fs::symlink_metadata(&shm) {
        if meta.file_type().is_symlink() || !meta.file_type().is_file() {
            return Err(LoadError::new(format!(
                "refusing non-regular or symlink shm {} (a WAL read needs a real -shm beside the database)",
                shm.display()
            )));
        }
    }

    let id = new_run_id()?;
    let dir = snapshot_base().join(format!("warehouse-sqlite-{id}"));
    let mut builder = fs::DirBuilder::new();
    builder.mode(0o700);
    builder
        .create(&dir)
        .map_err(|e| LoadError::new(format!("create {}: {e}", dir.display())))?;
    let snapshot = SqliteSnapshot {
        db_path: dir.join("data.db"),
        dir,
    };
    let checkpoint_path = snapshot.dir.join("checkpoint.db");
    copy_fd_to(&verified, &checkpoint_path)?;
    drop(verified);

    let src = Connection::open_with_flags(
        db,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NOFOLLOW,
    )
    .map_err(|e| {
        LoadError::new(format!(
            "open {} read-only without following links: {e}",
            db.display()
        ))
    })?;
    src.execute_batch("BEGIN").map_err(|e| {
        LoadError::new(format!("begin read transaction: {e}"))
    })?;
    let _ = src.query_row("PRAGMA schema_version", [], |row| row.get::<_, i64>(0));
    sqlite_holds_inode(dev, ino)?;
    recheck_wal(&wal, &wal_id)?;

    backup_consistent(&src, &snapshot.db_path)?;
    let _ = src.execute_batch("ROLLBACK");

    if wal_id.is_some() {
        if let Ok(base) = Connection::open_with_flags(
            &checkpoint_path,
            OpenFlags::SQLITE_OPEN_READ_ONLY,
        ) {
            if let Some(base_ids) = metric_ids(&base) {
                let snap = Connection::open_with_flags(
                    &snapshot.db_path,
                    OpenFlags::SQLITE_OPEN_READ_ONLY,
                )
                .map_err(|e| {
                    LoadError::new(format!("reopen snapshot: {e}"))
                })?;
                let snap_ids = metric_ids(&snap).ok_or_else(|| {
                    LoadError::new(
                        "wal does not belong to this database: snapshot has no metrics table",
                    )
                })?;
                if !base_ids.is_subset(&snap_ids) {
                    return Err(LoadError::new(
                        "wal does not belong to this database: checkpointed rows are missing after replay",
                    ));
                }
            }
        }
    }
    Ok(snapshot)
}

fn read_metrics(path: &Path) -> LoadResult<Vec<MetricRow>> {
    let snapshot = snapshot_sqlite(path)?;
    let conn = Connection::open_with_flags(
        &snapshot.db_path,
        OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .map_err(|e| {
        LoadError::new(format!(
            "open private copy of {} read-only: {e}",
            path.display()
        ))
    })?;
    let rows = read_metrics_conn(&conn)?;
    drop(conn);
    drop(snapshot);
    Ok(rows)
}

fn read_metrics_conn(conn: &Connection) -> LoadResult<Vec<MetricRow>> {
    conn.pragma_update(None, "query_only", "ON").map_err(|e| {
        LoadError::new(format!("set query_only: {e}"))
    })?;

    let mut present = Vec::new();
    {
        let mut info = conn
            .prepare("PRAGMA table_info(metrics)")
            .map_err(|e| LoadError::new(format!("read metrics schema: {e}")))?;
        let mut rows = info
            .query([])
            .map_err(|e| LoadError::new(format!("read metrics schema: {e}")))?;
        while let Some(row) = rows
            .next()
            .map_err(|e| LoadError::new(format!("read metrics schema: {e}")))?
        {
            let name: String = row
                .get(1)
                .map_err(|e| LoadError::new(format!("read metrics schema: {e}")))?;
            present.push(name);
        }
    }
    if present.is_empty() {
        return Err(LoadError::new(
            "sqlite has no metrics table (expected personal_groktor data.db)",
        ));
    }
    let missing: Vec<_> = EXPECTED_COLUMNS
        .iter()
        .filter(|col| !present.iter().any(|have| have == *col))
        .copied()
        .collect();
    if !missing.is_empty() {
        return Err(LoadError::new(format!(
            "metrics table is missing columns: {}",
            missing.join(", ")
        )));
    }

    let mut stmt = conn
        .prepare(
            "SELECT id, kind, category, recorded_at, day, value, unit, source, raw_name, notes
             FROM metrics
             ORDER BY day, kind, id",
        )
        .map_err(|e| LoadError::new(format!("query metrics: {e}")))?;
    let mut rows = stmt
        .query([])
        .map_err(|e| LoadError::new(format!("query metrics: {e}")))?;

    let mut out = Vec::new();
    let mut seen_ids = std::collections::BTreeSet::new();
    let mut index = 0usize;
    while let Some(row) = rows
        .next()
        .map_err(|e| LoadError::new(format!("read metrics row: {e}")))?
    {
        index += 1;
        let parsed = parse_row(index, &row)?;
        if !seen_ids.insert(parsed.id.clone()) {
            return Err(LoadError::new(format!(
                "row {index}: duplicate id {}",
                parsed.id
            )));
        }
        out.push(parsed);
    }
    Ok(out)
}

fn parse_row(index: usize, row: &rusqlite::Row<'_>) -> LoadResult<MetricRow> {
    let id: String = required_string(row, 0, index, "id")?;
    let kind: String = required_string(row, 1, index, "kind")?;
    let category: String = required_string(row, 2, index, "category")?;
    let recorded_raw: String = required_string(row, 3, index, "recorded_at")?;
    let day_raw: String = required_string(row, 4, index, "day")?;
    let value: f64 = row.get(5).map_err(|e| {
        LoadError::new(format!("row {index}: value is not a real number ({e})"))
    })?;
    let unit: String = required_string(row, 6, index, "unit")?;
    let source: String = required_string(row, 7, index, "source")?;
    let raw_name: Option<String> = optional_text(row, 8, index, "raw_name")?;
    let notes: Option<String> = optional_text(row, 9, index, "notes")?;

    validate_token(index, "id", &id, 80)?;
    validate_token(index, "kind", &kind, 128)?;
    validate_token(index, "category", &category, 64)?;
    // source, unit, raw_name, and notes are column values. They are not
    // used to build paths (the hive path uses the loader source name,
    // the Chicago date, and the run id).
    validate_data(index, "unit", &unit, 64)?;
    validate_data(index, "source", &source, 256)?;
    if let Some(name) = &raw_name {
        validate_data(index, "raw_name", name, 256)?;
    }
    if let Some(note) = &notes {
        validate_data(index, "notes", note, 2000)?;
    }
    if !value.is_finite() {
        return Err(LoadError::new(format!(
            "row {index}: value is not finite"
        )));
    }

    let recorded_at = DateTime::parse_from_rfc3339(&recorded_raw)
        .map(|dt| dt.with_timezone(&Utc))
        .map_err(|_| {
            LoadError::new(format!(
                "row {index}: recorded_at is not RFC3339 ({recorded_raw})"
            ))
        })?;
    let source_day = NaiveDate::parse_from_str(&day_raw, "%Y-%m-%d").map_err(|_| {
        LoadError::new(format!(
            "row {index}: day is not YYYY-MM-DD ({day_raw})"
        ))
    })?;
    let local_date = recorded_at.with_timezone(&Chicago).date_naive();

    Ok(MetricRow {
        id,
        kind,
        category,
        recorded_at,
        source_day,
        local_date,
        value,
        unit,
        source,
        raw_name,
        notes,
    })
}

fn required_string(
    row: &rusqlite::Row<'_>,
    idx: usize,
    index: usize,
    name: &str,
) -> LoadResult<String> {
    let value: Option<String> = row.get(idx).map_err(|e| {
        LoadError::new(format!("row {index}: {name} ({e})"))
    })?;
    match value {
        Some(text) if !text.trim().is_empty() => Ok(text),
        _ => Err(LoadError::new(format!("row {index}: {name} is empty"))),
    }
}

fn optional_text(
    row: &rusqlite::Row<'_>,
    idx: usize,
    index: usize,
    name: &str,
) -> LoadResult<Option<String>> {
    let value: Option<String> = row.get(idx).map_err(|e| {
        LoadError::new(format!("row {index}: {name} ({e})"))
    })?;
    Ok(value.filter(|text| !text.is_empty()))
}

fn validate_token(index: usize, name: &str, value: &str, max: usize) -> LoadResult<()> {
    validate_text(index, name, value, max)?;
    if value.chars().any(|c| c.is_whitespace()) {
        return Err(LoadError::new(format!(
            "row {index}: {name} contains whitespace"
        )));
    }
    Ok(())
}

fn validate_data(index: usize, name: &str, value: &str, max: usize) -> LoadResult<()> {
    if value.len() > max {
        return Err(LoadError::new(format!(
            "row {index}: {name} is longer than {max} bytes"
        )));
    }
    if value.chars().any(|c| c.is_control()) {
        return Err(LoadError::new(format!(
            "row {index}: {name} contains a control character"
        )));
    }
    Ok(())
}

fn validate_text(index: usize, name: &str, value: &str, max: usize) -> LoadResult<()> {
    if value.len() > max {
        return Err(LoadError::new(format!(
            "row {index}: {name} is longer than {max} bytes"
        )));
    }
    if value.chars().any(|c| c.is_control()) {
        return Err(LoadError::new(format!(
            "row {index}: {name} contains a control character"
        )));
    }
    if value.contains('/') || value.contains('\\') {
        return Err(LoadError::new(format!(
            "row {index}: {name} contains a path separator"
        )));
    }
    Ok(())
}

fn write_group(
    path: &Path,
    rows: &[MetricRow],
    run_id: &str,
    loaded_at: DateTime<Utc>,
    source_file: &Path,
) -> LoadResult<()> {
    let schema = parquet_schema();
    let batch = to_batch(&schema, rows, run_id, loaded_at, source_file)?;
    let file = File::create(path).map_err(|e| {
        LoadError::new(format!("create {}: {e}", path.display()))
    })?;
    let props = WriterProperties::builder()
        .set_compression(Compression::SNAPPY)
        .build();
    let mut writer = ArrowWriter::try_new(file, Arc::clone(&schema), Some(props))
        .map_err(|e| LoadError::new(format!("open parquet writer: {e}")))?;
    writer
        .write(&batch)
        .map_err(|e| LoadError::new(format!("write parquet: {e}")))?;
    writer
        .close()
        .map_err(|e| LoadError::new(format!("close parquet: {e}")))?;
    // close() drops the file without fsync. Reopen and sync the inode.
    let synced = File::open(path).map_err(|e| {
        LoadError::new(format!("reopen {} for fsync: {e}", path.display()))
    })?;
    synced
        .sync_all()
        .map_err(|e| LoadError::new(format!("fsync parquet: {e}")))?;
    Ok(())
}

fn parquet_schema() -> Arc<Schema> {
    let ts = DataType::Timestamp(TimeUnit::Microsecond, Some("UTC".into()));
    Arc::new(Schema::new(vec![
        Field::new("id", DataType::Utf8, false),
        Field::new("kind", DataType::Utf8, false),
        Field::new("category", DataType::Utf8, false),
        Field::new("recorded_at", ts.clone(), false),
        Field::new("source_day", DataType::Date32, false),
        Field::new("value", DataType::Float64, false),
        Field::new("unit", DataType::Utf8, false),
        Field::new("source", DataType::Utf8, false),
        Field::new("raw_name", DataType::Utf8, true),
        Field::new("notes", DataType::Utf8, true),
        Field::new("_loaded_at", ts, false),
        Field::new("_run_id", DataType::Utf8, false),
        Field::new("_source_file", DataType::Utf8, false),
        Field::new("_loader_version", DataType::Utf8, false),
    ]))
}

fn to_batch(
    schema: &Arc<Schema>,
    rows: &[MetricRow],
    run_id: &str,
    loaded_at: DateTime<Utc>,
    source_file: &Path,
) -> LoadResult<RecordBatch> {
    let epoch = NaiveDate::from_ymd_opt(1970, 1, 1).expect("unix epoch");
    let ids: Vec<&str> = rows.iter().map(|r| r.id.as_str()).collect();
    let kinds: Vec<&str> = rows.iter().map(|r| r.kind.as_str()).collect();
    let categories: Vec<&str> = rows.iter().map(|r| r.category.as_str()).collect();
    let recorded: Vec<i64> = rows
        .iter()
        .map(|r| r.recorded_at.timestamp_micros())
        .collect();
    let source_days: Vec<i32> = rows
        .iter()
        .map(|r| (r.source_day - epoch).num_days() as i32)
        .collect();
    let values: Vec<f64> = rows.iter().map(|r| r.value).collect();
    let units: Vec<&str> = rows.iter().map(|r| r.unit.as_str()).collect();
    let sources: Vec<&str> = rows.iter().map(|r| r.source.as_str()).collect();
    let raw_names: Vec<Option<String>> = rows.iter().map(|r| r.raw_name.clone()).collect();
    let notes: Vec<Option<String>> = rows.iter().map(|r| r.notes.clone()).collect();
    let loaded = loaded_at.timestamp_micros();
    let loaded_at_col = vec![loaded; rows.len()];
    let run_ids = vec![run_id; rows.len()];
    let source_files = vec![source_file.display().to_string(); rows.len()];
    let versions = vec![LOADER_VERSION; rows.len()];

    let recorded_array = TimestampMicrosecondArray::from(recorded).with_timezone("UTC");
    let loaded_array = TimestampMicrosecondArray::from(loaded_at_col).with_timezone("UTC");

    RecordBatch::try_new(
        Arc::clone(schema),
        vec![
            Arc::new(StringArray::from(ids)),
            Arc::new(StringArray::from(kinds)),
            Arc::new(StringArray::from(categories)),
            Arc::new(recorded_array),
            Arc::new(Date32Array::from(source_days)),
            Arc::new(Float64Array::from(values)),
            Arc::new(StringArray::from(units)),
            Arc::new(StringArray::from(sources)),
            Arc::new(StringArray::from(raw_names)),
            Arc::new(StringArray::from(notes)),
            Arc::new(loaded_array),
            Arc::new(StringArray::from(run_ids)),
            Arc::new(StringArray::from(source_files)),
            Arc::new(StringArray::from(versions)),
        ],
    )
    .map_err(|e| LoadError::new(format!("build record batch: {e}")))
}

fn new_run_id() -> LoadResult<String> {
    let mut bytes = [0u8; 16];
    getrandom::getrandom(&mut bytes)
        .map_err(|e| LoadError::new(format!("read random bytes: {e}")))?;
    let mut hex = String::with_capacity(32);
    for byte in bytes {
        hex.push_str(&format!("{byte:02x}"));
    }
    Ok(hex)
}

pub fn chicago_local_date(recorded_at: DateTime<Utc>) -> NaiveDate {
    recorded_at.with_timezone(&Chicago).date_naive()
}

/// Used by tests and by anyone checking that a timestamp landed on the expected partition.
pub fn partition_label(local_date: NaiveDate) -> String {
    format!(
        "dt={:04}-{:02}-{:02}",
        local_date.year(),
        local_date.month(),
        local_date.day()
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use parquet::arrow::arrow_reader::ParquetRecordBatchReaderBuilder;
    use rusqlite::params;

    fn fixture(dir: &Path, rows: &[(&str, &str, &str, &str, &str, f64, &str, &str)]) -> PathBuf {
        let path = dir.join("data.db");
        let conn = Connection::open(&path).unwrap();
        conn.execute_batch(
            "CREATE TABLE metrics (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                category TEXT NOT NULL,
                recorded_at TEXT NOT NULL,
                day TEXT NOT NULL,
                value REAL NOT NULL,
                unit TEXT NOT NULL,
                source TEXT NOT NULL,
                raw_name TEXT,
                notes TEXT
            );",
        )
        .unwrap();
        for (id, kind, category, recorded_at, day, value, unit, source) in rows {
            conn.execute(
                "INSERT INTO metrics
                    (id, kind, category, recorded_at, day, value, unit, source, raw_name, notes)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, NULL, NULL)",
                params![id, kind, category, recorded_at, day, value, unit, source],
            )
            .unwrap();
        }
        path
    }

    fn sample_row() -> (&'static str, &'static str, &'static str, &'static str, &'static str, f64, &'static str, &'static str)
    {
        (
            "11111111-1111-4111-8111-111111111111",
            "steps",
            "activity",
            "2026-07-21T03:30:00+00:00",
            "2026-07-21",
            9200.0,
            "count",
            "gadgetbridge:amazfit",
        )
    }

    #[test]
    fn chicago_date_crosses_midnight() {
        let recorded = DateTime::parse_from_rfc3339("2026-07-21T03:30:00+00:00")
            .unwrap()
            .with_timezone(&Utc);
        assert_eq!(
            chicago_local_date(recorded),
            NaiveDate::from_ymd_opt(2026, 7, 20).unwrap()
        );
    }

    #[test]
    fn writes_hive_partition_and_second_run_appends() {
        let tmp = tempfile_dir();
        let sqlite = fixture(&tmp, &[sample_row()]);
        let raw = tmp.join("raw");
        let config = LoadConfig {
            sqlite_path: sqlite.clone(),
            raw_root: raw.clone(),
            source: "health".into(),
        };
        let before = fs::read(&sqlite).unwrap();
        let first = load(&config).unwrap();
        assert_eq!(first.rows, 1);
        assert_eq!(first.files.len(), 1);
        let expected_dir = raw.join("health").join("dt=2026-07-20");
        assert_eq!(first.files[0].parent().unwrap(), expected_dir);
        assert!(first.files[0]
            .file_name()
            .unwrap()
            .to_string_lossy()
            .ends_with(".parquet"));
        assert!(fs::read_dir(&expected_dir)
            .unwrap()
            .all(|e| !e.unwrap().file_name().to_string_lossy().contains("partial")));
        let bytes = fs::read(&first.files[0]).unwrap();

        let file = File::open(&first.files[0]).unwrap();
        let reader = ParquetRecordBatchReaderBuilder::try_new(file)
            .unwrap()
            .build()
            .unwrap();
        let batches: Vec<_> = reader.collect::<Result<Vec<_>, _>>().unwrap();
        assert_eq!(batches.len(), 1);
        assert_eq!(batches[0].num_rows(), 1);
        let schema = batches[0].schema();
        for name in [
            "id",
            "kind",
            "value",
            "_loaded_at",
            "_run_id",
            "_source_file",
            "_loader_version",
            "source_day",
        ] {
            assert!(schema.column_with_name(name).is_some(), "missing {name}");
        }

        let second = load(&config).unwrap();
        assert_eq!(second.rows, 1);
        assert_ne!(first.run_id, second.run_id);
        assert_ne!(first.files[0], second.files[0]);
        assert_eq!(fs::read(&first.files[0]).unwrap(), bytes);
        assert_eq!(fs::read(&sqlite).unwrap(), before);
        let parquet_count = fs::read_dir(&expected_dir)
            .unwrap()
            .filter(|e| {
                e.as_ref()
                    .unwrap()
                    .path()
                    .extension()
                    .is_some_and(|ext| ext == "parquet")
            })
            .count();
        assert_eq!(parquet_count, 2);
    }

    #[test]
    fn rejects_non_finite_and_leaves_no_files() {
        let tmp = tempfile_dir();
        let path = tmp.join("data.db");
        let conn = Connection::open(&path).unwrap();
        conn.execute_batch(
            "CREATE TABLE metrics (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                category TEXT NOT NULL,
                recorded_at TEXT NOT NULL,
                day TEXT NOT NULL,
                value REAL NOT NULL,
                unit TEXT NOT NULL,
                source TEXT NOT NULL,
                raw_name TEXT,
                notes TEXT
            );",
        )
        .unwrap();
        // 1e999 is IEEE infinity. SQLite keeps it as a real; the loader must reject it.
        conn.execute_batch(
            "INSERT INTO metrics
                (id, kind, category, recorded_at, day, value, unit, source)
             VALUES ('abc', 'steps', 'activity', '2026-07-21T12:00:00+00:00', '2026-07-21', 1e999, 'count', 'csv');",
        )
        .unwrap();
        let err = load(&LoadConfig {
            sqlite_path: path,
            raw_root: tmp.join("raw"),
            source: "health".into(),
        })
        .unwrap_err();
        assert!(err.to_string().contains("not finite"), "{err}");
        assert!(!tmp.join("raw").join("health").exists() || dir_parquet_count(&tmp.join("raw")) == 0);
    }

    #[test]
    fn missing_column_fails_closed() {
        let tmp = tempfile_dir();
        let path = tmp.join("data.db");
        let conn = Connection::open(&path).unwrap();
        conn.execute_batch(
            "CREATE TABLE metrics (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                category TEXT NOT NULL,
                recorded_at TEXT NOT NULL,
                day TEXT NOT NULL,
                value REAL NOT NULL,
                source TEXT NOT NULL
            );",
        )
        .unwrap();
        let err = load(&LoadConfig {
            sqlite_path: path,
            raw_root: tmp.join("raw"),
            source: "health".into(),
        })
        .unwrap_err();
        assert!(err.to_string().contains("missing columns"), "{err}");
    }

    #[test]
    fn source_and_unit_text_is_data_not_a_path() {
        let tmp = tempfile_dir();
        let path = tmp.join("data.db");
        let conn = Connection::open(&path).unwrap();
        conn.execute_batch(
            "CREATE TABLE metrics (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                category TEXT NOT NULL,
                recorded_at TEXT NOT NULL,
                day TEXT NOT NULL,
                value REAL NOT NULL,
                unit TEXT NOT NULL,
                source TEXT NOT NULL,
                raw_name TEXT,
                notes TEXT
            );",
        )
        .unwrap();
        conn.execute(
            "INSERT INTO metrics
                (id, kind, category, recorded_at, day, value, unit, source, raw_name, notes)
             VALUES
                ('id-space', 'resting_heart_rate_bpm', 'heart',
                 '2026-07-21T15:00:00+00:00', '2026-07-21', 58,
                 'beats per minute', 'Apple Watch', 'Apple Watch', 'walk a/b'),
                ('id-slash', 'steps', 'activity',
                 '2026-07-21T16:00:00+00:00', '2026-07-21', 100,
                 'beats/minute', 'vendor/device', 'raw/name', 'note/with/slash')",
            [],
        )
        .unwrap();
        let report = load(&LoadConfig {
            sqlite_path: path,
            raw_root: tmp.join("raw"),
            source: "health".into(),
        })
        .unwrap();
        assert_eq!(report.rows, 2);
        assert_eq!(report.files.len(), 1);
        let file = &report.files[0];
        let rel = file.strip_prefix(tmp.join("raw")).unwrap();
        let rel_str = rel.to_string_lossy();
        assert!(rel_str.starts_with("health/dt="), "{rel_str}");
        assert!(!rel_str.contains("Apple"));
        assert!(!rel_str.contains("beats"));
        assert!(!rel_str.contains("vendor"));

        let opened = File::open(file).unwrap();
        let reader = ParquetRecordBatchReaderBuilder::try_new(opened)
            .unwrap()
            .build()
            .unwrap();
        let batches: Vec<_> = reader.collect::<Result<Vec<_>, _>>().unwrap();
        let batch = &batches[0];
        let sources = batch
            .column_by_name("source")
            .unwrap()
            .as_any()
            .downcast_ref::<arrow_array::StringArray>()
            .unwrap();
        let units = batch
            .column_by_name("unit")
            .unwrap()
            .as_any()
            .downcast_ref::<arrow_array::StringArray>()
            .unwrap();
        let mut saw_watch = false;
        let mut saw_slash = false;
        for i in 0..batch.num_rows() {
            if sources.value(i) == "Apple Watch" {
                saw_watch = true;
                assert_eq!(units.value(i), "beats per minute");
            }
            if sources.value(i) == "vendor/device" {
                saw_slash = true;
                assert_eq!(units.value(i), "beats/minute");
            }
        }
        assert!(saw_watch && saw_slash);
    }

    #[test]
    fn refuses_symlinked_sqlite_file() {
        let tmp = tempfile_dir();
        let real = fixture(&tmp, &[sample_row()]);
        let link = tmp.join("inbox.db");
        std::os::unix::fs::symlink(&real, &link).unwrap();
        let err = load(&LoadConfig {
            sqlite_path: link,
            raw_root: tmp.join("raw"),
            source: "health".into(),
        })
        .unwrap_err();
        assert!(err.to_string().contains("symlink"), "{err}");
        assert_eq!(dir_parquet_count(&tmp.join("raw")), 0);
    }

    fn sources_in(file: &Path) -> Vec<String> {
        let opened = File::open(file).unwrap();
        let reader = ParquetRecordBatchReaderBuilder::try_new(opened)
            .unwrap()
            .build()
            .unwrap();
        let batches: Vec<_> = reader.collect::<Result<Vec<_>, _>>().unwrap();
        let mut out = Vec::new();
        for batch in batches {
            let sources = batch
                .column_by_name("source")
                .unwrap()
                .as_any()
                .downcast_ref::<arrow_array::StringArray>()
                .unwrap();
            for i in 0..batch.num_rows() {
                out.push(sources.value(i).to_string());
            }
        }
        out
    }

    #[test]
    fn wal_rows_come_from_the_verified_sidecar() {
        let tmp = tempfile_dir();
        let path = tmp.join("data.db");
        let conn = Connection::open(&path).unwrap();
        conn.pragma_update(None, "journal_mode", "WAL").unwrap();
        conn.pragma_update(None, "wal_autocheckpoint", "0").unwrap();
        conn.execute_batch(
            "CREATE TABLE metrics (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                category TEXT NOT NULL,
                recorded_at TEXT NOT NULL,
                day TEXT NOT NULL,
                value REAL NOT NULL,
                unit TEXT NOT NULL,
                source TEXT NOT NULL,
                raw_name TEXT,
                notes TEXT
            );",
        )
        .unwrap();
        conn.execute(
            "INSERT INTO metrics
                (id, kind, category, recorded_at, day, value, unit, source)
             VALUES ('wal-1', 'steps', 'activity', '2026-07-21T15:00:00+00:00', '2026-07-21', 3, 'count', 'fromwal')",
            [],
        )
        .unwrap();
        assert!(
            sidecar_path(&path, "-wal").is_file(),
            "expected an uncheckpointed wal"
        );
        let report = load(&LoadConfig {
            sqlite_path: path,
            raw_root: tmp.join("raw"),
            source: "health".into(),
        })
        .unwrap();
        drop(conn);
        assert_eq!(report.rows, 1);
        assert_eq!(sources_in(&report.files[0]), vec!["fromwal".to_string()]);
    }

    fn metrics_schema(conn: &Connection) {
        conn.execute_batch(
            "CREATE TABLE metrics (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                category TEXT NOT NULL,
                recorded_at TEXT NOT NULL,
                day TEXT NOT NULL,
                value REAL NOT NULL,
                unit TEXT NOT NULL,
                source TEXT NOT NULL,
                raw_name TEXT,
                notes TEXT
            );",
        )
        .unwrap();
    }

    fn insert_seq(conn: &Connection, start: i64, end: i64, tag: &str) {
        for i in start..end {
            conn.execute(
                "INSERT INTO metrics
                    (id, kind, category, recorded_at, day, value, unit, source)
                 VALUES (?1, 'steps', 'activity', '2026-07-21T15:00:00+00:00', '2026-07-21', ?2, 'count', ?3)",
                rusqlite::params![format!("{tag}-{i:06}"), i as f64, tag],
            )
            .unwrap();
        }
    }

    #[test]
    fn torn_db_and_wal_fails_loudly() {
        let tmp = tempfile_dir();
        let src = tmp.join("src.db");
        let conn = Connection::open(&src).unwrap();
        conn.pragma_update(None, "journal_mode", "WAL").unwrap();
        conn.pragma_update(None, "wal_autocheckpoint", "0").unwrap();
        metrics_schema(&conn);
        insert_seq(&conn, 0, 1000, "own");
        conn.execute_batch("PRAGMA wal_checkpoint(TRUNCATE)").unwrap();
        let s0 = fs::read(&src).unwrap();
        insert_seq(&conn, 1000, 1200, "own");
        conn.execute_batch("PRAGMA wal_checkpoint(TRUNCATE)").unwrap();
        let s1 = fs::read(&src).unwrap();
        insert_seq(&conn, 1200, 1225, "own");
        let wal = fs::read(sidecar_path(&src, "-wal")).unwrap();
        drop(conn);

        let page = 4096usize;
        let cut = s0.len() - page;
        let mut torn = Vec::new();
        torn.extend_from_slice(&s0[..cut]);
        torn.extend_from_slice(&s1[cut..]);
        let inbox = tmp.join("inbox");
        fs::create_dir(&inbox).unwrap();
        let db = inbox.join("data.db");
        fs::write(&db, torn).unwrap();
        fs::write(sidecar_path(&db, "-wal"), wal).unwrap();
        match load(&LoadConfig {
            sqlite_path: db,
            raw_root: tmp.join("raw"),
            source: "health".into(),
        }) {
            Err(err) => {
                let msg = err.to_string();
                assert!(
                    msg.contains("integrity_check")
                        || msg.contains("malformed")
                        || msg.contains("belong")
                        || msg.contains("not a SQLite")
                        || msg.contains("refusing"),
                    "{msg}"
                );
                assert_eq!(dir_parquet_count(&tmp.join("raw")), 0);
            }
            Ok(report) => {
                let opened = File::open(&report.files[0]).unwrap();
                let reader = ParquetRecordBatchReaderBuilder::try_new(opened)
                    .unwrap()
                    .build()
                    .unwrap();
                let batches: Vec<_> = reader.collect::<Result<Vec<_>, _>>().unwrap();
                let mut values = Vec::new();
                for batch in batches {
                    let col = batch
                        .column_by_name("value")
                        .unwrap()
                        .as_any()
                        .downcast_ref::<arrow_array::Float64Array>()
                        .unwrap();
                    for i in 0..batch.num_rows() {
                        values.push(col.value(i) as i64);
                    }
                }
                values.sort_unstable();
                values.dedup();
                let max = *values.last().unwrap();
                let prefix: Vec<i64> = (0..=max).collect();
                assert_eq!(
                    values, prefix,
                    "torn snapshot published a gap instead of failing"
                );
            }
        }
    }

    #[test]
    fn foreign_wal_is_not_published() {
        let tmp = tempfile_dir();
        let own_path = tmp.join("own.db");
        let own = Connection::open(&own_path).unwrap();
        own.pragma_update(None, "journal_mode", "WAL").unwrap();
        own.pragma_update(None, "wal_autocheckpoint", "0").unwrap();
        metrics_schema(&own);
        insert_seq(&own, 0, 500, "own");
        own.execute_batch("PRAGMA wal_checkpoint(TRUNCATE)").unwrap();
        let inbox = tmp.join("inbox");
        fs::create_dir(&inbox).unwrap();
        let db = inbox.join("data.db");
        fs::copy(&own_path, &db).unwrap();
        drop(own);

        let foreign_path = tmp.join("foreign.db");
        let foreign = Connection::open(&foreign_path).unwrap();
        foreign.pragma_update(None, "journal_mode", "WAL").unwrap();
        foreign.pragma_update(None, "wal_autocheckpoint", "0").unwrap();
        metrics_schema(&foreign);
        foreign.execute_batch("PRAGMA wal_checkpoint(TRUNCATE)").unwrap();
        insert_seq(&foreign, 0, 700, "foreign");
        fs::copy(sidecar_path(&foreign_path, "-wal"), sidecar_path(&db, "-wal")).unwrap();
        drop(foreign);

        let err = load(&LoadConfig {
            sqlite_path: db,
            raw_root: tmp.join("raw"),
            source: "health".into(),
        })
        .unwrap_err();
        assert!(err.to_string().contains("belong"), "{err}");
        assert_eq!(dir_parquet_count(&tmp.join("raw")), 0);
    }

    #[test]
    fn live_writer_loads_are_consistent_or_loud() {
        let tmp = tempfile_dir();
        let db = tmp.join("data.db");
        let conn = Connection::open(&db).unwrap();
        conn.pragma_update(None, "journal_mode", "WAL").unwrap();
        conn.pragma_update(None, "wal_autocheckpoint", "20").unwrap();
        metrics_schema(&conn);
        insert_seq(&conn, 0, 100, "own");
        drop(conn);

        let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let stop_w = std::sync::Arc::clone(&stop);
        let db_w = db.clone();
        let writer = std::thread::spawn(move || {
            let conn = Connection::open(&db_w).unwrap();
            conn.busy_timeout(Duration::from_secs(2)).unwrap();
            conn.pragma_update(None, "wal_autocheckpoint", "20").unwrap();
            let mut next = 100i64;
            while !stop_w.load(std::sync::atomic::Ordering::Relaxed) {
                let tx = conn.unchecked_transaction().unwrap();
                insert_seq(&*tx, next, next + 25, "own");
                tx.commit().unwrap();
                next += 25;
                std::thread::sleep(Duration::from_millis(2));
            }
        });

        let mut saw_ok = 0u32;
        for n in 0..16 {
            match load(&LoadConfig {
                sqlite_path: db.clone(),
                raw_root: tmp.join(format!("raw-{n}")),
                source: "health".into(),
            }) {
                Ok(report) => {
                    assert_eq!(report.files.len(), 1);
                    let opened = File::open(&report.files[0]).unwrap();
                    let reader = ParquetRecordBatchReaderBuilder::try_new(opened)
                        .unwrap()
                        .build()
                        .unwrap();
                    let batches: Vec<_> = reader.collect::<Result<Vec<_>, _>>().unwrap();
                    let mut values = Vec::new();
                    for batch in batches {
                        let col = batch
                            .column_by_name("value")
                            .unwrap()
                            .as_any()
                            .downcast_ref::<arrow_array::Float64Array>()
                            .unwrap();
                        for i in 0..batch.num_rows() {
                            values.push(col.value(i) as i64);
                        }
                    }
                    values.sort_unstable();
                    values.dedup();
                    let max = *values.last().unwrap();
                    let prefix: Vec<i64> = (0..=max).collect();
                    assert_eq!(values, prefix, "silent gap in a successful load");
                    saw_ok += 1;
                }
                Err(err) => {
                    let msg = err.to_string();
                    assert!(!msg.is_empty());
                }
            }
        }
        stop.store(true, std::sync::atomic::Ordering::Relaxed);
        writer.join().unwrap();
        assert!(saw_ok > 0, "every load failed");
    }

    #[test]
    fn refuses_symlinked_wal() {
        let tmp = tempfile_dir();
        let path = fixture(&tmp, &[sample_row()]);
        let other = tmp.join("other.db");
        fs::copy(&path, &other).unwrap();
        std::os::unix::fs::symlink(&other, sidecar_path(&path, "-wal")).unwrap();
        let err = load(&LoadConfig {
            sqlite_path: path,
            raw_root: tmp.join("raw"),
            source: "health".into(),
        })
        .unwrap_err();
        assert!(err.to_string().contains("symlink"), "{err}");
        assert!(err.to_string().contains("wal"), "{err}");
        assert_eq!(dir_parquet_count(&tmp.join("raw")), 0);
    }

    #[test]
    fn refuses_non_regular_wal() {
        let tmp = tempfile_dir();
        let path = fixture(&tmp, &[sample_row()]);
        fs::create_dir(sidecar_path(&path, "-wal")).unwrap();
        let err = load(&LoadConfig {
            sqlite_path: path,
            raw_root: tmp.join("raw"),
            source: "health".into(),
        })
        .unwrap_err();
        assert!(err.to_string().contains("non-regular"), "{err}");
        assert_eq!(dir_parquet_count(&tmp.join("raw")), 0);
    }

    #[test]
    fn swap_race_never_reads_the_secret_database() {
        use std::sync::atomic::{AtomicBool, Ordering};
        use std::sync::Arc;

        let tmp = tempfile_dir();
        fs::create_dir_all(tmp.join("checked-dir")).unwrap();
        let checked = fixture(
            &tmp.join("checked-dir"),
            &[(
                "checked-id",
                "steps",
                "activity",
                "2026-07-21T15:00:00+00:00",
                "2026-07-21",
                1.0,
                "count",
                "checked",
            )],
        );
        let secret_dir = tmp.join("hidden");
        fs::create_dir_all(&secret_dir).unwrap();
        let secret = fixture(
            &secret_dir,
            &[(
                "secret-0",
                "steps",
                "activity",
                "2026-07-21T15:00:00+00:00",
                "2026-07-21",
                9.0,
                "count",
                "secret",
            )],
        );
        let inbox = tmp.join("inbox");
        fs::create_dir_all(&inbox).unwrap();
        let inbox_db = inbox.join("data.db");
        fs::hard_link(&checked, &inbox_db).unwrap();

        let stop = Arc::new(AtomicBool::new(false));
        let stop_thread = Arc::clone(&stop);
        let inbox_thread = inbox.clone();
        let checked_thread = checked.clone();
        let secret_thread = secret.clone();
        let swapper = std::thread::spawn(move || {
            let mut i = 0u64;
            while !stop_thread.load(Ordering::Relaxed) {
                i = i.wrapping_add(1);
                let tmp_a = inbox_thread.join(format!(".a{i}"));
                if fs::hard_link(&checked_thread, &tmp_a).is_ok() {
                    let _ = fs::rename(&tmp_a, inbox_thread.join("data.db"));
                }
                let tmp_s = inbox_thread.join(format!(".s{i}"));
                if std::os::unix::fs::symlink(&secret_thread, &tmp_s).is_ok() {
                    let _ = fs::rename(&tmp_s, inbox_thread.join("data.db"));
                }
            }
        });

        let mut saw_checked = 0u32;
        let mut saw_symlink_refusal = 0u32;
        let mut attempts = 0u32;
        while attempts < 800 && (saw_checked < 8 || saw_symlink_refusal < 8) {
            attempts += 1;
            let raw = tmp.join(format!("raw-{attempts}"));
            match load(&LoadConfig {
                sqlite_path: inbox_db.clone(),
                raw_root: raw,
                source: "health".into(),
            }) {
                Ok(report) => {
                    assert!(!report.files.is_empty());
                    for file in &report.files {
                        let sources = sources_in(file);
                        assert!(
                            sources.iter().all(|s| s == "checked"),
                            "secret database was read: {sources:?}"
                        );
                    }
                    saw_checked += 1;
                }
                Err(err) => {
                    let msg = err.to_string();
                    assert!(
                        !msg.contains("secret-0"),
                        "error leaked the secret database: {msg}"
                    );
                    if msg.contains("symlink") {
                        saw_symlink_refusal += 1;
                    }
                }
            }
        }
        stop.store(true, Ordering::Relaxed);
        swapper.join().unwrap();
        assert!(
            saw_checked > 0 && saw_symlink_refusal > 0,
            "race did not observe both a regular file and a symlink ({attempts} attempts, checked {saw_checked}, symlink {saw_symlink_refusal})"
        );
    }

    #[test]
    fn refuses_symlinked_directory() {
        let tmp = tempfile_dir();
        let dir = tmp.join("real-inbox");
        fs::create_dir(&dir).unwrap();
        let link = tmp.join("linked-inbox");
        std::os::unix::fs::symlink(&dir, &link).unwrap();
        let err = load(&LoadConfig {
            sqlite_path: link,
            raw_root: tmp.join("raw"),
            source: "health".into(),
        })
        .unwrap_err();
        assert!(err.to_string().contains("symlink"), "{err}");
        assert_eq!(dir_parquet_count(&tmp.join("raw")), 0);
    }

    #[test]
    fn missing_file_fails() {
        let tmp = tempfile_dir();
        let err = load(&LoadConfig {
            sqlite_path: tmp.join("missing.db"),
            raw_root: tmp.join("raw"),
            source: "health".into(),
        })
        .unwrap_err();
        assert!(err.to_string().contains("not found"), "{err}");
    }

    #[test]
    fn rejects_path_escape_in_source_name() {
        let tmp = tempfile_dir();
        let sqlite = fixture(&tmp, &[sample_row()]);
        let err = load(&LoadConfig {
            sqlite_path: sqlite,
            raw_root: tmp.join("raw"),
            source: "../raw".into(),
        })
        .unwrap_err();
        assert!(err.to_string().contains("source name"), "{err}");
    }

    fn dir_parquet_count(root: &Path) -> usize {
        if !root.exists() {
            return 0;
        }
        fn walk(path: &Path, n: &mut usize) {
            for entry in fs::read_dir(path).unwrap() {
                let entry = entry.unwrap();
                let p = entry.path();
                if p.is_dir() {
                    walk(&p, n);
                } else if p.extension().is_some_and(|ext| ext == "parquet") {
                    *n += 1;
                }
            }
        }
        let mut n = 0;
        walk(root, &mut n);
        n
    }

    fn tempfile_dir() -> PathBuf {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!(
            "warehouse-load-health-{}-{}",
            std::process::id(),
            nanos
        ));
        fs::create_dir_all(&dir).unwrap();
        dir
    }
}

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

/// Linux `O_NOFOLLOW`. Opening the inbox must not follow a symlink.
const O_NOFOLLOW: i32 = 0o400000;

use arrow_array::{Date32Array, Float64Array, RecordBatch, StringArray, TimestampMicrosecondArray};
use arrow_schema::{DataType, Field, Schema, TimeUnit};
use chrono::{DateTime, Datelike, NaiveDate, Utc};
use chrono_tz::America::Chicago;
use parquet::arrow::ArrowWriter;
use parquet::basic::Compression;
use parquet::file::properties::WriterProperties;
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
    src.seek(SeekFrom::Start(0))
        .map_err(|e| LoadError::new(format!("rewind {}: {e}", dest.display())))?;
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
    if raw == 1 {
        Ok(65536)
    } else {
        Ok(raw)
    }
}

struct FileStamp {
    dev: u64,
    ino: u64,
    len: u64,
    mtime: i64,
    mtime_nsec: i64,
    ctime: i64,
    ctime_nsec: i64,
}

fn stamp_of(meta: &std::fs::Metadata) -> FileStamp {
    FileStamp {
        dev: meta.dev(),
        ino: meta.ino(),
        len: meta.len(),
        mtime: meta.mtime(),
        mtime_nsec: meta.mtime_nsec(),
        ctime: meta.ctime(),
        ctime_nsec: meta.ctime_nsec(),
    }
}

fn stamps_match(a: &FileStamp, b: &FileStamp) -> bool {
    a.dev == b.dev
        && a.ino == b.ino
        && a.len == b.len
        && a.mtime == b.mtime
        && a.mtime_nsec == b.mtime_nsec
        && a.ctime == b.ctime
        && a.ctime_nsec == b.ctime_nsec
}

enum SnapFail {
    Fatal(LoadError),
    Changed(String),
}

fn checksum_words(bytes: &[u8], little_endian: bool, mut s0: u32, mut s1: u32) -> (u32, u32) {
    for chunk in bytes.chunks_exact(8) {
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

/// A wal must chain from the first byte to the last. SQLite would ignore
/// frames after the first bad one. This loader refuses that truncation.
fn validate_wal_frames(path: &Path, db_page_size: u32) -> LoadResult<()> {
    let mut file = File::open(path).map_err(|e| {
        LoadError::new(format!("open copied wal {}: {e}", path.display()))
    })?;
    let len = file.metadata().map_err(|e| {
        LoadError::new(format!("stat copied wal: {e}"))
    })?.len();
    if len < 32 {
        return Err(LoadError::new(
            "wal is shorter than a header; refusing to publish",
        ));
    }
    let mut hdr = [0u8; 32];
    file.read_exact(&mut hdr).map_err(|e| {
        LoadError::new(format!("read copied wal header: {e}"))
    })?;
    let magic = u32::from_be_bytes(hdr[0..4].try_into().unwrap());
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
    if page_size != db_page_size || page_size < 512 || !page_size.is_power_of_two() {
        return Err(LoadError::new(format!(
            "wal page size {page_size} does not match the database page size {db_page_size}"
        )));
    }
    let (s0, s1) = checksum_words(&hdr[..24], little_endian, 0, 0);
    let stored0 = u32::from_be_bytes(hdr[24..28].try_into().unwrap());
    let stored1 = u32::from_be_bytes(hdr[28..32].try_into().unwrap());
    if s0 != stored0 || s1 != stored1 {
        return Err(LoadError::new(
            "wal header checksum does not match its salt",
        ));
    }
    let frame_len = 24u64 + page_size as u64;
    let rest = len - 32;
    if rest % frame_len != 0 {
        return Err(LoadError::new(
            "wal does not end on a frame boundary; refusing a partial tail",
        ));
    }
    let salt = &hdr[16..24];
    let mut running0 = stored0;
    let mut running1 = stored1;
    let mut frame = vec![0u8; frame_len as usize];
    let frames = rest / frame_len;
    for index in 0..frames {
        file.read_exact(&mut frame).map_err(|e| {
            LoadError::new(format!("read wal frame {index}: {e}"))
        })?;
        if &frame[8..16] != salt {
            return Err(LoadError::new(format!(
                "wal frame {index} salt does not match the header; refusing a truncated chain"
            )));
        }
        let pgno = u32::from_be_bytes(frame[0..4].try_into().unwrap());
        if pgno == 0 {
            return Err(LoadError::new(format!(
                "wal frame {index} has page number 0; refusing a truncated chain"
            )));
        }
        (running0, running1) = checksum_words(&frame[..8], little_endian, running0, running1);
        (running0, running1) =
            checksum_words(&frame[24..], little_endian, running0, running1);
        let got0 = u32::from_be_bytes(frame[16..20].try_into().unwrap());
        let got1 = u32::from_be_bytes(frame[20..24].try_into().unwrap());
        if running0 != got0 || running1 != got1 {
            return Err(LoadError::new(format!(
                "wal frame {index} checksum does not chain; refusing a truncated wal"
            )));
        }
    }
    Ok(())
}

fn checkpoint_rows(path: &Path) -> LoadResult<HashSet<(String, u64, String)>> {
    let conn = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY).map_err(|e| {
        LoadError::new(format!(
            "open checkpointed copy {}: {e}",
            path.display()
        ))
    })?;
    let mut stmt = conn
        .prepare("SELECT id, value, source FROM metrics")
        .map_err(|e| {
            LoadError::new(format!(
                "wal does not belong to this database: checkpointed file has no metrics table ({e})"
            ))
        })?;
    let rows = stmt
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, f64>(1)?.to_bits(),
                row.get::<_, String>(2)?,
            ))
        })
        .map_err(|e| LoadError::new(format!("read checkpointed rows: {e}")))?;
    let mut out = HashSet::new();
    for row in rows {
        out.insert(row.map_err(|e| LoadError::new(format!("read checkpointed row: {e}")))?);
    }
    Ok(out)
}

fn snapshot_rows(path: &Path) -> LoadResult<HashSet<(String, u64, String)>> {
    let conn = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY).map_err(|e| {
        LoadError::new(format!("reopen snapshot: {e}"))
    })?;
    let _version: i64 = conn
        .query_row("PRAGMA schema_version", [], |row| row.get(0))
        .map_err(|e| LoadError::new(format!("schema_version: {e}")))?;
    let mut check = conn.prepare("PRAGMA integrity_check").map_err(|e| {
        LoadError::new(format!("integrity_check prepare: {e}"))
    })?;
    let mut messages = Vec::new();
    let mut query = check.query([]).map_err(|e| {
        LoadError::new(format!("integrity_check: {e}"))
    })?;
    while let Some(row) = query.next().map_err(|e| {
        LoadError::new(format!("integrity_check: {e}"))
    })? {
        messages.push(row.get::<_, String>(0).map_err(|e| {
            LoadError::new(format!("integrity_check: {e}"))
        })?);
    }
    drop(query);
    drop(check);
    if messages.as_slice() != ["ok"] {
        return Err(LoadError::new(format!(
            "integrity_check failed: {}",
            messages.join("; ")
        )));
    }
    let mut stmt = conn
        .prepare("SELECT id, value, source FROM metrics")
        .map_err(|e| LoadError::new(format!("read snapshot metrics: {e}")))?;
    let rows = stmt
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, f64>(1)?.to_bits(),
                row.get::<_, String>(2)?,
            ))
        })
        .map_err(|e| LoadError::new(format!("read snapshot rows: {e}")))?;
    let mut out = HashSet::new();
    for row in rows {
        out.insert(row.map_err(|e| LoadError::new(format!("read snapshot row: {e}")))?);
    }
    Ok(out)
}

/// Copy the verified inbox files, then open only that private copy.
///
/// A missing or zero-length -wal is not a wal. SQLite never opens the inbox,
/// so it cannot create -wal or -shm there. The loader does not need write
/// access to the inbox.
fn snapshot_sqlite(db: &Path) -> LoadResult<SqliteSnapshot> {
    sweep_runtime_snapshots();
    let mut why = String::from("inbox changed during copy");
    for _ in 0..8 {
        match snapshot_once(db) {
            Ok(snapshot) => return Ok(snapshot),
            Err(SnapFail::Changed(message)) => why = message,
            Err(SnapFail::Fatal(err)) => return Err(err),
        }
    }
    Err(LoadError::new(format!(
        "{why}; refusing to publish after 8 copy attempts"
    )))
}

fn snapshot_once(db: &Path) -> Result<SqliteSnapshot, SnapFail> {
    let mut db_file = open_inbox_file(db).map_err(SnapFail::Fatal)?;
    let db_stamp = stamp_of(&db_file.metadata().map_err(|e| {
        SnapFail::Fatal(LoadError::new(format!("fstat {}: {e}", db.display())))
    })?);
    let uid = db_file.metadata().map_err(|e| {
        SnapFail::Fatal(LoadError::new(format!("fstat {}: {e}", db.display())))
    })?.uid();
    let page_size = read_db_page_size(&mut db_file).map_err(SnapFail::Fatal)?;

    let wal_path = sidecar_path(db, "-wal");
    let wal_file = match fs::symlink_metadata(&wal_path) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
        Err(e) => {
            return Err(SnapFail::Fatal(LoadError::new(format!(
                "stat {}: {e}",
                wal_path.display()
            ))));
        }
        Ok(meta) => {
            if meta.file_type().is_symlink() {
                return Err(SnapFail::Fatal(LoadError::new(format!(
                    "refusing to follow symlink {} (wal sidecar must be a regular file)",
                    wal_path.display()
                ))));
            }
            if !meta.file_type().is_file() {
                return Err(SnapFail::Fatal(LoadError::new(format!(
                    "refusing non-regular file {} (wal sidecar must be a regular file)",
                    wal_path.display()
                ))));
            }
            if meta.len() == 0 {
                None
            } else {
                if meta.uid() != uid {
                    return Err(SnapFail::Fatal(LoadError::new(format!(
                        "wal owner {} does not match data.db owner {uid}",
                        meta.uid()
                    ))));
                }
                Some(open_inbox_file(&wal_path).map_err(SnapFail::Fatal)?)
            }
        }
    };
    let wal_stamp = match &wal_file {
        Some(file) => Some(stamp_of(&file.metadata().map_err(|e| {
            SnapFail::Fatal(LoadError::new(format!("fstat {}: {e}", wal_path.display())))
        })?)),
        None => None,
    };

    let id = new_run_id().map_err(SnapFail::Fatal)?;
    let dir = snapshot_base().join(format!("warehouse-sqlite-{id}"));
    let mut builder = fs::DirBuilder::new();
    builder.mode(0o700);
    builder.create(&dir).map_err(|e| {
        SnapFail::Fatal(LoadError::new(format!("create {}: {e}", dir.display())))
    })?;
    let snapshot = SqliteSnapshot {
        db_path: dir.join("data.db"),
        dir,
    };
    copy_fd_to(&db_file, &snapshot.db_path).map_err(SnapFail::Fatal)?;
    let checkpoint_path = snapshot.dir.join("checkpoint.db");
    copy_fd_to(&db_file, &checkpoint_path).map_err(SnapFail::Fatal)?;
    if let Some(file) = wal_file.as_ref() {
        copy_fd_to(file, &sidecar_path(&snapshot.db_path, "-wal")).map_err(SnapFail::Fatal)?;
    }

    let db_after = stamp_of(&db_file.metadata().map_err(|e| {
        SnapFail::Fatal(LoadError::new(format!("fstat {}: {e}", db.display())))
    })?);
    let db_path_now = fs::symlink_metadata(db).map_err(|e| {
        SnapFail::Fatal(LoadError::new(format!("stat {}: {e}", db.display())))
    })?;
    if db_path_now.file_type().is_symlink() || !db_path_now.file_type().is_file() {
        return Err(SnapFail::Changed(
            "database path changed to a non-regular file during copy".into(),
        ));
    }
    if !stamps_match(&db_stamp, &db_after) || !stamps_match(&db_stamp, &stamp_of(&db_path_now)) {
        return Err(SnapFail::Changed(
            "database inode, size, or timestamps changed during copy".into(),
        ));
    }
    match (&wal_file, &wal_stamp, fs::symlink_metadata(&wal_path)) {
        (None, None, Err(e)) if e.kind() == std::io::ErrorKind::NotFound => {}
        (None, None, Ok(meta)) if meta.file_type().is_file() && meta.len() == 0 => {}
        (None, None, Ok(_)) => {
            return Err(SnapFail::Changed(
                "wal appeared or changed during copy".into(),
            ));
        }
        (Some(file), Some(before), Ok(meta)) => {
            if meta.file_type().is_symlink() || !meta.file_type().is_file() {
                return Err(SnapFail::Changed(
                    "wal changed to a non-regular file during copy".into(),
                ));
            }
            let fd_now = stamp_of(&file.metadata().map_err(|e| {
                SnapFail::Fatal(LoadError::new(format!("fstat {}: {e}", wal_path.display())))
            })?);
            if !stamps_match(before, &fd_now) || !stamps_match(before, &stamp_of(&meta)) {
                return Err(SnapFail::Changed(
                    "wal inode, size, or timestamps changed during copy".into(),
                ));
            }
        }
        _ => {
            return Err(SnapFail::Changed(
                "wal presence changed during copy".into(),
            ));
        }
    }
    drop(db_file);
    drop(wal_file);

    if wal_stamp.is_some() {
        validate_wal_frames(&sidecar_path(&snapshot.db_path, "-wal"), page_size)
            .map_err(SnapFail::Fatal)?;
        let base = checkpoint_rows(&checkpoint_path).map_err(SnapFail::Fatal)?;
        let snap = snapshot_rows(&snapshot.db_path).map_err(SnapFail::Fatal)?;
        if !base.is_subset(&snap) {
            return Err(SnapFail::Fatal(LoadError::new(
                "wal does not belong to this database: a checkpointed row changed or disappeared",
            )));
        }
    } else {
        let conn = Connection::open_with_flags(
            &snapshot.db_path,
            OpenFlags::SQLITE_OPEN_READ_ONLY,
        )
        .map_err(|e| SnapFail::Fatal(LoadError::new(format!("open private copy: {e}"))))?;
        let _version: i64 = conn
            .query_row("PRAGMA schema_version", [], |row| row.get(0))
            .map_err(|e| SnapFail::Fatal(LoadError::new(format!("schema_version: {e}"))))?;
        let mut check = conn.prepare("PRAGMA integrity_check").map_err(|e| {
            SnapFail::Fatal(LoadError::new(format!("integrity_check prepare: {e}")))
        })?;
        let mut messages = Vec::new();
        let mut query = check.query([]).map_err(|e| {
            SnapFail::Fatal(LoadError::new(format!("integrity_check: {e}")))
        })?;
        while let Some(row) = query.next().map_err(|e| {
            SnapFail::Fatal(LoadError::new(format!("integrity_check: {e}")))
        })? {
            messages.push(row.get::<_, String>(0).map_err(|e| {
                SnapFail::Fatal(LoadError::new(format!("integrity_check: {e}")))
            })?);
        }
        if messages.as_slice() != ["ok"] {
            return Err(SnapFail::Fatal(LoadError::new(format!(
                "integrity_check failed: {}",
                messages.join("; ")
            ))));
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
        conn.execute_batch("PRAGMA wal_checkpoint(TRUNCATE)").unwrap();
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
        conn.execute_batch("PRAGMA wal_checkpoint(TRUNCATE)").unwrap();
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
    fn checkpointed_wal_without_sidecar_loads_twice() {
        let tmp = tempfile_dir();
        let path = tmp.join("data.db");
        let conn = Connection::open(&path).unwrap();
        conn.pragma_update(None, "journal_mode", "WAL").unwrap();
        metrics_schema(&conn);
        insert_seq(&conn, 0, 4, "own");
        conn.execute_batch("PRAGMA wal_checkpoint(TRUNCATE)").unwrap();
        drop(conn);
        let _ = fs::remove_file(sidecar_path(&path, "-wal"));
        let _ = fs::remove_file(sidecar_path(&path, "-shm"));
        for _ in 0..2 {
            let report = load(&LoadConfig {
                sqlite_path: path.clone(),
                raw_root: tmp.join("raw"),
                source: "health".into(),
            })
            .unwrap();
            assert_eq!(report.rows, 4);
            assert!(!sidecar_path(&path, "-wal").exists());
            assert!(!sidecar_path(&path, "-shm").exists());
        }
    }

    #[test]
    fn zero_byte_wal_is_treated_as_absent() {
        let tmp = tempfile_dir();
        let path = tmp.join("data.db");
        let conn = Connection::open(&path).unwrap();
        conn.pragma_update(None, "journal_mode", "WAL").unwrap();
        metrics_schema(&conn);
        insert_seq(&conn, 0, 2, "own");
        conn.execute_batch("PRAGMA wal_checkpoint(TRUNCATE)").unwrap();
        drop(conn);
        let _ = fs::remove_file(sidecar_path(&path, "-wal"));
        let _ = fs::remove_file(sidecar_path(&path, "-shm"));
        fs::write(sidecar_path(&path, "-wal"), b"").unwrap();
        let report = load(&LoadConfig {
            sqlite_path: path.clone(),
            raw_root: tmp.join("raw"),
            source: "health".into(),
        })
        .unwrap();
        assert_eq!(report.rows, 2);
        assert_eq!(fs::metadata(sidecar_path(&path, "-wal")).unwrap().len(), 0);
        assert!(!sidecar_path(&path, "-shm").exists());
    }

    fn value_rewriting_wal(dir: &Path) -> (PathBuf, PathBuf) {
        fs::create_dir_all(dir).unwrap();
        let live = dir.join("live.db");
        let conn = Connection::open(&live).unwrap();
        conn.pragma_update(None, "journal_mode", "WAL").unwrap();
        conn.pragma_update(None, "wal_autocheckpoint", "0").unwrap();
        metrics_schema(&conn);
        insert_seq(&conn, 0, 250, "own");
        conn.execute_batch("PRAGMA wal_checkpoint(TRUNCATE)").unwrap();
        let db_bytes = fs::read(&live).unwrap();
        conn.execute("UPDATE metrics SET value = 999999, source = 'forged'", [])
            .unwrap();
        let wal_bytes = fs::read(sidecar_path(&live, "-wal")).unwrap();
        drop(conn);
        let db = dir.join("data.db");
        let wal = sidecar_path(&db, "-wal");
        fs::write(&db, db_bytes).unwrap();
        fs::write(&wal, &wal_bytes).unwrap();
        (db, wal)
    }

    #[test]
    fn forged_same_rowid_wal_is_not_published() {
        let tmp = tempfile_dir();
        let (db, _wal) = value_rewriting_wal(&tmp.join("pair"));
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
    fn wal_swap_does_not_publish_forged_rows() {
        use std::sync::atomic::{AtomicBool, Ordering};
        use std::sync::Arc;

        let tmp = tempfile_dir();
        let (db, forged) = value_rewriting_wal(&tmp.join("forged"));
        let good_dir = tmp.join("good");
        fs::create_dir_all(&good_dir).unwrap();
        let good_db = good_dir.join("data.db");
        fs::copy(&db, &good_db).unwrap();
        let good = Connection::open(&good_db).unwrap();
        good.pragma_update(None, "journal_mode", "WAL").unwrap();
        good.pragma_update(None, "wal_autocheckpoint", "0").unwrap();
        insert_seq(&good, 250, 260, "own");
        let good_wal = tmp.join("good.wal");
        fs::copy(sidecar_path(&good_db, "-wal"), &good_wal).expect("append wal");
        drop(good);

        let inbox = tmp.join("inbox");
        fs::create_dir_all(&inbox).unwrap();
        let inbox_db = inbox.join("data.db");
        fs::copy(&db, &inbox_db).unwrap();
        fs::copy(&good_wal, sidecar_path(&inbox_db, "-wal")).unwrap();

        let stop = Arc::new(AtomicBool::new(false));
        let stop_t = Arc::clone(&stop);
        let target = sidecar_path(&inbox_db, "-wal");
        let a = good_wal.clone();
        let b = forged.clone();
        let swapper = std::thread::spawn(move || {
            let mut i = 0u64;
            while !stop_t.load(Ordering::Relaxed) {
                let src = if i % 2 == 0 { &a } else { &b };
                let tmp_name = target.with_extension(format!("tmp{i}"));
                let _ = fs::copy(src, &tmp_name);
                let _ = fs::rename(&tmp_name, &target);
                i = i.wrapping_add(1);
            }
        });
        for n in 0..24 {
            if let Ok(report) = load(&LoadConfig {
                sqlite_path: inbox_db.clone(),
                raw_root: tmp.join(format!("raw-{n}")),
                source: "health".into(),
            }) {
                for file in &report.files {
                    let sources = sources_in(file);
                    assert!(
                        sources.iter().all(|s| s == "own"),
                        "forged wal was published: {sources:?}"
                    );
                }
            }
        }
        stop.store(true, Ordering::Relaxed);
        swapper.join().unwrap();
    }

    #[test]
    fn planted_wal_is_not_published() {
        use std::sync::atomic::{AtomicBool, Ordering};
        use std::sync::Arc;

        let tmp = tempfile_dir();
        let (db, forged) = value_rewriting_wal(&tmp.join("forged"));
        let inbox = tmp.join("inbox");
        fs::create_dir_all(&inbox).unwrap();
        let inbox_db = inbox.join("data.db");
        fs::copy(&db, &inbox_db).unwrap();
        let wal = sidecar_path(&inbox_db, "-wal");

        let stop = Arc::new(AtomicBool::new(false));
        let stop_t = Arc::clone(&stop);
        let forged_t = forged.clone();
        let wal_t = wal.clone();
        let planter = std::thread::spawn(move || {
            while !stop_t.load(Ordering::Relaxed) {
                let tmp_name = wal_t.with_extension("plant");
                let _ = fs::copy(&forged_t, &tmp_name);
                let _ = fs::rename(&tmp_name, &wal_t);
                let _ = fs::remove_file(&wal_t);
            }
        });
        for n in 0..24 {
            if let Ok(report) = load(&LoadConfig {
                sqlite_path: inbox_db.clone(),
                raw_root: tmp.join(format!("raw-{n}")),
                source: "health".into(),
            }) {
                for file in &report.files {
                    let sources = sources_in(file);
                    assert!(
                        sources.iter().all(|s| s == "own"),
                        "planted wal was published: {sources:?}"
                    );
                }
            }
        }
        stop.store(true, Ordering::Relaxed);
        planter.join().unwrap();
    }

    #[test]
    fn broken_wal_frame_is_rejected() {
        let tmp = tempfile_dir();
        let path = tmp.join("data.db");
        let conn = Connection::open(&path).unwrap();
        conn.pragma_update(None, "journal_mode", "WAL").unwrap();
        conn.pragma_update(None, "wal_autocheckpoint", "0").unwrap();
        metrics_schema(&conn);
        conn.execute_batch("PRAGMA wal_checkpoint(TRUNCATE)").unwrap();
        insert_seq(&conn, 0, 4, "own");
        let wal_path = sidecar_path(&path, "-wal");
        let mut bytes = fs::read(&wal_path).unwrap();
        drop(conn);
        assert!(bytes.len() > 80, "wal too short to hold a frame");
        let original = bytes.clone();
        bytes[32 + 24 + 8] ^= 0xff;
        fs::write(&wal_path, &bytes).unwrap();
        let err = load(&LoadConfig {
            sqlite_path: path.clone(),
            raw_root: tmp.join("raw-flip"),
            source: "health".into(),
        })
        .unwrap_err();
        let msg = err.to_string();
        assert!(
            msg.contains("checksum") || msg.contains("chain") || msg.contains("integrity_check"),
            "{msg}"
        );
        assert_eq!(dir_parquet_count(&tmp.join("raw-flip")), 0);

        let mut tail = original;
        tail.pop();
        fs::write(&wal_path, &tail).unwrap();
        let err = load(&LoadConfig {
            sqlite_path: path,
            raw_root: tmp.join("raw-tail"),
            source: "health".into(),
        })
        .unwrap_err();
        let msg = err.to_string();
        assert!(
            msg.contains("frame boundary") || msg.contains("partial") || msg.contains("checksum"),
            "{msg}"
        );
        assert_eq!(dir_parquet_count(&tmp.join("raw-tail")), 0);
    }

    #[test]
    fn wal_with_no_checkpointed_metrics_table_is_rejected() {
        let tmp = tempfile_dir();
        let path = tmp.join("data.db");
        let conn = Connection::open(&path).unwrap();
        conn.pragma_update(None, "journal_mode", "WAL").unwrap();
        conn.pragma_update(None, "wal_autocheckpoint", "0").unwrap();
        conn.execute_batch("CREATE TABLE other (id INTEGER PRIMARY KEY); INSERT INTO other VALUES (1);")
            .unwrap();
        conn.execute_batch("PRAGMA wal_checkpoint(TRUNCATE)").unwrap();
        metrics_schema(&conn);
        insert_seq(&conn, 0, 3, "foreign");
        let db_bytes = fs::read(&path).unwrap();
        let wal_bytes = fs::read(sidecar_path(&path, "-wal")).unwrap();
        assert!(wal_bytes.len() > 32, "expected the metrics table to live in the wal");
        drop(conn);
        let inbox = tmp.join("inbox");
        fs::create_dir(&inbox).unwrap();
        let db = inbox.join("data.db");
        fs::write(&db, db_bytes).unwrap();
        fs::write(sidecar_path(&db, "-wal"), wal_bytes).unwrap();
        let err = load(&LoadConfig {
            sqlite_path: db,
            raw_root: tmp.join("raw"),
            source: "health".into(),
        })
        .unwrap_err();
        assert!(err.to_string().contains("no metrics table"), "{err}");
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
            conn.busy_timeout(std::time::Duration::from_secs(2)).unwrap();
            conn.pragma_update(None, "wal_autocheckpoint", "20").unwrap();
            let mut next = 100i64;
            while !stop_w.load(std::sync::atomic::Ordering::Relaxed) {
                let tx = conn.unchecked_transaction().unwrap();
                insert_seq(&*tx, next, next + 25, "own");
                tx.commit().unwrap();
                next += 25;
                std::thread::sleep(std::time::Duration::from_millis(2));
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

        let assert_not_secret = |raw: &Path| {
            match load(&LoadConfig {
                sqlite_path: inbox_db.clone(),
                raw_root: raw.to_path_buf(),
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
                    true
                }
                Err(err) => {
                    let msg = err.to_string();
                    assert!(
                        !msg.contains("secret-0"),
                        "error leaked the secret database: {msg}"
                    );
                    false
                }
            }
        };

        // Each good file is a new inode. Renaming a second hardlink of the
        // same inode is a no-op and leaks the temp link until EMLINK, after
        // which the inbox stays a symlink and the race never sees a database.
        let install_checked = |name: &str| {
            let fresh = inbox.join(name);
            fs::copy(&checked, &fresh).unwrap();
            fs::rename(&fresh, &inbox_db).unwrap();
        };

        for n in 0..4 {
            install_checked(&format!(".good{n}"));
            assert!(
                assert_not_secret(&tmp.join(format!("stable-{n}"))),
                "stable regular file did not load"
            );
            let link = inbox.join(format!(".link{n}"));
            std::os::unix::fs::symlink(&secret, &link).unwrap();
            fs::rename(&link, &inbox_db).unwrap();
            assert!(
                !assert_not_secret(&tmp.join(format!("link-{n}"))),
                "symlink was published"
            );
        }

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
                if fs::copy(&checked_thread, &tmp_a).is_ok() {
                    let _ = fs::rename(&tmp_a, inbox_thread.join("data.db"));
                    let _ = fs::remove_file(&tmp_a);
                }
                let tmp_s = inbox_thread.join(format!(".s{i}"));
                if std::os::unix::fs::symlink(&secret_thread, &tmp_s).is_ok() {
                    let _ = fs::rename(&tmp_s, inbox_thread.join("data.db"));
                    let _ = fs::remove_file(&tmp_s);
                }
            }
        });
        for n in 0..40 {
            let _ = assert_not_secret(&tmp.join(format!("race-{n}")));
        }
        stop.store(true, Ordering::Relaxed);
        swapper.join().unwrap();
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

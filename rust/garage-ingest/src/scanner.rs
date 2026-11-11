//! Counting a source's items before it is ingested: `ingest/scanner.py`.
//!
//! The scan is quick and opens as little as it can. What it counts depends on the source's kind:
//! indexable files for `filesystem` and `git` (the same rules as the walk, so the count is what a
//! run will see), threads or rows for `sqlite`, message files for `maildir` and entries for `feed`.
//! Every walk here is `os.walk`'s: top-down, unreadable directories passed over silently, symlinked
//! directories listed but not entered.

use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde_json::{Map, Value, json};

use crate::feed::count_feed_items;
use crate::policy::WalkPolicy;
use crate::source::ScanSummary;
use crate::sqlite::{Cell, Connection};
use crate::walk::{
    default_exclude_prefixes, expand_home, is_code_path, is_dependency_dir, is_diagnostic_dir, is_diagnostic_file,
    is_git_dir, is_hidden, is_indexable, is_inside_git_dir, list, relative_posix, root_problem,
};

/// How often a scan reports its running count (`PROGRESS_INTERVAL_SECONDS`).
pub const PROGRESS_INTERVAL: Duration = Duration::from_millis(250);

/// One source's scan (`SourceScanResult`).
#[derive(Clone, Debug, PartialEq)]
pub struct ScanResult {
    pub source_slug: String,
    pub kind: String,
    pub root: PathBuf,
    pub item_count: u64,
    /// What was counted: files, threads, records, messages, entries.
    pub item_type: String,
    pub details: Map<String, Value>,
    pub duration_seconds: f64,
    pub error: Option<String>,
}

impl ScanResult {
    fn new(source_slug: &str, kind: &str, root: &Path, item_type: &str) -> Self {
        Self {
            source_slug: source_slug.to_owned(),
            kind: kind.to_owned(),
            root: root.to_path_buf(),
            item_count: 0,
            item_type: item_type.to_owned(),
            details: Map::new(),
            duration_seconds: 0.0,
            error: None,
        }
    }

    fn missing(source_slug: &str, kind: &str, root: &Path, item_type: &str, started: Instant) -> Self {
        let mut result = Self::new(source_slug, kind, root, item_type);
        result.error = Some(format!("path does not exist: {}", root.display()));
        result.duration_seconds = started.elapsed().as_secs_f64();
        result
    }

    /// What the facade stores (`PersistScan`).
    #[must_use]
    pub fn summary(&self) -> ScanSummary {
        ScanSummary {
            item_count: self.item_count,
            item_type: self.item_type.clone(),
            duration_seconds: self.duration_seconds,
            details: self.details.clone(),
            error: self.error.clone(),
        }
    }

    /// `SourceScanResult.to_dict`.
    #[must_use]
    pub fn to_json(&self) -> Value {
        json!({
            "source_slug": self.source_slug,
            "kind": self.kind,
            "root": self.root.to_string_lossy(),
            "item_count": self.item_count,
            "item_type": self.item_type,
            "details": self.details,
            "duration_seconds": (self.duration_seconds * 10_000.0).round() / 10_000.0,
            "error": self.error,
        })
    }
}

/// What a scan needs besides the source.
pub struct ScanOptions<'a> {
    /// Count source code too, as the run that follows will ingest it.
    pub include_code: bool,
    /// The walk's rules: excluded directories, extensions, the size limit.
    pub policy: &'a WalkPolicy,
    /// Read a git source's tracked-file count through libgit2. Off, the detail is left out, as in a
    /// Python with no git reader.
    pub read_git: bool,
}

/// Hands the running count to a callback at most once per [`PROGRESS_INTERVAL`] (`_ProgressTicker`).
pub struct Ticker<'a> {
    report: Option<&'a mut dyn FnMut(u64)>,
    last: Instant,
}

impl<'a> Ticker<'a> {
    pub fn new(report: Option<&'a mut dyn FnMut(u64)>) -> Self {
        Self { report, last: Instant::now() }
    }

    fn tick(&mut self, count: u64) {
        let Some(report) = self.report.as_mut() else {
            return;
        };
        let now = Instant::now();
        if now.duration_since(self.last) >= PROGRESS_INTERVAL {
            self.last = now;
            report(count);
        }
    }
}

/// `os.walk(root, followlinks=False)`: `visit` sees each directory's subdirectory and file names
/// and keeps the subdirectories to descend into, as assigning `dirnames[:]` does.
fn os_walk(root: &Path, mut visit: impl FnMut(&Path, &mut Vec<String>, &[String])) {
    let mut stack = vec![root.to_path_buf()];
    while let Some(current) = stack.pop() {
        let Ok(listing) = list(&current) else {
            continue;
        };
        let mut names: Vec<String> = listing.dirs.iter().map(|(name, _)| name.clone()).collect();
        visit(&current, &mut names, &listing.files);
        let descend: Vec<PathBuf> = names
            .iter()
            .filter(|name| listing.dirs.iter().any(|(listed, symlink)| listed == *name && !symlink))
            .map(|name| current.join(name))
            .collect();
        stack.extend(descend.into_iter().rev());
    }
}

fn lower_ends_with(name: &str, suffixes: &[&str]) -> bool {
    let lowered = name.to_lowercase();
    suffixes.iter().any(|suffix| lowered.ends_with(suffix))
}

fn file_name(path: &Path) -> String {
    path.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default()
}

/// Indexable files in a tree (`scan_filesystem`). `exclude_prefixes` are root-relative directory
/// prefixes (`"Library/"`) whose subtrees are not counted, as the walk skips them.
pub fn scan_filesystem(
    root: &Path,
    source_slug: &str,
    options: &ScanOptions<'_>,
    exclude_prefixes: &[String],
    ticker: &mut Ticker<'_>,
) -> ScanResult {
    let started = Instant::now();
    let Ok(metadata) = fs::metadata(root) else {
        return ScanResult::missing(source_slug, "filesystem", root, "files", started);
    };
    let mut result = ScanResult::new(source_slug, "filesystem", root, "files");
    if is_inside_git_dir(root) {
        // The walk indexes nothing inside a git directory.
        result.details = json_map(json!({ "files": 0, "dirs": 0, "inside_git_dir": true }));
        result.duration_seconds = started.elapsed().as_secs_f64();
        return result;
    }
    let policy = options.policy;
    if metadata.is_file() {
        let name = file_name(root);
        let count = u64::from(is_indexable(&name, policy) && (options.include_code || !is_code_path(&name, policy)));
        result.item_count = count;
        result.details = json_map(json!({ "files": count, "dirs": 0 }));
        result.duration_seconds = started.elapsed().as_secs_f64();
        return result;
    }

    let (mut files, mut dirs, mut skipped_extensions) = (0_u64, 0_u64, 0_u64);
    os_walk(root, |parent, dirnames, filenames| {
        dirs += 1;
        ticker.tick(files);
        if is_git_dir(dirnames, filenames) {
            dirnames.clear();
            return;
        }
        dirnames.retain(|name| {
            !policy.exclude_dirs.contains(name)
                && !is_hidden(name)
                && !is_diagnostic_dir(name, policy)
                && !is_dependency_dir(&parent.join(name), root, policy)
        });
        if !exclude_prefixes.is_empty() && parent != root {
            let relative = relative_posix(parent, root).unwrap_or_default() + "/";
            if exclude_prefixes.iter().any(|prefix| relative.starts_with(prefix.as_str())) {
                dirnames.clear();
                return;
            }
        }
        for name in filenames {
            if is_hidden(name) || is_diagnostic_file(name, policy) {
                continue;
            }
            if !is_indexable(name, policy) {
                skipped_extensions += 1;
                continue;
            }
            if !options.include_code && is_code_path(name, policy) {
                continue;
            }
            match fs::metadata(parent.join(name)) {
                Ok(metadata) if metadata.len() <= policy.max_file_bytes => files += 1,
                _ => {}
            }
        }
    });
    result.item_count = files;
    result.details = json_map(json!({ "files": files, "dirs": dirs, "skipped_extensions": skipped_extensions }));
    result.duration_seconds = started.elapsed().as_secs_f64();
    result
}

/// The files a run will walk in a git working tree (`scan_git`): the filesystem count, untracked
/// files included, with whether `.git` is there and the tracked-file count as details.
pub fn scan_git(
    root: &Path,
    source_slug: &str,
    options: &ScanOptions<'_>,
    exclude_prefixes: &[String],
    ticker: &mut Ticker<'_>,
) -> ScanResult {
    let mut result = scan_filesystem(root, source_slug, options, exclude_prefixes, ticker);
    "git".clone_into(&mut result.kind);
    if result.error.is_none() {
        result.details.insert("is_git_repo".to_owned(), json!(root.join(".git").exists()));
        if options.read_git
            && let Ok(tracked) = garage_git::index_entry_count(root)
        {
            result.details.insert("tracked_files".to_owned(), json!(tracked));
        }
    }
    result
}

/// Apple Messages' `chat.db` always has these three tables, and no other known database has all of
/// them: such a database is counted in threads.
const APPLE_MESSAGES_TABLES: [&str; 3] = ["chat", "message", "handle"];

/// One database's rows (`_count_sqlite_database_rows`): its total, each table's count, and whether
/// the total is Messages threads. A database that cannot be read counts nothing.
fn count_database_rows(path: &Path) -> (u64, Map<String, Value>, bool) {
    let mut counts = Map::new();
    let resolved = fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    // Python builds the URI with no escaping, and so does this.
    let Ok(connection) = Connection::open_uri(&format!("file:{}?mode=ro", resolved.display()), 2000) else {
        return (0, counts, false);
    };
    let Ok(rows) = connection.rows("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
    else {
        return (0, counts, false);
    };
    let tables: Vec<String> = rows
        .into_iter()
        .filter_map(|row| match row.into_iter().next() {
            Some(Cell::Text(name)) => Some(name),
            _ => None,
        })
        .collect();
    let mut total = 0_u64;
    for table in &tables {
        let sql = format!("SELECT count(*) FROM \"{}\"", table.replace('"', "\"\""));
        if let Ok(rows) = connection.rows(&sql)
            && let Some(Cell::Integer(count)) = rows.into_iter().next().and_then(|row| row.into_iter().next())
        {
            let count = u64::try_from(count).unwrap_or(0);
            counts.insert(table.clone(), json!(count));
            total += count;
        }
    }
    if APPLE_MESSAGES_TABLES.iter().all(|name| tables.iter().any(|table| table == name)) {
        let threads = counts.get("chat").and_then(Value::as_u64).unwrap_or(0);
        return (threads, counts, true);
    }
    (total, counts, false)
}

/// Records across a source's SQLite databases (`scan_sqlite`): threads, once a Messages database
/// turns up, since the caches beside `chat.db` are databases too and their rows are not conversations.
pub fn scan_sqlite(root: &Path, source_slug: &str, ticker: &mut Ticker<'_>) -> ScanResult {
    let started = Instant::now();
    let Ok(metadata) = fs::metadata(root) else {
        return ScanResult::missing(source_slug, "sqlite", root, "records", started);
    };
    let mut databases: Vec<PathBuf> = Vec::new();
    if metadata.is_file() {
        databases.push(root.to_path_buf());
    } else {
        os_walk(root, |parent, dirnames, filenames| {
            dirnames.retain(|name| !is_hidden(name));
            for name in filenames {
                if is_hidden(name) || name.ends_with("-wal") || name.ends_with("-shm") || name.ends_with("-journal") {
                    continue;
                }
                if lower_ends_with(name, &[".db", ".sqlite", ".sqlite3"]) {
                    databases.push(parent.join(name));
                }
            }
        });
    }

    let (mut records, mut threads, mut any_threads) = (0_u64, 0_u64, false);
    let mut tables = Map::new();
    for path in &databases {
        ticker.tick(if any_threads { threads } else { records });
        let (rows, counts, is_threads) = count_database_rows(path);
        if is_threads {
            threads += rows;
        } else {
            records += rows;
        }
        tables.insert(file_name(path), Value::Object(counts));
        any_threads |= is_threads;
    }
    let mut result = ScanResult::new(source_slug, "sqlite", root, if any_threads { "threads" } else { "records" });
    result.item_count = if any_threads { threads } else { records };
    let names: Vec<String> = databases.iter().map(|path| file_name(path)).collect();
    result.details = json_map(json!({ "databases_count": databases.len(), "databases": names, "tables": tables }));
    result.duration_seconds = started.elapsed().as_secs_f64();
    result
}

/// Message files in a Maildir or Apple Mail tree (`scan_maildir`): everything in a `cur`, `new` or
/// `tmp` folder, and mail files by extension elsewhere.
pub fn scan_maildir(root: &Path, source_slug: &str, ticker: &mut Ticker<'_>) -> ScanResult {
    let started = Instant::now();
    if fs::metadata(root).is_err() {
        return ScanResult::missing(source_slug, "maildir", root, "messages", started);
    }
    let (mut messages, mut folders) = (0_u64, 0_u64);
    os_walk(root, |parent, _, filenames| {
        let mailbox = matches!(file_name(parent).to_lowercase().as_str(), "cur" | "new" | "tmp");
        folders += 1;
        ticker.tick(messages);
        for name in filenames {
            if is_hidden(name) {
                continue;
            }
            if mailbox || lower_ends_with(name, &[".eml", ".emlx", ".msg", ".mbox"]) {
                messages += 1;
            }
        }
    });
    let mut result = ScanResult::new(source_slug, "maildir", root, "messages");
    result.item_count = messages;
    result.details = json_map(json!({ "messages": messages, "folders": folders }));
    result.duration_seconds = started.elapsed().as_secs_f64();
    result
}

/// Entries across RSS, Atom and JSON feed files (`scan_feed`).
pub fn scan_feed(root: &Path, source_slug: &str, ticker: &mut Ticker<'_>) -> ScanResult {
    let started = Instant::now();
    let Ok(metadata) = fs::metadata(root) else {
        return ScanResult::missing(source_slug, "feed", root, "entries", started);
    };
    let mut feeds: Vec<PathBuf> = Vec::new();
    if metadata.is_file() {
        feeds.push(root.to_path_buf());
    } else {
        os_walk(root, |parent, dirnames, filenames| {
            dirnames.retain(|name| !is_hidden(name));
            for name in filenames {
                if !is_hidden(name) && lower_ends_with(name, &[".xml", ".rss", ".atom", ".json", ".feed"]) {
                    feeds.push(parent.join(name));
                }
            }
        });
    }
    let mut total = 0_u64;
    let mut details = Map::new();
    for path in &feeds {
        ticker.tick(total);
        let items = fs::read(path).map_or(0, |bytes| count_feed_items(&bytes));
        total += items;
        details.insert(file_name(path), json!(items));
    }
    let mut result = ScanResult::new(source_slug, "feed", root, "entries");
    result.item_count = total;
    result.details = json_map(json!({ "feeds_count": feeds.len(), "feeds": details }));
    result.duration_seconds = started.elapsed().as_secs_f64();
    result
}

/// What each kind counts, for a scan that could not start (`_ITEM_TYPES`).
fn item_type(kind: &str) -> &'static str {
    match kind {
        "filesystem" | "git" | "dropbox" => "files",
        "sqlite" => "records",
        "maildir" => "messages",
        "feed" => "entries",
        _ => "items",
    }
}

/// Scans one source by its kind (`scan_source`); an unknown kind is scanned as a filesystem. A
/// root that cannot be read gives an empty scan whose `root_problem` detail fails the run.
pub fn scan_source(
    source_slug: &str,
    kind: &str,
    root: &Path,
    options: &ScanOptions<'_>,
    ticker: &mut Ticker<'_>,
) -> ScanResult {
    if kind == crate::dropbox::KIND {
        // A Dropbox source is in the cloud: it is listed, and counted, when it is ingested.
        let mut result = ScanResult::new(source_slug, kind, root, "files");
        result.details.insert("remote".to_owned(), json!(kind));
        return result;
    }
    let root = expand_home(root);
    if let Some(problem) = root_problem(&root) {
        let mut result = ScanResult::new(source_slug, kind, &root, item_type(kind));
        result.details.insert("root_problem".to_owned(), json!(problem));
        result.error = Some(problem);
        return result;
    }
    let prefixes = default_exclude_prefixes(&root);
    match kind {
        "git" => scan_git(&root, source_slug, options, &prefixes, ticker),
        "sqlite" => scan_sqlite(&root, source_slug, ticker),
        "maildir" => scan_maildir(&root, source_slug, ticker),
        "feed" => scan_feed(&root, source_slug, ticker),
        _ => scan_filesystem(&root, source_slug, options, &prefixes, ticker),
    }
}

fn json_map(value: Value) -> Map<String, Value> {
    match value {
        Value::Object(map) => map,
        _ => Map::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Tree(PathBuf);

    impl Tree {
        fn new(name: &str) -> Self {
            let root = std::env::temp_dir().join(format!("garage-ingest-scan-{name}-{}", std::process::id()));
            let _ = fs::remove_dir_all(&root);
            fs::create_dir_all(&root).unwrap();
            Self(root)
        }

        fn file(&self, relative: &str, bytes: &[u8]) -> PathBuf {
            let path = self.0.join(relative);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(&path, bytes).unwrap();
            path
        }
    }

    impl Drop for Tree {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn scan(kind: &str, root: &Path, include_code: bool) -> ScanResult {
        let policy = WalkPolicy::default();
        let options = ScanOptions { include_code, policy: &policy, read_git: false };
        scan_source("s", kind, root, &options, &mut Ticker::new(None))
    }

    #[test]
    fn filesystem_counts_what_the_walk_yields() {
        let tree = Tree::new("fs");
        tree.file("notes/a.md", b"hello");
        tree.file("notes/empty.md", b"");
        tree.file("node_modules/x/readme.md", b"skip");
        tree.file(".hidden/b.md", b"skip");
        tree.file("src/main.py", b"print()");
        tree.file("photo.raw", b"unknown");
        let result = scan("filesystem", &tree.0, false);
        assert_eq!(result.item_count, 2);
        assert_eq!(result.details, json_map(json!({ "files": 2, "dirs": 3, "skipped_extensions": 1 })));
        assert_eq!(scan("filesystem", &tree.0, true).item_count, 3);
        let git = scan("git", &tree.0, false);
        assert_eq!(git.kind, "git");
        assert_eq!(git.details["is_git_repo"], json!(false));
    }

    #[test]
    fn maildir_and_feed_count_their_items() {
        let tree = Tree::new("mail");
        tree.file("INBOX/cur/1:2,S", b"x");
        tree.file("INBOX/new/2", b"x");
        tree.file("Archive/a.emlx", b"x");
        tree.file("Archive/.hidden.eml", b"x");
        tree.file("Archive/notes.txt", b"x");
        let result = scan("maildir", &tree.0, false);
        assert_eq!(result.item_count, 3);
        assert_eq!(result.details["folders"], json!(5));

        let feeds = Tree::new("feed");
        feeds.file("a.rss", b"<rss><channel><item/><item/></channel></rss>");
        feeds.file("b.json", br#"{"items": [1]}"#);
        feeds.file(".c.xml", b"<item/>");
        let result = scan("feed", &feeds.0, false);
        assert_eq!(result.item_count, 3);
        assert_eq!(result.details["feeds_count"], json!(2));
    }

    #[test]
    fn sqlite_counts_rows_or_messages_threads() {
        let tree = Tree::new("sqlite");
        let path = tree.0.join("plain.db");
        let uri = format!("file:{}", path.display());
        {
            let db = Connection::open_uri(&uri, 2000).unwrap();
            db.rows("CREATE TABLE t (x)").unwrap();
            db.rows("INSERT INTO t VALUES (1), (2)").unwrap();
        }
        tree.file("junk.sqlite", b"not a database");
        let result = scan("sqlite", &tree.0, false);
        assert_eq!(result.item_count, 2);
        assert_eq!(result.item_type, "records");

        let messages = tree.0.join("chat.db");
        {
            let db = Connection::open_uri(&format!("file:{}", messages.display()), 2000).unwrap();
            for sql in ["CREATE TABLE chat (x)", "CREATE TABLE message (x)", "CREATE TABLE handle (x)"] {
                db.rows(sql).unwrap();
            }
            db.rows("INSERT INTO chat VALUES (1)").unwrap();
            db.rows("INSERT INTO message VALUES (1), (2), (3)").unwrap();
        }
        let result = scan("sqlite", &tree.0, false);
        assert_eq!((result.item_count, result.item_type.as_str()), (1, "threads"));
    }

    #[test]
    fn an_unreadable_root_is_a_root_problem() {
        let tree = Tree::new("missing");
        let missing = tree.0.join("gone");
        let result = scan("maildir", &missing, false);
        assert_eq!(result.item_type, "messages");
        assert_eq!(result.error.as_deref(), Some(format!("path does not exist: {}", missing.display()).as_str()));
        assert!(result.summary().root_problem().is_some());
    }
}

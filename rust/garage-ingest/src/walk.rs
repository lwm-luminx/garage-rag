//! Filesystem discovery, ported from `garage_rag.ingest.walker`.
//!
//! The walk stats each candidate once and opens nothing: whether a file is worth opening is
//! decided from its name, its size and its stat. Excluded subtrees are pruned before descent, so
//! they are never listed at all. The order of the walk is `os.walk`'s: top-down, each directory's
//! entries in the order the file system lists them, symlinked directories listed but not entered.

use std::fs::{self, Metadata};
use std::io;
use std::ops::ControlFlow;
use std::path::{Component, Path, PathBuf};

use crate::fnmatch::fnmatch;
use crate::placeholder::is_placeholder;
use crate::policy::{DROPBOX_EXCLUDED_PREFIXES, WalkPolicy};

/// One file the walker considers worth looking at.
#[derive(Debug, Clone, PartialEq)]
pub struct Candidate {
    pub path: PathBuf,
    /// The size `stat` reports, which for a placeholder is the size it will have once downloaded.
    pub size: u64,
    /// Seconds since the epoch, as Python's `st_mtime`.
    pub mtime: f64,
    pub placeholder: bool,
}

/// What a walk saw, for the run report (`walker.WalkStats`).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct WalkStats {
    pub dirs: u64,
    pub files_seen: u64,
    pub yielded: u64,
    pub skipped_extension: u64,
    pub skipped_excluded_dir: u64,
    pub skipped_code: u64,
    pub skipped_too_large: u64,
    pub skipped_diagnostic: u64,
    pub placeholders: u64,
    pub unreadable: u64,
}

impl WalkStats {
    /// Each count under its Python name, in `WalkStats`'s field order.
    pub fn fields(&self) -> [(&'static str, u64); 10] {
        [
            ("dirs", self.dirs),
            ("files_seen", self.files_seen),
            ("yielded", self.yielded),
            ("skipped_extension", self.skipped_extension),
            ("skipped_excluded_dir", self.skipped_excluded_dir),
            ("skipped_code", self.skipped_code),
            ("skipped_too_large", self.skipped_too_large),
            ("skipped_diagnostic", self.skipped_diagnostic),
            ("placeholders", self.placeholders),
            ("unreadable", self.unreadable),
        ]
    }
}

/// How a walk ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Walked {
    /// The tree was walked (an unreadable root counts in `unreadable`).
    Walked,
    /// The root is a `.git` directory or lies inside one, so nothing was walked.
    InsideGitDir,
    /// The visitor stopped the walk before it ran out of files.
    Stopped,
}

/// What to walk besides the policy.
#[derive(Debug, Clone, Default)]
pub struct WalkOptions {
    /// Yield source code too. Off, a source is walked for its documentation only.
    pub include_code: bool,
    /// Subtrees below the root, as POSIX prefixes ending in `/`, to skip with everything in them.
    pub exclude_prefixes: Vec<String>,
}

fn name_matches_any(name: &str, patterns: &[String]) -> bool {
    let lowered = name.to_lowercase();
    patterns.iter().any(|pattern| fnmatch(&lowered, &pattern.to_lowercase()))
}

/// Whether a directory is a machine-generated diagnostic bundle.
pub fn is_diagnostic_dir(name: &str, policy: &WalkPolicy) -> bool {
    name_matches_any(name, &policy.diagnostic_dir_patterns)
}

/// Whether a file name is machine output regardless of its extension.
pub fn is_diagnostic_file(name: &str, policy: &WalkPolicy) -> bool {
    name_matches_any(name, &policy.diagnostic_file_patterns)
}

/// Whether a path lies inside a package-manager cache, by fragment.
pub fn is_dependency_path(path: &str, policy: &WalkPolicy) -> bool {
    let lowered = path.replace('\\', "/").to_lowercase();
    policy.dependency_path_fragments.iter().any(|fragment| lowered.contains(&fragment.to_lowercase()))
}

/// `path` below `root` as a POSIX path (`"."` for the root itself), or None outside it.
fn relative_posix(path: &Path, root: &Path) -> Option<String> {
    let relative = path.strip_prefix(root).ok()?;
    let parts: Vec<String> = relative
        .components()
        .filter_map(|component| match component {
            Component::Normal(part) => Some(part.to_string_lossy().into_owned()),
            _ => None,
        })
        .collect();
    Some(if parts.is_empty() { ".".to_owned() } else { parts.join("/") })
}

/// Whether `path` is a package-manager cache below `root`. Only the part below the root counts:
/// a source may live in a cache on purpose, and pruning on an ancestor would index nothing.
pub fn is_dependency_dir(path: &Path, root: &Path, policy: &WalkPolicy) -> bool {
    relative_posix(path, root)
        .is_some_and(|relative| relative != "." && is_dependency_path(&format!("/{relative}/"), policy))
}

/// Whether `path` is a `.git` directory or lies inside one.
pub fn is_inside_git_dir(path: &Path) -> bool {
    path.components().any(|component| component.as_os_str().to_string_lossy().to_lowercase() == ".git")
}

/// Whether a directory's listing is a git directory's: `HEAD`, `objects/` and `refs/`. Catches bare
/// repositories and mirrors, which pruning `.git` by name misses.
pub fn is_git_dir(dirnames: &[String], filenames: &[String]) -> bool {
    filenames.iter().any(|name| name == "HEAD")
        && dirnames.iter().any(|name| name == "objects")
        && dirnames.iter().any(|name| name == "refs")
}

fn is_hidden(name: &str) -> bool {
    name.starts_with('.')
}

/// The last suffix of a file name, as Python 3.14's `PurePath.suffix`: leading dots are not a
/// suffix, and a trailing dot is one.
pub fn suffix(name: &str) -> &str {
    let name = name.trim_start_matches('.');
    name.rfind('.').map_or("", |index| &name[index..])
}

/// A file name without its last suffix, as `PurePath.stem`.
pub fn stem(name: &str) -> &str {
    match name.rfind('.') {
        Some(index) if !name[..index].trim_start_matches('.').is_empty() => &name[..index],
        _ => name,
    }
}

/// Whether a built-in reader (or one the policy adds) opens a file of this name
/// (`dispatch.is_indexable`).
pub fn is_indexable(name: &str, policy: &WalkPolicy) -> bool {
    let suffix = suffix(name).to_lowercase();
    policy.indexable_extensions.contains(&suffix)
        || (suffix.is_empty() && policy.named_code_files.contains(&name.to_lowercase()))
}

/// Whether a file of this name would be classed as code (`classify.is_code_path`).
pub fn is_code_path(name: &str, policy: &WalkPolicy) -> bool {
    let suffix = suffix(name).to_lowercase();
    if policy.doc_extensions.contains(&suffix) {
        return false;
    }
    if policy.code_extensions.contains(&suffix) {
        return true;
    }
    if policy.doc_stems.contains(&stem(name).to_lowercase()) {
        return false;
    }
    false
}

/// `~` or `~/...` with the account's home folder in place of `~`, as `config.expand_home`: in a
/// sandboxed macOS process (`APP_SANDBOX_CONTAINER_ID` set) `$HOME` is the app's container, so
/// the home folder comes from the account record there.
pub fn expand_home(path: &Path) -> PathBuf {
    let mut components = path.components();
    let Some(Component::Normal(first)) = components.next() else {
        return path.to_path_buf();
    };
    if first != "~" {
        return path.to_path_buf();
    }
    let sandboxed = std::env::var_os("APP_SANDBOX_CONTAINER_ID").is_some_and(|value| !value.is_empty());
    let home =
        if sandboxed { account_home() } else { std::env::var_os("HOME").map(PathBuf::from).or_else(account_home) };
    match home {
        Some(home) => home.join(components.as_path()),
        None => path.to_path_buf(),
    }
}

#[cfg(unix)]
fn account_home() -> Option<PathBuf> {
    use std::ffi::{CStr, OsStr};
    use std::os::unix::ffi::OsStrExt;

    let mut buffer = vec![0 as libc::c_char; 16 * 1024];
    // SAFETY: zeroed passwd is a valid out-parameter; getpwuid_r fills it with pointers into `buffer`.
    let mut record: libc::passwd = unsafe { std::mem::zeroed() };
    let mut found: *mut libc::passwd = std::ptr::null_mut();
    // SAFETY: every pointer is valid for the call and `buffer.len()` is its size.
    let status =
        unsafe { libc::getpwuid_r(libc::getuid(), &raw mut record, buffer.as_mut_ptr(), buffer.len(), &raw mut found) };
    if status != 0 || found.is_null() || record.pw_dir.is_null() {
        return None;
    }
    // SAFETY: pw_dir points at a NUL-terminated string in `buffer`, alive here.
    let dir = unsafe { CStr::from_ptr(record.pw_dir) };
    Some(PathBuf::from(OsStr::from_bytes(dir.to_bytes())))
}

#[cfg(not(unix))]
fn account_home() -> Option<PathBuf> {
    None
}

/// An OS error's text without Rust's " (os error N)" tail: Python's `strerror`.
fn strerror(error: &io::Error) -> String {
    let text = error.to_string();
    match (error.raw_os_error(), text.rfind(" (os error ")) {
        (Some(_), Some(index)) => text[..index].to_owned(),
        _ => text,
    }
}

/// Why `root` cannot be walked, or None when it can (`walker.root_problem`). A missing root and
/// one this process may not list are told apart: in the sandboxed build, "permission denied"
/// means the folder's grant did not reach this process.
pub fn root_problem(root: &Path) -> Option<String> {
    let shown = root.display();
    let denied = || format!("not readable: {shown} (permission denied; this process has no access to it)");
    let failed = |error: &io::Error| match error.kind() {
        io::ErrorKind::PermissionDenied => denied(),
        _ => format!("not readable: {shown} ({})", strerror(error)),
    };
    let metadata = match fs::metadata(root) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Some(format!("path does not exist: {shown}")),
        Err(error) => return Some(failed(&error)),
    };
    if metadata.is_dir() {
        if let Err(error) = fs::read_dir(root) {
            return Some(failed(&error));
        }
    } else if !readable(root) {
        return Some(denied());
    }
    None
}

#[cfg(unix)]
fn readable(path: &Path) -> bool {
    use std::os::unix::ffi::OsStrExt;
    let Ok(path) = std::ffi::CString::new(path.as_os_str().as_bytes()) else {
        return false;
    };
    // SAFETY: `path` is NUL-terminated.
    unsafe { libc::access(path.as_ptr(), libc::R_OK) == 0 }
}

#[cfg(not(unix))]
fn readable(path: &Path) -> bool {
    fs::File::open(path).is_ok()
}

/// The subtrees a source skips by default (`walker.default_exclude_prefixes`): Dropbox's folders
/// of application bundles and binary objects, for a root that is a Dropbox.
pub fn default_exclude_prefixes(root: &Path) -> Vec<String> {
    let dropbox = root.file_name().is_some_and(|name| name == "Dropbox") || root.join(".dropbox.device").exists();
    if dropbox { DROPBOX_EXCLUDED_PREFIXES.iter().map(|&prefix| prefix.to_owned()).collect() } else { Vec::new() }
}

#[cfg(unix)]
fn mtime(metadata: &Metadata) -> f64 {
    use std::os::unix::fs::MetadataExt;
    // As CPython computes st_mtime: seconds plus nanoseconds times 1e-9, in doubles.
    #[allow(clippy::cast_precision_loss)]
    let seconds = metadata.mtime() as f64;
    #[allow(clippy::cast_precision_loss)]
    let nanos = metadata.mtime_nsec() as f64;
    seconds + nanos * 1e-9
}

#[cfg(not(unix))]
fn mtime(metadata: &Metadata) -> f64 {
    metadata
        .modified()
        .ok()
        .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
        .map_or(0.0, |since| since.as_secs_f64())
}

struct Listing {
    /// Directory names, each with whether it is a symlink (listed, never entered).
    dirs: Vec<(String, bool)>,
    files: Vec<String>,
}

/// One directory's entries, split as `os.walk` splits them: an entry is a directory when it is
/// one after following a symlink.
fn list(dir: &Path) -> io::Result<Listing> {
    let mut listing = Listing { dirs: Vec::new(), files: Vec::new() };
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().into_owned();
        let Ok(kind) = entry.file_type() else {
            listing.files.push(name);
            continue;
        };
        if kind.is_symlink() {
            if fs::metadata(entry.path()).is_ok_and(|target| target.is_dir()) {
                listing.dirs.push((name, true));
            } else {
                listing.files.push(name);
            }
        } else if kind.is_dir() {
            listing.dirs.push((name, false));
        } else {
            listing.files.push(name);
        }
    }
    Ok(listing)
}

/// Walks `root` (after [`expand_home`]) and hands `visit` each indexable file, counting what it
/// skipped into `stats`. An unreadable subtree is counted and passed over, never fatal.
pub fn walk(
    root: &Path,
    policy: &WalkPolicy,
    options: &WalkOptions,
    stats: &mut WalkStats,
    mut visit: impl FnMut(Candidate),
) -> Walked {
    walk_while(root, policy, options, stats, |candidate| {
        visit(candidate);
        ControlFlow::Continue(())
    })
}

/// [`walk`], which `visit` may stop, as breaking out of Python's walk generator does: the files after
/// the one it stops on are neither visited nor counted.
pub fn walk_while(
    root: &Path,
    policy: &WalkPolicy,
    options: &WalkOptions,
    stats: &mut WalkStats,
    mut visit: impl FnMut(Candidate) -> ControlFlow<()>,
) -> Walked {
    let root = expand_home(root);
    if is_inside_git_dir(&root) {
        return Walked::InsideGitDir;
    }
    let mut stack = vec![root.clone()];
    while let Some(current) = stack.pop() {
        let Ok(listing) = list(&current) else {
            stats.unreadable += 1;
            continue;
        };
        stats.dirs += 1;
        let dirnames: Vec<String> = listing.dirs.iter().map(|(name, _)| name.clone()).collect();

        if is_git_dir(&dirnames, &listing.files) || is_dependency_dir(&current, &root, policy) {
            stats.skipped_excluded_dir += 1;
            continue;
        }

        let mut kept: Vec<(String, bool)> = Vec::new();
        for (name, symlink) in listing.dirs {
            if policy.exclude_dirs.contains(&name) || is_hidden(&name) {
                stats.skipped_excluded_dir += 1;
            } else if is_diagnostic_dir(&name, policy) {
                stats.skipped_diagnostic += 1;
            } else {
                kept.push((name, symlink));
            }
        }

        if !options.exclude_prefixes.is_empty() {
            let relative = relative_posix(&current, &root).map(|relative| relative + "/").unwrap_or_default();
            if !relative.is_empty()
                && options.exclude_prefixes.iter().any(|prefix| relative.starts_with(prefix.as_str()))
            {
                continue;
            }
        }

        for name in &listing.files {
            stats.files_seen += 1;
            if let Some(candidate) = consider(&current, name, policy, options, stats) {
                stats.yielded += 1;
                if visit(candidate).is_break() {
                    return Walked::Stopped;
                }
            }
        }

        // Descend in listing order: the stack pops the last pushed first.
        for (name, symlink) in kept.into_iter().rev() {
            if !symlink {
                stack.push(current.join(name));
            }
        }
    }
    Walked::Walked
}

fn consider(
    dir: &Path,
    name: &str,
    policy: &WalkPolicy,
    options: &WalkOptions,
    stats: &mut WalkStats,
) -> Option<Candidate> {
    if is_hidden(name) {
        return None;
    }
    if is_diagnostic_file(name, policy) {
        stats.skipped_diagnostic += 1;
        return None;
    }
    if !is_indexable(name, policy) {
        stats.skipped_extension += 1;
        return None;
    }
    if !options.include_code && is_code_path(name, policy) {
        stats.skipped_code += 1;
        return None;
    }
    let path = dir.join(name);
    let Ok(metadata) = fs::metadata(&path) else {
        stats.unreadable += 1;
        return None;
    };
    let placeholder = is_placeholder(&path, &metadata);
    let size = metadata.len();
    if placeholder {
        stats.placeholders += 1;
    } else if size == 0 {
        return None;
    } else if size > policy.max_file_bytes {
        stats.skipped_too_large += 1;
        return None;
    }
    Some(Candidate { path, size, mtime: mtime(&metadata), placeholder })
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Tree(PathBuf);

    impl Tree {
        fn new(name: &str) -> Self {
            let root = std::env::temp_dir().join(format!("garage-ingest-walk-{name}-{}", std::process::id()));
            let _ = fs::remove_dir_all(&root);
            fs::create_dir_all(&root).unwrap();
            Self(root)
        }

        fn file(&self, relative: &str, bytes: &[u8]) {
            let path = self.0.join(relative);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(path, bytes).unwrap();
        }
    }

    impl Drop for Tree {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn names(tree: &Tree, options: &WalkOptions) -> (Vec<String>, WalkStats) {
        let mut stats = WalkStats::default();
        let mut found = Vec::new();
        walk(&tree.0, &WalkPolicy::default(), options, &mut stats, |candidate| {
            found.push(relative_posix(&candidate.path, &tree.0).unwrap());
        });
        found.sort();
        (found, stats)
    }

    #[test]
    fn suffix_and_stem_follow_python() {
        assert_eq!(suffix("a.tar.gz"), ".gz");
        assert_eq!(suffix("foo."), ".");
        assert_eq!(suffix("..x"), "");
        assert_eq!(suffix(".bashrc"), "");
        assert_eq!(suffix("Makefile"), "");
        assert_eq!(stem("a.tar.gz"), "a.tar");
        assert_eq!(stem(".bashrc"), ".bashrc");
        assert_eq!(stem("README.md"), "README");
    }

    #[test]
    fn prunes_excluded_hidden_diagnostic_and_git_dirs() {
        let tree = Tree::new("prune");
        tree.file("notes/a.md", b"hello");
        tree.file("node_modules/x/readme.md", b"skip");
        tree.file(".hidden/b.md", b"skip");
        tree.file("sysdiagnose_1/c.txt", b"skip");
        tree.file("mirror.git/HEAD", b"ref");
        tree.file("mirror.git/objects/d.txt", b"skip");
        tree.file("mirror.git/refs/e.txt", b"skip");
        tree.file("src/main.py", b"print()");
        tree.file("src/README", b"docs");
        tree.file("empty.md", b"");
        tree.file("ps.txt", b"diagnostic");
        tree.file("photo.raw", b"unknown");
        let (found, stats) = names(&tree, &WalkOptions::default());
        assert_eq!(found, ["notes/a.md"]);
        assert_eq!(stats.skipped_excluded_dir, 3);
        assert_eq!(stats.skipped_diagnostic, 2);
        assert_eq!(stats.skipped_code, 1);
        assert_eq!(stats.skipped_extension, 2);

        let (found, _) = names(&tree, &WalkOptions { include_code: true, exclude_prefixes: Vec::new() });
        assert_eq!(found, ["notes/a.md", "src/main.py"]);
        let (found, _) =
            names(&tree, &WalkOptions { include_code: false, exclude_prefixes: vec!["notes/".to_owned()] });
        assert!(found.is_empty());
    }

    #[test]
    fn a_root_inside_git_is_not_walked() {
        let tree = Tree::new("git");
        tree.file(".git/info/a.md", b"x");
        let mut stats = WalkStats::default();
        let walked = walk(&tree.0.join(".git"), &WalkPolicy::default(), &WalkOptions::default(), &mut stats, |_| {});
        assert_eq!(walked, Walked::InsideGitDir);
        assert_eq!(stats, WalkStats::default());
    }

    #[test]
    fn root_problems_are_told_apart() {
        let tree = Tree::new("problem");
        let missing = tree.0.join("missing");
        assert_eq!(root_problem(&missing), Some(format!("path does not exist: {}", missing.display())));
        assert_eq!(root_problem(&tree.0), None);
    }
}

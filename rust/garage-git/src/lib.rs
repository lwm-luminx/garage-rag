//! A repository's history, origin remote and tracked-file count, read in-process through libgit2:
//! the three reads `_garage_git` (`ext/python/garage_git/garage_git.c`) makes for
//! `garage_rag.attribute.git`, with the same answers. No `git` command runs, and nothing connects
//! anywhere: the libgit2 the app links (`//ext/libgit2`) has no network transport.
//!
//! The bindings are declared here by hand, for the dozen calls the reads need, so nothing but
//! libgit2 itself is linked. They assume a libgit2 built without `GIT_EXPERIMENTAL_SHA256`, as every
//! release build is (a SHA-1 `git_oid` of 20 bytes, which fixes where a diff delta keeps its path).

use std::ffi::{CStr, CString, c_char, c_int, c_uint};
use std::fmt;
use std::path::Path;
use std::ptr;
use std::sync::OnceLock;

// The C structs' own field names.
#[allow(clippy::struct_field_names)]
mod sys {
    use std::ffi::{c_char, c_int, c_uint};

    pub const GIT_ENOTFOUND: c_int = -3;
    pub const GIT_EINVALIDSPEC: c_int = -12;
    pub const GIT_ITEROVER: c_int = -31;
    pub const GIT_SORT_TIME: c_uint = 1 << 1;

    /// `git_oid` with SHA-1: 20 bytes.
    #[repr(C)]
    pub struct Oid {
        pub id: [u8; 20],
    }

    #[repr(C)]
    pub struct Error {
        pub message: *const c_char,
        pub klass: c_int,
    }

    #[repr(C)]
    pub struct Time {
        pub time: i64,
        pub offset: c_int,
        pub sign: c_char,
    }

    #[repr(C)]
    pub struct Signature {
        pub name: *const c_char,
        pub email: *const c_char,
        pub when: Time,
    }

    #[repr(C)]
    pub struct DiffFile {
        pub id: Oid,
        pub path: *const c_char,
        pub size: u64,
        pub flags: u32,
        pub mode: u16,
        pub id_abbrev: u16,
    }

    #[repr(C)]
    pub struct DiffDelta {
        pub status: c_int,
        pub flags: u32,
        pub similarity: u16,
        pub nfiles: u16,
        pub old_file: DiffFile,
        pub new_file: DiffFile,
    }

    macro_rules! opaque {
        ($($name:ident),*) => { $(#[repr(C)] pub struct $name { _private: [u8; 0] })* };
    }
    opaque!(Repository, Remote, Index, Mailmap, Revwalk, Commit, Tree, Diff);

    unsafe extern "C" {
        pub fn git_libgit2_init() -> c_int;
        pub fn git_libgit2_version(major: *mut c_int, minor: *mut c_int, patch: *mut c_int) -> c_int;
        pub fn git_error_last() -> *const Error;

        pub fn git_repository_open(out: *mut *mut Repository, path: *const c_char) -> c_int;
        pub fn git_repository_free(repo: *mut Repository);
        pub fn git_repository_head_unborn(repo: *mut Repository) -> c_int;
        pub fn git_repository_index(out: *mut *mut Index, repo: *mut Repository) -> c_int;

        pub fn git_index_entrycount(index: *const Index) -> usize;
        pub fn git_index_free(index: *mut Index);

        pub fn git_remote_lookup(out: *mut *mut Remote, repo: *mut Repository, name: *const c_char) -> c_int;
        pub fn git_remote_url(remote: *const Remote) -> *const c_char;
        pub fn git_remote_free(remote: *mut Remote);

        pub fn git_mailmap_from_repository(out: *mut *mut Mailmap, repo: *mut Repository) -> c_int;
        pub fn git_mailmap_free(mailmap: *mut Mailmap);

        pub fn git_revwalk_new(out: *mut *mut Revwalk, repo: *mut Repository) -> c_int;
        pub fn git_revwalk_sorting(walk: *mut Revwalk, mode: c_uint) -> c_int;
        pub fn git_revwalk_push_head(walk: *mut Revwalk) -> c_int;
        pub fn git_revwalk_next(out: *mut Oid, walk: *mut Revwalk) -> c_int;
        pub fn git_revwalk_free(walk: *mut Revwalk);

        pub fn git_commit_lookup(out: *mut *mut Commit, repo: *mut Repository, id: *const Oid) -> c_int;
        pub fn git_commit_free(commit: *mut Commit);
        pub fn git_commit_parentcount(commit: *const Commit) -> c_uint;
        pub fn git_commit_parent(out: *mut *mut Commit, commit: *const Commit, n: c_uint) -> c_int;
        pub fn git_commit_tree(out: *mut *mut Tree, commit: *const Commit) -> c_int;
        pub fn git_commit_author_with_mailmap(
            out: *mut *mut Signature,
            commit: *const Commit,
            mailmap: *const Mailmap,
        ) -> c_int;
        pub fn git_signature_free(signature: *mut Signature);
        pub fn git_tree_free(tree: *mut Tree);

        pub fn git_diff_tree_to_tree(
            out: *mut *mut Diff,
            repo: *mut Repository,
            old_tree: *mut Tree,
            new_tree: *mut Tree,
            options: *const std::ffi::c_void,
        ) -> c_int;
        pub fn git_diff_num_deltas(diff: *const Diff) -> usize;
        pub fn git_diff_get_delta(diff: *const Diff, index: usize) -> *const DiffDelta;
        pub fn git_diff_free(diff: *mut Diff);
    }
}

/// A libgit2 call failed: `what` it was doing and libgit2's message, worded as `_garage_git` words it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GitError(pub String);

impl fmt::Display for GitError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for GitError {}

fn error(rc: c_int, what: &str) -> GitError {
    // SAFETY: libgit2 keeps the last error per thread; the pointer is valid until the next call.
    let last = unsafe { sys::git_error_last() };
    // SAFETY: as above; a non-null message is NUL-terminated.
    let message = unsafe { last.as_ref() }
        .filter(|last| !last.message.is_null())
        .map(|last| unsafe { CStr::from_ptr(last.message) }.to_string_lossy().into_owned())
        .filter(|message| !message.is_empty());
    match message {
        Some(message) => GitError(format!("{what}: {message}")),
        None => GitError(format!("{what}: error {rc}")),
    }
}

/// Text from libgit2, decoded as `_garage_git` decodes it (UTF-8, invalid bytes replaced); null is empty.
fn decode(text: *const c_char) -> String {
    if text.is_null() {
        return String::new();
    }
    // SAFETY: libgit2's strings are NUL-terminated and live as long as their owner.
    unsafe { CStr::from_ptr(text) }.to_string_lossy().into_owned()
}

fn init() -> Result<(), GitError> {
    static INIT: OnceLock<c_int> = OnceLock::new();
    // SAFETY: no preconditions; libgit2 counts its initializations and these are never undone.
    let rc = *INIT.get_or_init(|| unsafe { sys::git_libgit2_init() });
    if rc < 0 { Err(error(rc, "git_libgit2_init")) } else { Ok(()) }
}

/// The linked libgit2's version, e.g. `1.9.7`.
///
/// # Errors
///
/// A libgit2 failure, worded with what was being read and libgit2's message.
pub fn version() -> Result<String, GitError> {
    init()?;
    let (mut major, mut minor, mut patch) = (0, 0, 0);
    // SAFETY: three writable ints.
    let rc = unsafe { sys::git_libgit2_version(&raw mut major, &raw mut minor, &raw mut patch) };
    if rc < 0 {
        return Err(error(rc, "version"));
    }
    Ok(format!("{major}.{minor}.{patch}"))
}

/// Frees a libgit2 object when dropped.
struct Owned<T>(*mut T, unsafe extern "C" fn(*mut T));

impl<T> Owned<T> {
    fn null(free: unsafe extern "C" fn(*mut T)) -> Self {
        Self(ptr::null_mut(), free)
    }
}

impl<T> Drop for Owned<T> {
    fn drop(&mut self) {
        if !self.0.is_null() {
            // SAFETY: the pointer came from the libgit2 call this free belongs to, and is freed once.
            unsafe { (self.1)(self.0) };
        }
    }
}

/// An open repository.
struct Repository(Owned<sys::Repository>);

impl Repository {
    fn open(path: &Path) -> Result<Self, GitError> {
        init()?;
        let encoded = path_bytes(path);
        let what = String::from_utf8_lossy(&encoded).into_owned();
        let encoded = CString::new(encoded).map_err(|_| GitError(format!("{what}: embedded NUL byte")))?;
        let mut repo = Owned::null(sys::git_repository_free);
        // SAFETY: a writable out-pointer and a NUL-terminated path.
        let rc = unsafe { sys::git_repository_open(&raw mut repo.0, encoded.as_ptr()) };
        if rc < 0 {
            return Err(error(rc, &what));
        }
        Ok(Self(repo))
    }

    fn raw(&self) -> *mut sys::Repository {
        self.0.0
    }
}

#[cfg(unix)]
fn path_bytes(path: &Path) -> Vec<u8> {
    use std::os::unix::ffi::OsStrExt;
    path.as_os_str().as_bytes().to_vec()
}

#[cfg(not(unix))]
fn path_bytes(path: &Path) -> Vec<u8> {
    path.to_string_lossy().into_owned().into_bytes()
}

/// `remote_url`: the remote's configured URL, as `git remote get-url` prints it, or `None` when
/// the repository has no such remote (or its URL is empty). A config lookup; it connects nowhere.
///
/// # Errors
///
/// A libgit2 failure, worded with what was being read and libgit2's message.
pub fn remote_url(path: &Path, name: &str) -> Result<Option<String>, GitError> {
    let repo = Repository::open(path)?;
    let Ok(name) = CString::new(name) else { return Ok(None) };
    let mut remote = Owned::null(sys::git_remote_free);
    // SAFETY: a writable out-pointer, an open repository and a NUL-terminated name.
    let rc = unsafe { sys::git_remote_lookup(&raw mut remote.0, repo.raw(), name.as_ptr()) };
    if rc == sys::GIT_ENOTFOUND || rc == sys::GIT_EINVALIDSPEC {
        return Ok(None);
    }
    if rc < 0 {
        return Err(error(rc, "remote"));
    }
    // SAFETY: a remote libgit2 returned; the URL lives as long as it.
    let url = unsafe { sys::git_remote_url(remote.0) };
    Ok(Some(decode(url)).filter(|url| !url.is_empty()))
}

/// `index_entry_count`: entries in the repository's index, the tracked files `git ls-files` lists.
///
/// # Errors
///
/// A libgit2 failure, worded with what was being read and libgit2's message.
pub fn index_entry_count(path: &Path) -> Result<usize, GitError> {
    let repo = Repository::open(path)?;
    let mut index = Owned::null(sys::git_index_free);
    // SAFETY: a writable out-pointer and an open repository.
    let rc = unsafe { sys::git_repository_index(&raw mut index.0, repo.raw()) };
    if rc < 0 {
        return Err(error(rc, "index"));
    }
    // SAFETY: an index libgit2 returned.
    Ok(unsafe { sys::git_index_entrycount(index.0) })
}

/// One commit's author (after `.mailmap`) and the paths it touched.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CommitPaths {
    /// The author's name.
    pub name: String,
    /// The author's address.
    pub email: String,
    /// Repository-relative POSIX paths the commit added, changed or deleted.
    pub paths: Vec<String>,
}

/// The paths one commit touched, against its first parent (or nothing, for a root commit), with no
/// rename detection: libgit2 detects renames only when asked (`git_diff_find_similar`).
fn changed_paths(repo: &Repository, commit: *mut sys::Commit, parents: c_uint) -> Result<Vec<String>, GitError> {
    let mut new_tree = Owned::null(sys::git_tree_free);
    let mut old_tree = Owned::null(sys::git_tree_free);
    let mut parent = Owned::null(sys::git_commit_free);
    let mut diff = Owned::null(sys::git_diff_free);
    // SAFETY: writable out-pointers, a live commit and an open repository throughout.
    unsafe {
        let rc = sys::git_commit_tree(&raw mut new_tree.0, commit);
        if rc < 0 {
            return Err(error(rc, "tree"));
        }
        if parents == 1 {
            let rc = sys::git_commit_parent(&raw mut parent.0, commit, 0);
            if rc < 0 {
                return Err(error(rc, "parent"));
            }
            let rc = sys::git_commit_tree(&raw mut old_tree.0, parent.0);
            if rc < 0 {
                return Err(error(rc, "parent tree"));
            }
        }
        let rc = sys::git_diff_tree_to_tree(&raw mut diff.0, repo.raw(), old_tree.0, new_tree.0, ptr::null());
        if rc < 0 {
            return Err(error(rc, "diff"));
        }
        let count = sys::git_diff_num_deltas(diff.0);
        let mut paths = Vec::with_capacity(count);
        for i in 0..count {
            let delta = &*sys::git_diff_get_delta(diff.0, i);
            let path = if delta.new_file.path.is_null() { delta.old_file.path } else { delta.new_file.path };
            paths.push(decode(path));
        }
        Ok(paths)
    }
}

/// `commit_paths`: (author, touched paths) for each commit reachable from `HEAD`, as `git log
/// --no-merges --no-renames --name-only --format=%aN%x1f%aE` prints them: newest first, merges
/// skipped, `.mailmap` applied to the author. `max_commits` counts the commits returned, as
/// `--max-count` does. An unborn `HEAD` gives no commits.
///
/// # Errors
///
/// A libgit2 failure, worded with what was being read and libgit2's message.
pub fn commit_paths(path: &Path, max_commits: Option<usize>) -> Result<Vec<CommitPaths>, GitError> {
    let repo = Repository::open(path)?;
    let mut mailmap = Owned::null(sys::git_mailmap_free);
    let mut walk = Owned::null(sys::git_revwalk_free);
    let mut commits = Vec::new();
    // SAFETY: writable out-pointers and an open repository; every object is freed by its guard.
    unsafe {
        let rc = sys::git_mailmap_from_repository(&raw mut mailmap.0, repo.raw());
        if rc < 0 {
            return Err(error(rc, "mailmap"));
        }
        let mut rc = sys::git_revwalk_new(&raw mut walk.0, repo.raw());
        if rc == 0 {
            rc = sys::git_revwalk_sorting(walk.0, sys::GIT_SORT_TIME);
        }
        if rc < 0 {
            return Err(error(rc, "revwalk"));
        }
        let mut rc = sys::git_repository_head_unborn(repo.raw());
        if rc == 1 {
            return Ok(commits);
        }
        if rc == 0 {
            rc = sys::git_revwalk_push_head(walk.0);
        }
        if rc < 0 {
            return Err(error(rc, "HEAD"));
        }
        let mut oid = sys::Oid { id: [0; 20] };
        while max_commits.is_none_or(|max| commits.len() < max) {
            let rc = sys::git_revwalk_next(&raw mut oid, walk.0);
            if rc == sys::GIT_ITEROVER {
                break;
            }
            if rc < 0 {
                return Err(error(rc, "revwalk"));
            }
            let mut commit = Owned::null(sys::git_commit_free);
            let rc = sys::git_commit_lookup(&raw mut commit.0, repo.raw(), &raw const oid);
            if rc < 0 {
                return Err(error(rc, "commit"));
            }
            let parents = sys::git_commit_parentcount(commit.0);
            if parents > 1 {
                // Merges restate their parents' paths and would double-count.
                continue;
            }
            let mut author = Owned::null(sys::git_signature_free);
            let rc = sys::git_commit_author_with_mailmap(&raw mut author.0, commit.0, mailmap.0);
            if rc < 0 {
                return Err(error(rc, "author"));
            }
            let paths = changed_paths(&repo, commit.0, parents)?;
            let author = &*author.0;
            commits.push(CommitPaths { name: decode(author.name), email: decode(author.email), paths });
        }
    }
    Ok(commits)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;

    fn git(root: &Path, args: &[&str], author: Option<(&str, &str)>) {
        let mut command = Command::new("git");
        command
            .args(args)
            .current_dir(root)
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_COMMITTER_NAME", "Committer")
            .env("GIT_COMMITTER_EMAIL", "committer@example.com");
        if let Some((name, email)) = author {
            command.env("GIT_AUTHOR_NAME", name).env("GIT_AUTHOR_EMAIL", email);
        }
        assert!(command.status().unwrap().success(), "git {args:?}");
    }

    fn scratch(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("garage-git-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn a_small_history_reads_back() {
        if Command::new("git").arg("--version").output().is_err() {
            return;
        }
        let root = scratch("history");
        git(&root, &["init", "-q", "-b", "main"], None);
        std::fs::write(root.join("a.md"), "a\n").unwrap();
        git(&root, &["add", "-A"], None);
        git(&root, &["commit", "-q", "-m", "one"], Some(("Ada", "ada@example.com")));
        std::fs::create_dir(root.join("docs")).unwrap();
        std::fs::write(root.join("docs/b.md"), "b\n").unwrap();
        std::fs::remove_file(root.join("a.md")).unwrap();
        git(&root, &["add", "-A"], None);
        git(&root, &["commit", "-q", "-m", "two"], Some(("Grace", "grace@example.com")));

        let commits = commit_paths(&root, None).unwrap();
        assert_eq!(commits.len(), 2);
        let mut touched: Vec<_> = commits.iter().flat_map(|commit| commit.paths.clone()).collect();
        touched.sort();
        assert_eq!(touched, ["a.md", "a.md", "docs/b.md"]);
        assert_eq!(commit_paths(&root, Some(1)).unwrap().len(), 1);
        assert_eq!(index_entry_count(&root).unwrap(), 1);
        assert_eq!(remote_url(&root, "origin").unwrap(), None);
        git(&root, &["remote", "add", "origin", "git@github.com:someone/repo.git"], None);
        assert_eq!(remote_url(&root, "origin").unwrap().as_deref(), Some("git@github.com:someone/repo.git"));
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn a_folder_that_is_no_repository_is_an_error() {
        let root = scratch("none");
        assert!(commit_paths(&root, None).is_err());
        assert!(index_entry_count(&root).is_err());
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn the_version_is_read() {
        assert!(version().unwrap().split('.').count() == 3);
    }
}

//! On-demand materialization of cloud placeholder files, ported from `ingest/materialize.py`.
//!
//! Reading a placeholder makes the sync client download it. That is the mechanism and the hazard:
//! walking a large online-only tree would pull hundreds of gigabytes with no upper bound. So every
//! download is metered by a [`Budget`] (files and bytes per run), and stopping at the budget is not a
//! failure: ingest is idempotent, so the next run spends its budget on the next slice.
//!
//! The budget only governs reads that go through [`Materializer::materialize`]. On macOS the
//! `IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES` I/O policy (`setiopolicy_np(3)`) makes any other read
//! of a dataless file fail with `EDEADLK` instead of downloading it: the pipeline runs with it off on
//! its thread ([`refusing_dataless_reads`]) and turns it on only in the one thread that performs a
//! budgeted download ([`allowing_dataless_reads`]). Elsewhere both are no-ops. The call is bound at
//! link time from libSystem, not looked up at run time.

use std::fs::File;
use std::io::{self, Read};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex, OnceLock, PoisonError};
use std::thread;
use std::time::Duration;

use crate::placeholder::is_placeholder;

/// Reads that outlived their timeout are left running (a blocking read on a stalled provider cannot
/// be cancelled); at most this many may be outstanding, and past that placeholders are deferred.
pub const MAX_STALLED_READS: usize = 4;

/// `sys/resource.h`: the I/O policy type and its values.
pub const IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES: i32 = 3;
/// The policy applies to the calling thread only.
pub const IOPOL_SCOPE_THREAD: i32 = 1;
/// The thread follows the process policy.
pub const IOPOL_MATERIALIZE_DATALESS_FILES_DEFAULT: i32 = 0;
/// Opening a dataless file fails instead of downloading it.
pub const IOPOL_MATERIALIZE_DATALESS_FILES_OFF: i32 = 1;
/// Opening a dataless file downloads it.
pub const IOPOL_MATERIALIZE_DATALESS_FILES_ON: i32 = 2;

/// Whether an errno is the kernel declining to materialize a dataless file: `EDEADLK`, or `EAGAIN`
/// from providers that decline a fetch.
#[must_use]
pub fn refused_dataless_errno(errno: i32) -> bool {
    errno == libc::EDEADLK || errno == libc::EAGAIN
}

#[cfg(target_os = "macos")]
mod iopolicy {
    use std::ffi::c_int;

    unsafe extern "C" {
        fn setiopolicy_np(iotype: c_int, scope: c_int, policy: c_int) -> c_int;
        fn getiopolicy_np(iotype: c_int, scope: c_int) -> c_int;
    }

    pub fn get() -> i32 {
        // SAFETY: plain libSystem call on scalar arguments.
        unsafe { getiopolicy_np(super::IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, super::IOPOL_SCOPE_THREAD) }
    }

    pub fn set(policy: i32) -> i32 {
        // SAFETY: plain libSystem call on scalar arguments.
        unsafe { setiopolicy_np(super::IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, super::IOPOL_SCOPE_THREAD, policy) }
    }
}

#[cfg(not(target_os = "macos"))]
mod iopolicy {
    pub fn get() -> i32 {
        -1
    }

    pub fn set(_policy: i32) -> i32 {
        -1
    }
}

/// Sets this thread's dataless-file policy; returns the previous one, or `None` where unavailable.
fn set_thread_policy(policy: i32) -> Option<i32> {
    let previous = iopolicy::get();
    if previous < 0 || iopolicy::set(policy) != 0 {
        return None;
    }
    Some(previous)
}

/// Restores the thread's previous dataless-file policy when dropped.
#[must_use = "the policy is restored when the guard is dropped"]
pub struct DatalessPolicyGuard {
    previous: Option<i32>,
}

impl DatalessPolicyGuard {
    /// Whether the policy was changed (false where the call is unavailable).
    #[must_use]
    pub fn applied(&self) -> bool {
        self.previous.is_some()
    }
}

impl Drop for DatalessPolicyGuard {
    fn drop(&mut self) {
        if let Some(previous) = self.previous {
            set_thread_policy(previous);
        }
    }
}

/// Turns dataless-file materialization off for the current thread until the guard drops. Threads
/// started meanwhile do not inherit a thread-scoped policy, which lets the download thread opt in.
pub fn refusing_dataless_reads() -> DatalessPolicyGuard {
    DatalessPolicyGuard { previous: set_thread_policy(IOPOL_MATERIALIZE_DATALESS_FILES_OFF) }
}

/// Turns materialization on for the current thread until the guard drops: the budgeted download.
pub fn allowing_dataless_reads() -> DatalessPolicyGuard {
    DatalessPolicyGuard { previous: set_thread_policy(IOPOL_MATERIALIZE_DATALESS_FILES_ON) }
}

/// Per-run cap on placeholder downloads, with what the run has done so far.
#[derive(Clone, Debug, PartialEq)]
pub struct Budget {
    /// `placeholders.materialize`: off, every placeholder is deferred.
    pub enabled: bool,
    /// At most this many files per run; 0 is unlimited.
    pub max_files: u64,
    /// At most this many bytes per run; 0 is unlimited.
    pub max_bytes: u64,
    /// How long one download may take before it is abandoned.
    pub timeout_seconds: f64,
    /// Files downloaded.
    pub files_done: u64,
    /// Bytes downloaded.
    pub bytes_done: u64,
    /// Placeholders left for a later run.
    pub deferred: u64,
    /// Downloads that failed, timed out or left a placeholder behind.
    pub failed: u64,
}

impl Default for Budget {
    fn default() -> Self {
        Self {
            enabled: false,
            max_files: 0,
            max_bytes: 0,
            timeout_seconds: 120.0,
            files_done: 0,
            bytes_done: 0,
            deferred: 0,
            failed: 0,
        }
    }
}

impl Budget {
    /// Whether the run has used its files or bytes.
    #[must_use]
    pub fn exhausted(&self) -> bool {
        (self.max_files != 0 && self.files_done >= self.max_files)
            || (self.max_bytes != 0 && self.bytes_done >= self.max_bytes)
    }

    /// `"materialized 1,234 files (0.50 GiB), deferred 3, failed 1"`, as Python words it.
    #[must_use]
    pub fn summary(&self) -> String {
        #[allow(clippy::cast_precision_loss)]
        let gib = self.bytes_done as f64 / f64::from(1u32 << 30);
        let mut parts = vec![format!("materialized {} files ({gib:.2} GiB)", grouped(self.files_done))];
        if self.deferred != 0 {
            parts.push(format!("deferred {}", grouped(self.deferred)));
        }
        if self.failed != 0 {
            parts.push(format!("failed {}", grouped(self.failed)));
        }
        parts.join(", ")
    }
}

/// Python's `f"{n:,}"`.
fn grouped(value: u64) -> String {
    let digits = value.to_string();
    let mut out = String::with_capacity(digits.len() + digits.len() / 3);
    for (index, digit) in digits.chars().enumerate() {
        if index != 0 && (digits.len() - index).is_multiple_of(3) {
            out.push(',');
        }
        out.push(digit);
    }
    out
}

/// Reads a file end to end, which is what triggers the download; returns the byte count. The content
/// is discarded: the extractor re-reads the file straight afterwards, local and warm in cache.
///
/// # Errors
///
/// The open's or a read's error.
pub fn force_read(path: &Path) -> io::Result<u64> {
    let mut file = File::open(path)?;
    let mut buffer = vec![0u8; 1 << 20];
    let mut total = 0u64;
    loop {
        match file.read(&mut buffer) {
            Ok(0) => return Ok(total),
            Ok(read) => total += read as u64,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error),
        }
    }
}

/// What one materialization attempt came to.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Outcome {
    /// The file was not a placeholder, or is local now.
    Local,
    /// Left for a later run: materialization is off, the budget is spent, or too many reads stalled.
    Deferred,
    /// The read failed, timed out, or left a placeholder behind; the message says which.
    Failed(String),
}

type Reader = dyn Fn(&Path) -> io::Result<u64> + Send + Sync;

/// Runs budgeted downloads and keeps count of reads that outlived their timeout.
pub struct Materializer {
    reader: Arc<Reader>,
    stalled: Mutex<Vec<Arc<AtomicBool>>>,
}

impl Default for Materializer {
    fn default() -> Self {
        Self::new()
    }
}

impl Materializer {
    /// A materializer that downloads with [`force_read`].
    #[must_use]
    pub fn new() -> Self {
        Self::with_reader(force_read)
    }

    /// A materializer with its own read, for tests.
    pub fn with_reader(reader: impl Fn(&Path) -> io::Result<u64> + Send + Sync + 'static) -> Self {
        Self { reader: Arc::new(reader), stalled: Mutex::new(Vec::new()) }
    }

    /// The process's materializer, which every caller shares so the stalled reads are counted once.
    pub fn shared() -> &'static Self {
        static SHARED: OnceLock<Materializer> = OnceLock::new();
        SHARED.get_or_init(Self::new)
    }

    /// Reads still running after their timeout.
    pub fn stalled_count(&self) -> usize {
        let mut stalled = self.stalled.lock().unwrap_or_else(PoisonError::into_inner);
        stalled.retain(|done| !done.load(Ordering::Acquire));
        stalled.len()
    }

    /// Runs the read on a detached thread with materialization on; `None` when it has not finished
    /// within the timeout, in which case it is counted as stalled.
    fn read_with_timeout(&self, path: &Path, timeout: Duration) -> Option<io::Result<u64>> {
        let (send, receive) = mpsc::channel();
        let done = Arc::new(AtomicBool::new(false));
        let reader = Arc::clone(&self.reader);
        let path_owned = path.to_path_buf();
        let finished = Arc::clone(&done);
        let name = format!("materialize:{}", path.file_name().map(|n| n.to_string_lossy()).unwrap_or_default());
        let spawned = thread::Builder::new().name(name).spawn(move || {
            let outcome = {
                let _policy = allowing_dataless_reads();
                reader(&path_owned)
            };
            finished.store(true, Ordering::Release);
            let _ = send.send(outcome);
        });
        if let Err(error) = spawned {
            return Some(Err(error));
        }
        let outcome = receive.recv_timeout(timeout).ok();
        if outcome.is_none() {
            self.stalled.lock().unwrap_or_else(PoisonError::into_inner).push(done);
        }
        outcome
    }

    /// Attempts to download one placeholder, charging `budget`. Never fails: anything but
    /// [`Outcome::Local`] leaves the file a placeholder.
    pub fn materialize(&self, path: &Path, budget: &mut Budget) -> Outcome {
        if !budget.enabled || budget.exhausted() {
            budget.deferred += 1;
            return Outcome::Deferred;
        }
        if self.stalled_count() >= MAX_STALLED_READS {
            budget.deferred += 1;
            return Outcome::Deferred;
        }
        let timeout = Duration::try_from_secs_f64(budget.timeout_seconds.max(0.0)).unwrap_or(Duration::MAX);
        let size = match self.read_with_timeout(path, timeout) {
            Some(Ok(size)) => size,
            Some(Err(error)) => {
                budget.failed += 1;
                return Outcome::Failed(format!("materialization failed for {}: {error}", path.display()));
            }
            None => {
                budget.failed += 1;
                return Outcome::Failed(format!(
                    "materialization timed out after {:.0}s: {}",
                    budget.timeout_seconds,
                    path.display()
                ));
            }
        };
        // The provider may hand back an empty file rather than an error: neither a success nor a
        // charge against the budget.
        if size == 0 || still_placeholder(path) {
            budget.failed += 1;
            return Outcome::Failed(format!("still a placeholder after read: {}", path.display()));
        }
        budget.files_done += 1;
        budget.bytes_done += size;
        Outcome::Local
    }

    /// Materializes `path` if it is a placeholder: the one entry point the pipeline uses, so budget
    /// accounting cannot be bypassed.
    pub fn ensure_local(&self, path: &Path, budget: &mut Budget) -> Outcome {
        if !still_placeholder(path) {
            return Outcome::Local;
        }
        self.materialize(path, budget)
    }
}

/// `is_placeholder(path)` with its own stat; a path that cannot be statted is not one.
fn still_placeholder(path: &Path) -> bool {
    std::fs::metadata(path).is_ok_and(|metadata| is_placeholder(path, &metadata))
        || path.file_name().is_some_and(|name| {
            let name = name.to_string_lossy();
            name.starts_with('.') && name.ends_with(".icloud")
        })
}

#[cfg(test)]
mod tests {
    use std::sync::Condvar;

    use super::*;

    fn budget() -> Budget {
        Budget { enabled: true, timeout_seconds: 0.05, ..Budget::default() }
    }

    /// A read that blocks until released, as a stalled provider does.
    fn gate() -> Arc<(Mutex<bool>, Condvar)> {
        Arc::new((Mutex::new(false), Condvar::new()))
    }

    fn blocked(gate: &Arc<(Mutex<bool>, Condvar)>) -> Materializer {
        let gate = Arc::clone(gate);
        Materializer::with_reader(move |_| {
            let (lock, wake) = &*gate;
            let open = lock.lock().unwrap();
            let _open = wake.wait_timeout_while(open, Duration::from_secs(10), |open| !*open).unwrap();
            Ok(0)
        })
    }

    fn release(gate: &Arc<(Mutex<bool>, Condvar)>) {
        *gate.0.lock().unwrap() = true;
        gate.1.notify_all();
    }

    #[test]
    fn a_timed_out_read_is_a_failure_and_stalls() {
        let gate = gate();
        let materializer = blocked(&gate);
        let mut budget = budget();
        assert!(matches!(materializer.materialize(Path::new("/tmp/stub"), &mut budget), Outcome::Failed(_)));
        assert_eq!(budget.failed, 1);
        assert_eq!(materializer.stalled_count(), 1);
        release(&gate);
    }

    #[test]
    fn stalled_reads_are_bounded_and_free_their_slot() {
        let gate = gate();
        let materializer = blocked(&gate);
        let mut budget = budget();
        for index in 0..MAX_STALLED_READS + 3 {
            materializer.materialize(Path::new(&format!("/tmp/stub-{index}")), &mut budget);
        }
        assert_eq!(materializer.stalled_count(), MAX_STALLED_READS);
        assert_eq!(budget.failed, MAX_STALLED_READS as u64);
        assert_eq!(budget.deferred, 3);
        release(&gate);
        for _ in 0..500 {
            if materializer.stalled_count() == 0 {
                break;
            }
            thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(materializer.stalled_count(), 0);
    }

    #[test]
    fn read_errors_count_as_failures() {
        let materializer = Materializer::new();
        let mut budget = Budget { timeout_seconds: 5.0, ..budget() };
        let outcome = materializer.materialize(Path::new("/no/such/garage/stub"), &mut budget);
        assert!(matches!(outcome, Outcome::Failed(message) if message.contains("materialization failed")));
        assert_eq!(budget.failed, 1);
        assert_eq!(materializer.stalled_count(), 0);
    }

    #[test]
    fn a_disabled_or_spent_budget_defers() {
        let materializer = Materializer::with_reader(|_| Ok(10));
        let mut off = Budget::default();
        assert_eq!(materializer.materialize(Path::new("/tmp/x"), &mut off), Outcome::Deferred);
        assert_eq!(off.deferred, 1);
        let mut spent = Budget { max_files: 1, files_done: 1, ..budget() };
        assert!(spent.exhausted());
        assert_eq!(materializer.materialize(Path::new("/tmp/x"), &mut spent), Outcome::Deferred);
        let bytes = Budget { max_bytes: 10, bytes_done: 10, ..budget() };
        assert!(bytes.exhausted());
    }

    #[test]
    fn a_read_that_leaves_a_real_file_is_charged() {
        let dir = std::env::temp_dir().join(format!("garage-materialize-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("note.md");
        std::fs::write(&file, b"hello").unwrap();
        let materializer = Materializer::new();
        let mut budget = Budget { timeout_seconds: 5.0, ..budget() };
        assert_eq!(materializer.materialize(&file, &mut budget), Outcome::Local);
        assert_eq!((budget.files_done, budget.bytes_done), (1, 5));
        // Not a placeholder: ensure_local reads nothing and charges nothing.
        assert_eq!(materializer.ensure_local(&file, &mut budget), Outcome::Local);
        assert_eq!(budget.files_done, 1);
        // An empty read is a failure, not a charge.
        let empty = Materializer::with_reader(|_| Ok(0));
        assert!(matches!(empty.materialize(&file, &mut budget), Outcome::Failed(_)));
        assert_eq!(budget.failed, 1);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn the_icloud_sidecar_is_a_placeholder_even_unreadable() {
        let materializer = Materializer::with_reader(|_| Ok(3));
        let mut budget = Budget::default();
        assert_eq!(materializer.ensure_local(Path::new("/no/such/.notes.md.icloud"), &mut budget), Outcome::Deferred);
    }

    #[test]
    fn the_summary_reads_as_python_writes_it() {
        let budget = Budget { files_done: 1234, bytes_done: 1 << 29, deferred: 3, failed: 1, ..Budget::default() };
        assert_eq!(budget.summary(), "materialized 1,234 files (0.50 GiB), deferred 3, failed 1");
        assert_eq!(Budget::default().summary(), "materialized 0 files (0.00 GiB)");
        assert_eq!(grouped(1_000_000), "1,000,000");
    }

    #[test]
    fn the_refused_errnos() {
        assert!(refused_dataless_errno(libc::EDEADLK));
        assert!(refused_dataless_errno(libc::EAGAIN));
        assert!(!refused_dataless_errno(libc::ENOENT));
    }

    #[test]
    fn the_policy_guards_nest() {
        let refusing = refusing_dataless_reads();
        {
            let allowing = allowing_dataless_reads();
            assert_eq!(allowing.applied(), refusing.applied());
        }
        if refusing.applied() {
            assert_eq!(iopolicy::get(), IOPOL_MATERIALIZE_DATALESS_FILES_OFF);
        }
    }
}

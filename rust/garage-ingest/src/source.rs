//! The loop over one walked source: `ingest/pipeline.py`'s `_ingest_source`.
//!
//! The scan's outcome is handed in (the caller runs [`crate::scanner`] or states one). A Messages database
//! (`sqlite` sources) is not walked: its threads are read by [`crate::conversations`]. Everything
//! else follows Python: a root problem fails the run before anything is stored; the scan is stored;
//! each candidate the walk yields is counted, decided by [`ingest_one`] and reported; a file whose
//! storage call fails is noted and recorded as seen, so reconcile does not take it for deleted; the
//! walk stops on cancellation or at the limit; and the run is finalized as complete only when the
//! walk ran out of files.

use std::ops::ControlFlow;
use std::path::PathBuf;

use serde_json::{Map, Value};

use crate::conversations::ingest_messages_source;
use crate::pipeline::{Context, Counters, ExistingStat, FileCandidate, FileHost, Storage, ingest_one};
use crate::walk::{WalkOptions, WalkStats, Walked, default_exclude_prefixes, walk_while};

/// A scan's outcome (`scanner.SourceScanResult`), as the facade stores it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ScanSummary {
    /// Items counted.
    pub item_count: u64,
    /// What they are: files, messages, records.
    pub item_type: String,
    /// How long the scan took.
    pub duration_seconds: f64,
    /// The scanner's details, stored verbatim.
    pub details: Map<String, Value>,
    /// Why the scan failed, when it did.
    pub error: Option<String>,
}

impl ScanSummary {
    /// Why the whole source cannot be read (`details["root_problem"]`, when truthy).
    #[must_use]
    pub fn root_problem(&self) -> Option<&Value> {
        self.details.get("root_problem").filter(|value| truthy(value))
    }
}

fn truthy(value: &Value) -> bool {
    match value {
        Value::Null => false,
        Value::Bool(flag) => *flag,
        Value::Number(number) => number.as_f64().is_some_and(|number| number != 0.0),
        Value::String(text) => !text.is_empty(),
        Value::Array(items) => !items.is_empty(),
        Value::Object(map) => !map.is_empty(),
    }
}

/// The facade calls a run makes besides each file's own.
pub trait SourceStorage: Storage {
    /// `check_stat`: what the database holds for `uri`.
    ///
    /// # Errors
    ///
    /// The call's failure.
    fn check_stat(&mut self, uri: &str) -> Result<ExistingStat, String>;

    /// `persist_scan`.
    ///
    /// # Errors
    ///
    /// The call's failure.
    fn persist_scan(&mut self, scan: &ScanSummary) -> Result<(), String>;

    /// `finalize_session`: ends the run with what it did.
    ///
    /// # Errors
    ///
    /// The call's failure.
    fn finalize(
        &mut self,
        completed: bool,
        counters: &Counters,
        materialized: u64,
        materialized_bytes: u64,
    ) -> Result<(), String>;
}

/// What a run reads files through, and tells about its progress.
pub trait SourceHost: FileHost {
    /// `is_cancelled`, asked before each file.
    fn cancelled(&mut self) -> bool {
        false
    }

    /// `progress`: `phase` is scan, ingest or cancelled; `current_item` the file's name.
    fn progress(&mut self, _phase: &str, _current_item: Option<&str>, _counters: &Counters) {}

    /// The budget's files and bytes downloaded so far.
    fn materialized(&self) -> (u64, u64) {
        (0, 0)
    }

    /// The host's cloud side, for a cloud source ([`crate::dropbox`], [`crate::onedrive`],
    /// [`crate::outlook`], [`crate::google_drive`], [`crate::gmail`]);
    /// none by default.
    fn remote(&mut self) -> Option<&mut dyn crate::dropbox::RemoteHost> {
        None
    }

    /// The names iMessage contacts shared, as `(handle, name)`, from the `NickNameCache` beside a Messages
    /// database in `directory` (`extract/nicknames.py`'s `read_shared_names`); none by default.
    fn shared_names(&mut self, _directory: &std::path::Path) -> Vec<(String, String)> {
        Vec::new()
    }
}

/// A run that reached its end.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct SourceRun {
    /// What happened to the files.
    pub counters: Counters,
    /// What the walk saw.
    pub walk_stats: WalkStats,
    /// Whether the walk ran out of files, so the run covered the whole source.
    pub completed: bool,
    /// Files a linked cloud source read from its desktop client's folder instead of downloading.
    pub read_locally: u64,
}

/// A run that failed as a whole.
#[derive(Clone, Debug, PartialEq)]
pub enum SourceError {
    /// The root cannot be read (`SourceUnavailable`); the run was finalized as incomplete.
    Unavailable(String),
    /// Storing the scan or finalizing the run failed.
    Storage(String),
}

impl std::fmt::Display for SourceError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unavailable(message) | Self::Storage(message) => f.write_str(message),
        }
    }
}

impl std::error::Error for SourceError {}

/// How much of the source to take.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SourceOptions {
    /// Walk code files too.
    pub include_code: bool,
    /// Stop after this many files.
    pub limit: Option<u64>,
    /// A Messages (`sqlite`) source: its databases are read thread by thread, not walked.
    pub messages: bool,
    /// An AI session source (`claude`, `chatgpt`, `antigravity`): read session by session, not walked.
    pub session_kind: Option<String>,
    /// A cloud source's desktop client folder on this node (`dropbox::local_folder`): a listed file
    /// whose copy there is on disk and matches is read from it instead of downloaded.
    pub local_folder: Option<PathBuf>,
    /// A `spotlight` source: list files through the Spotlight index and link existing documents as additional.
    pub spotlight: Option<crate::spotlight::SpotlightOptions>,
}

/// `st_mtime` as Python's walker hands it on: through `datetime.fromtimestamp(..., UTC).timestamp()`,
/// which rounds to the microsecond, half to even.
#[must_use]
pub fn microsecond_mtime(seconds: f64) -> f64 {
    let whole = seconds.trunc();
    let mut micros = ((seconds - whole) * 1e6).round_ties_even();
    let mut whole = whole;
    if micros >= 1e6 {
        micros -= 1e6;
        whole += 1.0;
    } else if micros < 0.0 {
        micros += 1e6;
        whole -= 1.0;
    }
    #[allow(clippy::cast_possible_truncation)]
    let total = whole as i64 * 1_000_000 + micros as i64;
    #[allow(clippy::cast_precision_loss)]
    let mtime = total as f64 / 1e6;
    mtime
}

/// `_ingest_source` for a walked source, after `begin_session` and the scan.
///
/// # Errors
///
/// [`SourceError::Unavailable`] when the scan found the root unreadable, and
/// [`SourceError::Storage`] when the scan or the run's end could not be stored.
pub fn ingest_source(
    host: &mut dyn SourceHost,
    storage: &mut dyn SourceStorage,
    context: &Context<'_>,
    scan: &ScanSummary,
    options: &SourceOptions,
) -> Result<SourceRun, SourceError> {
    let mut run = SourceRun::default();
    let finalize = |storage: &mut dyn SourceStorage, host: &dyn SourceHost, run: &SourceRun| {
        let (files, bytes) = host.materialized();
        storage.finalize(run.completed, &run.counters, files, bytes).map_err(SourceError::Storage)
    };

    if scan.root_problem().is_some() {
        // A root that cannot be read would walk as empty and finish "complete" with nothing seen.
        let problem =
            scan.error.clone().filter(|error| !error.is_empty()).unwrap_or_else(|| "source root unavailable".into());
        run.counters.note_error(problem.clone());
        finalize(storage, host, &run)?;
        return Err(SourceError::Unavailable(problem));
    }
    storage.persist_scan(scan).map_err(SourceError::Storage)?;
    host.progress("scan", None, &run.counters);

    if options.messages {
        run.completed = ingest_messages_source(host, storage, context, options.limit, &mut run.counters);
        finalize(storage, host, &run)?;
        if host.cancelled() {
            host.progress("cancelled", None, &run.counters);
        }
        return Ok(run);
    }

    if let Some(kind) = options.session_kind.as_deref() {
        run.completed =
            crate::sessions::ingest_sessions_source(host, storage, context, kind, options.limit, &mut run.counters);
        finalize(storage, host, &run)?;
        if host.cancelled() {
            host.progress("cancelled", None, &run.counters);
        }
        return Ok(run);
    }

    if let Some(spotlight) = options.spotlight.as_ref() {
        run.completed = crate::spotlight::ingest_spotlight_source(
            host,
            storage,
            context,
            options.include_code,
            options.limit,
            spotlight,
            &mut run,
        )
        .map_err(SourceError::Unavailable)?;
        finalize(storage, host, &run)?;
        return Ok(run);
    }

    let root = &context.source.root;
    let walk_options =
        WalkOptions { include_code: options.include_code, exclude_prefixes: default_exclude_prefixes(root) };
    let walked = walk_while(root, context.policy, &walk_options, &mut run.walk_stats, |found| {
        let candidate = FileCandidate {
            uri: found.path.to_string_lossy().into_owned(),
            path: found.path,
            size: found.size,
            mtime: microsecond_mtime(found.mtime),
            placeholder: found.placeholder,
        };
        let name = candidate.name();
        if host.cancelled() {
            host.progress("cancelled", Some(&name), &run.counters);
            return ControlFlow::Break(());
        }
        run.counters.seen += 1;
        let outcome = storage
            .check_stat(&candidate.uri)
            .and_then(|existing| ingest_one(host, storage, &existing, &candidate, context, &mut run.counters));
        if let Err(error) = outcome {
            run.counters.note_error(format!("{name}: {error}"));
            // The file is still there; without a seen row reconcile would treat it as deleted.
            let _ = storage.record_seen(&candidate.uri);
        }
        host.progress("ingest", Some(&name), &run.counters);
        if options.limit.is_some_and(|limit| run.counters.seen >= limit) {
            return ControlFlow::Break(());
        }
        ControlFlow::Continue(())
    });
    run.completed = walked != Walked::Stopped;
    finalize(storage, host, &run)?;
    Ok(run)
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::{Path, PathBuf};

    use super::*;
    use crate::attribution::{NoGit, SelfIdentity, TrustTier};
    use crate::pipeline::{DocumentPayload, IngestSettings, ReadOutcome, SourceInfo};
    use crate::policy::WalkPolicy;

    struct Tree(PathBuf);

    impl Tree {
        fn new(name: &str, files: &[&str]) -> Self {
            let root = std::env::temp_dir().join(format!("garage-ingest-source-{name}-{}", std::process::id()));
            let _ = fs::remove_dir_all(&root);
            for file in files {
                let path = root.join(file);
                fs::create_dir_all(path.parent().unwrap()).unwrap();
                fs::write(path, "x").unwrap();
            }
            fs::create_dir_all(&root).unwrap();
            Self(root)
        }
    }

    impl Drop for Tree {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    /// Every file is unreadable, so each ends in one `record_extract_failed`.
    #[derive(Default)]
    struct Host {
        cancel_after: Option<usize>,
        asked: usize,
        phases: Vec<String>,
    }

    impl FileHost for Host {
        fn ensure_local(&mut self, _: &FileCandidate) -> bool {
            true
        }

        fn source_sha256(&mut self, _: &FileCandidate) -> Option<String> {
            Some("ab".repeat(32))
        }

        fn read(&mut self, _: &FileCandidate) -> ReadOutcome {
            ReadOutcome::Failed("broken".into())
        }
    }

    impl SourceHost for Host {
        fn cancelled(&mut self) -> bool {
            self.asked += 1;
            self.cancel_after.is_some_and(|after| self.asked > after)
        }

        fn progress(&mut self, phase: &str, _: Option<&str>, _: &Counters) {
            self.phases.push(phase.to_owned());
        }
    }

    #[derive(Default)]
    struct Recorded {
        calls: Vec<String>,
        failing_stat: bool,
        finalized: Option<bool>,
    }

    impl Storage for Recorded {
        fn record_seen(&mut self, uri: &str) -> Result<(), String> {
            self.calls.push(format!("seen {}", Path::new(uri).file_name().unwrap().to_string_lossy()));
            Ok(())
        }
        fn record_placeholder(&mut self, _: &str, _: f64, _: &str, _: &str) -> Result<(), String> {
            unreachable!()
        }
        fn record_no_text(&mut self, _: &str, _: u64, _: f64, _: &str) -> Result<(), String> {
            unreachable!()
        }
        fn record_extract_failed(&mut self, uri: &str, _: &str, _: u64, _: f64, _: &str) -> Result<(), String> {
            self.calls.push(format!("failed {}", Path::new(uri).file_name().unwrap().to_string_lossy()));
            Ok(())
        }
        fn record_rejected(&mut self, _: &str) -> Result<(), String> {
            unreachable!()
        }
        fn refresh_metadata(&mut self, _: &str, _: u64, _: f64, _: &str, _: &str, _: &str) -> Result<(), String> {
            unreachable!()
        }
        fn replace_document(&mut self, _: &str, _: DocumentPayload) -> Result<usize, String> {
            unreachable!()
        }
    }

    impl SourceStorage for Recorded {
        fn check_stat(&mut self, _: &str) -> Result<ExistingStat, String> {
            if self.failing_stat { Err("the facade is down".into()) } else { Ok(ExistingStat::default()) }
        }
        fn persist_scan(&mut self, _: &ScanSummary) -> Result<(), String> {
            self.calls.push("scan".into());
            Ok(())
        }
        fn finalize(&mut self, completed: bool, _: &Counters, _: u64, _: u64) -> Result<(), String> {
            self.finalized = Some(completed);
            Ok(())
        }
    }

    fn ingest(
        tree: &Tree,
        host: &mut Host,
        storage: &mut Recorded,
        scan: &ScanSummary,
        limit: Option<u64>,
    ) -> Result<SourceRun, SourceError> {
        let source =
            SourceInfo { root: tree.0.clone(), default_class: "document".into(), default_trust: TrustTier::Authored };
        let identity = SelfIdentity::new("", &[]);
        let settings = IngestSettings::default();
        let policy = WalkPolicy::default();
        let context = Context {
            source: &source,
            identity: &identity,
            git: &NoGit,
            contact_names: None,
            settings: &settings,
            policy: &policy,
            force: false,
        };
        ingest_source(
            host,
            storage,
            &context,
            scan,
            &SourceOptions { include_code: false, limit, ..SourceOptions::default() },
        )
    }

    #[test]
    #[allow(clippy::float_cmp)] // The stored value must be Python's to the bit.
    fn mtimes_are_rounded_to_the_microsecond_as_python_does() {
        assert_eq!(microsecond_mtime(1_793_695_522.587_595_2), 1_793_695_522.587_595);
        assert_eq!(microsecond_mtime(1_700_000_000.25), 1_700_000_000.25);
        assert_eq!(microsecond_mtime(1.999_999_9), 2.0);
        assert_eq!(microsecond_mtime(-1.25), -1.25);
    }

    #[test]
    fn every_file_is_decided_and_the_run_completes() {
        let tree = Tree::new("all", &["a.md", "b/c.md"]);
        let (mut host, mut storage) = (Host::default(), Recorded::default());
        let run = ingest(&tree, &mut host, &mut storage, &ScanSummary::default(), None).unwrap();
        assert_eq!(storage.calls, ["scan", "failed a.md", "failed c.md"]);
        assert_eq!((run.counters.seen, run.counters.failed, run.completed), (2, 2, true));
        assert_eq!(storage.finalized, Some(true));
        assert_eq!(host.phases, ["scan", "ingest", "ingest"]);
    }

    #[test]
    fn a_limit_or_a_cancel_leaves_the_run_incomplete() {
        let tree = Tree::new("stop", &["a.md", "b.md", "c.md"]);
        let (mut host, mut storage) = (Host::default(), Recorded::default());
        let run = ingest(&tree, &mut host, &mut storage, &ScanSummary::default(), Some(2)).unwrap();
        assert_eq!((run.counters.seen, run.completed, storage.finalized), (2, false, Some(false)));

        let (mut host, mut storage) = (Host { cancel_after: Some(1), ..Host::default() }, Recorded::default());
        let run = ingest(&tree, &mut host, &mut storage, &ScanSummary::default(), None).unwrap();
        assert_eq!((run.counters.seen, run.completed), (1, false));
        assert_eq!(host.phases, ["scan", "ingest", "cancelled"]);
    }

    #[test]
    fn a_failed_call_is_noted_and_the_file_recorded_as_seen() {
        let tree = Tree::new("failing", &["a.md"]);
        let (mut host, mut storage) = (Host::default(), Recorded { failing_stat: true, ..Recorded::default() });
        let run = ingest(&tree, &mut host, &mut storage, &ScanSummary::default(), None).unwrap();
        assert_eq!(storage.calls, ["scan", "seen a.md"]);
        assert_eq!(run.counters.errors, ["a.md: the facade is down"]);
        assert!(run.completed);
    }

    #[test]
    fn an_unreadable_root_fails_the_run_before_the_scan_is_stored() {
        let tree = Tree::new("gone", &[]);
        let mut details = Map::new();
        details.insert("root_problem".into(), Value::String("missing".into()));
        let scan = ScanSummary { details, error: Some("root is missing".into()), ..ScanSummary::default() };
        let (mut host, mut storage) = (Host::default(), Recorded::default());
        let outcome = ingest(&tree, &mut host, &mut storage, &scan, None);
        assert_eq!(outcome, Err(SourceError::Unavailable("root is missing".into())));
        assert!(storage.calls.is_empty());
        assert_eq!(storage.finalized, Some(false));
    }
}

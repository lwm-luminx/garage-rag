//! A `spotlight` source: the files Spotlight's index holds under a folder, read from disk, and
//! linking any file already indexed by another source as an `additional` source rather than
//! duplicating chunks or vectors.
//!
//! Where a `filesystem` source walks a folder itself, this kind asks Spotlight which files the
//! folder holds ([`garage_spotlight::index::search`], an `MDQuery` scoped to the root, with
//! [`garage_spotlight::index::DEFAULT_QUERY`] narrowed by the source's own query when it has one).
//! Each path goes through the walk's rules (hidden, excluded and diagnostic folders, package
//! caches, extensions including Apple's Spotlight importer extensions, code, size, excluded
//! prefixes, cloud placeholders), and its URI is its path on disk.
//!
//! Two paths diverge at [`SourceStorage::check_stat`]:
//!
//! - If another source already owns a `documents` row at that URI (`existing_document_id.is_some()`),
//!   this source does **not** duplicate the document or re-read/re-chunk the file. If unchanged at
//!   the linked mtime it fast-skips with `record_seen`; otherwise it reads Spotlight's `MDItem`
//!   attributes ([`describe_attributes`]) and calls `link_additional` so `document_sources` records
//!   the additional source and non-destructively enriches `meta.spotlight`, fallback title, and
//!   authors.
//! - Otherwise, the file is read from disk (with system Spotlight `.mdimporter` plug-ins enabled
//!   for document types Garage has no built-in reader for), enriched with `MDItem` attributes
//!   ([`describe`]), and decided by [`ingest_one`].
//!
//! Privacy: the index is asked on this machine only, and personal records never come out of it.
//! Items whose type is a contact, calendar event, mail message, Messages transcript or photo
//! library are dropped by `garage-spotlight`, and so is anything under a private folder of the
//! home folder ([`private_path`]: Mail, Messages, Calendars, Contacts, Notes, Safari, keychains,
//! photo libraries, and all of `~/Library` for a root outside it). `kMDItemWhereFroms` is sanitized
//! to drop query strings, fragments, user info, and non-URL entries.

use std::fs;
use std::ops::ControlFlow;
use std::path::{Component, Path, PathBuf};
use std::time::Instant;

use garage_spotlight::index::{self, IndexedItem, Value as IndexValue};
use serde_json::{Map, Value, json};

use crate::pipeline::{
    AuthorPayload, Context, ExistingStat, Extracted, FileCandidate, FileHost, ReadOutcome, ingest_one, name_authors,
};
use crate::policy::WalkPolicy;
use crate::scanner::{ScanOptions, ScanResult, Ticker};
use crate::source::{SourceHost, SourceRun, SourceStorage, microsecond_mtime};
use crate::walk::{
    Candidate, WalkOptions, WalkStats, consider, expand_home, is_dependency_path, is_diagnostic_dir, is_hidden,
    relative_posix,
};

/// The kind's name.
pub const KIND: &str = "spotlight";

/// Folders below the home folder whose files are personal records or secrets, never taken from the
/// index whatever their type.
pub const PRIVATE_HOME_PREFIXES: &[&str] = &[
    "Library/Mail",
    "Library/Messages",
    "Library/Calendars",
    "Library/Application Support/AddressBook",
    "Library/Application Support/CallHistoryDB",
    "Library/Application Support/CallHistoryTransactions",
    "Library/Containers/com.apple.mail",
    "Library/Containers/com.apple.MobileSMS",
    "Library/Containers/com.apple.iChat",
    "Library/Containers/com.apple.Notes",
    "Library/Containers/com.apple.AddressBook",
    "Library/Containers/com.apple.iCal",
    "Library/Containers/com.apple.Photos",
    "Library/Group Containers/group.com.apple.notes",
    "Library/Group Containers/group.com.apple.reminders",
    "Library/Safari",
    "Library/Cookies",
    "Library/Keychains",
    "Library/Suggestions",
    "Library/Photos",
    "Library/Metadata/CoreSpotlight",
];

/// What a Spotlight source asks the index for.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SpotlightOptions {
    /// A Spotlight query that narrows [`index::DEFAULT_QUERY`] (`kMDItemLastUsedDate >=
    /// $time.today(-30)`, say); none takes every document.
    pub query: Option<String>,
}

/// Returns `base` extended with all extensions supported by system Spotlight importers so both
/// `scan` and `ingest` include them.
#[must_use]
pub fn policy_with_importers(base: &WalkPolicy) -> WalkPolicy {
    let mut policy = base.clone();
    policy.indexable_extensions.extend(garage_spotlight::extensions().iter().cloned());
    policy
}

/// What the index listed that the walk's own counts do not show.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Listed {
    /// Items the index returned under the root.
    pub items: u64,
    /// Items under a private folder ([`private_path`]).
    pub private: u64,
}

/// A path's real form, when it has one: the index reports real paths, not a symlinked root's.
fn real(path: &Path) -> PathBuf {
    fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf())
}

fn home() -> Option<PathBuf> {
    let home = expand_home(Path::new("~"));
    (home != Path::new("~")).then(|| real(&home))
}

/// Whether `path` (real) is under one of [`PRIVATE_HOME_PREFIXES`] of `home`, inside a photo
/// library, or anywhere in `~/Library` when the source's `root` (real) is not itself inside it.
#[must_use]
pub fn private_path(path: &Path, root: &Path, home: Option<&Path>) -> bool {
    let library_bundle = path.components().any(|component| {
        let name = component.as_os_str().to_string_lossy().to_lowercase();
        name.ends_with(".photoslibrary") || name.ends_with(".photolibrary") || name == "iphoto library"
    });
    if library_bundle {
        return true;
    }
    let Some(home) = home else { return false };
    if PRIVATE_HOME_PREFIXES.iter().any(|prefix| path.starts_with(home.join(prefix))) {
        return true;
    }
    let library = home.join("Library");
    path.starts_with(&library) && !root.starts_with(&library)
}

/// Why the walk would not have gone into the folder holding `path` (below `root`): a hidden,
/// excluded or diagnostic folder, a package cache, or one of the root's excluded prefixes. The walk's
/// counter for it is moved.
fn pruned(path: &Path, root: &Path, policy: &WalkPolicy, prefixes: &[String], stats: &mut WalkStats) -> bool {
    let Some(parent) = path.parent() else { return true };
    let Ok(relative) = parent.strip_prefix(root) else { return true };
    for component in relative.components() {
        let Component::Normal(name) = component else { continue };
        let name = name.to_string_lossy();
        if policy.exclude_dirs.contains(name.as_ref()) || is_hidden(&name) {
            stats.skipped_excluded_dir += 1;
            return true;
        }
        if is_diagnostic_dir(&name, policy) {
            stats.skipped_diagnostic += 1;
            return true;
        }
    }
    let relative = relative_posix(parent, root).unwrap_or_default();
    if relative != "."
        && (is_dependency_path(&format!("/{relative}/"), policy)
            || prefixes.iter().any(|prefix| format!("{relative}/").starts_with(prefix.as_str())))
    {
        stats.skipped_excluded_dir += 1;
        return true;
    }
    false
}

/// Filters `items` returned by Spotlight through privacy rules and the walk policy under `root`
/// (with `real_root` and `home` resolved).
#[allow(clippy::too_many_arguments)]
pub fn filter_items(
    root: &Path,
    real_root: &Path,
    home: Option<&Path>,
    items: &[IndexedItem],
    policy: &WalkPolicy,
    include_code: bool,
    exclude_prefixes: &[String],
    stats: &mut WalkStats,
    listed: &mut Listed,
) -> Vec<Candidate> {
    let effective_policy = policy_with_importers(policy);
    let walk_options = WalkOptions { include_code, exclude_prefixes: Vec::new() };
    let mut found = Vec::new();
    for item in items {
        let Ok(relative) = item.path.strip_prefix(real_root) else { continue };
        if relative.as_os_str().is_empty() {
            continue;
        }
        listed.items += 1;
        if private_path(&item.path, real_root, home) {
            listed.private += 1;
            continue;
        }
        let path = root.join(relative);
        if pruned(&path, root, &effective_policy, exclude_prefixes, stats) {
            continue;
        }
        if fs::metadata(&path).is_ok_and(|metadata| metadata.is_dir()) {
            continue;
        }
        let (Some(parent), Some(name)) = (path.parent(), path.file_name()) else { continue };
        stats.files_seen += 1;
        if let Some(candidate) = consider(parent, &name.to_string_lossy(), &effective_policy, &walk_options, stats) {
            stats.yielded += 1;
            found.push(candidate);
        }
    }
    found
}

/// The files of a Spotlight source, in path order: what the index holds under `root` (after `~` is
/// expanded), through the privacy rules and the walk's rules (including Spotlight importer
/// extensions). A candidate's path is spelled under `root` as given, even when the index answered
/// with the real path of a symlinked root.
///
/// # Errors
///
/// Why the index could not be searched (not a Mac, a query it cannot parse, a refusal).
pub fn candidates(
    root: &Path,
    policy: &WalkPolicy,
    include_code: bool,
    exclude_prefixes: &[String],
    spotlight: &SpotlightOptions,
    stats: &mut WalkStats,
    listed: &mut Listed,
) -> Result<Vec<Candidate>, String> {
    let root = expand_home(root);
    let real_root = real(&root);
    let home = home();
    let items = index::search(&real_root, &index::query_string(spotlight.query.as_deref()))?;
    Ok(filter_items(&root, &real_root, home.as_deref(), &items, policy, include_code, exclude_prefixes, stats, listed))
}

/// Counts a Spotlight source's files as a run will see them (`scan_source` for this kind). An index
/// that cannot be searched fails the scan with a `root_problem`, so the run that follows stops
/// instead of finishing "complete" with nothing seen.
pub fn scan_spotlight(
    root: &Path,
    source_slug: &str,
    options: &ScanOptions<'_>,
    exclude_prefixes: &[String],
    ticker: &mut Ticker<'_>,
) -> ScanResult {
    let started = Instant::now();
    let spotlight = options.spotlight.cloned().unwrap_or_default();
    let mut result = ScanResult::new(source_slug, KIND, root, "files");
    let mut stats = WalkStats::default();
    let mut listed = Listed::default();
    match candidates(root, options.policy, options.include_code, exclude_prefixes, &spotlight, &mut stats, &mut listed)
    {
        Ok(found) => {
            result.item_count = found.len() as u64;
            ticker.report_count(result.item_count);
            result.details = json_map(json!({
                "files": result.item_count,
                "spotlight_items": listed.items,
                "skipped_private": listed.private,
                "skipped_extensions": stats.skipped_extension,
                "query": index::query_string(spotlight.query.as_deref()),
            }));
        }
        Err(problem) => {
            result.details.insert("root_problem".to_owned(), json!(problem));
            result.error = Some(problem);
        }
    }
    result.duration_seconds = started.elapsed().as_secs_f64();
    result
}

fn json_map(value: Value) -> Map<String, Value> {
    match value {
        Value::Object(map) => map,
        _ => Map::new(),
    }
}

/// The run over a Spotlight source, after its scan was stored: each file the index lists is either
/// linked as an additional source if already in Garage's index under another source, or read and
/// indexed under this Spotlight source. `Ok` says whether the list ran out (so the run covered the
/// whole source).
///
/// # Errors
///
/// Why the index could not be searched.
pub fn ingest_spotlight_source(
    host: &mut dyn SourceHost,
    storage: &mut dyn SourceStorage,
    context: &Context<'_>,
    include_code: bool,
    limit: Option<u64>,
    spotlight: &SpotlightOptions,
    run: &mut SourceRun,
) -> Result<bool, String> {
    let root = &context.source.root;
    let prefixes = crate::walk::default_exclude_prefixes(&expand_home(root));
    let mut listed = Listed::default();
    let found = candidates(root, context.policy, include_code, &prefixes, spotlight, &mut run.walk_stats, &mut listed)?;
    Ok(ingest_candidates(host, storage, context, &found, limit, &|path| index::attributes(&real(path)), run))
}

/// Processes pre-resolved [`Candidate`]s with a pluggable attribute reader (used by both live
/// Spotlight ingest and unit tests).
pub fn ingest_candidates(
    host: &mut dyn SourceHost,
    storage: &mut dyn SourceStorage,
    context: &Context<'_>,
    found: &[Candidate],
    limit: Option<u64>,
    read_attrs: &dyn Fn(&Path) -> Vec<(String, IndexValue)>,
    run: &mut SourceRun,
) -> bool {
    for found in found {
        let candidate = FileCandidate {
            uri: found.path.to_string_lossy().into_owned(),
            path: found.path.clone(),
            size: found.size,
            mtime: microsecond_mtime(found.mtime),
            placeholder: found.placeholder,
        };
        if visit(host, storage, context, run, &candidate, limit, read_attrs).is_break() {
            return false;
        }
    }
    true
}

/// One candidate file: either linked to an existing document as additional, or ingested as a primary
/// document owned by the Spotlight source.
fn visit(
    host: &mut dyn SourceHost,
    storage: &mut dyn SourceStorage,
    context: &Context<'_>,
    run: &mut SourceRun,
    candidate: &FileCandidate,
    limit: Option<u64>,
    read_attrs: &dyn Fn(&Path) -> Vec<(String, IndexValue)>,
) -> ControlFlow<()> {
    let name = candidate.name();
    if host.cancelled() {
        host.progress("cancelled", Some(&name), &run.counters);
        return ControlFlow::Break(());
    }
    run.counters.seen += 1;
    let outcome = storage.check_stat(&candidate.uri).and_then(|existing| {
        if existing.existing_document_id.is_some() {
            link_existing(storage, &existing, candidate, context, &mut run.counters, read_attrs)
        } else {
            let mut described = Described { inner: &mut *host, read_attrs };
            ingest_one(&mut described, storage, &existing, candidate, context, &mut run.counters)
        }
    });
    if let Err(error) = outcome {
        run.counters.note_error(format!("{name}: {error}"));
        // The file is still there; without a seen row reconcile would treat it as deleted.
        let _ = storage.record_seen(&candidate.uri);
    }
    host.progress("ingest", Some(&name), &run.counters);
    if limit.is_some_and(|limit| run.counters.seen >= limit) {
        return ControlFlow::Break(());
    }
    ControlFlow::Continue(())
}

/// Links the Spotlight source to an already-indexed document owned by another source without
/// reading file bytes or duplicating chunks/embeddings.
fn link_existing(
    storage: &mut dyn SourceStorage,
    existing: &ExistingStat,
    candidate: &FileCandidate,
    context: &Context<'_>,
    counters: &mut crate::pipeline::Counters,
    read_attrs: &dyn Fn(&Path) -> Vec<(String, IndexValue)>,
) -> Result<(), String> {
    let same_mtime = existing.mtime > 0.0 && (existing.mtime - candidate.mtime).abs() < 1.0;
    if !context.force && existing.already_linked && same_mtime {
        counters.skipped += 1;
        return storage.record_seen(&candidate.uri);
    }
    let attrs = read_attrs(&candidate.path);
    let described = describe_attributes(&attrs);
    let mut meta = Map::new();
    if !described.spotlight.is_empty() {
        meta.insert("spotlight".to_owned(), Value::Object(described.spotlight));
    }
    let title = described.title.or(described.display_name);
    let raw_authors: Vec<AuthorPayload> = described
        .authors
        .into_iter()
        .map(|name| {
            let is_self = context.identity.matches(Some(&name), None);
            AuthorPayload {
                name,
                role: "author".to_owned(),
                confidence: 0.85,
                evidence: "spotlight:kMDItemAuthors".to_owned(),
                identities: Vec::new(),
                is_self,
            }
        })
        .collect();
    let authors = name_authors(raw_authors, context.contact_names);
    storage.link_additional(&candidate.uri, candidate.mtime, title.as_deref(), &meta, &authors)?;
    counters.indexed += 1;
    Ok(())
}

/// The host's reading, with each document described by what the index knows about its file.
struct Described<'a> {
    inner: &'a mut dyn SourceHost,
    read_attrs: &'a dyn Fn(&Path) -> Vec<(String, IndexValue)>,
}

impl FileHost for Described<'_> {
    fn ensure_local(&mut self, candidate: &FileCandidate) -> bool {
        self.inner.ensure_local(candidate)
    }

    fn source_sha256(&mut self, candidate: &FileCandidate) -> Option<String> {
        self.inner.source_sha256(candidate)
    }

    fn read(&mut self, candidate: &FileCandidate) -> ReadOutcome {
        match self.inner.read(candidate) {
            ReadOutcome::Document(mut document) => {
                describe(&mut document, &(self.read_attrs)(&candidate.path));
                ReadOutcome::Document(document)
            }
            outcome => outcome,
        }
    }
}

/// Extracted Spotlight `MDItem` attributes ready for document metadata or linking.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct SpotlightDescription {
    pub spotlight: Map<String, Value>,
    pub title: Option<String>,
    pub display_name: Option<String>,
    pub authors: Vec<String>,
}

fn strip_nul(s: String) -> String {
    if s.contains('\0') { s.replace('\0', "") } else { s }
}

/// A Spotlight date as RFC 3339, in UTC.
fn date(seconds: f64) -> Option<String> {
    #[allow(clippy::cast_possible_truncation)]
    let whole = seconds.floor() as i64;
    #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
    let nanos = ((seconds - seconds.floor()) * 1e9) as u32;
    chrono::DateTime::from_timestamp(whole, nanos).map(|time| time.to_rfc3339_opts(chrono::SecondsFormat::Secs, true))
}

/// A download origin without what could be a credential: the URL's query, fragment and user info are
/// dropped. Anything that is not a URL (Mail records an attachment's sender and subject here) is
/// left out: a communication's details stay with the communication.
pub(crate) fn origin(entry: &str) -> Option<String> {
    let entry = entry.trim();
    let (scheme, rest) = entry.split_once("://")?;
    if !matches!(scheme.to_ascii_lowercase().as_str(), "http" | "https" | "ftp" | "ftps") {
        return None;
    }
    let rest = rest.split(['?', '#']).next().unwrap_or_default();
    let (authority, path) = rest.split_once('/').map_or((rest, ""), |(authority, path)| (authority, path));
    let host = authority.rsplit_once('@').map_or(authority, |(_, host)| host);
    if host.is_empty() {
        return None;
    }
    Some(if path.is_empty() { format!("{scheme}://{host}") } else { format!("{scheme}://{host}/{path}") })
}

fn text_of(value: &IndexValue) -> Option<String> {
    match value {
        IndexValue::Text(text) => Some(strip_nul(text.trim().to_owned())).filter(|text| !text.is_empty()),
        IndexValue::List(items) => {
            items.iter().map(|item| strip_nul(item.trim().to_owned())).find(|item| !item.is_empty())
        }
        _ => None,
    }
}

fn list_of(value: &IndexValue) -> Vec<String> {
    match value {
        IndexValue::Text(text) => vec![strip_nul(text.trim().to_owned())],
        IndexValue::List(items) => items.iter().map(|item| strip_nul(item.trim().to_owned())).collect(),
        _ => Vec::new(),
    }
    .into_iter()
    .filter(|item| !item.is_empty())
    .collect()
}

/// Parses Spotlight `MDItem` attributes into sanitized JSON metadata, optional title/display name,
/// and author names (with NUL characters stripped).
#[must_use]
pub fn describe_attributes(attributes: &[(String, IndexValue)]) -> SpotlightDescription {
    let mut out = SpotlightDescription::default();
    for (name, value) in attributes {
        let (key, described) = match name.as_str() {
            "kMDItemDisplayName" => {
                out.display_name = text_of(value);
                ("display_name", out.display_name.clone().map(Value::String))
            }
            "kMDItemContentType" => ("content_type", text_of(value).map(Value::String)),
            "kMDItemKind" => ("kind", text_of(value).map(Value::String)),
            "kMDItemCreator" => ("creator", text_of(value).map(Value::String)),
            "kMDItemTitle" => {
                out.title = text_of(value);
                ("title", out.title.clone().map(Value::String))
            }
            "kMDItemAuthors" => {
                out.authors = list_of(value);
                ("authors", (!out.authors.is_empty()).then(|| json!(out.authors)))
            }
            "kMDItemKeywords" => {
                let keywords = list_of(value);
                ("keywords", (!keywords.is_empty()).then(|| json!(keywords)))
            }
            "kMDItemWhereFroms" => {
                let mut origins: Vec<String> = list_of(value).iter().filter_map(|entry| origin(entry)).collect();
                origins.dedup();
                ("where_froms", (!origins.is_empty()).then(|| json!(origins)))
            }
            "kMDItemUseCount" => match value {
                #[allow(clippy::cast_possible_truncation)]
                IndexValue::Number(count) if *count >= 0.0 => ("use_count", Some(json!(count.round() as i64))),
                _ => continue,
            },
            "kMDItemLastUsedDate" | "kMDItemContentCreationDate" | "kMDItemContentModificationDate" => {
                let key = match name.as_str() {
                    "kMDItemLastUsedDate" => "last_used",
                    "kMDItemContentCreationDate" => "created",
                    _ => "modified",
                };
                match value {
                    IndexValue::Date(seconds) => (key, date(*seconds).map(Value::String)),
                    _ => continue,
                }
            }
            _ => continue,
        };
        if let Some(described) = described {
            out.spotlight.insert(key.to_owned(), described);
        }
    }
    out
}

/// Adds what the index knows about a document's file (`attributes`, from
/// [`index::attributes`]) to its metadata as a `spotlight` object, and gives a document with no
/// title or authors of its own Spotlight's.
pub fn describe(document: &mut Extracted, attributes: &[(String, IndexValue)]) {
    let described = describe_attributes(attributes);
    if described.spotlight.is_empty() {
        return;
    }
    if document.title.as_deref().is_none_or(|own| own.trim().is_empty())
        && let Some(title) = described.title
    {
        document.title = Some(title);
    }
    if document.author_hints.is_empty() {
        document.author_hints = described.authors;
    }
    document.meta.insert("spotlight".to_owned(), Value::Object(described.spotlight));
}

#[cfg(test)]
mod tests;

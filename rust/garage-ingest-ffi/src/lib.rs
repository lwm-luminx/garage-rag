//! The ingest pieces' C ABI, declared in `include/garage_ingest.h`: each call takes a JSON request
//! and fills `result` with JSON, which Swift, .NET and Python's ctypes read without generated code.

use std::collections::BTreeMap;
use std::ffi::{CStr, CString, c_char, c_void};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use garage_ingest::attribution::{AuthorTally, GitHistory, RepoAttribution, SelfIdentity, Signals, TrustTier};
use garage_ingest::contact_names::ContactNames;
use garage_ingest::facade::{self, Connection, GrpcStorage, GrpcTarget};
use garage_ingest::pipeline::{
    self, Context, Counters, DocumentPayload, ExistingStat, Extracted, FileCandidate, FileHost, IngestSettings,
    ReadOutcome, SourceInfo, Storage,
};
use garage_ingest::scanner::{ScanOptions, Ticker, scan_source};
use garage_ingest::source::{self, ScanSummary, SourceError, SourceHost, SourceOptions};
use garage_ingest::{
    Budget, ContentKind, LibGitHistory, Materializer, Outcome as Materialized, WalkOptions, WalkPolicy, WalkStats,
    Walked,
};
use serde_json::{Map, Value, json};

mod service;

/// The call succeeded; the result is its JSON.
pub const GARAGE_INGEST_OK: i32 = 0;
/// The request was not valid JSON of the expected shape, or a pointer was null.
pub const GARAGE_INGEST_BAD_REQUEST: i32 = 1;
/// The library panicked. The process is unharmed.
pub const GARAGE_INGEST_PANIC: i32 = 2;

type Outcome = Result<Value, String>;

/// Parses `request`, runs `work` on it and writes its JSON (or `{"error": ...}`) to `*result`.
fn call(request: *const c_char, result: *mut *mut c_char, work: impl FnOnce(&Map<String, Value>) -> Outcome) -> i32 {
    let (status, value) = catch_unwind(AssertUnwindSafe(|| {
        if request.is_null() {
            return (GARAGE_INGEST_BAD_REQUEST, json!({ "error": "the request pointer was null" }));
        }
        // SAFETY: the caller passes a NUL-terminated string.
        let request = unsafe { CStr::from_ptr(request) };
        let request = match serde_json::from_slice::<Value>(request.to_bytes()) {
            Ok(Value::Object(request)) => request,
            Ok(_) => return (GARAGE_INGEST_BAD_REQUEST, json!({ "error": "the request is not a JSON object" })),
            Err(error) => {
                return (GARAGE_INGEST_BAD_REQUEST, json!({ "error": format!("the request is not JSON: {error}") }));
            }
        };
        match work(&request) {
            Ok(value) => (GARAGE_INGEST_OK, value),
            Err(error) => (GARAGE_INGEST_BAD_REQUEST, json!({ "error": error })),
        }
    }))
    .unwrap_or_else(|panic| {
        let message = panic
            .downcast_ref::<&str>()
            .map(|text| (*text).to_owned())
            .or_else(|| panic.downcast_ref::<String>().cloned())
            .unwrap_or_else(|| "the ingest library panicked".to_owned());
        (GARAGE_INGEST_PANIC, json!({ "error": message }))
    });
    if !result.is_null() {
        let text = CString::new(value.to_string()).unwrap_or_default();
        // SAFETY: the caller passes a writable pointer.
        unsafe { *result = text.into_raw() };
    }
    status
}

fn root(request: &Map<String, Value>) -> Result<PathBuf, String> {
    request
        .get("root")
        .and_then(Value::as_str)
        .map(PathBuf::from)
        .ok_or_else(|| "the request has no \"root\" string".to_owned())
}

fn walk(request: &Map<String, Value>) -> Outcome {
    let root = root(request)?;
    let policy = match request.get("policy") {
        None | Some(Value::Null) => WalkPolicy::default(),
        Some(Value::Object(overrides)) => WalkPolicy::with_overrides(overrides).map_err(|error| error.to_string())?,
        Some(_) => return Err("\"policy\" is not an object".to_owned()),
    };
    let include_code = request.get("include_code").and_then(Value::as_bool).unwrap_or(false);
    let expanded = garage_ingest::walk::expand_home(&root);
    let exclude_prefixes = match request.get("exclude_prefixes") {
        None | Some(Value::Null) => Vec::new(),
        Some(Value::String(word)) if word == "default" => garage_ingest::default_exclude_prefixes(&expanded),
        Some(Value::Array(items)) => items
            .iter()
            .map(|item| {
                item.as_str().map(str::to_owned).ok_or_else(|| "\"exclude_prefixes\" holds a non-string".to_owned())
            })
            .collect::<Result<_, _>>()?,
        Some(_) => return Err("\"exclude_prefixes\" is not a list or \"default\"".to_owned()),
    };
    let options = WalkOptions { include_code, exclude_prefixes };
    let mut stats = WalkStats::default();
    let mut candidates = Vec::new();
    let walked = garage_ingest::walk(&root, &policy, &options, &mut stats, |candidate| {
        candidates.push(json!({
            "path": candidate.path.to_string_lossy(),
            "size": candidate.size,
            "mtime": candidate.mtime,
            "placeholder": candidate.placeholder,
        }));
    });
    let stats: Map<String, Value> =
        stats.fields().iter().map(|&(name, count)| (name.to_owned(), json!(count))).collect();
    Ok(json!({
        "walked": walked == Walked::Walked,
        "root": expanded.to_string_lossy(),
        "exclude_prefixes": options.exclude_prefixes,
        "candidates": candidates,
        "stats": stats,
    }))
}

fn assess(request: &Map<String, Value>) -> Outcome {
    let text = request.get("text").and_then(Value::as_str).ok_or("the request has no \"text\" string")?;
    let sample_chars = match request.get("sample_chars") {
        None | Some(Value::Null) => garage_ingest::quality::SAMPLE_CHARS,
        Some(value) => value
            .as_u64()
            .and_then(|count| usize::try_from(count).ok())
            .ok_or("\"sample_chars\" is not a whole number")?,
    };
    let verdict = garage_ingest::assess(text, sample_chars);
    let metrics: Map<String, Value> =
        verdict.metrics.iter().map(|&(name, value)| (name.to_owned(), json!(value))).collect();
    Ok(json!({
        "machine_generated": verdict.machine_generated,
        "reasons": verdict.reasons,
        "reason_text": verdict.reason_text(),
        "metrics": metrics,
    }))
}

fn whole(request: &Map<String, Value>, key: &str) -> Result<usize, String> {
    request
        .get(key)
        .and_then(Value::as_u64)
        .and_then(|value| usize::try_from(value).ok())
        .ok_or_else(|| format!("the request has no whole number \"{key}\""))
}

fn chunk(request: &Map<String, Value>) -> Outcome {
    let text = request.get("text").and_then(Value::as_str).ok_or("the request has no \"text\" string")?;
    let kind = request.get("kind").and_then(Value::as_str).ok_or("the request has no \"kind\" string")?;
    let kind = ContentKind::parse(kind).ok_or_else(|| format!("{kind:?} is not a content kind"))?;
    let extension = request.get("extension").and_then(Value::as_str).unwrap_or_default();
    let size = whole(request, "size")?;
    let overlap = whole(request, "overlap")?;
    let chunks = garage_ingest::chunk_text(text, kind, extension, size, overlap).map_err(|error| error.to_string())?;
    let chunks: Vec<Value> = chunks
        .into_iter()
        .map(|chunk| {
            json!({
                "ord": chunk.ord,
                "text": chunk.text,
                "chunker": chunk.chunker,
                "heading_path": chunk.heading_path,
                "char_start": chunk.char_start,
                "char_end": chunk.char_end,
            })
        })
        .collect();
    Ok(json!({ "chunks": chunks }))
}

fn budget_from(request: &Map<String, Value>) -> Result<Budget, String> {
    let Some(value) = request.get("budget") else { return Ok(Budget::default()) };
    let object = value.as_object().ok_or("\"budget\" is not an object")?;
    let mut budget = Budget::default();
    for (key, value) in object {
        let count = || value.as_u64().ok_or_else(|| format!("budget.{key} is not a whole number"));
        match key.as_str() {
            "enabled" => budget.enabled = value.as_bool().ok_or("budget.enabled is not a boolean")?,
            "max_files" => budget.max_files = count()?,
            "max_bytes" => budget.max_bytes = count()?,
            "timeout_seconds" => {
                budget.timeout_seconds = value.as_f64().ok_or("budget.timeout_seconds is not a number")?;
            }
            "files_done" => budget.files_done = count()?,
            "bytes_done" => budget.bytes_done = count()?,
            "deferred" => budget.deferred = count()?,
            "failed" => budget.failed = count()?,
            other => return Err(format!("unknown budget field {other:?}")),
        }
    }
    Ok(budget)
}

fn budget_json(budget: &Budget) -> Value {
    json!({
        "enabled": budget.enabled,
        "max_files": budget.max_files,
        "max_bytes": budget.max_bytes,
        "timeout_seconds": budget.timeout_seconds,
        "files_done": budget.files_done,
        "bytes_done": budget.bytes_done,
        "deferred": budget.deferred,
        "failed": budget.failed,
        "exhausted": budget.exhausted(),
        "summary": budget.summary(),
    })
}

fn ensure_local(request: &Map<String, Value>) -> Outcome {
    let path = request.get("path").and_then(Value::as_str).ok_or("the request has no \"path\" string")?;
    let mut budget = budget_from(request)?;
    let materializer = Materializer::shared();
    let (outcome, message) = match materializer.ensure_local(Path::new(path), &mut budget) {
        Materialized::Local => ("local", None),
        Materialized::Deferred => ("deferred", None),
        Materialized::Failed(message) => ("failed", Some(message)),
    };
    Ok(json!({
        "outcome": outcome,
        "message": message,
        "budget": budget_json(&budget),
        "stalled": materializer.stalled_count(),
    }))
}

/// The repositories a request supplies, standing in for reading their history.
struct SuppliedRepos(BTreeMap<PathBuf, RepoAttribution>);

impl GitHistory for SuppliedRepos {
    fn repository(&self, root: &Path) -> Option<RepoAttribution> {
        self.0.get(root).cloned()
    }
}

fn strings(value: Option<&Value>, what: &str) -> Result<Vec<String>, String> {
    let Some(value) = value else { return Ok(Vec::new()) };
    value
        .as_array()
        .ok_or_else(|| format!("\"{what}\" is not a list"))?
        .iter()
        .map(|item| item.as_str().map(str::to_owned).ok_or_else(|| format!("\"{what}\" holds a non-string")))
        .collect()
}

fn repos(value: Option<&Value>) -> Result<SuppliedRepos, String> {
    let mut repos = BTreeMap::new();
    let Some(value) = value else { return Ok(SuppliedRepos(repos)) };
    for (root, repo) in value.as_object().ok_or("\"repos\" is not an object")? {
        let remote = repo.get("remote").and_then(Value::as_str).map(str::to_owned);
        let mut by_path = BTreeMap::new();
        if let Some(paths) = repo.get("by_path").and_then(Value::as_object) {
            for (relative, tallies) in paths {
                let tallies = tallies
                    .as_array()
                    .ok_or("a by_path entry is not a list")?
                    .iter()
                    .map(|tally| {
                        let name = tally[0].as_str().ok_or("a tally has no name")?;
                        let email = tally[1].as_str().ok_or("a tally has no email")?;
                        let commits = tally[2].as_u64().ok_or("a tally has no commit count")?;
                        Ok(AuthorTally { name: name.to_owned(), email: email.to_owned(), commits })
                    })
                    .collect::<Result<Vec<_>, String>>()?;
                by_path.insert(relative.clone(), tallies);
            }
        }
        repos.insert(PathBuf::from(root), RepoAttribution { remote, by_path });
    }
    Ok(SuppliedRepos(repos))
}

/// A [`FileHost`] that answers with what the request says the file holds.
struct StatedFile {
    local: bool,
    source_sha256: Option<String>,
    read: Option<ReadOutcome>,
}

impl FileHost for StatedFile {
    fn ensure_local(&mut self, _: &FileCandidate) -> bool {
        self.local
    }

    fn source_sha256(&mut self, _: &FileCandidate) -> Option<String> {
        self.source_sha256.clone()
    }

    fn read(&mut self, _: &FileCandidate) -> ReadOutcome {
        self.read.take().unwrap_or_else(|| ReadOutcome::Failed("the request has no \"read\"".to_owned()))
    }
}

/// A [`Storage`] that writes down each call, as `{"method", ...arguments}`.
#[derive(Default)]
struct RecordedCalls(Vec<Value>);

impl Storage for RecordedCalls {
    fn record_seen(&mut self, uri: &str) -> Result<(), String> {
        self.0.push(json!({ "method": "record_seen", "uri": uri }));
        Ok(())
    }

    fn record_placeholder(&mut self, uri: &str, mtime: f64, title: &str, reason: &str) -> Result<(), String> {
        self.0.push(
            json!({ "method": "record_placeholder", "uri": uri, "mtime": mtime, "title": title, "reason": reason }),
        );
        Ok(())
    }

    fn record_no_text(&mut self, uri: &str, byte_size: u64, mtime: f64, source_sha256: &str) -> Result<(), String> {
        self.0.push(json!({
            "method": "record_no_text", "uri": uri, "byte_size": byte_size, "mtime": mtime,
            "source_sha256": source_sha256,
        }));
        Ok(())
    }

    fn record_extract_failed(
        &mut self,
        uri: &str,
        error: &str,
        byte_size: u64,
        mtime: f64,
        source_sha256: &str,
    ) -> Result<(), String> {
        self.0.push(json!({
            "method": "record_extract_failed", "uri": uri, "error": error, "byte_size": byte_size, "mtime": mtime,
            "source_sha256": source_sha256,
        }));
        Ok(())
    }

    fn record_rejected(&mut self, uri: &str) -> Result<(), String> {
        self.0.push(json!({ "method": "record_rejected", "uri": uri }));
        Ok(())
    }

    fn refresh_metadata(
        &mut self,
        uri: &str,
        byte_size: u64,
        mtime: f64,
        source_sha256: &str,
        corpus_class: &str,
        trust_tier: &str,
    ) -> Result<(), String> {
        self.0.push(json!({
            "method": "refresh_metadata", "uri": uri, "byte_size": byte_size, "mtime": mtime,
            "source_sha256": source_sha256, "corpus_class": corpus_class, "trust_tier": trust_tier,
        }));
        Ok(())
    }

    fn replace_document(&mut self, uri: &str, document: DocumentPayload) -> Result<usize, String> {
        let written = document.chunks.len();
        let authors: Vec<Value> = document
            .authors
            .into_iter()
            .map(|author| {
                let identities: Map<String, Value> =
                    author.identities.into_iter().map(|(kind, value)| (kind, Value::String(value))).collect();
                json!({
                    "name": author.name, "role": author.role, "confidence": author.confidence,
                    "evidence": author.evidence, "identities": identities, "is_self": author.is_self,
                })
            })
            .collect();
        let chunks: Vec<Value> = document
            .chunks
            .into_iter()
            .map(|chunk| {
                json!({
                    "ord": chunk.ord, "text": chunk.text, "token_count": chunk.token_count,
                    "char_start": chunk.char_start, "char_end": chunk.char_end, "heading_path": chunk.heading_path,
                    "chunk_sha256": chunk.chunk_sha256, "chunker": chunk.chunker,
                })
            })
            .collect();
        self.0.push(json!({
            "method": "replace_document", "uri": uri, "title": document.title, "lang": document.lang,
            "byte_size": document.byte_size, "mtime": document.mtime, "source_sha256": document.source_sha256,
            "content_sha256": document.content_sha256, "extractor": document.extractor,
            "extractor_version": document.extractor_version, "chunker": document.chunker,
            "content": document.content, "meta": document.meta, "corpus_class": document.corpus_class,
            "trust_tier": document.trust_tier, "authors": authors, "chunks": chunks,
        }));
        Ok(written)
    }
}

fn text_field(object: &Map<String, Value>, key: &str) -> String {
    object.get(key).and_then(Value::as_str).unwrap_or_default().to_owned()
}

fn existing_stat(value: Option<&Value>) -> Result<ExistingStat, String> {
    let Some(value) = value.filter(|value| !value.is_null()) else { return Ok(ExistingStat::default()) };
    let object = value.as_object().ok_or("\"existing\" is not an object")?;
    Ok(ExistingStat {
        exists: object.get("exists").and_then(Value::as_bool).unwrap_or(false),
        byte_size: object.get("byte_size").and_then(Value::as_i64).unwrap_or(0),
        mtime: object.get("mtime").and_then(Value::as_f64).unwrap_or(0.0),
        content_sha256: text_field(object, "content_sha256"),
        chunker: text_field(object, "chunker"),
        state: text_field(object, "state"),
        source_sha256: text_field(object, "source_sha256"),
    })
}

fn file_candidate(value: Option<&Value>) -> Result<FileCandidate, String> {
    let object = value.and_then(Value::as_object).ok_or("the request has no \"candidate\" object")?;
    let path = object.get("path").and_then(Value::as_str).ok_or("the candidate has no \"path\" string")?;
    Ok(FileCandidate {
        path: PathBuf::from(path),
        uri: object.get("uri").and_then(Value::as_str).unwrap_or(path).to_owned(),
        size: object.get("size").and_then(Value::as_u64).unwrap_or(0),
        mtime: object.get("mtime").and_then(Value::as_f64).unwrap_or(0.0),
        placeholder: object.get("placeholder").and_then(Value::as_bool).unwrap_or(false),
    })
}

fn optional_text(object: &Map<String, Value>, key: &str) -> Option<String> {
    object.get(key).and_then(Value::as_str).map(str::to_owned)
}

fn read_outcome(value: Option<&Value>) -> Result<Option<ReadOutcome>, String> {
    let Some(value) = value.filter(|value| !value.is_null()) else { return Ok(None) };
    let object = value.as_object().ok_or("\"read\" is not an object")?;
    if let Some(document) = object.get("document") {
        let document = document.as_object().ok_or("\"read.document\" is not an object")?;
        let kind = document.get("kind").and_then(Value::as_str).unwrap_or("prose");
        let kind = ContentKind::parse(kind).ok_or_else(|| format!("{kind:?} is not a content kind"))?;
        return Ok(Some(ReadOutcome::Document(Extracted {
            text: text_field(document, "text"),
            kind,
            extractor: text_field(document, "extractor"),
            extractor_version: text_field(document, "extractor_version"),
            title: optional_text(document, "title"),
            lang: optional_text(document, "lang"),
            meta: document.get("meta").and_then(Value::as_object).cloned().unwrap_or_default(),
            author_hints: strings(document.get("author_hints"), "read.document.author_hints")?,
        })));
    }
    if let Some(message) = object.get("no_text") {
        return Ok(Some(ReadOutcome::NoText(message.as_str().unwrap_or_default().to_owned())));
    }
    if object.get("placeholder").and_then(Value::as_bool).unwrap_or(false) {
        return Ok(Some(ReadOutcome::Placeholder));
    }
    if let Some(error) = object.get("failed") {
        return Ok(Some(ReadOutcome::Failed(error.as_str().unwrap_or_default().to_owned())));
    }
    if let Some(error) = object.get("raised") {
        return Ok(Some(ReadOutcome::Raised(error.as_str().unwrap_or_default().to_owned())));
    }
    Err("\"read\" is not one of document, no_text, placeholder, failed or raised".to_owned())
}

fn ingest_settings(value: Option<&Value>) -> Result<IngestSettings, String> {
    let mut settings = IngestSettings::default();
    let Some(value) = value.filter(|value| !value.is_null()) else { return Ok(settings) };
    for (key, value) in value.as_object().ok_or("\"settings\" is not an object")? {
        let flag = || value.as_bool().ok_or_else(|| format!("\"settings.{key}\" is not a boolean"));
        let count = || {
            value
                .as_u64()
                .and_then(|count| usize::try_from(count).ok())
                .ok_or_else(|| format!("\"settings.{key}\" is not a whole number"))
        };
        match key.as_str() {
            "reject_machine_generated" => settings.reject_machine_generated = flag()?,
            "index_images" => settings.index_images = flag()?,
            "max_chunks_per_document" => settings.max_chunks_per_document = count()?,
            "chunk_size" => settings.chunk_size = count()?,
            "chunk_overlap" => settings.chunk_overlap = count()?,
            "code_chunk_size" => settings.code_chunk_size = count()?,
            "code_chunk_overlap" => settings.code_chunk_overlap = count()?,
            _ => return Err(format!("\"settings.{key}\" is not an ingest setting")),
        }
    }
    Ok(settings)
}

fn source_info(value: Option<&Value>) -> Result<SourceInfo, String> {
    let object = value.and_then(Value::as_object).ok_or("the request has no \"source\" object")?;
    let root = object.get("root").and_then(Value::as_str).ok_or("the source has no \"root\" string")?;
    let trust = object.get("default_trust").and_then(Value::as_str).unwrap_or("authored");
    Ok(SourceInfo {
        root: PathBuf::from(root),
        default_class: object.get("default_class").and_then(Value::as_str).unwrap_or("document").to_owned(),
        default_trust: TrustTier::parse(trust).ok_or_else(|| format!("{trust:?} is not a trust tier"))?,
    })
}

fn contact_names(value: Option<&Value>) -> Result<Option<ContactNames>, String> {
    let Some(value) = value.filter(|value| !value.is_null()) else { return Ok(None) };
    let tier = |value: &Value| -> Result<ContactNames, String> {
        let mut names = ContactNames::default();
        for entry in value.as_array().ok_or("a contact names tier is not a list")? {
            let handle = entry.get(0).and_then(Value::as_str).ok_or("a contact name has no handle")?;
            let name = entry.get(1).and_then(Value::as_str).ok_or("a contact name has no name")?;
            names.add(handle, name);
        }
        Ok(names)
    };
    // `[[handle, name], ...]`, or `{"names": [...], "fallback": [...]}` for two tiers.
    match value {
        Value::Object(tiers) => {
            let names = tier(tiers.get("names").unwrap_or(&Value::Array(Vec::new())))?;
            Ok(Some(match tiers.get("fallback") {
                Some(fallback) => names.with_fallback(tier(fallback)?),
                None => names,
            }))
        }
        _ => tier(value).map(Some),
    }
}

fn counters_json(counters: &Counters) -> Value {
    json!({
        "seen": counters.seen, "indexed": counters.indexed, "skipped": counters.skipped,
        "failed": counters.failed, "placeholders": counters.placeholders, "rejected": counters.rejected,
        "chunks_written": counters.chunks_written, "errors": counters.errors,
    })
}

/// `"facade": {"socket" | "host" and "port", "token", "run_id", "source_slug"}`: GarageService to persist through.
fn facade_storage(value: &Value) -> Result<GrpcStorage, String> {
    let object = value.as_object().ok_or("\"facade\" is not an object")?;
    let target = facade_target(object)?;
    let token = object.get("token").and_then(Value::as_str);
    let run_id = object.get("run_id").and_then(Value::as_i64).ok_or("\"facade\" has no \"run_id\"")?;
    let slug = object.get("source_slug").and_then(Value::as_str).ok_or("\"facade\" has no \"source_slug\"")?;
    let connection = Connection::connect(&target, token).map_err(|error| error.to_string())?;
    Ok(GrpcStorage::new(connection, run_id, slug))
}

/// With `"facade"`, the stat comes from `CheckDocumentStat` and each call goes to GarageService;
/// otherwise the calls are written down and returned.
fn ingest_one(request: &Map<String, Value>) -> Outcome {
    let candidate = file_candidate(request.get("candidate"))?;
    let mut host = StatedFile {
        local: request.get("local").and_then(Value::as_bool).unwrap_or(true),
        source_sha256: request.get("source_sha256").and_then(Value::as_str).map(str::to_owned),
        read: read_outcome(request.get("read"))?,
    };
    let settings = ingest_settings(request.get("settings"))?;
    let source = source_info(request.get("source"))?;
    let identity = identity(request)?;
    let names = contact_names(request.get("contact_names"))?;
    let policy = match request.get("policy") {
        None | Some(Value::Null) => WalkPolicy::default(),
        Some(Value::Object(overrides)) => WalkPolicy::with_overrides(overrides).map_err(|error| error.to_string())?,
        Some(_) => return Err("\"policy\" is not an object".to_owned()),
    };
    let supplied;
    let git: &dyn GitHistory = if request.get("read_git").and_then(Value::as_bool).unwrap_or(false) {
        library_history()
    } else {
        supplied = repos(request.get("repos"))?;
        &supplied
    };
    let context = Context {
        source: &source,
        identity: &identity,
        git,
        contact_names: names.as_ref(),
        settings: &settings,
        policy: &policy,
        force: request.get("force").and_then(Value::as_bool).unwrap_or(false),
    };
    let mut counters = Counters::default();
    let mut reply = Map::new();
    let outcome = if let Some(facade) = request.get("facade").filter(|facade| !facade.is_null()) {
        let mut storage = facade_storage(facade)?;
        let existing = storage.check_stat(&candidate.uri).map_err(|error| error.to_string())?;
        pipeline::ingest_one(&mut host, &mut storage, &existing, &candidate, &context, &mut counters)
    } else {
        let existing = existing_stat(request.get("existing"))?;
        let mut storage = RecordedCalls::default();
        let outcome = pipeline::ingest_one(&mut host, &mut storage, &existing, &candidate, &context, &mut counters);
        reply.insert("calls".to_owned(), Value::Array(storage.0));
        outcome
    };
    reply.insert("counters".to_owned(), counters_json(&counters));
    if let Err(error) = outcome {
        reply.insert("error".to_owned(), Value::String(error));
    }
    Ok(Value::Object(reply))
}

/// The files a run's walk finds, as the request says each reads: `"files": {"<path under the root>": {"local"?,
/// "source_sha256"?, "read"}}`, answering `is_cancelled` after `"cancel_after"` files and writing down each
/// progress report.
struct StatedFiles {
    root: PathBuf,
    files: Map<String, Value>,
    shared_names: Map<String, Value>,
    cancel_after: Option<u64>,
    asked: u64,
    progress: Vec<Value>,
}

impl StatedFiles {
    fn stated(&self, candidate: &FileCandidate) -> Option<&Map<String, Value>> {
        let relative = candidate.path.strip_prefix(&self.root).ok()?;
        let key = relative.components().map(|part| part.as_os_str().to_string_lossy()).collect::<Vec<_>>().join("/");
        self.files.get(&key).and_then(Value::as_object)
    }
}

impl FileHost for StatedFiles {
    fn ensure_local(&mut self, candidate: &FileCandidate) -> bool {
        self.stated(candidate).and_then(|file| file.get("local")).and_then(Value::as_bool).unwrap_or(true)
    }

    fn source_sha256(&mut self, candidate: &FileCandidate) -> Option<String> {
        self.stated(candidate).and_then(|file| file.get("source_sha256")).and_then(Value::as_str).map(str::to_owned)
    }

    fn read(&mut self, candidate: &FileCandidate) -> ReadOutcome {
        let stated = self.stated(candidate).and_then(|file| file.get("read"));
        match read_outcome(stated) {
            Ok(Some(outcome)) => outcome,
            Ok(None) => ReadOutcome::Failed(format!("the request states no read for {}", candidate.uri)),
            Err(error) => ReadOutcome::Failed(error),
        }
    }
}

impl SourceHost for StatedFiles {
    fn cancelled(&mut self) -> bool {
        self.asked += 1;
        self.cancel_after.is_some_and(|after| self.asked > after)
    }

    fn progress(&mut self, phase: &str, current_item: Option<&str>, _: &Counters) {
        self.progress.push(json!({ "phase": phase, "current_item": current_item }));
    }

    fn shared_names(&mut self, directory: &Path) -> Vec<(String, String)> {
        name_pairs(self.shared_names.get(&directory.to_string_lossy().into_owned()))
    }
}

/// `[[handle, name], ...]` as pairs; anything else is skipped.
fn name_pairs(value: Option<&Value>) -> Vec<(String, String)> {
    value
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|pair| match pair.as_array().map(Vec::as_slice) {
            Some([Value::String(handle), Value::String(name)]) => Some((handle.clone(), name.clone())),
            _ => None,
        })
        .collect()
}

fn scan_summary(value: Option<&Value>) -> Result<ScanSummary, String> {
    let object = value.and_then(Value::as_object).ok_or("the request has no \"scan\" object")?;
    Ok(ScanSummary {
        item_count: object.get("item_count").and_then(Value::as_u64).unwrap_or(0),
        item_type: text_field(object, "item_type"),
        duration_seconds: object.get("duration_seconds").and_then(Value::as_f64).unwrap_or(0.0),
        details: object.get("details").and_then(Value::as_object).cloned().unwrap_or_default(),
        error: optional_text(object, "error").filter(|error| !error.is_empty()),
    })
}

fn facade_target(object: &Map<String, Value>) -> Result<GrpcTarget, String> {
    if let Some(socket) = object.get("socket").and_then(Value::as_str) {
        return Ok(GrpcTarget::Socket(PathBuf::from(socket)));
    }
    let port = object
        .get("port")
        .and_then(Value::as_u64)
        .and_then(|port| u16::try_from(port).ok())
        .ok_or("\"facade\" names neither a socket nor a port")?;
    Ok(GrpcTarget::Tcp { host: object.get("host").and_then(Value::as_str).unwrap_or("127.0.0.1").to_owned(), port })
}

/// Counts a source's items, as `ingest/scanner.py`'s `scan_source` does.
fn scan(request: &Map<String, Value>) -> Outcome {
    let policy = match request.get("policy") {
        None | Some(Value::Null) => WalkPolicy::default(),
        Some(Value::Object(overrides)) => WalkPolicy::with_overrides(overrides).map_err(|error| error.to_string())?,
        Some(_) => return Err("\"policy\" is not an object".to_owned()),
    };
    let options = ScanOptions {
        include_code: request.get("include_code").and_then(Value::as_bool).unwrap_or(false),
        policy: &policy,
        read_git: request.get("read_git").and_then(Value::as_bool).unwrap_or(true),
    };
    let slug = request.get("source_slug").and_then(Value::as_str).unwrap_or_default();
    let kind = request.get("kind").and_then(Value::as_str).unwrap_or("filesystem");
    Ok(scan_source(slug, kind, Path::new(&root(request)?), &options, &mut Ticker::new(None)).to_json())
}

/// Runs one walked source through GarageService with the files the request states.
fn ingest_source(request: &Map<String, Value>) -> Outcome {
    let cancel_after = request.get("cancel_after").and_then(Value::as_u64);
    let files = request.get("files").and_then(Value::as_object).cloned().unwrap_or_default();
    let shared_names = request.get("shared_names").and_then(Value::as_object).cloned().unwrap_or_default();
    run_source_with(
        request,
        |root, _| StatedFiles { root, files, shared_names, cancel_after, asked: 0, progress: Vec::new() },
        |host, reply| {
            reply.insert("progress".to_owned(), Value::Array(host.progress));
        },
    )
}

/// `BeginIngestSession`, the scan, then [`source::ingest_source`] with the host `make_host` builds for
/// the source's root; `finish` adds what the host has to say to the reply.
fn run_source_with<H: SourceHost>(
    request: &Map<String, Value>,
    make_host: impl FnOnce(PathBuf, &ScanSummary) -> H,
    finish: impl FnOnce(H, &mut Map<String, Value>),
) -> Outcome {
    let facade = request.get("facade").and_then(Value::as_object).ok_or("the request has no \"facade\" object")?;
    let slug = facade.get("source_slug").and_then(Value::as_str).ok_or("\"facade\" has no \"source_slug\"")?;
    let connection = Connection::connect(&facade_target(facade)?, facade.get("token").and_then(Value::as_str))
        .map_err(|error| error.to_string())?;
    let options = SourceOptions {
        include_code: request.get("include_code").and_then(Value::as_bool).unwrap_or(false),
        limit: request.get("limit").and_then(Value::as_u64),
        messages: false,
    };
    let scan_given = request.get("scan").filter(|scan| !scan.is_null());
    let settings = ingest_settings(request.get("settings"))?;
    let identity = identity(request)?;
    let names = contact_names(request.get("contact_names"))?;
    let policy = match request.get("policy") {
        None | Some(Value::Null) => WalkPolicy::default(),
        Some(Value::Object(overrides)) => WalkPolicy::with_overrides(overrides).map_err(|error| error.to_string())?,
        Some(_) => return Err("\"policy\" is not an object".to_owned()),
    };
    let supplied;
    let git: &dyn GitHistory = if request.get("read_git").and_then(Value::as_bool).unwrap_or(false) {
        library_history()
    } else {
        supplied = repos(request.get("repos"))?;
        &supplied
    };

    let session = facade::begin_session(&connection, slug, options.include_code).map_err(|error| error.to_string())?;
    let source = source_info(Some(&json!({
        "root": session.root, "default_class": session.default_class, "default_trust": session.default_trust,
    })))?;
    let scan = if let Some(scan) = scan_given {
        scan_summary(Some(scan))?
    } else {
        let options = ScanOptions {
            include_code: options.include_code,
            policy: &policy,
            read_git: request.get("read_git").and_then(Value::as_bool).unwrap_or(false),
        };
        scan_source(slug, &session.kind, Path::new(&session.root), &options, &mut Ticker::new(None)).summary()
    };
    let mut storage = GrpcStorage::new(connection, session.run_id, slug);
    if rust_readers(request)?.is_some() {
        // GarageService remembers a no-text or failed file with the reader that gave up on it.
        storage = storage.with_extractor_revision(garage_readers::revision);
    }
    let options = SourceOptions { messages: session.kind == "sqlite", ..options };
    let context = Context {
        source: &source,
        identity: &identity,
        git,
        contact_names: names.as_ref(),
        settings: &settings,
        policy: &policy,
        force: request.get("force").and_then(Value::as_bool).unwrap_or(false),
    };
    let mut host = make_host(garage_ingest::walk::expand_home(&source.root), &scan);
    let mut reply = Map::new();
    reply.insert("run_id".to_owned(), json!(session.run_id));
    match source::ingest_source(&mut host, &mut storage, &context, &scan, &options) {
        Ok(run) => {
            let stats: Map<String, Value> =
                run.walk_stats.fields().iter().map(|&(name, count)| (name.to_owned(), json!(count))).collect();
            reply.insert("counters".to_owned(), counters_json(&run.counters));
            reply.insert("walk_stats".to_owned(), Value::Object(stats));
            reply.insert("completed".to_owned(), json!(run.completed));
        }
        Err(SourceError::Unavailable(problem)) => {
            reply.insert("unavailable".to_owned(), Value::String(problem));
        }
        Err(SourceError::Storage(error)) => {
            reply.insert("error".to_owned(), Value::String(error));
        }
    }
    finish(host, &mut reply);
    Ok(Value::Object(reply))
}

/// A host function: `request` is JSON; returns 0 and sets `*reply` to JSON, or nonzero and sets it
/// to the reason (or leaves it null). `*reply` is freed with the host's `release`.
pub type HostCall = Option<unsafe extern "C" fn(*mut c_void, *const c_char, *mut *mut c_char) -> i32>;

/// The process a run reads files in. See `garage_ingest.h` for each member.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct GarageIngestHost {
    pub context: *mut c_void,
    pub read: HostCall,
    pub release: Option<unsafe extern "C" fn(*mut c_void, *mut c_char)>,
    pub progress: Option<unsafe extern "C" fn(*mut c_void, *const c_char)>,
    pub cancelled: Option<unsafe extern "C" fn(*mut c_void) -> bool>,
    pub shared_names: HostCall,
}

/// The Rust readers a request asks for with `"readers": {...}` (their `extraction.*` settings, with
/// `index_images` also taken from `"settings"`), or none when the host reads the files.
fn rust_readers(request: &Map<String, Value>) -> Result<Option<garage_readers::Readers>, String> {
    let readers = match request.get("readers") {
        None | Some(Value::Null) => return Ok(None),
        Some(Value::Object(readers)) => readers,
        Some(_) => return Err("\"readers\" is not an object".to_owned()),
    };
    let mut settings = garage_readers::Settings::from_json(Some(readers));
    if !readers.contains_key("index_images")
        && let Some(index_images) =
            request.get("settings").and_then(|settings| settings.get("index_images")).and_then(Value::as_bool)
    {
        settings.index_images = index_images;
    }
    Ok(Some(garage_readers::Readers::new(settings)))
}

/// A run's files: placeholders made local within the budget and the bytes hashed here, the text
/// read by the Rust readers when the request asks for them, else by the host.
struct ReadingHost {
    host: GarageIngestHost,
    budget: Budget,
    readers: Option<garage_readers::Readers>,
    /// For `garage_ingest_run`: progress goes to the host as the app's `IngestProgress` events.
    events: Option<service::SourceEvents>,
}

impl ReadingHost {
    /// Calls one of the host's functions; its reply, or why there is none.
    fn call(&self, function: HostCall, what: &str, request: &Value) -> Result<String, String> {
        let function = function.ok_or_else(|| format!("the host offers no {what}"))?;
        let request = CString::new(request.to_string()).map_err(|_| "a path held a NUL byte".to_owned())?;
        let mut reply: *mut c_char = std::ptr::null_mut();
        // SAFETY: the host's contract (garage_ingest.h).
        let status = unsafe { function(self.host.context, request.as_ptr(), &raw mut reply) };
        let text = if reply.is_null() {
            String::new()
        } else {
            // SAFETY: a non-null reply is a NUL-terminated string the host owns until released.
            let text = unsafe { CStr::from_ptr(reply) }.to_string_lossy().into_owned();
            if let Some(release) = self.host.release {
                // SAFETY: the reply came from this host and is released once.
                unsafe { release(self.host.context, reply) };
            }
            text
        };
        if status == 0 {
            Ok(text)
        } else {
            Err(if text.is_empty() { format!("the host's {what} failed ({status})") } else { text })
        }
    }
}

impl FileHost for ReadingHost {
    fn ensure_local(&mut self, candidate: &FileCandidate) -> bool {
        matches!(Materializer::shared().ensure_local(&candidate.path, &mut self.budget), Materialized::Local)
    }

    fn source_sha256(&mut self, candidate: &FileCandidate) -> Option<String> {
        garage_ingest::sha256::file_hex_digest(&candidate.path).ok()
    }

    fn read(&mut self, candidate: &FileCandidate) -> ReadOutcome {
        if let Some(readers) = &mut self.readers {
            return readers.read(&candidate.path);
        }
        let request = json!({
            "path": candidate.path.to_string_lossy(),
            "uri": candidate.uri,
            "size": candidate.size,
            "mtime": candidate.mtime,
        });
        let reply = match self.call(self.host.read, "read", &request) {
            Ok(reply) => reply,
            Err(error) => return ReadOutcome::Raised(error),
        };
        let reply = match serde_json::from_str::<Value>(&reply) {
            Ok(reply) => reply,
            Err(error) => return ReadOutcome::Raised(format!("the host's read replied with bad JSON: {error}")),
        };
        match read_outcome(Some(&reply)) {
            Ok(Some(outcome)) => outcome,
            Ok(None) => ReadOutcome::Raised("the host's read replied with null".to_owned()),
            Err(error) => ReadOutcome::Raised(error),
        }
    }
}

impl SourceHost for ReadingHost {
    fn cancelled(&mut self) -> bool {
        // SAFETY: the host's contract (garage_ingest.h).
        self.host.cancelled.is_some_and(|cancelled| unsafe { cancelled(self.host.context) })
    }

    fn progress(&mut self, phase: &str, current_item: Option<&str>, counters: &Counters) {
        let event = match &self.events {
            Some(events) => events.progress(phase, current_item, counters),
            None => json!({
                "phase": phase,
                "current_item": current_item,
                "counters": counters_json(counters),
                "budget": budget_json(&self.budget),
            }),
        };
        send_event(&self.host, &event);
    }

    fn materialized(&self) -> (u64, u64) {
        (self.budget.files_done, self.budget.bytes_done)
    }

    fn shared_names(&mut self, directory: &Path) -> Vec<(String, String)> {
        if self.readers.is_some() {
            return garage_readers::shared_names(directory);
        }
        if self.host.shared_names.is_none() {
            return Vec::new();
        }
        let request = json!({ "directory": directory.to_string_lossy() });
        // Names are a nicety: a host that cannot read them leaves the handles as they are.
        let reply = self.call(self.host.shared_names, "shared_names", &request).unwrap_or_default();
        name_pairs(serde_json::from_str::<Value>(&reply).ok().as_ref().and_then(|reply| reply.get("names")))
    }
}

/// Hands `event` to the host's `progress`, when it has one.
fn send_event(host: &GarageIngestHost, event: &Value) {
    let Some(progress) = host.progress else { return };
    let Ok(event) = CString::new(event.to_string()) else { return };
    // SAFETY: the host's contract (garage_ingest.h); the event lives through the call.
    unsafe { progress(host.context, event.as_ptr()) };
}

/// Runs one walked source through GarageService, reading each file through the host.
fn run_source(request: &Map<String, Value>, host: GarageIngestHost) -> Outcome {
    let budget = budget_from(request)?;
    let readers = rust_readers(request)?;
    // Only the materialize thread may start a download; a read here of a dataless file fails instead.
    let _policy = garage_ingest::materialize::refusing_dataless_reads();
    run_source_with(
        request,
        |_root, _| ReadingHost { host, budget, readers, events: None },
        |host, reply| {
            reply.insert("budget".to_owned(), budget_json(&host.budget));
        },
    )
}

/// The owner: `"self": {"name", "identities": ["kind:value", ...]}`.
fn identity(request: &Map<String, Value>) -> Result<SelfIdentity, String> {
    let owner = request.get("self").and_then(Value::as_object);
    let name = owner.and_then(|owner| owner.get("name")).and_then(Value::as_str).unwrap_or_default();
    let pairs = strings(owner.and_then(|owner| owner.get("identities")), "self.identities")?
        .into_iter()
        .filter_map(|raw| {
            let (kind, value) = raw.split_once(':')?;
            Some((kind.trim().to_owned(), value.trim().to_owned())).filter(|(_, value)| !value.is_empty())
        })
        .collect::<Vec<_>>();
    Ok(SelfIdentity::new(name, &pairs))
}

/// Git history read through libgit2, once per process.
fn library_history() -> &'static LibGitHistory {
    static HISTORY: OnceLock<LibGitHistory> = OnceLock::new();
    HISTORY.get_or_init(LibGitHistory::new)
}

fn attribute(request: &Map<String, Value>) -> Outcome {
    let path = request.get("path").and_then(Value::as_str).ok_or("the request has no \"path\" string")?;
    let root = request.get("source_root").and_then(Value::as_str).ok_or("the request has no \"source_root\" string")?;
    let default = request.get("default_trust").and_then(Value::as_str).unwrap_or("authored");
    let default_trust = TrustTier::parse(default).ok_or_else(|| format!("{default:?} is not a trust tier"))?;
    let hints = strings(request.get("author_hints"), "author_hints")?;
    let identity = identity(request)?;
    let communication = request.get("communication").and_then(Value::as_bool).unwrap_or(false);
    let supplied;
    let repos: &dyn GitHistory = if request.get("read_git").and_then(Value::as_bool).unwrap_or(false) {
        library_history()
    } else {
        supplied = repos(request.get("repos"))?;
        &supplied
    };
    let signals = Signals {
        source_root: Path::new(root),
        default_trust,
        author_hints: &hints,
        identity: &identity,
        communication,
    };
    let attribution = garage_ingest::attribution::resolve(Path::new(path), &signals, repos);
    let authors: Vec<Value> = attribution
        .authors
        .iter()
        .map(|author| {
            json!({
                "name": author.name,
                "email": author.email,
                "role": author.role.as_str(),
                "confidence": author.confidence,
                "evidence": author.evidence,
            })
        })
        .collect();
    Ok(json!({
        "trust": attribution.trust.as_str(),
        "authors": authors,
        "evidence": attribution.evidence,
        "meta": attribution.meta,
    }))
}

fn git_history(request: &Map<String, Value>) -> Outcome {
    let root = root(request)?;
    let max_commits = match request.get("max_commits") {
        None | Some(Value::Null) => None,
        Some(value) => Some(
            value
                .as_u64()
                .and_then(|max| usize::try_from(max).ok())
                .ok_or("\"max_commits\" is not a non-negative integer")?,
        ),
    };
    let commits = garage_git::commit_paths(&root, max_commits).map_err(|error| error.to_string())?;
    let commits: Vec<Value> =
        commits.into_iter().map(|commit| json!([commit.name, commit.email, commit.paths])).collect();
    Ok(json!({ "commits": commits }))
}

fn git_remote(request: &Map<String, Value>) -> Outcome {
    let root = root(request)?;
    let name = request.get("name").and_then(Value::as_str).unwrap_or("origin");
    let url = garage_git::remote_url(&root, name).map_err(|error| error.to_string())?;
    Ok(json!({ "url": url }))
}

fn git_tracked(request: &Map<String, Value>) -> Outcome {
    let root = root(request)?;
    let count = garage_git::index_entry_count(&root).map_err(|error| error.to_string())?;
    Ok(json!({ "count": count }))
}

/// The default walk policy: `{}` -> `{"exclude_dirs": [...], ..., "max_file_bytes": n}`.
///
/// # Safety
///
/// `request` is a NUL-terminated string and `result` a writable pointer; free `*result` with
/// [`garage_ingest_string_free`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn garage_ingest_policy(request: *const c_char, result: *mut *mut c_char) -> i32 {
    call(request, result, |_| Ok(WalkPolicy::default().to_json()))
}

/// Walks a source: `{"root", "include_code"?, "exclude_prefixes"?: [..] | "default", "policy"?}`
/// -> `{"walked", "root", "exclude_prefixes", "candidates": [{"path", "size", "mtime",
/// "placeholder"}], "stats": {...}}`.
///
/// # Safety
///
/// As [`garage_ingest_policy`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn garage_ingest_walk(request: *const c_char, result: *mut *mut c_char) -> i32 {
    call(request, result, walk)
}

/// Why a source's root cannot be walked: `{"root"}` -> `{"problem": string | null}`.
///
/// # Safety
///
/// As [`garage_ingest_policy`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn garage_ingest_root_problem(request: *const c_char, result: *mut *mut c_char) -> i32 {
    call(request, result, |request| Ok(json!({ "problem": garage_ingest::root_problem(Path::new(&root(request)?)) })))
}

/// The quality gate: `{"text", "sample_chars"?}` -> `{"machine_generated", "reasons",
/// "reason_text", "metrics": {...}}`.
///
/// # Safety
///
/// As [`garage_ingest_policy`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn garage_ingest_assess(request: *const c_char, result: *mut *mut c_char) -> i32 {
    call(request, result, assess)
}

/// Attributes a file: `{"path", "source_root", "default_trust", "author_hints"?, "communication"?,
/// "self"?: {"name", "identities": ["git_email:...", ...]}, "repos"?: {"<root>": {"remote",
/// "by_path": {"<relative>": [[name, email, commits], ...]}}}, "read_git"?: false}` -> `{"trust",
/// "authors": [{"name", "email", "role", "confidence", "evidence"}], "evidence", "meta"}`. With
/// `"read_git": true` the library reads each repository's history itself, once per process, and
/// `"repos"` is ignored.
///
/// # Safety
///
/// As [`garage_ingest_policy`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn garage_ingest_attribute(request: *const c_char, result: *mut *mut c_char) -> i32 {
    call(request, result, attribute)
}

/// Makes a file local if it is a cloud placeholder, within a budget: `{"path", "budget"?: {"enabled",
/// "max_files", "max_bytes", "timeout_seconds", "files_done", "bytes_done", "deferred", "failed"}}` ->
/// `{"outcome": "local" | "deferred" | "failed", "message", "budget": {..., "exhausted", "summary"},
/// "stalled"}`. Pass the returned budget to the next call; the process keeps one count of stalled reads.
///
/// # Safety
///
/// As [`garage_ingest_policy`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn garage_ingest_ensure_local(request: *const c_char, result: *mut *mut c_char) -> i32 {
    call(request, result, ensure_local)
}

/// Chunks a document's text: `{"text", "kind": "prose" | "markdown" | "code" | "tabular" |
/// "conversation" | "image", "extension"?, "size", "overlap"}` -> `{"chunks": [{"ord", "text",
/// "chunker", "heading_path", "char_start", "char_end"}]}`.
///
/// # Safety
///
/// As [`garage_ingest_policy`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn garage_ingest_chunk(request: *const c_char, result: *mut *mut c_char) -> i32 {
    call(request, result, chunk)
}

/// A repository's history, as `git log --no-merges --no-renames --name-only` reports it with
/// `.mailmap` applied: `{"root", "max_commits"?}` -> `{"commits": [[name, email, [path, ...]], ...]}`,
/// newest first. A repository libgit2 cannot read answers BAD_REQUEST with its error.
///
/// # Safety
///
/// As [`garage_ingest_policy`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn garage_ingest_git_history(request: *const c_char, result: *mut *mut c_char) -> i32 {
    call(request, result, git_history)
}

/// A remote's configured URL: `{"root", "name"?: "origin"}` -> `{"url": string | null}`.
///
/// # Safety
///
/// As [`garage_ingest_policy`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn garage_ingest_git_remote(request: *const c_char, result: *mut *mut c_char) -> i32 {
    call(request, result, git_remote)
}

/// The tracked files `git ls-files` lists: `{"root"}` -> `{"count"}`.
///
/// # Safety
///
/// As [`garage_ingest_policy`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn garage_ingest_git_tracked(request: *const c_char, result: *mut *mut c_char) -> i32 {
    call(request, result, git_tracked)
}

/// Counts a source's items, as `ingest/scanner.py`'s `scan_source` does: `{"root", "kind"?:
/// "filesystem" | "git" | "sqlite" | "maildir" | "feed", "source_slug"?, "include_code"?, "read_git"?: true,
/// "policy"?}` -> `{"source_slug", "kind", "root", "item_count", "item_type", "details", "duration_seconds",
/// "error"}`. With `"read_git": false` a git source's `tracked_files` detail is left out.
///
/// # Safety
///
/// As [`garage_ingest_policy`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn garage_ingest_scan(request: *const c_char, result: *mut *mut c_char) -> i32 {
    call(request, result, scan)
}

/// Runs one walked source, as `ingest/pipeline.py`'s `_ingest_source` does, through GarageService:
/// `{"facade": {"socket" | "host" and "port", "token"?, "source_slug"}, "scan": {"item_count", "item_type",
/// "duration_seconds", "details", "error"}, "files": {"<path under the root>": {"local"?, "source_sha256"?,
/// "read"}}, "include_code"?, "limit"?, "cancel_after"?, "force"?, "settings"?, "self"?, "contact_names"?,
/// "repos"?, "read_git"?, "policy"?}` -> `{"run_id", "counters", "walk_stats", "completed", "progress"}`, with
/// `"unavailable"` in place of the counters when the scan found the root unreadable and `"error"` when a
/// run-wide call failed. Without `"scan"` the source is scanned here as [`garage_ingest_scan`] does. Each
/// file's read is stated as for [`garage_ingest_ingest_one`]; `"cancel_after"` cancels the run after that
/// many files.
///
/// # Safety
///
/// As [`garage_ingest_policy`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn garage_ingest_ingest_source(request: *const c_char, result: *mut *mut c_char) -> i32 {
    call(request, result, ingest_source)
}

/// Runs one walked source, as [`garage_ingest_ingest_source`] does, reading each file through `host`:
/// the request is the same without `"files"` and `"cancel_after"`, plus the materialize `"budget"` (as for
/// [`garage_ingest_ensure_local`]). Placeholders are made local within the budget and the bytes are hashed
/// here; the host's `read` reads the text, unless the request has `"readers": {"max_file_bytes"?,
/// "ocr_min_chars"?, "index_images"?, "pdf_min_chars_per_page"?}`, when [`garage_readers`] read it (and a
/// Messages source's shared names) and GarageService hears each reader's revision. Progress and cancellation go through the host. The reply holds
/// `"budget"` (as it stands at the end) in place of `"progress"`.
///
/// # Safety
///
/// As [`garage_ingest_policy`], and `host` points to a valid [`GarageIngestHost`] whose functions may be
/// called on this thread until the call returns.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn garage_ingest_run_source(
    request: *const c_char,
    host: *const GarageIngestHost,
    result: *mut *mut c_char,
) -> i32 {
    call(request, result, |request| {
        if host.is_null() {
            return Err("the host pointer was null".to_owned());
        }
        // SAFETY: the caller passes a valid host, which the library only reads.
        run_source(request, unsafe { std::ptr::read(host) })
    })
}

/// Runs the ingest service's request as `garage_rag.ingest.ingest_xpc` does: `{"facade": {"socket", or "host"
/// and "port"; "token"}, "source": slug | "*", "include_code"?, "limit"?, "force"?, "contact_names"?,
/// "settings": "service" | {...}, "budget"?, "self"?, "read_git"?}`. `"*"` runs every enabled source in turn;
/// with `"settings": "service"` the chunking, quality, placeholder and identity settings are GarageService's
/// own (`GetSetting`), the readers' too when the request has `"readers"`. Each file's text is read as for
/// [`garage_ingest_run_source`], and the host's
/// `progress` hears each `IngestProgress` event (`{"source", "phase", "seen", "total_items", ..., "message",
/// "error", "current_item"}`). The reply is `{"sources": [...each source's run_source reply, with
/// "source"], "cancelled"}`, with `"error"` when a source failed or could not be read.
///
/// # Safety
///
/// As [`garage_ingest_run_source`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn garage_ingest_run(
    request: *const c_char,
    host: *const GarageIngestHost,
    result: *mut *mut c_char,
) -> i32 {
    call(request, result, |request| {
        if host.is_null() {
            return Err("the host pointer was null".to_owned());
        }
        // SAFETY: the caller passes a valid host, which the library only reads.
        service::run(request, unsafe { std::ptr::read(host) })
    })
}

/// Decides what ingest does with one file, as `ingest/pipeline.py`'s `ingest_one` does, from what the
/// request says about it: `{"existing"?: {"exists", "byte_size", "mtime", "content_sha256", "chunker",
/// "state", "source_sha256"}, "candidate": {"path", "uri", "size", "mtime", "placeholder"}, "local"?: true,
/// "source_sha256"?, "read"?: {"document": {"text", "kind", "extractor", "extractor_version", "title",
/// "lang", "meta", "author_hints"}} | {"no_text": message} | {"placeholder": true} | {"failed": message},
/// "settings"?: {...}, "source": {"root", "default_class", "default_trust"}, "self"?, "contact_names"?,
/// "repos"?, "read_git"?, "policy"?, "force"?}` -> `{"calls": [{"method", ...arguments}], "counters"}`.
/// `"local"` is `ensure_local`'s answer and `"source_sha256"` the bytes' hash; `"self"`, `"repos"` and
/// `"read_git"` are as for [`garage_ingest_attribute`]. `"contact_names"` is `[[handle, name], ...]`, or
/// `{"names": [...], "fallback": [...]}`.
///
/// # Safety
///
/// As [`garage_ingest_policy`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn garage_ingest_ingest_one(request: *const c_char, result: *mut *mut c_char) -> i32 {
    call(request, result, ingest_one)
}

/// Frees a string this library returned. Null is ignored.
///
/// # Safety
///
/// `text` is null or a string one of this library's calls returned, not yet freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn garage_ingest_string_free(text: *mut c_char) {
    if !text.is_null() {
        // SAFETY: the caller's contract: a string this library made with CString::into_raw.
        drop(unsafe { CString::from_raw(text) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(entry: unsafe extern "C" fn(*const c_char, *mut *mut c_char) -> i32, request: &str) -> (i32, Value) {
        let request = CString::new(request).unwrap();
        let mut result: *mut c_char = std::ptr::null_mut();
        // SAFETY: a valid request and out-pointer.
        let status = unsafe { entry(request.as_ptr(), &raw mut result) };
        // SAFETY: the library returned it.
        let text = unsafe { CStr::from_ptr(result) }.to_str().unwrap().to_owned();
        // SAFETY: as above, freed once.
        unsafe { garage_ingest_string_free(result) };
        (status, serde_json::from_str(&text).unwrap())
    }

    #[test]
    fn assess_answers_with_a_verdict() {
        let (status, verdict) = run(garage_ingest_assess, r#"{"text": "one line"}"#);
        assert_eq!(status, GARAGE_INGEST_OK);
        assert_eq!(verdict["machine_generated"], false);
        assert_eq!(verdict["reason_text"], "looks human-authored");
        assert_eq!(verdict["metrics"]["lines"], 1.0);
    }

    #[test]
    fn chunk_answers_with_chunks() {
        let (status, reply) =
            run(garage_ingest_chunk, r##"{"text": "# A\nbody", "kind": "markdown", "size": 100, "overlap": 0}"##);
        assert_eq!(status, GARAGE_INGEST_OK);
        assert_eq!(reply["chunks"][0]["heading_path"], "A");
        let (status, _) = run(garage_ingest_chunk, r#"{"text": "x", "kind": "poem", "size": 1, "overlap": 0}"#);
        assert_eq!(status, GARAGE_INGEST_BAD_REQUEST);
    }

    #[test]
    fn ensure_local_carries_the_budget() {
        let (status, reply) =
            run(garage_ingest_ensure_local, r#"{"path": "/no/such/.stub.md.icloud", "budget": {"enabled": false}}"#);
        assert_eq!(status, GARAGE_INGEST_OK);
        assert_eq!(reply["outcome"], "deferred");
        assert_eq!(reply["budget"]["deferred"], 1);
        assert_eq!(reply["budget"]["summary"], "materialized 0 files (0.00 GiB), deferred 1");
        let (status, reply) = run(garage_ingest_ensure_local, r#"{"path": "/", "budget": {"nope": 1}}"#);
        assert_eq!(status, GARAGE_INGEST_BAD_REQUEST);
        assert!(reply["error"].as_str().unwrap().contains("nope"));
    }

    #[test]
    fn ingest_one_reports_the_facade_calls() {
        let request = r##"{"candidate": {"path": "/src/Notes/a.md", "size": 3, "mtime": 5.0},
            "source": {"root": "/src"}, "read": {"document": {"text": "# A\nbody", "kind": "markdown"}}}"##;
        let (status, reply) = run(garage_ingest_ingest_one, request);
        assert_eq!(status, GARAGE_INGEST_OK);
        assert_eq!(reply["calls"][0]["method"], "replace_document");
        assert_eq!(reply["calls"][0]["chunker"], "markdown:markdown-header+recursive/v2:1000/150");
        assert_eq!(reply["counters"]["indexed"], 1);
        let settled = r#"{"candidate": {"path": "/src/a.md", "size": 3, "mtime": 5.0}, "source": {"root": "/src"},
            "existing": {"exists": true, "byte_size": 3, "mtime": 5.0, "state": "OK"}}"#;
        let (_, reply) = run(garage_ingest_ingest_one, settled);
        assert_eq!(reply["calls"][0]["method"], "record_seen");
        assert_eq!(reply["counters"]["skipped"], 1);
        let (status, _) = run(
            garage_ingest_ingest_one,
            r#"{"candidate": {"path": "/a"}, "source": {"root": "/"}, "settings": {"nope": 1}}"#,
        );
        assert_eq!(status, GARAGE_INGEST_BAD_REQUEST);
    }

    #[test]
    fn a_bad_request_says_why() {
        let (status, reply) = run(garage_ingest_walk, "[]");
        assert_eq!(status, GARAGE_INGEST_BAD_REQUEST);
        assert_eq!(reply["error"], "the request is not a JSON object");
        let (status, reply) = run(garage_ingest_walk, r#"{"root": "/", "policy": {"nope": 1}}"#);
        assert_eq!(status, GARAGE_INGEST_BAD_REQUEST);
        assert!(reply["error"].as_str().unwrap().contains("nope"));
    }

    #[test]
    fn a_missing_root_is_a_problem() {
        let (status, reply) = run(garage_ingest_root_problem, r#"{"root": "/no/such/garage/root"}"#);
        assert_eq!(status, GARAGE_INGEST_OK);
        assert_eq!(reply["problem"], "path does not exist: /no/such/garage/root");
    }
}

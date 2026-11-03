//! What ingest does with one file (`ingest/pipeline.py`'s `ingest_one`), as Python decides it:
//!
//! 1. An unchanged stat on a settled file is skipped without opening it, so a placeholder is not
//!    downloaded.
//! 2. A changed stat over unchanged bytes refreshes the stat and skips extraction.
//! 3. The file is extracted; one with no text, or that fails, makes no document and is remembered.
//! 4. Unchanged text under the same chunker keeps its chunks and refreshes the metadata.
//! 5. Anything else replaces the document and its chunks.
//!
//! Each file ends in exactly one call on the [`Storage`] (the database facade) and moves the
//! [`Counters`] as Python's `IngestCounters` move. Reading the file is the [`FileHost`]'s: its stat
//! in the database, the budgeted download of a placeholder, the hash of its bytes, and the reader.
//!
//! A chunking error, which Python lets out of `ingest_one`, ends here as `_ingest_source` handles it:
//! the error is noted and the file recorded as seen.

use serde_json::{Map, Value, json};

use crate::attribution::{GitHistory, SelfIdentity, Signals, TrustTier};
use crate::chunking::{ContentKind, TextChunk, chunk_text, image_chunk};
use crate::contact_names::ContactNames;
use crate::policy::WalkPolicy;
use crate::quality::assess;
use crate::walk::{stem, suffix};

/// The pictures a reader OCRs (`dispatch.IMAGE_EXTENSIONS`).
pub const IMAGE_EXTENSIONS: &[&str] =
    &[".png", ".jpg", ".jpeg", ".tiff", ".tif", ".bmp", ".gif", ".webp", ".heic", ".heif", ".hif", ".avif"];

/// What the database holds for a file (`gateway.ExistingDocStat`).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ExistingStat {
    /// Whether a row or a remembered outcome exists.
    pub exists: bool,
    /// The size it was indexed at.
    pub byte_size: i64,
    /// Its modification time then, in seconds.
    pub mtime: f64,
    /// The extracted text's hash.
    pub content_sha256: String,
    /// The chunker signature.
    pub chunker: String,
    /// `OK`, `PLACEHOLDER`, `NO_TEXT`, `FAILED`, `EXTRACT_FAILED`...
    pub state: String,
    /// The raw bytes' hash.
    pub source_sha256: String,
}

impl ExistingStat {
    /// `_has_indexed_content`: an OK row, or one an older build marked as a placeholder after indexing it.
    fn has_indexed_content(&self) -> bool {
        let state = self.state.to_uppercase();
        state == "OK" || (state == "PLACEHOLDER" && !self.content_sha256.is_empty())
    }

    /// `_is_settled`: indexed, or known to hold no text or to fail.
    fn is_settled(&self) -> bool {
        let state = self.state.to_uppercase();
        self.exists && (self.has_indexed_content() || state == "NO_TEXT" || state == "FAILED")
    }
}

/// One file the walk found (`walker.Candidate`).
#[derive(Clone, Debug, PartialEq)]
pub struct FileCandidate {
    /// Its path.
    pub path: std::path::PathBuf,
    /// Its URI in the database.
    pub uri: String,
    /// Its size.
    pub size: u64,
    /// Its modification time, in seconds.
    pub mtime: f64,
    /// Whether it is a cloud placeholder.
    pub placeholder: bool,
}

impl FileCandidate {
    fn name(&self) -> String {
        self.path.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default()
    }

    fn suffix(&self) -> String {
        suffix(&self.name()).to_lowercase()
    }

    fn stem(&self) -> String {
        stem(&self.name()).to_owned()
    }

    /// `_stat_matches`: unchanged since `existing` by its stat alone. A placeholder reporting no
    /// size is compared on its modification time only.
    #[allow(clippy::cast_precision_loss)]
    fn stat_matches(&self, existing: &ExistingStat) -> bool {
        let same_mtime = existing.mtime > 0.0 && (existing.mtime - self.mtime).abs() < 1.0;
        if !same_mtime {
            return false;
        }
        if self.placeholder && self.size == 0 {
            return true;
        }
        existing.byte_size == i64::try_from(self.size).unwrap_or(i64::MAX)
    }
}

/// A reader's document (`base.ExtractResult`).
#[derive(Clone, Debug, PartialEq)]
pub struct Extracted {
    /// The text.
    pub text: String,
    /// How it is chunked.
    pub kind: ContentKind,
    /// The reader.
    pub extractor: String,
    /// Its version.
    pub extractor_version: String,
    /// The title, when known.
    pub title: Option<String>,
    /// The language, when known.
    pub lang: Option<String>,
    /// Provenance.
    pub meta: Map<String, Value>,
    /// Authors the reader found.
    pub author_hints: Vec<String>,
}

/// How reading a file went.
#[derive(Clone, Debug, PartialEq)]
pub enum ReadOutcome {
    /// A document.
    Document(Extracted),
    /// Read fine, and holds no text (`NoTextFound`).
    NoText(String),
    /// A cloud placeholder that is still not local (`PlaceholderFile`, or a read the kernel
    /// refused to download).
    Placeholder,
    /// The reader failed (`ExtractionError`, `OSError`).
    Failed(String),
}

/// Reading a file: the host's.
pub trait FileHost {
    /// `ensure_local`: makes a placeholder local within the run's budget; `false` when it stays in the cloud.
    fn ensure_local(&mut self, candidate: &FileCandidate) -> bool;
    /// `file_sha256` of the bytes, hex; `None` when the file cannot be read.
    fn source_sha256(&mut self, candidate: &FileCandidate) -> Option<String>;
    /// The reader's outcome.
    fn read(&mut self, candidate: &FileCandidate) -> ReadOutcome;
}

/// An author as the facade stores it (`gateway.AuthorPayload`).
#[derive(Clone, Debug, PartialEq)]
pub struct AuthorPayload {
    /// The name.
    pub name: String,
    /// `author` or `committer`.
    pub role: String,
    /// From 0 to 1.
    pub confidence: f64,
    /// Where it came from.
    pub evidence: String,
    /// Identity kind -> value, in the order Python's dict keeps.
    pub identities: Vec<(String, String)>,
    /// Whether it is the owner.
    pub is_self: bool,
}

/// A chunk as the facade stores it (`gateway.ChunkPayload`).
#[derive(Clone, Debug, PartialEq)]
pub struct ChunkPayload {
    /// Its position.
    pub ord: usize,
    /// Its text.
    pub text: String,
    /// `TextChunk.token_estimate`.
    pub token_count: usize,
    /// Where it starts in the text, in characters.
    pub char_start: Option<usize>,
    /// Where it ends.
    pub char_end: Option<usize>,
    /// Its heading path.
    pub heading_path: Option<String>,
    /// The text's hash, hex.
    pub chunk_sha256: String,
    /// The chunker.
    pub chunker: String,
}

/// A document to write (`replace_document`'s arguments).
#[derive(Clone, Debug, PartialEq)]
pub struct DocumentPayload {
    /// Its title.
    pub title: Option<String>,
    /// Its language.
    pub lang: Option<String>,
    /// Its size.
    pub byte_size: u64,
    /// Its modification time.
    pub mtime: f64,
    /// The bytes' hash, when they could be read.
    pub source_sha256: Option<String>,
    /// The text's hash.
    pub content_sha256: String,
    /// The reader.
    pub extractor: String,
    /// Its version.
    pub extractor_version: String,
    /// The chunker signature.
    pub chunker: String,
    /// The text.
    pub content: String,
    /// Provenance, attribution's included.
    pub meta: Map<String, Value>,
    /// `document`, `code` or `communication`.
    pub corpus_class: String,
    /// `authored`, `reference` or `received`.
    pub trust_tier: String,
    /// Its authors.
    pub authors: Vec<AuthorPayload>,
    /// Its chunks.
    pub chunks: Vec<ChunkPayload>,
}

/// The facade calls ingest makes for one file (`IngestStorageGateway`'s `record_*`,
/// `refresh_metadata` and `replace_document`). The run and source are the storage's own. A call
/// that fails says why; ingest stops that file there, as Python's gateway raising does.
pub trait Storage {
    /// `record_seen`.
    ///
    /// # Errors
    ///
    /// Why the call failed.
    fn record_seen(&mut self, uri: &str) -> Result<(), String>;
    /// `record_placeholder`.
    ///
    /// # Errors
    ///
    /// Why the call failed.
    fn record_placeholder(&mut self, uri: &str, mtime: f64, title: &str, reason: &str) -> Result<(), String>;
    /// `record_no_text`.
    ///
    /// # Errors
    ///
    /// Why the call failed.
    fn record_no_text(&mut self, uri: &str, byte_size: u64, mtime: f64, source_sha256: &str) -> Result<(), String>;
    /// `record_extract_failed`.
    ///
    /// # Errors
    ///
    /// Why the call failed.
    fn record_extract_failed(
        &mut self,
        uri: &str,
        error: &str,
        byte_size: u64,
        mtime: f64,
        source_sha256: &str,
    ) -> Result<(), String>;
    /// `record_rejected`.
    ///
    /// # Errors
    ///
    /// Why the call failed.
    fn record_rejected(&mut self, uri: &str) -> Result<(), String>;
    /// `refresh_metadata`; empty class and trust leave the row's own.
    ///
    /// # Errors
    ///
    /// Why the call failed.
    fn refresh_metadata(
        &mut self,
        uri: &str,
        byte_size: u64,
        mtime: f64,
        source_sha256: &str,
        corpus_class: &str,
        trust_tier: &str,
    ) -> Result<(), String>;
    /// `replace_document`: the chunks written.
    ///
    /// # Errors
    ///
    /// Why the call failed.
    fn replace_document(&mut self, uri: &str, document: DocumentPayload) -> Result<usize, String>;
}

/// `IngestCounters`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Counters {
    /// Files the walk yielded.
    pub seen: u64,
    /// Documents written.
    pub indexed: u64,
    /// Files left as they were.
    pub skipped: u64,
    /// Files that failed.
    pub failed: u64,
    /// Placeholders left in the cloud.
    pub placeholders: u64,
    /// Files with nothing to index.
    pub rejected: u64,
    /// Chunks written.
    pub chunks_written: u64,
    /// The first 50 failures.
    pub errors: Vec<String>,
}

impl Counters {
    /// `note_error`.
    pub fn note_error(&mut self, message: String) {
        self.failed += 1;
        if self.errors.len() < 50 {
            self.errors.push(message);
        }
    }
}

/// The settings ingest reads (`Settings`'s fields of the same names).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct IngestSettings {
    /// Reject machine-generated text.
    pub reject_machine_generated: bool,
    /// Give scanned pictures an image chunk too.
    pub index_images: bool,
    /// The most chunks one document keeps.
    pub max_chunks_per_document: usize,
    /// Prose chunk size.
    pub chunk_size: usize,
    /// Prose overlap.
    pub chunk_overlap: usize,
    /// Code chunk size.
    pub code_chunk_size: usize,
    /// Code overlap.
    pub code_chunk_overlap: usize,
}

impl Default for IngestSettings {
    fn default() -> Self {
        Self {
            reject_machine_generated: true,
            index_images: true,
            max_chunks_per_document: 1500,
            chunk_size: 1000,
            chunk_overlap: 150,
            code_chunk_size: 1500,
            code_chunk_overlap: 100,
        }
    }
}

/// The source being ingested (`gateway.SourceContext`).
#[derive(Clone, Debug)]
pub struct SourceInfo {
    /// Its root.
    pub root: std::path::PathBuf,
    /// Its default class.
    pub default_class: String,
    /// Its default trust.
    pub default_trust: TrustTier,
}

/// What one file is decided against.
pub struct Context<'a> {
    /// The source.
    pub source: &'a SourceInfo,
    /// The owner.
    pub identity: &'a SelfIdentity,
    /// Git history.
    pub git: &'a dyn GitHistory,
    /// Names for handles.
    pub contact_names: Option<&'a ContactNames>,
    /// The settings.
    pub settings: &'a IngestSettings,
    /// The tables `classify` reads.
    pub policy: &'a WalkPolicy,
    /// Ignore every reason to skip.
    pub force: bool,
}

/// `classify`: the corpus class, by content shape first and the source's default after.
#[must_use]
pub fn classify(name: &str, kind: ContentKind, source_default: &str, policy: &WalkPolicy) -> &'static str {
    if kind == ContentKind::Conversation || source_default == "communication" {
        return "communication";
    }
    let extension = suffix(name).to_lowercase();
    let documentation = policy.doc_extensions.contains(&extension)
        || (!policy.code_extensions.contains(&extension) && policy.doc_stems.contains(&stem(name).to_lowercase()));
    if documentation {
        return "document";
    }
    match kind {
        ContentKind::Code => "code",
        ContentKind::Conversation => "communication",
        _ => "document",
    }
}

/// `ContentKind`'s value.
#[must_use]
pub fn kind_name(kind: ContentKind) -> &'static str {
    match kind {
        ContentKind::Prose => "prose",
        ContentKind::Markdown => "markdown",
        ContentKind::Code => "code",
        ContentKind::Tabular => "tabular",
        ContentKind::Conversation => "conversation",
        ContentKind::Image => "image",
    }
}

/// `sha256_text`, hex.
#[must_use]
pub fn sha256_hex(bytes: &[u8]) -> String {
    crate::sha256::hex_digest(bytes)
}

/// `name_authors`: authors named after one of their own handles take the contact's name.
#[must_use]
pub fn name_authors(authors: Vec<AuthorPayload>, contact_names: Option<&ContactNames>) -> Vec<AuthorPayload> {
    let Some(names) = contact_names.filter(|names| !names.is_empty()) else { return authors };
    authors
        .into_iter()
        .map(|mut author| {
            let handles: Vec<&String> = author.identities.iter().map(|(_, value)| value).collect();
            if !author.is_self
                && handles.contains(&&author.name)
                && let Some(name) = handles.iter().find_map(|handle| names.name_for(handle))
            {
                author.name = name;
            }
            author
        })
        .collect()
}

fn placeholder(storage: &mut dyn Storage, candidate: &FileCandidate, counters: &mut Counters) -> Result<(), String> {
    counters.placeholders += 1;
    storage.record_placeholder(&candidate.uri, candidate.mtime, &candidate.stem(), "not materialized")
}

/// `ingest_one`: indexes one file, replacing any previous version of it.
///
/// # Errors
///
/// A storage call's failure; the counters then hold what happened before it.
#[allow(clippy::too_many_lines)]
pub fn ingest_one(
    host: &mut dyn FileHost,
    storage: &mut dyn Storage,
    existing: &ExistingStat,
    candidate: &FileCandidate,
    context: &Context<'_>,
    counters: &mut Counters,
) -> Result<(), String> {
    let force = context.force;
    let extension = candidate.suffix();

    // Step 1: an unchanged stat, without opening the file. For a placeholder this avoids a download.
    // A row an older reader indexed is read again (`.eml` became mail, a communication).
    let retired =
        extension == ".eml" && existing.has_indexed_content() && !existing.chunker.starts_with("conversation:");
    if !force && existing.is_settled() && candidate.stat_matches(existing) && !retired {
        counters.skipped += 1;
        return storage.record_seen(&candidate.uri);
    }

    if !host.ensure_local(candidate) {
        return placeholder(storage, candidate, counters);
    }

    // Step 2: unchanged bytes.
    let raw_hash = host.source_sha256(candidate);
    if !force
        && let Some(hash) = raw_hash.as_deref().filter(|hash| !hash.is_empty())
        && existing.source_sha256 == hash
        && existing.is_settled()
    {
        counters.skipped += 1;
        return match existing.state.to_uppercase().as_str() {
            "NO_TEXT" => storage.record_no_text(&candidate.uri, candidate.size, candidate.mtime, hash),
            "FAILED" => storage.record_seen(&candidate.uri),
            _ => storage.refresh_metadata(&candidate.uri, candidate.size, candidate.mtime, hash, "", ""),
        };
    }
    let raw_hash_or_empty = raw_hash.clone().unwrap_or_default();

    // Step 3: extract.
    let result = match host.read(candidate) {
        ReadOutcome::Document(result) => result,
        ReadOutcome::NoText(_) => {
            counters.rejected += 1;
            return storage.record_no_text(&candidate.uri, candidate.size, candidate.mtime, &raw_hash_or_empty);
        }
        ReadOutcome::Placeholder => return placeholder(storage, candidate, counters),
        ReadOutcome::Failed(error) => {
            counters.note_error(format!("{}: {error}", candidate.name()));
            return storage.record_extract_failed(
                &candidate.uri,
                &error,
                candidate.size,
                candidate.mtime,
                &raw_hash_or_empty,
            );
        }
    };
    let settings = context.settings;

    // A content backstop for machine output the path rules missed; a picture's text is its name.
    if settings.reject_machine_generated
        && result.kind != ContentKind::Image
        && assess(&result.text, crate::quality::SAMPLE_CHARS).machine_generated
    {
        counters.rejected += 1;
        return storage.record_rejected(&candidate.uri);
    }

    let content_hash = sha256_hex(result.text.as_bytes());
    let (size, overlap) = if result.kind == ContentKind::Code {
        (settings.code_chunk_size, settings.code_chunk_overlap)
    } else {
        (settings.chunk_size, settings.chunk_overlap)
    };
    let mut chunks = match chunk_text(&result.text, result.kind, &extension, size, overlap) {
        Ok(chunks) => chunks,
        Err(error) => {
            counters.note_error(format!("{}: {error}", candidate.name()));
            return storage.record_seen(&candidate.uri);
        }
    };
    if chunks.is_empty() {
        counters.rejected += 1;
        return storage.record_rejected(&candidate.uri);
    }
    if settings.index_images && IMAGE_EXTENSIONS.contains(&extension.as_str()) && result.kind != ContentKind::Image {
        // A screenshot or scan: its text is chunked above, and one image chunk lets an image
        // embedding model embed the picture itself.
        let title = result.title.clone().filter(|title| !title.is_empty()).unwrap_or_else(|| candidate.stem());
        let mut chunk: TextChunk = image_chunk(&title);
        chunk.ord = chunks.len();
        chunks.push(chunk);
    }
    // No single document may dominate the index.
    let truncated = chunks.len().saturating_sub(settings.max_chunks_per_document);
    chunks.truncate(settings.max_chunks_per_document);
    let label = chunks.first().map_or("none", |chunk| chunk.chunker.as_str());
    let signature = format!("{}:{label}", kind_name(result.kind));

    let corpus_class = classify(&candidate.name(), result.kind, &context.source.default_class, context.policy);
    let signals = Signals {
        source_root: &context.source.root,
        default_trust: context.source.default_trust,
        author_hints: &result.author_hints,
        identity: context.identity,
        communication: result.kind == ContentKind::Conversation,
    };
    let attribution = crate::attribution::resolve(&candidate.path, &signals, context.git);

    // Step 4: unchanged text under the same chunker keeps its chunks.
    if existing.exists
        && !force
        && existing.content_sha256 == content_hash
        && existing.chunker == signature
        && existing.state.to_uppercase() == "OK"
    {
        storage.refresh_metadata(
            &candidate.uri,
            candidate.size,
            candidate.mtime,
            &raw_hash_or_empty,
            corpus_class,
            attribution.trust.as_str(),
        )?;
        counters.skipped += 1;
        return Ok(());
    }

    // Step 5: replace.
    let mut meta = result.meta.clone();
    for (key, value) in &attribution.meta {
        meta.insert(key.clone(), value.clone());
    }
    meta.insert("attribution".to_owned(), json!(attribution.evidence));
    if truncated > 0 {
        meta.insert("truncated_chunks".to_owned(), json!(truncated));
    }
    let authors = attribution
        .authors
        .iter()
        .filter(|author| !author.name.is_empty())
        .map(|author| {
            let mut identities = Vec::new();
            if let Some(email) = author.email.as_deref().filter(|email| !email.is_empty()) {
                let kind = if author.evidence.starts_with("git") { "git_email" } else { "email" };
                identities.push((kind.to_owned(), email.to_lowercase()));
            }
            identities.push(("git_name".to_owned(), author.name.clone()));
            AuthorPayload {
                name: author.name.clone(),
                role: author.role.as_str().to_owned(),
                confidence: author.confidence,
                evidence: author.evidence.clone(),
                identities,
                is_self: context.identity.matches(Some(&author.name), author.email.as_deref()),
            }
        })
        .collect();
    let authors = name_authors(authors, context.contact_names);
    let chunks = chunks
        .into_iter()
        .map(|chunk| ChunkPayload {
            ord: chunk.ord,
            token_count: (chunk.text.chars().count() / 4).max(1),
            char_start: chunk.char_start,
            char_end: chunk.char_end,
            heading_path: chunk.heading_path,
            chunk_sha256: sha256_hex(chunk.text.as_bytes()),
            chunker: chunk.chunker,
            text: chunk.text,
        })
        .collect();
    let document = DocumentPayload {
        title: result.title,
        lang: result.lang,
        byte_size: candidate.size,
        mtime: candidate.mtime,
        source_sha256: raw_hash,
        content_sha256: content_hash,
        extractor: result.extractor,
        extractor_version: result.extractor_version,
        chunker: signature,
        content: result.text,
        meta,
        corpus_class: corpus_class.to_owned(),
        trust_tier: attribution.trust.as_str().to_owned(),
        authors,
        chunks,
    };
    let written = storage.replace_document(&candidate.uri, document)?;
    counters.chunks_written += written as u64;
    counters.indexed += 1;
    Ok(())
}

//! Ingest's database, as the Rust pipeline reaches it: GarageService's facade calls.
//!
//! [`GrpcStorage`] is `ingest/gateway.py`'s `GrpcIngestStorageGateway`: each [`Storage`] call is one
//! `PersistDocument` with the same action and fields, and a session begins with
//! `BeginIngestSession`, asks `CheckDocumentStat` before each file and ends with
//! `FinalizeIngestSession`.

use garage_facade::FacadeError;
use garage_facade::proto::{
    BeginIngestSessionRequest, BeginIngestSessionResponse, CheckDocumentStatRequest, DocumentAuthorPayload,
    DocumentChunkPayload, FinalizeIngestSessionRequest, PersistDocumentRequest,
};

use crate::pipeline::{Counters, DocumentPayload, ExistingStat, Storage};

pub use garage_facade::{Connection, GrpcTarget};

/// GarageService's ingest calls, for one run of one source.
pub struct GrpcStorage {
    connection: Connection,
    run_id: i64,
    source_slug: String,
}

impl GrpcStorage {
    /// Persists through `connection` into the run `run_id` (from [`begin_session`]) of `source_slug`.
    #[must_use]
    pub fn new(connection: Connection, run_id: i64, source_slug: &str) -> Self {
        Self { connection, run_id, source_slug: source_slug.to_owned() }
    }

    /// The connection, for the session calls.
    #[must_use]
    pub fn connection(&self) -> &Connection {
        &self.connection
    }

    /// What the database holds for `uri`: `CheckDocumentStat`.
    ///
    /// # Errors
    ///
    /// The call's failure.
    pub fn check_stat(&self, uri: &str) -> Result<ExistingStat, FacadeError> {
        let request = CheckDocumentStatRequest { source_slug: self.source_slug.clone(), uri: uri.to_owned() };
        let reply = self.connection.call(|mut client| async move { client.check_document_stat(request).await })?;
        Ok(ExistingStat {
            exists: reply.exists,
            byte_size: reply.byte_size,
            mtime: reply.mtime,
            content_sha256: reply.content_sha256,
            chunker: reply.chunker,
            state: reply.state,
            source_sha256: reply.source_sha256,
        })
    }

    /// Ends the run, with what it did: `FinalizeIngestSession`.
    ///
    /// # Errors
    ///
    /// The call's failure.
    pub fn finalize(
        &self,
        completed: bool,
        counters: &Counters,
        materialized: i64,
        materialized_bytes: i64,
    ) -> Result<(), FacadeError> {
        let count = |value: u64| i64::try_from(value).unwrap_or(i64::MAX);
        let request = FinalizeIngestSessionRequest {
            run_id: self.run_id,
            completed,
            seen_count: count(counters.seen),
            indexed_count: count(counters.indexed),
            skipped_count: count(counters.skipped),
            failed_count: count(counters.failed),
            placeholder_count: count(counters.placeholders),
            materialized_count: materialized,
            materialized_bytes,
            errors: counters.errors.clone(),
        };
        self.connection.call(|mut client| async move { client.finalize_ingest_session(request).await })?;
        Ok(())
    }

    fn persist(&self, request: PersistDocumentRequest) -> Result<i32, String> {
        let request = PersistDocumentRequest { run_id: self.run_id, source_slug: self.source_slug.clone(), ..request };
        let reply = self
            .connection
            .call(|mut client| async move { client.persist_document(request).await })
            .map_err(|error| error.to_string())?;
        Ok(reply.chunks_written)
    }
}

/// Starts a run of `source_slug`: `BeginIngestSession`.
///
/// # Errors
///
/// The call's failure; an unknown source is [`FacadeError::NotFound`].
pub fn begin_session(
    connection: &Connection,
    source_slug: &str,
    include_code: bool,
) -> Result<BeginIngestSessionResponse, FacadeError> {
    let request = BeginIngestSessionRequest { source_slug: source_slug.to_owned(), include_code };
    connection.call(|mut client| async move { client.begin_ingest_session(request).await })
}

fn action(uri: &str, action: &str) -> PersistDocumentRequest {
    PersistDocumentRequest { uri: uri.to_owned(), action: action.to_owned(), ..PersistDocumentRequest::default() }
}

fn size(value: u64) -> i64 {
    i64::try_from(value).unwrap_or(i64::MAX)
}

fn int32(value: usize) -> i32 {
    i32::try_from(value).unwrap_or(i32::MAX)
}

impl Storage for GrpcStorage {
    fn record_seen(&mut self, uri: &str) -> Result<(), String> {
        self.persist(action(uri, "seen")).map(drop)
    }

    fn record_placeholder(&mut self, uri: &str, mtime: f64, title: &str, reason: &str) -> Result<(), String> {
        self.persist(PersistDocumentRequest {
            title: title.to_owned(),
            mtime,
            error: reason.to_owned(),
            ..action(uri, "placeholder")
        })
        .map(drop)
    }

    fn record_no_text(&mut self, uri: &str, byte_size: u64, mtime: f64, source_sha256: &str) -> Result<(), String> {
        self.persist(PersistDocumentRequest {
            byte_size: size(byte_size),
            mtime,
            source_sha256: source_sha256.to_owned(),
            ..action(uri, "no_text")
        })
        .map(drop)
    }

    fn record_extract_failed(
        &mut self,
        uri: &str,
        error: &str,
        byte_size: u64,
        mtime: f64,
        source_sha256: &str,
    ) -> Result<(), String> {
        self.persist(PersistDocumentRequest {
            error: error.to_owned(),
            byte_size: size(byte_size),
            mtime,
            source_sha256: source_sha256.to_owned(),
            ..action(uri, "extract_failed")
        })
        .map(drop)
    }

    fn record_rejected(&mut self, uri: &str) -> Result<(), String> {
        self.persist(action(uri, "rejected")).map(drop)
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
        self.persist(PersistDocumentRequest {
            byte_size: size(byte_size),
            mtime,
            source_sha256: source_sha256.to_owned(),
            corpus_class: corpus_class.to_owned(),
            trust_tier: trust_tier.to_owned(),
            ..action(uri, "refresh_metadata")
        })
        .map(drop)
    }

    fn replace_document(&mut self, uri: &str, document: DocumentPayload) -> Result<usize, String> {
        let authors = document
            .authors
            .into_iter()
            .map(|author| DocumentAuthorPayload {
                name: author.name,
                role: author.role,
                #[allow(clippy::cast_possible_truncation)]
                confidence: author.confidence as f32,
                evidence: author.evidence,
                identities: author.identities.into_iter().collect(),
                is_self: author.is_self,
            })
            .collect();
        let chunks = document
            .chunks
            .into_iter()
            .map(|chunk| DocumentChunkPayload {
                ord: int32(chunk.ord),
                text: chunk.text,
                token_count: int32(chunk.token_count),
                char_start: chunk.char_start.map(int32),
                char_end: chunk.char_end.map(int32),
                heading_path: chunk.heading_path.unwrap_or_default(),
                chunk_sha256: chunk.chunk_sha256,
                chunker: chunk.chunker,
                ..DocumentChunkPayload::default()
            })
            .collect();
        let meta_json = if document.meta.is_empty() {
            "{}".to_owned()
        } else {
            serde_json::to_string(&document.meta).map_err(|error| error.to_string())?
        };
        let written = self.persist(PersistDocumentRequest {
            title: document.title.unwrap_or_default(),
            lang: document.lang.unwrap_or_default(),
            byte_size: size(document.byte_size),
            mtime: document.mtime,
            source_sha256: document.source_sha256.unwrap_or_default(),
            content_sha256: document.content_sha256,
            extractor: document.extractor,
            extractor_version: document.extractor_version,
            chunker: document.chunker,
            content: document.content,
            meta_json,
            corpus_class: document.corpus_class,
            trust_tier: document.trust_tier,
            authors,
            chunks,
            ..action(uri, "replace")
        })?;
        Ok(usize::try_from(written).unwrap_or_default())
    }
}

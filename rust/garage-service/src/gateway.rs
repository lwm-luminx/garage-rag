//! The server side of the ingest storage facade (`ingest.gateway.SqlAlchemyIngestStorageGateway`):
//! ingest runs, the remembered no-text and failed outcomes, and `replace_document`, which keeps
//! every chunk whose ord, hash, text and chunker are unchanged so its vectors survive. Authors are
//! resolved by identity first (`attribute.resolver.get_or_create_author`), and an author known
//! only by a handle takes the contact name it later arrives with (`_adopt_name`).

use std::collections::{HashMap, HashSet};

use chrono::{DateTime, Utc};
use serde_json::{Map, Value, json};
use tokio_postgres::Transaction;

use crate::config::Config;
use crate::db::{Client, hex_bytes, hex_string};
use crate::error::{Result, ServiceError};
use crate::revision::python_extractor_revision;

/// The context an ingest run opens with (`SourceContext`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SourceContext {
    pub source_id: i64,
    pub slug: String,
    pub root: String,
    pub default_class: String,
    pub default_trust: String,
    pub run_id: i64,
    pub kind: String,
    pub source_slugs: Vec<String>,
    pub query: String,
}

/// What is known of a document before its file is read (`ExistingDocStat`).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ExistingDocStat {
    pub exists: bool,
    pub byte_size: i64,
    pub mtime: f64,
    pub content_sha256: String,
    pub chunker: String,
    pub state: String,
    pub source_sha256: String,
    pub existing_document_id: Option<i64>,
    pub already_linked: bool,
}

/// One author of a document as the pipeline attributed it (`AuthorPayload`).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct AuthorPayload {
    pub name: String,
    pub role: String,
    pub confidence: f32,
    pub evidence: Option<String>,
    pub identities: Vec<(String, String)>,
    pub is_self: bool,
}

/// One chunk to store (`ChunkPayload`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ChunkPayload {
    pub ord: i32,
    pub text: String,
    pub token_count: Option<i32>,
    pub char_start: Option<i32>,
    pub char_end: Option<i32>,
    pub heading_path: Option<String>,
    /// Hex.
    pub chunk_sha256: String,
    pub chunker: Option<String>,
    pub direction: Option<String>,
    pub sender: Option<String>,
    pub session_turn_external_id: Option<String>,
}

/// Everything `replace_document` writes.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct DocumentPayload {
    pub title: Option<String>,
    pub lang: Option<String>,
    pub byte_size: i64,
    pub mtime: f64,
    /// Hex; empty for none.
    pub source_sha256: String,
    /// Hex.
    pub content_sha256: String,
    pub extractor: String,
    pub extractor_version: String,
    pub chunker: Option<String>,
    pub content: Option<String>,
    pub meta: Map<String, Value>,
    pub corpus_class: String,
    pub trust_tier: String,
    pub authors: Vec<AuthorPayload>,
    pub chunks: Vec<ChunkPayload>,
    pub session_json: Option<String>,
}

struct SourceRow {
    id: i64,
    slug: String,
    root: String,
    kind: String,
    default_class: String,
    default_trust: String,
    query: String,
}

async fn source_by_slug(tx: &Transaction<'_>, slug: &str) -> Result<SourceRow> {
    let row = tx
        .query_opt(
            "SELECT id, slug, root, kind, default_class::text, default_trust::text, \
             coalesce(config->>'query', '') FROM sources WHERE slug = $1",
            &[&slug],
        )
        .await?
        .ok_or_else(|| ServiceError::not_found(format!("No such source: {slug}")))?;
    Ok(SourceRow {
        id: row.get(0),
        slug: row.get(1),
        root: row.get(2),
        kind: row.get(3),
        default_class: row.get(4),
        default_trust: row.get(5),
        query: row.get(6),
    })
}

async fn mark_seen(tx: &Transaction<'_>, run_id: i64, uri: &str) -> Result<()> {
    if run_id != 0 {
        tx.execute("INSERT INTO ingest_seen (run_id, uri) VALUES ($1, $2) ON CONFLICT DO NOTHING", &[&run_id, &uri])
            .await?;
    }
    Ok(())
}

/// Slugs of every enabled source, in registration order (`list_enabled_sources`).
///
/// # Errors
///
/// The server.
pub async fn list_enabled_sources(client: &Client) -> Result<Vec<String>> {
    let rows = client.query("SELECT slug FROM sources WHERE enabled ORDER BY id", &[]).await?;
    Ok(rows.iter().map(|row| row.get(0)).collect())
}

/// Opens an ingest run for `source_slug`, or `*` for every enabled source (`begin_session`). The
/// corpus owner's author row is made or brought up to date first (`ensure_self_author`).
///
/// # Errors
///
/// [`ServiceError::NotFound`] for an unknown slug or no sources at all.
pub async fn begin_session(client: &mut Client, config: &Config, source_slug: &str) -> Result<SourceContext> {
    let tx = client.transaction().await?;
    let (source, source_slugs) = if source_slug == "*" {
        let rows = tx
            .query(
                "SELECT id, slug, root, kind, default_class::text, default_trust::text, \
                 coalesce(config->>'query', '') FROM sources WHERE enabled ORDER BY id",
                &[],
            )
            .await?;
        let first = rows.first().ok_or_else(|| ServiceError::not_found("No sources registered"))?;
        let slugs: Vec<String> = rows.iter().map(|row| row.get(1)).collect();
        (
            SourceRow {
                id: first.get(0),
                slug: first.get(1),
                root: first.get(2),
                kind: first.get(3),
                default_class: first.get(4),
                default_trust: first.get(5),
                query: first.get(6),
            },
            slugs,
        )
    } else {
        let source = source_by_slug(&tx, source_slug).await?;
        let slugs = vec![source.slug.clone()];
        (source, slugs)
    };
    ensure_self_author(&tx, config).await?;
    let run_id: i64 =
        tx.query_one("INSERT INTO ingest_runs (source_id) VALUES ($1) RETURNING id", &[&source.id]).await?.get(0);
    tx.commit().await?;
    Ok(SourceContext {
        source_id: source.id,
        slug: source.slug,
        root: source.root,
        default_class: source.default_class,
        default_trust: source.default_trust,
        run_id,
        kind: source.kind,
        source_slugs,
        query: source.query,
    })
}

/// Records a scan's expected element count and details on the source (`persist_scan_result`).
///
/// # Errors
///
/// An unknown slug, or the server.
pub async fn persist_scan(
    client: &mut Client,
    source_slug: &str,
    item_count: i64,
    item_type: &str,
    details: &Value,
) -> Result<()> {
    let tx = client.transaction().await?;
    source_by_slug(&tx, source_slug).await?;
    let details = if details.is_object() { details.clone() } else { Value::Object(Map::new()) };
    tx.execute(
        "UPDATE sources SET expected_elements = $2, scan_item_type = $3, scan_details = $4, scanned_at = now() WHERE slug = $1",
        &[&source_slug, &item_count, &item_type, &details],
    )
    .await?;
    tx.commit().await?;
    Ok(())
}

/// The stored no-text or failed outcome for `uri`, if its reader is unchanged since
/// (`_remembered_outcome`); `revision` is the caller's reader, else the Python readers'.
async fn remembered_outcome(
    tx: &Transaction<'_>,
    source_id: i64,
    uri: &str,
    revision: Option<&str>,
) -> Result<Option<ExistingDocStat>> {
    let row = tx
        .query_opt(
            "SELECT outcome, byte_size, extract(epoch FROM mtime)::float8, source_sha256, extractor_revision \
             FROM ingest_outcomes WHERE source_id = $1 AND uri = $2",
            &[&source_id, &uri],
        )
        .await?;
    let Some(row) = row else { return Ok(None) };
    let stored: String = row.get(4);
    let wanted = revision.map_or_else(|| python_extractor_revision(uri), str::to_owned);
    if stored != wanted {
        return Ok(None);
    }
    Ok(Some(ExistingDocStat {
        exists: true,
        byte_size: row.get::<_, Option<i64>>(1).unwrap_or(0),
        mtime: row.get::<_, Option<f64>>(2).unwrap_or(0.0),
        content_sha256: String::new(),
        chunker: String::new(),
        state: row.get(0),
        source_sha256: row.get::<_, Option<Vec<u8>>>(3).map(|b| hex_string(&b)).unwrap_or_default(),
        ..Default::default()
    }))
}

#[allow(clippy::too_many_arguments)]
async fn remember_outcome(
    tx: &Transaction<'_>,
    source_id: i64,
    uri: &str,
    outcome: &str,
    byte_size: i64,
    mtime: f64,
    source_sha256: &str,
    error: Option<&str>,
    revision: Option<&str>,
) -> Result<()> {
    let revision = revision.map_or_else(|| python_extractor_revision(uri), str::to_owned);
    let size = (byte_size != 0).then_some(byte_size);
    let mtime = (mtime != 0.0).then_some(mtime);
    let sha = (!source_sha256.is_empty()).then(|| hex_bytes(source_sha256));
    tx.execute(
        "INSERT INTO ingest_outcomes (source_id, uri, outcome, byte_size, mtime, source_sha256, extractor_revision, error, recorded_at) \
         VALUES ($1, $2, $3, $4, to_timestamp($5), $6, $7, $8, now()) \
         ON CONFLICT (source_id, uri) DO UPDATE SET outcome = EXCLUDED.outcome, byte_size = EXCLUDED.byte_size, \
         mtime = EXCLUDED.mtime, source_sha256 = EXCLUDED.source_sha256, extractor_revision = EXCLUDED.extractor_revision, \
         error = EXCLUDED.error, recorded_at = EXCLUDED.recorded_at",
        &[&source_id, &uri, &outcome, &size, &mtime, &sha, &revision, &error],
    )
    .await?;
    Ok(())
}

async fn forget_outcome(tx: &Transaction<'_>, source_id: i64, uri: &str) -> Result<()> {
    tx.execute("DELETE FROM ingest_outcomes WHERE source_id = $1 AND uri = $2", &[&source_id, &uri]).await?;
    Ok(())
}

/// The existing document's stat and hashes, for change detection (`check_stat`). A document that
/// is missing or not `ok` answers with the remembered outcome when one applies.
///
/// # Errors
///
/// An unknown slug, or the server.
pub async fn check_stat(
    client: &mut Client,
    source_slug: &str,
    uri: &str,
    extractor_revision: Option<&str>,
) -> Result<ExistingDocStat> {
    let tx = client.transaction().await?;
    let source = source_by_slug(&tx, source_slug).await?;
    let doc = tx
        .query_opt(
            "SELECT byte_size, extract(epoch FROM mtime)::float8, content_sha256, chunker, state::text, source_sha256 \
             FROM documents WHERE source_id = $1 AND uri = $2",
            &[&source.id, &uri],
        )
        .await?;
    if doc.is_none()
        && source.kind == "spotlight"
        && let Some(row) = tx
            .query_opt(
                "SELECT d.id, \
                        coalesce(extract(epoch FROM ds.mtime)::float8, extract(epoch FROM d.mtime)::float8, 0.0), \
                        ds.source_id IS NOT NULL, \
                        coalesce(d.byte_size, 0) \
                 FROM documents d \
                 LEFT JOIN document_sources ds ON ds.document_id = d.id AND ds.source_id = $1 \
                 WHERE d.uri = $2 AND d.source_id <> $1 AND d.state = 'ok' \
                 ORDER BY d.id \
                 LIMIT 1",
                &[&source.id, &uri],
            )
            .await?
    {
        return Ok(ExistingDocStat {
            exists: false,
            byte_size: row.get(3),
            mtime: row.get(1),
            state: "ok".to_owned(),
            existing_document_id: Some(row.get(0)),
            already_linked: row.get(2),
            ..Default::default()
        });
    }
    let state: Option<String> = doc.as_ref().map(|row| row.get(4));
    if state.as_deref() != Some("ok")
        && let Some(remembered) = remembered_outcome(&tx, source.id, uri, extractor_revision).await?
    {
        return Ok(remembered);
    }
    let Some(row) = doc else { return Ok(ExistingDocStat::default()) };
    Ok(ExistingDocStat {
        exists: true,
        byte_size: row.get::<_, Option<i64>>(0).unwrap_or(0),
        mtime: row.get::<_, Option<f64>>(1).unwrap_or(0.0),
        content_sha256: hex_string(&row.get::<_, Vec<u8>>(2)),
        chunker: row.get::<_, Option<String>>(3).unwrap_or_default(),
        state: state.unwrap_or_default(),
        source_sha256: row.get::<_, Option<Vec<u8>>>(5).map(|b| hex_string(&b)).unwrap_or_default(),
        ..Default::default()
    })
}

/// Records that `uri` was observed by the run without touching its document (`record_seen`).
///
/// # Errors
///
/// The server.
pub async fn record_seen(client: &mut Client, run_id: i64, uri: &str) -> Result<()> {
    if run_id == 0 {
        return Ok(());
    }
    let tx = client.transaction().await?;
    mark_seen(&tx, run_id, uri).await?;
    tx.commit().await?;
    Ok(())
}

/// A placeholder was observed (`record_placeholder`): no document is written.
///
/// # Errors
///
/// An unknown slug.
pub async fn record_placeholder(client: &mut Client, run_id: i64, source_slug: &str, uri: &str) -> Result<()> {
    let tx = client.transaction().await?;
    source_by_slug(&tx, source_slug).await?;
    mark_seen(&tx, run_id, uri).await?;
    tx.commit().await?;
    Ok(())
}

/// Extraction failed (`record_extract_failed`): the document, if any, is marked, and the file's stat
/// is remembered so an unchanged file is not retried.
///
/// # Errors
///
/// An unknown slug.
#[allow(clippy::too_many_arguments)]
pub async fn record_extract_failed(
    client: &mut Client,
    run_id: i64,
    source_slug: &str,
    uri: &str,
    error: &str,
    byte_size: i64,
    mtime: f64,
    source_sha256: &str,
    extractor_revision: Option<&str>,
) -> Result<()> {
    let tx = client.transaction().await?;
    let source = source_by_slug(&tx, source_slug).await?;
    let error: String = error.chars().take(2000).collect();
    tx.execute(
        "UPDATE documents SET state = 'extract_failed', error = $3 WHERE source_id = $1 AND uri = $2",
        &[&source.id, &uri, &error],
    )
    .await?;
    if mtime != 0.0 || !source_sha256.is_empty() {
        remember_outcome(
            &tx,
            source.id,
            uri,
            "failed",
            byte_size,
            mtime,
            source_sha256,
            Some(&error),
            extractor_revision,
        )
        .await?;
    }
    mark_seen(&tx, run_id, uri).await?;
    tx.commit().await?;
    Ok(())
}

/// The file holds no text (`record_no_text`): its document, if any, is dropped and its stat remembered.
///
/// # Errors
///
/// An unknown slug.
#[allow(clippy::too_many_arguments)]
pub async fn record_no_text(
    client: &mut Client,
    run_id: i64,
    source_slug: &str,
    uri: &str,
    byte_size: i64,
    mtime: f64,
    source_sha256: &str,
    extractor_revision: Option<&str>,
) -> Result<()> {
    let tx = client.transaction().await?;
    let source = source_by_slug(&tx, source_slug).await?;
    tx.execute("DELETE FROM documents WHERE source_id = $1 AND uri = $2", &[&source.id, &uri]).await?;
    remember_outcome(&tx, source.id, uri, "no_text", byte_size, mtime, source_sha256, None, extractor_revision).await?;
    mark_seen(&tx, run_id, uri).await?;
    tx.commit().await?;
    Ok(())
}

/// The document was rejected (`record_rejected`): its row and its remembered outcome go.
///
/// # Errors
///
/// An unknown slug.
pub async fn record_rejected(client: &mut Client, run_id: i64, source_slug: &str, uri: &str) -> Result<()> {
    let tx = client.transaction().await?;
    let source = source_by_slug(&tx, source_slug).await?;
    tx.execute("DELETE FROM documents WHERE source_id = $1 AND uri = $2", &[&source.id, &uri]).await?;
    forget_outcome(&tx, source.id, uri).await?;
    mark_seen(&tx, run_id, uri).await?;
    tx.commit().await?;
    Ok(())
}

/// An unchanged document's metadata is refreshed (`refresh_metadata`); empty values leave a column alone.
///
/// # Errors
///
/// An unknown slug.
#[allow(clippy::too_many_arguments)]
pub async fn refresh_metadata(
    client: &mut Client,
    run_id: i64,
    source_slug: &str,
    uri: &str,
    byte_size: i64,
    mtime: f64,
    source_sha256: &str,
    corpus_class: &str,
    trust_tier: &str,
) -> Result<()> {
    let tx = client.transaction().await?;
    let source = source_by_slug(&tx, source_slug).await?;
    let mtime = (mtime != 0.0).then_some(mtime);
    let sha = (!source_sha256.is_empty()).then(|| hex_bytes(source_sha256));
    let class = (!corpus_class.is_empty()).then(|| corpus_class.to_owned());
    let trust = (!trust_tier.is_empty()).then(|| trust_tier.to_owned());
    tx.execute(
        "UPDATE documents SET byte_size = $3, \
         mtime = COALESCE(to_timestamp($4), mtime), \
         source_sha256 = COALESCE($5, source_sha256), \
         corpus_class = COALESCE(CAST($6::text AS corpus_class), corpus_class), \
         trust_tier = COALESCE(CAST($7::text AS trust_tier), trust_tier) \
         WHERE source_id = $1 AND uri = $2",
        &[&source.id, &uri, &byte_size, &mtime, &sha, &class, &trust],
    )
    .await?;
    mark_seen(&tx, run_id, uri).await?;
    tx.commit().await?;
    Ok(())
}

async fn attach_authors(tx: &Transaction<'_>, doc_id: i64, authors: &[AuthorPayload]) -> Result<()> {
    let mut seen_authors: HashSet<(i64, String)> = HashSet::new();
    for author in authors {
        if author.name.is_empty() {
            continue;
        }
        let author_id = get_or_create_author(tx, &author.name, &author.identities, author.is_self).await?;
        let role = if author.role.is_empty() { "author".to_owned() } else { author.role.clone() };
        if !seen_authors.insert((author_id, role.clone())) {
            continue;
        }
        let confidence = if author.confidence == 0.0 { 1.0_f32 } else { author.confidence };
        let evidence = author.evidence.clone().filter(|e| !e.is_empty());
        tx.execute(
            "INSERT INTO document_authors (document_id, author_id, role, confidence, evidence) \
             VALUES ($1, $2, CAST($3::text AS author_role), $4, $5) \
             ON CONFLICT (document_id, author_id, role) DO NOTHING",
            &[&doc_id, &author_id, &role, &confidence, &evidence],
        )
        .await
        .map_err(|e| {
            if e.to_string().contains("author_role") {
                ServiceError::invalid(format!("unknown author role {role:?}"))
            } else {
                e.into()
            }
        })?;
    }
    Ok(())
}

/// Links an additional source (typically Spotlight) to an existing `'ok'` document owned by another
/// source, merging metadata, backfilling an empty title, and adding newly attributed authors
/// without touching content, chunks, or primary ownership (`link_additional_document`).
///
/// # Errors
///
/// [`ServiceError::NotFound`] if the source slug is unknown or no `'ok'` document exists at
/// `uri` on another source; an invalid author role; or the database server.
#[allow(clippy::too_many_arguments)]
pub async fn link_additional_document(
    client: &mut Client,
    run_id: i64,
    source_slug: &str,
    uri: &str,
    mtime: f64,
    title: Option<&str>,
    meta: &Map<String, Value>,
    authors: &[AuthorPayload],
) -> Result<i64> {
    let tx = client.transaction().await?;
    let source = source_by_slug(&tx, source_slug).await?;
    let row = tx
        .query_opt(
            "SELECT id FROM documents WHERE uri = $1 AND source_id <> $2 AND state = 'ok' ORDER BY id LIMIT 1",
            &[&uri, &source.id],
        )
        .await?
        .ok_or_else(|| ServiceError::not_found(format!("No existing ok document to link at {uri}")))?;
    let doc_id: i64 = row.get(0);
    let mtime_opt = (mtime != 0.0).then_some(mtime);
    let meta_val = Value::Object(meta.clone());
    tx.execute(
        "INSERT INTO document_sources (document_id, source_id, uri, mtime, meta, linked_at) \
         VALUES ($1, $2, $3, to_timestamp($4), $5, now()) \
         ON CONFLICT (document_id, source_id) DO UPDATE SET \
         uri = EXCLUDED.uri, \
         mtime = COALESCE(EXCLUDED.mtime, document_sources.mtime), \
         meta = document_sources.meta || EXCLUDED.meta, \
         linked_at = now()",
        &[&doc_id, &source.id, &uri, &mtime_opt, &meta_val],
    )
    .await?;
    let title_opt = title.map(str::trim).filter(|s| !s.is_empty());
    tx.execute(
        "UPDATE documents SET \
         meta = meta || $2::jsonb, \
         title = CASE WHEN COALESCE(btrim(title), '') = '' THEN NULLIF(btrim($3), '') ELSE title END \
         WHERE id = $1",
        &[&doc_id, &meta_val, &title_opt],
    )
    .await?;
    attach_authors(&tx, doc_id, authors).await?;
    mark_seen(&tx, run_id, uri).await?;
    tx.commit().await?;
    Ok(doc_id)
}

/// Replaces the document, its authors and its chunks (`replace_document`); how many chunks it now
/// has. A chunk whose ord, hash, text and chunker are unchanged keeps its row, so its vectors in
/// every model table survive; it takes the new offsets, heading, direction and sender in place.
/// Fact chunks are always dropped, and the document's `fact_runs` with them.
///
/// # Errors
///
/// An unknown slug, a bad class or tier, or the server.
#[allow(clippy::too_many_lines)]
pub async fn replace_document(
    client: &mut Client,
    run_id: i64,
    source_slug: &str,
    uri: &str,
    payload: &DocumentPayload,
) -> Result<usize> {
    let tx = client.transaction().await?;
    let source = source_by_slug(&tx, source_slug).await?;
    let mtime = (payload.mtime != 0.0).then_some(payload.mtime);
    let raw_hash = (!payload.source_sha256.is_empty()).then(|| hex_bytes(&payload.source_sha256));
    let content_hash = hex_bytes(&payload.content_sha256);
    let class =
        if payload.corpus_class.is_empty() { source.default_class.clone() } else { payload.corpus_class.clone() };
    let trust = if payload.trust_tier.is_empty() { source.default_trust.clone() } else { payload.trust_tier.clone() };
    let title = payload.title.clone().filter(|t| !t.is_empty());
    let lang = payload.lang.clone().filter(|l| !l.is_empty());
    let version = if payload.extractor_version.is_empty() { "1".to_owned() } else { payload.extractor_version.clone() };
    let chunker = payload.chunker.clone().filter(|c| !c.is_empty());
    let content = payload.content.clone().filter(|c| !c.is_empty());
    let mut meta_map = payload.meta.clone();

    // Order-independence: if a non-spotlight source is indexing a URI currently owned by a
    // spotlight source, promote the existing row in place so chunks and embeddings survive and
    // demote the spotlight link into document_sources.
    if source.kind != "spotlight" {
        let owned = tx
            .query_opt("SELECT id FROM documents WHERE source_id = $1 AND uri = $2", &[&source.id, &uri])
            .await?
            .is_some();
        if !owned
            && let Some(sp_row) = tx
                .query_opt(
                    "SELECT d.id, d.source_id, d.mtime, d.meta \
                     FROM documents d \
                     JOIN sources s ON s.id = d.source_id \
                     WHERE d.uri = $1 AND s.kind = 'spotlight' \
                     ORDER BY d.id \
                     LIMIT 1",
                    &[&uri],
                )
                .await?
        {
            let existing_doc_id: i64 = sp_row.get(0);
            let spotlight_source_id: i64 = sp_row.get(1);
            let prior_mtime: Option<DateTime<Utc>> = sp_row.get(2);
            let prior_meta: Value = sp_row.get(3);
            let spotlight_meta = match prior_meta.get("spotlight").cloned() {
                Some(val) => {
                    if !meta_map.contains_key("spotlight") {
                        meta_map.insert("spotlight".to_owned(), val.clone());
                    }
                    json!({ "spotlight": val })
                }
                None => json!({}),
            };
            tx.execute("UPDATE documents SET source_id = $1 WHERE id = $2", &[&source.id, &existing_doc_id]).await?;
            tx.execute(
                "INSERT INTO document_sources (document_id, source_id, uri, mtime, meta, linked_at) \
                 VALUES ($1, $2, $3, $4, $5, now()) \
                 ON CONFLICT (document_id, source_id) DO UPDATE SET \
                 uri = EXCLUDED.uri, \
                 mtime = COALESCE(EXCLUDED.mtime, document_sources.mtime), \
                 meta = document_sources.meta || EXCLUDED.meta, \
                 linked_at = now()",
                &[&existing_doc_id, &spotlight_source_id, &uri, &prior_mtime, &spotlight_meta],
            )
            .await?;
        }
    }

    let meta = Value::Object(meta_map);
    let doc_id: i64 = tx
        .query_one(
            "INSERT INTO documents (source_id, uri, corpus_class, trust_tier, title, mime, lang, byte_size, mtime, \
             source_sha256, content_sha256, extractor, extractor_version, chunker, content, meta, state, error, ingested_at) \
             VALUES ($1, $2, CAST($3::text AS corpus_class), CAST($4::text AS trust_tier), $5, NULL, $6, $7, to_timestamp($8), \
             $9, $10, $11, $12, $13, $14, $15, 'ok', NULL, now()) \
             ON CONFLICT (source_id, uri) DO UPDATE SET corpus_class = EXCLUDED.corpus_class, trust_tier = EXCLUDED.trust_tier, \
             title = EXCLUDED.title, mime = NULL, lang = EXCLUDED.lang, byte_size = EXCLUDED.byte_size, mtime = EXCLUDED.mtime, \
             source_sha256 = EXCLUDED.source_sha256, content_sha256 = EXCLUDED.content_sha256, extractor = EXCLUDED.extractor, \
             extractor_version = EXCLUDED.extractor_version, chunker = EXCLUDED.chunker, content = EXCLUDED.content, \
             meta = EXCLUDED.meta, state = 'ok', error = NULL, ingested_at = now() \
             RETURNING id",
            &[
                &source.id,
                &uri,
                &class,
                &trust,
                &title,
                &lang,
                &payload.byte_size,
                &mtime,
                &raw_hash,
                &content_hash,
                &payload.extractor,
                &version,
                &chunker,
                &content,
                &meta,
            ],
        )
        .await
        .map_err(|e| map_enum_error(e, &class, &trust))?
        .get(0);
    tx.execute("DELETE FROM document_sources WHERE document_id = $1 AND source_id = $2", &[&doc_id, &source.id])
        .await?;
    forget_outcome(&tx, source.id, uri).await?;

    // Authors.
    tx.execute("DELETE FROM document_authors WHERE document_id = $1", &[&doc_id]).await?;
    attach_authors(&tx, doc_id, &payload.authors).await?;

    // Normalized session tables (`025_sessions.sql`), if this document belongs to a session source.
    let session_turn_ids = crate::sessions_store::persist_session_payload(
        &tx,
        source.id,
        doc_id,
        &content_hash,
        payload.session_json.as_deref(),
    )
    .await?;

    // Chunks: keep the unchanged, drop the rest, add the new.
    let doc_chunker = chunker.clone().unwrap_or_else(|| "default".to_owned());
    let wanted: HashMap<i32, (Vec<u8>, String, &str)> = payload
        .chunks
        .iter()
        .map(|c| {
            (
                c.ord,
                (
                    hex_bytes(&c.chunk_sha256),
                    c.chunker.clone().filter(|k| !k.is_empty()).unwrap_or_else(|| doc_chunker.clone()),
                    c.text.as_str(),
                ),
            )
        })
        .collect();
    let rows = tx
        .query("SELECT id, ord, chunk_sha256, chunker, text, fact_id FROM chunks WHERE document_id = $1", &[&doc_id])
        .await?;
    let mut kept: HashMap<i32, i64> = HashMap::new();
    let mut stale: Vec<i64> = Vec::new();
    let mut stale_facts = false;
    for row in &rows {
        let id: i64 = row.get(0);
        let ord: i32 = row.get(1);
        let sha: Vec<u8> = row.get(2);
        let chunker: String = row.get(3);
        let text: String = row.get(4);
        let fact_id: Option<i64> = row.get(5);
        let unchanged = fact_id.is_none()
            && wanted.get(&ord).is_some_and(|(want_sha, want_chunker, want_text)| {
                !want_sha.is_empty() && *want_sha == sha && *want_chunker == chunker && *want_text == text
            });
        if unchanged {
            kept.insert(ord, id);
        } else {
            stale_facts |= fact_id.is_some();
            stale.push(id);
        }
    }
    if !stale.is_empty() {
        tx.execute("DELETE FROM chunks WHERE id = ANY($1)", &[&stale]).await?;
        if stale_facts {
            tx.execute("DELETE FROM fact_runs WHERE document_id = $1", &[&doc_id]).await?;
        }
    }
    let update = tx
        .prepare(
            "UPDATE chunks SET token_count = $2, char_start = $3, char_end = $4, heading_path = $5, \
             direction = $6, sender = $7, session_turn_id = $8 \
             WHERE id = $1",
        )
        .await?;
    let insert = tx
        .prepare(
            "INSERT INTO chunks (document_id, ord, text, token_count, char_start, char_end, heading_path, chunk_sha256, chunker, \
             direction, sender, session_turn_id) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)",
        )
        .await?;
    for c in &payload.chunks {
        let token_count = c.token_count.filter(|n| *n != 0);
        let heading = c.heading_path.clone().filter(|h| !h.is_empty());
        let direction = c.direction.clone().filter(|d| !d.is_empty());
        let sender = c.sender.clone().filter(|s| !s.is_empty());
        let session_turn_id = c.session_turn_external_id.as_deref().and_then(|ext| session_turn_ids.get(ext).copied());
        if let Some(id) = kept.get(&c.ord) {
            tx.execute(
                &update,
                &[id, &token_count, &c.char_start, &c.char_end, &heading, &direction, &sender, &session_turn_id],
            )
            .await?;
            continue;
        }
        let (sha, chunker, _) = &wanted[&c.ord];
        tx.execute(
            &insert,
            &[
                &doc_id,
                &c.ord,
                &c.text,
                &token_count,
                &c.char_start,
                &c.char_end,
                &heading,
                sha,
                chunker,
                &direction,
                &sender,
                &session_turn_id,
            ],
        )
        .await?;
    }
    mark_seen(&tx, run_id, uri).await?;
    tx.commit().await?;
    Ok(payload.chunks.len())
}

fn map_enum_error(error: tokio_postgres::Error, class: &str, trust: &str) -> ServiceError {
    let text = error.to_string();
    if text.contains("corpus_class") {
        ServiceError::invalid(format!("{class:?} is not a valid CorpusClass"))
    } else if text.contains("trust_tier") {
        ServiceError::invalid(format!("{trust:?} is not a valid TrustTier"))
    } else {
        error.into()
    }
}

/// Closes the ingest run with its final counts (`finalize_session`).
///
/// # Errors
///
/// The server.
#[allow(clippy::too_many_arguments)]
pub async fn finalize_session(
    client: &mut Client,
    run_id: i64,
    completed: bool,
    seen: i64,
    indexed: i64,
    skipped: i64,
    failed: i64,
    placeholders: i64,
    materialized: i64,
    materialized_bytes: i64,
    errors: &[String],
) -> Result<()> {
    let error = if errors.is_empty() {
        None
    } else {
        Some(errors.iter().take(5).cloned().collect::<Vec<_>>().join("; ").chars().take(4000).collect::<String>())
    };
    let count = |n: i64| i32::try_from(n).unwrap_or(i32::MAX);
    client
        .execute(
            "UPDATE ingest_runs SET finished_at = now(), completed = $2, seen_count = $3, indexed_count = $4, skipped_count = $5, \
             failed_count = $6, placeholder_count = $7, materialized_count = $8, materialized_bytes = $9, \
             error = COALESCE($10, error) WHERE id = $1",
            &[
                &run_id,
                &completed,
                &count(seen),
                &count(indexed),
                &count(skipped),
                &count(failed),
                &count(placeholders),
                &count(materialized),
                &materialized_bytes,
                &error,
            ],
        )
        .await?;
    Ok(())
}

// ---------------------------------------------------------------------------
// authors
// ---------------------------------------------------------------------------

/// Resolves an author by identity, creating one on first sight (`get_or_create_author`); its id.
pub(crate) async fn get_or_create_author(
    tx: &Transaction<'_>,
    name: &str,
    identities: &[(String, String)],
    is_self: bool,
) -> Result<i64> {
    let pairs: Vec<(&str, &str)> = identities
        .iter()
        .filter(|(kind, value)| !kind.is_empty() && !value.is_empty())
        .map(|(kind, value)| (kind.as_str(), value.as_str()))
        .collect();
    for (kind, value) in &pairs {
        if let Some(row) = tx
            .query_opt("SELECT author_id FROM author_identities WHERE kind = $1 AND value = $2", &[kind, value])
            .await?
        {
            return adopt_name(tx, row.get(0), name).await;
        }
    }
    let name_for_row = if name.is_empty() { "unknown" } else { name };
    let author_id: i64 =
        match tx.query_opt("SELECT id FROM authors WHERE display_name = $1 ORDER BY id LIMIT 1", &[&name]).await? {
            Some(row) => row.get(0),
            None => tx
                .query_one(
                    "INSERT INTO authors (display_name, is_self) VALUES ($1, $2) RETURNING id",
                    &[&name_for_row, &is_self],
                )
                .await?
                .get(0),
        };
    for (kind, value) in &pairs {
        tx.execute(
            "INSERT INTO author_identities (author_id, kind, value) VALUES ($1, $2, $3) ON CONFLICT (kind, value) DO NOTHING",
            &[&author_id, kind, value],
        )
        .await?;
    }
    Ok(author_id)
}

/// Gives an author known only by a handle the real name it now arrives with (`_adopt_name`); when
/// another author already has that name, the handle's row is merged into it. The author to use.
async fn adopt_name(tx: &Transaction<'_>, author_id: i64, name: &str) -> Result<i64> {
    let row = tx.query_one("SELECT display_name, is_self FROM authors WHERE id = $1", &[&author_id]).await?;
    let display_name: String = row.get(0);
    let is_self: bool = row.get(1);
    if name.is_empty() || is_self || name == display_name {
        return Ok(author_id);
    }
    let handles: Vec<String> = tx
        .query("SELECT value FROM author_identities WHERE author_id = $1", &[&author_id])
        .await?
        .iter()
        .map(|row| row.get(0))
        .collect();
    if !handles.contains(&display_name) || handles.iter().any(|h| h == name) {
        return Ok(author_id);
    }
    let named = tx
        .query_opt(
            "SELECT id FROM authors WHERE display_name = $1 AND id <> $2 AND NOT is_self ORDER BY id LIMIT 1",
            &[&name, &author_id],
        )
        .await?;
    let Some(named) = named else {
        tx.execute("UPDATE authors SET display_name = $2 WHERE id = $1", &[&author_id, &name]).await?;
        return Ok(author_id);
    };
    let named_id: i64 = named.get(0);
    tx.execute(
        "INSERT INTO document_authors (document_id, author_id, role, confidence, evidence) \
         SELECT document_id, $2, role, confidence, evidence FROM document_authors WHERE author_id = $1 \
         ON CONFLICT (document_id, author_id, role) DO NOTHING",
        &[&author_id, &named_id],
    )
    .await?;
    tx.execute("DELETE FROM document_authors WHERE author_id = $1", &[&author_id]).await?;
    tx.execute("UPDATE author_identities SET author_id = $2 WHERE author_id = $1", &[&author_id, &named_id]).await?;
    tx.execute("DELETE FROM authors WHERE id = $1", &[&author_id]).await?;
    Ok(named_id)
}

/// Creates or updates the row representing the corpus owner (`ensure_self_author`); its id, or
/// none when `identity.name` is not set.
async fn ensure_self_author(tx: &Transaction<'_>, config: &Config) -> Result<Option<i64>> {
    let name = config.self_name();
    if name.is_empty() {
        return Ok(None);
    }
    let pairs = config.self_identity_pairs();
    let existing = tx.query_opt("SELECT id FROM authors WHERE is_self", &[]).await?;
    let author_id: i64 = match existing {
        Some(row) => row.get(0),
        None => tx
            .query_one("INSERT INTO authors (display_name, is_self) VALUES ($1, true) RETURNING id", &[&name])
            .await?
            .get(0),
    };
    for (kind, value) in &pairs {
        tx.execute(
            "INSERT INTO author_identities (author_id, kind, value) VALUES ($1, $2, $3) ON CONFLICT (kind, value) DO NOTHING",
            &[&author_id, kind, value],
        )
        .await?;
    }
    Ok(Some(author_id))
}

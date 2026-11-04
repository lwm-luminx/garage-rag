//! `GarageService` itself: each RPC a thin translation between its messages and the functions of
//! this crate, as the Python servicer was over `garage_rag.ops`. The RPCs later stages port answer
//! `UNIMPLEMENTED` with a pointer to the plan.

use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use deadpool_postgres::Pool;
use garage_facade::proto;
use garage_facade::proto::garage_service_server::GarageService as GarageServiceTrait;
use garage_mcp::pyjson;
use serde_json::{Map, Value};
use tokio_stream::Stream;
use tonic::{Request, Response, Status};

use crate::config::Config;
use crate::db::{Client, isoformat_opt};
use crate::embedding::{backfill_distilled, count_pending, pending_chunks, store_vectors};
use crate::error::{Result, ServiceError};
use crate::gateway::{self, AuthorPayload, ChunkPayload, DocumentPayload};
use crate::migrate::{apply_migrations, pending_migrations};
use crate::models::{count_vectors, get_model, list_models};
use crate::search::{QueryEmbedder, SearchFilters, search, snippet};
use crate::{corpus, db};

/// What `GetVersion` reports: the Python package's version, since the app shows it as the
/// backend's and nothing about the contract changed.
pub const VERSION: &str = "1.5.0";

/// The largest message the server accepts (`MAX_REQUEST_BYTES`): `PersistDocument` carries a whole
/// document's text and chunks.
pub const MAX_REQUEST_BYTES: usize = 256 * 1024 * 1024;

/// `json.dumps(..., ensure_ascii=False)`, as the Corpus* results were written.
const CORPUS_JSON: pyjson::Style = pyjson::Style { compact: false, ensure_ascii: false };

/// The service: a pool on the database `garage.json` names, the configuration, and the process's
/// query embedder.
pub struct GarageService {
    pool: Pool,
    config: Config,
    embedder: Arc<dyn QueryEmbedder>,
    sql_dir: PathBuf,
    /// Whether every caller is one the server can vouch for (the token, or the Unix socket), so
    /// the config-changing methods may be answered (`callers_vouched_for`).
    callers_vouched_for: bool,
}

impl GarageService {
    /// # Errors
    ///
    /// A database URL that does not parse.
    pub fn new(
        config: Config,
        embedder: Arc<dyn QueryEmbedder>,
        sql_dir: PathBuf,
        callers_vouched_for: bool,
    ) -> Result<Self> {
        let pool = db::pool_for(&config.database_url())?;
        Ok(Self { pool, config, embedder, sql_dir, callers_vouched_for })
    }

    pub fn config(&self) -> &Config {
        &self.config
    }

    async fn client(&self) -> Result<Client> {
        Ok(self.pool.get().await?)
    }

    fn config_change(&self, method: &str) -> std::result::Result<(), Status> {
        if self.callers_vouched_for {
            Ok(())
        } else {
            Err(Status::permission_denied(format!(
                "{method} changes configuration; it needs the {} token or the Unix socket",
                crate::auth::METADATA_KEY
            )))
        }
    }

    fn default_model(&self) -> String {
        self.config.default_embedding_model()
    }
}

fn opt(text: &str) -> Option<String> {
    (!text.is_empty()).then(|| text.to_owned())
}

fn json_object(text: &str) -> Result<Map<String, Value>> {
    if text.is_empty() {
        return Ok(Map::new());
    }
    match serde_json::from_str(text)? {
        Value::Object(map) => Ok(map),
        _ => Err(ServiceError::invalid("expected a JSON object")),
    }
}

fn json_text(value: &Map<String, Value>) -> String {
    if value.is_empty() { String::new() } else { pyjson::dumps(&Value::Object(value.clone()), pyjson::DEFAULT) }
}

#[allow(clippy::unnecessary_wraps)] // every handler returns it
fn ok<T>(value: T) -> std::result::Result<Response<T>, Status> {
    Ok(Response::new(value))
}

type StatusStream<T> = Pin<Box<dyn Stream<Item = std::result::Result<T, Status>> + Send + 'static>>;

fn unimplemented<T>(name: &str) -> std::result::Result<Response<T>, Status> {
    Err(Status::unimplemented(format!(
        "{name} is not ported to the Rust GarageService yet (docs/plans/python-removal.md)"
    )))
}

#[tonic::async_trait]
#[allow(clippy::too_many_lines)] // one method per RPC
impl GarageServiceTrait for GarageService {
    type ScanStream = StatusStream<proto::ScanStatus>;
    type BackfillStream = StatusStream<proto::BackfillStatus>;
    type EnrichFactsStream = StatusStream<proto::EnrichFactsStatus>;
    type ClusterFactsStream = StatusStream<proto::ClusterFactsStatus>;

    // -- system -----------------------------------------------------------------------------

    async fn ping(
        &self,
        request: Request<proto::PingRequest>,
    ) -> std::result::Result<Response<proto::PingResponse>, Status> {
        let message = request.into_inner().message;
        let timestamp =
            SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| i64::try_from(d.as_secs()).unwrap_or(0));
        ok(proto::PingResponse { message: if message.is_empty() { "pong".into() } else { message }, timestamp })
    }

    async fn get_status(
        &self,
        _request: Request<proto::StatusRequest>,
    ) -> std::result::Result<Response<proto::StatusResponse>, Status> {
        let (db_status, is_ready) = match self.client().await {
            Ok(client) => match client.simple_query("SELECT 1").await {
                Ok(_) => match pending_migrations(&client, &self.sql_dir).await {
                    Ok(pending) if pending.is_empty() => ("connected".to_owned(), true),
                    Ok(_) => ("needs_migration".to_owned(), false),
                    Err(e) => (format!("error: {e}"), false),
                },
                Err(e) => (format!("error: {e}"), false),
            },
            Err(e) => (format!("error: {e}"), false),
        };
        ok(proto::StatusResponse {
            version: VERSION.into(),
            is_ready,
            pid: i32::try_from(std::process::id()).unwrap_or(0),
            db_status,
            server_type: "grpc".into(),
        })
    }

    async fn get_version(
        &self,
        _request: Request<proto::VersionRequest>,
    ) -> std::result::Result<Response<proto::VersionResponse>, Status> {
        ok(proto::VersionResponse { version: VERSION.into() })
    }

    // -- search -----------------------------------------------------------------------------

    async fn search(
        &self,
        request: Request<proto::SearchRequest>,
    ) -> std::result::Result<Response<proto::SearchResponse>, Status> {
        let r = request.into_inner();
        let mut client = self.client().await?;
        let filters = SearchFilters {
            corpus_classes: r.corpus_classes,
            trust_tiers: r.trust_tiers,
            sources: r.sources,
            author: opt(&r.author),
            direction: opt(&r.direction),
        };
        let mode = if r.mode.is_empty() { "hybrid" } else { r.mode.as_str() };
        let limit = if r.limit == 0 { 10 } else { i64::from(r.limit) };
        let hits = search(
            &mut client,
            self.embedder.clone(),
            &r.query,
            limit,
            mode,
            opt(&r.model).as_deref(),
            &self.default_model(),
            self.config.hnsw_ef_search(),
            &filters,
            600,
        )
        .await?;
        let proto_hits: Vec<proto::SearchHit> = hits
            .iter()
            .enumerate()
            .map(|(i, hit)| proto::SearchHit {
                rank: i32::try_from(i + 1).unwrap_or(i32::MAX),
                title: hit.title.clone().filter(|t| !t.is_empty()).unwrap_or_else(|| "(untitled)".into()),
                uri: hit.uri.clone(),
                corpus_class: hit.corpus_class.clone(),
                trust_tier: hit.trust_tier.clone(),
                matched_by: hit.matched_by().into(),
                #[allow(clippy::cast_possible_truncation)] // the proto's float
                score: hit.score as f32,
                heading_path: hit.heading_path.clone().unwrap_or_default(),
                authors: hit.authors.clone(),
                text: hit.text.clone(),
                snippet: if r.full { hit.text.clone() } else { snippet(&hit.text) },
                direction: hit.direction.clone().unwrap_or_default(),
                sender: hit.sender.clone().unwrap_or_default(),
            })
            .collect();
        let total = i32::try_from(proto_hits.len()).unwrap_or(i32::MAX);
        ok(proto::SearchResponse {
            formatted_output: format!("Found {} results for {}", proto_hits.len(), pyrepr_str(&r.query)),
            hits: proto_hits,
            total_hits: total,
        })
    }

    // -- documents --------------------------------------------------------------------------

    async fn list_documents(
        &self,
        request: Request<proto::ListDocumentsRequest>,
    ) -> std::result::Result<Response<proto::ListDocumentsResponse>, Status> {
        let r = request.into_inner();
        let client = self.client().await?;
        let mut params: Vec<Box<dyn tokio_postgres::types::ToSql + Sync + Send>> = Vec::new();
        let mut filters: Vec<String> = Vec::new();
        if !r.source.is_empty() {
            params.push(Box::new(r.source.clone()));
            filters.push(format!("s.slug = ${}", params.len()));
        }
        if !r.corpus_class.is_empty() {
            params.push(Box::new(r.corpus_class.clone()));
            filters.push(format!("d.corpus_class::text = ${}", params.len()));
        }
        if !r.trust_tier.is_empty() {
            params.push(Box::new(r.trust_tier.clone()));
            filters.push(format!("d.trust_tier::text = ${}", params.len()));
        }
        if !r.query.is_empty() {
            params.push(Box::new(format!("%{}%", r.query)));
            filters.push(format!("(d.title ILIKE ${0} OR d.uri ILIKE ${0})", params.len()));
        }
        let where_clause = if filters.is_empty() { String::new() } else { format!("WHERE {}", filters.join(" AND ")) };
        let total: i64 = client
            .query_one(
                &format!("SELECT count(*) FROM documents d JOIN sources s ON s.id = d.source_id {where_clause}"),
                &refs(&params),
            )
            .await
            .map_err(ServiceError::from)?
            .get(0);
        let limit = i64::from(if r.limit == 0 { 100 } else { r.limit });
        let offset = i64::from(r.offset.max(0));
        params.push(Box::new(limit));
        params.push(Box::new(offset));
        let rows = client
            .query(
                &format!(
                    "SELECT d.id, d.uri, d.title, s.slug, d.corpus_class::text, d.trust_tier::text, d.mime, d.lang, d.byte_size, \
                     (SELECT count(*) FROM chunks c WHERE c.document_id = d.id)::int AS chunk_count, d.state::text, d.ingested_at, \
                     (SELECT count(*) FROM facts f WHERE f.document_id = d.id)::int AS fact_count \
                     FROM documents d JOIN sources s ON s.id = d.source_id {where_clause} \
                     ORDER BY d.ingested_at DESC, d.id DESC LIMIT ${} OFFSET ${}",
                    params.len() - 1,
                    params.len()
                ),
                &refs(&params),
            )
            .await
            .map_err(ServiceError::from)?;
        let documents: Vec<proto::DocumentSummary> = rows
            .iter()
            .map(|row| proto::DocumentSummary {
                id: row.get(0),
                uri: row.get(1),
                title: row.get::<_, Option<String>>(2).unwrap_or_default(),
                source_slug: row.get(3),
                corpus_class: row.get(4),
                trust_tier: row.get(5),
                mime: row.get::<_, Option<String>>(6).unwrap_or_default(),
                lang: row.get::<_, Option<String>>(7).unwrap_or_default(),
                byte_size: row.get::<_, Option<i64>>(8).unwrap_or(0),
                chunk_count: row.get(9),
                state: row.get(10),
                ingested_at: isoformat_opt(row.get(11)),
                fact_count: row.get(12),
            })
            .collect();
        ok(proto::ListDocumentsResponse {
            formatted_output: format!("{} of {total} documents", documents.len()),
            documents,
            total_count: total,
        })
    }

    async fn get_document(
        &self,
        request: Request<proto::GetDocumentRequest>,
    ) -> std::result::Result<Response<proto::GetDocumentResponse>, Status> {
        let id = request.into_inner().document_id;
        let client = self.client().await?;
        let row = client
            .query_opt(
                "SELECT d.id, d.uri, d.title, s.slug, d.corpus_class::text, d.trust_tier::text, d.mime, d.lang, d.byte_size, \
                 d.extractor, d.extractor_version, d.chunker, d.meta, d.state::text, d.error, d.ingested_at \
                 FROM documents d LEFT JOIN sources s ON s.id = d.source_id WHERE d.id = $1",
                &[&id],
            )
            .await
            .map_err(ServiceError::from)?
            .ok_or_else(|| Status::not_found(format!("document {id} not found")))?;
        let authors = client
            .query(
                "SELECT a.display_name, da.role::text, da.confidence FROM document_authors da JOIN authors a ON a.id = da.author_id \
                 WHERE da.document_id = $1 ORDER BY a.id, da.role",
                &[&id],
            )
            .await
            .map_err(ServiceError::from)?
            .iter()
            .map(|a| proto::DocumentAuthorInfo { name: a.get(0), role: a.get(1), confidence: a.get(2) })
            .collect();
        let chunks: Vec<proto::DocumentChunkInfo> = client
            .query(
                "SELECT id, ord, text, token_count, char_start, char_end, heading_path FROM chunks WHERE document_id = $1 ORDER BY ord",
                &[&id],
            )
            .await
            .map_err(ServiceError::from)?
            .iter()
            .map(|c| proto::DocumentChunkInfo {
                id: c.get(0),
                ord: c.get(1),
                text: c.get(2),
                token_count: c.get::<_, Option<i32>>(3).unwrap_or(0),
                char_start: c.get(4),
                char_end: c.get(5),
                heading_path: c.get::<_, Option<String>>(6).unwrap_or_default(),
            })
            .collect();
        let facts: Vec<proto::DocumentFactInfo> = client
            .query(
                "SELECT id, ord, fact, fact_class, attributes, char_start, char_end, extractor FROM facts WHERE document_id = $1 ORDER BY ord",
                &[&id],
            )
            .await
            .map_err(ServiceError::from)?
            .iter()
            .map(|f| proto::DocumentFactInfo {
                id: f.get(0),
                ord: f.get(1),
                fact: f.get(2),
                fact_class: f.get::<_, Option<String>>(3).unwrap_or_default(),
                attributes_json: match f.get::<_, Value>(4) {
                    Value::Object(map) => json_text(&map),
                    _ => String::new(),
                },
                char_start: f.get(5),
                char_end: f.get(6),
                extractor: f.get::<_, Option<String>>(7).unwrap_or_default(),
            })
            .collect();
        let meta_json = match row.get::<_, Value>(12) {
            Value::Object(map) => json_text(&map),
            _ => String::new(),
        };
        let detail = proto::DocumentDetail {
            id: row.get(0),
            uri: row.get(1),
            title: row.get::<_, Option<String>>(2).unwrap_or_default(),
            source_slug: row.get::<_, Option<String>>(3).unwrap_or_default(),
            corpus_class: row.get(4),
            trust_tier: row.get(5),
            mime: row.get::<_, Option<String>>(6).unwrap_or_default(),
            lang: row.get::<_, Option<String>>(7).unwrap_or_default(),
            byte_size: row.get::<_, Option<i64>>(8).unwrap_or(0),
            extractor: row.get::<_, Option<String>>(9).unwrap_or_default(),
            extractor_version: row.get::<_, Option<String>>(10).unwrap_or_default(),
            chunker: row.get::<_, Option<String>>(11).unwrap_or_default(),
            meta_json,
            state: row.get(13),
            error: row.get::<_, Option<String>>(14).unwrap_or_default(),
            ingested_at: isoformat_opt(row.get(15)),
            authors,
        };
        let shown = if detail.title.is_empty() { detail.uri.clone() } else { detail.title.clone() };
        ok(proto::GetDocumentResponse {
            formatted_output: format!("{shown}: {} chunks, {} facts", chunks.len(), facts.len()),
            document: Some(detail),
            chunks,
            facts,
        })
    }

    async fn list_facts(
        &self,
        _r: Request<proto::ListFactsRequest>,
    ) -> std::result::Result<Response<proto::ListFactsResponse>, Status> {
        unimplemented("ListFacts")
    }

    async fn get_fact_stats(
        &self,
        _r: Request<proto::FactStatsRequest>,
    ) -> std::result::Result<Response<proto::FactStatsResponse>, Status> {
        unimplemented("GetFactStats")
    }

    // -- sources, models, stats -------------------------------------------------------------

    async fn list_sources(
        &self,
        _request: Request<proto::ListSourcesRequest>,
    ) -> std::result::Result<Response<proto::ListSourcesResponse>, Status> {
        let client = self.client().await?;
        let rows = client
            .query(
                "SELECT s.slug, s.kind, s.default_class::text, s.default_trust::text, s.enabled, s.root, \
                 (SELECT count(*) FROM documents d WHERE d.source_id = s.id), s.expected_elements \
                 FROM sources s ORDER BY s.id",
                &[],
            )
            .await
            .map_err(ServiceError::from)?;
        let sources: Vec<proto::SourceInfo> = rows
            .iter()
            .map(|s| proto::SourceInfo {
                slug: s.get(0),
                kind: s.get(1),
                corpus_class: s.get(2),
                trust_tier: s.get(3),
                enabled: s.get(4),
                root: s.get(5),
                document_count: s.get(6),
                expected_elements: s.get(7),
            })
            .collect();
        ok(proto::ListSourcesResponse { formatted_output: format!("{} sources registered", sources.len()), sources })
    }

    async fn list_models(
        &self,
        _request: Request<proto::ListModelsRequest>,
    ) -> std::result::Result<Response<proto::ListModelsResponse>, Status> {
        let client = self.client().await?;
        let models: Vec<proto::ModelInfo> = list_models(&client)
            .await?
            .into_iter()
            .map(|m| proto::ModelInfo {
                slug: m.slug,
                provider: m.provider,
                model_ref: m.model_ref,
                dims: m.dims,
                stored_dims: m.stored_dims,
                storage_kind: m.storage_kind,
                index_kind: m.index_kind,
                table_name: m.table_name,
                is_default: m.is_default,
                model_id: m.model_id.unwrap_or_default(),
                distance: m.distance,
                modality: if m.modality.is_empty() { "text".into() } else { m.modality },
            })
            .collect();
        ok(proto::ListModelsResponse { formatted_output: format!("{} models registered", models.len()), models })
    }

    async fn get_stats(
        &self,
        _request: Request<proto::StatsRequest>,
    ) -> std::result::Result<Response<proto::StatsResponse>, Status> {
        let client = self.client().await?;
        let count = |sql: &'static str| {
            let client = &client;
            async move { client.query_one(sql, &[]).await.map(|row| row.get::<_, i64>(0)).map_err(ServiceError::from) }
        };
        let documents = count("SELECT count(*) FROM documents").await?;
        let chunks = count("SELECT count(*) FROM chunks").await?;
        let sources = count("SELECT count(*) FROM sources").await?;
        let documents_by_source = client
            .query(
                "SELECT s.slug, count(d.id) FROM sources s LEFT JOIN documents d ON d.source_id = s.id GROUP BY s.slug",
                &[],
            )
            .await
            .map_err(ServiceError::from)?
            .iter()
            .map(|row| (row.get::<_, String>(0), row.get::<_, i64>(1)))
            .collect();
        let models = list_models(&client).await?;
        let mut chunks_by_model = std::collections::HashMap::new();
        for model in &models {
            chunks_by_model.insert(model.slug.clone(), count_vectors(&client, &model.table_name).await?);
        }
        ok(proto::StatsResponse {
            documents,
            chunks,
            sources,
            models: i64::try_from(models.len()).unwrap_or(0),
            chunks_by_model,
            documents_by_source,
            formatted_output: format!(
                "Corpus: {} documents, {} chunks across {sources} sources, {} embedding models",
                thousands(documents),
                thousands(chunks),
                models.len()
            ),
        })
    }

    // -- corpus reads for the MCP server ----------------------------------------------------

    async fn corpus_search(
        &self,
        request: Request<proto::CorpusSearchRequest>,
    ) -> std::result::Result<Response<proto::CorpusReadResponse>, Status> {
        let r = request.into_inner();
        let mut client = self.client().await?;
        let filters = SearchFilters {
            corpus_classes: r.corpus_classes,
            trust_tiers: r.trust_tiers,
            sources: r.sources,
            author: r.author,
            direction: r.direction,
        };
        let mode = if r.mode.is_empty() { "hybrid".to_owned() } else { r.mode };
        let limit = if r.limit == 0 { 10 } else { i64::from(r.limit) };
        let result = corpus::rag_search(
            &mut client,
            self.embedder.clone(),
            &r.query,
            limit,
            &mode,
            &self.default_model(),
            self.config.hnsw_ef_search(),
            &filters,
        )
        .await?;
        ok(proto::CorpusReadResponse { result_json: pyjson::dumps(&result, CORPUS_JSON) })
    }

    async fn corpus_document(
        &self,
        request: Request<proto::CorpusDocumentRequest>,
    ) -> std::result::Result<Response<proto::CorpusReadResponse>, Status> {
        let r = request.into_inner();
        let client = self.client().await?;
        let max_chars = if r.max_chars == 0 { 20_000 } else { usize::try_from(r.max_chars).unwrap_or(20_000) };
        let result = corpus::rag_get_document(&client, r.document_id, opt(&r.location).as_deref(), max_chars).await?;
        ok(proto::CorpusReadResponse { result_json: pyjson::dumps(&result, CORPUS_JSON) })
    }

    async fn corpus_sources(
        &self,
        _request: Request<proto::CorpusSourcesRequest>,
    ) -> std::result::Result<Response<proto::CorpusReadResponse>, Status> {
        let client = self.client().await?;
        let result = corpus::rag_list_sources(&client).await?;
        ok(proto::CorpusReadResponse { result_json: pyjson::dumps(&result, CORPUS_JSON) })
    }

    async fn corpus_authors(
        &self,
        request: Request<proto::CorpusAuthorsRequest>,
    ) -> std::result::Result<Response<proto::CorpusReadResponse>, Status> {
        let limit = request.into_inner().limit;
        let client = self.client().await?;
        let result = corpus::rag_list_authors(&client, if limit == 0 { 30 } else { i64::from(limit) }).await?;
        ok(proto::CorpusReadResponse { result_json: pyjson::dumps(&result, CORPUS_JSON) })
    }

    async fn corpus_stats(
        &self,
        _request: Request<proto::CorpusStatsRequest>,
    ) -> std::result::Result<Response<proto::CorpusReadResponse>, Status> {
        let client = self.client().await?;
        let result = corpus::rag_stats(&client).await?;
        ok(proto::CorpusReadResponse { result_json: pyjson::dumps(&result, CORPUS_JSON) })
    }

    // -- schema and settings ----------------------------------------------------------------

    async fn init_db(
        &self,
        request: Request<proto::InitDbRequest>,
    ) -> std::result::Result<Response<proto::InitDbResponse>, Status> {
        self.config_change("InitDb")?;
        let schema_dir = request.into_inner().schema_dir;
        let dir = if schema_dir.is_empty() { self.sql_dir.clone() } else { PathBuf::from(schema_dir) };
        let client = self.client().await?;
        let applied = apply_migrations(&client, &dir).await?;
        let mut lines: Vec<String> = applied.iter().map(|name| format!("applied {name}")).collect();
        lines.push(format!("schema ready ({})", db::redact_url(&self.config.database_url())));
        ok(proto::InitDbResponse { applied, message: lines.join("\n") })
    }

    async fn get_setting(
        &self,
        request: Request<proto::GetSettingRequest>,
    ) -> std::result::Result<Response<proto::GetSettingResponse>, Status> {
        let name = request.into_inner().name;
        let value = self.config.setting(&name)?;
        ok(proto::GetSettingResponse { name, value_json: pyjson::dumps(&value, pyjson::DEFAULT) })
    }

    // -- the ingest facade ------------------------------------------------------------------

    async fn begin_ingest_session(
        &self,
        request: Request<proto::BeginIngestSessionRequest>,
    ) -> std::result::Result<Response<proto::BeginIngestSessionResponse>, Status> {
        let r = request.into_inner();
        let mut client = self.client().await?;
        let ctx = gateway::begin_session(&mut client, &self.config, &r.source_slug).await?;
        ok(proto::BeginIngestSessionResponse {
            source_id: ctx.source_id,
            slug: ctx.slug,
            root: ctx.root,
            default_class: ctx.default_class,
            default_trust: ctx.default_trust,
            run_id: ctx.run_id,
            source_slugs: ctx.source_slugs,
            kind: ctx.kind,
        })
    }

    async fn persist_scan(
        &self,
        request: Request<proto::PersistScanRequest>,
    ) -> std::result::Result<Response<proto::PersistScanResponse>, Status> {
        let r = request.into_inner();
        let mut client = self.client().await?;
        let details: Value = if r.details_json.is_empty() {
            Value::Object(Map::new())
        } else {
            serde_json::from_str(&r.details_json).map_err(ServiceError::from)?
        };
        gateway::persist_scan(&mut client, &r.source_slug, r.item_count, &r.item_type, &details).await?;
        ok(proto::PersistScanResponse { success: true })
    }

    async fn check_document_stat(
        &self,
        request: Request<proto::CheckDocumentStatRequest>,
    ) -> std::result::Result<Response<proto::CheckDocumentStatResponse>, Status> {
        let r = request.into_inner();
        let mut client = self.client().await?;
        let stat =
            gateway::check_stat(&mut client, &r.source_slug, &r.uri, opt(&r.extractor_revision).as_deref()).await?;
        ok(proto::CheckDocumentStatResponse {
            exists: stat.exists,
            byte_size: stat.byte_size,
            mtime: stat.mtime,
            content_sha256: stat.content_sha256,
            chunker: stat.chunker,
            state: stat.state,
            source_sha256: stat.source_sha256,
        })
    }

    async fn persist_document(
        &self,
        request: Request<proto::PersistDocumentRequest>,
    ) -> std::result::Result<Response<proto::PersistDocumentResponse>, Status> {
        let r = request.into_inner();
        let mut client = self.client().await?;
        let revision = opt(&r.extractor_revision);
        let (run_id, slug, uri) = (r.run_id, r.source_slug.as_str(), r.uri.as_str());
        let mut chunks_written = 0usize;
        match r.action.as_str() {
            "placeholder" => gateway::record_placeholder(&mut client, run_id, slug, uri).await?,
            "extract_failed" => {
                let error = if r.error.is_empty() { "extraction failed" } else { r.error.as_str() };
                gateway::record_extract_failed(
                    &mut client,
                    run_id,
                    slug,
                    uri,
                    error,
                    r.byte_size,
                    r.mtime,
                    &r.source_sha256,
                    revision.as_deref(),
                )
                .await?;
            }
            "no_text" => {
                gateway::record_no_text(
                    &mut client,
                    run_id,
                    slug,
                    uri,
                    r.byte_size,
                    r.mtime,
                    &r.source_sha256,
                    revision.as_deref(),
                )
                .await?;
            }
            "rejected" => gateway::record_rejected(&mut client, run_id, slug, uri).await?,
            "seen" => gateway::record_seen(&mut client, run_id, uri).await?,
            "refresh_metadata" => {
                gateway::refresh_metadata(
                    &mut client,
                    run_id,
                    slug,
                    uri,
                    r.byte_size,
                    r.mtime,
                    &r.source_sha256,
                    &r.corpus_class,
                    &r.trust_tier,
                )
                .await?;
            }
            "replace" => {
                let payload = DocumentPayload {
                    title: opt(&r.title),
                    lang: opt(&r.lang),
                    byte_size: r.byte_size,
                    mtime: r.mtime,
                    source_sha256: r.source_sha256.clone(),
                    content_sha256: r.content_sha256.clone(),
                    extractor: r.extractor.clone(),
                    extractor_version: if r.extractor_version.is_empty() {
                        "1".into()
                    } else {
                        r.extractor_version.clone()
                    },
                    chunker: opt(&r.chunker),
                    content: opt(&r.content),
                    meta: json_object(&r.meta_json)?,
                    corpus_class: r.corpus_class.clone(),
                    trust_tier: r.trust_tier.clone(),
                    authors: r
                        .authors
                        .iter()
                        .map(|a| AuthorPayload {
                            name: a.name.clone(),
                            role: if a.role.is_empty() { "author".into() } else { a.role.clone() },
                            confidence: if a.confidence == 0.0 { 1.0 } else { a.confidence },
                            evidence: opt(&a.evidence),
                            identities: a.identities.iter().map(|(k, v)| (k.clone(), v.clone())).collect(),
                            is_self: a.is_self,
                        })
                        .collect(),
                    chunks: r
                        .chunks
                        .iter()
                        .map(|c| ChunkPayload {
                            ord: c.ord,
                            text: c.text.clone(),
                            token_count: (c.token_count != 0).then_some(c.token_count),
                            char_start: c.char_start,
                            char_end: c.char_end,
                            heading_path: opt(&c.heading_path),
                            chunk_sha256: c.chunk_sha256.clone(),
                            chunker: opt(&c.chunker),
                            direction: opt(&c.direction),
                            sender: opt(&c.sender),
                        })
                        .collect(),
                };
                chunks_written = gateway::replace_document(&mut client, run_id, slug, uri, &payload).await?;
            }
            other => {
                return Err(Status::invalid_argument(format!("unknown PersistDocument action {}", pyrepr_str(other))));
            }
        }
        ok(proto::PersistDocumentResponse {
            success: true,
            chunks_written: i32::try_from(chunks_written).unwrap_or(i32::MAX),
            error: String::new(),
        })
    }

    async fn finalize_ingest_session(
        &self,
        request: Request<proto::FinalizeIngestSessionRequest>,
    ) -> std::result::Result<Response<proto::FinalizeIngestSessionResponse>, Status> {
        let r = request.into_inner();
        let mut client = self.client().await?;
        gateway::finalize_session(
            &mut client,
            r.run_id,
            r.completed,
            r.seen_count,
            r.indexed_count,
            r.skipped_count,
            r.failed_count,
            r.placeholder_count,
            r.materialized_count,
            r.materialized_bytes,
            &r.errors,
        )
        .await?;
        ok(proto::FinalizeIngestSessionResponse { success: true })
    }

    // -- the embed facade -------------------------------------------------------------------

    async fn get_embedding_batches(
        &self,
        request: Request<proto::GetEmbeddingBatchesRequest>,
    ) -> std::result::Result<Response<proto::GetEmbeddingBatchesResponse>, Status> {
        let r = request.into_inner();
        let client = self.client().await?;
        let model = get_model(&client, opt(&r.model_slug).as_deref(), &self.default_model()).await?;
        // The worker posts these texts to the model's provider: an off-box one never gets
        // communication chunks.
        let local = garage_embed::provider::provider_is_local(&model.provider, &self.config.embed_settings());
        let pending_total = count_pending(&client, &model, local).await?;
        let withheld = if local { 0 } else { count_pending(&client, &model, true).await? - pending_total };
        let mut fetch_limit = if r.batch_size > 0 { i64::from(r.batch_size) } else { 64 };
        if r.limit > 0 && i64::from(r.limit) < fetch_limit {
            fetch_limit = i64::from(r.limit);
        }
        let chunks: Vec<proto::EmbeddingChunkItem> = pending_chunks(&client, &model, local, fetch_limit)
            .await?
            .into_iter()
            .map(|(chunk_id, text)| proto::EmbeddingChunkItem { chunk_id, text })
            .collect();
        let has_more = pending_total - i64::try_from(chunks.len()).unwrap_or(0) > 0;
        ok(proto::GetEmbeddingBatchesResponse {
            model_slug: model.slug.clone(),
            table_name: model.table_name.clone(),
            provider: model.provider.clone(),
            model_ref: model.model_ref.clone(),
            dims: model.dims,
            stored_dims: model.stored_dims,
            storage_kind: model.storage_kind.clone(),
            index_kind: model.index_kind.clone(),
            total_pending: pending_total,
            chunks,
            has_more,
            modality: model.modality().to_owned(),
            withheld,
        })
    }

    async fn update_embeddings(
        &self,
        request: Request<proto::UpdateEmbeddingsRequest>,
    ) -> std::result::Result<Response<proto::UpdateEmbeddingsResponse>, Status> {
        let r = request.into_inner();
        let mut client = self.client().await?;
        let model = get_model(&client, opt(&r.model_slug).as_deref(), &self.default_model()).await?;
        if r.embeddings.is_empty() {
            return ok(proto::UpdateEmbeddingsResponse { success: true, count: 0, error: String::new() });
        }
        let vectors: Vec<(i64, Vec<f32>)> = r.embeddings.into_iter().map(|item| (item.chunk_id, item.vector)).collect();
        let count = store_vectors(&mut client, &model, &vectors, true).await?;
        ok(proto::UpdateEmbeddingsResponse {
            success: true,
            count: i32::try_from(count).unwrap_or(i32::MAX),
            error: String::new(),
        })
    }

    async fn backfill_distilled(
        &self,
        request: Request<proto::BackfillDistilledRequest>,
    ) -> std::result::Result<Response<proto::BackfillDistilledResponse>, Status> {
        let r = request.into_inner();
        let client = self.client().await?;
        let model = get_model(&client, opt(&r.model_slug).as_deref(), &self.default_model()).await?;
        let distilled = backfill_distilled(&client, &model).await?;
        ok(proto::BackfillDistilledResponse { distilled })
    }

    // -- later stages -----------------------------------------------------------------------

    async fn add_source(
        &self,
        _r: Request<proto::AddSourceRequest>,
    ) -> std::result::Result<Response<proto::AddSourceResponse>, Status> {
        self.config_change("AddSource")?;
        unimplemented("AddSource")
    }

    async fn remove_source(
        &self,
        _r: Request<proto::RemoveSourceRequest>,
    ) -> std::result::Result<Response<proto::RemoveSourceResponse>, Status> {
        self.config_change("RemoveSource")?;
        unimplemented("RemoveSource")
    }

    async fn scan(&self, _r: Request<proto::ScanRequest>) -> std::result::Result<Response<Self::ScanStream>, Status> {
        unimplemented("Scan")
    }

    async fn sync_sources(
        &self,
        _r: Request<proto::SyncSourcesRequest>,
    ) -> std::result::Result<Response<proto::SyncSourcesResponse>, Status> {
        unimplemented("SyncSources")
    }

    async fn import_sources_to_config(
        &self,
        _r: Request<proto::ImportSourcesToConfigRequest>,
    ) -> std::result::Result<Response<proto::ImportSourcesToConfigResponse>, Status> {
        self.config_change("ImportSourcesToConfig")?;
        unimplemented("ImportSourcesToConfig")
    }

    async fn reconcile(
        &self,
        _r: Request<proto::ReconcileRequest>,
    ) -> std::result::Result<Response<proto::ReconcileResponse>, Status> {
        unimplemented("Reconcile")
    }

    async fn register_model(
        &self,
        _r: Request<proto::RegisterModelRequest>,
    ) -> std::result::Result<Response<proto::RegisterModelResponse>, Status> {
        self.config_change("RegisterModel")?;
        unimplemented("RegisterModel")
    }

    async fn set_default_model(
        &self,
        _r: Request<proto::SetDefaultModelRequest>,
    ) -> std::result::Result<Response<proto::SetDefaultModelResponse>, Status> {
        self.config_change("SetDefaultModel")?;
        unimplemented("SetDefaultModel")
    }

    async fn drop_model(
        &self,
        _r: Request<proto::DropModelRequest>,
    ) -> std::result::Result<Response<proto::DropModelResponse>, Status> {
        self.config_change("DropModel")?;
        unimplemented("DropModel")
    }

    async fn backfill(
        &self,
        _r: Request<proto::BackfillRequest>,
    ) -> std::result::Result<Response<Self::BackfillStream>, Status> {
        unimplemented("Backfill")
    }

    async fn embed_text(
        &self,
        _r: Request<proto::EmbedTextRequest>,
    ) -> std::result::Result<Response<proto::EmbedTextResponse>, Status> {
        unimplemented("EmbedText")
    }

    async fn ensure_llama_model(
        &self,
        _r: Request<proto::EnsureLlamaModelRequest>,
    ) -> std::result::Result<Response<proto::EnsureLlamaModelResponse>, Status> {
        unimplemented("EnsureLlamaModel")
    }

    async fn enrich_facts(
        &self,
        _r: Request<proto::EnrichFactsRequest>,
    ) -> std::result::Result<Response<Self::EnrichFactsStream>, Status> {
        unimplemented("EnrichFacts")
    }

    async fn cluster_facts(
        &self,
        _r: Request<proto::ClusterFactsRequest>,
    ) -> std::result::Result<Response<Self::ClusterFactsStream>, Status> {
        unimplemented("ClusterFacts")
    }

    async fn list_fact_prompts(
        &self,
        _r: Request<proto::ListFactPromptsRequest>,
    ) -> std::result::Result<Response<proto::ListFactPromptsResponse>, Status> {
        unimplemented("ListFactPrompts")
    }

    async fn get_graph_labels(
        &self,
        _r: Request<proto::GraphLabelsRequest>,
    ) -> std::result::Result<Response<proto::GraphLabelsResponse>, Status> {
        unimplemented("GetGraphLabels")
    }

    async fn find_graph_vertices(
        &self,
        _r: Request<proto::FindGraphVerticesRequest>,
    ) -> std::result::Result<Response<proto::FindGraphVerticesResponse>, Status> {
        unimplemented("FindGraphVertices")
    }

    async fn get_graph_neighborhood(
        &self,
        _r: Request<proto::GraphNeighborhoodRequest>,
    ) -> std::result::Result<Response<proto::GraphNeighborhoodResponse>, Status> {
        unimplemented("GetGraphNeighborhood")
    }

    async fn set_setting(
        &self,
        _r: Request<proto::SetSettingRequest>,
    ) -> std::result::Result<Response<proto::SetSettingResponse>, Status> {
        self.config_change("SetSetting")?;
        unimplemented("SetSetting")
    }

    async fn mcp_install(
        &self,
        _r: Request<proto::McpInstallRequest>,
    ) -> std::result::Result<Response<proto::McpInstallResponse>, Status> {
        self.config_change("McpInstall")?;
        unimplemented("McpInstall")
    }

    async fn mcp_uninstall(
        &self,
        _r: Request<proto::McpUninstallRequest>,
    ) -> std::result::Result<Response<proto::McpUninstallResponse>, Status> {
        self.config_change("McpUninstall")?;
        unimplemented("McpUninstall")
    }

    async fn mcp_status(
        &self,
        _r: Request<proto::McpStatusRequest>,
    ) -> std::result::Result<Response<proto::McpStatusResponse>, Status> {
        unimplemented("McpStatus")
    }
}

/// Python's `repr()` of a string, for the messages that carried one (`{query!r}`).
fn pyrepr_str(text: &str) -> String {
    garage_mcp::pyrepr::str_repr(text)
}

/// `f"{n:,}"`.
fn thousands(n: i64) -> String {
    let digits = n.abs().to_string();
    let mut out = String::new();
    for (i, ch) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i).is_multiple_of(3) {
            out.push(',');
        }
        out.push(ch);
    }
    if n < 0 { format!("-{out}") } else { out }
}

/// Boxed parameters as the slice `tokio_postgres` queries take.
fn refs(
    params: &[Box<dyn tokio_postgres::types::ToSql + Sync + Send>],
) -> Vec<&(dyn tokio_postgres::types::ToSql + Sync)> {
    params.iter().map(|b| b.as_ref() as &(dyn tokio_postgres::types::ToSql + Sync)).collect()
}

/// Where the SQL lives for a service built from `config`: the folder named, else the default.
pub fn sql_dir(explicit: Option<&Path>) -> PathBuf {
    explicit.map_or_else(crate::migrate::default_sql_dir, Path::to_path_buf)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn counts_are_grouped_as_python_formats_them() {
        assert_eq!(thousands(0), "0");
        assert_eq!(thousands(999), "999");
        assert_eq!(thousands(1000), "1,000");
        assert_eq!(thousands(1_234_567), "1,234,567");
    }
}

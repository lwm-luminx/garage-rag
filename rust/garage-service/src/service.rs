//! `GarageService` itself: each RPC a thin translation between its messages and the functions of
//! this crate, as the Python servicer was over `garage_rag.ops`. The RPCs later stages port answer
//! `UNIMPLEMENTED` with a pointer to the plan.

use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::{Arc, PoisonError, RwLock};
use std::time::{SystemTime, UNIX_EPOCH};

use deadpool_postgres::Pool;
use garage_embed::Host;
use garage_facade::proto;
use garage_facade::proto::garage_service_server::GarageService as GarageServiceTrait;
use garage_ingest::WalkPolicy;
use garage_ingest::scanner::{ScanOptions, ScanResult, Ticker, scan_source};
use garage_mcp::chat::{ChatModel, ChatSettings};
use garage_mcp::pyjson;
use serde_json::{Map, Value};
use tokio::sync::mpsc;
use tokio_stream::Stream;
use tokio_stream::wrappers::ReceiverStream;
use tonic::{Request, Response, Status};

use crate::catalog::{self, ModelRequest};
use crate::clusters::{self, ChatDistiller, ClusterParams, ClusterProgress, ClusterRun, ClusterSummary, Distill};
use crate::config::{CONFIG_FILENAME, Config, default_config_path, update_config};
use crate::db::{Client, isoformat_opt};
use crate::embedding::{backfill_distilled, count_pending, pending_chunks, store_vectors};
use crate::error::{Result, ServiceError};
use crate::facts::{self, FactFilters, FactRow};
use crate::gateway::{self, AuthorPayload, ChunkPayload, DocumentPayload};
use crate::mcp_install::{self, InstallRequest};
use crate::migrate::{apply_migrations, pending_migrations};
use crate::models::{count_vectors, drop_model, get_model, list_models, register_model, set_default_model};
use crate::prompts::EffectivePrompt;
use crate::registry::{StoragePlan, truncate_vector};
use crate::search::{QueryEmbedder, SearchFilters, search, snippet};
use crate::sources::{self, DEFAULT_MAX_DELETE_FRACTION};
use crate::{corpus, db, graph, prompts};

/// What `GetVersion` reports: the Python package's version, since the app shows it as the
/// backend's and nothing about the contract changed.
pub const VERSION: &str = "1.5.0";

/// The largest message the server accepts (`MAX_REQUEST_BYTES`): `PersistDocument` carries a whole
/// document's text and chunks.
pub const MAX_REQUEST_BYTES: usize = 256 * 1024 * 1024;

/// `json.dumps(..., ensure_ascii=False)`, as the Corpus* results were written.
const CORPUS_JSON: pyjson::Style = pyjson::Style { compact: false, ensure_ascii: false };

/// The service: a pool on the database `garage.json` names, the configuration (replaced by
/// `SetSetting`, as Python reloaded its process-wide settings), and the process's query embedder.
pub struct GarageService {
    pool: Pool,
    config: RwLock<Config>,
    embedder: Arc<dyn QueryEmbedder>,
    /// The process's way to a model server, for the chat model the long jobs ask (`ClusterFacts`'s
    /// distiller); without one those jobs run without a model.
    host: Option<Arc<dyn Host>>,
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
        Ok(Self { pool, config: RwLock::new(config), embedder, host: None, sql_dir, callers_vouched_for })
    }

    /// The same service with a host for its chat model.
    #[must_use]
    pub fn with_host(mut self, host: Arc<dyn Host>) -> Self {
        self.host = Some(host);
        self
    }

    /// The configured chat model (`LocalChatModel`), or why there is none.
    fn chat_model(&self, config: &Config) -> Result<ChatModel> {
        let Some(host) = self.host.clone() else {
            return Err(ServiceError::Unavailable("this process has no way to reach a model server".into()));
        };
        ChatModel::new(&chat_settings(config), host).map_err(|e| ServiceError::invalid(e.0))
    }

    /// The configuration in effect.
    pub fn config(&self) -> Config {
        self.config.read().unwrap_or_else(PoisonError::into_inner).clone()
    }

    fn replace_config(&self, config: Config) {
        *self.config.write().unwrap_or_else(PoisonError::into_inner) = config;
    }

    /// The configuration read again from its file (the in-memory one when there is no file), and
    /// kept, as Python's `set_settings(load_config(path))` after a write.
    fn reloaded_config(&self) -> Result<Config> {
        let current = self.config();
        let Some(path) = current.path.as_deref().filter(|p| p.is_file()) else { return Ok(current) };
        let fresh = Config::load(Some(path))?;
        self.replace_config(fresh.clone());
        Ok(fresh)
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
        self.config().default_embedding_model()
    }
}

/// `text`, or `default` when it is empty (`request.field or default`).
fn or_default<'a>(text: &'a str, default: &'a str) -> &'a str {
    if text.is_empty() { default } else { text }
}

fn path_text(path: &Path) -> String {
    path.to_string_lossy().into_owned()
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
            self.config().hnsw_ef_search(),
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
        request: Request<proto::ListFactsRequest>,
    ) -> std::result::Result<Response<proto::ListFactsResponse>, Status> {
        let r = request.into_inner();
        let client = self.client().await?;
        let filters = FactFilters {
            query: r.query,
            source: r.source,
            fact_class: r.fact_class,
            corpus_class: r.corpus_class,
            document_id: Some(r.document_id),
        };
        let limit = if r.limit == 0 { 200 } else { i64::from(r.limit) };
        let page =
            facts::list_facts(&client, &filters, limit, i64::from(r.offset), r.collapse, Some(r.distilled_fact_id))
                .await?;
        let summaries: Vec<proto::FactSummary> = page.facts.iter().map(fact_summary).collect();
        ok(proto::ListFactsResponse {
            formatted_output: format!("{} of {} facts", summaries.len(), page.total),
            facts: summaries,
            total_count: page.total,
            classes: page
                .classes
                .into_iter()
                .map(|(fact_class, count)| proto::FactClassCount { fact_class, count })
                .collect(),
        })
    }

    async fn get_fact_stats(
        &self,
        request: Request<proto::FactStatsRequest>,
    ) -> std::result::Result<Response<proto::FactStatsResponse>, Status> {
        let r = request.into_inner();
        let client = self.client().await?;
        let filters = FactFilters {
            query: r.query,
            source: r.source,
            fact_class: r.fact_class,
            corpus_class: r.corpus_class,
            document_id: Some(r.document_id),
        };
        let stats = facts::fact_stats(&client, &filters).await?;
        ok(proto::FactStatsResponse {
            formatted_output: stats.message(),
            facts: stats.facts,
            documents: stats.documents,
            facts_by_source: stats.by_source.into_iter().collect(),
            facts_by_class: stats.by_class.into_iter().collect(),
            distilled: stats.distilled,
            clusters: stats.clusters,
            clustered_facts: stats.clustered_facts,
        })
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
            self.config().hnsw_ef_search(),
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
        lines.push(format!("schema ready ({})", db::redact_url(&self.config().database_url())));
        ok(proto::InitDbResponse { applied, message: lines.join("\n") })
    }

    async fn get_setting(
        &self,
        request: Request<proto::GetSettingRequest>,
    ) -> std::result::Result<Response<proto::GetSettingResponse>, Status> {
        let name = request.into_inner().name;
        let value = self.config().setting(&name)?;
        ok(proto::GetSettingResponse { name, value_json: pyjson::dumps(&value, pyjson::DEFAULT) })
    }

    // -- the ingest facade ------------------------------------------------------------------

    async fn begin_ingest_session(
        &self,
        request: Request<proto::BeginIngestSessionRequest>,
    ) -> std::result::Result<Response<proto::BeginIngestSessionResponse>, Status> {
        let r = request.into_inner();
        let mut client = self.client().await?;
        let ctx = gateway::begin_session(&mut client, &self.config(), &r.source_slug).await?;
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
        let local = garage_embed::provider::provider_is_local(&model.provider, &self.config().embed_settings());
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

    // -- sources ----------------------------------------------------------------------------

    async fn add_source(
        &self,
        request: Request<proto::AddSourceRequest>,
    ) -> std::result::Result<Response<proto::AddSourceResponse>, Status> {
        self.config_change("AddSource")?;
        let r = request.into_inner();
        let mut client = self.client().await?;
        let result = sources::add_source(
            &mut client,
            &r.slug,
            &r.root,
            or_default(&r.kind, "filesystem"),
            or_default(&r.corpus_class, "document"),
            or_default(&r.trust, "authored"),
        )
        .await?;
        ok(proto::AddSourceResponse {
            message: result.message(),
            slug: result.slug,
            root: path_text(&result.root),
            created: result.created,
        })
    }

    async fn remove_source(
        &self,
        request: Request<proto::RemoveSourceRequest>,
    ) -> std::result::Result<Response<proto::RemoveSourceResponse>, Status> {
        self.config_change("RemoveSource")?;
        let slug = request.into_inner().slug;
        let config_path = self.config().path;
        let mut client = self.client().await?;
        let result = sources::remove_source(&mut client, config_path.as_deref(), &slug).await?;
        if result.config_path.is_some() {
            self.reloaded_config()?;
        }
        ok(proto::RemoveSourceResponse {
            message: result.message(),
            slug: result.slug,
            deleted_documents: result.deleted_documents,
        })
    }

    async fn scan(
        &self,
        request: Request<proto::ScanRequest>,
    ) -> std::result::Result<Response<Self::ScanStream>, Status> {
        let r = request.into_inner();
        let client = self.client().await?;
        let targets = sources::scan_targets(&client, &r.source).await?;
        drop(client);
        let pool = self.pool.clone();
        let (tx, rx) = mpsc::channel(64);
        tokio::spawn(async move {
            if let Err(status) = run_scan(&pool, targets, r.include_code, &tx).await {
                let _ = tx.send(Err(status)).await;
            }
        });
        ok(Box::pin(ReceiverStream::new(rx)) as Self::ScanStream)
    }

    async fn sync_sources(
        &self,
        request: Request<proto::SyncSourcesRequest>,
    ) -> std::result::Result<Response<proto::SyncSourcesResponse>, Status> {
        let dry_run = request.into_inner().dry_run;
        // The file is the source of truth, so it is read as it stands, not as it was loaded.
        let config = self.reloaded_config()?;
        let mut client = self.client().await?;
        let result = sources::sync_sources(&mut client, &config, !dry_run).await?;
        ok(proto::SyncSourcesResponse {
            message: result.lines().join("\n"),
            config_path: result.config_path.as_deref().map(path_text).unwrap_or_default(),
            declared: i32::try_from(result.declared).unwrap_or(i32::MAX),
            applied: result.applied,
            created: result.created,
            updated: result.updated,
            undeclared: result
                .undeclared
                .into_iter()
                .map(|(slug, document_count)| proto::UndeclaredSource { slug, document_count })
                .collect(),
        })
    }

    async fn import_sources_to_config(
        &self,
        request: Request<proto::ImportSourcesToConfigRequest>,
    ) -> std::result::Result<Response<proto::ImportSourcesToConfigResponse>, Status> {
        self.config_change("ImportSourcesToConfig")?;
        let path = request.into_inner().path;
        let target = if path.is_empty() {
            self.config()
                .path
                .unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")).join(CONFIG_FILENAME))
        } else {
            PathBuf::from(path)
        };
        let client = self.client().await?;
        let result = sources::import_sources(&client, &target).await?;
        if self.config().path.as_deref() == Some(target.as_path()) {
            self.reloaded_config()?;
        }
        ok(proto::ImportSourcesToConfigResponse {
            message: result.message(),
            path: path_text(&result.path),
            added: result.added,
        })
    }

    async fn reconcile(
        &self,
        request: Request<proto::ReconcileRequest>,
    ) -> std::result::Result<Response<proto::ReconcileResponse>, Status> {
        let r = request.into_inner();
        let mut client = self.client().await?;
        let result =
            sources::reconcile_source(&mut client, &r.source, !r.apply, r.force, DEFAULT_MAX_DELETE_FRACTION).await?;
        ok(proto::ReconcileResponse {
            message: result.message(r.apply),
            fraction: result.fraction(),
            source: result.source,
            total_documents: result.total_documents,
            candidates: result.candidates,
            deleted: result.deleted,
            refused: result.refused,
            reason: result.reason,
        })
    }

    // -- models -----------------------------------------------------------------------------

    async fn register_model(
        &self,
        request: Request<proto::RegisterModelRequest>,
    ) -> std::result::Result<Response<proto::RegisterModelResponse>, Status> {
        self.config_change("RegisterModel")?;
        let r = request.into_inner();
        let model_request = ModelRequest {
            slug: r.slug,
            dims: (r.dims > 0).then(|| usize::try_from(r.dims).unwrap_or(usize::MAX)),
            model_ref: opt(&r.model_ref),
            provider: opt(&r.provider),
            model_id: opt(&r.model_id),
            distance: opt(&r.distance),
            modality: opt(&r.modality),
        };
        let spec = catalog::resolve_spec(&model_request, &catalog::known_models()?)?;
        let mut client = self.client().await?;
        let row = register_model(&mut client, &spec, r.make_default).await?;
        let mut notes = Vec::new();
        if row.stored_dims < row.dims {
            notes.push(format!(
                "truncated {} -> {} (Matryoshka) to fit the halfvec HNSW ceiling",
                row.dims, row.stored_dims
            ));
        }
        if row.index_kind == "hnsw_bq" {
            notes.push(format!("binary-quantized index; queries re-rank on exact {} distance", row.distance));
        }
        let kind = if row.modality == "image" { " (image model)" } else { "" };
        let headline = format!(
            "registered {}{kind}: {}-dim -> {}({}), index={}, distance={}, table={}",
            row.slug, row.dims, row.storage_kind, row.stored_dims, row.index_kind, row.distance, row.table_name
        );
        let mut lines = vec![headline];
        lines.extend(notes.iter().cloned());
        ok(proto::RegisterModelResponse {
            model: Some(proto::ModelInfo {
                slug: row.slug,
                provider: row.provider,
                model_ref: row.model_ref,
                dims: row.dims,
                stored_dims: row.stored_dims,
                storage_kind: row.storage_kind,
                index_kind: row.index_kind,
                table_name: row.table_name,
                is_default: row.is_default,
                model_id: row.model_id.unwrap_or_default(),
                distance: row.distance,
                modality: row.modality,
            }),
            notes,
            message: lines.join("\n"),
        })
    }

    async fn set_default_model(
        &self,
        request: Request<proto::SetDefaultModelRequest>,
    ) -> std::result::Result<Response<proto::SetDefaultModelResponse>, Status> {
        self.config_change("SetDefaultModel")?;
        let slug = request.into_inner().slug;
        let mut client = self.client().await?;
        get_model(&client, Some(&slug), &self.default_model()).await?;
        set_default_model(&mut client, &slug).await?;
        ok(proto::SetDefaultModelResponse { message: format!("default model = {slug}") })
    }

    async fn drop_model(
        &self,
        request: Request<proto::DropModelRequest>,
    ) -> std::result::Result<Response<proto::DropModelResponse>, Status> {
        self.config_change("DropModel")?;
        let slug = request.into_inner().slug;
        let mut client = self.client().await?;
        drop_model(&mut client, &slug, &self.default_model()).await?;
        ok(proto::DropModelResponse { message: format!("dropped {slug}") })
    }

    async fn embed_text(
        &self,
        request: Request<proto::EmbedTextRequest>,
    ) -> std::result::Result<Response<proto::EmbedTextResponse>, Status> {
        let r = request.into_inner();
        if r.text.trim().is_empty() {
            return Err(Status::invalid_argument("nothing to embed: the text is empty"));
        }
        let client = self.client().await?;
        let model = get_model(&client, opt(&r.model).as_deref(), &self.default_model()).await?;
        drop(client);
        let (embedder, embedded_model, text) = (self.embedder.clone(), model.clone(), r.text);
        let mut vector = tokio::task::spawn_blocking(move || embedder.embed_query(&embedded_model, &text))
            .await
            .map_err(|e| ServiceError::failed(format!("embedding the text: {e}")))??;
        let native = vector.len();
        if r.dimensions != 0 {
            let dimensions = usize::try_from(r.dimensions).unwrap_or(0);
            if dimensions == 0 || dimensions > native {
                return Err(Status::invalid_argument(format!(
                    "{} gives {native} dimensions; {} is not between 1 and {native}",
                    model.slug, r.dimensions
                )));
            }
            let plan = StoragePlan {
                stored_dims: dimensions,
                storage_kind: "vector".to_owned(),
                index_kind: "hnsw".to_owned(),
                truncated_from: Some(native),
            };
            vector = truncate_vector(&vector, &plan)?;
        }
        ok(proto::EmbedTextResponse {
            model: model.slug,
            provider: model.provider,
            model_ref: model.model_ref,
            native_dims: i32::try_from(native).unwrap_or(i32::MAX),
            vector,
        })
    }

    // -- later stages -----------------------------------------------------------------------

    async fn backfill(
        &self,
        _r: Request<proto::BackfillRequest>,
    ) -> std::result::Result<Response<Self::BackfillStream>, Status> {
        unimplemented("Backfill")
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
        request: Request<proto::ClusterFactsRequest>,
    ) -> std::result::Result<Response<Self::ClusterFactsStream>, Status> {
        let r = request.into_inner();
        let config = self.config();
        let params = ClusterParams::from_config(
            &config,
            (r.threshold != 0.0).then_some(r.threshold),
            (r.neighbors != 0).then_some(i64::from(r.neighbors)),
        )?;
        let distiller: Option<Arc<dyn Distill>> = if r.no_distill {
            None
        } else {
            Some(Arc::new(ChatDistiller { chat: Arc::new(self.chat_model(&config)?) }))
        };
        let mut client = self.client().await?;
        let model = get_model(&client, Some(&r.model), &config.default_embedding_model()).await?;
        let schema = if r.no_graph { None } else { Some(prompts::graph_schema(&configured_prompts(&config)?)?) };
        let ef_search = config.hnsw_ef_search();
        let (tx, rx) = mpsc::channel(64);
        tokio::spawn(async move {
            let job = ClusterJob { model, params, full: r.full, distiller, schema, ef_search };
            let result = run_cluster(&mut client, job, &tx).await;
            let _ = match result {
                Ok(finished) => tx.send(Ok(finished)).await,
                Err(error) => tx.send(Err(Status::from(error))).await,
            };
        });
        ok(Box::pin(ReceiverStream::new(rx)) as Self::ClusterFactsStream)
    }

    async fn list_fact_prompts(
        &self,
        request: Request<proto::ListFactPromptsRequest>,
    ) -> std::result::Result<Response<proto::ListFactPromptsResponse>, Status> {
        let _ = request;
        let config = self.config();
        let configured = config.setting("facts.prompts")?;
        let prompts = prompts::effective_prompts(&prompts::parse_prompts(&configured)?)?
            .iter()
            .map(|p| proto::FactPrompt {
                name: p.name.clone(),
                description: p.description.clone(),
                examples_json: pyjson::dumps(&p.examples_value(), CORPUS_JSON),
                corpus_classes: p.corpus_classes.clone(),
                sources: p.sources.clone(),
                enabled: p.enabled,
                builtin: p.builtin,
                customized: p.customized,
                sha256: db::hex_string(&p.sha256()),
            })
            .collect();
        ok(proto::ListFactPromptsResponse { prompts, configured_json: pyjson::dumps(&configured, CORPUS_JSON) })
    }

    async fn get_graph_labels(
        &self,
        request: Request<proto::GraphLabelsRequest>,
    ) -> std::result::Result<Response<proto::GraphLabelsResponse>, Status> {
        let _ = request;
        let mut client = self.client().await?;
        let labels = graph::graph_labels(&mut client).await?;
        ok(proto::GraphLabelsResponse {
            available: labels.available,
            vertex_labels: labels
                .vertices
                .into_iter()
                .map(|(label, count)| proto::GraphLabelCount { label, count })
                .collect(),
            edge_labels: labels
                .edges
                .into_iter()
                .map(|(label, count)| proto::GraphLabelCount { label, count })
                .collect(),
        })
    }

    async fn find_graph_vertices(
        &self,
        request: Request<proto::FindGraphVerticesRequest>,
    ) -> std::result::Result<Response<proto::FindGraphVerticesResponse>, Status> {
        let r = request.into_inner();
        let mut client = self.client().await?;
        if !graph::graph_labels(&mut client).await?.available {
            return ok(proto::FindGraphVerticesResponse::default());
        }
        let limit = if r.limit == 0 { 50 } else { i64::from(r.limit) };
        let found = graph::find_vertices(&mut client, &r.query, &r.label, limit).await?;
        ok(proto::FindGraphVerticesResponse { available: true, vertices: found.iter().map(graph_vertex).collect() })
    }

    async fn get_graph_neighborhood(
        &self,
        request: Request<proto::GraphNeighborhoodRequest>,
    ) -> std::result::Result<Response<proto::GraphNeighborhoodResponse>, Status> {
        let r = request.into_inner();
        let mut client = self.client().await?;
        let center = if r.vertex_id != 0 {
            graph::Center::Id(r.vertex_id)
        } else {
            graph::Center::Key { label: r.label.clone(), key: r.key }
        };
        let depth = if r.depth == 0 { 1 } else { i64::from(r.depth) };
        let vertex_labels =
            (r.filter_vertex_labels || !r.vertex_labels.is_empty()).then_some(r.vertex_labels.as_slice());
        let edge_labels = (r.filter_edge_labels || !r.edge_labels.is_empty()).then_some(r.edge_labels.as_slice());
        let limit = if r.limit == 0 { 200 } else { i64::from(r.limit) };
        let result = graph::neighborhood(&mut client, &center, depth, vertex_labels, edge_labels, limit).await?;
        let (true, Some(center)) = (result.available, result.center) else {
            return ok(proto::GraphNeighborhoodResponse::default());
        };
        ok(proto::GraphNeighborhoodResponse {
            available: true,
            center: Some(graph_vertex(&center)),
            vertices: result.vertices.iter().map(graph_vertex).collect(),
            edges: result
                .edges
                .iter()
                .map(|e| proto::GraphEdge {
                    id: e.id,
                    label: e.label.clone(),
                    source_id: e.source_id,
                    target_id: e.target_id,
                    properties_json: graph::properties_json(&e.properties),
                })
                .collect(),
            truncated: result.truncated,
        })
    }

    async fn set_setting(
        &self,
        request: Request<proto::SetSettingRequest>,
    ) -> std::result::Result<Response<proto::SetSettingResponse>, Status> {
        self.config_change("SetSetting")?;
        let r = request.into_inner();
        let target = if r.path.is_empty() {
            self.config().path.unwrap_or_else(default_config_path)
        } else {
            PathBuf::from(r.path)
        };
        let (written, stored) = update_config(&target, &r.name, &r.value)?;
        // The process runs on the file it just wrote, as Python's `set_settings(load_config(target))`.
        let path = written.path.unwrap_or(target);
        self.replace_config(Config::load(Some(&path))?);
        ok(proto::SetSettingResponse {
            name: r.name,
            value_json: pyjson::dumps(&stored, pyjson::DEFAULT),
            path: path_text(&path),
        })
    }

    async fn mcp_install(
        &self,
        request: Request<proto::McpInstallRequest>,
    ) -> std::result::Result<Response<proto::McpInstallResponse>, Status> {
        self.config_change("McpInstall")?;
        let r = request.into_inner();
        let install_request = InstallRequest {
            target: or_default(&r.target, "project").to_owned(),
            path: opt(&r.path).map(PathBuf::from),
            all_configs: r.all,
            name: or_default(&r.name, mcp_install::DEFAULT_SERVER_NAME).to_owned(),
            stdio: r.stdio,
            host: opt(&r.host),
            port: (r.port != 0).then_some(i64::from(r.port)),
            route: opt(&r.route),
            force: r.force,
            dry_run: r.dry_run,
        };
        let config = self.config();
        let report = tokio::task::spawn_blocking(move || mcp_install::install_mcp_server(&config, &install_request))
            .await
            .map_err(|e| ServiceError::failed(format!("installing: {e}")))??;
        ok(proto::McpInstallResponse {
            message: report.lines().join("\n"),
            url: report.url.unwrap_or_default(),
            command: report.command.unwrap_or_default(),
            args: report.args,
            fell_back: report.fell_back,
            outcomes: report
                .outcomes
                .into_iter()
                .map(|o| proto::McpTargetOutcome {
                    key: o.key,
                    label: o.label,
                    path: path_text(&o.path),
                    written: o.written,
                    created_file: o.created_file,
                    replaced_entry: o.replaced_entry,
                    backup_path: o.backup.as_deref().map(path_text).unwrap_or_default(),
                    skipped: o.skipped.unwrap_or_default(),
                    preview_json: o.preview.map(|p| pyjson::dumps(&p, pyjson::DEFAULT)).unwrap_or_default(),
                })
                .collect(),
        })
    }

    async fn mcp_uninstall(
        &self,
        request: Request<proto::McpUninstallRequest>,
    ) -> std::result::Result<Response<proto::McpUninstallResponse>, Status> {
        self.config_change("McpUninstall")?;
        let r = request.into_inner();
        let name = or_default(&r.name, mcp_install::DEFAULT_SERVER_NAME).to_owned();
        let target = or_default(&r.target, "project").to_owned();
        let path = opt(&r.path).map(PathBuf::from);
        let (config, removed) = {
            let name = name.clone();
            tokio::task::spawn_blocking(move || mcp_install::uninstall_mcp_server(&target, path.as_deref(), &name))
                .await
                .map_err(|e| ServiceError::failed(format!("uninstalling: {e}")))??
        };
        let message = if removed {
            format!("removed {name} from {}", config.display())
        } else {
            format!("{name} was not configured in {}", config.display())
        };
        ok(proto::McpUninstallResponse { path: path_text(&config), removed, message })
    }

    async fn mcp_status(
        &self,
        _request: Request<proto::McpStatusRequest>,
    ) -> std::result::Result<Response<proto::McpStatusResponse>, Status> {
        let (server_command, clients) = tokio::task::spawn_blocking(mcp_install::mcp_status)
            .await
            .map_err(|e| ServiceError::failed(format!("reading client configs: {e}")))?;
        ok(proto::McpStatusResponse {
            server_command,
            clients: clients
                .into_iter()
                .map(|c| proto::McpClientInfo {
                    key: c.key,
                    label: c.label,
                    path: path_text(&c.path),
                    registered: c.registered,
                    config_exists: c.config_exists,
                })
                .collect(),
        })
    }
}

type ScanSender = mpsc::Sender<std::result::Result<proto::ScanStatus, Status>>;

fn scan_status(result: &ScanResult) -> proto::SourceScanStatus {
    proto::SourceScanStatus {
        source: result.source_slug.clone(),
        kind: result.kind.clone(),
        root: path_text(&result.root),
        item_count: i64::try_from(result.item_count).unwrap_or(i64::MAX),
        item_type: result.item_type.clone(),
        duration_seconds: result.duration_seconds,
        error: result.error.clone().unwrap_or_default(),
    }
}

fn scan_progress(source: &str, source_items: u64, total_items: u64) -> proto::ScanStatus {
    proto::ScanStatus {
        phase: "progress".to_owned(),
        source: source.to_owned(),
        source_items: i64::try_from(source_items).unwrap_or(i64::MAX),
        total_items: i64::try_from(total_items).unwrap_or(i64::MAX),
        result: None,
        summary: None,
    }
}

/// Scans each target in turn, as `scan_sources` did, sending the running count while a source is
/// walked, each source's result when it is done, and the summary last. A closed channel (the
/// client went away) ends the scan at its next step.
async fn run_scan(
    pool: &Pool,
    targets: Vec<(String, String, PathBuf)>,
    include_code: bool,
    tx: &ScanSender,
) -> std::result::Result<(), Status> {
    let mut results: Vec<ScanResult> = Vec::new();
    let mut found_before: u64 = 0;
    for (slug, kind, root) in targets {
        if tx.send(Ok(scan_progress(&slug, 0, found_before))).await.is_err() {
            return Ok(());
        }
        let (progress, scanned_slug, before) = (tx.clone(), slug.clone(), found_before);
        let result = tokio::task::spawn_blocking(move || {
            let mut report = |count: u64| {
                let _ = progress.blocking_send(Ok(scan_progress(&scanned_slug, count, before + count)));
            };
            let policy = WalkPolicy::default();
            let options = ScanOptions { include_code, policy: &policy, read_git: true };
            scan_source(&scanned_slug, &kind, &root, &options, &mut Ticker::new(Some(&mut report)))
        })
        .await
        .map_err(|e| Status::internal(format!("scanning {slug}: {e}")))?;
        let mut client = pool.get().await.map_err(ServiceError::from)?;
        gateway::persist_scan(
            &mut client,
            &slug,
            i64::try_from(result.item_count).unwrap_or(i64::MAX),
            &result.item_type,
            &Value::Object(result.details.clone()),
        )
        .await?;
        found_before += result.item_count;
        let done = proto::ScanStatus {
            phase: "source".to_owned(),
            source: slug.clone(),
            source_items: i64::try_from(result.item_count).unwrap_or(i64::MAX),
            total_items: i64::try_from(found_before).unwrap_or(i64::MAX),
            result: Some(scan_status(&result)),
            summary: None,
        };
        results.push(result);
        if tx.send(Ok(done)).await.is_err() {
            return Ok(());
        }
    }
    let total = i64::try_from(found_before).unwrap_or(i64::MAX);
    let message = if results.is_empty() {
        "no sources registered to scan".to_owned()
    } else {
        format!("Scanned {} source(s): {} items", results.len(), thousands(total))
    };
    let summary =
        proto::ScanResponse { sources: results.iter().map(scan_status).collect(), total_items: total, message };
    let _ = tx
        .send(Ok(proto::ScanStatus {
            phase: "finished".to_owned(),
            source: String::new(),
            source_items: 0,
            total_items: total,
            result: None,
            summary: Some(summary),
        }))
        .await;
    Ok(())
}

/// The chat model's configuration (`facts.*`, `inference.*`, `identity.name`, the servers).
fn chat_settings(config: &Config) -> ChatSettings {
    let text = |name: &str| match config.setting(name) {
        Ok(Value::String(value)) => value,
        _ => String::new(),
    };
    let mut settings = ChatSettings { servers: config.embed_settings(), ..ChatSettings::default() };
    for (value, field) in
        [(text("facts.provider"), &mut settings.fact_provider), (text("facts.model"), &mut settings.fact_model)]
    {
        if !value.is_empty() {
            *field = value;
        }
    }
    settings.inference_provider = text("inference.provider");
    settings.inference_model = text("inference.model");
    settings.self_name = config.self_name();
    settings
}

/// The effective fact prompts, from `facts.prompts` (`configured_prompts`).
fn configured_prompts(config: &Config) -> Result<Vec<EffectivePrompt>> {
    prompts::effective_prompts(&prompts::parse_prompts(&config.setting("facts.prompts")?)?)
}

type ClusterSender = mpsc::Sender<std::result::Result<proto::ClusterFactsStatus, Status>>;

/// One `ClusterFacts` run as asked for.
struct ClusterJob {
    model: crate::models::EmbeddingModel,
    params: ClusterParams,
    full: bool,
    distiller: Option<Arc<dyn Distill>>,
    /// The graph to rebuild afterwards; `None` with `no_graph`.
    schema: Option<prompts::GraphSchema>,
    ef_search: i64,
}

/// A progress report as the RPC streams it (`on_progress`).
fn cluster_progress(state: &ClusterProgress) -> proto::ClusterFactsStatus {
    proto::ClusterFactsStatus {
        phase: state.phase.clone(),
        facts: state.facts,
        unembedded: state.unembedded,
        scanned: state.scanned,
        to_distill: state.to_distill,
        distilled: state.distilled,
        full: state.full,
        documents: state.documents,
        nodes: state.nodes,
        attached: state.attached,
        candidates: state.candidates,
        message: state.message(),
        ..Default::default()
    }
}

/// Runs the pass, streaming each progress line with a message (a report the channel cannot take
/// at the moment is dropped; a closed channel ends the run), rebuilds the graph when asked, and
/// returns the `finished` status.
async fn run_cluster(client: &mut Client, job: ClusterJob, tx: &ClusterSender) -> Result<proto::ClusterFactsStatus> {
    let progress = tx.clone();
    let mut report = move |state: &ClusterProgress| -> bool {
        if state.message().is_empty() {
            return true;
        }
        !matches!(progress.try_send(Ok(cluster_progress(state))), Err(mpsc::error::TrySendError::Closed(_)))
    };
    let distill_model = job.distiller.as_ref().map(|d| d.model_id()).unwrap_or_default();
    let run = ClusterRun {
        params: job.params.clone(),
        full: job.full,
        distiller: job.distiller,
        report_to: Some(&mut report),
        ef_search: job.ef_search,
    };
    let state = clusters::cluster_facts(client, &job.model, run).await?;
    let graph = match &job.schema {
        Some(schema) => {
            let summary = graph::rebuild_graph(client, schema).await?;
            if summary.available { summary.message() } else { String::new() }
        }
        None => String::new(),
    };
    let summary =
        ClusterSummary { model: job.model.slug.clone(), threshold: job.params.threshold, distill_model, state, graph };
    let s = &summary.state;
    Ok(proto::ClusterFactsStatus {
        phase: "finished".to_owned(),
        full: s.full,
        documents: s.documents,
        restatements: s.restatements,
        nodes: s.nodes,
        attached: s.attached,
        accepted: s.accepted,
        facts: s.facts,
        unembedded: s.unembedded,
        distilled_facts: s.distilled_facts,
        clusters: s.clusters,
        clustered_facts: s.clustered_facts,
        dissolved: s.dissolved,
        failed: s.failed,
        withheld: s.withheld,
        model: summary.model.clone(),
        distill_model: summary.distill_model.clone(),
        graph: summary.graph.clone(),
        errors: s.errors.clone(),
        message: summary.message(),
        scanned: 0,
        to_distill: 0,
        distilled: 0,
        candidates: 0,
    })
}

/// Python's `repr()` of a string, for the messages that carried one (`{query!r}`).
fn pyrepr_str(text: &str) -> String {
    garage_mcp::pyrepr::str_repr(text)
}

/// A `FactRow` as its proto (`ListFacts`).
fn fact_summary(f: &FactRow) -> proto::FactSummary {
    proto::FactSummary {
        id: f.id,
        document_id: f.document_id,
        ord: f.ord,
        fact: f.fact.clone(),
        fact_class: f.fact_class.clone(),
        attributes_json: match &f.attributes {
            Value::Object(map) if !map.is_empty() => pyjson::dumps(&f.attributes, pyjson::DEFAULT),
            _ => String::new(),
        },
        char_start: f.char_start,
        char_end: f.char_end,
        extractor: f.extractor.clone(),
        extractor_model: f.extractor_model.clone().unwrap_or_default(),
        created_at: isoformat_opt(f.created_at),
        document_title: f.document_title.clone().unwrap_or_default(),
        document_uri: f.document_uri.clone(),
        source_slug: f.source_slug.clone(),
        corpus_class: f.corpus_class.clone(),
        excerpt: f.excerpt.clone().unwrap_or_default(),
        excerpt_start: if f.excerpt.as_deref().is_some_and(|e| !e.is_empty()) { f.excerpt_start } else { 0 },
        distilled_fact_id: f.distilled_fact_id.unwrap_or(0),
        distilled_size: i32::try_from(f.distilled_size).unwrap_or(i32::MAX),
        distilled_statement: f.distilled_statement.clone().unwrap_or_default(),
        distilled_generated: f.distilled_generated,
        distilled_spread: f.distilled_spread,
        restates_fact_id: f.restates_fact_id.unwrap_or(0),
    }
}

/// A graph vertex as its proto (`_graph_vertex`).
fn graph_vertex(v: &graph::GraphVertex) -> proto::GraphVertex {
    proto::GraphVertex {
        id: v.id,
        label: v.label.clone(),
        key: v.key,
        title: v.title.clone(),
        properties_json: graph::properties_json(&v.properties),
    }
}

/// `f"{n:,}"`.
pub fn thousands(n: i64) -> String {
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

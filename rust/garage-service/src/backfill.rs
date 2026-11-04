//! `Backfill` (`ops/backfill.py`): the embed worker (`garage-embed`) run in this process over the
//! database, instead of over gRPC as the app's embed service runs it. The worker is the same code:
//! [`LocalFacade`] answers its facade calls from the pool, the way the `GetEmbeddingBatches`,
//! `UpdateEmbeddings`, `BackfillDistilled` and `ListModels` handlers answer them over the wire,
//! and [`ReportingHost`] carries its requests through the process's host and its progress into
//! the RPC's stream. The CLI's `garage backfill` is the caller; the app embeds through its own
//! worker.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use deadpool_postgres::Pool;
use garage_embed::facade::Facade;
use garage_embed::worker::{BackfillEvent, BackfillOptions};
use garage_embed::{FacadeError, Host, HttpRequest, HttpResponse, Settings};
use garage_facade::proto;
use tokio::runtime::Handle;
use tokio::sync::mpsc;
use tonic::Status;

use crate::db::Client;
use crate::embedding::{backfill_distilled, count_pending, pending_chunks, store_vectors};
use crate::error::{Result, ServiceError};
use crate::models::{get_model, list_models};

/// `ListModels`'s rows.
///
/// # Errors
///
/// The database.
pub async fn model_infos(client: &Client) -> Result<Vec<proto::ModelInfo>> {
    Ok(list_models(client)
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
        .collect())
}

fn opt(value: &str) -> Option<&str> {
    (!value.is_empty()).then_some(value)
}

/// `GetEmbeddingBatches`: the next chunks the model has no vector for. The worker posts these
/// texts to the model's provider: an off-box one never gets communication chunks.
///
/// # Errors
///
/// An unknown model; the database.
pub async fn embedding_batches(
    client: &Client,
    default_model: &str,
    settings: &Settings,
    r: &proto::GetEmbeddingBatchesRequest,
) -> Result<proto::GetEmbeddingBatchesResponse> {
    let model = get_model(client, opt(&r.model_slug), default_model).await?;
    let local = garage_embed::provider::provider_is_local(&model.provider, settings);
    let pending_total = count_pending(client, &model, local).await?;
    let withheld = if local { 0 } else { count_pending(client, &model, true).await? - pending_total };
    let mut fetch_limit = if r.batch_size > 0 { i64::from(r.batch_size) } else { 64 };
    if r.limit > 0 && i64::from(r.limit) < fetch_limit {
        fetch_limit = i64::from(r.limit);
    }
    let chunks: Vec<proto::EmbeddingChunkItem> = pending_chunks(client, &model, local, fetch_limit)
        .await?
        .into_iter()
        .map(|(chunk_id, text)| proto::EmbeddingChunkItem { chunk_id, text })
        .collect();
    let has_more = pending_total - i64::try_from(chunks.len()).unwrap_or(0) > 0;
    Ok(proto::GetEmbeddingBatchesResponse {
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

/// `UpdateEmbeddings`: stores the vectors.
///
/// # Errors
///
/// An unknown model; the database.
pub async fn update_embeddings(
    client: &mut Client,
    default_model: &str,
    r: proto::UpdateEmbeddingsRequest,
) -> Result<proto::UpdateEmbeddingsResponse> {
    let model = get_model(client, opt(&r.model_slug), default_model).await?;
    if r.embeddings.is_empty() {
        return Ok(proto::UpdateEmbeddingsResponse { success: true, count: 0, error: String::new() });
    }
    let vectors: Vec<(i64, Vec<f32>)> = r.embeddings.into_iter().map(|item| (item.chunk_id, item.vector)).collect();
    let count = store_vectors(client, &model, &vectors, true).await?;
    Ok(proto::UpdateEmbeddingsResponse {
        success: true,
        count: i32::try_from(count).unwrap_or(i32::MAX),
        error: String::new(),
    })
}

/// `BackfillDistilled`: the model's distilled facts get their vectors; how many did.
///
/// # Errors
///
/// An unknown model; the database.
pub async fn distilled(client: &Client, default_model: &str, model_slug: &str) -> Result<i64> {
    let model = get_model(client, opt(model_slug), default_model).await?;
    backfill_distilled(client, &model).await
}

/// The worker's facade answered from the pool, on the runtime `handle`; each call blocks the
/// worker's thread until the database has answered, as the gRPC facade does.
pub struct LocalFacade {
    pub pool: Pool,
    pub default_model: String,
    pub settings: Settings,
    pub handle: Handle,
}

impl LocalFacade {
    fn run<T>(&self, call: impl Future<Output = Result<T>>) -> std::result::Result<T, FacadeError> {
        self.handle.block_on(call).map_err(|error| match error {
            ServiceError::NotFound(message) => FacadeError::NotFound(message),
            other => FacadeError::Failed(other.message().to_owned()),
        })
    }
}

impl Facade for LocalFacade {
    fn list_models(&self) -> std::result::Result<Vec<proto::ModelInfo>, FacadeError> {
        self.run(async { model_infos(&self.pool.get().await?).await })
    }

    fn get_embedding_batches(
        &self,
        request: proto::GetEmbeddingBatchesRequest,
    ) -> std::result::Result<proto::GetEmbeddingBatchesResponse, FacadeError> {
        self.run(async {
            embedding_batches(&self.pool.get().await?, &self.default_model, &self.settings, &request).await
        })
    }

    fn update_embeddings(
        &self,
        request: proto::UpdateEmbeddingsRequest,
    ) -> std::result::Result<proto::UpdateEmbeddingsResponse, FacadeError> {
        self.run(async { update_embeddings(&mut self.pool.get().await?, &self.default_model, request).await })
    }

    fn backfill_distilled(&self, model_slug: &str) -> std::result::Result<i64, FacadeError> {
        self.run(async { distilled(&self.pool.get().await?, &self.default_model, model_slug).await })
    }
}

/// A `BackfillStatus` as the RPC streams it (`BackfillEvent`).
#[must_use]
pub fn status(event: &BackfillEvent) -> proto::BackfillStatus {
    let count = |n: u64| i64::try_from(n).unwrap_or(i64::MAX);
    proto::BackfillStatus {
        model_slug: event.model.clone(),
        phase: event.phase.name().to_owned(),
        total: count(event.total),
        embedded: count(event.embedded),
        failed: count(event.failed),
        remaining: count(event.remaining()),
        batches: count(event.batches),
        message: event.message.clone(),
    }
}

/// The process's host with the worker's progress sent into the RPC's stream. A client that went
/// away ends the run at its next batch; a report the channel cannot take at the moment is dropped.
pub struct ReportingHost {
    inner: Arc<dyn Host>,
    tx: mpsc::Sender<std::result::Result<proto::BackfillStatus, Status>>,
    closed: AtomicBool,
}

impl ReportingHost {
    #[must_use]
    pub fn new(inner: Arc<dyn Host>, tx: mpsc::Sender<std::result::Result<proto::BackfillStatus, Status>>) -> Self {
        Self { inner, tx, closed: AtomicBool::new(false) }
    }
}

impl Host for ReportingHost {
    fn http(&self, request: &HttpRequest) -> std::result::Result<HttpResponse, String> {
        self.inner.http(request)
    }

    fn ensure_llama_model(&self, model: &str) -> std::result::Result<String, String> {
        self.inner.ensure_llama_model(model)
    }

    fn embed_images(&self, model: &str, paths: &[String]) -> std::result::Result<Vec<Vec<f32>>, String> {
        self.inner.embed_images(model, paths)
    }

    fn embed_image_texts(&self, model: &str, texts: &[String]) -> std::result::Result<Vec<Vec<f32>>, String> {
        self.inner.embed_image_texts(model, texts)
    }

    fn progress(&self, event: &BackfillEvent) {
        if let Err(mpsc::error::TrySendError::Closed(_)) = self.tx.try_send(Ok(status(event))) {
            self.closed.store(true, Ordering::Relaxed);
        }
    }

    fn cancelled(&self) -> bool {
        self.closed.load(Ordering::Relaxed) || self.tx.is_closed()
    }
}

/// The request's options (`backfill`'s arguments).
#[must_use]
pub fn options(r: &proto::BackfillRequest) -> BackfillOptions {
    let positive = |n: i32| usize::try_from(n).ok().filter(|&n| n > 0);
    BackfillOptions {
        model: opt(&r.model).map(str::to_owned),
        batch_size: positive(r.batch_size),
        limit: positive(r.limit),
        skip_verify: r.skip_verify,
    }
}

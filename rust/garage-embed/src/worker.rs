//! The backfill: `garage_rag.ops.backfill` and `embed.ollama.backfill_model`, over the facade.
//!
//! For each model (or the one named): fetch a batch of the chunks it has no vector for, embed it,
//! store the vectors, and fetch again until none are left. Pure insert, so safe to re-run and to
//! interrupt. Before the first batch one probe checks the registered width against what the model
//! emits, so a mis-registered model stops at once rather than after an hour. A failed batch is
//! counted and ends that model's run: a backend that is down fails every later batch too. When a
//! model's run completes, its distilled facts get their vectors (`BackfillDistilled`).
//!
//! The events and their messages are Python's, so the app shows the same lines whichever process
//! embedded.

use std::fmt::{self, Write as _};
use std::sync::Arc;

use crate::facade::{Facade, FacadeError};
use crate::host::Host;
use crate::proto::{
    ChunkEmbeddingItem, GetEmbeddingBatchesRequest, GetEmbeddingBatchesResponse, UpdateEmbeddingsRequest,
};
use crate::provider::{self, Embedder};
use crate::settings::Settings;

/// What to embed.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct BackfillOptions {
    /// One model's slug; `None` (or `*`) for every registered model.
    pub model: Option<String>,
    /// Chunks per embedding request; `None` for `embedding.batch_size`.
    pub batch_size: Option<usize>,
    /// Stop each model after this many chunks.
    pub limit: Option<usize>,
    /// Skip the width probe.
    pub skip_verify: bool,
}

/// `complete`: nothing was pending. `skipped`: the model could not be used (`message` says why).
/// `started`/`progress`/`finished` bracket the embedding of one model's pending chunks.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    Complete,
    Skipped,
    Started,
    Progress,
    Finished,
}

impl Phase {
    pub fn name(self) -> &'static str {
        match self {
            Self::Complete => "complete",
            Self::Skipped => "skipped",
            Self::Started => "started",
            Self::Progress => "progress",
            Self::Finished => "finished",
        }
    }

    /// Whether the event ends a model's run.
    pub fn is_outcome(self) -> bool {
        matches!(self, Self::Complete | Self::Skipped | Self::Finished)
    }
}

/// One step of a backfill run (`garage_rag.ops.backfill.BackfillEvent`, `BackfillStatus`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BackfillEvent {
    pub model: String,
    pub phase: Phase,
    pub total: u64,
    pub embedded: u64,
    pub failed: u64,
    pub batches: u64,
    pub message: String,
}

impl BackfillEvent {
    fn new(model: &str, phase: Phase, message: String) -> Self {
        Self { model: model.to_string(), phase, total: 0, embedded: 0, failed: 0, batches: 0, message }
    }

    pub fn remaining(&self) -> u64 {
        self.total.saturating_sub(self.embedded + self.failed)
    }
}

/// Why a backfill stopped before every model was done.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum BackfillError {
    /// No such model, or none registered.
    NotFound(String),
    /// The facade or the model's setup failed.
    Failed(String),
    /// The host asked it to stop.
    Cancelled,
}

impl fmt::Display for BackfillError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NotFound(message) | Self::Failed(message) => f.write_str(message),
            Self::Cancelled => f.write_str("backfill cancelled"),
        }
    }
}

impl std::error::Error for BackfillError {}

impl From<FacadeError> for BackfillError {
    fn from(error: FacadeError) -> Self {
        match error {
            FacadeError::NotFound(message) => Self::NotFound(message),
            FacadeError::Failed(message) => Self::Failed(message),
        }
    }
}

/// Embeds the chunks each model (or `options.model`) has no vectors for.
///
/// Every step goes to `host.progress`; each model's `complete`/`skipped`/`finished` event is also
/// returned.
///
/// # Errors
///
/// [`BackfillError::NotFound`] for an unknown model or when none is registered;
/// [`BackfillError::Failed`] when the facade fails or a model's provider cannot be set up;
/// [`BackfillError::Cancelled`] when the host asks it to stop.
pub fn backfill(
    facade: &dyn Facade,
    settings: &Settings,
    host: &Arc<dyn Host>,
    options: &BackfillOptions,
) -> Result<Vec<BackfillEvent>, BackfillError> {
    let slugs = match options.model.as_deref() {
        Some(model) if !model.is_empty() && model != "*" => vec![model.to_string()],
        _ => facade.list_models()?.into_iter().map(|model| model.slug).collect(),
    };
    if slugs.is_empty() {
        return Err(BackfillError::NotFound("no models registered".into()));
    }
    let mut outcomes = Vec::new();
    for slug in slugs {
        let mut emit = |event: BackfillEvent| {
            host.progress(&event);
            if event.phase.is_outcome() {
                outcomes.push(event);
            }
        };
        backfill_model(facade, settings, host, options, &slug, &mut emit)?;
    }
    Ok(outcomes)
}

/// One model's run, from its first batch to its `finished` event.
struct ModelRun<'a> {
    facade: &'a dyn Facade,
    host: &'a Arc<dyn Host>,
    slug: String,
    size: usize,
    limit: Option<usize>,
}

impl ModelRun<'_> {
    /// The next batch, no larger than what is left of the limit after `done` chunks.
    fn fetch(&self, done: usize) -> Result<GetEmbeddingBatchesResponse, BackfillError> {
        let wanted = self.limit.map_or(self.size, |limit| self.size.min(limit - done));
        let wanted = i32::try_from(wanted).unwrap_or(i32::MAX);
        Ok(self.facade.get_embedding_batches(GetEmbeddingBatchesRequest {
            model_slug: self.slug.clone(),
            batch_size: wanted,
            limit: wanted,
        })?)
    }

    /// Embeds batches from `batch` on until none is left, one fails, or the limit is reached;
    /// how many chunks were stored.
    fn embed_pending(
        &self,
        mut batch: GetEmbeddingBatchesResponse,
        embedder: &dyn Embedder,
        state: &mut BackfillEvent,
        emit: &mut dyn FnMut(BackfillEvent),
    ) -> Result<usize, BackfillError> {
        let slug = &self.slug;
        let image = batch.modality == "image";
        let dims = usize::try_from(batch.dims).unwrap_or(0);
        let mut done = 0usize;
        while !batch.chunks.is_empty() {
            let count = batch.chunks.len() as u64;
            let inputs: Vec<String> = batch.chunks.iter().map(|chunk| chunk.text.clone()).collect();
            let vectors = match embed_batch(embedder, &inputs, image, dims) {
                Ok(vectors) => vectors,
                Err(error) => {
                    // Counted, never re-raised: a backend that is down fails every later batch too.
                    state.failed += count;
                    let message = format!("batch failed ({count} chunks): {error}");
                    emit(BackfillEvent { phase: Phase::Progress, message, ..state.clone() });
                    break;
                }
            };
            let embeddings = batch
                .chunks
                .iter()
                .zip(vectors)
                .map(|(chunk, vector)| ChunkEmbeddingItem { chunk_id: chunk.chunk_id, vector })
                .collect();
            let stored =
                self.facade.update_embeddings(UpdateEmbeddingsRequest { model_slug: slug.clone(), embeddings })?;
            if !stored.success {
                return Err(BackfillError::Failed(format!("Failed to update embeddings via gRPC: {}", stored.error)));
            }
            state.embedded += count;
            state.batches += 1;
            done += batch.chunks.len();
            let message =
                format!("{slug}: {}/{} ({} batches)", grouped(state.embedded), grouped(state.total), state.batches);
            emit(BackfillEvent { phase: Phase::Progress, message, ..state.clone() });
            if self.limit.is_some_and(|limit| done >= limit) || !batch.has_more {
                break;
            }
            if self.host.cancelled() {
                return Err(BackfillError::Cancelled);
            }
            batch = self.fetch(done)?;
        }
        Ok(done)
    }
}

fn backfill_model(
    facade: &dyn Facade,
    settings: &Settings,
    host: &Arc<dyn Host>,
    options: &BackfillOptions,
    slug: &str,
    emit: &mut dyn FnMut(BackfillEvent),
) -> Result<(), BackfillError> {
    if host.cancelled() {
        return Err(BackfillError::Cancelled);
    }
    let mut run = ModelRun {
        facade,
        host,
        slug: slug.to_string(),
        size: options.batch_size.filter(|size| *size > 0).unwrap_or(settings.batch_size).max(1),
        limit: options.limit.filter(|limit| *limit > 0),
    };
    let batch = run.fetch(0)?;
    run.slug.clone_from(&batch.model_slug);
    let slug = run.slug.clone();
    let total = u64::try_from(batch.total_pending).unwrap_or(0);
    let withheld = u64::try_from(batch.withheld).unwrap_or(0);
    if total == 0 {
        let message = if withheld > 0 {
            format!("{slug}: nothing to embed; {}", withheld_note(withheld))
        } else {
            format!("{slug}: already complete")
        };
        emit(BackfillEvent::new(&slug, Phase::Complete, message));
        return Ok(());
    }

    let embedder = provider::get_embedder(&batch.provider, &batch.model_ref, settings, host.clone())
        .map_err(|error| BackfillError::Failed(format!("{slug}: {error}")))?;
    if batch.modality == "image" && !embedder.embeds_images() {
        return Err(BackfillError::Failed(format!(
            "{slug} is an image model but provider {:?} embeds text only",
            batch.provider
        )));
    }
    if !options.skip_verify
        && let Some(reason) = verify(embedder.as_ref(), &slug, usize::try_from(batch.dims).unwrap_or(0))
    {
        emit(BackfillEvent { total, ..BackfillEvent::new(&slug, Phase::Skipped, reason) });
        return Ok(());
    }

    let mut state = BackfillEvent { total, ..BackfillEvent::new(&slug, Phase::Started, String::new()) };
    emit(BackfillEvent { message: format!("{slug}: embedding {} chunks", grouped(total)), ..state.clone() });
    let done = run.embed_pending(batch, embedder.as_ref(), &mut state, emit)?;
    if state.failed == 0 && run.limit.is_none_or(|limit| done < limit) {
        facade.backfill_distilled(&slug)?;
    }

    let mut summary = format!("{slug}: embedded {}", grouped(state.embedded));
    if state.failed > 0 {
        let _ = write!(summary, ", failed {}", grouped(state.failed));
    }
    if state.remaining() > 0 {
        let _ = write!(summary, ", remaining {}", grouped(state.remaining()));
    }
    if withheld > 0 {
        let _ = write!(summary, "; {}", withheld_note(withheld));
    }
    emit(BackfillEvent { phase: Phase::Finished, message: summary, ..state });
    Ok(())
}

/// Why the model cannot be used, from one probe: it fails, or its width is not the registered
/// one. Every insert would then fail the column's type check; better to stop now than after an
/// hour of work.
fn verify(embedder: &dyn Embedder, slug: &str, dims: usize) -> Option<String> {
    match embedder.probe_dims() {
        Err(error) => Some(format!("{slug}: {error}")),
        Ok(actual) if actual != dims => Some(format!(
            "{slug}: registered {dims} dims but the model emits {actual}. Re-register with --dims {actual}."
        )),
        Ok(_) => None,
    }
}

fn withheld_note(withheld: u64) -> String {
    format!("{} communication chunk(s) withheld: the provider is not on this machine", grouped(withheld))
}

/// One batch's vectors, each checked against the registered width before anything is stored: a
/// vector of the wrong size would be refused by the column anyway, and a model that emits the
/// wrong width does so for every batch.
fn embed_batch(embedder: &dyn Embedder, inputs: &[String], image: bool, dims: usize) -> Result<Vec<Vec<f32>>, String> {
    let vectors = if image { embedder.embed_images(inputs) } else { embedder.embed(inputs) };
    let vectors = vectors.map_err(|error| error.to_string())?;
    if let Some(wrong) = vectors.iter().find(|vector| vector.len() != dims) {
        return Err(format!("{} returned a {}-dim vector; registered as {dims}", embedder.model_ref(), wrong.len()));
    }
    Ok(vectors)
}

/// `1,234,567`, as Python's `{:,}`.
fn grouped(value: u64) -> String {
    let digits = value.to_string();
    let mut out = String::with_capacity(digits.len() + digits.len() / 3);
    for (index, digit) in digits.chars().enumerate() {
        if index > 0 && (digits.len() - index).is_multiple_of(3) {
            out.push(',');
        }
        out.push(digit);
    }
    out
}

#[cfg(test)]
#[allow(
    clippy::cast_possible_wrap,
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss,
    clippy::cast_precision_loss
)]
mod tests {
    use std::cell::RefCell;
    use std::collections::BTreeMap;
    use std::sync::Mutex;

    use super::*;
    use crate::host::{HttpRequest, HttpResponse};
    use crate::proto::{EmbeddingChunkItem, GetEmbeddingBatchesResponse, ModelInfo, UpdateEmbeddingsResponse};

    /// The facade over an in-memory table: chunk id → (text, is a communication).
    struct Memory {
        models: Vec<(String, String, i32, String)>,
        chunks: BTreeMap<i64, (String, bool)>,
        stored: RefCell<BTreeMap<(String, i64), Vec<f32>>>,
        distilled: RefCell<Vec<String>>,
        local: bool,
    }

    impl Memory {
        fn new(provider: &str, dims: i32, chunks: usize) -> Self {
            Self {
                models: vec![("m".into(), provider.into(), dims, "text".into())],
                chunks: (1..=chunks as i64).map(|id| (id, (format!("chunk {id}"), false))).collect(),
                stored: RefCell::default(),
                distilled: RefCell::default(),
                local: true,
            }
        }

        fn pending(&self, slug: &str, include_communications: bool) -> Vec<(i64, String)> {
            let stored = self.stored.borrow();
            self.chunks
                .iter()
                .filter(|(id, (_, communication))| {
                    !stored.contains_key(&(slug.to_string(), **id)) && (include_communications || !communication)
                })
                .map(|(id, (text, _))| (*id, text.clone()))
                .collect()
        }
    }

    impl Facade for Memory {
        fn list_models(&self) -> Result<Vec<ModelInfo>, FacadeError> {
            Ok(self.models.iter().map(|(slug, ..)| ModelInfo { slug: slug.clone(), ..ModelInfo::default() }).collect())
        }

        fn get_embedding_batches(
            &self,
            request: GetEmbeddingBatchesRequest,
        ) -> Result<GetEmbeddingBatchesResponse, FacadeError> {
            let Some((slug, provider, dims, modality)) =
                self.models.iter().find(|(slug, ..)| *slug == request.model_slug)
            else {
                return Err(FacadeError::NotFound(format!("no model {:?} registered", request.model_slug)));
            };
            let pending = self.pending(slug, self.local);
            let withheld = self.pending(slug, true).len() - pending.len();
            let chunks: Vec<EmbeddingChunkItem> = pending
                .iter()
                .take(request.batch_size as usize)
                .map(|(id, text)| EmbeddingChunkItem { chunk_id: *id, text: text.clone() })
                .collect();
            Ok(GetEmbeddingBatchesResponse {
                model_slug: slug.clone(),
                provider: provider.clone(),
                model_ref: "ref".into(),
                dims: *dims,
                total_pending: pending.len() as i64,
                has_more: pending.len() > chunks.len(),
                chunks,
                modality: modality.clone(),
                withheld: withheld as i64,
                ..GetEmbeddingBatchesResponse::default()
            })
        }

        fn update_embeddings(&self, request: UpdateEmbeddingsRequest) -> Result<UpdateEmbeddingsResponse, FacadeError> {
            let count = request.embeddings.len();
            for item in request.embeddings {
                self.stored.borrow_mut().insert((request.model_slug.clone(), item.chunk_id), item.vector);
            }
            Ok(UpdateEmbeddingsResponse { success: true, count: count as i32, error: String::new() })
        }

        fn backfill_distilled(&self, model_slug: &str) -> Result<i64, FacadeError> {
            self.distilled.borrow_mut().push(model_slug.to_string());
            Ok(0)
        }
    }

    /// An Ollama that embeds each text as `[len, 1, 0...]` of `dims`, failing on request.
    struct FakeOllama {
        dims: usize,
        fail_after: Option<usize>,
        calls: Mutex<usize>,
        events: Mutex<Vec<BackfillEvent>>,
        cancel_after: Option<usize>,
    }

    impl FakeOllama {
        fn new(dims: usize) -> Arc<Self> {
            Arc::new(Self {
                dims,
                fail_after: None,
                calls: Mutex::new(0),
                events: Mutex::default(),
                cancel_after: None,
            })
        }

        fn phases(&self) -> Vec<(&'static str, String)> {
            self.events.lock().unwrap().iter().map(|event| (event.phase.name(), event.message.clone())).collect()
        }
    }

    impl Host for FakeOllama {
        fn http(&self, request: &HttpRequest) -> Result<HttpResponse, String> {
            let mut calls = self.calls.lock().unwrap();
            *calls += 1;
            if self.fail_after.is_some_and(|after| *calls > after) {
                return Err("connection refused".into());
            }
            let body: serde_json::Value = serde_json::from_slice(&request.body).unwrap();
            let embeddings: Vec<Vec<f32>> = body["input"]
                .as_array()
                .unwrap()
                .iter()
                .map(|text| {
                    let mut vector = vec![0.0; self.dims];
                    vector[0] = text.as_str().unwrap().len() as f32;
                    vector
                })
                .collect();
            let reply = serde_json::json!({ "embeddings": embeddings });
            Ok(HttpResponse { status: 200, body: reply.to_string().into_bytes() })
        }

        fn progress(&self, event: &BackfillEvent) {
            self.events.lock().unwrap().push(event.clone());
        }

        fn cancelled(&self) -> bool {
            self.cancel_after.is_some_and(|after| self.events.lock().unwrap().len() >= after)
        }
    }

    fn run(
        facade: &Memory,
        host: Arc<FakeOllama>,
        options: &BackfillOptions,
    ) -> Result<Vec<BackfillEvent>, BackfillError> {
        let settings = Settings { batch_size: 2, ..Settings::default() };
        let host: Arc<dyn Host> = host;
        backfill(facade, &settings, &host, options)
    }

    #[test]
    fn embeds_every_pending_chunk_in_batches() {
        let facade = Memory::new("ollama", 3, 5);
        let host = FakeOllama::new(3);
        let outcomes = run(&facade, host.clone(), &BackfillOptions::default()).unwrap();
        assert_eq!(facade.stored.borrow().len(), 5);
        assert_eq!(facade.stored.borrow()[&("m".into(), 1)], vec![7.0, 0.0, 0.0]);
        assert_eq!(*facade.distilled.borrow(), vec!["m".to_string()]);
        assert_eq!(
            host.phases(),
            vec![
                ("started", "m: embedding 5 chunks".into()),
                ("progress", "m: 2/5 (1 batches)".into()),
                ("progress", "m: 4/5 (2 batches)".into()),
                ("progress", "m: 5/5 (3 batches)".into()),
                ("finished", "m: embedded 5".into()),
            ]
        );
        assert_eq!(outcomes.len(), 1);
        assert_eq!((outcomes[0].embedded, outcomes[0].batches, outcomes[0].remaining()), (5, 3, 0));
        // A second run finds nothing to do.
        let host = FakeOllama::new(3);
        run(&facade, host.clone(), &BackfillOptions::default()).unwrap();
        assert_eq!(host.phases(), vec![("complete", "m: already complete".into())]);
    }

    #[test]
    fn a_limit_stops_early_and_leaves_distilled_facts_for_later() {
        let facade = Memory::new("ollama", 3, 5);
        let host = FakeOllama::new(3);
        let options = BackfillOptions { limit: Some(3), ..BackfillOptions::default() };
        let outcomes = run(&facade, host, &options).unwrap();
        assert_eq!(facade.stored.borrow().len(), 3);
        assert!(facade.distilled.borrow().is_empty());
        assert_eq!(outcomes[0].message, "m: embedded 3, remaining 2");
    }

    #[test]
    fn a_mis_registered_width_is_skipped_before_any_batch() {
        let facade = Memory::new("ollama", 4, 5);
        let host = FakeOllama::new(3);
        let outcomes = run(&facade, host.clone(), &BackfillOptions::default()).unwrap();
        assert!(facade.stored.borrow().is_empty());
        assert_eq!(outcomes[0].phase, Phase::Skipped);
        assert_eq!(outcomes[0].message, "m: registered 4 dims but the model emits 3. Re-register with --dims 3.");
        assert_eq!(outcomes[0].total, 5);
    }

    #[test]
    fn a_failed_batch_is_counted_and_ends_the_run() {
        let facade = Memory::new("ollama", 3, 5);
        // The probe and one batch succeed; the next batch's request finds the server gone.
        let host = Arc::new(FakeOllama { fail_after: Some(2), ..Arc::into_inner(FakeOllama::new(3)).unwrap() });
        let outcomes = run(&facade, host.clone(), &BackfillOptions::default()).unwrap();
        assert_eq!(facade.stored.borrow().len(), 2);
        assert!(facade.distilled.borrow().is_empty());
        assert_eq!(outcomes[0].message, "m: embedded 2, failed 2, remaining 1");
        let failure = &host.phases()[2].1;
        assert!(
            failure.starts_with("batch failed (2 chunks): ollama embed failed for ref: cannot reach Ollama"),
            "{failure}"
        );
    }

    #[test]
    fn an_off_box_provider_reports_what_was_withheld() {
        let mut facade = Memory::new("ollama", 3, 3);
        facade.local = false;
        facade.chunks.get_mut(&2).unwrap().1 = true;
        let host = FakeOllama::new(3);
        let outcomes = run(&facade, host, &BackfillOptions::default()).unwrap();
        assert!(!facade.stored.borrow().contains_key(&("m".into(), 2)));
        assert_eq!(
            outcomes[0].message,
            "m: embedded 2; 1 communication chunk(s) withheld: the provider is not on this machine"
        );
        let host = FakeOllama::new(3);
        let outcomes = run(&facade, host, &BackfillOptions::default()).unwrap();
        assert_eq!(
            outcomes[0].message,
            "m: nothing to embed; 1 communication chunk(s) withheld: the provider is not on this machine"
        );
    }

    #[test]
    fn an_unknown_model_is_not_found_and_none_registered_too() {
        let facade = Memory::new("ollama", 3, 1);
        let options = BackfillOptions { model: Some("other".into()), ..BackfillOptions::default() };
        assert!(matches!(run(&facade, FakeOllama::new(3), &options), Err(BackfillError::NotFound(_))));
        let empty = Memory { models: Vec::new(), ..Memory::new("ollama", 3, 1) };
        let error = run(&empty, FakeOllama::new(3), &BackfillOptions::default()).unwrap_err();
        assert_eq!(error, BackfillError::NotFound("no models registered".into()));
    }

    #[test]
    fn a_text_provider_cannot_embed_an_image_model() {
        let mut facade = Memory::new("ollama", 3, 1);
        facade.models[0].3 = "image".into();
        let error = run(&facade, FakeOllama::new(3), &BackfillOptions::default()).unwrap_err();
        assert_eq!(error, BackfillError::Failed("m is an image model but provider \"ollama\" embeds text only".into()));
    }

    #[test]
    fn stops_between_batches_when_cancelled() {
        let facade = Memory::new("ollama", 3, 5);
        let host = Arc::new(FakeOllama { cancel_after: Some(2), ..Arc::into_inner(FakeOllama::new(3)).unwrap() });
        assert_eq!(run(&facade, host, &BackfillOptions::default()), Err(BackfillError::Cancelled));
        assert_eq!(facade.stored.borrow().len(), 2);
    }

    #[test]
    fn groups_thousands() {
        assert_eq!(grouped(0), "0");
        assert_eq!(grouped(999), "999");
        assert_eq!(grouped(1000), "1,000");
        assert_eq!(grouped(1_234_567), "1,234,567");
    }
}

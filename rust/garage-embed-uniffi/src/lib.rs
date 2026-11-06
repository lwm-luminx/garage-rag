//! The embed worker through UniFFI: the same three calls as `garage-embed-ffi`'s C ABI
//! (`garage_embed.h`), with typed records and errors in place of JSON, and the host as a protocol
//! the caller implements (`EmbedHost` in Swift, a class in Python) in place of a struct of C
//! function pointers.
//!
//! A pilot of UniFFI for the boundary between the XPC services and their Rust workers
//! (docs/plans/uniffi.md). It sits beside the C ABI, which the app's `GarageEmbedWorker` still uses,
//! so nothing changes until a host switches.

// UniFFI hands exported functions owned values, and the host's methods throw what their docs say.
#![allow(clippy::needless_pass_by_value, clippy::missing_errors_doc)]

use std::path::PathBuf;
use std::sync::Arc;

use garage_embed::provider::{self, BackendKind};
use garage_embed::{BackfillError, BackfillEvent, BackfillOptions, GrpcFacade, GrpcTarget, Host, Settings};

uniffi::setup_scaffolding!("garage_embed");

/// The model server a request goes to.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum Backend {
    Ollama,
    LmStudio,
    LlamaXpc,
}

impl From<BackendKind> for Backend {
    fn from(kind: BackendKind) -> Self {
        match kind {
            BackendKind::Ollama => Self::Ollama,
            BackendKind::LmStudio => Self::LmStudio,
            BackendKind::LlamaXpc => Self::LlamaXpc,
        }
    }
}

/// One header of a request.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct Header {
    pub name: String,
    pub value: String,
}

/// An HTTP request to a model server, already approved by the worker's egress rules. Send it to
/// exactly `url`: no proxy, and a redirect is the reply, never followed. A `LlamaXpc` request may
/// go over the host's own connection to LlamaXPCService instead (`path` is the route).
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct HttpRequest {
    pub backend: Backend,
    pub method: String,
    pub url: String,
    pub path: String,
    pub headers: Vec<Header>,
    pub body: Vec<u8>,
    pub timeout_seconds: f64,
}

/// The server's reply, whatever its status.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct HttpResponse {
    pub status: u16,
    pub body: Vec<u8>,
}

/// Why a host call has no answer. Thrown by the host's methods.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Error)]
pub enum HostError {
    /// The host could not do it; `reason` says why.
    Failed { reason: String },
}

impl std::fmt::Display for HostError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Failed { reason } => f.write_str(reason),
        }
    }
}

impl std::error::Error for HostError {}

// A host method that fails in a way the bindings did not expect (a Swift error of another type).
impl From<uniffi::UnexpectedUniFFICallbackError> for HostError {
    fn from(error: uniffi::UnexpectedUniFFICallbackError) -> Self {
        Self::Failed { reason: error.reason }
    }
}

/// Where a backfill stands (`BackfillStatus` in garage.proto).
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum Phase {
    /// Nothing was pending.
    Complete,
    /// The model could not be used; `message` says why.
    Skipped,
    Started,
    Progress,
    Finished,
}

/// One step of a backfill.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct BackfillStatus {
    pub model_slug: String,
    pub phase: Phase,
    pub total: u64,
    pub embedded: u64,
    pub failed: u64,
    pub remaining: u64,
    pub batches: u64,
    pub message: String,
}

impl From<&BackfillEvent> for BackfillStatus {
    fn from(event: &BackfillEvent) -> Self {
        use garage_embed::Phase as P;
        Self {
            model_slug: event.model.clone(),
            phase: match event.phase {
                P::Complete => Phase::Complete,
                P::Skipped => Phase::Skipped,
                P::Started => Phase::Started,
                P::Progress => Phase::Progress,
                P::Finished => Phase::Finished,
            },
            total: event.total,
            embedded: event.embedded,
            failed: event.failed,
            remaining: event.remaining(),
            batches: event.batches,
            message: event.message.clone(),
        }
    }
}

/// The process the worker runs in: the Swift service, or a test. Every method is called on the
/// thread that called into the worker.
#[uniffi::export(with_foreign)]
pub trait EmbedHost: Send + Sync {
    /// Sends `request` and returns the reply. Throws only when no reply came.
    fn http(&self, request: HttpRequest) -> Result<HttpResponse, HostError>;

    /// LlamaXPCService said `model` is not loaded; load it. Returns what was done.
    fn ensure_llama_model(&self, model: String) -> Result<String, HostError>;

    /// An image model's image tower over the files at `paths`, which the host reads.
    fn embed_images(&self, model: String, paths: Vec<String>) -> Result<Vec<Vec<f32>>, HostError>;

    /// An image model's text tower.
    fn embed_image_texts(&self, model: String, texts: Vec<String>) -> Result<Vec<Vec<f32>>, HostError>;

    /// One step of a backfill, as it happens.
    fn progress(&self, status: BackfillStatus);

    /// Whether to stop; asked between batches.
    fn cancelled(&self) -> bool;
}

/// [`EmbedHost`] behind the worker's [`Host`] trait.
struct ForeignHost(Arc<dyn EmbedHost>);

impl Host for ForeignHost {
    fn http(&self, request: &garage_embed::HttpRequest) -> Result<garage_embed::HttpResponse, String> {
        let request = HttpRequest {
            backend: request.backend.into(),
            method: request.method.to_owned(),
            url: request.url.clone(),
            path: request.path.clone(),
            headers: request
                .headers
                .iter()
                .map(|(name, value)| Header { name: name.clone(), value: value.clone() })
                .collect(),
            body: request.body.clone(),
            timeout_seconds: request.timeout.as_secs_f64(),
        };
        let reply = self.0.http(request).map_err(|error| error.to_string())?;
        Ok(garage_embed::HttpResponse { status: reply.status, body: reply.body })
    }

    fn ensure_llama_model(&self, model: &str) -> Result<String, String> {
        self.0.ensure_llama_model(model.to_owned()).map_err(|error| error.to_string())
    }

    fn embed_images(&self, model: &str, paths: &[String]) -> Result<Vec<Vec<f32>>, String> {
        self.0.embed_images(model.to_owned(), paths.to_vec()).map_err(|error| error.to_string())
    }

    fn embed_image_texts(&self, model: &str, texts: &[String]) -> Result<Vec<Vec<f32>>, String> {
        self.0.embed_image_texts(model.to_owned(), texts.to_vec()).map_err(|error| error.to_string())
    }

    fn progress(&self, event: &BackfillEvent) {
        self.0.progress(event.into());
    }

    fn cancelled(&self) -> bool {
        self.0.cancelled()
    }
}

/// How to reach GarageService.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum Endpoint {
    /// Its Unix-domain socket (the app's `s/grpc`).
    Socket { path: String },
    /// A TCP port, for a backend started by hand.
    Tcp { host: String, port: u16 },
}

/// GarageService's address and the per-launch `GARAGE_GRPC_TOKEN`.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct Connection {
    pub endpoint: Endpoint,
    pub token: Option<String>,
}

/// `embedding.*`; a field left out keeps Python's default.
#[derive(Clone, Debug, Default, PartialEq, Eq, uniffi::Record)]
pub struct EmbedSettings {
    pub ollama_host: Option<String>,
    pub lmstudio_host: Option<String>,
    pub llama_host: Option<String>,
    /// LM Studio's token (a secret).
    pub lmstudio_api_token: Option<String>,
    pub batch_size: Option<u32>,
}

impl From<&EmbedSettings> for Settings {
    fn from(given: &EmbedSettings) -> Self {
        let mut settings = Settings::default();
        let text = |value: &Option<String>| value.clone().filter(|value| !value.is_empty());
        if let Some(host) = text(&given.ollama_host) {
            settings.ollama_host = host;
        }
        if let Some(host) = text(&given.lmstudio_host) {
            settings.lmstudio_host = host;
        }
        if let Some(host) = text(&given.llama_host) {
            settings.llama_host = host;
        }
        settings.lmstudio_api_token = text(&given.lmstudio_api_token);
        if let Some(size) = given.batch_size.filter(|size| *size > 0) {
            settings.batch_size = usize::try_from(size).unwrap_or(settings.batch_size);
        }
        settings
    }
}

/// Where the worker's settings come from.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum SettingsSource {
    /// The backend's own `embedding.*`, through `GetSetting`, so the worker and Python never disagree.
    Service,
    /// These.
    Given { settings: EmbedSettings },
}

/// What to embed.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct BackfillRequest {
    pub connection: Connection,
    pub settings: SettingsSource,
    /// LM Studio's token from the app's Keychain, over whatever `settings` found (a secret).
    pub lmstudio_api_token: Option<String>,
    /// One model's slug; none (or `*`) for every registered model.
    pub model: Option<String>,
    pub batch_size: Option<u32>,
    pub limit: Option<u32>,
    pub skip_verify: bool,
}

/// A model GarageService has registered.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct RegisteredModel {
    pub slug: String,
    pub provider: String,
    pub model_ref: String,
    pub dims: i32,
}

/// Why a call failed: the C ABI's statuses, as errors.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Error)]
pub enum EmbedError {
    /// The work failed (GarageService, a provider's setup, the embedding).
    Failed { message: String },
    /// The model named does not exist, or none is registered.
    NotFound { message: String },
    /// The host's `cancelled` said to stop.
    Cancelled,
}

impl std::fmt::Display for EmbedError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Failed { message } | Self::NotFound { message } => f.write_str(message),
            Self::Cancelled => f.write_str("backfill cancelled"),
        }
    }
}

impl std::error::Error for EmbedError {}

fn failed(error: impl std::fmt::Display) -> EmbedError {
    EmbedError::Failed { message: error.to_string() }
}

fn connect(connection: &Connection) -> Result<GrpcFacade, EmbedError> {
    let target = match &connection.endpoint {
        Endpoint::Socket { path } => GrpcTarget::Socket(PathBuf::from(path)),
        Endpoint::Tcp { host, port } => GrpcTarget::Tcp { host: host.clone(), port: *port },
    };
    GrpcFacade::connect(&target, connection.token.as_deref()).map_err(failed)
}

fn size(value: Option<u32>) -> Option<usize> {
    value.filter(|value| *value > 0).and_then(|value| usize::try_from(value).ok())
}

/// Embeds the chunks each model (or the one named) has no vectors for. Every step goes to
/// `host.progress`; each model's complete, skipped or finished step is also returned.
///
/// # Errors
///
/// [`EmbedError`] as the C ABI's statuses describe them.
#[uniffi::export]
pub fn backfill(request: BackfillRequest, host: Arc<dyn EmbedHost>) -> Result<Vec<BackfillStatus>, EmbedError> {
    let facade = connect(&request.connection)?;
    let mut settings = match &request.settings {
        SettingsSource::Service => Settings::from_service(|name| facade.get_setting(name)),
        SettingsSource::Given { settings } => settings.into(),
    };
    if let Some(token) = request.lmstudio_api_token.filter(|token| !token.is_empty()) {
        settings.lmstudio_api_token = Some(token);
    }
    let options = BackfillOptions {
        model: request.model,
        batch_size: size(request.batch_size),
        limit: size(request.limit),
        skip_verify: request.skip_verify,
    };
    let host: Arc<dyn Host> = Arc::new(ForeignHost(host));
    match garage_embed::backfill(&facade, &settings, &host, &options) {
        Ok(outcomes) => Ok(outcomes.iter().map(BackfillStatus::from).collect()),
        Err(BackfillError::NotFound(message)) => Err(EmbedError::NotFound { message }),
        Err(BackfillError::Failed(message)) => Err(EmbedError::Failed { message }),
        Err(BackfillError::Cancelled) => Err(EmbedError::Cancelled),
    }
}

/// The models GarageService has registered, which also shows the worker reaches it.
///
/// # Errors
///
/// [`EmbedError::Failed`] when GarageService cannot be reached.
#[uniffi::export]
pub fn models(connection: Connection) -> Result<Vec<RegisteredModel>, EmbedError> {
    let facade = connect(&connection)?;
    let models = garage_embed::Facade::list_models(&facade).map_err(failed)?;
    Ok(models
        .into_iter()
        .map(|model| RegisteredModel {
            slug: model.slug,
            provider: model.provider,
            model_ref: model.model_ref,
            dims: model.dims,
        })
        .collect())
}

/// Embeds a few texts with one provider, for a self test.
///
/// # Errors
///
/// [`EmbedError::Failed`] when the provider cannot be set up or the embedding fails.
#[uniffi::export]
pub fn embed_texts(
    provider: String,
    model_ref: String,
    texts: Vec<String>,
    settings: EmbedSettings,
    host: Arc<dyn EmbedHost>,
) -> Result<Vec<Vec<f32>>, EmbedError> {
    let host: Arc<dyn Host> = Arc::new(ForeignHost(host));
    let embedder = provider::get_embedder(&provider, &model_ref, &(&settings).into(), host).map_err(failed)?;
    embedder.embed(&texts).map_err(failed)
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use super::*;

    /// A host that answers Ollama's /api/embed with one vector per input, and records each request.
    #[derive(Default)]
    struct FakeOllama {
        requests: Mutex<Vec<HttpRequest>>,
    }

    impl EmbedHost for FakeOllama {
        fn http(&self, request: HttpRequest) -> Result<HttpResponse, HostError> {
            let body = String::from_utf8_lossy(&request.body).into_owned();
            let inputs = body.matches("\"hello").count().max(1);
            self.requests.lock().expect("lock").push(request);
            let vectors = vec!["[0.5,0.25]"; inputs].join(",");
            Ok(HttpResponse { status: 200, body: format!("{{\"embeddings\":[{vectors}]}}").into_bytes() })
        }

        fn ensure_llama_model(&self, _: String) -> Result<String, HostError> {
            Err(HostError::Failed { reason: "no loader".into() })
        }

        fn embed_images(&self, _: String, _: Vec<String>) -> Result<Vec<Vec<f32>>, HostError> {
            Err(HostError::Failed { reason: "no images".into() })
        }

        fn embed_image_texts(&self, _: String, _: Vec<String>) -> Result<Vec<Vec<f32>>, HostError> {
            Err(HostError::Failed { reason: "no images".into() })
        }

        fn progress(&self, _: BackfillStatus) {}

        fn cancelled(&self) -> bool {
            false
        }
    }

    #[test]
    fn embeds_through_the_host() {
        let host = Arc::new(FakeOllama::default());
        let vectors = embed_texts(
            "ollama".into(),
            "nomic-embed-text".into(),
            vec!["hello".into(), "hello again".into()],
            EmbedSettings::default(),
            host.clone(),
        )
        .expect("embed");
        assert_eq!(vectors, vec![vec![0.5, 0.25], vec![0.5, 0.25]]);
        let requests = host.requests.lock().expect("lock");
        assert_eq!(requests.len(), 1);
        assert_eq!(requests[0].backend, Backend::Ollama);
        assert_eq!(requests[0].url, "http://localhost:11434/api/embed");
    }

    #[test]
    fn an_unknown_provider_fails() {
        let settings = EmbedSettings { ollama_host: Some("http://localhost:11434".into()), ..EmbedSettings::default() };
        let error = embed_texts("nope".into(), "m".into(), vec![], settings, Arc::new(FakeOllama::default()));
        assert!(matches!(error, Err(EmbedError::Failed { .. })));
    }
}

//! The embedding providers: `garage_rag.embed`'s backends and the HTTP client under them
//! (`garage_rag.inference.client`), with the same routes, errors and messages.
//!
//! * `ollama`: `POST /api/embed` (`{"model", "input"}` → `{"embeddings"}`), Ollama's native route,
//!   which the vectors already stored came from.
//! * `lmstudio`: `POST /v1/embeddings`, with two retries of a transient failure and its bearer
//!   token when one is configured.
//! * `llama_xpc`: `POST /v1/embeddings` on LlamaXPCService (loopback only), loading the model on
//!   demand when the service answers that it is not loaded.
//! * `image_xpc`: the app's image embedding service, through the host.

use std::fmt;
use std::sync::Arc;
use std::time::Duration;

use serde_json::{Value, json};

use crate::egress::{self, EgressBlocked};
use crate::host::{Host, HttpRequest};
use crate::settings::Settings;

/// Providers the worker knows, as `garage_rag.embed.factory.PROVIDERS`.
pub const PROVIDERS: [&str; 4] = ["image_xpc", "llama_xpc", "lmstudio", "ollama"];

/// A model server reached over HTTP.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum BackendKind {
    Ollama,
    LmStudio,
    LlamaXpc,
}

impl BackendKind {
    /// The provider's name in the configuration and the model registry.
    pub fn name(self) -> &'static str {
        match self {
            Self::Ollama => "ollama",
            Self::LmStudio => "lmstudio",
            Self::LlamaXpc => "llama_xpc",
        }
    }

    /// The server's name in messages.
    pub fn label(self) -> &'static str {
        match self {
            Self::Ollama => "Ollama",
            Self::LmStudio => "LM Studio",
            Self::LlamaXpc => "LlamaXPCService",
        }
    }
}

/// The embedding backend could not produce vectors: the one error the worker catches from a
/// provider, as `garage_rag.embed.base.EmbeddingError`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EmbedError(pub String);

impl fmt::Display for EmbedError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for EmbedError {}

/// One registered model's way of turning text, or image files, into vectors.
pub trait Embedder: Send + Sync {
    fn provider(&self) -> &'static str;
    fn model_ref(&self) -> &str;

    /// One vector per text, in order.
    ///
    /// # Errors
    ///
    /// [`EmbedError`] naming the provider and model.
    fn embed(&self, texts: &[String]) -> Result<Vec<Vec<f32>>, EmbedError>;

    /// Whether the model embeds images ([`Embedder::embed_images`]).
    fn embeds_images(&self) -> bool {
        false
    }

    /// One vector per image file, in order.
    ///
    /// # Errors
    ///
    /// [`EmbedError`]; a text model refuses.
    fn embed_images(&self, paths: &[String]) -> Result<Vec<Vec<f32>>, EmbedError> {
        let _ = paths;
        Err(EmbedError(format!("{} embeds text only", self.provider())))
    }

    /// The model's output width, from embedding a short probe string.
    ///
    /// # Errors
    ///
    /// [`EmbedError`] when the probe fails or comes back empty.
    fn probe_dims(&self) -> Result<usize, EmbedError> {
        let vectors = self.embed(&["dimension probe".to_string()])?;
        match vectors.first() {
            Some(vector) if !vector.is_empty() => Ok(vector.len()),
            _ => Err(EmbedError(format!(
                "{} probe returned an empty embedding for {:?}",
                self.provider(),
                self.model_ref()
            ))),
        }
    }
}

/// Whether the provider embeds on this machine, so communications may be sent to it
/// (`garage_rag.embed.factory.provider_is_local`).
pub fn provider_is_local(provider: &str, settings: &Settings) -> bool {
    match provider {
        "llama_xpc" | "image_xpc" => true,
        "ollama" => egress::allows_communications(&settings.ollama_host),
        "lmstudio" => egress::allows_communications(&settings.lmstudio_host),
        _ => false,
    }
}

/// Why a provider could not be set up: unknown, or its server is not an approved destination.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ProviderError {
    Unknown(String),
    Refused(EgressBlocked),
}

impl fmt::Display for ProviderError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unknown(provider) => {
                write!(f, "unknown embedding provider {provider:?}; supported: {}", PROVIDERS.join(", "))
            }
            Self::Refused(blocked) => blocked.fmt(f),
        }
    }
}

impl std::error::Error for ProviderError {}

/// The embedder for `provider` and `model_ref` (`garage_rag.embed.factory.get_embedder`).
///
/// # Errors
///
/// [`ProviderError`] for an unknown provider, or one whose server the egress rules refuse.
pub fn get_embedder(
    provider: &str,
    model_ref: &str,
    settings: &Settings,
    host: Arc<dyn Host>,
) -> Result<Box<dyn Embedder>, ProviderError> {
    let backend = match provider {
        "ollama" => Backend::new(BackendKind::Ollama, &settings.ollama_host, None, 0),
        "lmstudio" => {
            // Two retries on no reply or HTTP 408/409/429/5xx, as the openai SDK it replaced made.
            Backend::new(BackendKind::LmStudio, &settings.lmstudio_host, settings.lmstudio_api_token.clone(), 2)
        }
        "llama_xpc" => Backend::new(BackendKind::LlamaXpc, &settings.llama_host, None, 0),
        "image_xpc" => return Ok(Box::new(ImageXpcEmbedder { model_ref: model_ref.to_string(), host })),
        other => return Err(ProviderError::Unknown(other.to_string())),
    };
    let purpose = format!("inference:{}", backend.kind.name());
    egress::check_destination(&backend.base_url, &purpose, backend.kind == BackendKind::LlamaXpc, settings)
        .map_err(ProviderError::Refused)?;
    Ok(Box::new(HttpEmbedder { server: ModelServer { backend, host }, model_ref: model_ref.to_string() }))
}

/// Where one inference server is and how to talk to it (`garage_rag.inference.Backend`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Backend {
    pub kind: BackendKind,
    /// The server root: scheme added when missing, no trailing slash, no trailing `/v1`.
    pub base_url: String,
    pub token: Option<String>,
    pub max_retries: u32,
    pub timeout: Duration,
}

impl Backend {
    pub fn new(kind: BackendKind, base_url: &str, token: Option<String>, max_retries: u32) -> Self {
        Self {
            kind,
            base_url: normalise_base_url(base_url),
            token: token.filter(|token| !token.is_empty()),
            max_retries,
            // Generous: a first request may load a model, as LM Studio does on first use.
            timeout: Duration::from_secs(600),
        }
    }
}

fn normalise_base_url(url: &str) -> String {
    let url = url.trim();
    let mut url = if url.contains("://") { url.to_string() } else { format!("http://{url}") };
    while url.ends_with('/') {
        url.pop();
    }
    if let Some(stripped) = url.strip_suffix("/v1") {
        url = stripped.to_string();
    }
    url
}

/// HTTP 408, 409 and 429 are retried, as is any 5xx and no reply at all.
fn is_transient(status: u16) -> bool {
    matches!(status, 408 | 409 | 429) || status >= 500
}

/// An error from the server, with the HTTP status it came with.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HttpFailure {
    pub status: u16,
    pub message: String,
}

/// One model server and the host that carries its requests: `garage_rag.inference.InferenceClient`'s
/// transport, shared by the embedders here and the MCP server's chat model.
#[derive(Clone)]
pub struct ModelServer {
    pub backend: Backend,
    pub host: Arc<dyn Host>,
}

/// Ollama, LM Studio and LlamaXPCService.
struct HttpEmbedder {
    server: ModelServer,
    model_ref: String,
}

impl std::ops::Deref for HttpEmbedder {
    type Target = ModelServer;

    fn deref(&self) -> &ModelServer {
        &self.server
    }
}

impl ModelServer {
    /// One reply, after up to `max_retries` retries of a transient failure.
    ///
    /// # Errors
    ///
    /// [`HttpFailure`] (503) when no reply came.
    pub fn send(&self, method: &'static str, path: &str, body: &Value) -> Result<(u16, Vec<u8>), HttpFailure> {
        let mut headers = vec![("Accept".to_string(), "application/json".to_string())];
        headers.push(("Content-Type".to_string(), "application/json".to_string()));
        if let Some(token) = &self.backend.token {
            headers.push(("Authorization".to_string(), format!("Bearer {token}")));
        }
        let request = HttpRequest {
            backend: self.backend.kind,
            method,
            url: format!("{}{path}", self.backend.base_url),
            path: path.to_string(),
            headers,
            body: body.to_string().into_bytes(),
            timeout: self.backend.timeout,
        };
        let mut attempt = 0;
        loop {
            let last = attempt == self.backend.max_retries;
            match self.host.http(&request) {
                Ok(reply) if last || !is_transient(reply.status) => return Ok((reply.status, reply.body)),
                Err(reason) if last => {
                    return Err(HttpFailure {
                        status: 503,
                        message: format!(
                            "cannot reach {} at {}: {reason}",
                            self.backend.kind.label(),
                            self.backend.base_url
                        ),
                    });
                }
                // A transient failure, with a retry left.
                _ => {}
            }
            std::thread::sleep(Duration::from_millis(500 << attempt));
            attempt += 1;
        }
    }

    /// One request whose reply must be a 2xx JSON object without an `error` key.
    ///
    /// # Errors
    ///
    /// [`HttpFailure`] with the server's message and status.
    pub fn call(
        &self,
        method: &'static str,
        path: &str,
        body: &Value,
    ) -> Result<serde_json::Map<String, Value>, HttpFailure> {
        let label = self.backend.kind.label();
        let (status, reply) = self.send(method, path, body)?;
        let ok = (200..300).contains(&status);
        let payload: Value = if reply.is_empty() {
            json!({})
        } else {
            match serde_json::from_slice(&reply) {
                Ok(payload) => payload,
                Err(_) if ok => {
                    return Err(HttpFailure {
                        status: 502,
                        message: format!("{method} {path}: non-JSON reply from {label} (HTTP {status})"),
                    });
                }
                // An error page from a proxy or a crashed server: keep a readable snippet.
                Err(_) => {
                    let snippet = String::from_utf8_lossy(&reply[..reply.len().min(200)]).trim().to_string();
                    json!({ "error": snippet })
                }
            }
        };
        let detail = error_detail(&payload);
        let place = format!("{method} {path}");
        if !ok {
            let text = detail.unwrap_or_else(|| format!("HTTP {status}"));
            if status == 401 || status == 403 {
                let hint = if self.backend.kind == BackendKind::LmStudio {
                    "; set GARAGE_LMSTUDIO_API_TOKEN or embedding.lmstudio_api_token_file"
                } else {
                    ""
                };
                return Err(HttpFailure {
                    status,
                    message: format!("{place}: {label} refused the request (HTTP {status}): {text}{hint}"),
                });
            }
            return Err(HttpFailure { status, message: format!("{place}: {text}") });
        }
        let has_error = payload.get("error").is_some_and(|error| match error {
            Value::Null | Value::Bool(false) => false,
            Value::String(text) => !text.is_empty(),
            Value::Object(map) => !map.is_empty(),
            Value::Array(items) => !items.is_empty(),
            _ => true,
        });
        if has_error {
            // LM Studio: HTTP 200 {"error": "Unexpected endpoint or method. ..."}.
            let text = detail.unwrap_or_else(|| payload["error"].to_string());
            return Err(HttpFailure {
                status,
                message: format!("{place}: {label} replied HTTP {status} with an error: {text}"),
            });
        }
        match payload {
            Value::Object(map) => Ok(map),
            other => Err(HttpFailure {
                status: 502,
                message: format!("{place}: expected a JSON object, got {}", json_type(&other)),
            }),
        }
    }
}

impl HttpEmbedder {
    fn embed_once(&self, texts: &[String]) -> Result<Vec<Vec<f32>>, HttpFailure> {
        if self.backend.kind == BackendKind::Ollama {
            let path = "/api/embed";
            let payload = self.call("POST", path, &json!({ "model": self.model_ref, "input": texts }))?;
            let Some(Value::Array(embeddings)) = payload.get("embeddings") else {
                return Err(bad_reply(format!("POST {path}: reply has no 'embeddings' list")));
            };
            let vectors = embeddings
                .iter()
                .map(floats)
                .collect::<Option<Vec<_>>>()
                .ok_or_else(|| bad_reply(format!("POST {path}: malformed embedding")))?;
            return check_count(vectors, texts.len(), path);
        }
        let path = "/v1/embeddings";
        let payload = self.call("POST", path, &json!({ "input": texts, "model": self.model_ref }))?;
        let Some(Value::Array(data)) = payload.get("data") else {
            return Err(bad_reply(format!("POST {path}: reply has no 'data' list")));
        };
        let mut items = data
            .iter()
            .map(|item| Some((item.get("index")?.as_i64()?, floats(item.get("embedding")?)?)))
            .collect::<Option<Vec<_>>>()
            .ok_or_else(|| bad_reply(format!("POST {path}: malformed embedding item")))?;
        items.sort_by_key(|(index, _)| *index);
        check_count(items.into_iter().map(|(_, vector)| vector).collect(), texts.len(), path)
    }

    /// `embed_once`, and for LlamaXPCService once more after loading a model it did not have.
    fn embed_loading(&self, texts: &[String]) -> Result<Vec<Vec<f32>>, String> {
        match self.embed_once(texts) {
            Ok(vectors) => Ok(vectors),
            Err(failure) if self.backend.kind == BackendKind::LlamaXpc && is_model_not_loaded(&failure) => {
                match self.host.ensure_llama_model(&self.model_ref) {
                    Ok(_) => self.embed_once(texts).map_err(|failure| failure.message),
                    Err(reason) => Err(format!("{}; loading it on demand failed: {reason}", failure.message)),
                }
            }
            Err(failure) => Err(failure.message),
        }
    }
}

impl Embedder for HttpEmbedder {
    fn provider(&self) -> &'static str {
        self.backend.kind.name()
    }

    fn model_ref(&self) -> &str {
        &self.model_ref
    }

    fn embed(&self, texts: &[String]) -> Result<Vec<Vec<f32>>, EmbedError> {
        if texts.is_empty() {
            return Ok(Vec::new());
        }
        let vectors = self.embed_loading(texts).map_err(|reason| {
            EmbedError(format!("{} embed failed for {}: {reason}", self.provider(), self.model_ref))
        })?;
        expect_one_each(vectors, texts.len(), &self.model_ref, "inputs")
    }
}

/// The app's image embedding service (`garage_rag.embed.image_xpc`).
struct ImageXpcEmbedder {
    model_ref: String,
    host: Arc<dyn Host>,
}

impl Embedder for ImageXpcEmbedder {
    fn provider(&self) -> &'static str {
        "image_xpc"
    }

    fn model_ref(&self) -> &str {
        &self.model_ref
    }

    fn embed(&self, texts: &[String]) -> Result<Vec<Vec<f32>>, EmbedError> {
        if texts.is_empty() {
            return Ok(Vec::new());
        }
        let vectors = self.host.embed_image_texts(&self.model_ref, texts).map_err(EmbedError)?;
        expect_one_each(vectors, texts.len(), &self.model_ref, "inputs")
    }

    fn embeds_images(&self) -> bool {
        true
    }

    fn embed_images(&self, paths: &[String]) -> Result<Vec<Vec<f32>>, EmbedError> {
        if paths.is_empty() {
            return Ok(Vec::new());
        }
        let vectors = self.host.embed_images(&self.model_ref, paths).map_err(EmbedError)?;
        expect_one_each(vectors, paths.len(), &self.model_ref, "images")
    }
}

fn expect_one_each(
    vectors: Vec<Vec<f32>>,
    wanted: usize,
    model_ref: &str,
    what: &str,
) -> Result<Vec<Vec<f32>>, EmbedError> {
    if vectors.len() == wanted {
        Ok(vectors)
    } else {
        Err(EmbedError(format!("{model_ref} returned {} vectors for {wanted} {what}", vectors.len())))
    }
}

/// Whether LlamaXPCService refused because its model is not resident: 503 `no model loaded`
/// when nothing is, 404 `model X is not loaded (loaded: ...)` when others are.
pub fn is_model_not_loaded(failure: &HttpFailure) -> bool {
    let text = failure.message.to_lowercase();
    matches!(failure.status, 404 | 503) && (text.contains("no model loaded") || text.contains("is not loaded"))
}

/// The message out of an error body: `{"error": {"message"}}` (OpenAI, llama-server, LM Studio)
/// or `{"error": "text"}` (Ollama, LM Studio's unknown routes).
fn error_detail(payload: &Value) -> Option<String> {
    match payload.get("error")? {
        Value::Object(error) => match error.get("message")? {
            Value::String(message) if !message.is_empty() => Some(message.clone()),
            Value::String(_) | Value::Null => None,
            other => Some(other.to_string()),
        },
        Value::String(text) if !text.is_empty() => Some(text.clone()),
        _ => None,
    }
}

fn floats(value: &Value) -> Option<Vec<f32>> {
    #[allow(clippy::cast_possible_truncation)]
    value.as_array()?.iter().map(|x| x.as_f64().map(|x| x as f32)).collect()
}

fn check_count(vectors: Vec<Vec<f32>>, inputs: usize, path: &str) -> Result<Vec<Vec<f32>>, HttpFailure> {
    if vectors.len() == inputs {
        Ok(vectors)
    } else {
        Err(bad_reply(format!("POST {path}: {} vectors for {inputs} inputs", vectors.len())))
    }
}

pub fn bad_reply(message: String) -> HttpFailure {
    HttpFailure { status: 502, message }
}

fn json_type(value: &Value) -> &'static str {
    match value {
        Value::Null => "NoneType",
        Value::Bool(_) => "bool",
        Value::Number(number) if number.is_f64() => "float",
        Value::Number(_) => "int",
        Value::String(_) => "str",
        Value::Array(_) => "list",
        Value::Object(_) => "dict",
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use super::*;
    use crate::host::HttpResponse;

    /// Answers each request with the next canned reply, and records what was asked.
    #[derive(Default)]
    struct Canned {
        replies: Mutex<Vec<Result<HttpResponse, String>>>,
        requests: Mutex<Vec<HttpRequest>>,
        loads: Mutex<Vec<String>>,
    }

    impl Canned {
        fn with(replies: Vec<Result<(u16, Value), String>>) -> Arc<Self> {
            let replies = replies
                .into_iter()
                .rev()
                .map(|reply| reply.map(|(status, body)| HttpResponse { status, body: body.to_string().into_bytes() }))
                .collect();
            Arc::new(Self { replies: Mutex::new(replies), ..Self::default() })
        }

        fn requests(&self) -> Vec<HttpRequest> {
            self.requests.lock().unwrap().clone()
        }
    }

    impl Host for Canned {
        fn http(&self, request: &HttpRequest) -> Result<HttpResponse, String> {
            self.requests.lock().unwrap().push(request.clone());
            self.replies.lock().unwrap().pop().expect("an unexpected request")
        }

        fn ensure_llama_model(&self, model: &str) -> Result<String, String> {
            self.loads.lock().unwrap().push(model.to_string());
            Ok("loaded".into())
        }
    }

    fn texts(items: &[&str]) -> Vec<String> {
        items.iter().map(ToString::to_string).collect()
    }

    fn embedder(provider: &str, host: &Arc<Canned>, settings: &Settings) -> Box<dyn Embedder> {
        get_embedder(provider, "m", settings, host.clone()).unwrap()
    }

    #[test]
    fn ollama_posts_to_its_native_route() {
        let host = Canned::with(vec![Ok((200, json!({"embeddings": [[1.0, 2.0], [3.0, 4.0]]})))]);
        let vectors = embedder("ollama", &host, &Settings::default()).embed(&texts(&["a", "b"])).unwrap();
        assert_eq!(vectors, vec![vec![1.0, 2.0], vec![3.0, 4.0]]);
        let request = &host.requests()[0];
        assert_eq!(request.url, "http://localhost:11434/api/embed");
        assert_eq!(request.path, "/api/embed");
        let body: Value = serde_json::from_slice(&request.body).unwrap();
        assert_eq!(body, json!({"model": "m", "input": ["a", "b"]}));
    }

    #[test]
    fn openai_route_orders_by_index_and_sends_the_token() {
        let settings = Settings { lmstudio_api_token: Some("secret".into()), ..Settings::default() };
        let reply = json!({"data": [{"index": 1, "embedding": [2.0]}, {"index": 0, "embedding": [1.0]}]});
        let host = Canned::with(vec![Ok((200, reply))]);
        let vectors = embedder("lmstudio", &host, &settings).embed(&texts(&["a", "b"])).unwrap();
        assert_eq!(vectors, vec![vec![1.0], vec![2.0]]);
        let request = &host.requests()[0];
        assert_eq!(request.url, "http://localhost:1234/v1/embeddings");
        assert!(request.headers.contains(&("Authorization".into(), "Bearer secret".into())));
    }

    #[test]
    fn lmstudio_retries_a_transient_failure_twice() {
        let host = Canned::with(vec![
            Err("connection refused".into()),
            Ok((503, json!({"error": "busy"}))),
            Ok((200, json!({"data": [{"index": 0, "embedding": [1.0]}]}))),
        ]);
        let vectors = embedder("lmstudio", &host, &Settings::default()).embed(&texts(&["a"])).unwrap();
        assert_eq!(vectors, vec![vec![1.0]]);
        assert_eq!(host.requests().len(), 3);
    }

    #[test]
    fn errors_read_as_pythons() {
        let cases = [
            (Ok((500, json!({"error": {"message": "boom"}}))), "ollama embed failed for m: POST /api/embed: boom"),
            (
                Ok((200, json!({"error": "Unexpected endpoint or method."}))),
                "ollama embed failed for m: POST /api/embed: Ollama replied HTTP 200 with an error: Unexpected endpoint or method.",
            ),
            (
                Ok((200, json!({"nope": 1}))),
                "ollama embed failed for m: POST /api/embed: reply has no 'embeddings' list",
            ),
            (
                Ok((200, json!({"embeddings": [[1.0], [2.0]]}))),
                "ollama embed failed for m: POST /api/embed: 2 vectors for 1 inputs",
            ),
            (
                Err("connection refused".to_string()),
                "ollama embed failed for m: cannot reach Ollama at http://localhost:11434: connection refused",
            ),
        ];
        for (reply, expected) in cases {
            let host = Canned::with(vec![reply]);
            let error = embedder("ollama", &host, &Settings::default()).embed(&texts(&["a"])).unwrap_err();
            assert_eq!(error.0, expected);
        }
    }

    #[test]
    fn an_lmstudio_auth_failure_says_where_the_token_goes() {
        let host = Canned::with(vec![Ok((401, json!({"error": "unauthorized"})))]);
        let error =
            get_embedder("lmstudio", "m", &Settings::default(), host).unwrap().embed(&texts(&["a"])).unwrap_err();
        assert!(
            error.0.contains("LM Studio refused the request (HTTP 401): unauthorized; set GARAGE_LMSTUDIO_API_TOKEN"),
            "{error}"
        );
    }

    #[test]
    fn llama_xpc_loads_a_missing_model_and_asks_again() {
        let host = Canned::with(vec![
            Ok((404, json!({"error": {"message": "model m is not loaded (loaded: other)"}}))),
            Ok((200, json!({"data": [{"index": 0, "embedding": [1.0, 0.0]}]}))),
        ]);
        let vectors = embedder("llama_xpc", &host, &Settings::default()).embed(&texts(&["a"])).unwrap();
        assert_eq!(vectors, vec![vec![1.0, 0.0]]);
        assert_eq!(*host.loads.lock().unwrap(), vec!["m".to_string()]);
        assert_eq!(host.requests()[0].backend, BackendKind::LlamaXpc);
    }

    #[test]
    fn unapproved_servers_are_refused_before_anything_is_sent() {
        let host = Canned::with(vec![]);
        let settings = Settings { llama_host: "http://gpu.lan:8790".into(), ..Settings::default() };
        let refused = get_embedder("llama_xpc", "m", &settings, host.clone()).err().unwrap();
        assert!(matches!(refused, ProviderError::Refused(_)), "{refused}");
        assert!(matches!(get_embedder("nope", "m", &settings, host.clone()), Err(ProviderError::Unknown(_))));
        assert!(host.requests().is_empty());
    }

    #[test]
    fn locality_follows_the_configured_hosts() {
        let settings = Settings { ollama_host: "http://gpu.lan:11434".into(), ..Settings::default() };
        assert!(!provider_is_local("ollama", &settings));
        assert!(provider_is_local("lmstudio", &settings));
        assert!(provider_is_local("llama_xpc", &settings));
        assert!(provider_is_local("image_xpc", &settings));
        assert!(!provider_is_local("other", &settings));
    }

    #[test]
    fn normalises_base_urls() {
        assert_eq!(normalise_base_url(" localhost:1234/v1/ "), "http://localhost:1234");
        assert_eq!(normalise_base_url("https://x.example.com/"), "https://x.example.com");
    }
}

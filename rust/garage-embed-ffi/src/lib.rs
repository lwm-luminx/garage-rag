//! The embed worker's C ABI, declared in `include/garage_embed.h`.
//!
//! Requests, results and everything the worker asks of its host cross as UTF-8 JSON, which Swift
//! and .NET both read without generated code. The host supplies the model servers (an HTTP
//! request, an image model, loading a llama.cpp model) and hears each step of the backfill; the
//! worker decides what is asked and where it may go (`garage_embed::egress`).

use std::ffi::{CStr, CString, c_char, c_void};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::PathBuf;
use std::sync::Arc;

use garage_embed::provider;
use garage_embed::{
    BackfillError, BackfillEvent, BackfillOptions, Facade, GrpcFacade, GrpcTarget, Host, HttpRequest, HttpResponse,
    Settings,
};
use serde_json::{Map, Value, json};

/// The call succeeded; the result is its JSON.
pub const GARAGE_EMBED_OK: i32 = 0;
/// The request was not valid JSON of the expected shape, or a pointer was null.
pub const GARAGE_EMBED_BAD_REQUEST: i32 = 1;
/// The worker panicked. The process is unharmed.
pub const GARAGE_EMBED_PANIC: i32 = 2;
/// The work failed: the facade, a provider's setup, or (for `garage_embed_texts`) the embedding.
pub const GARAGE_EMBED_FAILED: i32 = 3;
/// The model named does not exist, or none is registered.
pub const GARAGE_EMBED_NOT_FOUND: i32 = 4;
/// The host asked the backfill to stop.
pub const GARAGE_EMBED_CANCELLED: i32 = 5;

/// A host call: `request` is JSON; returns 0 and sets `*reply` to JSON, or nonzero and sets it to
/// the reason. `*reply` (when set) is freed with the host's `release`.
pub type HostCall = Option<unsafe extern "C" fn(*mut c_void, *const c_char, *mut *mut c_char) -> i32>;

/// The process the worker runs in. See `garage_embed.h` for each member.
#[repr(C)]
pub struct GarageEmbedHost {
    pub context: *mut c_void,
    pub http: HostCall,
    pub ensure_llama_model: HostCall,
    pub embed_images: HostCall,
    pub embed_image_texts: HostCall,
    pub release: Option<unsafe extern "C" fn(*mut c_void, *mut c_char)>,
    pub progress: Option<unsafe extern "C" fn(*mut c_void, *const c_char)>,
    pub cancelled: Option<unsafe extern "C" fn(*mut c_void) -> bool>,
}

/// [`GarageEmbedHost`] behind the worker's [`Host`] trait.
struct CHost {
    host: GarageEmbedHost,
}

// SAFETY: the header requires the host's functions to be callable from the thread that called
// into the library, which is the only thread the worker uses, and its context to stay valid for
// the call.
unsafe impl Send for CHost {}
// SAFETY: as above.
unsafe impl Sync for CHost {}

impl CHost {
    /// Calls `function` with `request`; its reply, or why there is none.
    fn call(&self, function: HostCall, what: &str, request: &Value) -> Result<String, String> {
        let Some(function) = function else {
            return Err(format!("the host offers no {what}"));
        };
        let request = CString::new(request.to_string()).map_err(|_| "a request held a NUL byte".to_string())?;
        let mut reply: *mut c_char = std::ptr::null_mut();
        // SAFETY: the host's contract (garage_embed.h).
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

    fn vectors(&self, function: HostCall, what: &str, request: &Value) -> Result<Vec<Vec<f32>>, String> {
        let reply = self.call(function, what, request)?;
        let reply: Value = serde_json::from_str(&reply)
            .map_err(|error| format!("the host's {what} replied with bad JSON: {error}"))?;
        vectors_of(&reply["vectors"]).ok_or_else(|| format!("the host's {what} replied without 'vectors'"))
    }
}

impl Host for CHost {
    fn http(&self, request: &HttpRequest) -> Result<HttpResponse, String> {
        let headers: Vec<Value> = request.headers.iter().map(|(name, value)| json!([name, value])).collect();
        let request = json!({
            "backend": request.backend.name(),
            "method": request.method,
            "url": request.url,
            "path": request.path,
            "headers": headers,
            "body": String::from_utf8_lossy(&request.body),
            "timeout": request.timeout.as_secs_f64(),
        });
        let reply = self.call(self.host.http, "HTTP request", &request)?;
        let reply: Value =
            serde_json::from_str(&reply).map_err(|error| format!("the host's HTTP reply is bad JSON: {error}"))?;
        let status = reply["status"]
            .as_u64()
            .and_then(|status| u16::try_from(status).ok())
            .ok_or("the host's HTTP reply has no status")?;
        let body = reply["body"].as_str().unwrap_or_default().as_bytes().to_vec();
        Ok(HttpResponse { status, body })
    }

    fn ensure_llama_model(&self, model: &str) -> Result<String, String> {
        self.call(self.host.ensure_llama_model, "model loader", &json!({ "model": model }))
    }

    fn embed_images(&self, model: &str, paths: &[String]) -> Result<Vec<Vec<f32>>, String> {
        self.vectors(self.host.embed_images, "image embedding", &json!({ "model": model, "paths": paths }))
    }

    fn embed_image_texts(&self, model: &str, texts: &[String]) -> Result<Vec<Vec<f32>>, String> {
        self.vectors(
            self.host.embed_image_texts,
            "image model text embedding",
            &json!({ "model": model, "texts": texts }),
        )
    }

    fn progress(&self, event: &BackfillEvent) {
        let Some(progress) = self.host.progress else { return };
        if let Ok(event) = CString::new(event_json(event).to_string()) {
            // SAFETY: the host's contract (garage_embed.h).
            unsafe { progress(self.host.context, event.as_ptr()) };
        }
    }

    fn cancelled(&self) -> bool {
        // SAFETY: the host's contract (garage_embed.h).
        self.host.cancelled.is_some_and(|cancelled| unsafe { cancelled(self.host.context) })
    }
}

fn vectors_of(value: &Value) -> Option<Vec<Vec<f32>>> {
    value
        .as_array()?
        .iter()
        .map(|vector| {
            #[allow(clippy::cast_possible_truncation)]
            vector.as_array()?.iter().map(|x| x.as_f64().map(|x| x as f32)).collect()
        })
        .collect()
}

/// A `BackfillStatus`, field for field.
fn event_json(event: &BackfillEvent) -> Value {
    json!({
        "model_slug": event.model,
        "phase": event.phase.name(),
        "total": event.total,
        "embedded": event.embedded,
        "failed": event.failed,
        "remaining": event.remaining(),
        "batches": event.batches,
        "message": event.message,
    })
}

/// `settings` of a request; anything left out is Python's default.
fn settings_of(request: &Map<String, Value>) -> Settings {
    let mut settings = Settings::default();
    let Some(Value::Object(given)) = request.get("settings") else { return settings };
    let text = |key: &str| given.get(key).and_then(Value::as_str).filter(|value| !value.is_empty()).map(str::to_string);
    if let Some(host) = text("ollama_host") {
        settings.ollama_host = host;
    }
    if let Some(host) = text("lmstudio_host") {
        settings.lmstudio_host = host;
    }
    if let Some(host) = text("llama_host") {
        settings.llama_host = host;
    }
    settings.lmstudio_api_token = text("lmstudio_api_token");
    if let Some(size) = given.get("batch_size").and_then(Value::as_u64).filter(|size| *size > 0) {
        settings.batch_size = usize::try_from(size).unwrap_or(settings.batch_size);
    }
    settings
}

fn grpc_target(request: &Map<String, Value>) -> Result<(GrpcTarget, Option<String>), String> {
    let grpc = request.get("grpc").and_then(Value::as_object).ok_or("the request has no 'grpc' object")?;
    let token = grpc.get("token").and_then(Value::as_str).map(str::to_string);
    if let Some(socket) = grpc.get("socket").and_then(Value::as_str).filter(|socket| !socket.is_empty()) {
        return Ok((GrpcTarget::Socket(PathBuf::from(socket)), token));
    }
    let port = grpc
        .get("port")
        .and_then(Value::as_u64)
        .and_then(|port| u16::try_from(port).ok())
        .ok_or("'grpc' names neither a socket nor a port")?;
    let host = grpc.get("host").and_then(Value::as_str).filter(|host| !host.is_empty()).unwrap_or("127.0.0.1");
    Ok((GrpcTarget::Tcp { host: host.to_string(), port }, token))
}

fn usize_of(request: &Map<String, Value>, key: &str) -> Option<usize> {
    request.get(key).and_then(Value::as_u64).filter(|value| *value > 0).and_then(|value| usize::try_from(value).ok())
}

/// The status and result JSON of a backfill request.
fn run_backfill(request: &Map<String, Value>, host: &Arc<dyn Host>) -> (i32, Value) {
    let (target, token) = match grpc_target(request) {
        Ok(target) => target,
        Err(message) => return (GARAGE_EMBED_BAD_REQUEST, json!({ "error": message })),
    };
    let options = BackfillOptions {
        model: request.get("model").and_then(Value::as_str).map(str::to_string),
        batch_size: usize_of(request, "batch_size"),
        limit: usize_of(request, "limit"),
        skip_verify: request.get("skip_verify").and_then(Value::as_bool).unwrap_or(false),
    };
    let facade = match GrpcFacade::connect(&target, token.as_deref()) {
        Ok(facade) => facade,
        Err(error) => return (GARAGE_EMBED_FAILED, json!({ "error": error.to_string() })),
    };
    // "service": the backend's own settings, so the worker and Python never disagree.
    let mut settings = if request.get("settings").and_then(Value::as_str) == Some("service") {
        Settings::from_service(|name| facade.get_setting(name))
    } else {
        settings_of(request)
    };
    // The app keeps LM Studio's token in its Keychain and hands it over with the request.
    if let Some(token) = request.get("lmstudio_api_token").and_then(Value::as_str).filter(|token| !token.is_empty()) {
        settings.lmstudio_api_token = Some(token.to_string());
    }
    match garage_embed::backfill(&facade, &settings, host, &options) {
        Ok(outcomes) => (GARAGE_EMBED_OK, json!({ "outcomes": outcomes.iter().map(event_json).collect::<Vec<_>>() })),
        Err(error) => {
            let status = match error {
                BackfillError::NotFound(_) => GARAGE_EMBED_NOT_FOUND,
                BackfillError::Failed(_) => GARAGE_EMBED_FAILED,
                BackfillError::Cancelled => GARAGE_EMBED_CANCELLED,
            };
            (status, json!({ "error": error.to_string() }))
        }
    }
}

/// The status and result JSON of an embed-texts request.
fn run_texts(request: &Map<String, Value>, host: &Arc<dyn Host>) -> (i32, Value) {
    let text = |key: &str| request.get(key).and_then(Value::as_str).unwrap_or_default();
    let Some(texts) = request.get("texts").and_then(Value::as_array) else {
        return (GARAGE_EMBED_BAD_REQUEST, json!({ "error": "the request has no 'texts' list" }));
    };
    let Some(texts) = texts.iter().map(|text| text.as_str().map(str::to_string)).collect::<Option<Vec<_>>>() else {
        return (GARAGE_EMBED_BAD_REQUEST, json!({ "error": "'texts' holds something other than strings" }));
    };
    let embedder =
        match provider::get_embedder(text("provider"), text("model_ref"), &settings_of(request), host.clone()) {
            Ok(embedder) => embedder,
            Err(error) => return (GARAGE_EMBED_FAILED, json!({ "error": error.to_string() })),
        };
    match embedder.embed(&texts) {
        Ok(vectors) => (GARAGE_EMBED_OK, json!({ "vectors": vectors })),
        Err(error) => (GARAGE_EMBED_FAILED, json!({ "error": error.to_string() })),
    }
}

/// The status and result JSON of a models request: what GarageService has registered, which also
/// shows the worker reaches it with the token it was given.
fn run_models(request: &Map<String, Value>, _host: &Arc<dyn Host>) -> (i32, Value) {
    let (target, token) = match grpc_target(request) {
        Ok(target) => target,
        Err(message) => return (GARAGE_EMBED_BAD_REQUEST, json!({ "error": message })),
    };
    let models = GrpcFacade::connect(&target, token.as_deref()).and_then(|facade| facade.list_models());
    match models {
        Ok(models) => {
            let models: Vec<Value> = models
                .iter()
                .map(|model| {
                    json!({ "slug": model.slug, "provider": model.provider, "model_ref": model.model_ref, "dims": model.dims })
                })
                .collect();
            (GARAGE_EMBED_OK, json!({ "models": models }))
        }
        Err(error) => (GARAGE_EMBED_FAILED, json!({ "error": error.to_string() })),
    }
}

/// One of the calls: the request's JSON and the host in, its status and result JSON out.
type Body = fn(&Map<String, Value>, &Arc<dyn Host>) -> (i32, Value);

/// Parses `request`, runs `body` with the host, and writes its result to `*result`.
///
/// # Safety
///
/// As for [`garage_embed_backfill`].
unsafe fn entry(request: *const c_char, host: *const GarageEmbedHost, result: *mut *mut c_char, body: Body) -> i32 {
    if result.is_null() {
        return GARAGE_EMBED_BAD_REQUEST;
    }
    let outcome = catch_unwind(AssertUnwindSafe(|| {
        if request.is_null() || host.is_null() {
            return (GARAGE_EMBED_BAD_REQUEST, json!({ "error": "a pointer was null" }));
        }
        // SAFETY: the caller passes a NUL-terminated string.
        let request = unsafe { CStr::from_ptr(request) };
        let request = match serde_json::from_slice::<Value>(request.to_bytes()) {
            Ok(Value::Object(request)) => request,
            Ok(_) => return (GARAGE_EMBED_BAD_REQUEST, json!({ "error": "the request is not a JSON object" })),
            Err(error) => {
                return (GARAGE_EMBED_BAD_REQUEST, json!({ "error": format!("the request is not JSON: {error}") }));
            }
        };
        // SAFETY: the caller passes a valid host, which the library only reads.
        let host = unsafe { std::ptr::read(host) };
        let host: Arc<dyn Host> = Arc::new(CHost { host });
        body(&request, &host)
    }));
    let (status, value) = outcome.unwrap_or_else(|panic| {
        let message = panic
            .downcast_ref::<&str>()
            .map(ToString::to_string)
            .or_else(|| panic.downcast_ref::<String>().cloned())
            .unwrap_or_else(|| "the embed worker panicked".into());
        (GARAGE_EMBED_PANIC, json!({ "error": message }))
    });
    let text = CString::new(value.to_string()).unwrap_or_default();
    // SAFETY: checked non-null above; the caller frees it with garage_embed_string_free.
    unsafe { *result = text.into_raw() };
    status
}

/// Embeds the chunks each model (or the one named) has no vectors for, through GarageService.
///
/// # Safety
///
/// `request` is a NUL-terminated string; `host` points to a valid [`GarageEmbedHost`] whose
/// functions stay callable for the call; `result` points to writable storage for a string the
/// caller frees with [`garage_embed_string_free`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn garage_embed_backfill(
    request: *const c_char,
    host: *const GarageEmbedHost,
    result: *mut *mut c_char,
) -> i32 {
    // SAFETY: the caller's contract is the function's.
    unsafe { entry(request, host, result, run_backfill) }
}

/// Lists the models GarageService has registered (a self test of the worker's connection).
///
/// # Safety
///
/// As for [`garage_embed_backfill`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn garage_embed_models(
    request: *const c_char,
    host: *const GarageEmbedHost,
    result: *mut *mut c_char,
) -> i32 {
    // SAFETY: the caller's contract is the function's.
    unsafe { entry(request, host, result, run_models) }
}

/// Embeds a few texts with one provider and model, for a self test.
///
/// # Safety
///
/// As for [`garage_embed_backfill`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn garage_embed_texts(
    request: *const c_char,
    host: *const GarageEmbedHost,
    result: *mut *mut c_char,
) -> i32 {
    // SAFETY: the caller's contract is the function's.
    unsafe { entry(request, host, result, run_texts) }
}

/// Frees a result one of the calls above wrote.
///
/// # Safety
///
/// `text` came from this library and was not freed before (or is null).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn garage_embed_string_free(text: *mut c_char) {
    if !text.is_null() {
        // SAFETY: the caller's contract: a string this library made with CString::into_raw.
        drop(unsafe { CString::from_raw(text) });
    }
}

/// The backend names a host routes HTTP requests on (`garage_embed.h`).
pub const BACKENDS: [&str; 3] = ["ollama", "lmstudio", "llama_xpc"];

#[cfg(test)]
#[allow(clippy::cast_precision_loss)]
mod tests {
    use super::*;
    use garage_embed::provider::BackendKind;

    unsafe extern "C" fn http(_: *mut c_void, request: *const c_char, reply: *mut *mut c_char) -> i32 {
        let request: Value = serde_json::from_str(unsafe { CStr::from_ptr(request) }.to_str().unwrap()).unwrap();
        assert_eq!(request["backend"], "llama_xpc");
        assert_eq!(request["path"], "/v1/embeddings");
        let body: Value = serde_json::from_str(request["body"].as_str().unwrap()).unwrap();
        let data: Vec<Value> = body["input"]
            .as_array()
            .unwrap()
            .iter()
            .enumerate()
            .map(|(index, _)| json!({ "index": index, "embedding": [index as f64, 1.0] }))
            .collect();
        let text = json!({ "status": 200, "body": json!({ "data": data }).to_string() }).to_string();
        unsafe { *reply = CString::new(text).unwrap().into_raw() };
        0
    }

    unsafe extern "C" fn release(_: *mut c_void, reply: *mut c_char) {
        drop(unsafe { CString::from_raw(reply) });
    }

    fn host() -> GarageEmbedHost {
        GarageEmbedHost {
            context: std::ptr::null_mut(),
            http: Some(http),
            ensure_llama_model: None,
            embed_images: None,
            embed_image_texts: None,
            release: Some(release),
            progress: None,
            cancelled: None,
        }
    }

    fn call(
        function: unsafe extern "C" fn(*const c_char, *const GarageEmbedHost, *mut *mut c_char) -> i32,
        request: &str,
    ) -> (i32, Value) {
        let request = CString::new(request).unwrap();
        let host = host();
        let mut result: *mut c_char = std::ptr::null_mut();
        let status = unsafe { function(request.as_ptr(), &raw const host, &raw mut result) };
        let value = serde_json::from_str(unsafe { CStr::from_ptr(result) }.to_str().unwrap()).unwrap();
        unsafe { garage_embed_string_free(result) };
        (status, value)
    }

    #[test]
    fn embeds_texts_through_the_hosts_http() {
        let (status, value) =
            call(garage_embed_texts, r#"{"provider": "llama_xpc", "model_ref": "m", "texts": ["a", "b"]}"#);
        assert_eq!(status, GARAGE_EMBED_OK, "{value}");
        assert_eq!(value, json!({ "vectors": [[0.0, 1.0], [1.0, 1.0]] }));
    }

    #[test]
    fn refuses_what_the_egress_rules_refuse() {
        let request = r#"{"provider": "llama_xpc", "model_ref": "m", "texts": ["a"], "settings": {"llama_host": "http://gpu.lan:8790"}}"#;
        let (status, value) = call(garage_embed_texts, request);
        assert_eq!(status, GARAGE_EMBED_FAILED);
        assert!(value["error"].as_str().unwrap().contains("must be a loopback URL"), "{value}");
    }

    #[test]
    fn bad_requests_say_why() {
        assert_eq!(call(garage_embed_texts, "nope").0, GARAGE_EMBED_BAD_REQUEST);
        assert_eq!(call(garage_embed_texts, "[]").0, GARAGE_EMBED_BAD_REQUEST);
        assert_eq!(call(garage_embed_backfill, "{}").1, json!({ "error": "the request has no 'grpc' object" }));
    }

    #[test]
    fn a_missing_server_fails_the_backfill() {
        let dir = std::env::temp_dir().join(format!("garage-embed-ffi-{}", std::process::id()));
        let request = json!({ "grpc": { "socket": dir.join("none.sock") } }).to_string();
        let (status, value) = call(garage_embed_backfill, &request);
        assert_eq!(status, GARAGE_EMBED_FAILED);
        assert!(value["error"].as_str().unwrap().starts_with("cannot reach GarageService at unix:"), "{value}");
    }

    #[test]
    fn the_backend_names_are_the_workers() {
        assert_eq!(BACKENDS, [BackendKind::Ollama.name(), BackendKind::LmStudio.name(), BackendKind::LlamaXpc.name()]);
    }
}

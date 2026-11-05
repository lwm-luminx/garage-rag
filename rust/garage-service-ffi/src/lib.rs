//! GarageService's C ABI, declared in `include/garage_service.h`.
//!
//! GarageXPCService starts and stops the gRPC server through it, as it started and stopped the
//! Python `create_grpc_server` before; a probe answers its Database Connection self test. Requests,
//! results and the host's calls are UTF-8 JSON. The host carries the model servers' HTTP requests
//! (LlamaXPCService over NSXPC, Ollama and LM Studio with the system's HTTP stack), loads a
//! llama.cpp model on demand and embeds with the image models; the service decides what is asked
//! and where it may go.
//!
//! The environment the Python server read is read here too, by the service's own modules:
//! `GARAGE_DATABASE_URL` (the configuration), `GARAGE_MODEL_MANIFEST` (the catalog),
//! `GARAGE_MCP_EXECUTABLE` (the MCP registrations), `GARAGE_LMSTUDIO_API_TOKEN` (the settings)
//! and `GARAGE_GRPC_TOKEN` when the request names no token. The host sets them before it starts
//! a server.

use std::ffi::{CStr, CString, c_char, c_void};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use garage_embed::{Host, HttpRequest, HttpResponse};
use garage_service::auth::{config_change_allowed, token_from_env};
use garage_service::config::Config;
use garage_service::host::HostEmbedder;
use garage_service::langextract::LangExtractor;
use garage_service::server::{Endpoint, bind, serve_bound};
use garage_service::service::{GarageService, sql_dir};
use garage_service::{VERSION, db};
use serde_json::{Map, Value, json};
use tokio::sync::oneshot;

/// The call succeeded; the result is its JSON.
pub const GARAGE_SERVICE_OK: i32 = 0;
/// The request was not valid JSON of the expected shape, or a pointer was null.
pub const GARAGE_SERVICE_BAD_REQUEST: i32 = 1;
/// The service panicked. The process is unharmed.
pub const GARAGE_SERVICE_PANIC: i32 = 2;
/// The work failed: the endpoint could not be bound, the configuration does not load, the
/// database does not answer.
pub const GARAGE_SERVICE_FAILED: i32 = 3;

/// A host call: `request` is JSON; returns 0 and sets `*reply` to JSON, or nonzero and sets it to
/// the reason. `*reply` (when set) is freed with the host's `release`.
pub type HostCall = Option<unsafe extern "C" fn(*mut c_void, *const c_char, *mut *mut c_char) -> i32>;

/// The process the service runs in. Any member but `http` and `release` may be NULL; a NULL
/// member answers its calls as unavailable.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct GarageServiceHost {
    /// Passed back as the first argument of every call.
    pub context: *mut c_void,
    /// An HTTP request to a model server, already approved by the service's egress rules:
    /// {"backend": "ollama" | "lmstudio" | "llama_xpc", "method", "url", "path",
    ///  "headers": [[name, value], ...], "body": string, "timeout": seconds}
    /// -> {"status": int, "body": string}. Send it to exactly `url`: no proxy, and a redirect is
    /// the reply, never followed. A llama_xpc request may go over the host's own connection to
    /// LlamaXPCService instead (`path` is the route). Nonzero only when no reply came.
    pub http: HostCall,
    /// {"model"}: LlamaXPCService said the model is not loaded; load it. Reply: what was done.
    /// `EnsureLlamaModel` (the launchers' way in) is answered through it too.
    pub ensure_llama_model: HostCall,
    /// {"model", "paths": [...]} -> {"vectors": [[...], ...]}: an image model's image tower over
    /// the files at `paths`, which the host reads.
    pub embed_images: HostCall,
    /// {"model", "texts": [...]} -> {"vectors": [[...], ...]}: an image model's text tower.
    pub embed_image_texts: HostCall,
    /// Frees a reply one of the calls above set.
    pub release: Option<unsafe extern "C" fn(*mut c_void, *mut c_char)>,
}

/// [`GarageServiceHost`] behind the service's [`Host`] trait.
struct CHost {
    host: GarageServiceHost,
}

// SAFETY: the header requires the host's functions to be callable from any thread, at once, and
// its context to stay valid until the server using it has stopped.
unsafe impl Send for CHost {}
// SAFETY: as above.
unsafe impl Sync for CHost {}

impl CHost {
    fn call(&self, function: HostCall, what: &str, request: &Value) -> Result<String, String> {
        let Some(function) = function else {
            return Err(format!("the host offers no {what}"));
        };
        let request = CString::new(request.to_string()).map_err(|_| "a request held a NUL byte".to_string())?;
        let mut reply: *mut c_char = std::ptr::null_mut();
        // SAFETY: the host's contract (garage_service.h).
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

fn text(request: &Map<String, Value>, key: &str) -> Option<String> {
    request.get(key).and_then(Value::as_str).filter(|value| !value.trim().is_empty()).map(str::to_owned)
}

/// `{"endpoint": {"socket": path} | {"host": ip, "port": n}}`; the host defaults to loopback.
fn endpoint_of(request: &Map<String, Value>) -> Result<Endpoint, String> {
    let endpoint = request.get("endpoint").and_then(Value::as_object).ok_or("the request has no 'endpoint' object")?;
    if let Some(socket) = text(endpoint, "socket") {
        return Ok(Endpoint::Unix(PathBuf::from(socket)));
    }
    let port = endpoint
        .get("port")
        .and_then(Value::as_u64)
        .and_then(|port| u16::try_from(port).ok())
        .ok_or("'endpoint' names neither a socket nor a port")?;
    let host = text(endpoint, "host").unwrap_or_else(|| "127.0.0.1".to_owned());
    let ip: std::net::IpAddr =
        host.parse().map_err(|_| format!("'endpoint.host' must be an IP address, not {host:?}"))?;
    Ok(Endpoint::Tcp(std::net::SocketAddr::new(ip, port)))
}

/// `{"config": path}`: the file when it exists, else the defaults, remembered at that path so
/// `SetSetting` writes it there (the app's `garage.json` in its working directory, which a fresh
/// install has not written yet). Without a path, the search the binary makes.
fn config_of(request: &Map<String, Value>) -> Result<Config, String> {
    match text(request, "config") {
        Some(path) if Path::new(&path).is_file() => Config::load(Some(Path::new(&path))).map_err(|e| e.to_string()),
        Some(path) => {
            let mut config = Config::defaults();
            config.path = Some(PathBuf::from(path));
            Ok(config)
        }
        None => Config::load(None).map_err(|e| e.to_string()),
    }
}

/// A running gRPC server, opaque to C: its runtime, the task serving on it and the way to stop it.
pub struct GarageServiceServer {
    runtime: tokio::runtime::Runtime,
    shutdown: Option<oneshot::Sender<()>>,
    task: Option<tokio::task::JoinHandle<std::io::Result<()>>>,
}

fn start(request: &Map<String, Value>, host: Arc<dyn Host>) -> Result<(GarageServiceServer, Value), (i32, String)> {
    let bad = |message: String| (GARAGE_SERVICE_BAD_REQUEST, message);
    let failed = |message: String| (GARAGE_SERVICE_FAILED, message);
    let endpoint = endpoint_of(request).map_err(bad)?;
    let config = config_of(request).map_err(failed)?;
    let token = text(request, "token").or_else(token_from_env);
    let sql = sql_dir(text(request, "sql_dir").map(PathBuf::from).as_deref());
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .thread_name("garage-service")
        .enable_all()
        .build()
        .map_err(|e| failed(format!("tokio runtime: {e}")))?;
    let vouched = config_change_allowed(token.is_some(), matches!(endpoint, Endpoint::Unix(_)));
    let embedder = Arc::new(HostEmbedder { host: host.clone(), settings: config.embed_settings() });
    let service = GarageService::new(config, embedder, sql, vouched)
        .map_err(|e| failed(e.to_string()))?
        .with_extractor(Arc::new(LangExtractor::new(host.clone())))
        .with_host(host);
    let bound = runtime.block_on(bind(&endpoint)).map_err(|e| failed(e.to_string()))?;
    let listening = bound.endpoint();
    let (shutdown, stopped) = oneshot::channel::<()>();
    let task = runtime.spawn(async move {
        serve_bound(service, bound, token.as_deref(), async {
            let _ = stopped.await;
        })
        .await
    });
    let mut result = json!({ "endpoint": listening.to_string(), "pid": std::process::id(), "version": VERSION });
    match &listening {
        Endpoint::Unix(path) => result["socket"] = json!(path.display().to_string()),
        Endpoint::Tcp(addr) => {
            result["host"] = json!(addr.ip().to_string());
            result["port"] = json!(addr.port());
        }
    }
    Ok((GarageServiceServer { runtime, shutdown: Some(shutdown), task: Some(task) }, result))
}

impl GarageServiceServer {
    fn is_running(&self) -> bool {
        self.task.as_ref().is_some_and(|task| !task.is_finished())
    }

    /// Stops serving: no new connections, calls in flight get `grace` to finish, then the runtime
    /// is shut down (its blocking threads get a little longer).
    fn stop(mut self, grace: Duration) {
        if let Some(shutdown) = self.shutdown.take() {
            let _ = shutdown.send(());
        }
        if let Some(task) = self.task.take() {
            let _ = self.runtime.block_on(async { tokio::time::timeout(grace, task).await });
        }
        self.runtime.shutdown_timeout(grace + Duration::from_secs(1));
    }
}

/// Runs `body` with the parsed request, catching a panic.
///
/// # Safety
///
/// `request` is null or a NUL-terminated string.
unsafe fn guarded<T>(
    request: *const c_char,
    body: impl FnOnce(&Map<String, Value>) -> (i32, Value, Option<T>),
) -> (i32, Value, Option<T>) {
    let outcome = catch_unwind(AssertUnwindSafe(|| {
        if request.is_null() {
            return (GARAGE_SERVICE_BAD_REQUEST, json!({ "error": "the request was null" }), None);
        }
        // SAFETY: the caller passes a NUL-terminated string.
        let request = unsafe { CStr::from_ptr(request) };
        let request = match serde_json::from_slice::<Value>(request.to_bytes()) {
            Ok(Value::Object(request)) => request,
            Ok(_) => return (GARAGE_SERVICE_BAD_REQUEST, json!({ "error": "the request is not a JSON object" }), None),
            Err(error) => {
                return (
                    GARAGE_SERVICE_BAD_REQUEST,
                    json!({ "error": format!("the request is not JSON: {error}") }),
                    None,
                );
            }
        };
        body(&request)
    }));
    outcome.unwrap_or_else(|panic| {
        let message = panic
            .downcast_ref::<&str>()
            .map(ToString::to_string)
            .or_else(|| panic.downcast_ref::<String>().cloned())
            .unwrap_or_else(|| "GarageService panicked".into());
        (GARAGE_SERVICE_PANIC, json!({ "error": message }), None)
    })
}

/// Writes `value` to `*result`.
///
/// # Safety
///
/// `result` is non-null and writable.
unsafe fn write_result(result: *mut *mut c_char, value: &Value) {
    let text = CString::new(value.to_string()).unwrap_or_default();
    // SAFETY: the caller's contract; freed with garage_service_string_free.
    unsafe { *result = text.into_raw() };
}

/// Starts the gRPC server and returns once it listens:
/// `{"endpoint": {"socket": path} | {"host": ip, "port": n}, "token": string?, "config": path?,
///   "sql_dir": path?}`
/// -> `{"endpoint": "unix:path" | "ip:port", "socket"? | "host", "port", "pid", "version"}`.
///
/// `token` is the per-launch token every call but `EnsureLlamaModel` must carry
/// (`GARAGE_GRPC_TOKEN` when absent); `config` the `garage.json` to run on, written there by
/// `SetSetting` when it does not exist yet; `sql_dir` the schema `InitDb` applies without one of
/// its own. A server on a Unix socket, or with a token, answers the config-changing methods; one
/// on a port without a token refuses them.
///
/// # Safety
///
/// `request` is a NUL-terminated string; `host` points to a valid [`GarageServiceHost`] whose
/// functions stay callable, from any thread, until [`garage_service_stop`] returns; `server` and
/// `result` point to writable storage. `*server` is set only on success.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn garage_service_start(
    request: *const c_char,
    host: *const GarageServiceHost,
    server: *mut *mut GarageServiceServer,
    result: *mut *mut c_char,
) -> i32 {
    if result.is_null() || server.is_null() {
        return GARAGE_SERVICE_BAD_REQUEST;
    }
    if host.is_null() {
        // SAFETY: checked non-null above.
        unsafe { write_result(result, &json!({ "error": "the host was null" })) };
        return GARAGE_SERVICE_BAD_REQUEST;
    }
    // SAFETY: the caller passes a valid host, which the library copies.
    let host: Arc<dyn Host> = Arc::new(CHost { host: unsafe { *host } });
    // SAFETY: the caller's contract is the function's.
    let (status, value, started) = unsafe {
        guarded(request, |request| match start(request, host) {
            Ok((running, value)) => (GARAGE_SERVICE_OK, value, Some(running)),
            Err((status, message)) => (status, json!({ "error": message }), None),
        })
    };
    if let Some(running) = started {
        // SAFETY: checked non-null above.
        unsafe { *server = Box::into_raw(Box::new(running)) };
    }
    // SAFETY: checked non-null above.
    unsafe { write_result(result, &value) };
    status
}

/// Whether the server is still serving.
///
/// # Safety
///
/// `server` came from [`garage_service_start`] and was not stopped (or is null).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn garage_service_is_running(server: *const GarageServiceServer) -> bool {
    // SAFETY: the caller's contract.
    unsafe { server.as_ref() }.is_some_and(GarageServiceServer::is_running)
}

/// Stops the server: no new connections, calls in flight get `grace_seconds` to finish (0 stops
/// them at once), the socket file is removed and the server is freed.
///
/// # Safety
///
/// `server` came from [`garage_service_start`] and was not stopped before (or is null).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn garage_service_stop(server: *mut GarageServiceServer, grace_seconds: f64) {
    if !server.is_null() {
        // SAFETY: the caller's contract: a server this library made with Box::into_raw.
        let server = unsafe { Box::from_raw(server) };
        server.stop(Duration::from_secs_f64(grace_seconds.max(0.0)));
    }
}

/// Connects to the database the configuration names and asks its version, for a self test:
/// `{"config": path?}` -> `{"database": "PostgreSQL 18...", "database_url": redacted, "version"}`.
///
/// # Safety
///
/// `request` is a NUL-terminated string; `result` points to writable storage for a string the
/// caller frees with [`garage_service_string_free`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn garage_service_probe(request: *const c_char, result: *mut *mut c_char) -> i32 {
    if result.is_null() {
        return GARAGE_SERVICE_BAD_REQUEST;
    }
    // SAFETY: the caller's contract is the function's.
    let (status, value, _) = unsafe {
        guarded::<()>(request, |request| match probe(request) {
            Ok(value) => (GARAGE_SERVICE_OK, value, None),
            Err(message) => (GARAGE_SERVICE_FAILED, json!({ "error": message }), None),
        })
    };
    // SAFETY: checked non-null above.
    unsafe { write_result(result, &value) };
    status
}

fn probe(request: &Map<String, Value>) -> Result<Value, String> {
    let config = config_of(request)?;
    let url = config.database_url();
    let pool = db::pool_for(&url).map_err(|e| e.to_string())?;
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().map_err(|e| e.to_string())?;
    let version: String = runtime.block_on(async {
        let client = pool.get().await.map_err(|e| e.to_string())?;
        let row = client.query_one("SELECT version()", &[]).await.map_err(|e| e.to_string())?;
        Ok::<_, String>(row.get(0))
    })?;
    Ok(json!({ "database": version, "database_url": db::redact_url(&url), "version": VERSION }))
}

/// The service's version, as `GetVersion` reports it. A static string: never freed.
#[unsafe(no_mangle)]
pub extern "C" fn garage_service_version() -> *const c_char {
    static TEXT: OnceLock<CString> = OnceLock::new();
    TEXT.get_or_init(|| CString::new(VERSION).unwrap_or_default()).as_ptr()
}

/// Frees a result one of the calls above wrote.
///
/// # Safety
///
/// `text` came from this library and was not freed before (or is null).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn garage_service_string_free(text: *mut c_char) {
    if !text.is_null() {
        // SAFETY: the caller's contract: a string this library made with CString::into_raw.
        drop(unsafe { CString::from_raw(text) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn call_start(request: &str, host: &GarageServiceHost) -> (i32, Value, *mut GarageServiceServer) {
        let request = CString::new(request).unwrap();
        let mut server: *mut GarageServiceServer = std::ptr::null_mut();
        let mut result: *mut c_char = std::ptr::null_mut();
        // SAFETY: valid pointers, as the header asks.
        let status = unsafe { garage_service_start(request.as_ptr(), host, &raw mut server, &raw mut result) };
        // SAFETY: the result was written by this library.
        let value: Value = serde_json::from_str(unsafe { CStr::from_ptr(result) }.to_str().unwrap()).unwrap();
        // SAFETY: freed once.
        unsafe { garage_service_string_free(result) };
        (status, value, server)
    }

    fn no_host() -> GarageServiceHost {
        GarageServiceHost {
            context: std::ptr::null_mut(),
            http: None,
            ensure_llama_model: None,
            embed_images: None,
            embed_image_texts: None,
            release: None,
        }
    }

    #[test]
    fn a_bad_request_is_refused_before_anything_starts() {
        let host = no_host();
        let (status, value, server) = call_start("not json", &host);
        assert_eq!(status, GARAGE_SERVICE_BAD_REQUEST);
        assert!(value["error"].as_str().unwrap().starts_with("the request is not JSON"));
        assert!(server.is_null());
        let (status, value, _) = call_start(r#"{"endpoint": {}}"#, &host);
        assert_eq!(status, GARAGE_SERVICE_BAD_REQUEST);
        assert_eq!(value["error"], "'endpoint' names neither a socket nor a port");
        let (status, value, _) = call_start(r#"{"endpoint": {"socket": "relative/path"}}"#, &host);
        assert_eq!(status, GARAGE_SERVICE_FAILED);
        assert!(value["error"].as_str().unwrap().contains("must be absolute"));
    }

    #[test]
    fn a_server_binds_a_port_and_stops() {
        let host = no_host();
        let dir = std::env::temp_dir().join(format!("garage-service-ffi-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let config = dir.join("garage.json");
        let request = json!({
            "endpoint": {"host": "127.0.0.1", "port": 0},
            "config": config.display().to_string(),
            "token": "secret",
        });
        let (status, value, server) = call_start(&request.to_string(), &host);
        assert_eq!(status, GARAGE_SERVICE_OK, "{value}");
        assert!(!server.is_null());
        assert_eq!(value["host"], "127.0.0.1");
        let port = value["port"].as_u64().unwrap();
        assert!(port > 0);
        assert_eq!(value["endpoint"], format!("127.0.0.1:{port}"));
        assert_eq!(value["version"], VERSION);
        // SAFETY: a server this library made.
        assert!(unsafe { garage_service_is_running(server) });
        // The port is taken while it serves.
        let mut same_port = request.clone();
        same_port["endpoint"]["port"] = json!(port);
        let (status, value, second) = call_start(&same_port.to_string(), &host);
        assert_eq!(status, GARAGE_SERVICE_FAILED);
        assert!(second.is_null());
        assert!(value["error"].as_str().unwrap().contains("in use"), "{value}");
        // SAFETY: as above, stopped once.
        unsafe { garage_service_stop(server, 1.0) };
        let (status, _, again) = call_start(&request.to_string(), &host);
        assert_eq!(status, GARAGE_SERVICE_OK);
        // SAFETY: as above.
        unsafe { garage_service_stop(again, 0.0) };
        // A config that does not exist yet is not an error: SetSetting writes it.
        assert!(!config.exists());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_version_is_the_services() {
        // SAFETY: a static string.
        assert_eq!(unsafe { CStr::from_ptr(garage_service_version()) }.to_str().unwrap(), VERSION);
    }
}

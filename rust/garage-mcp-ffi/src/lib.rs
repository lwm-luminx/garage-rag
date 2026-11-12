//! The MCP server's C ABI, declared in `include/garage_mcp.h`.
//!
//! GarageMCPServerService starts and stops the streamable HTTP server through it; a single
//! message can be answered too (for a stdio front end, and for the parity tests), and so can one
//! HTTP exchange of the streamable transport without a listener (an endpoint: for a host that
//! carries MCP's HTTP requests over its own channel, as the App Store build's Garage Door tunnel
//! does over XPC). Requests,
//! results and the host's calls are UTF-8 JSON. The host carries the local model's HTTP requests
//! (LlamaXPCService over NSXPC, Ollama and LM Studio with the system's HTTP stack) and loads a
//! llama.cpp model on demand; the server decides what is asked and where it may go.

use std::ffi::{CStr, CString, c_char, c_void};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::PathBuf;
use std::sync::Arc;

use garage_embed::{GrpcTarget, Host, HttpRequest, HttpResponse};
use garage_mcp::{Caller, Endpoint, GrpcCorpus, HttpOptions, HttpServer, Server, Transport};
use serde_json::{Map, Value, json};

/// The call succeeded; the result is its JSON.
pub const GARAGE_MCP_OK: i32 = 0;
/// The request was not valid JSON of the expected shape, or a pointer was null.
pub const GARAGE_MCP_BAD_REQUEST: i32 = 1;
/// The server panicked. The process is unharmed.
pub const GARAGE_MCP_PANIC: i32 = 2;
/// The work failed: the listener could not bind, say.
pub const GARAGE_MCP_FAILED: i32 = 3;

/// A host call: `request` is JSON; returns 0 and sets `*reply` to JSON, or nonzero and sets it to
/// the reason. `*reply` (when set) is freed with the host's `release`.
pub type HostCall = Option<unsafe extern "C" fn(*mut c_void, *const c_char, *mut *mut c_char) -> i32>;

/// The process the server runs in. See `garage_mcp.h` for each member.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct GarageMcpHost {
    pub context: *mut c_void,
    pub http: HostCall,
    pub ensure_llama_model: HostCall,
    pub release: Option<unsafe extern "C" fn(*mut c_void, *mut c_char)>,
}

/// [`GarageMcpHost`] behind the server's [`Host`] trait.
struct CHost {
    host: GarageMcpHost,
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
        // SAFETY: the host's contract (garage_mcp.h).
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

fn server_of(request: &Map<String, Value>, host: Arc<dyn Host>) -> Result<Server, String> {
    let (target, token) = grpc_target(request)?;
    Ok(Server::new(Arc::new(GrpcCorpus::new(target, token)), host))
}

fn strings(value: Option<&Value>) -> Vec<String> {
    value
        .and_then(Value::as_array)
        .map_or_else(Vec::new, |items| items.iter().filter_map(Value::as_str).map(str::to_string).collect())
}

fn http_options(request: &Map<String, Value>) -> HttpOptions {
    let mut options = HttpOptions::default();
    let Some(Value::Object(http)) = request.get("http") else { return options };
    if let Some(host) = http.get("host").and_then(Value::as_str).filter(|host| !host.is_empty()) {
        options.host = host.to_string();
    }
    if let Some(port) = http.get("port").and_then(Value::as_u64).and_then(|port| u16::try_from(port).ok()) {
        options.port = port;
    }
    if let Some(path) = http.get("path").and_then(Value::as_str).filter(|path| !path.is_empty()) {
        options.path = path.to_string();
    }
    options.allowed_origins = strings(http.get("allowed_origins"));
    options.allowed_hosts = strings(http.get("allowed_hosts"));
    options
}

/// Runs `body` with the parsed request and host, catching a panic.
///
/// # Safety
///
/// `request` is null or a NUL-terminated string; `host` is null or points to a valid host.
unsafe fn guarded<T>(
    request: *const c_char,
    host: *const GarageMcpHost,
    body: impl FnOnce(&Map<String, Value>, Arc<dyn Host>) -> (i32, Value, Option<T>),
) -> (i32, Value, Option<T>) {
    let outcome = catch_unwind(AssertUnwindSafe(|| {
        if request.is_null() || host.is_null() {
            return (GARAGE_MCP_BAD_REQUEST, json!({ "error": "a pointer was null" }), None);
        }
        // SAFETY: the caller passes a NUL-terminated string.
        let request = unsafe { CStr::from_ptr(request) };
        let request = match serde_json::from_slice::<Value>(request.to_bytes()) {
            Ok(Value::Object(request)) => request,
            Ok(_) => return (GARAGE_MCP_BAD_REQUEST, json!({ "error": "the request is not a JSON object" }), None),
            Err(error) => {
                return (GARAGE_MCP_BAD_REQUEST, json!({ "error": format!("the request is not JSON: {error}") }), None);
            }
        };
        // SAFETY: the caller passes a valid host, which the library copies.
        let host = unsafe { *host };
        body(&request, Arc::new(CHost { host }))
    }));
    outcome.unwrap_or_else(|panic| {
        let message = panic
            .downcast_ref::<&str>()
            .map(ToString::to_string)
            .or_else(|| panic.downcast_ref::<String>().cloned())
            .unwrap_or_else(|| "the MCP server panicked".into());
        (GARAGE_MCP_PANIC, json!({ "error": message }), None)
    })
}

/// Writes `value` to `*result`.
///
/// # Safety
///
/// `result` is non-null and writable.
unsafe fn write_result(result: *mut *mut c_char, value: &Value) {
    let text = CString::new(value.to_string()).unwrap_or_default();
    // SAFETY: the caller's contract; freed with garage_mcp_string_free.
    unsafe { *result = text.into_raw() };
}

/// A running HTTP server, opaque to C.
pub struct GarageMcpHttpServer {
    server: HttpServer,
}

/// Starts the streamable HTTP server.
///
/// # Safety
///
/// `request` is a NUL-terminated string; `host` points to a valid [`GarageMcpHost`] whose
/// functions stay callable, from any thread, until [`garage_mcp_http_stop`] returns; `server` and
/// `result` point to writable storage. `*server` is set only on success.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn garage_mcp_http_start(
    request: *const c_char,
    host: *const GarageMcpHost,
    server: *mut *mut GarageMcpHttpServer,
    result: *mut *mut c_char,
) -> i32 {
    if result.is_null() || server.is_null() {
        return GARAGE_MCP_BAD_REQUEST;
    }
    // SAFETY: the caller's contract is the function's.
    let (status, value, started) = unsafe {
        guarded(request, host, |request, host| {
            let mcp = match server_of(request, host) {
                Ok(mcp) => Arc::new(mcp),
                Err(message) => return (GARAGE_MCP_BAD_REQUEST, json!({ "error": message }), None),
            };
            let options = http_options(request);
            match HttpServer::start(mcp, &options) {
                Ok(http) => {
                    let address = http.address().to_string();
                    (GARAGE_MCP_OK, json!({ "address": address, "path": options.path }), Some(http))
                }
                Err(message) => (GARAGE_MCP_FAILED, json!({ "error": message }), None),
            }
        })
    };
    if let Some(http) = started {
        // SAFETY: checked non-null above.
        unsafe { *server = Box::into_raw(Box::new(GarageMcpHttpServer { server: http })) };
    }
    // SAFETY: checked non-null above.
    unsafe { write_result(result, &value) };
    status
}

/// Whether the server is still serving.
///
/// # Safety
///
/// `server` came from [`garage_mcp_http_start`] and was not stopped (or is null).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn garage_mcp_http_is_running(server: *const GarageMcpHttpServer) -> bool {
    // SAFETY: the caller's contract.
    unsafe { server.as_ref() }.is_some_and(|server| server.server.is_running())
}

/// Stops the server: no new connections, requests in flight finish (up to ten seconds), and the
/// server is freed.
///
/// # Safety
///
/// `server` came from [`garage_mcp_http_start`] and was not stopped before (or is null).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn garage_mcp_http_stop(server: *mut GarageMcpHttpServer) {
    if !server.is_null() {
        // SAFETY: the caller's contract: a server this library made with Box::into_raw.
        let server = unsafe { Box::from_raw(server) };
        server.server.stop();
    }
}

/// Answers one JSON-RPC message:
/// `{"grpc": {...}, "message": {...}, "transport": "stdio" | "http", "registration_token": ...}`
/// -> `{"reply": message or null}`.
///
/// # Safety
///
/// `request` is a NUL-terminated string; `host` points to a valid [`GarageMcpHost`] whose functions
/// stay callable for the call; `result` points to writable storage for a string the caller frees
/// with [`garage_mcp_string_free`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn garage_mcp_handle(
    request: *const c_char,
    host: *const GarageMcpHost,
    result: *mut *mut c_char,
) -> i32 {
    if result.is_null() {
        return GARAGE_MCP_BAD_REQUEST;
    }
    // SAFETY: the caller's contract is the function's.
    let (status, value, ()) = unsafe {
        let (status, value, _) = guarded::<()>(request, host, |request, host| {
            let mcp = match server_of(request, host) {
                Ok(mcp) => mcp,
                Err(message) => return (GARAGE_MCP_BAD_REQUEST, json!({ "error": message }), None),
            };
            let Some(message) = request.get("message") else {
                return (GARAGE_MCP_BAD_REQUEST, json!({ "error": "the request has no 'message'" }), None);
            };
            let transport = if request.get("transport").and_then(Value::as_str) == Some("http") {
                Transport::Http
            } else {
                Transport::Stdio
            };
            let mut caller = Caller::new(transport);
            caller.registration_token =
                request.get("registration_token").and_then(Value::as_str).filter(|t| !t.is_empty()).map(str::to_string);
            let reply = mcp.handle(message, &caller);
            (GARAGE_MCP_OK, json!({ "reply": reply }), None)
        });
        (status, value, ())
    };
    // SAFETY: checked non-null above.
    unsafe { write_result(result, &value) };
    status
}

/// The streamable HTTP transport without a listener, opaque to C: the server and its sessions.
pub struct GarageMcpEndpoint {
    endpoint: Endpoint,
}

/// Makes an endpoint: `{"grpc": {...}}` -> `{}`.
///
/// # Safety
///
/// `request` is a NUL-terminated string; `host` points to a valid [`GarageMcpHost`] whose
/// functions stay callable, from any thread, until [`garage_mcp_endpoint_free`] returns; `endpoint`
/// and `result` point to writable storage. `*endpoint` is set only on success.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn garage_mcp_endpoint_new(
    request: *const c_char,
    host: *const GarageMcpHost,
    endpoint: *mut *mut GarageMcpEndpoint,
    result: *mut *mut c_char,
) -> i32 {
    if result.is_null() || endpoint.is_null() {
        return GARAGE_MCP_BAD_REQUEST;
    }
    // SAFETY: the caller's contract is the function's.
    let (status, value, made) = unsafe {
        guarded(request, host, |request, host| match server_of(request, host) {
            Ok(server) => (GARAGE_MCP_OK, json!({}), Some(Endpoint::new(Arc::new(server)))),
            Err(message) => (GARAGE_MCP_BAD_REQUEST, json!({ "error": message }), None),
        })
    };
    if let Some(made) = made {
        // SAFETY: checked non-null above.
        unsafe { *endpoint = Box::into_raw(Box::new(GarageMcpEndpoint { endpoint: made })) };
    }
    // SAFETY: checked non-null above.
    unsafe { write_result(result, &value) };
    status
}

/// Answers one HTTP exchange, blocking while a tool runs:
/// `{"method": "POST", "headers": {name: value}, "body": "..."}` ->
/// `{"status": 200, "headers": {name: value}, "body": "..."}`. Sessions start at `initialize` and
/// live in the endpoint. The `Host` and `Origin` checks of the listener do not apply. Calls may
/// come from several threads at once.
///
/// # Safety
///
/// `endpoint` came from [`garage_mcp_endpoint_new`] and was not freed; `request` is a
/// NUL-terminated string; `result` points to writable storage for a string the caller frees with
/// [`garage_mcp_string_free`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn garage_mcp_endpoint_exchange(
    endpoint: *const GarageMcpEndpoint,
    request: *const c_char,
    result: *mut *mut c_char,
) -> i32 {
    if result.is_null() || endpoint.is_null() || request.is_null() {
        return GARAGE_MCP_BAD_REQUEST;
    }
    let outcome = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: the caller passes a NUL-terminated string.
        let request = unsafe { CStr::from_ptr(request) };
        match serde_json::from_slice::<Value>(request.to_bytes()) {
            Ok(request @ Value::Object(_)) => {
                // SAFETY: the caller's contract: a live endpoint this library made.
                let endpoint = unsafe { &(*endpoint).endpoint };
                (GARAGE_MCP_OK, endpoint.exchange(&request))
            }
            Ok(_) => (GARAGE_MCP_BAD_REQUEST, json!({ "error": "the request is not a JSON object" })),
            Err(error) => (GARAGE_MCP_BAD_REQUEST, json!({ "error": format!("the request is not JSON: {error}") })),
        }
    }));
    let (status, value) = outcome.unwrap_or_else(|_| (GARAGE_MCP_PANIC, json!({ "error": "the MCP server panicked" })));
    // SAFETY: checked non-null above.
    unsafe { write_result(result, &value) };
    status
}

/// Frees an endpoint and its sessions.
///
/// # Safety
///
/// `endpoint` came from [`garage_mcp_endpoint_new`] and was not freed before (or is null), and no
/// exchange on it is running.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn garage_mcp_endpoint_free(endpoint: *mut GarageMcpEndpoint) {
    if !endpoint.is_null() {
        // SAFETY: the caller's contract: an endpoint this library made with Box::into_raw.
        drop(unsafe { Box::from_raw(endpoint) });
    }
}

/// Frees a result one of the calls above wrote.
///
/// # Safety
///
/// `text` came from this library and was not freed before (or is null).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn garage_mcp_string_free(text: *mut c_char) {
    if !text.is_null() {
        // SAFETY: the caller's contract: a string this library made with CString::into_raw.
        drop(unsafe { CString::from_raw(text) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn call(text: &str, f: impl FnOnce(*const c_char, *mut *mut c_char) -> i32) -> (i32, Value) {
        let text = CString::new(text).unwrap();
        let mut result: *mut c_char = std::ptr::null_mut();
        let status = f(text.as_ptr(), &raw mut result);
        // SAFETY: the library wrote a NUL-terminated string, freed once below.
        let value = serde_json::from_slice(unsafe { CStr::from_ptr(result) }.to_bytes()).unwrap();
        // SAFETY: as above.
        unsafe { garage_mcp_string_free(result) };
        (status, value)
    }

    #[test]
    fn an_endpoint_answers_exchanges_with_sessions_and_no_listener() {
        let host = GarageMcpHost { context: std::ptr::null_mut(), http: None, ensure_llama_model: None, release: None };
        let mut endpoint: *mut GarageMcpEndpoint = std::ptr::null_mut();
        let (status, _) = call(r#"{"grpc": {"socket": "/nonexistent/garage.sock"}}"#, |request, result| {
            // SAFETY: valid pointers for the call; the host has no functions to call.
            unsafe { garage_mcp_endpoint_new(request, &raw const host, &raw mut endpoint, result) }
        });
        assert_eq!(status, GARAGE_MCP_OK);
        assert!(!endpoint.is_null());

        let initialize = json!({
            "method": "POST",
            "headers": {"content-type": "application/json", "accept": "application/json, text/event-stream"},
            "body": json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}).to_string(),
        });
        let (status, reply) = call(&initialize.to_string(), |request, result| {
            // SAFETY: a live endpoint and valid pointers.
            unsafe { garage_mcp_endpoint_exchange(endpoint, request, result) }
        });
        assert_eq!(status, GARAGE_MCP_OK);
        assert_eq!(reply["status"], 200);
        assert!(reply["headers"]["mcp-session-id"].is_string());

        let (status, reply) = call("[]", |request, result| {
            // SAFETY: as above.
            unsafe { garage_mcp_endpoint_exchange(endpoint, request, result) }
        });
        assert_eq!(status, GARAGE_MCP_BAD_REQUEST);
        assert!(reply["error"].is_string());

        // SAFETY: made above, freed once, nothing running.
        unsafe { garage_mcp_endpoint_free(endpoint) };
    }
}

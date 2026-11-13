//! MCP's streamable HTTP transport, as the Python server serves it at `127.0.0.1:8787/mcp`: POST a
//! JSON-RPC message and get the reply as one server-sent event, with a session from `initialize`
//! on (`mcp-session-id`), and the DNS-rebinding checks of the SDK's transport security (the `Host`
//! must be one this server answers to, and an `Origin`, when sent, one it allows).
//!
//! The server sends nothing unasked, so a GET for a standalone event stream is answered 405, which
//! the specification allows. This replaces the Python server's listener at the same address; it
//! adds none.
//!
//! [`Endpoint`] is the transport without a socket: one exchange (method, headers, body) in, one
//! reply out. The listener answers through it, and so can a host that carries MCP's HTTP exchanges
//! some other way (`garage_mcp_exchange`: the App Store build's Garage Door tunnel, over XPC), so
//! sessions and replies are the same whichever way a request came.

use std::collections::HashSet;
use std::convert::Infallible;
use std::fmt::Write as _;
use std::net::{IpAddr, SocketAddr};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;

use bytes::Bytes;
use http_body_util::{BodyExt, Full, Limited};
use hyper::body::Incoming;
use hyper::header::{HeaderMap, HeaderValue};
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper::{Method, Request, Response, StatusCode};
use hyper_util::rt::TokioIo;
use serde_json::{Value, json};
use tokio::sync::watch;

use crate::corpus::{Caller, Transport};
use crate::protocol::{Server, is_request};

/// The largest request body accepted.
pub const MAX_BODY_BYTES: usize = 4 * 1024 * 1024;
const SESSION_HEADER: &str = "mcp-session-id";

/// Where to listen and whom to answer.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HttpOptions {
    pub host: String,
    pub port: u16,
    pub path: String,
    /// `Origin` values a browser page may send.
    pub allowed_origins: Vec<String>,
    /// Extra `Host` values a bind that is not loopback answers to.
    pub allowed_hosts: Vec<String>,
}

impl Default for HttpOptions {
    fn default() -> Self {
        Self {
            host: "127.0.0.1".into(),
            port: 8787,
            path: "/mcp".into(),
            allowed_origins: Vec::new(),
            allowed_hosts: Vec::new(),
        }
    }
}

/// Whether `host` can only be reached from this machine (`server.is_loopback`).
pub fn is_loopback(host: &str) -> bool {
    if matches!(host, "localhost" | "::1" | "127.0.0.1") {
        return true;
    }
    host.parse::<IpAddr>().is_ok_and(|address| address.is_loopback())
}

/// The DNS-rebinding settings `_http_security` builds.
#[derive(Clone, Debug)]
struct Security {
    protect: bool,
    allowed_hosts: HashSet<String>,
    allowed_origins: Vec<String>,
}

impl Security {
    fn new(options: &HttpOptions, port: u16) -> Self {
        let authority = if options.host.contains(':') { format!("[{}]", options.host) } else { options.host.clone() };
        let mut allowed_hosts: HashSet<String> =
            [format!("{authority}:{port}"), format!("localhost:{port}"), format!("127.0.0.1:{port}")].into();
        allowed_hosts.extend(options.allowed_hosts.iter().cloned());
        let protect = is_loopback(&options.host) || !options.allowed_hosts.is_empty();
        if !protect {
            eprintln!(
                "garage-mcp: bound to {} with no allowed hosts: the Host header is not checked, so DNS-rebinding \
                 protection is off",
                options.host
            );
        }
        Self { protect, allowed_hosts, allowed_origins: options.allowed_origins.clone() }
    }

    fn matches(allowed: &[String], value: &str) -> bool {
        allowed.iter().any(|allowed| {
            allowed == value || allowed.strip_suffix(":*").is_some_and(|base| value.starts_with(&format!("{base}:")))
        })
    }

    /// The SDK's `validate_request`: `None` when the request may go on.
    fn check(&self, headers: &HeaderMap, is_post: bool) -> Option<Reply> {
        if let Some(refusal) = content_type_refusal(headers, is_post) {
            return Some(refusal);
        }
        if !self.protect {
            return None;
        }
        let hosts: Vec<String> = self.allowed_hosts.iter().cloned().collect();
        match header(headers, "host") {
            Some(host) if Self::matches(&hosts, host) => {}
            _ => return Some(plain(StatusCode::MISDIRECTED_REQUEST, "Invalid Host header")),
        }
        match header(headers, "origin") {
            None | Some("") => None,
            Some(origin) if Self::matches(&self.allowed_origins, origin) => None,
            Some(_) => Some(plain(StatusCode::FORBIDDEN, "Invalid Origin header")),
        }
    }
}

/// The `content-type` a POST must carry: `None` when the request may go on.
fn content_type_refusal(headers: &HeaderMap, is_post: bool) -> Option<Reply> {
    if !is_post {
        return None;
    }
    let content_type = header(headers, "content-type").map(str::to_ascii_lowercase);
    if content_type.is_some_and(|value| value.starts_with("application/json")) {
        None
    } else {
        Some(plain(StatusCode::BAD_REQUEST, "Invalid Content-Type header"))
    }
}

/// Headers kept out of a caller's attributes: they carry the client's credentials.
const CREDENTIAL_HEADERS: [&str; 3] = ["authorization", "proxy-authorization", "cookie"];

fn header<'a>(headers: &'a HeaderMap, name: &str) -> Option<&'a str> {
    headers.get(name).and_then(|value| value.to_str().ok())
}

/// One reply of the transport, before it is a hyper response or a host's JSON.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Reply {
    pub status: StatusCode,
    pub headers: HeaderMap,
    pub body: Bytes,
}

impl Reply {
    fn new(status: StatusCode, content_type: &'static str, body: impl Into<Bytes>) -> Self {
        let mut headers = HeaderMap::new();
        headers.insert("content-type", HeaderValue::from_static(content_type));
        Self { status, headers, body: body.into() }
    }

    fn with_session(mut self, session: Option<&str>) -> Self {
        if let Some(session) = session
            && let Ok(value) = HeaderValue::from_str(session)
        {
            self.headers.insert(SESSION_HEADER, value);
        }
        self
    }

    fn into_response(self) -> Response<Full<Bytes>> {
        let mut response = Response::new(Full::new(self.body));
        *response.status_mut() = self.status;
        *response.headers_mut() = self.headers;
        response
    }
}

fn plain(status: StatusCode, text: &str) -> Reply {
    Reply::new(status, "text/plain; charset=utf-8", text.to_string())
}

/// A JSON-RPC error with no id, as the transport sends for a request it cannot take.
fn rpc_error(status: StatusCode, code: i64, message: &str, session: Option<&str>) -> Reply {
    let body = json!({"jsonrpc": "2.0", "id": null, "error": {"code": code, "message": message}});
    Reply::new(status, "application/json", body.to_string()).with_session(session)
}

/// A new session id: 32 hex digits from the system's random source.
fn new_session_id() -> String {
    use std::io::Read;
    let mut bytes = [0u8; 16];
    let filled = std::fs::File::open("/dev/urandom").and_then(|mut file| file.read_exact(&mut bytes)).is_ok();
    if !filled {
        use std::hash::{BuildHasher, RandomState};
        let state = RandomState::new();
        for (i, chunk) in bytes.chunks_mut(8).enumerate() {
            chunk.copy_from_slice(&state.hash_one((i, std::time::SystemTime::now())).to_le_bytes());
        }
    }
    bytes.iter().fold(String::with_capacity(32), |mut out, b| {
        let _ = write!(out, "{b:02x}");
        out
    })
}

/// `check_accept_headers`: whether the client takes JSON and server-sent events.
fn accepts(headers: &HeaderMap) -> (bool, bool) {
    let types: Vec<String> = header(headers, "accept")
        .unwrap_or_default()
        .split(',')
        .map(|part| part.split(';').next().unwrap_or_default().trim().to_ascii_lowercase())
        .collect();
    let any = types.iter().any(|t| t == "*/*");
    let json = any || types.iter().any(|t| t == "application/json" || t == "application/*");
    let sse = any || types.iter().any(|t| t == "text/event-stream" || t == "text/*");
    (json, sse)
}

/// The streamable HTTP transport without a socket: the server and its sessions.
///
/// It checks what the specification asks of a request (the method, the session, `Accept`,
/// `Content-Type`, the JSON-RPC envelope) but not the `Host` and `Origin` of the listener's
/// DNS-rebinding protection, which only a socket a browser can reach needs.
pub struct Endpoint {
    server: Arc<Server>,
    sessions: Mutex<HashSet<String>>,
}

impl Endpoint {
    pub fn new(server: Arc<Server>) -> Self {
        Self { server, sessions: Mutex::new(HashSet::new()) }
    }

    /// Answers one exchange, blocking while a tool runs (call it off any async worker).
    pub fn answer(&self, method: &Method, headers: &HeaderMap, body: &[u8]) -> Reply {
        let is_post = method == Method::POST;
        if let Some(refusal) = content_type_refusal(headers, is_post) {
            return refusal;
        }
        match *method {
            Method::POST => match self.admit(headers) {
                Ok(_) if body.len() > MAX_BODY_BYTES => plain(StatusCode::PAYLOAD_TOO_LARGE, "Request body too large"),
                Ok(known) => self.post(headers, known, body),
                Err(refusal) => refusal,
            },
            Method::DELETE => self.delete(headers),
            _ => Self::not_allowed(headers),
        }
    }

    /// [`Endpoint::answer`] in JSON, for hosts that carry exchanges over their own channel:
    /// `{"method": "POST", "headers": {name: value}, "body": "..."}` in,
    /// `{"status": 200, "headers": {name: value}, "body": "..."}` out. Bodies are UTF-8 text, as
    /// MCP's JSON and event streams are; header names come out in lower case.
    pub fn exchange(&self, request: &Value) -> Value {
        let method = request
            .get("method")
            .and_then(Value::as_str)
            .and_then(|method| Method::from_bytes(method.to_ascii_uppercase().as_bytes()).ok())
            .unwrap_or(Method::GET);
        let mut headers = HeaderMap::new();
        if let Some(given) = request.get("headers").and_then(Value::as_object) {
            for (name, value) in given {
                if let (Ok(name), Some(Ok(value))) = (
                    hyper::header::HeaderName::from_bytes(name.to_ascii_lowercase().as_bytes()),
                    value.as_str().map(HeaderValue::from_str),
                ) {
                    headers.insert(name, value);
                }
            }
        }
        let body = request.get("body").and_then(Value::as_str).unwrap_or_default();
        let reply = self.answer(&method, &headers, body.as_bytes());
        let headers: serde_json::Map<String, Value> = reply
            .headers
            .iter()
            .filter_map(|(name, value)| Some((name.as_str().to_string(), json!(value.to_str().ok()?))))
            .collect();
        json!({
            "status": reply.status.as_u16(),
            "headers": headers,
            "body": String::from_utf8_lossy(&reply.body),
        })
    }

    fn caller(headers: &HeaderMap) -> Caller {
        let mut caller = Caller::new(Transport::Http);
        caller.registration_token = header(headers, "authorization")
            .and_then(|value| value.strip_prefix("Bearer ").or_else(|| value.strip_prefix("bearer ")))
            .map(|token| token.trim().to_string())
            .filter(|token| !token.is_empty());
        // The request's headers go along as attributes, and GarageService keeps only those its
        // access policy names (`caller_headers`): a Door's `x-garage-registration`, for one. The
        // headers that carry credentials never leave the transport.
        for (name, value) in headers {
            if CREDENTIAL_HEADERS.contains(&name.as_str()) {
                continue;
            }
            if let Ok(value) = value.to_str() {
                caller.attributes.entry(name.as_str().to_string()).or_insert_with(|| value.to_string());
            }
        }
        caller
    }

    fn not_allowed(headers: &HeaderMap) -> Reply {
        let session = header(headers, SESSION_HEADER);
        let mut reply = rpc_error(StatusCode::METHOD_NOT_ALLOWED, -32600, "Method Not Allowed", session);
        reply.headers.insert("allow", HeaderValue::from_static("POST, DELETE"));
        reply
    }

    /// The session a request names: `Ok(None)` for none, `Err` with the reply for an unknown one.
    #[allow(clippy::result_large_err)]
    fn session(&self, headers: &HeaderMap) -> Result<Option<String>, Reply> {
        match header(headers, SESSION_HEADER) {
            None => Ok(None),
            Some(id) if self.sessions.lock().is_ok_and(|sessions| sessions.contains(id)) => Ok(Some(id.to_string())),
            Some(_) => Err(rpc_error(StatusCode::NOT_FOUND, -32600, "Session not found", None)),
        }
    }

    fn delete(&self, headers: &HeaderMap) -> Reply {
        match self.session(headers) {
            Err(refusal) => refusal,
            Ok(None) => rpc_error(StatusCode::BAD_REQUEST, -32600, "Bad Request: Missing session ID", None),
            Ok(Some(id)) => {
                if let Ok(mut sessions) = self.sessions.lock() {
                    sessions.remove(&id);
                }
                Reply::new(StatusCode::OK, "application/json", Bytes::new()).with_session(Some(&id))
            }
        }
    }

    /// What a POST is checked for before its body is read: the session it names and `Accept`.
    #[allow(clippy::result_large_err)]
    fn admit(&self, headers: &HeaderMap) -> Result<Option<String>, Reply> {
        let known = self.session(headers)?;
        let (json_ok, sse_ok) = accepts(headers);
        if !(json_ok && sse_ok) {
            return Err(rpc_error(
                StatusCode::NOT_ACCEPTABLE,
                -32600,
                "Not Acceptable: Client must accept both application/json and text/event-stream",
                known.as_deref(),
            ));
        }
        Ok(known)
    }

    /// A POST that was admitted: its message answered as one server-sent event. Blocks while the
    /// tool runs.
    fn post(&self, headers: &HeaderMap, known: Option<String>, bytes: &[u8]) -> Reply {
        let message: Value = match serde_json::from_slice(bytes) {
            Ok(message) => message,
            Err(error) => {
                return rpc_error(StatusCode::BAD_REQUEST, -32700, &format!("Parse error: {error}"), known.as_deref());
            }
        };
        if !message.is_object() || message.get("jsonrpc") != Some(&json!("2.0")) {
            return rpc_error(
                StatusCode::BAD_REQUEST,
                -32602,
                "Validation error: not a JSON-RPC 2.0 message",
                known.as_deref(),
            );
        }
        let initializing = message.get("method").and_then(Value::as_str) == Some("initialize");
        let session = match known {
            Some(id) => id,
            None if initializing => {
                let id = new_session_id();
                if let Ok(mut sessions) = self.sessions.lock() {
                    sessions.insert(id.clone());
                }
                id
            }
            None => return rpc_error(StatusCode::BAD_REQUEST, -32600, "Bad Request: Missing session ID", None),
        };
        if !is_request(&message) {
            // A notification or a response: accepted, nothing to say.
            return Reply::new(StatusCode::ACCEPTED, "application/json", Bytes::new()).with_session(Some(&session));
        }
        let reply = self
            .server
            .handle(&message, &Self::caller(headers))
            .unwrap_or_else(|| json!({"jsonrpc": "2.0", "id": null, "error": {"code": -32603, "message": "no reply"}}));
        let mut reply = Reply::new(StatusCode::OK, "text/event-stream", format!("event: message\ndata: {reply}\n\n"))
            .with_session(Some(&session));
        reply.headers.insert("cache-control", HeaderValue::from_static("no-cache, no-transform"));
        reply
    }
}

struct State {
    endpoint: Arc<Endpoint>,
    security: Security,
    path: String,
}

impl State {
    async fn serve(self: Arc<Self>, request: Request<Incoming>) -> Response<Full<Bytes>> {
        let is_post = request.method() == Method::POST;
        if request.uri().path() != self.path {
            return plain(StatusCode::NOT_FOUND, "Not Found").into_response();
        }
        if let Some(refusal) = self.security.check(request.headers(), is_post) {
            return refusal.into_response();
        }
        match *request.method() {
            Method::POST => self.post(request).await.into_response(),
            Method::DELETE => self.endpoint.delete(request.headers()).into_response(),
            _ => Endpoint::not_allowed(request.headers()).into_response(),
        }
    }

    async fn post(self: Arc<Self>, request: Request<Incoming>) -> Reply {
        let (parts, body) = request.into_parts();
        let headers = parts.headers;
        let known = match self.endpoint.admit(&headers) {
            Ok(known) => known,
            Err(refusal) => return refusal,
        };
        let bytes = match Limited::new(body, MAX_BODY_BYTES).collect().await {
            Ok(collected) => collected.to_bytes(),
            Err(_) => return plain(StatusCode::PAYLOAD_TOO_LARGE, "Request body too large"),
        };
        let endpoint = Arc::clone(&self.endpoint);
        // Tools block on the facade and the model: off the async workers.
        tokio::task::spawn_blocking(move || endpoint.post(&headers, known, &bytes))
            .await
            .unwrap_or_else(|_| rpc_error(StatusCode::INTERNAL_SERVER_ERROR, -32603, "the tool's thread failed", None))
    }
}

/// A running HTTP server; dropping it stops it.
pub struct HttpServer {
    address: SocketAddr,
    shutdown: watch::Sender<bool>,
    running: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl HttpServer {
    /// Binds and starts serving on a thread of its own. Returns once the socket is bound.
    ///
    /// # Errors
    ///
    /// Why the server could not start (the address is in use, say).
    pub fn start(server: Arc<Server>, options: &HttpOptions) -> Result<Self, String> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("garage-mcp-http")
            .enable_all()
            .build()
            .map_err(|error| format!("cannot start the HTTP runtime: {error}"))?;
        let host = options.host.trim_start_matches('[').trim_end_matches(']').to_string();
        let listener = runtime
            .block_on(tokio::net::TcpListener::bind((host.as_str(), options.port)))
            .map_err(|error| format!("MCP server cannot listen on {}:{}: {error}", options.host, options.port))?;
        let address = listener.local_addr().map_err(|error| error.to_string())?;
        if !is_loopback(&options.host) {
            eprintln!(
                "garage-mcp: listening on {}, which is reachable from other machines; this server has no \
                 authentication and exposes the whole corpus",
                options.host
            );
        }
        let state = Arc::new(State {
            endpoint: Arc::new(Endpoint::new(server)),
            security: Security::new(options, address.port()),
            path: options.path.clone(),
        });
        let (shutdown, mut stop) = watch::channel(false);
        let running = Arc::new(AtomicBool::new(true));
        let flag = Arc::clone(&running);
        let thread = std::thread::Builder::new()
            .name("garage-mcp-http".into())
            .spawn(move || {
                runtime.block_on(async move {
                    loop {
                        tokio::select! {
                            _ = stop.changed() => break,
                            accepted = listener.accept() => {
                                let Ok((stream, _)) = accepted else { continue };
                                let state = Arc::clone(&state);
                                let mut stop = stop.clone();
                                tokio::spawn(async move {
                                    let service = service_fn(move |request| {
                                        let state = Arc::clone(&state);
                                        async move { Ok::<_, Infallible>(state.serve(request).await) }
                                    });
                                    let connection = http1::Builder::new().serve_connection(TokioIo::new(stream), service);
                                    tokio::pin!(connection);
                                    tokio::select! {
                                        _ = connection.as_mut() => {}
                                        _ = stop.changed() => connection.as_mut().graceful_shutdown(),
                                    }
                                });
                            }
                        }
                    }
                });
                runtime.shutdown_timeout(Duration::from_secs(10));
                flag.store(false, Ordering::SeqCst);
            })
            .map_err(|error| format!("cannot start the HTTP thread: {error}"))?;
        Ok(Self { address, shutdown, running, thread: Some(thread) })
    }

    /// Where it listens (the port chosen, when asked for port 0).
    pub fn address(&self) -> SocketAddr {
        self.address
    }

    pub fn is_running(&self) -> bool {
        self.running.load(Ordering::SeqCst)
    }

    /// Stops accepting, lets requests in flight finish (up to ten seconds), and waits.
    pub fn stop(mut self) {
        self.shutdown_now();
    }

    fn shutdown_now(&mut self) {
        let _ = self.shutdown.send(true);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

impl Drop for HttpServer {
    fn drop(&mut self) {
        self.shutdown_now();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::chat::{Chat, ChatError};
    use crate::corpus::{Corpus, CorpusError, DocumentQuery, SearchQuery};

    struct Empty;

    impl Corpus for Empty {
        fn search(&self, _: &Caller, _: &SearchQuery) -> Result<Value, CorpusError> {
            Ok(json!({"query": "", "results": []}))
        }
        fn document(&self, _: &Caller, _: &DocumentQuery) -> Result<Value, CorpusError> {
            Ok(json!({}))
        }
        fn sources(&self, _: &Caller) -> Result<Value, CorpusError> {
            Ok(json!({"sources": []}))
        }
        fn authors(&self, _: &Caller, _: i32) -> Result<Value, CorpusError> {
            Ok(json!({"authors": []}))
        }
        fn stats(&self, _: &Caller) -> Result<Value, CorpusError> {
            Ok(json!({}))
        }
        fn setting(&self, _: &str) -> Result<Value, CorpusError> {
            Ok(Value::Null)
        }
    }

    fn endpoint() -> Endpoint {
        let chat: crate::tools::ChatFactory =
            Arc::new(|_| Err::<Box<dyn Chat>, _>(ChatError("no model in tests".into())));
        Endpoint::new(Arc::new(Server::with_chat(Arc::new(Empty), chat)))
    }

    fn post(endpoint: &Endpoint, session: Option<&str>, message: &Value) -> Value {
        let mut headers = json!({
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        });
        if let Some(session) = session {
            headers["mcp-session-id"] = json!(session);
        }
        endpoint.exchange(&json!({"method": "POST", "headers": headers, "body": message.to_string()}))
    }

    #[test]
    fn a_session_starts_at_initialize_and_carries_the_calls_after_it() {
        let endpoint = endpoint();
        let initialize = json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t", "version": "1"}}});
        let reply = post(&endpoint, None, &initialize);
        assert_eq!(reply["status"], 200);
        assert_eq!(reply["headers"]["content-type"], "text/event-stream");
        let session = reply["headers"]["mcp-session-id"].as_str().unwrap().to_string();
        assert_eq!(session.len(), 32);
        assert!(reply["body"].as_str().unwrap().starts_with("event: message\ndata: {"));

        let initialized = json!({"jsonrpc": "2.0", "method": "notifications/initialized"});
        let reply = post(&endpoint, Some(&session), &initialized);
        assert_eq!(reply["status"], 202);
        assert_eq!(reply["body"], "");

        let list = json!({"jsonrpc": "2.0", "id": 2, "method": "tools/list"});
        let reply = post(&endpoint, Some(&session), &list);
        assert_eq!(reply["status"], 200);
        assert!(reply["body"].as_str().unwrap().contains("rag_search"));

        let reply = endpoint.exchange(&json!({"method": "DELETE", "headers": {"mcp-session-id": session}}));
        assert_eq!(reply["status"], 200);
        let reply = post(&endpoint, Some(&session), &list);
        assert_eq!(reply["status"], 404);
    }

    #[test]
    fn a_call_without_a_session_or_with_the_wrong_headers_is_refused() {
        let endpoint = endpoint();
        let list = json!({"jsonrpc": "2.0", "id": 2, "method": "tools/list"});
        assert_eq!(post(&endpoint, None, &list)["status"], 400);
        assert_eq!(post(&endpoint, Some("not-a-session"), &list)["status"], 404);

        let reply = endpoint
            .exchange(&json!({"method": "POST", "headers": {"accept": "application/json, text/event-stream"},
            "body": list.to_string()}));
        assert_eq!(reply["status"], 400, "no content-type");
        let reply = endpoint.exchange(&json!({"method": "POST",
            "headers": {"content-type": "application/json", "accept": "application/json"}, "body": list.to_string()}));
        assert_eq!(reply["status"], 406);
        let reply = endpoint.exchange(&json!({"method": "GET", "headers": {}}));
        assert_eq!(reply["status"], 405);
        assert_eq!(reply["headers"]["allow"], "POST, DELETE");
        let reply = post(&endpoint, None, &json!({"id": 1, "method": "initialize"}));
        assert_eq!(reply["status"], 400, "not JSON-RPC 2.0");
    }

    #[test]
    fn no_host_header_is_needed_without_a_socket() {
        // The listener's DNS-rebinding check wants a Host; an exchange carried by the app has none.
        let endpoint = endpoint();
        let initialize = json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}});
        assert_eq!(post(&endpoint, None, &initialize)["status"], 200);
    }

    #[test]
    fn a_caller_carries_the_headers_but_not_the_credentials() {
        let mut headers = HeaderMap::new();
        headers.insert("authorization", HeaderValue::from_static("Bearer gmr_token"));
        headers.insert("cookie", HeaderValue::from_static("session=1"));
        headers.insert("proxy-authorization", HeaderValue::from_static("Basic eA=="));
        headers.insert("x-garage-registration", HeaderValue::from_static("r1"));
        headers.insert("content-type", HeaderValue::from_static("application/json"));
        let caller = Endpoint::caller(&headers);
        assert_eq!(caller.transport, Transport::Http);
        assert_eq!(caller.registration_token.as_deref(), Some("gmr_token"));
        assert_eq!(caller.attributes.get("x-garage-registration").map(String::as_str), Some("r1"));
        assert_eq!(caller.attributes.get("content-type").map(String::as_str), Some("application/json"));
        for secret in CREDENTIAL_HEADERS {
            assert!(!caller.attributes.contains_key(secret), "{secret}");
        }
    }
}

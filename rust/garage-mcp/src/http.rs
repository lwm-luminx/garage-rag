//! MCP's streamable HTTP transport, as the Python server serves it at `127.0.0.1:8787/mcp`: POST a
//! JSON-RPC message and get the reply as one server-sent event, with a session from `initialize`
//! on (`mcp-session-id`), and the DNS-rebinding checks of the SDK's transport security (the `Host`
//! must be one this server answers to, and an `Origin`, when sent, one it allows).
//!
//! The server sends nothing unasked, so a GET for a standalone event stream is answered 405, which
//! the specification allows. This replaces the Python server's listener at the same address; it
//! adds none.

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
    fn check(&self, headers: &HeaderMap, is_post: bool) -> Option<Response<Full<Bytes>>> {
        if is_post {
            let content_type = header(headers, "content-type").map(str::to_ascii_lowercase);
            if !content_type.is_some_and(|value| value.starts_with("application/json")) {
                return Some(plain(StatusCode::BAD_REQUEST, "Invalid Content-Type header"));
            }
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

fn header<'a>(headers: &'a HeaderMap, name: &str) -> Option<&'a str> {
    headers.get(name).and_then(|value| value.to_str().ok())
}

fn plain(status: StatusCode, text: &str) -> Response<Full<Bytes>> {
    let mut response = Response::new(Full::new(Bytes::from(text.to_string())));
    *response.status_mut() = status;
    response.headers_mut().insert("content-type", HeaderValue::from_static("text/plain; charset=utf-8"));
    response
}

/// A JSON-RPC error with no id, as the transport sends for a request it cannot take.
fn rpc_error(status: StatusCode, code: i64, message: &str, session: Option<&str>) -> Response<Full<Bytes>> {
    let body = json!({"jsonrpc": "2.0", "id": null, "error": {"code": code, "message": message}});
    let mut response = Response::new(Full::new(Bytes::from(body.to_string())));
    *response.status_mut() = status;
    response.headers_mut().insert("content-type", HeaderValue::from_static("application/json"));
    with_session(&mut response, session);
    response
}

fn with_session(response: &mut Response<Full<Bytes>>, session: Option<&str>) {
    if let Some(session) = session
        && let Ok(value) = HeaderValue::from_str(session)
    {
        response.headers_mut().insert(SESSION_HEADER, value);
    }
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

struct State {
    server: Arc<Server>,
    security: Security,
    path: String,
    sessions: Mutex<HashSet<String>>,
}

impl State {
    fn caller(headers: &HeaderMap) -> Caller {
        let mut caller = Caller::new(Transport::Http);
        caller.registration_token = header(headers, "authorization")
            .and_then(|value| value.strip_prefix("Bearer ").or_else(|| value.strip_prefix("bearer ")))
            .map(|token| token.trim().to_string())
            .filter(|token| !token.is_empty());
        caller
    }

    async fn serve(self: Arc<Self>, request: Request<Incoming>) -> Response<Full<Bytes>> {
        let is_post = request.method() == Method::POST;
        if request.uri().path() != self.path {
            return plain(StatusCode::NOT_FOUND, "Not Found");
        }
        if let Some(refusal) = self.security.check(request.headers(), is_post) {
            return refusal;
        }
        match *request.method() {
            Method::POST => self.post(request).await,
            Method::DELETE => self.delete(request.headers()),
            _ => {
                let session = header(request.headers(), SESSION_HEADER).map(str::to_string);
                let mut response =
                    rpc_error(StatusCode::METHOD_NOT_ALLOWED, -32600, "Method Not Allowed", session.as_deref());
                response.headers_mut().insert("allow", HeaderValue::from_static("POST, DELETE"));
                response
            }
        }
    }

    /// The session a request names: `Ok(None)` for none, `Err` with the reply for an unknown one.
    #[allow(clippy::result_large_err)]
    fn session(&self, headers: &HeaderMap) -> Result<Option<String>, Response<Full<Bytes>>> {
        match header(headers, SESSION_HEADER) {
            None => Ok(None),
            Some(id) if self.sessions.lock().is_ok_and(|sessions| sessions.contains(id)) => Ok(Some(id.to_string())),
            Some(_) => Err(rpc_error(StatusCode::NOT_FOUND, -32600, "Session not found", None)),
        }
    }

    fn delete(&self, headers: &HeaderMap) -> Response<Full<Bytes>> {
        match self.session(headers) {
            Err(refusal) => refusal,
            Ok(None) => rpc_error(StatusCode::BAD_REQUEST, -32600, "Bad Request: Missing session ID", None),
            Ok(Some(id)) => {
                if let Ok(mut sessions) = self.sessions.lock() {
                    sessions.remove(&id);
                }
                let mut response = Response::new(Full::new(Bytes::new()));
                response.headers_mut().insert("content-type", HeaderValue::from_static("application/json"));
                with_session(&mut response, Some(&id));
                response
            }
        }
    }

    async fn post(self: Arc<Self>, request: Request<Incoming>) -> Response<Full<Bytes>> {
        let (parts, body) = request.into_parts();
        let headers = parts.headers;
        let known = match self.session(&headers) {
            Ok(known) => known,
            Err(refusal) => return refusal,
        };
        let (json_ok, sse_ok) = accepts(&headers);
        if !(json_ok && sse_ok) {
            return rpc_error(
                StatusCode::NOT_ACCEPTABLE,
                -32600,
                "Not Acceptable: Client must accept both application/json and text/event-stream",
                known.as_deref(),
            );
        }
        let bytes = match Limited::new(body, MAX_BODY_BYTES).collect().await {
            Ok(collected) => collected.to_bytes(),
            Err(_) => return plain(StatusCode::PAYLOAD_TOO_LARGE, "Request body too large"),
        };
        let message: Value = match serde_json::from_slice(&bytes) {
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
            let mut response = Response::new(Full::new(Bytes::new()));
            *response.status_mut() = StatusCode::ACCEPTED;
            response.headers_mut().insert("content-type", HeaderValue::from_static("application/json"));
            with_session(&mut response, Some(&session));
            return response;
        }
        let caller = Self::caller(&headers);
        let server = Arc::clone(&self.server);
        // Tools block on the facade and the model: off the async workers.
        let reply = tokio::task::spawn_blocking(move || server.handle(&message, &caller)).await.ok().flatten();
        let reply = reply
            .unwrap_or_else(|| json!({"jsonrpc": "2.0", "id": null, "error": {"code": -32603, "message": "no reply"}}));
        let event = format!("event: message\ndata: {reply}\n\n");
        let mut response = Response::new(Full::new(Bytes::from(event)));
        let headers = response.headers_mut();
        headers.insert("content-type", HeaderValue::from_static("text/event-stream"));
        headers.insert("cache-control", HeaderValue::from_static("no-cache, no-transform"));
        with_session(&mut response, Some(&session));
        response
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
            server,
            security: Security::new(options, address.port()),
            path: options.path.clone(),
            sessions: Mutex::new(HashSet::new()),
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

//! What the service needs from the process it runs in: carrying an approved request to a model
//! server, and embedding a search query with it.
//!
//! In the Mac app the host is Swift (NSXPC to LlamaXPCService, URLSession elsewhere). The plain
//! host here, for the `garage-service` binary and the `garage` CLI, speaks HTTP/1.1 over plain TCP,
//! follows no redirect and uses no proxy, as the Python egress guard's clients did. The egress rules
//! themselves are the embed worker's (`garage_embed::egress`), applied by `get_embedder` before a
//! request is built. Outside the app two things reach LlamaXPCService the way the Python launchers
//! did: a `llama_xpc` request goes over its Unix-domain socket when `GARAGE_LLAMA_SOCKET` names one
//! (`GarageSockets`), and a model it has not loaded is loaded through the app's own GarageService,
//! `EnsureLlamaModel` over `GARAGE_GRPC_SOCKET` (the one call its token does not guard).

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use garage_embed::provider::{BackendKind, get_embedder};
use garage_embed::{Host, HttpRequest, HttpResponse, Settings};
use garage_facade::GrpcTarget;
use garage_facade::proto::EnsureLlamaModelRequest;
use http_body_util::{BodyExt, Full};
use hyper::body::Bytes;
use hyper_util::client::legacy::Client;
use hyper_util::client::legacy::connect::HttpConnector;
use hyper_util::rt::TokioExecutor;
#[cfg(unix)]
use hyper_util::rt::TokioIo;
use tokio::runtime::Handle;

use crate::error::{Result, ServiceError};
use crate::models::EmbeddingModel;
use crate::search::QueryEmbedder;

/// LlamaXPCService's llama-server API socket, as the launchers export it.
pub const LLAMA_SOCKET_ENV: &str = "GARAGE_LLAMA_SOCKET";
/// The app's GarageService socket, as the launchers export it.
pub const GRPC_SOCKET_ENV: &str = "GARAGE_GRPC_SOCKET";

/// The binary's own host: plain HTTP on the runtime `handle`.
pub struct PlainHost {
    handle: Handle,
    client: Client<HttpConnector, Full<Bytes>>,
    /// Where `llama_xpc` requests go instead of their URL's port, when the app's socket is known.
    llama_socket: Option<PathBuf>,
    /// The app's GarageService, which loads llama models on demand for this process.
    app_service: Option<PathBuf>,
}

impl PlainHost {
    /// A host on `handle`, reading `GARAGE_LLAMA_SOCKET` and `GARAGE_GRPC_SOCKET` from the environment.
    pub fn new(handle: Handle) -> Self {
        let path = |name: &str| std::env::var_os(name).map(PathBuf::from).filter(|p| !p.as_os_str().is_empty());
        Self::with_sockets(handle, path(LLAMA_SOCKET_ENV), path(GRPC_SOCKET_ENV))
    }

    /// A host on `handle` with the llama API socket and the app's GarageService socket given.
    pub fn with_sockets(handle: Handle, llama_socket: Option<PathBuf>, app_service: Option<PathBuf>) -> Self {
        let mut connector = HttpConnector::new();
        connector.enforce_http(true);
        connector.set_connect_timeout(Some(Duration::from_secs(10)));
        Self { handle, client: Client::builder(TokioExecutor::new()).build(connector), llama_socket, app_service }
    }

    fn build(request: &HttpRequest, uri: &str) -> std::result::Result<hyper::Request<Full<Bytes>>, String> {
        let mut builder = hyper::Request::builder().method(request.method).uri(uri);
        for (name, value) in &request.headers {
            builder = builder.header(name.as_str(), value.as_str());
        }
        builder.body(Full::new(Bytes::from(request.body.clone()))).map_err(|e| e.to_string())
    }

    /// Sends `request` over the Unix-domain socket at `path` (one HTTP/1.1 connection per request).
    #[cfg(unix)]
    fn over_socket(&self, request: &HttpRequest, path: &Path) -> std::result::Result<HttpResponse, String> {
        let outgoing = Self::build(request, &format!("http://localhost{}", request.path))?;
        let timeout = request.timeout;
        let path = path.to_path_buf();
        self.handle.block_on(async move {
            tokio::time::timeout(timeout, async move {
                let stream = tokio::net::UnixStream::connect(&path)
                    .await
                    .map_err(|e| format!("cannot reach LlamaXPCService at {}: {e}", path.display()))?;
                let (mut sender, connection) =
                    hyper::client::conn::http1::handshake(TokioIo::new(stream)).await.map_err(|e| e.to_string())?;
                tokio::spawn(connection);
                let response = sender.send_request(outgoing).await.map_err(|e| e.to_string())?;
                let status = response.status().as_u16();
                let body = response.into_body().collect().await.map_err(|e| e.to_string())?.to_bytes().to_vec();
                Ok(HttpResponse { status, body })
            })
            .await
            .map_err(|_| format!("timed out after {timeout:?}"))?
        })
    }

    /// Without Unix-domain sockets there is no LlamaXPCService to reach: the request fails as the
    /// Windows services' host answers for `llama_xpc`.
    #[cfg(not(unix))]
    #[allow(clippy::unused_self)]
    fn over_socket(&self, _request: &HttpRequest, path: &Path) -> std::result::Result<HttpResponse, String> {
        Err(format!("cannot reach LlamaXPCService at {}: Unix-domain sockets are not available here", path.display()))
    }
}

impl Host for PlainHost {
    fn http(&self, request: &HttpRequest) -> std::result::Result<HttpResponse, String> {
        if request.backend == BackendKind::LlamaXpc
            && let Some(socket) = &self.llama_socket
        {
            return self.over_socket(request, socket);
        }
        if request.url.starts_with("https://") {
            return Err(format!(
                "{}: the garage-service binary carries plain HTTP only; an https model server needs the app's host",
                request.url
            ));
        }
        let outgoing = Self::build(request, &request.url)?;
        let client = self.client.clone();
        let timeout = request.timeout;
        self.handle.block_on(async move {
            let response = tokio::time::timeout(timeout, client.request(outgoing))
                .await
                .map_err(|_| format!("timed out after {timeout:?}"))?
                .map_err(|e| e.to_string())?;
            let status = response.status().as_u16();
            let body = response.into_body().collect().await.map_err(|e| e.to_string())?.to_bytes().to_vec();
            Ok(HttpResponse { status, body })
        })
    }

    fn ensure_llama_model(&self, model: &str) -> std::result::Result<String, String> {
        let Some(socket) = &self.app_service else {
            return Err(format!(
                "{model} is not loaded, and this process cannot load it: it is not running inside the Garage app \
                 and GARAGE_GRPC_SOCKET names no running app. Open Garage and load {model} on the Models page."
            ));
        };
        let target = GrpcTarget::Socket(socket.clone());
        // Off the runtime: the facade connection blocks on a runtime of its own.
        let model = model.to_owned();
        let loaded = std::thread::scope(|scope| {
            scope
                .spawn(|| {
                    let connection = garage_facade::Connection::connect(&target, None).map_err(|e| e.to_string())?;
                    connection
                        .call(|mut client| async move {
                            client.ensure_llama_model(EnsureLlamaModelRequest { model }).await
                        })
                        .map(|reply| reply.message)
                        .map_err(|e| e.to_string())
                })
                .join()
                .unwrap_or_else(|_| Err("the model loader panicked".to_owned()))
        })?;
        Ok(loaded)
    }
}

/// Embeds search queries and `EmbedText`'s texts through the embed worker's providers, with
/// `settings` naming the servers. A provider that cannot be built (an unknown one, an origin the
/// egress rules refuse) is the caller's mistake; a server that does not answer is `UNAVAILABLE`.
pub struct HostEmbedder {
    pub host: Arc<dyn Host>,
    pub settings: Settings,
}

impl QueryEmbedder for HostEmbedder {
    fn embed_query(&self, model: &EmbeddingModel, query: &str) -> Result<Vec<f32>> {
        let embedder = get_embedder(&model.provider, &model.model_ref, &self.settings, self.host.clone())
            .map_err(|e| ServiceError::invalid(e.to_string()))?;
        let mut vectors = embedder.embed(&[query.to_owned()]).map_err(|e| ServiceError::unavailable(e.to_string()))?;
        vectors
            .pop()
            .filter(|v| !v.is_empty())
            .ok_or_else(|| ServiceError::unavailable("the model returned no embedding"))
    }
}

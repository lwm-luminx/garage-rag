//! What the service needs from the process it runs in: carrying an approved request to a model
//! server, and embedding a search query with it.
//!
//! In the Mac app the host is Swift (NSXPC to LlamaXPCService, URLSession elsewhere). The plain
//! host here, for the `garage-service` binary, speaks HTTP/1.1 over plain TCP, follows no redirect
//! and uses no proxy, as the Python egress guard's clients did. The egress rules themselves are the
//! embed worker's (`garage_embed::egress`), applied by `get_embedder` before a request is built.

use std::sync::Arc;
use std::time::Duration;

use garage_embed::provider::get_embedder;
use garage_embed::{Host, HttpRequest, HttpResponse, Settings};
use http_body_util::{BodyExt, Full};
use hyper::body::Bytes;
use hyper_util::client::legacy::Client;
use hyper_util::client::legacy::connect::HttpConnector;
use hyper_util::rt::TokioExecutor;
use tokio::runtime::Handle;

use crate::error::{Result, ServiceError};
use crate::models::EmbeddingModel;
use crate::search::QueryEmbedder;

/// The binary's own host: plain HTTP on the runtime `handle`.
pub struct PlainHost {
    handle: Handle,
    client: Client<HttpConnector, Full<Bytes>>,
}

impl PlainHost {
    pub fn new(handle: Handle) -> Self {
        let mut connector = HttpConnector::new();
        connector.enforce_http(true);
        connector.set_connect_timeout(Some(Duration::from_secs(10)));
        Self { handle, client: Client::builder(TokioExecutor::new()).build(connector) }
    }
}

impl Host for PlainHost {
    fn http(&self, request: &HttpRequest) -> std::result::Result<HttpResponse, String> {
        if request.url.starts_with("https://") {
            return Err(format!(
                "{}: the garage-service binary carries plain HTTP only; an https model server needs the app's host",
                request.url
            ));
        }
        let mut builder = hyper::Request::builder().method(request.method).uri(&request.url);
        for (name, value) in &request.headers {
            builder = builder.header(name.as_str(), value.as_str());
        }
        let outgoing = builder.body(Full::new(Bytes::from(request.body.clone()))).map_err(|e| e.to_string())?;
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

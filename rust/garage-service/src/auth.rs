//! The per-launch token that guards the port (`garage_rag.service.auth`), as a tower layer.
//!
//! When `GARAGE_GRPC_TOKEN` is set, every call but `EnsureLlamaModel` must carry it as
//! `x-garage-token` metadata or is answered `UNAUTHENTICATED`. Without one, the config-changing
//! methods are answered only by a server bound to the owner-only Unix socket.

use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};

use tonic::body::Body;
use tonic::codegen::http::{Request, Response};
use tonic::{Code, Status};
use tower::{Layer, Service};

pub const TOKEN_ENV: &str = "GARAGE_GRPC_TOKEN";
pub const METADATA_KEY: &str = "x-garage-token";

/// Methods answered without the token: how a stdio `garage-mcp` outside the app gets its
/// `llama_xpc` model loaded.
pub const UNAUTHENTICATED_METHODS: [&str; 1] = ["EnsureLlamaModel"];

/// Methods that write configuration (`garage.json`, an MCP client's config file) or run SQL of the
/// caller's choosing (`InitDb`); answered only for a caller the server can vouch for.
pub const CONFIG_CHANGING_METHODS: [&str; 10] = [
    "InitDb",
    "AddSource",
    "RemoveSource",
    "ImportSourcesToConfig",
    "RegisterModel",
    "SetDefaultModel",
    "DropModel",
    "SetSetting",
    "McpInstall",
    "McpUninstall",
];

/// The token in `GARAGE_GRPC_TOKEN`, or none when it is unset or empty.
pub fn token_from_env() -> Option<String> {
    std::env::var(TOKEN_ENV).ok().map(|t| t.trim().to_owned()).filter(|t| !t.is_empty())
}

/// Constant-time comparison of a presented token against the expected one.
pub fn token_matches(presented: &[u8], expected: &str) -> bool {
    let expected = expected.as_bytes();
    if presented.len() != expected.len() {
        return false;
    }
    presented.iter().zip(expected).fold(0u8, |acc, (a, b)| acc | (a ^ b)) == 0
}

/// Whether a server answers config-changing methods for its callers (`config_change_allowed`):
/// a token authenticates every call; without one only the owner-only socket vouches for them.
pub fn config_change_allowed(token_configured: bool, unix_socket: bool) -> bool {
    token_configured || unix_socket
}

/// The method name of a gRPC path: `/garage.GarageService/Ping` -> `Ping`.
pub fn method_name(path: &str) -> &str {
    path.rsplit('/').next().unwrap_or(path)
}

/// Rejects every call whose `x-garage-token` is not the token (`TokenAuthInterceptor`).
#[derive(Clone)]
pub struct TokenAuthLayer {
    token: Arc<str>,
}

impl TokenAuthLayer {
    pub fn new(token: &str) -> Self {
        Self { token: Arc::from(token) }
    }
}

impl<S> Layer<S> for TokenAuthLayer {
    type Service = TokenAuth<S>;

    fn layer(&self, inner: S) -> Self::Service {
        TokenAuth { inner, token: self.token.clone() }
    }
}

#[derive(Clone)]
pub struct TokenAuth<S> {
    inner: S,
    token: Arc<str>,
}

impl<S: tonic::server::NamedService> tonic::server::NamedService for TokenAuth<S> {
    const NAME: &'static str = S::NAME;
}

type BoxFuture<T> = Pin<Box<dyn Future<Output = T> + Send + 'static>>;

impl<S, ReqBody> Service<Request<ReqBody>> for TokenAuth<S>
where
    S: Service<Request<ReqBody>, Response = Response<Body>> + Clone + Send + 'static,
    S::Future: Send + 'static,
    S::Error: Send + 'static,
    ReqBody: Send + 'static,
{
    type Response = S::Response;
    type Error = S::Error;
    type Future = BoxFuture<Result<Self::Response, Self::Error>>;

    fn poll_ready(&mut self, cx: &mut Context<'_>) -> Poll<Result<(), Self::Error>> {
        self.inner.poll_ready(cx)
    }

    fn call(&mut self, request: Request<ReqBody>) -> Self::Future {
        let authorized = UNAUTHENTICATED_METHODS.contains(&method_name(request.uri().path()))
            || request.headers().get(METADATA_KEY).is_some_and(|value| token_matches(value.as_bytes(), &self.token));
        if authorized {
            // tower's pattern: the ready service is the clone, the original stays ready for the next call.
            let clone = self.inner.clone();
            let mut inner = std::mem::replace(&mut self.inner, clone);
            return Box::pin(async move { inner.call(request).await });
        }
        let status = Status::new(Code::Unauthenticated, format!("missing or invalid {METADATA_KEY}"));
        Box::pin(async move { Ok(status.into_http()) })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tokens_compare_and_methods_resolve() {
        assert!(token_matches(b"abc", "abc"));
        assert!(!token_matches(b"abd", "abc"));
        assert!(!token_matches(b"ab", "abc"));
        assert_eq!(method_name("/garage.GarageService/Ping"), "Ping");
        assert!(config_change_allowed(false, true));
        assert!(!config_change_allowed(false, false));
    }
}

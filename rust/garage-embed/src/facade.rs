//! The database, as the worker reaches it: GarageService's facade calls.
//!
//! [`Facade`] is what the worker needs; [`GrpcFacade`] is GarageService over gRPC, on its Unix
//! socket (`GARAGE_GRPC_SOCKET`) or a TCP port, with the per-launch token as `x-garage-token`.

use std::fmt;
use std::path::PathBuf;

use hyper_util::rt::TokioIo;
use tonic::metadata::{Ascii, MetadataValue};
use tonic::service::Interceptor;
use tonic::service::interceptor::InterceptedService;
use tonic::transport::{Channel, Endpoint, Uri};

use crate::proto::garage_service_client::GarageServiceClient;
use crate::proto::{
    BackfillDistilledRequest, GetEmbeddingBatchesRequest, GetEmbeddingBatchesResponse, GetSettingRequest,
    ListModelsRequest, ModelInfo, UpdateEmbeddingsRequest, UpdateEmbeddingsResponse,
};

/// The largest message either side sends (`service.server.MAX_REQUEST_BYTES`).
pub const MAX_MESSAGE_BYTES: usize = 256 * 1024 * 1024;

/// A facade call that failed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FacadeError {
    /// The model (or anything else named) does not exist: gRPC `NOT_FOUND`.
    NotFound(String),
    /// Anything else: the server unreachable, refusing the token, or failing.
    Failed(String),
}

impl fmt::Display for FacadeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NotFound(message) | Self::Failed(message) => f.write_str(message),
        }
    }
}

impl std::error::Error for FacadeError {}

impl From<tonic::Status> for FacadeError {
    fn from(status: tonic::Status) -> Self {
        let message = if status.message().is_empty() {
            format!("GarageService: {:?}", status.code())
        } else {
            format!("GarageService: {}", status.message())
        };
        if status.code() == tonic::Code::NotFound { Self::NotFound(message) } else { Self::Failed(message) }
    }
}

/// The database calls the worker makes.
pub trait Facade {
    /// Every registered model.
    ///
    /// # Errors
    ///
    /// [`FacadeError`] when the call fails.
    fn list_models(&self) -> Result<Vec<ModelInfo>, FacadeError>;

    /// The next chunks `request.model_slug` has no vector for, with the model's registration.
    ///
    /// # Errors
    ///
    /// [`FacadeError::NotFound`] for an unknown model.
    fn get_embedding_batches(
        &self,
        request: GetEmbeddingBatchesRequest,
    ) -> Result<GetEmbeddingBatchesResponse, FacadeError>;

    /// Stores vectors.
    ///
    /// # Errors
    ///
    /// [`FacadeError`] when the call fails.
    fn update_embeddings(&self, request: UpdateEmbeddingsRequest) -> Result<UpdateEmbeddingsResponse, FacadeError>;

    /// Gives the model's distilled facts their vectors; how many got one.
    ///
    /// # Errors
    ///
    /// [`FacadeError`] when the call fails.
    fn backfill_distilled(&self, model_slug: &str) -> Result<i64, FacadeError>;
}

/// Where GarageService listens.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum GrpcTarget {
    /// Its Unix-domain socket.
    Socket(PathBuf),
    /// A TCP port, on loopback.
    Tcp { host: String, port: u16 },
}

/// Adds the per-launch token, when there is one, to every call.
#[derive(Clone)]
struct Token(Option<MetadataValue<Ascii>>);

impl Interceptor for Token {
    fn call(&mut self, mut request: tonic::Request<()>) -> Result<tonic::Request<()>, tonic::Status> {
        if let Some(token) = &self.0 {
            request.metadata_mut().insert("x-garage-token", token.clone());
        }
        Ok(request)
    }
}

type Client = GarageServiceClient<InterceptedService<Channel, Token>>;

/// GarageService over gRPC. Blocking: each call runs to completion on the facade's own runtime.
pub struct GrpcFacade {
    runtime: tokio::runtime::Runtime,
    client: Client,
}

impl GrpcFacade {
    /// Connects to GarageService. `token` is the per-launch `GARAGE_GRPC_TOKEN`, when one is set.
    ///
    /// # Errors
    ///
    /// [`FacadeError::Failed`] when there is no server to connect to.
    pub fn connect(target: &GrpcTarget, token: Option<&str>) -> Result<Self, FacadeError> {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|error| FacadeError::Failed(format!("cannot start the gRPC runtime: {error}")))?;
        let channel = runtime.block_on(connect(target))?;
        let token = match token.filter(|token| !token.is_empty()) {
            Some(token) => Some(
                MetadataValue::try_from(token)
                    .map_err(|_| FacadeError::Failed("the gRPC token is not valid metadata".into()))?,
            ),
            None => None,
        };
        let client = GarageServiceClient::with_interceptor(channel, Token(token))
            .max_decoding_message_size(MAX_MESSAGE_BYTES)
            .max_encoding_message_size(MAX_MESSAGE_BYTES);
        Ok(Self { runtime, client })
    }

    /// One setting the backend runs with (`GetSetting`, SECTION.KEY as `garage.json` names it),
    /// decoded from its JSON.
    ///
    /// # Errors
    ///
    /// The call's own failure (an unknown key is `NotFound` or `Failed`), or a reply that is not JSON.
    pub fn get_setting(&self, name: &str) -> Result<serde_json::Value, FacadeError> {
        let mut client = self.client.clone();
        let request = GetSettingRequest { name: name.to_string() };
        let reply = self.runtime.block_on(client.get_setting(request))?.into_inner();
        serde_json::from_str(&reply.value_json)
            .map_err(|error| FacadeError::Failed(format!("{name}: GarageService answered with no JSON: {error}")))
    }
}

async fn connect(target: &GrpcTarget) -> Result<Channel, FacadeError> {
    let unreachable = |error: tonic::transport::Error| {
        let source = std::error::Error::source(&error).map_or_else(String::new, |source| format!(": {source}"));
        FacadeError::Failed(format!("cannot reach GarageService at {}: {error}{source}", describe(target)))
    };
    match target {
        #[cfg(unix)]
        GrpcTarget::Socket(path) => {
            let path = path.clone();
            // The URI is required by the API and ignored by the connector.
            Endpoint::from_static("http://garage")
                .connect_with_connector(tower::service_fn(move |_: Uri| {
                    let path = path.clone();
                    async move { Ok::<_, std::io::Error>(TokioIo::new(tokio::net::UnixStream::connect(path).await?)) }
                }))
                .await
                .map_err(unreachable)
        }
        #[cfg(not(unix))]
        GrpcTarget::Socket(_) => Err(FacadeError::Failed(format!(
            "cannot reach GarageService at {}: Unix-domain sockets need Unix",
            describe(target)
        ))),
        GrpcTarget::Tcp { host, port } => {
            let host = if host.contains(':') { format!("[{host}]") } else { host.clone() };
            let endpoint = Endpoint::from_shared(format!("http://{host}:{port}"))
                .map_err(|error| FacadeError::Failed(format!("bad GarageService address: {error}")))?;
            endpoint.connect().await.map_err(unreachable)
        }
    }
}

fn describe(target: &GrpcTarget) -> String {
    match target {
        GrpcTarget::Socket(path) => format!("unix:{}", path.display()),
        GrpcTarget::Tcp { host, port } => format!("{host}:{port}"),
    }
}

impl Facade for GrpcFacade {
    fn list_models(&self) -> Result<Vec<ModelInfo>, FacadeError> {
        let mut client = self.client.clone();
        let response = self.runtime.block_on(client.list_models(ListModelsRequest {}))?;
        Ok(response.into_inner().models)
    }

    fn get_embedding_batches(
        &self,
        request: GetEmbeddingBatchesRequest,
    ) -> Result<GetEmbeddingBatchesResponse, FacadeError> {
        let mut client = self.client.clone();
        Ok(self.runtime.block_on(client.get_embedding_batches(request))?.into_inner())
    }

    fn update_embeddings(&self, request: UpdateEmbeddingsRequest) -> Result<UpdateEmbeddingsResponse, FacadeError> {
        let mut client = self.client.clone();
        Ok(self.runtime.block_on(client.update_embeddings(request))?.into_inner())
    }

    fn backfill_distilled(&self, model_slug: &str) -> Result<i64, FacadeError> {
        let mut client = self.client.clone();
        let request = BackfillDistilledRequest { model_slug: model_slug.to_string() };
        Ok(self.runtime.block_on(client.backfill_distilled(request))?.into_inner().distilled)
    }
}

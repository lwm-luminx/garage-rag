//! The database, as the worker reaches it: GarageService's facade calls.
//!
//! [`Facade`] is what the worker needs; [`GrpcFacade`] is GarageService over gRPC, on its Unix
//! socket (`GARAGE_GRPC_SOCKET`) or a TCP port, with the per-launch token as `x-garage-token`.

use garage_facade::Connection;

use crate::proto::{
    BackfillDistilledRequest, GetEmbeddingBatchesRequest, GetEmbeddingBatchesResponse, GetSettingRequest,
    ListModelsRequest, ModelInfo, UpdateEmbeddingsRequest, UpdateEmbeddingsResponse,
};

pub use garage_facade::{FacadeError, GrpcTarget, MAX_MESSAGE_BYTES};

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

/// GarageService over gRPC. Blocking: each call runs to completion on the facade's own runtime.
pub struct GrpcFacade {
    connection: Connection,
}

impl GrpcFacade {
    /// Connects to GarageService. `token` is the per-launch `GARAGE_GRPC_TOKEN`, when one is set.
    ///
    /// # Errors
    ///
    /// [`FacadeError::Failed`] when there is no server to connect to.
    pub fn connect(target: &GrpcTarget, token: Option<&str>) -> Result<Self, FacadeError> {
        Ok(Self { connection: Connection::connect(target, token)? })
    }

    /// One setting the backend runs with (`GetSetting`, SECTION.KEY as `garage.json` names it),
    /// decoded from its JSON.
    ///
    /// # Errors
    ///
    /// The call's own failure (an unknown key is `NotFound` or `Failed`), or a reply that is not JSON.
    pub fn get_setting(&self, name: &str) -> Result<serde_json::Value, FacadeError> {
        let request = GetSettingRequest { name: name.to_string() };
        let reply = self.connection.call(|mut client| async move { client.get_setting(request).await })?;
        serde_json::from_str(&reply.value_json)
            .map_err(|error| FacadeError::Failed(format!("{name}: GarageService answered with no JSON: {error}")))
    }
}

impl Facade for GrpcFacade {
    fn list_models(&self) -> Result<Vec<ModelInfo>, FacadeError> {
        let reply = self.connection.call(|mut client| async move { client.list_models(ListModelsRequest {}).await })?;
        Ok(reply.models)
    }

    fn get_embedding_batches(
        &self,
        request: GetEmbeddingBatchesRequest,
    ) -> Result<GetEmbeddingBatchesResponse, FacadeError> {
        self.connection.call(|mut client| async move { client.get_embedding_batches(request).await })
    }

    fn update_embeddings(&self, request: UpdateEmbeddingsRequest) -> Result<UpdateEmbeddingsResponse, FacadeError> {
        self.connection.call(|mut client| async move { client.update_embeddings(request).await })
    }

    fn backfill_distilled(&self, model_slug: &str) -> Result<i64, FacadeError> {
        let request = BackfillDistilledRequest { model_slug: model_slug.to_string() };
        let reply = self.connection.call(|mut client| async move { client.backfill_distilled(request).await })?;
        Ok(reply.distilled)
    }
}

//! The part of Garage's configuration the worker reads (`embedding.*` in `garage.json`).

/// Where the model servers are, as `garage_rag.config.Settings` names them. The host fills it from
/// the configuration; [`Settings::default`] is Python's defaults.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Settings {
    /// `embedding.ollama_host`.
    pub ollama_host: String,
    /// `embedding.lmstudio_host` (with `/v1`, which the client strips).
    pub lmstudio_host: String,
    /// `embedding.llama_host`, LlamaXPCService's API (loopback only).
    pub llama_host: String,
    /// LM Studio's bearer token, when the configuration names one
    /// (`GARAGE_LMSTUDIO_API_TOKEN` or `embedding.lmstudio_api_token_file`, read by the host).
    pub lmstudio_api_token: Option<String>,
    /// `embedding.batch_size`: chunks per embedding request.
    pub batch_size: usize,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            ollama_host: "http://localhost:11434".into(),
            lmstudio_host: "http://localhost:1234/v1".into(),
            llama_host: "http://127.0.0.1:8790".into(),
            lmstudio_api_token: None,
            batch_size: 64,
        }
    }
}

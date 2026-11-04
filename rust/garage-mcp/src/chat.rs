//! The local model behind rag_ask, rag_generate and rag_agent: `garage_rag.enrich.generation`'s
//! `LocalChatModel`, on the OpenAI-compatible `POST /v1/chat/completions` of the app's
//! LlamaXPCService, Ollama or LM Studio. There is no cloud path: the server is reached through the
//! host after the egress rules approve it, as the embed worker reaches its model servers.

use std::sync::Arc;

use garage_embed::Host;
use garage_embed::egress::{self, EgressBlocked};
use garage_embed::provider::{Backend, BackendKind, HttpFailure, ModelServer, bad_reply, is_model_not_loaded};
use serde_json::{Map, Value, json};

use crate::corpus::Corpus;

/// `generation.PROVIDERS`.
pub const PROVIDERS: [&str; 3] = ["llama_xpc", "ollama", "lmstudio"];

/// The configuration the model is chosen from, read from the backend (`GetSetting`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ChatSettings {
    /// `facts.provider` / `facts.model`: the distillation model, which answers too by default.
    pub fact_provider: String,
    pub fact_model: String,
    /// `inference.provider` / `inference.model`: the chat model, when one is set.
    pub inference_provider: String,
    pub inference_model: String,
    /// `identity.name`: the corpus owner, so the agent can tie "I" to an author.
    pub self_name: String,
    /// Where the model servers are.
    pub servers: garage_embed::Settings,
}

impl Default for ChatSettings {
    fn default() -> Self {
        Self {
            fact_provider: "llama_xpc".into(),
            fact_model: "gemma2-2b".into(),
            inference_provider: String::new(),
            inference_model: String::new(),
            self_name: String::new(),
            servers: garage_embed::Settings::default(),
        }
    }
}

impl ChatSettings {
    /// The backend's settings, one key at a time; a key it cannot answer keeps its default.
    pub fn from_corpus(corpus: &dyn Corpus) -> Self {
        let mut settings = Self::default();
        let text = |key: &str| match corpus.setting(key) {
            Ok(Value::String(value)) => Some(value),
            _ => None,
        };
        if let Some(value) = text("facts.provider").filter(|v| !v.is_empty()) {
            settings.fact_provider = value;
        }
        if let Some(value) = text("facts.model").filter(|v| !v.is_empty()) {
            settings.fact_model = value;
        }
        if let Some(value) = text("inference.provider") {
            settings.inference_provider = value;
        }
        if let Some(value) = text("inference.model") {
            settings.inference_model = value;
        }
        if let Some(value) = text("identity.name") {
            settings.self_name = value;
        }
        settings.servers = garage_embed::Settings::from_service(|key| corpus.setting(key));
        settings
    }
}

/// The model could not answer, or was never set up; the message says what was tried and how to fix
/// it (`LocalModelUnavailable`, `ValueError`, `EgressBlocked`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ChatError(pub String);

impl std::fmt::Display for ChatError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for ChatError {}

impl From<EgressBlocked> for ChatError {
    fn from(blocked: EgressBlocked) -> Self {
        Self(blocked.0)
    }
}

/// One completion and the server's token accounting (`ChatReply`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ChatReply {
    pub text: String,
    pub prompt_tokens: Option<i64>,
    pub completion_tokens: Option<i64>,
}

/// Something that answers chat messages: [`ChatModel`], or a stand-in in tests.
pub trait Chat: Send + Sync {
    /// The provider's name (`llama_xpc`, `ollama`, `lmstudio`).
    fn provider(&self) -> &str;
    /// The model's name as the provider knows it.
    fn model_ref(&self) -> &str;
    /// The server's URL as configured, which the content rule is checked against.
    fn host_url(&self) -> &str;

    /// One completion; `messages` are OpenAI-style role/content objects.
    ///
    /// # Errors
    ///
    /// [`ChatError`] naming the provider, host and model, and how to fix it.
    fn complete(
        &self,
        messages: &[Value],
        max_tokens: Option<i64>,
        temperature: Option<f64>,
    ) -> Result<ChatReply, ChatError>;
}

/// `LocalChatModel`.
pub struct ChatModel {
    provider: String,
    model_ref: String,
    host_url: String,
    server: ModelServer,
}

impl ChatModel {
    /// The configured model. Makes no request; fails when the provider is unknown or its server is
    /// not an approved destination.
    ///
    /// # Errors
    ///
    /// [`ChatError`] with `ValueError`'s or the egress rule's message.
    pub fn new(settings: &ChatSettings, host: Arc<dyn Host>) -> Result<Self, ChatError> {
        let chosen = &settings.inference_model;
        let provider = if !chosen.is_empty() && !settings.inference_provider.is_empty() {
            settings.inference_provider.clone()
        } else {
            settings.fact_provider.clone()
        };
        let servers = &settings.servers;
        let (kind, host_url, token, retries) = match provider.as_str() {
            "llama_xpc" => (BackendKind::LlamaXpc, servers.llama_host.clone(), None, 0),
            "ollama" => (BackendKind::Ollama, servers.ollama_host.clone(), None, 0),
            "lmstudio" => (BackendKind::LmStudio, servers.lmstudio_host.clone(), servers.lmstudio_api_token.clone(), 2),
            other => {
                return Err(ChatError(format!(
                    "unknown generation provider {}; expected one of ('llama_xpc', 'ollama', 'lmstudio')",
                    crate::pyrepr::str_repr(other)
                )));
            }
        };
        let model_ref = if chosen.is_empty() { settings.fact_model.clone() } else { chosen.clone() };
        egress::check_destination(
            &host_url,
            &format!("generation:{provider}"),
            kind == BackendKind::LlamaXpc,
            servers,
        )?;
        let backend = Backend::new(kind, &host_url, token, retries);
        Ok(Self { provider, model_ref, host_url, server: ModelServer { backend, host } })
    }

    fn unavailable(&self, reason: &str) -> ChatError {
        let label = match self.provider.as_str() {
            "llama_xpc" => "the app's LlamaXPCService",
            "ollama" => "the local Ollama server",
            _ => "the local LM Studio server",
        };
        let hint = match self.provider.as_str() {
            "llama_xpc" => {
                "download it on the app's Models page (Fact distillation); Garage loads it when needed".into()
            }
            "ollama" => format!("pull it with 'ollama pull {}'", self.model_ref),
            _ => format!("download it in LM Studio (or 'lms get {}')", self.model_ref),
        };
        ChatError(format!(
            "local model {} is not available from {label} ({} at {}): {reason}. Check the model name in \
             facts.model and {hint}; or switch facts.provider.",
            crate::pyrepr::str_repr(&self.model_ref),
            self.provider,
            self.host_url
        ))
    }

    fn chat_once(&self, body: &Value) -> Result<ChatReply, HttpFailure> {
        let path = "/v1/chat/completions";
        let payload = self.server.call("POST", path, body)?;
        let content = payload
            .get("choices")
            .and_then(|choices| choices.get(0))
            .and_then(|choice| choice.get("message"))
            .and_then(Value::as_object)
            .map(|message| message.get("content").cloned().unwrap_or(Value::Null))
            .ok_or_else(|| bad_reply(format!("POST {path}: malformed reply")))?;
        let text = match content {
            Value::Null => String::new(),
            Value::String(text) => text,
            other => other.to_string(),
        };
        let usage = payload.get("usage").and_then(Value::as_object).cloned().unwrap_or_else(Map::new);
        let count = |key: &str| usage.get(key).and_then(Value::as_i64);
        Ok(ChatReply {
            text: text.trim().to_string(),
            prompt_tokens: count("prompt_tokens"),
            completion_tokens: count("completion_tokens"),
        })
    }
}

impl Chat for ChatModel {
    fn provider(&self) -> &str {
        &self.provider
    }

    fn model_ref(&self) -> &str {
        &self.model_ref
    }

    fn host_url(&self) -> &str {
        &self.host_url
    }

    fn complete(
        &self,
        messages: &[Value],
        max_tokens: Option<i64>,
        temperature: Option<f64>,
    ) -> Result<ChatReply, ChatError> {
        let mut body = Map::new();
        body.insert("messages".into(), Value::Array(messages.to_vec()));
        if !self.model_ref.is_empty() {
            body.insert("model".into(), json!(self.model_ref));
        }
        if let Some(max_tokens) = max_tokens {
            body.insert("max_tokens".into(), json!(max_tokens));
        }
        if let Some(temperature) = temperature {
            body.insert("temperature".into(), json!(temperature));
        }
        let body = Value::Object(body);
        match self.chat_once(&body) {
            Ok(reply) => Ok(reply),
            // LlamaXPCService holds only the models it was asked to load: have it load this one.
            Err(failure) if self.server.backend.kind == BackendKind::LlamaXpc && is_model_not_loaded(&failure) => {
                match self.server.host.ensure_llama_model(&self.model_ref) {
                    Ok(_) => self.chat_once(&body).map_err(|failure| self.unavailable(&failure.message)),
                    Err(reason) => {
                        Err(self.unavailable(&format!("{}; loading it on demand failed: {reason}", failure.message)))
                    }
                }
            }
            Err(failure) => Err(self.unavailable(&failure.message)),
        }
    }
}

/// The content rule: a communication goes only to a model on this machine.
///
/// # Errors
///
/// [`EgressBlocked`] when `corpus_class` is a communication and the host is not loopback.
pub fn check_content(host_url: &str, purpose: &str, corpus_class: &str) -> Result<(), EgressBlocked> {
    if corpus_class == "communication" && !egress::allows_communications(host_url) {
        return Err(EgressBlocked(format!(
            "{purpose}: communications never leave this machine; {host_url:?} is not a loopback host"
        )));
    }
    Ok(())
}

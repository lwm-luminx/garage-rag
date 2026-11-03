//! The corpus, as the MCP tools read it: GarageService's `Corpus*` calls, whose replies are the
//! Python tools' own results as JSON, so a tool here answers exactly as the Python one does.
//!
//! Every read names its [`Caller`]. Nothing here decides what a caller may see: GarageService
//! does, once the access hooks land (`docs/plans/access-hooks.md`), so the policy has one home
//! whichever server a client reached.

use std::collections::BTreeMap;
use std::future::Future;
use std::sync::{Arc, Mutex};

use garage_facade::proto::{
    CorpusAuthorsRequest, CorpusCaller, CorpusDocumentRequest, CorpusSearchRequest, CorpusSourcesRequest,
    CorpusStatsRequest, GetSettingRequest,
};
use garage_facade::{Client, Connection, FacadeError, GrpcTarget};
use serde_json::Value;

/// How a client reached the server.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Transport {
    Stdio,
    Http,
}

impl Transport {
    pub fn name(self) -> &'static str {
        match self {
            Self::Stdio => "stdio",
            Self::Http => "http",
        }
    }
}

/// Who is reading, as the transport saw it: passed along, never judged here.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Caller {
    pub transport: Transport,
    /// The registration token the client presented (`Authorization: Bearer` over HTTP,
    /// `GARAGE_MCP_TOKEN` over stdio), unverified.
    pub registration_token: Option<String>,
    /// Transport facts a policy may ask for.
    pub attributes: BTreeMap<String, String>,
}

impl Caller {
    pub fn new(transport: Transport) -> Self {
        Self { transport, registration_token: None, attributes: BTreeMap::new() }
    }

    fn proto(&self) -> CorpusCaller {
        CorpusCaller {
            kind: "mcp".into(),
            transport: self.transport.name().into(),
            registration_token: self.registration_token.clone().unwrap_or_default(),
            attributes: self.attributes.iter().map(|(k, v)| (k.clone(), v.clone())).collect(),
        }
    }
}

/// rag_search's query, its filters already lists (empty: no filter).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SearchQuery {
    pub query: String,
    pub limit: i32,
    pub mode: String,
    pub corpus_classes: Vec<String>,
    pub trust_tiers: Vec<String>,
    pub sources: Vec<String>,
    pub author: Option<String>,
    pub direction: Option<String>,
}

/// rag_get_document's: an id, or else a location.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct DocumentQuery {
    pub document_id: Option<i64>,
    pub location: Option<String>,
    pub max_chars: i32,
}

/// A read that failed. The message is the backend's, which the agent shows its model; an MCP
/// client sees only that the tool failed, as from the Python server.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CorpusError(pub String);

impl std::fmt::Display for CorpusError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for CorpusError {}

impl From<FacadeError> for CorpusError {
    fn from(error: FacadeError) -> Self {
        let text = error.to_string();
        // The tool's own words, without the transport's prefix: "no such document: 7".
        Self(text.strip_prefix("GarageService: ").unwrap_or(&text).to_string())
    }
}

/// The reads the tools make. Each result is the Python tool's dataclass, as a JSON object.
pub trait Corpus: Send + Sync {
    /// rag_search's `SearchResult`.
    ///
    /// # Errors
    ///
    /// [`CorpusError`] when the read fails.
    fn search(&self, caller: &Caller, query: &SearchQuery) -> Result<Value, CorpusError>;

    /// rag_get_document's `DocumentResult`.
    ///
    /// # Errors
    ///
    /// [`CorpusError`]: no such document, or the read failed.
    fn document(&self, caller: &Caller, query: &DocumentQuery) -> Result<Value, CorpusError>;

    /// rag_list_sources's `SourceList`.
    ///
    /// # Errors
    ///
    /// [`CorpusError`] when the read fails.
    fn sources(&self, caller: &Caller) -> Result<Value, CorpusError>;

    /// rag_list_authors's `AuthorList`.
    ///
    /// # Errors
    ///
    /// [`CorpusError`] when the read fails.
    fn authors(&self, caller: &Caller, limit: i32) -> Result<Value, CorpusError>;

    /// rag_stats's `CorpusStats`.
    ///
    /// # Errors
    ///
    /// [`CorpusError`] when the read fails.
    fn stats(&self, caller: &Caller) -> Result<Value, CorpusError>;

    /// One setting the backend runs with (SECTION.KEY), for the local model's configuration.
    ///
    /// # Errors
    ///
    /// [`CorpusError`] for an unknown key or a failed call.
    fn setting(&self, name: &str) -> Result<Value, CorpusError>;
}

/// GarageService over gRPC, on its Unix socket or a loopback port, with the per-launch token.
///
/// It connects on first use, not when made, and again after a call finds the server gone, so the
/// MCP server can start before the backend and outlive a restart of it: a tool called meanwhile
/// fails, as the Python server's did while Postgres was down.
pub struct GrpcCorpus {
    target: GrpcTarget,
    token: Option<String>,
    connection: Mutex<Option<Arc<Connection>>>,
}

impl GrpcCorpus {
    /// A corpus that reaches GarageService at `target`. Connects nothing yet.
    pub fn new(target: GrpcTarget, token: Option<String>) -> Self {
        Self { target, token: token.filter(|token| !token.is_empty()), connection: Mutex::new(None) }
    }

    fn connection(&self) -> Result<Arc<Connection>, CorpusError> {
        let mut slot = self.connection.lock().map_err(|_| CorpusError("the connection lock is poisoned".into()))?;
        if let Some(connection) = slot.as_ref() {
            return Ok(Arc::clone(connection));
        }
        let connection = Arc::new(Connection::connect(&self.target, self.token.as_deref())?);
        *slot = Some(Arc::clone(&connection));
        Ok(connection)
    }

    /// Runs one call; a failure drops the connection, so the next call makes a new one.
    fn call<T, F>(&self, call: impl FnOnce(Client) -> F) -> Result<T, CorpusError>
    where
        F: Future<Output = Result<tonic::Response<T>, tonic::Status>>,
    {
        let connection = self.connection()?;
        connection.call(call).map_err(|error| {
            if let FacadeError::Failed(_) = error
                && let Ok(mut slot) = self.connection.lock()
            {
                *slot = None;
            }
            CorpusError::from(error)
        })
    }
}

fn decode(json: &str) -> Result<Value, CorpusError> {
    serde_json::from_str(json).map_err(|error| CorpusError(format!("GarageService answered with no JSON: {error}")))
}

impl Corpus for GrpcCorpus {
    fn search(&self, caller: &Caller, query: &SearchQuery) -> Result<Value, CorpusError> {
        let request = CorpusSearchRequest {
            caller: Some(caller.proto()),
            query: query.query.clone(),
            limit: query.limit,
            mode: query.mode.clone(),
            corpus_classes: query.corpus_classes.clone(),
            trust_tiers: query.trust_tiers.clone(),
            sources: query.sources.clone(),
            author: query.author.clone(),
            direction: query.direction.clone(),
        };
        let reply = self.call(|mut client| async move { client.corpus_search(request).await })?;
        decode(&reply.result_json)
    }

    fn document(&self, caller: &Caller, query: &DocumentQuery) -> Result<Value, CorpusError> {
        let request = CorpusDocumentRequest {
            caller: Some(caller.proto()),
            document_id: query.document_id,
            location: query.location.clone().unwrap_or_default(),
            max_chars: query.max_chars,
        };
        let reply = self.call(|mut client| async move { client.corpus_document(request).await })?;
        decode(&reply.result_json)
    }

    fn sources(&self, caller: &Caller) -> Result<Value, CorpusError> {
        let request = CorpusSourcesRequest { caller: Some(caller.proto()) };
        let reply = self.call(|mut client| async move { client.corpus_sources(request).await })?;
        decode(&reply.result_json)
    }

    fn authors(&self, caller: &Caller, limit: i32) -> Result<Value, CorpusError> {
        let request = CorpusAuthorsRequest { caller: Some(caller.proto()), limit };
        let reply = self.call(|mut client| async move { client.corpus_authors(request).await })?;
        decode(&reply.result_json)
    }

    fn stats(&self, caller: &Caller) -> Result<Value, CorpusError> {
        let request = CorpusStatsRequest { caller: Some(caller.proto()) };
        let reply = self.call(|mut client| async move { client.corpus_stats(request).await })?;
        decode(&reply.result_json)
    }

    fn setting(&self, name: &str) -> Result<Value, CorpusError> {
        let request = GetSettingRequest { name: name.to_string() };
        let reply = self.call(|mut client| async move { client.get_setting(request).await })?;
        decode(&reply.value_json)
    }
}

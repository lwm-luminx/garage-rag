//! The access hooks on the service's side (`docs/plans/access-hooks.md`): the build's policy, the
//! caller of each read, and the one place a policy's answer becomes SQL or a refusal.
//!
//! The policy is whatever the linked extension registers (`garage_access_extension`, which a plain
//! build takes from `garage-access-none`, so [`NullPolicy`](garage_access::NullPolicy)). Read
//! paths ask [`AccessGate`], never the policy, so a policy that fails is handled in one place: the
//! read fails, and the caller is told nothing about the corpus.

use std::collections::HashSet;
use std::sync::{Arc, OnceLock};

use garage_access::{AccessError, AccessPolicy, Caller, NullPolicy, Registration, Registry, SqlFilter};
use garage_facade::proto::CorpusCaller;
use tokio_postgres::types::ToSql;

use crate::db::Client;
use crate::error::ServiceError;
use crate::registrations;

/// The policy the linked extension registers, made once per process.
///
/// # Errors
///
/// The extension registered more than one policy: the service does not start.
pub fn installed_policy() -> Result<Arc<dyn AccessPolicy>, AccessError> {
    static POLICY: OnceLock<Result<Arc<dyn AccessPolicy>, AccessError>> = OnceLock::new();
    POLICY
        .get_or_init(|| {
            let mut registry = Registry::new();
            garage_access_extension::register(&mut registry);
            registry.into_policy()
        })
        .clone()
}

/// What a refused or failed policy answer tells the caller: nothing about the corpus.
const POLICY_FAILED: &str = "the access policy could not decide; nothing was read";

/// The policy, asked on behalf of the service's read paths.
#[derive(Clone)]
pub struct AccessGate {
    policy: Arc<dyn AccessPolicy>,
}

impl AccessGate {
    pub fn new(policy: Arc<dyn AccessPolicy>) -> Self {
        Self { policy }
    }

    /// The policy's name (`none` with no policy).
    pub fn name(&self) -> &str {
        self.policy.name()
    }

    /// Whether the build has a policy at all. Without one nothing about a caller is looked up.
    pub fn is_null(&self) -> bool {
        self.policy.name() == NullPolicy::NAME
    }

    /// The caller of an MCP read, from what `garage-mcp` passed along: the registration its token
    /// proves (`registrations::resolve`), and only the headers the policy asked for. With no policy,
    /// no registration is looked up.
    ///
    /// # Errors
    ///
    /// The server.
    pub async fn mcp_caller(&self, client: &Client, given: Option<&CorpusCaller>) -> Result<Caller, ServiceError> {
        let Some(given) = given else { return Ok(Caller::mcp("stdio", None)) };
        let registration =
            if self.is_null() { None } else { registrations::resolve(client, &given.registration_token).await? };
        Ok(Self::caller_from(&self.policy.caller_headers(), given, registration))
    }

    /// A registration was uninstalled; tells the policy, after the row is gone.
    pub async fn registration_removed(&self, registration_id: &str) {
        self.policy.on_registration_removed(registration_id).await;
    }

    fn caller_from(headers: &[String], given: &CorpusCaller, registration: Option<Registration>) -> Caller {
        let wanted: HashSet<String> = headers.iter().map(|h| h.to_ascii_lowercase()).collect();
        let attributes = given
            .attributes
            .iter()
            .filter(|(key, _)| wanted.contains(&key.to_ascii_lowercase()))
            .map(|(key, value)| (key.to_ascii_lowercase(), value.clone()))
            .collect();
        let transport = if given.transport.is_empty() { "stdio" } else { given.transport.as_str() };
        Caller::mcp(transport, registration).with_attributes(attributes)
    }

    /// The condition for what `caller` may see, or `None` for everything.
    ///
    /// # Errors
    ///
    /// The policy failed; the message names no document.
    pub async fn filter(&self, client: &Client, caller: &Caller) -> Result<Option<SqlFilter>, ServiceError> {
        self.policy.document_filter(client, caller).await.map_err(|error| refused(self.policy.name(), &error))
    }
}

/// The policy's failure, logged in full and reported as nothing in particular.
fn refused(policy: &str, error: &AccessError) -> ServiceError {
    eprintln!("access policy {policy}: {error}");
    ServiceError::failed(POLICY_FAILED)
}

/// A filter's SQL and parameters appended to a statement that binds `params` already: the
/// condition to put in its `WHERE`.
///
/// # Errors
///
/// A filter that does not render (a policy's mistake): the read fails as the policy's failure.
pub fn append_filter(filter: &SqlFilter, params: &mut Vec<Param>) -> Result<String, ServiceError> {
    let condition = filter.render(params.len()).map_err(|error| refused("filter", &error))?;
    params.extend(filter.params.iter().cloned().map(|p| Box::new(p) as Box<dyn ToSql + Sync + Send>));
    Ok(condition)
}

/// A bind parameter of a statement built one condition at a time.
pub type Param = Box<dyn ToSql + Sync + Send>;

/// `column IN (...)`, true for the document ids `filter` lets through, or `TRUE` with no filter.
/// The filter's own aliases (`d`, `s`) live in the subquery, so `column` can be any expression of
/// the outer statement (`d.id`, `da.document_id`, `c.document_id`).
///
/// # Errors
///
/// A filter that does not render.
pub fn document_condition(
    column: &str,
    filter: Option<&SqlFilter>,
    params: &mut Vec<Param>,
) -> Result<String, ServiceError> {
    let Some(filter) = filter else { return Ok("TRUE".to_owned()) };
    let condition = append_filter(filter, params)?;
    Ok(format!(
        "{column} IN (SELECT d.id FROM documents d LEFT JOIN sources s ON s.id = d.source_id WHERE {condition})"
    ))
}

/// The statement's parameters as `query` takes them.
pub fn refs(params: &[Param]) -> Vec<&(dyn ToSql + Sync)> {
    params.iter().map(|p| p.as_ref() as &(dyn ToSql + Sync)).collect()
}

impl From<AccessError> for ServiceError {
    fn from(error: AccessError) -> Self {
        refused("extension", &error)
    }
}

/// How each GarageService method stands with the hooks (`docs/plans/access-hooks.md`, "Where the
/// hooks go"). A test holds it to `proto/garage.proto`, so a new method has to be placed here.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ReadPath {
    /// Reads the corpus for a caller and asks the policy.
    Asks,
    /// Reads the corpus for a caller and does not ask yet; the plan's next step adds it.
    NotYet,
    /// Reads no document content for a caller: system calls, configuration, operations and the
    /// workers' facade, which the app's own services call.
    NotARead,
}

/// Every GarageService method and how it stands.
pub const READ_PATHS: &[(&str, ReadPath)] = &[
    ("Ping", ReadPath::NotARead),
    ("GetStatus", ReadPath::NotARead),
    ("GetVersion", ReadPath::NotARead),
    ("Search", ReadPath::Asks),
    ("ListDocuments", ReadPath::Asks),
    ("GetDocument", ReadPath::Asks),
    ("ListFacts", ReadPath::NotYet),
    ("GetFactStats", ReadPath::NotYet),
    ("ListSources", ReadPath::NotYet),
    ("AddSource", ReadPath::NotARead),
    ("RemoveSource", ReadPath::NotARead),
    ("Scan", ReadPath::NotARead),
    ("SyncSources", ReadPath::NotARead),
    ("ImportSourcesToConfig", ReadPath::NotARead),
    ("Reconcile", ReadPath::NotARead),
    ("ListModels", ReadPath::NotARead),
    ("RegisterModel", ReadPath::NotARead),
    ("SetDefaultModel", ReadPath::NotARead),
    ("DropModel", ReadPath::NotARead),
    ("Backfill", ReadPath::NotARead),
    ("EmbedText", ReadPath::NotARead),
    ("EnsureLlamaModel", ReadPath::NotARead),
    ("EnrichFacts", ReadPath::NotARead),
    ("ClusterFacts", ReadPath::NotARead),
    ("ListFactPrompts", ReadPath::NotARead),
    ("GetGraphLabels", ReadPath::NotYet),
    ("FindGraphVertices", ReadPath::NotYet),
    ("GetGraphNeighborhood", ReadPath::NotYet),
    ("GetStats", ReadPath::NotYet),
    ("InitDb", ReadPath::NotARead),
    ("GetSetting", ReadPath::NotARead),
    ("SetSetting", ReadPath::NotARead),
    ("McpInstall", ReadPath::NotARead),
    ("McpUninstall", ReadPath::NotARead),
    ("McpStatus", ReadPath::NotARead),
    ("BeginIngestSession", ReadPath::NotARead),
    ("PersistScan", ReadPath::NotARead),
    ("CheckDocumentStat", ReadPath::NotARead),
    ("PersistDocument", ReadPath::NotARead),
    ("FinalizeIngestSession", ReadPath::NotARead),
    ("GetEmbeddingBatches", ReadPath::NotARead),
    ("UpdateEmbeddings", ReadPath::NotARead),
    ("BackfillDistilled", ReadPath::NotARead),
    ("CorpusSearch", ReadPath::Asks),
    ("CorpusDocument", ReadPath::Asks),
    ("CorpusSources", ReadPath::Asks),
    ("CorpusAuthors", ReadPath::Asks),
    ("CorpusStats", ReadPath::Asks),
];

#[cfg(test)]
mod tests {
    use super::*;
    use garage_access::CallerKind;

    struct Headers;

    impl AccessPolicy for Headers {
        fn name(&self) -> &'static str {
            "headers"
        }

        fn caller_headers(&self) -> Vec<String> {
            vec!["Garage-Door-Client".into()]
        }
    }

    #[test]
    fn every_method_of_the_service_is_placed() {
        let proto = include_str!("../../../proto/garage.proto");
        let methods: Vec<&str> = proto
            .lines()
            .filter_map(|line| line.trim().strip_prefix("rpc "))
            .map(|rest| rest.split(|c: char| c == '(' || c.is_whitespace()).next().unwrap_or_default())
            .collect();
        let placed: Vec<&str> = READ_PATHS.iter().map(|(name, _)| *name).collect();
        let unplaced: Vec<&&str> = methods.iter().filter(|m| !placed.contains(m)).collect();
        assert!(unplaced.is_empty(), "place these in READ_PATHS (docs/plans/access-hooks.md): {unplaced:?}");
        let gone: Vec<&&str> = placed.iter().filter(|p| !methods.contains(p)).collect();
        assert!(gone.is_empty(), "no longer in garage.proto: {gone:?}");
    }

    #[test]
    fn a_plain_build_has_no_policy() {
        assert_eq!(installed_policy().unwrap().name(), NullPolicy::NAME);
    }

    #[test]
    fn an_mcp_caller_keeps_only_the_headers_the_policy_asked_for() {
        let given = CorpusCaller {
            kind: "mcp".into(),
            transport: "http".into(),
            registration_token: "gmr_unchecked".into(),
            attributes: [("garage-door-client".to_owned(), "phone".to_owned()), ("cookie".to_owned(), "x".to_owned())]
                .into_iter()
                .collect(),
        };
        let caller = AccessGate::caller_from(&Headers.caller_headers(), &given, None);
        assert_eq!(caller.kind, CallerKind::Mcp);
        assert_eq!(caller.transport, "http");
        assert_eq!(caller.registration, None);
        assert_eq!(caller.attributes.into_iter().collect::<Vec<_>>(), [("garage-door-client".into(), "phone".into())]);
        let none = AccessGate::caller_from(&NullPolicy.caller_headers(), &given, None);
        assert!(none.attributes.is_empty());
    }

    #[test]
    fn a_filter_is_appended_after_the_statements_own_parameters() {
        let mut params: Vec<Box<dyn ToSql + Sync + Send>> = vec![Box::new(1i64), Box::new("x".to_owned())];
        let filter = SqlFilter::new("d.id <> $1::bigint", vec![garage_access::SqlValue::Int(9)]);
        assert_eq!(append_filter(&filter, &mut params).unwrap(), "(d.id <> $3::bigint)");
        assert_eq!(params.len(), 3);
    }
}

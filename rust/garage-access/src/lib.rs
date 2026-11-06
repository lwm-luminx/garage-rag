//! The access hooks (`docs/plans/access-hooks.md`): who is reading the corpus, and the seam where an
//! extension's access policy decides what that reader may see.
//!
//! Garage ships no policy. A plain build links `garage-access-none`, whose `register` adds nothing,
//! so [`Registry::into_policy`] gives [`NullPolicy`], every caller sees everything, and no read's
//! SQL changes. A build with a policy links its own extension in its place (Bazel's
//! `//rust/garage-access:extension`): the choice is made when the binary is linked, never by a
//! setting or at run time.
//!
//! A policy hides whole documents. It answers with a [`SqlFilter`] over the document (`d`) and its
//! source (`s`), which every read path puts inside its own `WHERE`, so a filtered search still fills
//! its limit and a hidden document reads exactly as a missing one.

use std::collections::BTreeMap;
use std::error::Error;
use std::fmt;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

use tokio_postgres::types::{IsNull, ToSql, Type, to_sql_checked};

/// Who a read is for.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum CallerKind {
    /// The app's pages: a gRPC call the server vouches for (the app's per-launch token, or the
    /// Unix socket in the app's container).
    App,
    /// `garage` on a terminal, running the service in its own process.
    Cli,
    /// An MCP assistant, through `garage-mcp`'s `Corpus*` calls.
    Mcp,
    /// A gRPC call the server cannot vouch for: a TCP port with no token (`garage serve` by hand).
    Unverified,
}

impl CallerKind {
    pub fn name(self) -> &'static str {
        match self {
            Self::App => "app",
            Self::Cli => "cli",
            Self::Mcp => "mcp",
            Self::Unverified => "unverified",
        }
    }
}

/// An MCP registration, proved by the token it carries.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Registration {
    /// Stable, minted with the registration and never reused; survives Reset token. A policy keys
    /// its rules on it as a value, never as a foreign key: under v2 registrations move to a catalog
    /// database of their own.
    pub id: String,
    /// For display only; the user may rename it.
    pub name: String,
    /// `claude-desktop`, `cursor`, `garage-door`, ...
    pub client: String,
}

/// Who is reading, as the server established it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Caller {
    pub kind: CallerKind,
    /// For [`CallerKind::Mcp`]: the registration its token proved, or `None` (no token, an unknown
    /// one, a revoked one).
    pub registration: Option<Registration>,
    /// `grpc`, `stdio`, `http` or `local`.
    pub transport: String,
    /// Transport facts the policy asked for ([`AccessPolicy::caller_headers`]), uninterpreted. A
    /// policy honours them only from registrations it trusts to set them.
    pub attributes: BTreeMap<String, String>,
}

impl Caller {
    /// The app's pages, over gRPC.
    pub fn app() -> Self {
        Self::new(CallerKind::App, "grpc")
    }

    /// `garage` on a terminal.
    pub fn cli() -> Self {
        Self::new(CallerKind::Cli, "local")
    }

    /// A gRPC caller the server cannot vouch for.
    pub fn unverified() -> Self {
        Self::new(CallerKind::Unverified, "grpc")
    }

    /// An MCP client over `transport`, with the registration its token proved, if any.
    pub fn mcp(transport: impl Into<String>, registration: Option<Registration>) -> Self {
        Self { registration, ..Self::new(CallerKind::Mcp, transport) }
    }

    fn new(kind: CallerKind, transport: impl Into<String>) -> Self {
        Self { kind, registration: None, transport: transport.into(), attributes: BTreeMap::new() }
    }

    /// The same caller with these transport facts.
    #[must_use]
    pub fn with_attributes(mut self, attributes: BTreeMap<String, String>) -> Self {
        self.attributes = attributes;
        self
    }
}

/// A bind parameter of a [`SqlFilter`]. A closed set, so a filter can be cloned, compared and
/// logged, and the policy cannot hand the search an arbitrary type.
#[derive(Clone, Debug, PartialEq)]
pub enum SqlValue {
    Bool(bool),
    Int(i64),
    Text(String),
    IntArray(Vec<i64>),
    TextArray(Vec<String>),
}

impl ToSql for SqlValue {
    fn to_sql(&self, ty: &Type, out: &mut bytes::BytesMut) -> Result<IsNull, Box<dyn Error + Sync + Send>> {
        match self {
            Self::Bool(v) => v.to_sql(ty, out),
            Self::Int(v) => v.to_sql(ty, out),
            Self::Text(v) => v.to_sql(ty, out),
            Self::IntArray(v) => v.to_sql(ty, out),
            Self::TextArray(v) => v.to_sql(ty, out),
        }
    }

    fn accepts(ty: &Type) -> bool {
        <bool as ToSql>::accepts(ty)
            || <i64 as ToSql>::accepts(ty)
            || <String as ToSql>::accepts(ty)
            || <Vec<i64> as ToSql>::accepts(ty)
            || <Vec<String> as ToSql>::accepts(ty)
    }

    to_sql_checked!();
}

/// A condition a policy adds to a read: SQL over the document (`d`, `documents`) and its source
/// (`s`, `sources`), true for the documents the caller may see.
///
/// The SQL numbers its own parameters `$1`..`$n`, in the order of `params`, and casts each
/// (`$1::bigint[]`) so the server can type it; [`SqlFilter::render`] moves them past the read's
/// own. It must hold no other `$`: no dollar quoting, and no `$` in a literal.
#[derive(Clone, Debug, PartialEq)]
pub struct SqlFilter {
    pub sql: String,
    pub params: Vec<SqlValue>,
}

impl SqlFilter {
    pub fn new(sql: impl Into<String>, params: Vec<SqlValue>) -> Self {
        Self { sql: sql.into(), params }
    }

    /// The SQL with each `$k` renumbered to `$(k + offset)`, for a statement that already binds
    /// `offset` parameters, in parentheses.
    ///
    /// # Errors
    ///
    /// A `$` not followed by a parameter number, or a number outside `1..=params.len()`.
    pub fn render(&self, offset: usize) -> Result<String, AccessError> {
        let mut out = String::with_capacity(self.sql.len() + 2);
        out.push('(');
        let mut chars = self.sql.char_indices().peekable();
        while let Some((_, ch)) = chars.next() {
            if ch != '$' {
                out.push(ch);
                continue;
            }
            let mut digits = String::new();
            while let Some(&(_, d)) = chars.peek().filter(|(_, d)| d.is_ascii_digit()) {
                digits.push(d);
                chars.next();
            }
            let index: usize = digits
                .parse()
                .map_err(|_| AccessError::new("the policy's filter has a '$' that is not a parameter"))?;
            if index == 0 || index > self.params.len() {
                return Err(AccessError::new(format!(
                    "the policy's filter names ${index} but binds {} parameters",
                    self.params.len()
                )));
            }
            out.push('$');
            out.push_str(&(index + offset).to_string());
        }
        out.push(')');
        Ok(out)
    }
}

/// Why a policy could not answer. The read fails with it: a policy that cannot decide never falls
/// back to showing everything. The message is for the log; the caller is told nothing about the
/// corpus.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AccessError(pub String);

impl AccessError {
    pub fn new(message: impl Into<String>) -> Self {
        Self(message.into())
    }
}

impl fmt::Display for AccessError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl Error for AccessError {}

impl From<tokio_postgres::Error> for AccessError {
    fn from(error: tokio_postgres::Error) -> Self {
        Self(error.to_string())
    }
}

/// A boxed future, as [`AccessPolicy`]'s methods return so the trait can be used as `dyn`.
pub type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// What an access policy decides. Every method but [`name`](Self::name) has a default that
/// restricts nothing, so a policy implements what it uses.
pub trait AccessPolicy: Send + Sync {
    /// The policy's name, which the app shows (`GetStatus`) and the logs name.
    fn name(&self) -> &str;

    /// The request headers the HTTP MCP transport passes in [`Caller::attributes`]; no others are.
    fn caller_headers(&self) -> Vec<String> {
        Vec::new()
    }

    /// The condition for the documents `caller` may see, or `None` when it sees every one, so its
    /// reads run exactly as with no policy. `client` reads the policy's own tables.
    ///
    /// # Errors
    ///
    /// Anything that keeps the policy from deciding; the read then fails.
    fn document_filter<'a>(
        &'a self,
        client: &'a tokio_postgres::Client,
        caller: &'a Caller,
    ) -> BoxFuture<'a, Result<Option<SqlFilter>, AccessError>> {
        let _ = (client, caller);
        Box::pin(async { Ok(None) })
    }

    /// A registration was uninstalled and its row deleted, after that committed.
    fn on_registration_removed<'a>(&'a self, registration_id: &'a str) -> BoxFuture<'a, ()> {
        let _ = registration_id;
        Box::pin(async {})
    }
}

/// The policy of a build with none: every caller sees everything.
#[derive(Clone, Copy, Debug, Default)]
pub struct NullPolicy;

impl NullPolicy {
    pub const NAME: &'static str = "none";
}

impl AccessPolicy for NullPolicy {
    fn name(&self) -> &str {
        Self::NAME
    }
}

/// Where an extension declares what it provides. Only the access policy so far; the plan's config
/// sections, SQL and gRPC services join it as they are needed.
#[derive(Default)]
pub struct Registry {
    policy: Option<Arc<dyn AccessPolicy>>,
    error: Option<AccessError>,
}

impl Registry {
    pub fn new() -> Self {
        Self::default()
    }

    /// Installs the build's policy. There is at most one: a second is an error, never a silent
    /// override, and it stays an error at [`into_policy`](Self::into_policy) even if the extension
    /// ignores this result.
    ///
    /// # Errors
    ///
    /// A policy is already registered.
    pub fn register_access_policy(&mut self, policy: Arc<dyn AccessPolicy>) -> Result<(), AccessError> {
        if let Some(existing) = &self.policy {
            let error = AccessError::new(format!(
                "an access policy ({}) is already registered; {} cannot be added",
                existing.name(),
                policy.name()
            ));
            self.error.get_or_insert_with(|| error.clone());
            return Err(error);
        }
        self.policy = Some(policy);
        Ok(())
    }

    /// The registered policy, or [`NullPolicy`].
    ///
    /// # Errors
    ///
    /// A registration failed.
    pub fn into_policy(self) -> Result<Arc<dyn AccessPolicy>, AccessError> {
        if let Some(error) = self.error {
            return Err(error);
        }
        Ok(self.policy.unwrap_or_else(|| Arc::new(NullPolicy)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_filter_is_renumbered_past_the_reads_own_parameters() {
        let filter = SqlFilter::new(
            "NOT (d.id = ANY($1::bigint[])) AND s.slug <> $2::text",
            vec![SqlValue::IntArray(vec![1]), SqlValue::Text("x".into())],
        );
        assert_eq!(filter.render(0).unwrap(), "(NOT (d.id = ANY($1::bigint[])) AND s.slug <> $2::text)");
        assert_eq!(filter.render(7).unwrap(), "(NOT (d.id = ANY($8::bigint[])) AND s.slug <> $9::text)");
        assert_eq!(SqlFilter::new("$10 > 0", vec![SqlValue::Int(0); 10]).render(5).unwrap(), "($15 > 0)");
    }

    #[test]
    fn a_stray_dollar_or_an_unbound_parameter_is_refused() {
        assert!(SqlFilter::new("d.title = '$x'", vec![]).render(0).is_err());
        assert!(SqlFilter::new("d.id = $2::bigint", vec![SqlValue::Int(1)]).render(0).is_err());
        assert!(SqlFilter::new("d.id = $0::bigint", vec![SqlValue::Int(1)]).render(0).is_err());
    }

    struct Named(&'static str);

    impl AccessPolicy for Named {
        fn name(&self) -> &str {
            self.0
        }
    }

    #[test]
    fn with_none_registered_the_null_policy_restricts_nothing() {
        let policy = Registry::new().into_policy().unwrap();
        assert_eq!(policy.name(), NullPolicy::NAME);
        assert!(policy.caller_headers().is_empty());
    }

    #[test]
    fn a_second_policy_is_an_error() {
        let mut registry = Registry::new();
        registry.register_access_policy(Arc::new(Named("first"))).unwrap();
        let error = registry.register_access_policy(Arc::new(Named("second"))).unwrap_err();
        assert!(error.0.contains("first"), "{error}");
        assert_eq!(registry.into_policy().err(), Some(error));
    }

    #[test]
    fn callers_say_who_they_are() {
        let registration = Registration { id: "r1".into(), name: "Claude".into(), client: "claude-desktop".into() };
        let caller = Caller::mcp("stdio", Some(registration.clone()));
        assert_eq!(caller.kind.name(), "mcp");
        assert_eq!(caller.registration, Some(registration));
        assert_eq!(Caller::app().kind, CallerKind::App);
        assert_eq!(Caller::cli().transport, "local");
    }
}

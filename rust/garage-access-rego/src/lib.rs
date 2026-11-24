//! Garage's access policies (`docs/plans/access-policies.md`): the policy GarageService holds every
//! read to (garage-access's `AccessPolicy`, `docs/plans/access-hooks.md`).
//!
//! A Rego policy (`policy`) decides, once per read, which boundaries the caller is held to; with none
//! stored, the built-in one applies the rules below, and with no rules, defaults or policies at all,
//! every caller sees every document, as before there were any.
//!
//! ALLOW and DENY rules match documents by metadata (source, class, trust tier, author, path) or by
//! content (a regular expression, a keyword query), and name the targets they apply to: the app,
//! `garage`, each MCP registration by its id, and each registration's grants. A DENY always wins; an
//! ALLOW matters under a DENY default. A rule hides the whole document.
//!
//! Rules, defaults and policies are read on every request, so a change applies to the next read.
//! Content rules are evaluated ahead of the read, a bounded batch at a time, and a document a DENY
//! has not been evaluated against is hidden from that DENY's targets until it has: the rules fail
//! closed.
//!
//! GarageService installs [`RulesPolicy`] unless the build's access extension registers a policy of
//! its own, and its access calls (`ListAccessPolicies`, `PutAccessPolicy`, `TestAccess`, ...) edit
//! these tables.

pub mod filter;
pub mod policy;
pub mod rules;
pub mod store;

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use garage_access::{AccessError, AccessPolicy, BoxFuture, Caller, Registry, SqlFilter};

use crate::policy::Policy;
use crate::rules::{DOOR_CLIENT_HEADER, target_names};

/// What [`RulesPolicy::explain`] found for one caller.
#[derive(Clone, Debug, PartialEq)]
pub struct Explanation {
    /// The stored policies that decided, by name; empty: the built-in one alone.
    pub policies: Vec<String>,
    /// The target names the caller goes by, outermost first.
    pub targets: Vec<String>,
    pub decision: policy::Decision,
    /// The content rules the decision depends on, which are evaluated ahead of a read.
    pub content_rules: Vec<String>,
    /// The condition the caller's reads carry; `None`: they see every document.
    pub filter: Option<SqlFilter>,
}

/// Registers the rules as the build's access policy.
pub fn register(registry: &mut Registry) {
    // A second policy is remembered by the registry and fails the service's start.
    let _ = registry.register_access_policy(Arc::new(RulesPolicy::default()));
}

/// The policy.
pub struct RulesPolicy {
    /// How many documents one read evaluates per content rule before answering.
    pub batch: i64,
    /// How long one rule's batch may take; what is left stays pending, and so hidden.
    pub timeout_ms: i64,
    schema_ready: AtomicBool,
    /// The last compiled policy, reused while the stored modules are unchanged.
    compiled: Mutex<Option<Arc<Policy>>>,
}

impl Default for RulesPolicy {
    fn default() -> Self {
        Self { batch: 2_000, timeout_ms: 2_000, schema_ready: AtomicBool::new(false), compiled: Mutex::new(None) }
    }
}

impl RulesPolicy {
    pub const NAME: &'static str = "rego";

    async fn decide(&self, client: &tokio_postgres::Client, caller: &Caller) -> Result<Option<SqlFilter>, AccessError> {
        Ok(self.explain(client, caller, true, None).await?.filter)
    }

    /// What a read by `caller` would be held to: its target names, the policy's decision and the SQL
    /// filter the read would carry. With `evaluate`, a bounded batch of every content rule the
    /// decision names is evaluated first, as a read does; without, nothing is written, so a
    /// `TestAccess` changes nothing. A `draft` module is decided with in place of the stored one of
    /// its name (or beside the stored ones), as an editor's unsaved text would be.
    ///
    /// # Errors
    ///
    /// The tables cannot be read, or the policy cannot decide.
    pub async fn explain(
        &self,
        client: &tokio_postgres::Client,
        caller: &Caller,
        evaluate: bool,
        draft: Option<&policy::Module>,
    ) -> Result<Explanation, AccessError> {
        self.ready(client).await?;
        let rules = store::list_rules(client).await.map_err(|e| AccessError::new(format!("reading rules: {e}")))?;
        let defaults =
            store::list_defaults(client).await.map_err(|e| AccessError::new(format!("reading defaults: {e}")))?;
        let mut modules =
            store::list_policies(client).await.map_err(|e| AccessError::new(format!("reading policies: {e}")))?;
        let targets = target_names(caller);
        // Nothing stored: the built-in policy would allow every target with no condition, so a read
        // skips the engine and runs as it did before there were policies.
        if evaluate && draft.is_none() && rules.is_empty() && defaults.is_empty() && modules.is_empty() {
            return Ok(Explanation {
                policies: Vec::new(),
                targets,
                decision: policy::Decision::default(),
                content_rules: Vec::new(),
                filter: None,
            });
        }
        let policy = match draft {
            Some(draft) => {
                modules = store::with_module(modules, draft);
                Arc::new(Policy::new(&modules).map_err(|e| AccessError::new(e.to_string()))?)
            }
            None => self.policy(&modules)?,
        };
        let decision = policy
            .decide(&policy::input(caller, &targets), &policy::data(&rules, &defaults))
            .map_err(|e| AccessError::new(e.to_string()))?;
        let boundaries = filter::resolve(&decision, &rules).map_err(|e| AccessError::new(e.to_string()))?;
        let content = filter::content_rules(&boundaries);
        if evaluate {
            for stored in &content {
                // A batch that fails or times out leaves its documents pending, which hides them
                // from a DENY's targets: the read goes on, closed rather than open.
                if let Err(error) = store::evaluate(client, stored, self.batch, self.timeout_ms).await {
                    eprintln!("access rule {}: evaluation stopped: {error}", stored.rule.name);
                }
            }
        }
        Ok(Explanation {
            policies: modules.into_iter().map(|m| m.name).collect(),
            targets,
            content_rules: content.iter().map(|r| r.rule.name.clone()).collect(),
            filter: filter::build(&boundaries),
            decision,
        })
    }

    /// Creates the access tables if this process has not yet, as before its first read.
    ///
    /// # Errors
    ///
    /// The server.
    pub async fn ready(&self, client: &tokio_postgres::Client) -> Result<(), AccessError> {
        if !self.schema_ready.load(Ordering::Acquire) {
            store::ensure_schema(client).await.map_err(|e| AccessError::new(format!("the access tables: {e}")))?;
            self.schema_ready.store(true, Ordering::Release);
        }
        Ok(())
    }

    /// The policy compiled from `modules`, from the cache when they are the ones it was compiled from.
    /// A stored module that no longer compiles fails the read: never a fall back to the built-in.
    fn policy(&self, modules: &[policy::Module]) -> Result<Arc<Policy>, AccessError> {
        let mut compiled = self.compiled.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(policy) = compiled.as_ref().filter(|p| p.modules() == modules) {
            return Ok(Arc::clone(policy));
        }
        let policy = Arc::new(Policy::new(modules).map_err(|e| AccessError::new(e.to_string()))?);
        *compiled = Some(Arc::clone(&policy));
        Ok(policy)
    }
}

impl AccessPolicy for RulesPolicy {
    fn name(&self) -> &str {
        Self::NAME
    }

    fn caller_headers(&self) -> Vec<String> {
        vec![DOOR_CLIENT_HEADER.to_owned()]
    }

    fn document_filter<'a>(
        &'a self,
        client: &'a tokio_postgres::Client,
        caller: &'a Caller,
    ) -> BoxFuture<'a, Result<Option<SqlFilter>, AccessError>> {
        Box::pin(self.decide(client, caller))
    }

    // A removed registration's id is never minted again, so rules naming it can never match a later
    // registration, whatever its name: nothing to undo here.
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn it_registers_itself_and_asks_for_the_door_header() {
        let mut registry = Registry::new();
        register(&mut registry);
        let policy = registry.into_policy().unwrap();
        assert_eq!(policy.name(), RulesPolicy::NAME);
        assert_eq!(policy.caller_headers(), ["x-garage-registration"]);
    }
}

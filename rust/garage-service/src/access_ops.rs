//! The access calls (`docs/plans/access-policies.md`): the Rego modules, rules and defaults the
//! build's [`RulesPolicy`](garage_access_rego::RulesPolicy) holds every read to, listed, changed and
//! tried out. `garage access` and the app's Access page are thin presenters over these.
//!
//! A change is a row in the policy's own tables, read again on the next read, so it applies at once
//! and needs no restart. A module is compiled with the other enabled ones before it is stored, so a
//! policy that would fail every read is refused here, with regorus's message, instead.

use std::collections::BTreeMap;

use garage_access::{Caller, CallerKind, Registration, SqlValue};
use garage_access_rego::policy::{BUILTIN_PRIVACY, BUILTIN_RULES, BUILTIN_TOOLS, Module};
use garage_access_rego::rules::{DOOR_CLIENT, DOOR_CLIENT_HEADER, Effect, Rule};
use garage_access_rego::{RulesPolicy, store};
use garage_facade::proto;
use serde_json::Value;

use crate::access::AccessGate;
use crate::db::Client;
use crate::error::{Result, ServiceError};

/// The Rego policy, when it is the one this build holds reads to.
fn editable(gate: &AccessGate) -> Result<&'static RulesPolicy> {
    gate.rego().ok_or_else(|| {
        ServiceError::failed(format!(
            "this build's access policy ({}) is not the Rego one; its rules are not edited here",
            gate.name()
        ))
    })
}

fn store_error(error: &store::StoreError) -> ServiceError {
    match error {
        store::StoreError::Database(e) => ServiceError::failed(e.to_string()),
        other => ServiceError::invalid(other.to_string()),
    }
}

async fn ready(gate: &AccessGate, client: &Client) -> Result<&'static RulesPolicy> {
    let policy = editable(gate)?;
    policy.ready(client).await.map_err(|e| ServiceError::failed(e.0))?;
    Ok(policy)
}

/// `ListAccessPolicies`. Answers for any build, so the app can say why there is nothing to edit.
///
/// # Errors
///
/// The server.
pub async fn list_policies(gate: &AccessGate, client: &Client) -> Result<proto::ListAccessPoliciesResponse> {
    let mut response = proto::ListAccessPoliciesResponse {
        // Both built-in modules: the document decision and the tool decision.
        builtin_rego: format!("{BUILTIN_RULES}\n{BUILTIN_PRIVACY}\n{BUILTIN_TOOLS}"),
        engine: gate.name().to_owned(),
        editable: gate.rego().is_some(),
        ..Default::default()
    };
    if response.editable {
        ready(gate, client).await?;
        response.callers = callers(client).await?;
        response.policies = store::all_policies(client)
            .await
            .map_err(|e| store_error(&e))?
            .into_iter()
            .map(|p| proto::AccessPolicy {
                name: p.module.name,
                rego: p.module.rego,
                enabled: p.enabled,
                updated_at: p.updated_at,
            })
            .collect();
    }
    Ok(response)
}

/// The callers `TestAccess` takes: the fixed ones, then each registration by name.
async fn callers(client: &Client) -> Result<Vec<proto::AccessCaller>> {
    let fixed = [
        ("app", "The app"),
        ("cli", "garage on a terminal"),
        ("mcp:unregistered", "An MCP client with no registration"),
        ("unverified", "An unverified gRPC caller"),
    ];
    let mut callers: Vec<proto::AccessCaller> = fixed
        .iter()
        .map(|(caller, label)| proto::AccessCaller { caller: (*caller).to_owned(), label: (*label).to_owned() })
        .collect();
    for row in client.query("SELECT id, name, client FROM mcp_registrations ORDER BY name, id", &[]).await? {
        let (id, name, kind): (String, String, String) = (row.get(0), row.get(1), row.get(2));
        let prefix = if kind == DOOR_CLIENT { "door" } else { "mcp" };
        callers.push(proto::AccessCaller { caller: format!("{prefix}:{id}"), label: format!("{name} ({kind})") });
    }
    Ok(callers)
}

fn module(policy: Option<proto::AccessPolicy>) -> Result<(Module, bool)> {
    let policy = policy.ok_or_else(|| ServiceError::invalid("no policy given"))?;
    Ok((Module { name: policy.name.trim().to_owned(), rego: policy.rego }, policy.enabled))
}

/// `PutAccessPolicy`: stores the module once it compiles with the other enabled ones, or with
/// `check_only` compiles it and stores nothing.
///
/// # Errors
///
/// The module does not compile (`INVALID_ARGUMENT`, regorus's message), or the server.
pub async fn put_policy(
    gate: &AccessGate,
    client: &Client,
    request: proto::PutAccessPolicyRequest,
) -> Result<proto::PutAccessPolicyResponse> {
    ready(gate, client).await?;
    let (module, enabled) = module(request.policy)?;
    let message = if request.check_only {
        store::check_policy(client, &module).await.map_err(|e| store_error(&e))?;
        format!("policy {} compiles with the other enabled policies", module.name)
    } else {
        store::put_policy(client, &module, enabled).await.map_err(|e| store_error(&e))?;
        format!("policy {} saved{}", module.name, if enabled { "" } else { ", disabled" })
    };
    Ok(proto::PutAccessPolicyResponse { message })
}

/// `RemoveAccessPolicy`.
///
/// # Errors
///
/// There is no policy of that name (`NOT_FOUND`), or the server.
pub async fn remove_policy(
    gate: &AccessGate,
    client: &Client,
    name: &str,
) -> Result<proto::RemoveAccessPolicyResponse> {
    ready(gate, client).await?;
    if store::delete_policy(client, name).await.map_err(|e| store_error(&e))? {
        Ok(proto::RemoveAccessPolicyResponse { message: format!("policy {name} removed") })
    } else {
        Err(ServiceError::not_found(format!("no policy named {name}")))
    }
}

/// `ListAccessRules`, with how many documents each content rule has yet to look at.
///
/// # Errors
///
/// The server.
pub async fn list_rules(gate: &AccessGate, client: &Client) -> Result<proto::ListAccessRulesResponse> {
    ready(gate, client).await?;
    let mut rules = Vec::new();
    for stored in store::list_rules(client).await.map_err(|e| store_error(&e))? {
        let pending = store::pending(client, &stored).await.map_err(|e| store_error(&e))?;
        rules.push(proto::AccessRule {
            name: stored.rule.name.clone(),
            rule_json: stored.rule.to_json().to_string(),
            enabled: stored.rule.enabled,
            pending,
        });
    }
    Ok(proto::ListAccessRulesResponse { rules })
}

/// `PutAccessRule`: adds the rule, or replaces the one of its name.
///
/// # Errors
///
/// A rule that is not one (`INVALID_ARGUMENT`), or the server.
pub async fn put_rule(gate: &AccessGate, client: &Client, rule_json: &str) -> Result<proto::PutAccessRuleResponse> {
    ready(gate, client).await?;
    let value: Value =
        serde_json::from_str(rule_json).map_err(|e| ServiceError::invalid(format!("the rule is not JSON: {e}")))?;
    let rule = Rule::from_json(&value).map_err(|e| ServiceError::invalid(e.0))?;
    let id = store::put_rule(client, &rule).await.map_err(|e| store_error(&e))?;
    Ok(proto::PutAccessRuleResponse { id, message: format!("rule {} saved", rule.name) })
}

/// `RemoveAccessRule`.
///
/// # Errors
///
/// There is no rule of that name (`NOT_FOUND`), or the server.
pub async fn remove_rule(gate: &AccessGate, client: &Client, name: &str) -> Result<proto::RemoveAccessRuleResponse> {
    ready(gate, client).await?;
    if store::delete_rule(client, name).await.map_err(|e| store_error(&e))? {
        Ok(proto::RemoveAccessRuleResponse { message: format!("rule {name} removed") })
    } else {
        Err(ServiceError::not_found(format!("no rule named {name}")))
    }
}

/// `ListAccessDefaults`.
///
/// # Errors
///
/// The server.
pub async fn list_defaults(gate: &AccessGate, client: &Client) -> Result<proto::ListAccessDefaultsResponse> {
    ready(gate, client).await?;
    let defaults = store::list_defaults(client)
        .await
        .map_err(|e| store_error(&e))?
        .into_iter()
        .map(|(target, effect)| proto::AccessDefault { target, effect: effect.name().to_owned() })
        .collect();
    Ok(proto::ListAccessDefaultsResponse { defaults })
}

/// `SetAccessDefault`: an empty effect clears the target's default.
///
/// # Errors
///
/// An effect that is not `allow` or `deny`, an empty target (`INVALID_ARGUMENT`), or the server.
pub async fn set_default(
    gate: &AccessGate,
    client: &Client,
    request: &proto::SetAccessDefaultRequest,
) -> Result<proto::SetAccessDefaultResponse> {
    ready(gate, client).await?;
    let target = request.target.trim();
    if target.is_empty() {
        return Err(ServiceError::invalid("a default names its target (app, cli, mcp:<id>, mcp:*, *)"));
    }
    let effect = match request.effect.trim() {
        "" | "clear" => None,
        other => Some(Effect::parse(other).map_err(|e| ServiceError::invalid(e.0))?),
    };
    store::set_default(client, target, effect).await.map_err(|e| store_error(&e))?;
    Ok(proto::SetAccessDefaultResponse {
        message: format!("default for {target}: {}", effect.map_or("cleared", Effect::name)),
    })
}

/// The caller `name` stands for, as the service would establish it for a read.
///
/// # Errors
///
/// A name that is no caller, or a registration that does not exist (`INVALID_ARGUMENT`), or the
/// server.
pub async fn caller_for(client: &Client, name: &str, transport: &str) -> Result<Caller> {
    let transport = (!transport.trim().is_empty()).then(|| transport.trim());
    let not_a_caller = || {
        ServiceError::invalid(format!(
            "not a caller: {name} (app, cli, unverified, mcp:unregistered, mcp:<registration id> or \
             door:<registration id>[/<grant>])"
        ))
    };
    let caller = match name.trim() {
        "app" => Caller::app(),
        "cli" => Caller::cli(),
        "unverified" => Caller::unverified(),
        "mcp:unregistered" => Caller::mcp(transport.unwrap_or("stdio"), None),
        other => {
            let (door, rest) = if let Some(rest) = other.strip_prefix("door:") {
                (true, rest)
            } else if let Some(rest) = other.strip_prefix("mcp:") {
                (false, rest)
            } else {
                return Err(not_a_caller());
            };
            let (id, grant) = match rest.split_once('/') {
                Some((id, grant)) if door && !grant.is_empty() && !grant.contains('/') => (id, Some(grant)),
                Some(_) => return Err(not_a_caller()),
                None => (rest, None),
            };
            let row = client
                .query_opt("SELECT name, client FROM mcp_registrations WHERE id = $1", &[&id])
                .await?
                .ok_or_else(|| ServiceError::invalid(format!("no MCP registration with id {id}")))?;
            let registration = Registration { id: id.to_owned(), name: row.get(0), client: row.get(1) };
            if door != (registration.client == DOOR_CLIENT) {
                let kind = if registration.client == DOOR_CLIENT { "door" } else { "mcp" };
                return Err(ServiceError::invalid(format!(
                    "registration {id} is a {} registration: use {kind}:{id}",
                    registration.client
                )));
            }
            let attributes: BTreeMap<String, String> =
                grant.map(|g| [(DOOR_CLIENT_HEADER.to_owned(), g.to_owned())].into()).unwrap_or_default();
            Caller::mcp(transport.unwrap_or("http"), Some(registration)).with_attributes(attributes)
        }
    };
    Ok(caller)
}

/// A bind parameter as JSON, for the Access page and `garage access test`.
fn param_json(value: &SqlValue) -> String {
    match value {
        SqlValue::Bool(v) => v.to_string(),
        SqlValue::Int(v) => v.to_string(),
        SqlValue::Text(v) => Value::from(v.as_str()).to_string(),
        SqlValue::IntArray(v) => Value::from(v.clone()).to_string(),
        SqlValue::TextArray(v) => Value::from(v.clone()).to_string(),
    }
}

/// `TestAccess`: what a caller's reads would be held to. Evaluates no content rule and writes
/// nothing.
///
/// # Errors
///
/// An unknown caller, a draft that does not compile or a policy that cannot decide
/// (`INVALID_ARGUMENT`, with the reason: unlike a read, the person asking wrote the policy), or the
/// server.
pub async fn test(
    gate: &AccessGate,
    client: &Client,
    request: proto::TestAccessRequest,
) -> Result<proto::TestAccessResponse> {
    let policy = ready(gate, client).await?;
    let caller = caller_for(client, &request.caller, &request.transport).await?;
    let draft = request.draft.map(|d| Module { name: d.name.trim().to_owned(), rego: d.rego });
    let explanation =
        policy.explain(client, &caller, false, draft.as_ref()).await.map_err(|e| ServiceError::invalid(e.0))?;
    // Only an assistant reaches the MCP tools; the app and `garage` have none to withhold.
    let (tools, withheld_tools) = if caller.kind == CallerKind::Mcp {
        let offered = garage_mcp::tools::tool_names();
        let allowed =
            policy.tools(client, &caller, &offered, draft.as_ref()).await.map_err(|e| ServiceError::invalid(e.0))?;
        let withheld = offered.into_iter().filter(|name| !allowed.contains(name)).collect();
        (allowed, withheld)
    } else {
        (Vec::new(), Vec::new())
    };
    let rules = store::list_rules(client).await.map_err(|e| store_error(&e))?;
    let mut content_rules = Vec::new();
    for name in &explanation.content_rules {
        if let Some(stored) = rules.iter().find(|r| &r.rule.name == name) {
            let pending = store::pending(client, stored).await.map_err(|e| store_error(&e))?;
            content_rules.push(proto::AccessContentRule { name: name.clone(), pending });
        }
    }
    let (filter_sql, filter_params) = explanation
        .filter
        .as_ref()
        .map(|f| (f.sql.clone(), f.params.iter().map(param_json).collect()))
        .unwrap_or_default();
    Ok(proto::TestAccessResponse {
        caller_kind: caller.kind.name().to_owned(),
        transport: caller.transport.clone(),
        targets: explanation.targets,
        policies: explanation.policies,
        decision_json: serde_json::to_string_pretty(&explanation.decision.to_json())?,
        content_rules,
        sees_everything: explanation.filter.is_none(),
        filter_sql,
        filter_params,
        registration_name: caller.registration.map(|r| r.name).unwrap_or_default(),
        tools,
        withheld_tools,
    })
}

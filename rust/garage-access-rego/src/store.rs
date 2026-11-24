//! The access tables (`data/sql/027_access_policies.sql`): storing rules, defaults and Rego
//! modules, and evaluating content rules into `access_evaluations`.

use serde_json::Value;
use tokio_postgres::Client;

use crate::policy::{Module, Policy, PolicyError};
use crate::rules::{Effect, Field, Matcher, Rule, RuleError};

/// The tables' DDL, idempotent. The migrations apply the same file; the policy applies it too, once
/// per process, so a database migrated before it existed still answers.
pub const SCHEMA: &str = include_str!("../../../data/sql/027_access_policies.sql");

/// Why a store call failed.
#[derive(Debug)]
pub enum StoreError {
    Rule(RuleError),
    Policy(PolicyError),
    Database(tokio_postgres::Error),
}

impl std::fmt::Display for StoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Rule(e) => write!(f, "{e}"),
            Self::Policy(e) => write!(f, "{e}"),
            Self::Database(e) => write!(f, "{e}"),
        }
    }
}

impl std::error::Error for StoreError {}

impl From<RuleError> for StoreError {
    fn from(error: RuleError) -> Self {
        Self::Rule(error)
    }
}

impl From<PolicyError> for StoreError {
    fn from(error: PolicyError) -> Self {
        Self::Policy(error)
    }
}

impl From<tokio_postgres::Error> for StoreError {
    fn from(error: tokio_postgres::Error) -> Self {
        Self::Database(error)
    }
}

/// A rule as stored: its id and the version its content evaluations must carry.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StoredRule {
    pub id: i64,
    pub version: String,
    pub rule: Rule,
}

/// Creates the tables if they are missing.
///
/// # Errors
///
/// The server.
pub async fn ensure_schema(client: &Client) -> Result<(), StoreError> {
    client.batch_execute(SCHEMA).await?;
    Ok(())
}

/// Adds `rule`, or replaces the rule of the same name; its id. A changed matcher gets a new version,
/// so its old evaluations stop counting at once.
///
/// # Errors
///
/// A regular expression the server does not accept, or the server.
pub async fn put_rule(client: &Client, rule: &Rule) -> Result<i64, StoreError> {
    if let Matcher::Regex { pattern, .. } = &rule.matcher {
        // Refuse a pattern Postgres cannot compile here, rather than leave a rule pending forever.
        if let Err(error) = client.query_one("SELECT '' ~ $1::text", &[pattern]).await {
            return Err(RuleError(format!("{}: not a valid regular expression ({error})", rule.name)).into());
        }
    }
    let spec = rule.matcher.to_json().to_string();
    let row = client
        .query_one(
            "INSERT INTO access_rules (name, effect, targets, matcher, spec, version, enabled) \
             VALUES ($1, $2, $3, $4, CAST($5::text AS jsonb), \
                     encode(sha256(convert_to($4 || ':' || $5, 'UTF8')), 'hex'), $6) \
             ON CONFLICT (name) DO UPDATE SET effect = EXCLUDED.effect, targets = EXCLUDED.targets, \
                 matcher = EXCLUDED.matcher, spec = EXCLUDED.spec, version = EXCLUDED.version, \
                 enabled = EXCLUDED.enabled, updated_at = now() \
             RETURNING id",
            &[&rule.name, &rule.effect.name(), &rule.targets, &rule.matcher.kind(), &spec, &rule.enabled],
        )
        .await?;
    Ok(row.get(0))
}

/// Deletes the rule named `name`, with its evaluations; whether there was one.
///
/// # Errors
///
/// The server.
pub async fn delete_rule(client: &Client, name: &str) -> Result<bool, StoreError> {
    Ok(client.execute("DELETE FROM access_rules WHERE name = $1", &[&name]).await? > 0)
}

/// Every rule, by id.
///
/// # Errors
///
/// A stored rule that no longer parses, or the server.
pub async fn list_rules(client: &Client) -> Result<Vec<StoredRule>, StoreError> {
    let rows = client
        .query("SELECT id, version, name, effect, targets, spec, enabled FROM access_rules ORDER BY id", &[])
        .await?;
    rows.iter()
        .map(|row| {
            let spec: Value = row.get(5);
            let rule = Rule {
                name: row.get(2),
                effect: Effect::parse(row.get(3))?,
                targets: row.get(4),
                matcher: Matcher::from_json(&spec)?,
                enabled: row.get(6),
            };
            Ok(StoredRule { id: row.get(0), version: row.get(1), rule })
        })
        .collect()
}

/// Sets the default of the target name or pattern `target`, or removes it (`None`).
///
/// # Errors
///
/// The server.
pub async fn set_default(client: &Client, target: &str, effect: Option<Effect>) -> Result<(), StoreError> {
    match effect {
        Some(effect) => {
            client
                .execute(
                    "INSERT INTO access_defaults (target, effect) VALUES ($1, $2) \
                     ON CONFLICT (target) DO UPDATE SET effect = EXCLUDED.effect",
                    &[&target, &effect.name()],
                )
                .await?;
        }
        None => {
            client.execute("DELETE FROM access_defaults WHERE target = $1", &[&target]).await?;
        }
    }
    Ok(())
}

/// Every default, as `(target, effect)`.
///
/// # Errors
///
/// A stored effect that does not parse, or the server.
pub async fn list_defaults(client: &Client) -> Result<Vec<(String, Effect)>, StoreError> {
    let rows = client.query("SELECT target, effect FROM access_defaults ORDER BY target", &[]).await?;
    rows.iter().map(|row| Ok((row.get(0), Effect::parse(row.get(1))?))).collect()
}

/// Adds the Rego module `module` under `name`, or replaces the one of that name. It is compiled with
/// the other enabled modules first, so a policy that would fail every read is refused here instead.
///
/// # Errors
///
/// The module does not compile with the others, or the server.
pub async fn put_policy(client: &Client, module: &Module, enabled: bool) -> Result<(), StoreError> {
    check_name(&module.name)?;
    if enabled {
        check_policy(client, module).await?;
    } else {
        // A disabled module is not evaluated, but it must still be Rego, so enabling it later is the
        // only step left.
        Policy::new(std::slice::from_ref(module))?;
    }
    client
        .execute(
            "INSERT INTO access_policies (name, module, enabled) VALUES ($1, $2, $3) \
             ON CONFLICT (name) DO UPDATE SET module = EXCLUDED.module, enabled = EXCLUDED.enabled, \
                 updated_at = now()",
            &[&module.name, &module.rego, &enabled],
        )
        .await?;
    Ok(())
}

/// Compiles `module` with the other enabled modules, as [`put_policy`] would before saving it, and
/// saves nothing.
///
/// # Errors
///
/// The module does not compile with the others, or the server.
pub async fn check_policy(client: &Client, module: &Module) -> Result<(), StoreError> {
    check_name(&module.name)?;
    Policy::new(&with_module(list_policies(client).await?, module))?;
    Ok(())
}

/// A policy's name: what regorus files it under (`<name>.rego`) and what the Access page lists.
fn check_name(name: &str) -> Result<(), PolicyError> {
    if name.trim().is_empty() || name.trim() != name || name.contains(['/', '\\']) {
        return Err(PolicyError(format!("{name:?} is not a policy name: give it a name with no slash")));
    }
    Ok(())
}

/// `modules` with `module` in place of the one of its name, or added.
pub fn with_module(modules: Vec<Module>, module: &Module) -> Vec<Module> {
    let mut modules: Vec<Module> = modules.into_iter().filter(|m| m.name != module.name).collect();
    modules.push(module.clone());
    modules.sort_by(|a, b| a.name.cmp(&b.name));
    modules
}

/// Deletes the policy named `name`; whether there was one.
///
/// # Errors
///
/// The server.
pub async fn delete_policy(client: &Client, name: &str) -> Result<bool, StoreError> {
    Ok(client.execute("DELETE FROM access_policies WHERE name = $1", &[&name]).await? > 0)
}

/// The enabled policies, by name: what a read evaluates.
///
/// # Errors
///
/// The server.
pub async fn list_policies(client: &Client) -> Result<Vec<Module>, StoreError> {
    let rows = client.query("SELECT name, module FROM access_policies WHERE enabled ORDER BY name", &[]).await?;
    Ok(rows.iter().map(|row| Module { name: row.get(0), rego: row.get(1) }).collect())
}

/// How many documents a content rule has no current evaluation for: what a DENY still hides
/// because it has not looked yet. A metadata rule has none.
///
/// # Errors
///
/// The server.
pub async fn pending(client: &Client, stored: &StoredRule) -> Result<i64, StoreError> {
    if !stored.rule.matcher.reads_content() {
        return Ok(0);
    }
    let row = client
        .query_one(
            "SELECT count(*) FROM documents d WHERE NOT EXISTS (SELECT 1 FROM access_evaluations e \
             WHERE e.rule_id = $1 AND e.document_id = d.id AND e.version = $2 \
             AND e.content_sha256 = d.content_sha256)",
            &[&stored.id, &stored.version],
        )
        .await?;
    Ok(row.get(0))
}

/// A stored policy, enabled or not, as the Access page lists it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StoredPolicy {
    pub module: Module,
    pub enabled: bool,
    /// RFC 3339, UTC.
    pub updated_at: String,
}

/// Every stored policy, enabled or not.
///
/// # Errors
///
/// The server.
pub async fn all_policies(client: &Client) -> Result<Vec<StoredPolicy>, StoreError> {
    let rows = client
        .query(
            "SELECT name, module, enabled, \
             to_char(updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') \
             FROM access_policies ORDER BY name",
            &[],
        )
        .await?;
    Ok(rows
        .iter()
        .map(|row| StoredPolicy {
            module: Module { name: row.get(0), rego: row.get(1) },
            enabled: row.get(2),
            updated_at: row.get(3),
        })
        .collect())
}

/// Evaluates a content rule over up to `limit` documents it has no current evaluation for (none
/// yet, an older version, or content changed since), within `timeout_ms`; how many it evaluated.
/// A metadata rule needs none and evaluates nothing.
///
/// # Errors
///
/// The server, including the statement timeout: the documents left over stay pending.
pub async fn evaluate(client: &Client, stored: &StoredRule, limit: i64, timeout_ms: i64) -> Result<u64, StoreError> {
    let condition = match &stored.rule.matcher {
        Matcher::Regex { field, case_sensitive, .. } => {
            let op = if *case_sensitive { "~" } else { "~*" };
            match field {
                Field::Text => {
                    format!("EXISTS (SELECT 1 FROM chunks c WHERE c.document_id = d.id AND c.text {op} $4::text)")
                }
                Field::Title => format!("COALESCE(d.title, '') {op} $4::text"),
                Field::Path => format!("d.uri {op} $4::text"),
            }
        }
        Matcher::Term(_) => "EXISTS (SELECT 1 FROM chunks c WHERE c.document_id = d.id \
                             AND c.tsv @@ websearch_to_tsquery('english', $4::text))"
            .to_owned(),
        _ => return Ok(0),
    };
    let argument = match &stored.rule.matcher {
        Matcher::Regex { pattern, .. } => pattern.clone(),
        Matcher::Term(term) => term.clone(),
        _ => unreachable!("content matchers only"),
    };
    let sql = format!(
        "INSERT INTO access_evaluations (rule_id, document_id, version, content_sha256, matched) \
         SELECT $1, d.id, $2, d.content_sha256, {condition} \
         FROM documents d \
         WHERE NOT EXISTS (SELECT 1 FROM access_evaluations e WHERE e.rule_id = $1 AND e.document_id = d.id \
                           AND e.version = $2 AND e.content_sha256 = d.content_sha256) \
         ORDER BY d.id LIMIT $3 \
         ON CONFLICT (rule_id, document_id) DO UPDATE SET version = EXCLUDED.version, \
             content_sha256 = EXCLUDED.content_sha256, matched = EXCLUDED.matched, evaluated_at = now()"
    );
    // A pathological pattern must not hold the read up: what the timeout leaves stays pending.
    client.query_one("SELECT set_config('statement_timeout', $1, false)", &[&timeout_ms.max(1).to_string()]).await?;
    let outcome = client.execute(&sql, &[&stored.id, &stored.version, &limit, &argument]).await;
    client.batch_execute("RESET statement_timeout").await?;
    Ok(outcome?)
}

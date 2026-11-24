//! Rego policies (`docs/plans/access-policies.md`): what decides, for each read, which documents
//! a caller may see.
//!
//! A policy is Open Policy Agent's language, evaluated in-process by regorus. It is asked once per
//! read, about the caller, never about each document: its answer, `data.garage.access.decision`, is
//! a list of boundaries in the rules' own vocabulary (a stored rule by name, or an inline metadata
//! matcher), which [`crate::filter`] turns into the read's SQL. So a search stays one filtered query,
//! and a change to a policy, a rule or a default applies to the next read.
//!
//! The stored rules and defaults are the policy's data (`data.garage.rules`, `data.garage.defaults`).
//! With no stored policy of its own, the service runs the built-in one (`policy/rules.rego`), which
//! decides exactly as the rules did before Rego: the targets, their defaults, and a DENY that always
//! wins.
//!
//! The policy fails closed: a module that does not compile, an evaluation that errs, runs out of
//! time or leaves the decision undefined, and an answer outside the vocabulary each fail the read.

use std::num::NonZeroU32;
use std::time::Duration;

use garage_access::Caller;
use regorus::Engine;
use regorus::utils::limits::ExecutionTimerConfig;
use serde_json::{Value, json};

use crate::rules::{Effect, Matcher, RuleError};
use crate::store::StoredRule;

/// The built-in policy: the stored rules as Rego.
pub const BUILTIN_RULES: &str = include_str!("../policy/rules.rego");
/// The package a policy answers in, and the rule the service reads.
pub const PACKAGE: &str = "data.garage.access";
pub const ENTRY_POINT: &str = "data.garage.access.decision";
/// The entry point's module when no stored policy declares the package: the built-in decision.
const DEFAULT_ENTRY: &str = "package garage.access\n\ndecision := data.garage.access.rules.decision\n";

/// How long one decision may take. A policy decides about one caller, so this is generous.
const TIME_LIMIT: Duration = Duration::from_millis(250);
/// How many steps run between checks of the clock.
const CHECK_INTERVAL: NonZeroU32 = NonZeroU32::new(64).unwrap();

/// Why a policy could not decide.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PolicyError(pub String);

impl std::fmt::Display for PolicyError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for PolicyError {}

impl From<RuleError> for PolicyError {
    fn from(error: RuleError) -> Self {
        Self(error.0)
    }
}

/// A stored policy module: its name and its Rego.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Module {
    pub name: String,
    pub rego: String,
}

/// One condition of a boundary, as a policy names it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Condition {
    /// A stored rule's matcher, by the rule's name (`{"rule": "no-keys"}`). Its effect and targets
    /// are the built-in policy's business; here only what it matches counts.
    Rule(String),
    /// A metadata matcher written in the policy (`{"corpus_class": "communication"}`). Content
    /// matchers read the corpus ahead of the read, so they are stored rules, named.
    Inline(Matcher),
}

impl Condition {
    /// The condition as a policy writes it.
    pub fn to_json(&self) -> Value {
        match self {
            Self::Rule(name) => json!({"rule": name}),
            Self::Inline(matcher) => matcher.to_json(),
        }
    }

    fn from_json(value: &Value) -> Result<Self, PolicyError> {
        if let Some(name) = value.get("rule") {
            let name = name
                .as_str()
                .filter(|n| !n.is_empty())
                .ok_or_else(|| PolicyError("a condition's rule is a rule's name".into()))?;
            return Ok(Self::Rule(name.to_owned()));
        }
        let matcher = Matcher::from_json(value)?;
        if matcher.reads_content() {
            return Err(PolicyError(format!(
                "a policy names a stored rule for a {} match ({{\"rule\": \"<name>\"}}); it cannot write one inline",
                matcher.kind()
            )));
        }
        Ok(Self::Inline(matcher))
    }
}

/// What a document must pass for one target: no DENY condition matches it, and, under a DENY
/// default, some ALLOW condition does.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Boundary {
    /// For the logs and the Access page; the decision does not depend on it.
    pub target: String,
    pub default: Effect,
    pub deny: Vec<Condition>,
    pub allow: Vec<Condition>,
}

/// A policy's answer for one caller: a document is visible when it passes every boundary. No
/// boundaries: the caller sees every document.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct Decision {
    pub boundaries: Vec<Boundary>,
}

impl Decision {
    /// The decision as a policy writes it.
    pub fn to_json(&self) -> Value {
        let conditions = |c: &[Condition]| c.iter().map(Condition::to_json).collect::<Vec<_>>();
        json!({"boundaries": self.boundaries.iter().map(|b| json!({
            "target": b.target,
            "default": b.default.name(),
            "deny": conditions(&b.deny),
            "allow": conditions(&b.allow),
        })).collect::<Vec<_>>()})
    }

    /// The decision from the policy's JSON.
    ///
    /// # Errors
    ///
    /// Anything outside `{"boundaries": [{"target"?, "default"?, "deny"?, "allow"?}]}`.
    pub fn from_json(value: &Value) -> Result<Self, PolicyError> {
        let shape =
            || PolicyError("the decision is {\"boundaries\": [{\"default\", \"deny\", \"allow\"}, ...]}".into());
        let boundaries = value.get("boundaries").and_then(Value::as_array).ok_or_else(shape)?;
        let conditions = |b: &Value, key: &str| -> Result<Vec<Condition>, PolicyError> {
            match b.get(key) {
                None => Ok(Vec::new()),
                Some(Value::Array(items)) => items.iter().map(Condition::from_json).collect(),
                Some(_) => Err(shape()),
            }
        };
        let boundaries = boundaries
            .iter()
            .map(|b| {
                if !b.is_object() {
                    return Err(shape());
                }
                Ok(Boundary {
                    target: b.get("target").and_then(Value::as_str).unwrap_or("").to_owned(),
                    default: Effect::parse(b.get("default").and_then(Value::as_str).unwrap_or("allow"))?,
                    deny: conditions(b, "deny")?,
                    allow: conditions(b, "allow")?,
                })
            })
            .collect::<Result<_, PolicyError>>()?;
        Ok(Self { boundaries })
    }
}

/// The input a policy is asked about: the caller as the server established it, and the target names
/// the rules know it by, outermost first.
pub fn input(caller: &Caller, targets: &[String]) -> Value {
    json!({
        "caller": {
            "kind": caller.kind.name(),
            "transport": caller.transport,
            "registration": caller.registration.as_ref().map(|r| json!({
                "id": r.id, "name": r.name, "client": r.client,
            })),
            "attributes": caller.attributes,
        },
        "targets": targets,
    })
}

/// The data a policy reads: the stored rules and defaults.
pub fn data(rules: &[StoredRule], defaults: &[(String, Effect)]) -> Value {
    json!({
        "garage": {
            "rules": rules.iter().map(|r| r.rule.to_json()).collect::<Vec<_>>(),
            "defaults": defaults.iter().map(|(target, effect)| json!({
                "target": target, "effect": effect.name(),
            })).collect::<Vec<_>>(),
        }
    })
}

/// The compiled modules: the built-in rules, the stored modules, and the default entry point when
/// none of them declares the package.
pub struct Policy {
    modules: Vec<Module>,
    engine: Engine,
}

impl Policy {
    /// The built-in policy alone.
    ///
    /// # Panics
    ///
    /// The built-in module does not compile, which its tests rule out.
    pub fn builtin() -> Self {
        Self::new(&[]).expect("the built-in policy compiles")
    }

    /// The built-in policy and `modules`.
    ///
    /// # Errors
    ///
    /// A module that does not parse or compile, or one that takes the built-in's package.
    pub fn new(modules: &[Module]) -> Result<Self, PolicyError> {
        let mut engine = Engine::new();
        engine.set_execution_timer_config(ExecutionTimerConfig { limit: TIME_LIMIT, check_interval: CHECK_INTERVAL });
        engine
            .add_policy("builtin/rules.rego".into(), BUILTIN_RULES.into())
            .map_err(|e| PolicyError(format!("the built-in policy: {e}")))?;
        let builtin_packages = engine.get_packages().map_err(|e| PolicyError(e.to_string()))?;
        for module in modules {
            let package = engine
                .add_policy(format!("{}.rego", module.name), module.rego.clone())
                .map_err(|e| PolicyError(format!("policy {}: {e}", module.name)))?;
            if builtin_packages.contains(&package) {
                return Err(PolicyError(format!("policy {}: {package} is the built-in rules' package", module.name)));
            }
        }
        let packages = engine.get_packages().map_err(|e| PolicyError(e.to_string()))?;
        if !packages.iter().any(|p| p == PACKAGE) {
            engine
                .add_policy("builtin/entry.rego".into(), DEFAULT_ENTRY.into())
                .map_err(|e| PolicyError(format!("the default entry point: {e}")))?;
        }
        Ok(Self { modules: modules.to_vec(), engine })
    }

    /// The stored modules this was compiled from.
    pub fn modules(&self) -> &[Module] {
        &self.modules
    }

    /// The decision for `input` over `data`.
    ///
    /// # Errors
    ///
    /// The evaluation fails, runs out of time, or leaves the decision undefined or malformed.
    pub fn decide(&self, input: &Value, data: &Value) -> Result<Decision, PolicyError> {
        // Through text, not regorus's From<serde_json::Value>: under Bazel regorus links its own
        // serde_json (the root's crates hub), a different crate from the one garage-rag's hub gives this one.
        let to_rego = |value: &Value, what: &str| {
            regorus::Value::from_json_str(&value.to_string())
                .map_err(|e| PolicyError(format!("the policy's {what}: {e}")))
        };
        let mut engine = self.engine.clone();
        engine.add_data(to_rego(data, "data")?).map_err(|e| PolicyError(format!("the policy's data: {e}")))?;
        engine.set_input(to_rego(input, "input")?);
        let value = engine.eval_rule(ENTRY_POINT.into()).map_err(|e| PolicyError(format!("the policy: {e}")))?;
        if value == regorus::Value::Undefined {
            return Err(PolicyError(format!("the policy leaves {ENTRY_POINT} undefined for this caller")));
        }
        let json: Value =
            serde_json::from_str(&value.to_json_str().map_err(|e| PolicyError(format!("the policy's decision: {e}")))?)
                .map_err(|e| PolicyError(format!("the policy's decision: {e}")))?;
        Decision::from_json(&json)
    }
}

#[cfg(test)]
mod tests {
    use garage_access::Registration;

    use super::*;
    use crate::rules::{Rule, target_names};

    fn stored(id: i64, rule: &Value) -> StoredRule {
        StoredRule { id, version: format!("v{id}"), rule: Rule::from_json(rule).unwrap() }
    }

    fn rule(name: &str) -> Condition {
        Condition::Rule(name.into())
    }

    fn mcp() -> Caller {
        Caller::mcp(
            "http",
            Some(Registration { id: "r1".into(), name: "Claude".into(), client: "claude-desktop".into() }),
        )
    }

    fn decide(policy: &Policy, caller: &Caller, rules: &[StoredRule], defaults: &[(String, Effect)]) -> Decision {
        policy.decide(&input(caller, &target_names(caller)), &data(rules, defaults)).unwrap()
    }

    #[test]
    fn the_builtin_policy_decides_as_the_rules_did() {
        let rules = [
            stored(1, &json!({"name": "keys", "effect": "deny", "targets": ["*"], "match": {"regex": "KEY"}})),
            stored(
                2,
                &json!({"name": "mail", "effect": "deny", "targets": ["mcp:*", "door:*"], "match": {"corpus_class": "communication"}}),
            ),
            stored(
                3,
                &json!({"name": "off", "effect": "deny", "targets": ["*"], "match": {"term": "x"}, "enabled": false}),
            ),
            stored(4, &json!({"name": "work", "effect": "allow", "targets": ["mcp:r1"], "match": {"source": "work"}})),
        ];
        let defaults = vec![
            ("*".to_owned(), Effect::Deny),
            ("mcp:*".to_owned(), Effect::Allow),
            ("mcp:r1".to_owned(), Effect::Deny),
        ];
        let policy = Policy::builtin();
        assert_eq!(
            decide(&policy, &mcp(), &rules, &defaults),
            Decision {
                boundaries: vec![Boundary {
                    target: "mcp:r1".into(),
                    default: Effect::Deny,
                    deny: vec![rule("keys"), rule("mail")],
                    allow: vec![rule("work")],
                }]
            }
        );
        // Longest prefix, then `*`, then allow.
        let unregistered = decide(&policy, &Caller::mcp("stdio", None), &rules, &defaults);
        assert_eq!(unregistered.boundaries[0].default, Effect::Allow);
        assert_eq!(decide(&policy, &Caller::app(), &rules, &defaults).boundaries[0].default, Effect::Deny);
        assert_eq!(decide(&policy, &Caller::app(), &[], &[]).boundaries[0].default, Effect::Allow);
        assert_eq!(decide(&policy, &Caller::app(), &rules, &defaults).boundaries[0].deny, [rule("keys")]);
    }

    #[test]
    fn a_decision_round_trips_through_json() {
        let decision = Decision {
            boundaries: vec![Boundary {
                target: "mcp:r1".into(),
                default: Effect::Deny,
                deny: vec![rule("keys")],
                allow: vec![Condition::Inline(Matcher::Source(vec!["work".into()]))],
            }],
        };
        assert_eq!(Decision::from_json(&decision.to_json()).unwrap(), decision);
    }

    #[test]
    fn a_door_grant_is_held_to_its_door() {
        let caller = Caller::mcp(
            "http",
            Some(Registration { id: "d1".into(), name: "Door".into(), client: "garage-door".into() }),
        )
        .with_attributes([("x-garage-registration".to_owned(), "g7".to_owned())].into());
        let rules = [stored(
            1,
            &json!({"name": "grant", "effect": "deny", "targets": ["door:d1/*"], "match": {"path": "/x/*"}}),
        )];
        let decision = decide(&Policy::builtin(), &caller, &rules, &[]);
        let targets: Vec<_> = decision.boundaries.iter().map(|b| b.target.as_str()).collect();
        assert_eq!(targets, ["door:d1", "door:d1/g7"]);
        assert!(decision.boundaries[0].deny.is_empty());
        assert_eq!(decision.boundaries[1].deny, [rule("grant")]);
    }

    #[test]
    fn a_stored_policy_replaces_or_builds_on_the_rules() {
        let policy = Policy::new(&[Module {
            name: "assistants".into(),
            rego: r#"
package garage.access

# Assistants never see mail, on top of whatever the rules say.
decision := {"boundaries": array.concat(data.garage.access.rules.decision.boundaries, extra)}

extra := [{"default": "allow", "deny": [{"corpus_class": "communication"}]}] if {
    input.caller.kind == "mcp"
} else := []
"#
            .into(),
        }])
        .unwrap();
        let rules =
            [stored(1, &json!({"name": "keys", "effect": "deny", "targets": ["*"], "match": {"regex": "KEY"}}))];
        let assistant = decide(&policy, &mcp(), &rules, &[]);
        assert_eq!(assistant.boundaries.len(), 2);
        assert_eq!(assistant.boundaries[0].deny, [rule("keys")]);
        assert_eq!(
            assistant.boundaries[1].deny,
            [Condition::Inline(Matcher::CorpusClass(vec!["communication".into()]))]
        );
        assert_eq!(decide(&policy, &Caller::app(), &rules, &[]).boundaries.len(), 1);
    }

    #[test]
    fn a_policy_that_cannot_decide_fails_closed() {
        let module = |rego: &str| Module { name: "p".into(), rego: rego.into() };
        // Does not parse; takes the built-in's package.
        assert!(Policy::new(&[module("package garage.access\n\ndecision := ")]).is_err());
        assert!(Policy::new(&[module("package garage.access.rules\n\nx := 1\n")]).is_err());
        let undefined = Policy::new(&[module("package garage.access\n\ndecision := {} if { false }\n")]).unwrap();
        let input = input(&Caller::app(), &["app".into()]);
        assert!(undefined.decide(&input, &data(&[], &[])).unwrap_err().0.contains("undefined"));
        // Outside the vocabulary: an inline content matcher, an unknown matcher, a bad effect.
        for decision in [
            r#"{"boundaries": [{"deny": [{"regex": "x"}]}]}"#,
            r#"{"boundaries": [{"deny": [{"colour": "red"}]}]}"#,
            r#"{"boundaries": [{"default": "maybe"}]}"#,
            r#"{"allow": true}"#,
        ] {
            let policy = Policy::new(&[module(&format!("package garage.access\n\ndecision := {decision}\n"))]).unwrap();
            assert!(policy.decide(&input, &data(&[], &[])).is_err(), "{decision}");
        }
    }

    #[test]
    fn a_policy_that_runs_away_is_stopped() {
        let policy = Policy::new(&[Module {
            name: "slow".into(),
            rego: "package garage.access\n\nn := count([1 | some x in numbers.range(1, 20000); some y in numbers.range(1, 20000)])\n\ndecision := {\"boundaries\": []} if { n > 0 }\n"
                .into(),
        }])
        .unwrap();
        let input = input(&Caller::app(), &["app".into()]);
        let started = std::time::Instant::now();
        assert!(policy.decide(&input, &data(&[], &[])).is_err());
        assert!(started.elapsed() < Duration::from_secs(5));
    }
}

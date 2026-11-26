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
/// The built-in privacy levels, whose boundaries every decision carries.
pub const BUILTIN_PRIVACY: &str = include_str!("../policy/privacy.rego");
/// The rule the privacy decision is read from.
pub const PRIVACY_ENTRY_POINT: &str = "data.garage.privacy.levels.decision";
/// The caller attributes the privacy levels read, as the node's end of Garage Door sets them
/// (garage-enterprise's `mcp/src/context.rs`). Each can only lower the level or narrow the route.
pub const PRIVACY_ATTRIBUTES: [&str; 4] =
    ["garage-door-route", "garage-door-privacy", "garage-door-scope", "garage-door-inference"];
/// The privacy decision's package, which stored policies may add modifications to.
const PRIVACY_PACKAGE: &str = "data.garage.privacy";
/// The node's level when nothing lowers it: the privacy.level setting's default.
pub const MOST_OPEN_LEVEL: u8 = 5;
/// The built-in tool decision, which stored policies extend with `deny` in its package.
pub const BUILTIN_TOOLS: &str = include_str!("../policy/tools.rego");
/// The tool decision's package, which stored policies may add `deny` to.
const TOOLS_PACKAGE: &str = "data.garage.tools";
/// The rule the MCP server's tool decision is read from.
pub const TOOLS_ENTRY_POINT: &str = "data.garage.tools.decision";
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

/// The input of a tool decision: [`input`] and the tools the MCP server offers.
pub fn tools_input(caller: &Caller, targets: &[String], tools: &[String]) -> Value {
    let mut value = input(caller, targets);
    value["tools"] = json!(tools);
    value
}

/// The data a policy reads: the stored rules and defaults, with the node at its most open level.
pub fn data(rules: &[StoredRule], defaults: &[(String, Effect)]) -> Value {
    data_at(rules, defaults, MOST_OPEN_LEVEL)
}

/// The data a policy reads: the stored rules and defaults, and the node's own privacy level
/// (`data.garage.settings.privacy_level`, 1 to 5).
pub fn data_at(rules: &[StoredRule], defaults: &[(String, Effect)], privacy_level: u8) -> Value {
    json!({
        "garage": {
            "rules": rules.iter().map(|r| r.rule.to_json()).collect::<Vec<_>>(),
            "defaults": defaults.iter().map(|(target, effect)| json!({
                "target": target, "effect": effect.name(),
            })).collect::<Vec<_>>(),
            "settings": {"privacy_level": privacy_level},
        }
    })
}

/// The privacy decision for one caller (`data.garage.privacy.levels.decision`, `policy/privacy.rego`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Privacy {
    /// The level in effect, 1 to 5: the node's own, lowered by what the caller reported from Door.
    pub level: u8,
    /// The level's name (`node`, `cluster`, `remote`, `providers`, `augmented`).
    pub name: String,
    /// What the level turns on, lowest first.
    pub features: Vec<String>,
    /// How the caller reached the node: `local`, `linked`, `sealed`, `web`, or a route Door named
    /// that the policy does not know.
    pub route: String,
    /// Whether the level lets the caller in at all.
    pub open: bool,
    /// What the level holds the caller's reads to; added to every decision.
    pub boundaries: Vec<Boundary>,
    /// Tools the level withholds from the caller even when its route is open.
    pub withheld_tools: Vec<String>,
}

impl Privacy {
    fn from_json(value: &Value) -> Result<Self, PolicyError> {
        let shape = || PolicyError(format!("{PRIVACY_ENTRY_POINT} is malformed"));
        let strings = |key: &str| -> Result<Vec<String>, PolicyError> {
            value
                .get(key)
                .and_then(Value::as_array)
                .ok_or_else(shape)?
                .iter()
                .map(|v| v.as_str().map(str::to_owned).ok_or_else(shape))
                .collect()
        };
        let boundaries = Decision::from_json(&json!({"boundaries": value.get("boundaries").ok_or_else(shape)?}))?;
        Ok(Self {
            level: value
                .get("level")
                .and_then(Value::as_u64)
                .and_then(|n| u8::try_from(n).ok())
                .filter(|n| (1..=5).contains(n))
                .ok_or_else(shape)?,
            name: value.get("name").and_then(Value::as_str).ok_or_else(shape)?.to_owned(),
            features: strings("features")?,
            route: value.get("route").and_then(Value::as_str).ok_or_else(shape)?.to_owned(),
            open: value.get("open").and_then(Value::as_bool).ok_or_else(shape)?,
            boundaries: boundaries.boundaries,
            withheld_tools: strings("withheld_tools")?,
        })
    }
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
        // The levels' package is the built-in's; stored modules modify a level in its parent
        // (`data.garage.privacy`: `open_routes`, `deny`, ...).
        engine
            .add_policy("builtin/privacy.rego".into(), BUILTIN_PRIVACY.into())
            .map_err(|e| PolicyError(format!("the built-in privacy levels: {e}")))?;
        let builtin_packages = engine.get_packages().map_err(|e| PolicyError(e.to_string()))?;
        let mut adds_to_tools = false;
        let mut modifies_privacy = false;
        for module in modules {
            let package = engine
                .add_policy(format!("{}.rego", module.name), module.rego.clone())
                .map_err(|e| PolicyError(format!("policy {}: {e}", module.name)))?;
            if builtin_packages.contains(&package) {
                return Err(PolicyError(format!("policy {}: {package} is a built-in policy's package", module.name)));
            }
            adds_to_tools |= package == TOOLS_PACKAGE;
            modifies_privacy |= package == PRIVACY_PACKAGE;
        }

        // After the stored modules, which may add to its package (`deny`) but not take its decision.
        engine
            .add_policy("builtin/tools.rego".into(), BUILTIN_TOOLS.into())
            .map_err(|e| PolicyError(format!("the built-in tool policy: {e}")))?;
        let packages = engine.get_packages().map_err(|e| PolicyError(e.to_string()))?;
        if adds_to_tools {
            // A module that adds to the tools package is tried once now, so one that takes the
            // built-in decision or defines `deny` as something other than a set fails its Check, not
            // the first tools/list after it is saved.
            let mut trial = engine.clone();
            trial.set_input(
                regorus::Value::from_json_str(r#"{"caller": {}, "targets": [], "tools": ["a tool"]}"#)
                    .map_err(|e| PolicyError(e.to_string()))?,
            );
            match trial.eval_rule(TOOLS_ENTRY_POINT.into()) {
                Ok(regorus::Value::Undefined) => {
                    return Err(PolicyError(format!(
                        "{TOOLS_ENTRY_POINT} is undefined: `deny` must be a set of tool names"
                    )));
                }
                Ok(_) => {}
                Err(e) => return Err(PolicyError(format!("the tool policy: {e}"))),
            }
        }
        if modifies_privacy {
            // Tried once now, as for the tools, so a modification that is not a set, or one that takes
            // a rule of the level's own, fails its Check rather than every read after it is saved.
            let mut trial = engine.clone();
            trial.set_input(
                regorus::Value::from_json_str(r#"{"caller": {"attributes": {}}, "targets": []}"#)
                    .map_err(|e| PolicyError(e.to_string()))?,
            );
            match trial.eval_rule(PRIVACY_ENTRY_POINT.into()) {
                Ok(regorus::Value::Undefined) => {
                    return Err(PolicyError(format!(
                        "{PRIVACY_ENTRY_POINT} is undefined: open_routes, close_routes, deny, withhold_tools and grant_tools must be sets"
                    )));
                }
                Ok(_) => {}
                Err(e) => return Err(PolicyError(format!("the privacy levels: {e}"))),
            }
        }
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
    /// The privacy level's boundaries come last, whatever the entry point decided: no stored policy
    /// opens what the level closes.
    pub fn decide(&self, input: &Value, data: &Value) -> Result<Decision, PolicyError> {
        let json = self.eval(ENTRY_POINT, input, data)?;
        let mut decision = Decision::from_json(&json)?;
        decision.boundaries.extend(self.privacy(input, data)?.boundaries);
        Ok(decision)
    }

    /// The privacy decision alone (`policy/privacy.rego`), which [`decide`](Self::decide) and the tool
    /// decision already include.
    ///
    /// # Errors
    ///
    /// The evaluation fails, runs out of time, or answers something malformed.
    pub fn privacy(&self, input: &Value, data: &Value) -> Result<Privacy, PolicyError> {
        Privacy::from_json(&self.eval(PRIVACY_ENTRY_POINT, input, data)?)
    }

    /// The tools `input.tools` names that the caller may list and call, in the order given. A name the
    /// policy answers that was not offered is ignored: a policy withholds tools, never adds them.
    ///
    /// # Errors
    ///
    /// The evaluation fails, runs out of time, or answers something other than `{"allowed": [names]}`.
    pub fn tools(&self, input: &Value, data: &Value) -> Result<Vec<String>, PolicyError> {
        let json = self.eval(TOOLS_ENTRY_POINT, input, data)?;
        let allowed = json
            .get("allowed")
            .and_then(Value::as_array)
            .ok_or_else(|| PolicyError(format!("{TOOLS_ENTRY_POINT} is not {{\"allowed\": [...]}}")))?;
        let allowed: Vec<&str> = allowed
            .iter()
            .map(|name| {
                name.as_str()
                    .ok_or_else(|| PolicyError(format!("{TOOLS_ENTRY_POINT} names a tool that is not a string")))
            })
            .collect::<Result<_, _>>()?;
        let offered = input.get("tools").and_then(Value::as_array).cloned().unwrap_or_default();
        Ok(offered.iter().filter_map(Value::as_str).filter(|name| allowed.contains(name)).map(str::to_owned).collect())
    }

    fn eval(&self, entry: &str, input: &Value, data: &Value) -> Result<Value, PolicyError> {
        // Through text, not regorus's From<serde_json::Value>: under Bazel regorus links its own
        // serde_json (the root's crates hub), a different crate from the one garage-rag's hub gives this one.
        let to_rego = |value: &Value, what: &str| {
            regorus::Value::from_json_str(&value.to_string())
                .map_err(|e| PolicyError(format!("the policy's {what}: {e}")))
        };
        let mut engine = self.engine.clone();
        engine.add_data(to_rego(data, "data")?).map_err(|e| PolicyError(format!("the policy's data: {e}")))?;
        engine.set_input(to_rego(input, "input")?);
        let value = engine.eval_rule(entry.into()).map_err(|e| PolicyError(format!("the policy: {e}")))?;
        if value == regorus::Value::Undefined {
            return Err(PolicyError(format!("the policy leaves {entry} undefined for this caller")));
        }
        serde_json::from_str(&value.to_json_str().map_err(|e| PolicyError(format!("the policy's decision: {e}")))?)
            .map_err(|e| PolicyError(format!("the policy's decision: {e}")))
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

    fn offered() -> Vec<String> {
        ["rag_search", "rag_get_document", "rag_agent"].map(String::from).to_vec()
    }

    #[test]
    fn every_tool_is_allowed_until_a_policy_denies_one() {
        let caller = mcp();
        let input = tools_input(&caller, &target_names(&caller), &offered());
        assert_eq!(Policy::builtin().tools(&input, &data(&[], &[])).unwrap(), offered());
        let policy = Policy::new(&[Module {
            name: "no-agent".into(),
            rego: "package garage.tools\n\ndeny contains \"rag_agent\" if input.caller.kind == \"mcp\"\n\ndeny contains \"not_offered\"\n"
                .into(),
        }])
        .unwrap();
        assert_eq!(policy.tools(&input, &data(&[], &[])).unwrap(), ["rag_search", "rag_get_document"]);
        let app = tools_input(&Caller::app(), &["app".into()], &offered());
        assert_eq!(policy.tools(&app, &data(&[], &[])).unwrap(), offered());
        // The access decision is unchanged beside it.
        assert_eq!(decide(&policy, &caller, &[], &[]).boundaries.len(), 1);
    }

    #[test]
    fn a_tool_policy_that_cannot_decide_fails_closed() {
        let module = |rego: &str| Module { name: "t".into(), rego: rego.into() };
        // Taking the built-in decision, or a `deny` that is not a set, fails when compiled (Check).
        let taken = Policy::new(&[module("package garage.tools\n\ndecision := {\"allowed\": []}\n")]);
        assert!(taken.err().unwrap().0.contains("conflicts"));
        let scalar = Policy::new(&[module("package garage.tools\n\ndeny := \"rag_agent\"\n")]);
        assert!(scalar.err().unwrap().0.contains("must be a set"));
        // An error while deciding fails the decision rather than allowing the tool.
        let policy = Policy::new(&[module(
            "package garage.tools\n\ndeny contains name if { some name in input.tools; input.caller.kind == \"app\"; to_number(\"x\") == 1 }\n",
        )])
        .unwrap();
        let input = tools_input(&Caller::app(), &["app".into()], &offered());
        assert!(policy.tools(&input, &data(&[], &[])).is_err());
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

    /// A caller as the node's end of Garage Door makes one (garage-enterprise's `DoorContext::to_caller`).
    fn door(route: &str, privacy: &str, extra: &[(&str, &str)]) -> Caller {
        let mut attributes: std::collections::BTreeMap<String, String> =
            [("garage-door-route", route), ("garage-door-privacy", privacy)]
                .iter()
                .chain(extra)
                .map(|(k, v)| ((*k).to_owned(), (*v).to_owned()))
                .collect();
        attributes.retain(|_, v| !v.is_empty());
        Caller::mcp("http", None).with_attributes(attributes)
    }

    fn module(rego: &str) -> Module {
        Module { name: "p".into(), rego: rego.into() }
    }

    fn privacy_at(caller: &Caller, node: u8) -> Privacy {
        Policy::builtin().privacy(&input(caller, &target_names(caller)), &data_at(&[], &[], node)).unwrap()
    }

    fn tools_at(policy: &Policy, caller: &Caller, node: u8) -> Vec<String> {
        policy.tools(&tools_input(caller, &target_names(caller), &all_tools()), &data_at(&[], &[], node)).unwrap()
    }

    const ALL: [&str; 8] = [
        "rag_search",
        "rag_get_document",
        "rag_list_sources",
        "rag_list_authors",
        "rag_stats",
        "rag_ask",
        "rag_generate",
        "rag_agent",
    ];

    fn all_tools() -> Vec<String> {
        ALL.iter().map(|t| (*t).to_owned()).collect()
    }

    #[test]
    fn each_level_opens_its_routes_and_keeps_the_ones_below() {
        // The lowest level each route opens at: linked nodes 2, the sealed stream 3, hosted assistants 4.
        for (route, lowest) in [("linked", 2), ("sealed", 3), ("web", 4)] {
            for level in 1..=5u8 {
                let privacy = privacy_at(&door(route, &level.to_string(), &[]), 5);
                assert_eq!(privacy.open, level >= lowest, "{route} at {level}");
                assert_eq!(privacy.level, level);
                assert_eq!(privacy.route, route);
                assert_eq!(privacy.boundaries.is_empty(), privacy.open);
            }
        }
        let names: Vec<_> = (1..=5u8).map(|l| privacy_at(&Caller::app(), l).name).collect();
        assert_eq!(names, ["node", "cluster", "remote", "providers", "augmented"]);
        assert_eq!(privacy_at(&Caller::app(), 1).features, Vec::<String>::new());
        assert_eq!(privacy_at(&Caller::app(), 3).features, ["linked_nodes", "remote_access"]);
        assert_eq!(
            privacy_at(&Caller::app(), 5).features,
            ["linked_nodes", "remote_access", "public_providers", "hosted_vault"]
        );
    }

    #[test]
    fn the_node_is_never_closed_to_itself() {
        for caller in [Caller::app(), Caller::cli(), Caller::unverified(), Caller::mcp("stdio", None), mcp()] {
            let privacy = privacy_at(&caller, 1);
            assert_eq!(privacy.route, "local");
            assert!(privacy.open && privacy.boundaries.is_empty());
        }
    }

    #[test]
    fn a_caller_can_only_lower_the_level() {
        // The lower of the node's level and the reported one.
        assert_eq!(privacy_at(&door("web", "5", &[]), 3).level, 3);
        assert!(!privacy_at(&door("web", "5", &[]), 3).open);
        assert_eq!(privacy_at(&door("web", "2", &[]), 5).level, 2);
        // Anything but 1 to 5 reads as the most private.
        for junk in ["0", "6", "4.0", "four", " 4"] {
            assert_eq!(privacy_at(&door("sealed", junk, &[]), 5).level, 1, "{junk}");
        }
        // So does a node level out of range.
        assert_eq!(privacy_at(&Caller::app(), 0).level, 1);
        assert_eq!(privacy_at(&Caller::app(), 9).level, 1);
        // No report: the node's own level.
        assert_eq!(privacy_at(&door("sealed", "", &[]), 4).level, 4);
    }

    #[test]
    fn a_route_the_policy_does_not_know_opens_at_no_level() {
        let privacy = privacy_at(&door("satellite", "5", &[]), 5);
        assert_eq!(privacy.route, "satellite");
        assert!(!privacy.open);
        // A Garage Door connector's registration with no route is a hosted assistant's.
        let connector = Caller::mcp(
            "http",
            Some(Registration { id: "d1".into(), name: "Door".into(), client: "garage-door".into() }),
        );
        assert_eq!(privacy_at(&connector, 5).route, "web");
        assert!(privacy_at(&connector, 5).open);
        assert!(!privacy_at(&connector, 3).open);
    }

    #[test]
    fn a_closed_route_sees_nothing_whatever_a_stored_policy_says() {
        let caller = door("web", "3", &[]);
        let closed = decide(&Policy::builtin(), &caller, &[], &[]);
        let last = closed.boundaries.last().unwrap();
        assert_eq!(last.target, "privacy:web");
        assert_eq!(last.default, Effect::Deny);
        assert!(last.allow.is_empty());
        // A stored entry point that allows everything still carries the level's boundary.
        let open_door = Policy::new(&[module("package garage.access\n\ndecision := {\"boundaries\": []}\n")]).unwrap();
        assert_eq!(decide(&open_door, &caller, &[], &[]).boundaries, std::slice::from_ref(last));
        // A stored module cannot take the level's own rules, only add to its modifications.
        let taken = Policy::new(&[module("package garage.privacy.levels\n\nopen := true\n")]);
        assert!(taken.err().unwrap().0.contains("built-in"));
        let ignored = Policy::new(&[module("package garage.privacy\n\nopen := true\n")]).unwrap();
        assert!(!ignored.privacy(&input(&caller, &target_names(&caller)), &data(&[], &[])).unwrap().open);
        let scalar = Policy::new(&[module("package garage.privacy\n\nopen_routes := \"web\"\n")]);
        assert!(scalar.err().unwrap().0.contains("must be sets"));
        // Open, the level adds nothing.
        assert!(decide(&open_door, &door("web", "4", &[]), &[], &[]).boundaries.is_empty());
    }

    #[test]
    fn a_closed_route_gets_no_tools_and_a_phone_runs_the_model_only_when_allowed() {
        let policy = Policy::builtin();
        assert_eq!(tools_at(&policy, &door("web", "3", &[]), 5), Vec::<String>::new());
        assert_eq!(tools_at(&policy, &door("web", "4", &[]), 5), all_tools());
        assert_eq!(tools_at(&policy, &Caller::app(), 1), all_tools());
        let retrieval = &all_tools()[..5];
        // A phone gets the retrieval tools, and the node's model only with the ask scope and the switch on.
        assert_eq!(tools_at(&policy, &door("sealed", "3", &[]), 5), retrieval);
        let scoped = |scope: &str, inference: &str| {
            door("sealed", "3", &[("garage-door-scope", scope), ("garage-door-inference", inference)])
        };
        assert_eq!(tools_at(&policy, &scoped("search", "1"), 5), retrieval);
        assert_eq!(tools_at(&policy, &scoped("ask", "0"), 5), retrieval);
        assert_eq!(tools_at(&policy, &scoped("ask", "1"), 5), all_tools());
        assert_eq!(privacy_at(&scoped("ask", "0"), 5).withheld_tools, ["rag_agent", "rag_ask", "rag_generate"]);
        // A stored deny still applies on top.
        let deny = Policy::new(&[module("package garage.tools\n\ndeny contains \"rag_stats\" if true\n")]).unwrap();
        assert_eq!(tools_at(&deny, &scoped("ask", "1"), 5).len(), 7);
        assert!(tools_at(&deny, &door("sealed", "2", &[]), 5).is_empty());
    }

    #[test]
    fn a_stored_module_modifies_the_base_level() {
        let modified = Policy::new(&[module(
            r#"package garage.privacy

import data.garage.privacy.levels

open_routes contains "web" if levels.level >= 3
close_routes contains "sealed" if levels.level < 5
close_routes contains "local"
deny contains {"corpus_class": "communication"} if levels.route == "web"
withhold_tools contains "rag_agent" if levels.route == "web"
grant_tools contains "rag_ask" if levels.route == "sealed"
"#,
        )])
        .unwrap();
        let privacy =
            |caller: &Caller| modified.privacy(&input(caller, &target_names(caller)), &data_at(&[], &[], 5)).unwrap();
        // Hosted assistants open a level early, held to the added condition.
        let web = privacy(&door("web", "3", &[]));
        assert!(web.open);
        assert_eq!(web.boundaries.len(), 1);
        assert_eq!(web.boundaries[0].default, Effect::Allow);
        assert_eq!(web.boundaries[0].deny, [Condition::Inline(Matcher::CorpusClass(vec!["communication".into()]))]);
        assert_eq!(web.withheld_tools, ["rag_agent"]);
        // Phones close until augmented, and get rag_ask back there.
        assert!(!privacy(&door("sealed", "4", &[])).open);
        let phone = privacy(&door("sealed", "5", &[]));
        assert!(phone.open);
        assert_eq!(phone.withheld_tools, ["rag_agent", "rag_generate"]);
        // The node is never closed to itself.
        assert!(privacy(&Caller::app()).open);
        // Below 3 the base level still keeps assistants out.
        assert!(!privacy(&door("web", "2", &[])).open);
    }
}

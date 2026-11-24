//! Rules, their matchers and their targets (`docs/plans/access-policies.md`, "What decides"), as
//! plain values: no database here.

use std::fmt;

use garage_access::{Caller, CallerKind};
use serde_json::{Map, Value, json};

/// What a rule does to the documents it matches.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Effect {
    Allow,
    Deny,
}

impl Effect {
    pub fn name(self) -> &'static str {
        match self {
            Self::Allow => "allow",
            Self::Deny => "deny",
        }
    }

    /// # Errors
    ///
    /// Neither `allow` nor `deny`.
    pub fn parse(text: &str) -> Result<Self, RuleError> {
        match text {
            "allow" => Ok(Self::Allow),
            "deny" => Ok(Self::Deny),
            other => Err(RuleError(format!("effect must be allow or deny, not {other:?}"))),
        }
    }
}

/// What a `regex` rule reads.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Field {
    /// Any chunk's text (facts included: they are chunks of their document).
    Text,
    Title,
    Path,
}

impl Field {
    pub fn name(self) -> &'static str {
        match self {
            Self::Text => "text",
            Self::Title => "title",
            Self::Path => "path",
        }
    }
}

/// How a rule decides which documents it matches.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Matcher {
    /// The document's source is one of these slugs.
    Source(Vec<String>),
    /// Its `corpus_class` is one of these.
    CorpusClass(Vec<String>),
    /// Its `trust_tier` is one of these.
    TrustTier(Vec<String>),
    /// One of its authors' names or identities contains this, case-insensitive.
    Author(String),
    /// Its URI matches this glob (`*` any run of characters, `?` one).
    Path(String),
    /// A POSIX regular expression (Postgres's `~`), over a field.
    Regex { pattern: String, field: Field, case_sensitive: bool },
    /// A keyword query (`websearch_to_tsquery`), over any chunk, stemmed as the search is.
    Term(String),
}

impl Matcher {
    /// The matcher's name, as `access_rules.matcher` stores it.
    pub fn kind(&self) -> &'static str {
        match self {
            Self::Source(_) => "source",
            Self::CorpusClass(_) => "corpus_class",
            Self::TrustTier(_) => "trust_tier",
            Self::Author(_) => "author",
            Self::Path(_) => "path",
            Self::Regex { .. } => "regex",
            Self::Term(_) => "term",
        }
    }

    /// Whether it reads content, so it is evaluated ahead of a query and stored, rather than put
    /// inline in the filter.
    pub fn reads_content(&self) -> bool {
        matches!(self, Self::Regex { .. } | Self::Term(_))
    }

    /// The `match` object of a rule (`{"regex": "...", "field": "text"}`).
    ///
    /// # Errors
    ///
    /// No known matcher, or a malformed one.
    pub fn from_json(spec: &Value) -> Result<Self, RuleError> {
        let object = spec.as_object().ok_or_else(|| RuleError::new("match must be an object"))?;
        let list = |key: &str| -> Result<Vec<String>, RuleError> {
            match &object[key] {
                Value::String(one) => Ok(vec![one.clone()]),
                Value::Array(items) => items
                    .iter()
                    .map(|v| v.as_str().map(str::to_owned).ok_or_else(|| RuleError(format!("{key} lists strings"))))
                    .collect(),
                _ => Err(RuleError(format!("{key} is a string or a list of strings"))),
            }
        };
        let text = |key: &str| -> Result<String, RuleError> {
            object[key]
                .as_str()
                .filter(|s| !s.is_empty())
                .map(str::to_owned)
                .ok_or_else(|| RuleError(format!("{key} is a non-empty string")))
        };
        let matcher = if object.contains_key("source") {
            Self::Source(list("source")?)
        } else if object.contains_key("corpus_class") {
            Self::CorpusClass(list("corpus_class")?)
        } else if object.contains_key("trust_tier") {
            Self::TrustTier(list("trust_tier")?)
        } else if object.contains_key("author") {
            Self::Author(text("author")?)
        } else if object.contains_key("path") {
            Self::Path(text("path")?)
        } else if object.contains_key("regex") {
            let field = match object.get("field").and_then(Value::as_str).unwrap_or("text") {
                "text" => Field::Text,
                "title" => Field::Title,
                "path" => Field::Path,
                other => {
                    return Err(RuleError(format!("field must be text, title or path, not {other:?}")));
                }
            };
            let case_sensitive = object.get("case_sensitive").and_then(Value::as_bool).unwrap_or(false);
            Self::Regex { pattern: text("regex")?, field, case_sensitive }
        } else if object.contains_key("term") {
            Self::Term(text("term")?)
        } else if object.contains_key("similar") || object.contains_key("judge") {
            return Err(RuleError::new("similar and judge rules are not supported yet"));
        } else {
            return Err(RuleError::new(
                "match needs one of source, corpus_class, trust_tier, author, path, regex or term",
            ));
        };
        if let Self::Source(v) | Self::CorpusClass(v) | Self::TrustTier(v) = &matcher
            && v.is_empty()
        {
            return Err(RuleError(format!("{} lists nothing", matcher.kind())));
        }
        Ok(matcher)
    }

    /// The `match` object, normalized: what a rule's version is a hash of.
    pub fn to_json(&self) -> Value {
        match self {
            Self::Source(v) => json!({"source": v}),
            Self::CorpusClass(v) => json!({"corpus_class": v}),
            Self::TrustTier(v) => json!({"trust_tier": v}),
            Self::Author(a) => json!({"author": a}),
            Self::Path(p) => json!({"path": p}),
            Self::Regex { pattern, field, case_sensitive } => {
                json!({"regex": pattern, "field": field.name(), "case_sensitive": case_sensitive})
            }
            Self::Term(t) => json!({"term": t}),
        }
    }
}

/// A rule as the user writes it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Rule {
    pub name: String,
    pub effect: Effect,
    /// Target names and prefix patterns ending in `*` (`app`, `mcp:*`, `door:<id>/*`, `*`).
    pub targets: Vec<String>,
    pub matcher: Matcher,
    pub enabled: bool,
}

impl Rule {
    /// A rule from its JSON (`{"name", "effect", "targets", "match", "enabled"}`).
    ///
    /// # Errors
    ///
    /// A missing or malformed part.
    pub fn from_json(value: &Value) -> Result<Self, RuleError> {
        let object = value.as_object().ok_or_else(|| RuleError::new("a rule is an object"))?;
        let name = object
            .get("name")
            .and_then(Value::as_str)
            .filter(|n| !n.trim().is_empty())
            .ok_or_else(|| RuleError::new("a rule needs a name"))?
            .to_owned();
        let effect = Effect::parse(object.get("effect").and_then(Value::as_str).unwrap_or_default())?;
        let targets: Vec<String> = match object.get("targets") {
            Some(Value::Array(items)) => items.iter().filter_map(Value::as_str).map(str::to_owned).collect(),
            _ => return Err(RuleError::new("targets is a list of target names")),
        };
        let matcher = Matcher::from_json(object.get("match").unwrap_or(&Value::Null))?;
        let enabled = object.get("enabled").and_then(Value::as_bool).unwrap_or(true);
        Ok(Self { name, effect, targets, matcher, enabled })
    }

    pub fn to_json(&self) -> Value {
        let mut object = Map::new();
        object.insert("name".into(), json!(self.name));
        object.insert("effect".into(), json!(self.effect.name()));
        object.insert("targets".into(), json!(self.targets));
        object.insert("match".into(), self.matcher.to_json());
        object.insert("enabled".into(), json!(self.enabled));
        Value::Object(object)
    }

    /// Whether the rule applies to the target named `target`.
    pub fn applies_to(&self, target: &str) -> bool {
        self.targets.iter().any(|pattern| pattern_matches(pattern, target))
    }
}

/// A target pattern: `*` is every target, `prefix*` every target starting with it, anything else
/// that target alone.
pub fn pattern_matches(pattern: &str, target: &str) -> bool {
    match pattern.strip_suffix('*') {
        Some(prefix) => target.starts_with(prefix),
        None => pattern == target,
    }
}

/// The default for `target` among `defaults`: an exact name first, then the longest prefix
/// pattern, then `*`; with none, ALLOW, so a corpus with no rules reads as it did before.
pub fn default_for(defaults: &[(String, Effect)], target: &str) -> Effect {
    if let Some((_, effect)) = defaults.iter().find(|(pattern, _)| pattern == target) {
        return *effect;
    }
    defaults
        .iter()
        .filter(|(pattern, _)| pattern.ends_with('*') && pattern_matches(pattern, target))
        .max_by_key(|(pattern, _)| pattern.len())
        .map_or(Effect::Allow, |(_, effect)| *effect)
}

/// The header Door sets on a request it relays, naming the assistant registration the gateway authenticated
/// (its `REGISTRATION_HEADER`); no client can send it through.
pub const DOOR_CLIENT_HEADER: &str = "x-garage-registration";
/// The `client` a door connector's registration carries.
pub const DOOR_CLIENT: &str = "garage-door";

/// The target names a caller is checked against, outermost first. A door's grant is checked against
/// its door and then itself, so it never sees more than its door.
pub fn target_names(caller: &Caller) -> Vec<String> {
    match caller.kind {
        CallerKind::App => vec!["app".into()],
        CallerKind::Cli => vec!["cli".into()],
        CallerKind::Unverified => vec!["unverified".into()],
        CallerKind::Mcp => match &caller.registration {
            None => vec!["mcp:unregistered".into()],
            Some(registration) if registration.client == DOOR_CLIENT => {
                let door = format!("door:{}", registration.id);
                // Honoured only on a door's registration: the gateway sets it after its own token
                // check and strips any value the client sent.
                match caller.attributes.get(DOOR_CLIENT_HEADER).filter(|g| !g.is_empty() && !g.contains('/')) {
                    Some(grant) => vec![door.clone(), format!("{door}/{grant}")],
                    None => vec![door],
                }
            }
            Some(registration) => vec![format!("mcp:{}", registration.id)],
        },
    }
}

/// A rule that cannot be stored or used.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RuleError(pub String);

impl RuleError {
    pub fn new(message: impl Into<String>) -> Self {
        Self(message.into())
    }
}

impl fmt::Display for RuleError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for RuleError {}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use garage_access::Registration;

    use super::*;

    #[test]
    fn rules_round_trip_through_json() {
        let rule = Rule::from_json(&json!({
            "name": "no-keys", "effect": "deny", "targets": ["*"],
            "match": {"regex": "-----BEGIN [A-Z ]*PRIVATE KEY-----"}
        }))
        .unwrap();
        assert_eq!(
            rule.matcher,
            Matcher::Regex {
                pattern: "-----BEGIN [A-Z ]*PRIVATE KEY-----".into(),
                field: Field::Text,
                case_sensitive: false
            }
        );
        assert!(rule.enabled && rule.matcher.reads_content());
        assert_eq!(Rule::from_json(&rule.to_json()).unwrap(), rule);
        let work = Rule::from_json(&json!({
            "name": "work-only", "effect": "allow", "targets": ["door:abc"], "match": {"source": "work"}
        }))
        .unwrap();
        assert_eq!(work.matcher, Matcher::Source(vec!["work".into()]));
        assert!(!work.matcher.reads_content());
    }

    #[test]
    fn malformed_rules_are_refused() {
        let base = |m: Value| json!({"name": "r", "effect": "deny", "targets": ["*"], "match": m});
        assert!(Rule::from_json(&base(json!({}))).is_err());
        assert!(Rule::from_json(&base(json!({"source": []}))).is_err());
        assert!(Rule::from_json(&base(json!({"regex": "x", "field": "body"}))).is_err());
        assert!(Rule::from_json(&base(json!({"similar": "my health"}))).unwrap_err().0.contains("not supported"));
        assert!(
            Rule::from_json(&json!({"name": "r", "effect": "hide", "targets": [], "match": {"term": "x"}})).is_err()
        );
        assert!(Rule::from_json(&json!({"effect": "deny", "targets": [], "match": {"term": "x"}})).is_err());
    }

    #[test]
    fn patterns_and_defaults_pick_the_most_specific() {
        assert!(pattern_matches("*", "app"));
        assert!(pattern_matches("mcp:*", "mcp:unregistered"));
        assert!(!pattern_matches("mcp:*", "door:a"));
        assert!(pattern_matches("door:a/*", "door:a/g"));
        assert!(!pattern_matches("door:a", "door:a/g"));
        let defaults = vec![
            ("*".to_owned(), Effect::Deny),
            ("mcp:*".to_owned(), Effect::Allow),
            ("mcp:unregistered".to_owned(), Effect::Deny),
        ];
        assert_eq!(default_for(&defaults, "mcp:r1"), Effect::Allow);
        assert_eq!(default_for(&defaults, "mcp:unregistered"), Effect::Deny);
        assert_eq!(default_for(&defaults, "door:x"), Effect::Deny);
        assert_eq!(default_for(&[], "door:x"), Effect::Allow);
    }

    #[test]
    fn callers_map_to_targets_and_only_a_door_names_a_grant() {
        let registration = |client: &str| Registration { id: "r1".into(), name: "n".into(), client: client.into() };
        let grant = BTreeMap::from([(DOOR_CLIENT_HEADER.to_owned(), "g7".to_owned())]);
        assert_eq!(target_names(&Caller::app()), ["app"]);
        assert_eq!(target_names(&Caller::mcp("stdio", None)), ["mcp:unregistered"]);
        let assistant = Caller::mcp("http", Some(registration("cursor"))).with_attributes(grant.clone());
        assert_eq!(target_names(&assistant), ["mcp:r1"]);
        let door = Caller::mcp("http", Some(registration(DOOR_CLIENT))).with_attributes(grant);
        assert_eq!(target_names(&door), ["door:r1", "door:r1/g7"]);
        let bare = Caller::mcp("http", Some(registration(DOOR_CLIENT)));
        assert_eq!(target_names(&bare), ["door:r1"]);
    }
}

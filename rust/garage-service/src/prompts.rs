//! Fact-extraction prompts: the `facts.prompts` setting and the built-in default
//! (`garage_rag.config.fact_prompts`).
//!
//! A prompt is what the extractor is given besides the document: a description (the instructions)
//! and few-shot examples, each an example text with the extractions expected from it. The built-in
//! prompts (`default`) are always present unless overridden: an entry of a built-in's name replaces
//! it field by field, and any other entry is added after the built-ins. An override may leave
//! `description` or `examples` out to keep the built-in's; a prompt that is not a built-in must
//! give both. Each fact records its prompt's name and the hash of what the model was shown.
//!
//! A prompt's optional `graph` block says how its classes appear in the AGE graph (`graph.rs`):
//! vertices of their own label, or edges between other classes' distilled facts.
//! [`graph_schema`] merges every prompt's block and rejects labels that clash.

use std::collections::BTreeMap;

use garage_mcp::pyjson;
use garage_mcp::pyrepr::str_repr;
use regex::Regex;
use serde_json::{Map, Value, json};

use std::sync::LazyLock;

use crate::error::{Result, ServiceError};

/// The corpus classes a prompt may be scoped to (`CorpusClassName`).
pub const CORPUS_CLASS_NAMES: [&str; 3] = ["document", "code", "communication"];

/// The built-in prompt's name (`DEFAULT_PROMPT_NAME`).
pub const DEFAULT_PROMPT_NAME: &str = "default";
/// The built-in prompts' names (`BUILTIN_PROMPT_NAMES`).
pub const BUILTIN_PROMPT_NAMES: [&str; 1] = [DEFAULT_PROMPT_NAME];
/// The projection's own vertex labels, which configuration may not take.
pub const BUILTIN_VERTEX_LABELS: [&str; 5] = ["Document", "Chunk", "Author", "PotentialFact", "Fact"];
/// The projection's own edge labels.
pub const BUILTIN_EDGE_LABELS: [&str; 6] = ["HAS_CHUNK", "WROTE", "RECEIVED", "STATES", "RESTATES", "SUPPORTS"];

/// The built-in `default` prompt's instructions (`DEFAULT_DESCRIPTION`).
pub const DEFAULT_DESCRIPTION: &str = "Extract every standalone fact stated in this document.\n\n\
A fact is a single, self-contained claim or piece of information that\n\
would still be true and meaningful if read on its own, out of context.\n\
Use the exact wording from the document for each fact -- do not\n\
paraphrase, summarize, or combine multiple facts into one. Do not invent\n\
or infer anything that is not explicitly stated. List facts in the order\n\
they appear.";

static PROMPT_NAME: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$").unwrap());
static VERTEX_LABEL: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[A-Z][A-Za-z0-9]{0,62}$").unwrap());
static EDGE_LABEL: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[A-Z][A-Z0-9_]{0,62}$").unwrap());
static ATTRIBUTE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[A-Za-z_][A-Za-z0-9_]{0,62}$").unwrap());
static CLASS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[A-Za-z0-9][A-Za-z0-9 _.-]{0,62}$").unwrap());

/// One extraction the model should produce from an example's text (`FactExtractionExample`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ExampleExtraction {
    /// `class`: what kind of thing this is; stored as `facts.fact_class`.
    pub class: String,
    /// The extraction, quoted exactly from the example's text.
    pub text: String,
    /// Attributes the model should attach (each a string or a list of strings).
    pub attributes: Map<String, Value>,
}

/// A few-shot example: a text and what should be extracted from it (`FactExample`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Example {
    pub text: String,
    pub extractions: Vec<ExampleExtraction>,
}

/// A class whose distilled facts are vertices of their own label (`GraphVertex` in the config).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct VertexSpec {
    /// `class`: the extraction class projected.
    pub class: String,
    pub label: String,
    /// The attribute whose value names the vertex; unset: the distilled fact's statement.
    pub title: Option<String>,
}

/// A class whose potential facts are edges between two other classes' distilled facts.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EdgeSpec {
    pub class: String,
    pub source: String,
    pub source_class: String,
    pub target: String,
    pub target_class: String,
    /// The edge label, or the fallback when `label_attribute` names none of `labels`.
    pub label: String,
    pub label_attribute: Option<String>,
    pub labels: Vec<String>,
}

/// How a prompt's classes appear in the graph (`FactGraph`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct FactGraph {
    pub vertices: Vec<VertexSpec>,
    pub edges: Vec<EdgeSpec>,
}

/// A named fact-extraction prompt, as written in `facts.prompts` (`FactPrompt`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FactPrompt {
    pub name: String,
    pub description: Option<String>,
    pub examples: Option<Vec<Example>>,
    pub corpus_classes: Vec<String>,
    pub sources: Vec<String>,
    pub enabled: bool,
    pub graph: Option<FactGraph>,
}

/// A prompt as it runs: an override merged onto its built-in, everything filled in
/// (`EffectivePrompt`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EffectivePrompt {
    pub name: String,
    pub description: String,
    pub examples: Vec<Example>,
    pub corpus_classes: Vec<String>,
    pub sources: Vec<String>,
    pub enabled: bool,
    pub builtin: bool,
    /// A built-in with an entry in `facts.prompts`.
    pub customized: bool,
    pub graph: Option<FactGraph>,
}

fn invalid(message: String) -> ServiceError {
    ServiceError::invalid(message)
}

fn field_str(object: &Map<String, Value>, key: &str, context: &str) -> Result<Option<String>> {
    match object.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) => Ok(Some(s.clone())),
        Some(other) => Err(invalid(format!("{context}: {key} must be a string, not {}", kind_of(other)))),
    }
}

fn required_str(object: &Map<String, Value>, key: &str, context: &str) -> Result<String> {
    field_str(object, key, context)?.ok_or_else(|| invalid(format!("{context}: {key} is required")))
}

fn matched(value: String, pattern: &Regex, what: &str, context: &str) -> Result<String> {
    if pattern.is_match(&value) {
        Ok(value)
    } else {
        Err(invalid(format!("{context}: {what} {} does not match {}", str_repr(&value), pattern.as_str())))
    }
}

fn kind_of(value: &Value) -> &'static str {
    match value {
        Value::Null => "null",
        Value::Bool(_) => "a boolean",
        Value::Number(_) => "a number",
        Value::String(_) => "a string",
        Value::Array(_) => "a list",
        Value::Object(_) => "an object",
    }
}

fn forbid_extra(object: &Map<String, Value>, allowed: &[&str], context: &str) -> Result<()> {
    for key in object.keys() {
        if !allowed.contains(&key.as_str()) {
            return Err(invalid(format!("{context}: unknown field {}", str_repr(key))));
        }
    }
    Ok(())
}

fn str_list(object: &Map<String, Value>, key: &str, context: &str) -> Result<Vec<String>> {
    match object.get(key) {
        None | Some(Value::Null) => Ok(Vec::new()),
        Some(Value::Array(items)) => items
            .iter()
            .map(|item| {
                item.as_str()
                    .map(str::to_owned)
                    .ok_or_else(|| invalid(format!("{context}: {key} must be a list of strings")))
            })
            .collect(),
        Some(_) => Err(invalid(format!("{context}: {key} must be a list of strings"))),
    }
}

fn parse_extraction(value: &Value, context: &str) -> Result<ExampleExtraction> {
    let Value::Object(object) = value else {
        return Err(invalid(format!("{context}: each extraction must be an object")));
    };
    forbid_extra(object, &["class", "extraction_class", "text", "attributes"], context)?;
    let class = field_str(object, "class", context)?
        .or(field_str(object, "extraction_class", context)?)
        .unwrap_or_else(|| "fact".to_owned());
    let text = required_str(object, "text", context)?;
    let mut attributes = Map::new();
    match object.get("attributes") {
        None | Some(Value::Null) => {}
        Some(Value::Object(given)) => {
            for (key, value) in given {
                let ok = match value {
                    Value::String(_) => true,
                    Value::Array(items) => items.iter().all(Value::is_string),
                    _ => false,
                };
                if !ok {
                    return Err(invalid(format!(
                        "{context}: attribute {} must be a string or a list of strings",
                        str_repr(key)
                    )));
                }
                attributes.insert(key.clone(), value.clone());
            }
        }
        Some(_) => return Err(invalid(format!("{context}: attributes must be an object"))),
    }
    Ok(ExampleExtraction { class, text, attributes })
}

fn parse_example(value: &Value, context: &str) -> Result<Example> {
    let Value::Object(object) = value else {
        return Err(invalid(format!("{context}: each example must be an object")));
    };
    forbid_extra(object, &["text", "extractions"], context)?;
    let text = required_str(object, "text", context)?;
    let extractions = match object.get("extractions") {
        None | Some(Value::Null) => Vec::new(),
        Some(Value::Array(items)) => items.iter().map(|e| parse_extraction(e, context)).collect::<Result<_>>()?,
        Some(_) => return Err(invalid(format!("{context}: extractions must be a list"))),
    };
    Ok(Example { text, extractions })
}

fn parse_vertex(value: &Value, context: &str) -> Result<VertexSpec> {
    let Value::Object(object) = value else {
        return Err(invalid(format!("{context}: each graph vertex must be an object")));
    };
    forbid_extra(object, &["class", "extraction_class", "label", "title"], context)?;
    let class = field_str(object, "class", context)?
        .or(field_str(object, "extraction_class", context)?)
        .ok_or_else(|| invalid(format!("{context}: a graph vertex needs a class")))?;
    Ok(VertexSpec {
        class: matched(class, &CLASS, "class", context)?,
        label: matched(required_str(object, "label", context)?, &VERTEX_LABEL, "label", context)?,
        title: field_str(object, "title", context)?.map(|t| matched(t, &ATTRIBUTE, "title", context)).transpose()?,
    })
}

fn parse_edge(value: &Value, context: &str) -> Result<EdgeSpec> {
    let Value::Object(object) = value else {
        return Err(invalid(format!("{context}: each graph edge must be an object")));
    };
    forbid_extra(
        object,
        &[
            "class",
            "extraction_class",
            "source",
            "source_class",
            "target",
            "target_class",
            "label",
            "label_attribute",
            "labels",
        ],
        context,
    )?;
    let class = field_str(object, "class", context)?
        .or(field_str(object, "extraction_class", context)?)
        .ok_or_else(|| invalid(format!("{context}: a graph edge needs a class")))?;
    let labels = str_list(object, "labels", context)?;
    for label in &labels {
        if !EDGE_LABEL.is_match(label) {
            return Err(invalid(format!(
                "{context}: {} is not an edge label (upper case, digits and _)",
                str_repr(label)
            )));
        }
    }
    Ok(EdgeSpec {
        class: matched(class, &CLASS, "class", context)?,
        source: matched(required_str(object, "source", context)?, &ATTRIBUTE, "source", context)?,
        source_class: matched(required_str(object, "source_class", context)?, &CLASS, "source_class", context)?,
        target: matched(required_str(object, "target", context)?, &ATTRIBUTE, "target", context)?,
        target_class: matched(required_str(object, "target_class", context)?, &CLASS, "target_class", context)?,
        label: matched(
            field_str(object, "label", context)?.unwrap_or_else(|| "RELATED_TO".to_owned()),
            &EDGE_LABEL,
            "label",
            context,
        )?,
        label_attribute: field_str(object, "label_attribute", context)?
            .map(|a| matched(a, &ATTRIBUTE, "label_attribute", context))
            .transpose()?,
        labels,
    })
}

fn parse_graph(value: &Value, context: &str) -> Result<FactGraph> {
    let Value::Object(object) = value else {
        return Err(invalid(format!("{context}: graph must be an object")));
    };
    forbid_extra(object, &["vertices", "edges"], context)?;
    let list = |key: &str| -> Result<Vec<Value>> {
        match object.get(key) {
            None | Some(Value::Null) => Ok(Vec::new()),
            Some(Value::Array(items)) => Ok(items.clone()),
            Some(_) => Err(invalid(format!("{context}: graph.{key} must be a list"))),
        }
    };
    Ok(FactGraph {
        vertices: list("vertices")?.iter().map(|v| parse_vertex(v, context)).collect::<Result<_>>()?,
        edges: list("edges")?.iter().map(|e| parse_edge(e, context)).collect::<Result<_>>()?,
    })
}

/// One `facts.prompts` entry.
///
/// # Errors
///
/// A shape pydantic would refuse: a missing or malformed name, an unknown field, a field of the
/// wrong type, a label or attribute that does not match its pattern, an empty examples list.
pub fn parse_prompt(value: &Value) -> Result<FactPrompt> {
    let Value::Object(object) = value else {
        return Err(invalid("facts.prompts: each prompt must be an object".to_owned()));
    };
    let name = match object.get("name") {
        Some(Value::String(name)) => name.clone(),
        _ => return Err(invalid("facts.prompts: each prompt needs a name".to_owned())),
    };
    let context = format!("facts.prompts: {}", str_repr(&name));
    forbid_extra(
        object,
        &["name", "description", "examples", "corpus_classes", "sources", "enabled", "graph"],
        &context,
    )?;
    let name = matched(name, &PROMPT_NAME, "name", &context)?;
    let examples = match object.get("examples") {
        None | Some(Value::Null) => None,
        Some(Value::Array(items)) => {
            if items.is_empty() {
                return Err(invalid(format!("{context}: examples must not be empty; LangExtract needs at least one")));
            }
            Some(items.iter().map(|e| parse_example(e, &context)).collect::<Result<_>>()?)
        }
        Some(_) => return Err(invalid(format!("{context}: examples must be a list"))),
    };
    let corpus_classes = str_list(object, "corpus_classes", &context)?;
    for class in &corpus_classes {
        if !CORPUS_CLASS_NAMES.contains(&class.as_str()) {
            return Err(invalid(format!(
                "{context}: corpus class {} is not one of {}",
                str_repr(class),
                CORPUS_CLASS_NAMES.join(", ")
            )));
        }
    }
    let enabled = match object.get("enabled") {
        None | Some(Value::Null) => true,
        Some(Value::Bool(b)) => *b,
        Some(_) => return Err(invalid(format!("{context}: enabled must be true or false"))),
    };
    Ok(FactPrompt {
        name,
        description: field_str(object, "description", &context)?,
        examples,
        corpus_classes,
        sources: str_list(object, "sources", &context)?,
        enabled,
        graph: object.get("graph").filter(|g| !g.is_null()).map(|g| parse_graph(g, &context)).transpose()?,
    })
}

/// The built-in prompts (`BUILTIN_PROMPTS`): today just `default`.
pub fn builtin_prompts() -> Vec<FactPrompt> {
    vec![FactPrompt {
        name: DEFAULT_PROMPT_NAME.to_owned(),
        description: Some(DEFAULT_DESCRIPTION.to_owned()),
        examples: Some(vec![Example {
            text: "Acme Corp was founded in 1998 by Jane Doe. The company is headquartered in Austin, Texas, and \
                   has 42 employees."
                .to_owned(),
            extractions: [
                "Acme Corp was founded in 1998 by Jane Doe.",
                "The company is headquartered in Austin, Texas.",
                "The company has 42 employees.",
            ]
            .into_iter()
            .map(|text| ExampleExtraction { class: "fact".to_owned(), text: text.to_owned(), attributes: Map::new() })
            .collect(),
        }]),
        corpus_classes: Vec::new(),
        sources: Vec::new(),
        enabled: true,
        graph: None,
    }]
}

/// `validate_prompt_list`: names are unique, a prompt that is not a built-in says everything
/// itself, and the graph blocks merge.
///
/// # Errors
///
/// `ValueError`'s messages, as `INVALID_ARGUMENT`.
pub fn validate_prompt_list(prompts: &[FactPrompt]) -> Result<()> {
    let mut seen = std::collections::BTreeSet::new();
    for prompt in prompts {
        if !seen.insert(prompt.name.as_str()) {
            return Err(invalid(format!("facts.prompts: the name {} is used twice", str_repr(&prompt.name))));
        }
        if BUILTIN_PROMPT_NAMES.contains(&prompt.name.as_str()) {
            continue;
        }
        let mut missing = Vec::new();
        if prompt.description.is_none() {
            missing.push("description");
        }
        if prompt.examples.is_none() {
            missing.push("examples");
        }
        if !missing.is_empty() {
            return Err(invalid(format!(
                "facts.prompts: {} is not a built-in prompt, so it needs {}",
                str_repr(&prompt.name),
                missing.join(" and ")
            )));
        }
        if prompt.description.as_deref().unwrap_or_default().trim().is_empty() {
            return Err(invalid(format!("facts.prompts: {} has an empty description", str_repr(&prompt.name))));
        }
    }
    graph_schema(&effective_prompts(prompts)?)?;
    Ok(())
}

/// The `facts.prompts` value parsed and validated.
///
/// # Errors
///
/// What [`parse_prompt`] and [`validate_prompt_list`] refuse.
pub fn parse_prompts(value: &Value) -> Result<Vec<FactPrompt>> {
    let Value::Array(items) = value else {
        return Err(invalid("fact_prompts: expected a list of prompts".to_owned()));
    };
    let prompts = items.iter().map(parse_prompt).collect::<Result<Vec<_>>>()?;
    validate_prompt_list(&prompts)?;
    Ok(prompts)
}

fn resolve(prompt: &FactPrompt, base: Option<&FactPrompt>) -> Result<EffectivePrompt> {
    let description = prompt.description.clone().or_else(|| base.and_then(|b| b.description.clone()));
    let examples = prompt.examples.clone().or_else(|| base.and_then(|b| b.examples.clone()));
    let (Some(description), Some(examples)) = (description, examples) else {
        return Err(invalid(format!("facts.prompts: {} needs a description and examples", str_repr(&prompt.name))));
    };
    Ok(EffectivePrompt {
        name: prompt.name.clone(),
        description,
        examples,
        corpus_classes: prompt.corpus_classes.clone(),
        sources: prompt.sources.clone(),
        enabled: prompt.enabled,
        builtin: base.is_some(),
        customized: base.is_some_and(|b| !std::ptr::eq(b, prompt)),
        graph: prompt.graph.clone().or_else(|| base.and_then(|b| b.graph.clone())),
    })
}

/// Built-ins first (each overridden by a configured entry of its name), then the others in file
/// order (`effective_prompts`).
///
/// # Errors
///
/// A prompt with no description or examples once merged.
pub fn effective_prompts(configured: &[FactPrompt]) -> Result<Vec<EffectivePrompt>> {
    let builtins = builtin_prompts();
    let mut resolved = Vec::new();
    for builtin in &builtins {
        let own = configured.iter().find(|p| p.name == builtin.name);
        resolved.push(resolve(own.unwrap_or(builtin), Some(builtin))?);
    }
    for prompt in configured.iter().filter(|p| !BUILTIN_PROMPT_NAMES.contains(&p.name.as_str())) {
        resolved.push(resolve(prompt, None)?);
    }
    Ok(resolved)
}

/// The prompts a run uses: every enabled one, or exactly `names` (enabled or not)
/// (`select_prompts`). An unknown name is `LookupError`.
///
/// # Errors
///
/// `NOT_FOUND` naming the unknown prompts and the known ones.
pub fn select_prompts(prompts: &[EffectivePrompt], names: &[String]) -> Result<Vec<EffectivePrompt>> {
    if names.is_empty() {
        return Ok(prompts.iter().filter(|p| p.enabled).cloned().collect());
    }
    let unknown: Vec<&str> =
        names.iter().filter(|n| !prompts.iter().any(|p| &p.name == *n)).map(String::as_str).collect();
    if !unknown.is_empty() {
        let known: Vec<&str> = prompts.iter().map(|p| p.name.as_str()).collect();
        return Err(ServiceError::not_found(format!(
            "unknown fact prompt(s) {}; known: {}",
            unknown.join(", "),
            known.join(", ")
        )));
    }
    let mut chosen: Vec<EffectivePrompt> = Vec::new();
    for name in names {
        if chosen.iter().any(|p| &p.name == name) {
            continue;
        }
        if let Some(prompt) = prompts.iter().find(|p| &p.name == name) {
            chosen.push(prompt.clone());
        }
    }
    Ok(chosen)
}

fn example_value(example: &Example) -> Value {
    json!({
        "text": example.text,
        "extractions": example.extractions.iter().map(|e| json!({
            "class": e.class, "text": e.text, "attributes": Value::Object(e.attributes.clone()),
        })).collect::<Vec<_>>(),
    })
}

/// `value` with every object's keys sorted, as `json.dumps(sort_keys=True)` writes it.
pub fn sorted_keys(value: &Value) -> Value {
    match value {
        Value::Object(map) => {
            let sorted: BTreeMap<&String, &Value> = map.iter().collect();
            Value::Object(sorted.into_iter().map(|(k, v)| (k.clone(), sorted_keys(v))).collect())
        }
        Value::Array(items) => Value::Array(items.iter().map(sorted_keys).collect()),
        other => other.clone(),
    }
}

impl EffectivePrompt {
    /// The examples as JSON (`to_config()["examples"]`), in the file's shape.
    pub fn examples_value(&self) -> Value {
        Value::Array(self.examples.iter().map(example_value).collect())
    }

    /// Hash of what the model is shown (description and examples), stored beside each fact
    /// (`sha256`). Scope and `enabled` are left out: they decide which documents a prompt runs on,
    /// not what it extracts.
    pub fn sha256(&self) -> Vec<u8> {
        let payload = sorted_keys(&json!({"description": self.description, "examples": self.examples_value()}));
        garage_ingest::sha256::digest(pyjson::dumps(&payload, pyjson::COMPACT_UNICODE).as_bytes()).to_vec()
    }

    /// Whether this prompt runs on a document of `corpus_class` from `source_slug` (`applies_to`).
    pub fn applies_to(&self, corpus_class: Option<&str>, source_slug: Option<&str>) -> bool {
        if !self.corpus_classes.is_empty() && !corpus_class.is_some_and(|c| self.corpus_classes.iter().any(|x| x == c))
        {
            return false;
        }
        self.sources.is_empty() || source_slug.is_some_and(|s| self.sources.iter().any(|x| x == s))
    }
}

/// Every prompt's graph block merged: the configured vertex labels by class, and the edges
/// (`GraphSchema`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct GraphSchema {
    pub vertices: BTreeMap<String, VertexSpec>,
    pub edges: Vec<EdgeSpec>,
}

impl GraphSchema {
    /// The vertex label a class's distilled facts take: its configured one, else `Fact`.
    pub fn label_for(&self, fact_class: &str) -> String {
        self.vertices.get(fact_class).map_or_else(|| "Fact".to_owned(), |v| v.label.clone())
    }
}

/// Merge the prompts' graph blocks, enabled or not (`graph_schema`).
///
/// # Errors
///
/// A class given two labels, a label used for two classes, or a configured label that is one of
/// the projection's own.
pub fn graph_schema(prompts: &[EffectivePrompt]) -> Result<GraphSchema> {
    let mut schema = GraphSchema::default();
    let mut classes_of: BTreeMap<String, String> = BTreeMap::new();
    for prompt in prompts {
        let Some(graph) = &prompt.graph else { continue };
        for vertex in &graph.vertices {
            if BUILTIN_VERTEX_LABELS.iter().any(|l| l.eq_ignore_ascii_case(&vertex.label)) {
                return Err(invalid(format!(
                    "facts.prompts: {} uses the built-in vertex label {}",
                    str_repr(&prompt.name),
                    str_repr(&vertex.label)
                )));
            }
            if let Some(known) = schema.vertices.get(&vertex.class)
                && known.label != vertex.label
            {
                return Err(invalid(format!(
                    "facts.prompts: class {} is both {} and {}",
                    str_repr(&vertex.class),
                    str_repr(&known.label),
                    str_repr(&vertex.label)
                )));
            }
            let lowered = vertex.label.to_lowercase();
            if let Some(other) = classes_of.get(&lowered)
                && other != &vertex.class
            {
                return Err(invalid(format!(
                    "facts.prompts: vertex label {} is used for {} and {}",
                    str_repr(&vertex.label),
                    str_repr(other),
                    str_repr(&vertex.class)
                )));
            }
            schema.vertices.insert(vertex.class.clone(), vertex.clone());
            classes_of.insert(lowered, vertex.class.clone());
        }
        for edge in &graph.edges {
            for label in std::iter::once(&edge.label).chain(edge.labels.iter()) {
                if BUILTIN_EDGE_LABELS.contains(&label.as_str()) {
                    return Err(invalid(format!(
                        "facts.prompts: {} uses the built-in edge label {}",
                        str_repr(&prompt.name),
                        str_repr(label)
                    )));
                }
            }
            schema.edges.push(edge.clone());
        }
    }
    Ok(schema)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::hex_string;

    #[test]
    fn the_default_prompt_hashes_as_python_does() {
        let prompts = effective_prompts(&[]).unwrap();
        assert_eq!(prompts.len(), 1);
        let default = &prompts[0];
        assert!(default.builtin && !default.customized && default.enabled);
        // garage_rag.config.fact_prompts.effective_prompts([])[0].sha256.hex()
        assert_eq!(hex_string(&default.sha256()), "d39469abe21804eade92ad4cd1b95cb821d8b50951e2d6122bdbca98f9172b92");
        let style = pyjson::Style { compact: false, ensure_ascii: false };
        assert!(pyjson::dumps(&default.examples_value(), style).starts_with(
            "[{\"text\": \"Acme Corp was founded in 1998 by Jane Doe. The company is headquartered in Austin, \
             Texas, and has 42 employees.\", \"extractions\": [{\"class\": \"fact\", \"text\": \"Acme Corp was \
             founded in 1998 by Jane Doe.\", \"attributes\": {}}, "
        ));
    }

    #[test]
    fn a_configured_prompt_is_added_after_the_builtins_and_hashes_with_sorted_keys() {
        let configured = parse_prompts(&json!([{
            "name": "mine", "description": "Find people.",
            "examples": [{"text": "Ann met Bob.", "extractions": [
                {"class": "person", "text": "Ann", "attributes": {"role": "host", "tags": ["a", "b"]}}]}],
        }]))
        .unwrap();
        let prompts = effective_prompts(&configured).unwrap();
        assert_eq!(prompts.iter().map(|p| p.name.as_str()).collect::<Vec<_>>(), ["default", "mine"]);
        let mine = &prompts[1];
        assert!(!mine.builtin && !mine.customized);
        assert_eq!(hex_string(&mine.sha256()), "c6334c2a25a568ef90a9a8abe158c2ccfc2fd595c9ec1306986505cf0819ae3b");
        assert_eq!(
            pyjson::dumps(&mine.examples_value(), pyjson::Style { compact: false, ensure_ascii: false }),
            "[{\"text\": \"Ann met Bob.\", \"extractions\": [{\"class\": \"person\", \"text\": \"Ann\", \
             \"attributes\": {\"role\": \"host\", \"tags\": [\"a\", \"b\"]}}]}]"
        );
    }

    #[test]
    fn an_override_keeps_the_builtins_text_and_a_new_prompt_needs_its_own() {
        let configured = parse_prompts(&json!([{"name": "default", "enabled": false, "sources": ["notes"]}])).unwrap();
        let prompts = effective_prompts(&configured).unwrap();
        assert_eq!(prompts.len(), 1);
        assert!(prompts[0].builtin && prompts[0].customized && !prompts[0].enabled);
        assert_eq!(prompts[0].description, DEFAULT_DESCRIPTION);
        assert!(prompts[0].applies_to(Some("document"), Some("notes")));
        assert!(!prompts[0].applies_to(Some("document"), Some("mail")));

        let error = parse_prompts(&json!([{"name": "mine", "description": "d"}])).unwrap_err();
        assert_eq!(error.message(), "facts.prompts: 'mine' is not a built-in prompt, so it needs examples");
        let error = parse_prompts(&json!([{"name": "a", "description": "d", "examples": []}])).unwrap_err();
        assert_eq!(error.message(), "facts.prompts: 'a': examples must not be empty; LangExtract needs at least one");
        let error = parse_prompts(&json!([{"name": "default"}, {"name": "default"}])).unwrap_err();
        assert_eq!(error.message(), "facts.prompts: the name 'default' is used twice");
        let error = parse_prompts(&json!([{"name": "default", "colour": "red"}])).unwrap_err();
        assert_eq!(error.message(), "facts.prompts: 'default': unknown field 'colour'");
    }

    #[test]
    fn selecting_by_name_runs_a_disabled_prompt_and_refuses_an_unknown_one() {
        let configured = parse_prompts(&json!([{"name": "default", "enabled": false}])).unwrap();
        let prompts = effective_prompts(&configured).unwrap();
        assert!(select_prompts(&prompts, &[]).unwrap().is_empty());
        let named = select_prompts(&prompts, &["default".to_owned(), "default".to_owned()]).unwrap();
        assert_eq!(named.len(), 1);
        let error = select_prompts(&prompts, &["other".to_owned()]).unwrap_err();
        assert_eq!(error, ServiceError::not_found("unknown fact prompt(s) other; known: default"));
    }

    #[test]
    fn graph_blocks_merge_and_clashing_labels_are_refused() {
        let configured = parse_prompts(&json!([{
            "name": "people", "description": "People and employers.",
            "examples": [{"text": "Ann works at Acme.", "extractions": [{"class": "person", "text": "Ann"}]}],
            "graph": {
                "vertices": [{"class": "person", "label": "Person", "title": "name"}, {"class": "org", "label": "Org"}],
                "edges": [{"class": "employment", "source": "who", "source_class": "person", "target": "where",
                           "target_class": "org", "label": "WORKS_AT"}],
            },
        }]))
        .unwrap();
        let schema = graph_schema(&effective_prompts(&configured).unwrap()).unwrap();
        assert_eq!(schema.label_for("person"), "Person");
        assert_eq!(schema.label_for("thing"), "Fact");
        assert_eq!(schema.edges.len(), 1);
        assert_eq!(schema.edges[0].label, "WORKS_AT");

        let taken = parse_prompts(&json!([{
            "name": "p", "description": "d", "examples": [{"text": "t"}],
            "graph": {"vertices": [{"class": "x", "label": "Document"}]},
        }]))
        .unwrap_err();
        assert_eq!(taken.message(), "facts.prompts: 'p' uses the built-in vertex label 'Document'");
        let bad = parse_prompts(&json!([{
            "name": "p", "description": "d", "examples": [{"text": "t"}],
            "graph": {"edges": [{"class": "x", "source": "a", "source_class": "x", "target": "b", "target_class": "x",
                                 "label": "has_chunk"}]},
        }]))
        .unwrap_err();
        assert!(bad.message().contains("label 'has_chunk' does not match"), "{}", bad.message());
    }
}

//! A tool's arguments, checked against its input schema as the Python server's pydantic model
//! checks them: the same lax conversions (`"7"` is 7, `1` is `1.0`, `"yes"` is true), the same
//! constraints, and errors worded as pydantic words them, since that text is what a model reads
//! and corrects.
//!
//! The schemas are the ones in `tools.json`, which the Python server publishes. Only the shapes
//! those use are understood: a string, integer, number or boolean, a string enum, any of those or
//! null, and the filters' list-or-one-value union (a bare value is taken as a one-item list first,
//! as `_as_list` does).

use serde_json::{Map, Value};

use crate::pyrepr;

/// The pydantic version whose wording the errors follow, for the link each one ends with.
pub const PYDANTIC_DOCS: &str = "https://errors.pydantic.dev/2.14/v";

/// What one value must be.
#[derive(Clone, Debug, PartialEq)]
enum Kind {
    Str,
    Int {
        min: Option<Value>,
        max: Option<Value>,
    },
    Float {
        min: Option<Value>,
        max: Option<Value>,
    },
    Bool,
    Literal(Vec<String>),
    /// The kind, or null.
    Optional(Box<Kind>),
    /// A list of `item`, or one `scalar`, or null; a string is a one-item list first.
    ListOr {
        item: Box<Kind>,
        scalar: Box<Kind>,
    },
    /// Anything the schema shapes above do not cover: accepted as given.
    Any,
}

impl Kind {
    fn from_schema(schema: &Value) -> Self {
        if let Some(Value::Array(options)) = schema.get("anyOf") {
            let kept: Vec<&Value> = options.iter().filter(|o| o.get("type") != Some(&Value::from("null"))).collect();
            let nullable = kept.len() < options.len();
            if let [only] = kept.as_slice() {
                let inner = Self::from_schema(only);
                return if nullable { Self::Optional(Box::new(inner)) } else { inner };
            }
            if let [list, scalar] = kept.as_slice()
                && list.get("type") == Some(&Value::from("array"))
            {
                let item = list.get("items").map_or(Self::Any, Self::from_schema);
                return Self::ListOr { item: Box::new(item), scalar: Box::new(Self::from_schema(scalar)) };
            }
            return Self::Any;
        }
        if let Some(Value::Array(values)) = schema.get("enum") {
            return Self::Literal(values.iter().filter_map(|v| v.as_str().map(str::to_string)).collect());
        }
        match schema.get("type").and_then(Value::as_str) {
            Some("string") => Self::Str,
            Some("integer") => Self::Int { min: schema.get("minimum").cloned(), max: schema.get("maximum").cloned() },
            Some("number") => Self::Float { min: schema.get("minimum").cloned(), max: schema.get("maximum").cloned() },
            Some("boolean") => Self::Bool,
            _ => Self::Any,
        }
    }

    /// The type's name in a union's error location: `str`, `literal['a','b']`, `list[str]`.
    fn tag(&self) -> String {
        match self {
            Self::Str => "str".into(),
            Self::Int { .. } => "int".into(),
            Self::Float { .. } => "float".into(),
            Self::Bool => "bool".into(),
            Self::Literal(values) => {
                format!("literal[{}]", values.iter().map(|v| pyrepr::str_repr(v)).collect::<Vec<_>>().join(","))
            }
            Self::Optional(inner) => format!("nullable[{}]", inner.tag()),
            Self::ListOr { item, .. } => format!("list[{}]", item.tag()),
            Self::Any => "any".into(),
        }
    }
}

/// One failed check.
#[derive(Clone, Debug, PartialEq)]
pub struct ErrorItem {
    /// Where: the field, then any union branch and list index.
    pub loc: Vec<String>,
    pub kind: &'static str,
    pub message: String,
    pub input: Value,
}

/// A tool's arguments were not what its schema allows. `Display` is pydantic's text.
#[derive(Clone, Debug, PartialEq)]
pub struct ValidationError {
    pub title: String,
    pub errors: Vec<ErrorItem>,
}

impl std::fmt::Display for ValidationError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let n = self.errors.len();
        write!(f, "{n} validation error{} for {}", if n == 1 { "" } else { "s" }, self.title)?;
        for error in &self.errors {
            write!(
                f,
                "\n{}\n  {} [type={}, input_value={}, input_type={}]\n    For further information visit {PYDANTIC_DOCS}/{}",
                error.loc.join("."),
                error.message,
                error.kind,
                pyrepr::truncated(&error.input),
                pyrepr::type_name(&error.input),
                error.kind,
            )?;
        }
        Ok(())
    }
}

impl std::error::Error for ValidationError {}

/// One argument of a tool.
#[derive(Clone, Debug)]
struct Field {
    name: String,
    kind: Kind,
    required: bool,
    default: Value,
}

/// How to check one tool's arguments.
#[derive(Clone, Debug)]
pub struct Arguments {
    title: String,
    fields: Vec<Field>,
}

impl Arguments {
    /// From a tool's `inputSchema`.
    pub fn from_schema(schema: &Value) -> Self {
        let title = schema.get("title").and_then(Value::as_str).unwrap_or("Arguments").to_string();
        let required: Vec<&str> = schema
            .get("required")
            .and_then(Value::as_array)
            .map(|names| names.iter().filter_map(Value::as_str).collect())
            .unwrap_or_default();
        let fields = schema
            .get("properties")
            .and_then(Value::as_object)
            .map(|properties| {
                properties
                    .iter()
                    .map(|(name, spec)| Field {
                        name: name.clone(),
                        kind: Kind::from_schema(spec),
                        required: required.contains(&name.as_str()),
                        default: spec.get("default").cloned().unwrap_or(Value::Null),
                    })
                    .collect()
            })
            .unwrap_or_default();
        Self { title, fields }
    }

    /// The arguments with defaults filled in and values converted, keyed in schema order; keys
    /// the schema does not name are dropped, as pydantic drops them.
    ///
    /// # Errors
    ///
    /// [`ValidationError`] listing every failed check, in field order.
    pub fn validate(&self, given: &Map<String, Value>) -> Result<Map<String, Value>, ValidationError> {
        let parsed = self.pre_parse(given);
        let mut out = Map::new();
        let mut errors = Vec::new();
        for field in &self.fields {
            match parsed.get(&field.name) {
                None if field.required => errors.push(ErrorItem {
                    loc: vec![field.name.clone()],
                    kind: "missing",
                    message: "Field required".into(),
                    input: Value::Object(parsed.clone()),
                }),
                None => {
                    out.insert(field.name.clone(), field.default.clone());
                }
                Some(value) => match check(&field.kind, value) {
                    Ok(value) => {
                        out.insert(field.name.clone(), value);
                    }
                    Err(mut found) => {
                        for error in &mut found {
                            error.loc.insert(0, field.name.clone());
                        }
                        errors.extend(found);
                    }
                },
            }
        }
        if errors.is_empty() { Ok(out) } else { Err(ValidationError { title: self.title.clone(), errors }) }
    }

    /// The MCP SDK's `pre_parse_json`: a string given for an argument that is not a plain string is
    /// read as JSON when that makes a list, an object, null or a boolean (clients send `"[\"a\"]"`).
    fn pre_parse(&self, given: &Map<String, Value>) -> Map<String, Value> {
        let mut out = given.clone();
        for field in &self.fields {
            if field.kind == Kind::Str {
                continue;
            }
            if let Some(Value::String(text)) = given.get(&field.name)
                && let Ok(parsed) = serde_json::from_str::<Value>(text)
                && !matches!(parsed, Value::String(_) | Value::Number(_) | Value::Bool(_))
            {
                out.insert(field.name.clone(), parsed);
            }
        }
        out
    }
}

fn error(kind: &'static str, message: impl Into<String>, input: &Value) -> Vec<ErrorItem> {
    vec![ErrorItem { loc: Vec::new(), kind, message: message.into(), input: input.clone() }]
}

/// A bound as pydantic prints it in a message: `2.0` is `2`.
fn bound(value: &Value) -> String {
    match value.as_f64() {
        Some(x) if x.fract() == 0.0 && x.abs() < 1e15 => {
            #[allow(clippy::cast_possible_truncation)]
            let int = x as i64;
            int.to_string()
        }
        Some(x) => pyrepr::float_repr(x),
        None => value.to_string(),
    }
}

fn check_range(value: f64, min: Option<&Value>, max: Option<&Value>, input: &Value) -> Result<(), Vec<ErrorItem>> {
    if let Some(min) = min
        && let Some(low) = min.as_f64()
        && value < low
    {
        return Err(error(
            "greater_than_equal",
            format!("Input should be greater than or equal to {}", bound(min)),
            input,
        ));
    }
    if let Some(max) = max
        && let Some(high) = max.as_f64()
        && value > high
    {
        return Err(error("less_than_equal", format!("Input should be less than or equal to {}", bound(max)), input));
    }
    Ok(())
}

fn literal_message(values: &[String]) -> String {
    let quoted: Vec<String> = values.iter().map(|v| pyrepr::str_repr(v)).collect();
    match quoted.as_slice() {
        [] => "Input should be one of nothing".into(),
        [one] => format!("Input should be {one}"),
        [rest @ .., last] => format!("Input should be {} or {last}", rest.join(", ")),
    }
}

#[allow(clippy::too_many_lines)]
fn check(kind: &Kind, value: &Value) -> Result<Value, Vec<ErrorItem>> {
    match kind {
        Kind::Any => Ok(value.clone()),
        Kind::Str => match value {
            Value::String(_) => Ok(value.clone()),
            _ => Err(error("string_type", "Input should be a valid string", value)),
        },
        Kind::Int { min, max } => {
            let int = match value {
                Value::Bool(flag) => i64::from(*flag),
                Value::Number(number) => match number.as_i64() {
                    Some(int) => int,
                    None => match number.as_f64() {
                        #[allow(clippy::cast_possible_truncation)]
                        Some(x) if x.fract() == 0.0 && x.is_finite() => x as i64,
                        _ => {
                            return Err(error(
                                "int_from_float",
                                "Input should be a valid integer, got a number with a fractional part",
                                value,
                            ));
                        }
                    },
                },
                Value::String(text) => match parse_int(text) {
                    Some(int) => int,
                    None => {
                        return Err(error(
                            "int_parsing",
                            "Input should be a valid integer, unable to parse string as an integer",
                            value,
                        ));
                    }
                },
                _ => return Err(error("int_type", "Input should be a valid integer", value)),
            };
            #[allow(clippy::cast_precision_loss)]
            check_range(int as f64, min.as_ref(), max.as_ref(), value)?;
            Ok(Value::from(int))
        }
        Kind::Float { min, max } => {
            let float = match value {
                Value::Bool(flag) => f64::from(u8::from(*flag)),
                Value::Number(number) => number.as_f64().unwrap_or(0.0),
                Value::String(text) => match text.trim().parse::<f64>() {
                    Ok(x) => x,
                    Err(_) => {
                        return Err(error(
                            "float_parsing",
                            "Input should be a valid number, unable to parse string as a number",
                            value,
                        ));
                    }
                },
                _ => return Err(error("float_type", "Input should be a valid number", value)),
            };
            check_range(float, min.as_ref(), max.as_ref(), value)?;
            Ok(serde_json::Number::from_f64(float).map_or(Value::Null, Value::Number))
        }
        Kind::Bool => match value {
            Value::Bool(_) => Ok(value.clone()),
            Value::Number(number) => match number.as_f64() {
                Some(0.0) => Ok(Value::Bool(false)),
                Some(x) if (x - 1.0).abs() < f64::EPSILON => Ok(Value::Bool(true)),
                _ => Err(error("bool_parsing", "Input should be a valid boolean, unable to interpret input", value)),
            },
            Value::String(text) => match text.to_ascii_lowercase().as_str() {
                "0" | "off" | "f" | "false" | "n" | "no" => Ok(Value::Bool(false)),
                "1" | "on" | "t" | "true" | "y" | "yes" => Ok(Value::Bool(true)),
                _ => Err(error("bool_parsing", "Input should be a valid boolean, unable to interpret input", value)),
            },
            _ => Err(error("bool_type", "Input should be a valid boolean", value)),
        },
        Kind::Literal(values) => match value {
            Value::String(text) if values.iter().any(|v| v == text) => Ok(value.clone()),
            _ => Err(error("literal_error", literal_message(values), value)),
        },
        Kind::Optional(inner) => match value {
            Value::Null => Ok(Value::Null),
            _ => check(inner, value),
        },
        Kind::ListOr { item, scalar } => {
            // `_as_list`, the BeforeValidator: one string is a one-item list.
            let value = match value {
                Value::String(_) => Value::Array(vec![value.clone()]),
                other => other.clone(),
            };
            if value.is_null() {
                return Ok(Value::Null);
            }
            let list_tag = kind.tag();
            let mut errors = Vec::new();
            match &value {
                Value::Array(items) => {
                    let mut out = Vec::with_capacity(items.len());
                    for (index, element) in items.iter().enumerate() {
                        match check(item, element) {
                            Ok(element) => out.push(element),
                            Err(found) => {
                                for mut e in found {
                                    e.loc.insert(0, index.to_string());
                                    e.loc.insert(0, list_tag.clone());
                                    errors.push(e);
                                }
                            }
                        }
                    }
                    if errors.is_empty() {
                        return Ok(Value::Array(out));
                    }
                }
                _ => errors.push(ErrorItem {
                    loc: vec![list_tag],
                    kind: "list_type",
                    message: "Input should be a valid list".into(),
                    input: value.clone(),
                }),
            }
            match check(scalar, &value) {
                Ok(one) => Ok(one),
                Err(found) => {
                    for mut e in found {
                        e.loc.insert(0, scalar.tag());
                        errors.push(e);
                    }
                    Err(errors)
                }
            }
        }
    }
}

/// pydantic's string-to-integer: surrounding whitespace allowed, and a whole number written with
/// a fractional part (`"12.0"`).
fn parse_int(text: &str) -> Option<i64> {
    let text = text.trim();
    if let Ok(int) = text.parse::<i64>() {
        return Some(int);
    }
    let (whole, fraction) = text.split_once('.')?;
    if !fraction.is_empty() && fraction.chars().all(|c| c == '0') {
        return whole.parse().ok();
    }
    None
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::tools::tool_schema;

    fn validate(tool: &str, args: Value) -> Result<Map<String, Value>, String> {
        let schema = tool_schema(tool).unwrap();
        let Value::Object(args) = args else { panic!() };
        Arguments::from_schema(&schema["inputSchema"]).validate(&args).map_err(|e| e.to_string())
    }

    #[test]
    fn defaults_fill_in_and_lax_values_convert() {
        let out =
            validate("rag_search", json!({"query": "x", "limit": "7", "corpus_class": "code", "extra": 1})).unwrap();
        assert_eq!(
            Value::Object(out),
            json!({"query": "x", "limit": 7, "mode": "hybrid", "corpus_class": ["code"], "trust": null,
                   "source": null, "author": null, "direction": null})
        );
        let out = validate("rag_agent", json!({"question": "q", "search_first": "yes", "temperature": 1})).unwrap();
        assert_eq!(out["search_first"], json!(true));
        assert_eq!(out["temperature"], json!(1.0));
        assert_eq!(validate("rag_search", json!({"query": "x", "limit": "12.0"})).unwrap()["limit"], json!(12));
        assert_eq!(
            validate("rag_search", json!({"query": "x", "corpus_class": "[\"code\"]"})).unwrap()["corpus_class"],
            json!(["code"])
        );
    }

    #[test]
    fn errors_read_as_pydantic_writes_them() {
        assert_eq!(
            validate("rag_search", json!({"query": "x", "limit": 99})).unwrap_err(),
            "1 validation error for rag_searchArguments\nlimit\n  Input should be less than or equal to 50 \
             [type=less_than_equal, input_value=99, input_type=int]\n    For further information visit \
             https://errors.pydantic.dev/2.14/v/less_than_equal"
        );
        let text = validate("rag_search", json!({"query": "x", "corpus_class": ["code", "bad"]})).unwrap_err();
        assert!(text.starts_with("2 validation errors for rag_searchArguments\ncorpus_class.list[literal['document','code','communication']].1\n  Input should be 'document', 'code' or 'communication' [type=literal_error, input_value='bad', input_type=str]"), "{text}");
        assert!(text.contains("\ncorpus_class.literal['document','code','communication']\n  Input should be 'document', 'code' or 'communication' [type=literal_error, input_value=['code', 'bad'], input_type=list]"), "{text}");
        let text = validate("rag_ask", json!({"question": "q", "temperature": 3})).unwrap_err();
        assert!(
            text.contains(
                "Input should be less than or equal to 2 [type=less_than_equal, input_value=3, input_type=int]"
            ),
            "{text}"
        );
        let text = validate("rag_search", json!({})).unwrap_err();
        assert!(text.contains("query\n  Field required [type=missing, input_value={}, input_type=dict]"), "{text}");
    }
}

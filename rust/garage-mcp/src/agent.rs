//! rag_agent: the local model answers a question with the read-only corpus tools in hand
//! (`garage_rag.mcp_server.agent`, step for step).
//!
//! Tool calls travel as JSON in the conversation, not as the OpenAI `tools` field: the model
//! replies with one object, `{"tool": "rag_search", "arguments": {...}}`, gets the result back as
//! the next user turn, and a reply that is not a tool call is the answer. By default the question
//! is searched before the model says anything, so a small model starts from the user's documents.
//!
//! The content rule holds here too: when the model host is not loopback, rag_search is restricted
//! to documents and code and a communication in any result is withheld from the model.

use std::fmt::Write as _;
use std::sync::LazyLock;

use regex::Regex;
use serde_json::{Map, Value, json};

use crate::chat::{Chat, ChatError, ChatReply};
use crate::pyjson;
use crate::pyrepr;
use crate::tools::{TOOLS, is_py_space, trim};

/// The tools the model may call: the ones that only read.
pub const AGENT_TOOL_NAMES: [&str; 5] =
    ["rag_search", "rag_get_document", "rag_list_sources", "rag_list_authors", "rag_stats"];
/// A tool result is cut to this many characters before it goes back to the model.
pub const TOOL_RESULT_CHARS: usize = 6000;
/// Each rag_search hit's text is trimmed to this many characters in a tool result.
pub const HIT_TEXT_CHARS: usize = 700;
/// Citations carry a shorter snippet, as rag_ask's do.
pub const SNIPPET_CHARS: usize = 240;
pub const DEFAULT_MAX_STEPS: usize = 6;
/// Hits the opening search asks for.
pub const FIRST_SEARCH_LIMIT: i64 = 6;
/// What rag_search may return when the model host is off this machine.
const LOCAL_ONLY_CLASSES: [&str; 2] = ["document", "code"];

const SYSTEM_PROMPT: &str = include_str!("agent_prompt.txt");

pub const NO_ANSWER_TEXT: &str = "The model kept asking for tools instead of answering. Try a more specific question.";
pub const FIRST_SEARCH_NO_HITS_NOTE: &str = "Note: this search found nothing. Search once more with different \
keywords (a name, a company, a subject); if that finds nothing either, say that you found nothing about it in the \
user's files.";
pub const FIRST_SEARCH_VECTOR_ONLY_NOTE: &str = "Note: none of these hits contains the question's words. They are \
only the documents nearest in meaning and may be about something else entirely. Use a hit only if its text answers \
the question. Otherwise search once more with different keywords (a name, a company, a subject), and if that finds \
nothing either, say that you found nothing about it in the user's files. Never read an answer into an unrelated \
document.";
pub const FINAL_ANSWER_PROMPT: &str = "No more tool calls are available. Answer the question now in plain prose \
from what the tool results so far contain, and say plainly if they do not contain the answer.";

/// A tool as the model sees it.
#[derive(Clone, Debug, PartialEq)]
pub struct AgentTool {
    pub name: String,
    /// The description with its whitespace collapsed.
    pub description: String,
    /// The input schema without titles and null branches (`_schema_for_prompt`).
    pub parameters: Value,
}

/// The agent's tools, from the published definitions.
pub fn agent_tools() -> Vec<AgentTool> {
    AGENT_TOOL_NAMES
        .iter()
        .filter_map(|name| {
            let tool = TOOLS.iter().find(|tool| tool["name"].as_str() == Some(name))?;
            let description = tool["description"].as_str().unwrap_or_default();
            Some(AgentTool {
                name: (*name).to_string(),
                description: description.split(is_py_space).filter(|w| !w.is_empty()).collect::<Vec<_>>().join(" "),
                parameters: schema_for_prompt(&tool["inputSchema"]),
            })
        })
        .collect()
}

/// `_schema_for_prompt`.
pub fn schema_for_prompt(schema: &Value) -> Value {
    let mut properties = Map::new();
    if let Some(Value::Object(given)) = schema.get("properties") {
        for (name, spec) in given {
            properties.insert(name.clone(), simplify_property(spec));
        }
    }
    let mut out = Map::new();
    out.insert("type".into(), json!("object"));
    out.insert("properties".into(), Value::Object(properties));
    if let Some(Value::Array(required)) = schema.get("required")
        && !required.is_empty()
    {
        out.insert("required".into(), Value::Array(required.clone()));
    }
    Value::Object(out)
}

/// `_simplify_property`.
fn simplify_property(spec: &Value) -> Value {
    let Some(spec) = spec.as_object() else { return spec.clone() };
    let mut out = Map::new();
    if let Some(Value::Array(options)) = spec.get("anyOf") {
        let kept: Vec<&Value> = options.iter().filter(|o| o.get("type") != Some(&json!("null"))).collect();
        if let [only] = kept.as_slice() {
            let mut merged = only.as_object().cloned().unwrap_or_default();
            for (key, value) in spec {
                if key != "anyOf" && key != "title" {
                    merged.insert(key.clone(), value.clone());
                }
            }
            return simplify_property(&Value::Object(merged));
        }
        out.insert("anyOf".into(), Value::Array(kept.into_iter().map(simplify_property).collect()));
    }
    for key in ["type", "description", "enum", "default", "minimum", "maximum", "items"] {
        if let Some(value) = spec.get(key) {
            if key == "default" && value.is_null() {
                continue;
            }
            let value = if key == "items" && value.is_object() { simplify_property(value) } else { value.clone() };
            out.insert(key.into(), value);
        }
    }
    Value::Object(out)
}

/// Arguments the model is not shown; still accepted when it passes one.
fn hidden(tool: &str) -> &'static [&'static str] {
    match tool {
        "rag_search" => &["mode"],
        "rag_get_document" => &["max_chars"],
        _ => &[],
    }
}

/// The tool section of the system prompt: one line per tool.
pub fn describe_tools(tools: &[AgentTool]) -> String {
    tools
        .iter()
        .map(|tool| format!("- {}({}): {}", tool.name, signature(tool), first_sentence(&tool.description)))
        .collect::<Vec<_>>()
        .join("\n")
}

fn signature(tool: &AgentTool) -> String {
    let hidden = hidden(&tool.name);
    let required: Vec<&str> = tool
        .parameters
        .get("required")
        .and_then(Value::as_array)
        .map_or_else(Vec::new, |r| r.iter().filter_map(Value::as_str).collect());
    let mut parts = Vec::new();
    if let Some(Value::Object(properties)) = tool.parameters.get("properties") {
        for (name, spec) in properties {
            if hidden.contains(&name.as_str()) {
                continue;
            }
            let mut part = format!("{name}{}", if required.contains(&name.as_str()) { "" } else { "?" });
            let values = enum_values(spec);
            if !values.is_empty() {
                let quoted: Vec<String> = values.iter().map(|v| format!("\"{}\"", py_str(v))).collect();
                let _ = write!(part, ": {}", quoted.join(" | "));
            }
            parts.push(part);
        }
    }
    parts.join(", ")
}

fn enum_values(spec: &Value) -> Vec<Value> {
    if let Some(Value::Array(values)) = spec.get("enum") {
        return values.clone();
    }
    if let Some(Value::Array(options)) = spec.get("anyOf") {
        for option in options {
            let inner = match option.get("items") {
                Some(items) if !is_falsy(items) => items,
                _ => option,
            };
            let values = enum_values(inner);
            if !values.is_empty() {
                return values;
            }
        }
    }
    Vec::new()
}

/// Python's truthiness of a JSON value.
fn is_falsy(value: &Value) -> bool {
    match value {
        Value::Null => true,
        Value::Bool(flag) => !flag,
        Value::Number(number) => number.as_f64() == Some(0.0),
        Value::String(text) => text.is_empty(),
        Value::Array(items) => items.is_empty(),
        Value::Object(map) => map.is_empty(),
    }
}

/// `str(value)`: a string as it is, anything else as its repr.
fn py_str(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        other => pyrepr::repr(other),
    }
}

static FIRST_SENTENCE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^(.+?[.!?])(\s|$)").expect("valid"));
static FENCE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?s)```(?:json)?\s*(.*?)```").expect("valid"));

fn first_sentence(text: &str) -> String {
    FIRST_SENTENCE.captures(text).and_then(|c| c.get(1)).map_or_else(|| text.to_string(), |m| m.as_str().to_string())
}

/// The opening messages: the system prompt with the tools, then the question.
pub fn build_agent_messages(question: &str, tools: &[AgentTool], owner: &str) -> Vec<Value> {
    let owner_line = if owner.trim().is_empty() {
        String::new()
    } else {
        format!("The user is {owner}; \"authored\" documents and the author {owner} are theirs.\n")
    };
    let system = SYSTEM_PROMPT.replacen("{owner}", &owner_line, 1).replacen("{tools}", &describe_tools(tools), 1);
    vec![
        json!({"role": "system", "content": system}),
        json!({"role": "user", "content": format!("Question: {question}")}),
    ]
}

/// The tool call in a reply, or `None` when the reply is an answer. Takes the bare object, one in a
/// code fence, or one with a little prose around it.
pub fn parse_tool_call(text: &str) -> Option<(String, Map<String, Value>)> {
    let mut candidates = vec![text.trim().to_string()];
    candidates.extend(FENCE.captures_iter(text).filter_map(|c| c.get(1)).map(|m| m.as_str().trim().to_string()));
    if let (Some(start), Some(end)) = (text.find('{'), text.rfind('}'))
        && end > start
    {
        candidates.push(text[start..=end].to_string());
    }
    for candidate in candidates {
        if !candidate.starts_with('{') {
            continue;
        }
        let Ok(Value::Object(object)) = serde_json::from_str::<Value>(&candidate) else { continue };
        let name = match object.get("tool") {
            Some(tool) if !is_falsy(tool) => Some(tool),
            _ => object.get("name"),
        };
        let Some(Value::String(name)) = name else { continue };
        if name.is_empty() {
            continue;
        }
        let arguments = object
            .get("arguments")
            .or_else(|| object.get("parameters"))
            .or_else(|| object.get("input"))
            .cloned()
            .unwrap_or_else(|| json!({}));
        let arguments = match arguments {
            Value::Null => Map::new(),
            Value::Object(map) => map,
            _ => continue,
        };
        return Some((name.clone(), arguments));
    }
    None
}

/// The result as compact JSON, long texts shortened so it fits the context.
pub fn render_tool_result(tool: &str, result: &Value) -> String {
    let mut data = result.clone();
    if tool == "rag_search"
        && let Some(Value::Array(hits)) = data.get_mut("hits")
    {
        for hit in hits.iter_mut().filter_map(Value::as_object_mut) {
            if let Some(Value::String(text)) = hit.get("text") {
                let short = trim(text, HIT_TEXT_CHARS);
                hit.insert("text".into(), Value::String(short));
            }
            for key in ["chunk_id", "matched_by", "score"] {
                hit.shift_remove(key);
            }
            // Direction and sender only mean something on a message hit.
            for key in ["direction", "sender"] {
                if hit.get(key).is_some_and(Value::is_null) {
                    hit.shift_remove(key);
                }
            }
        }
    }
    let text = pyjson::dumps(&data, pyjson::COMPACT_UNICODE);
    if text.chars().count() > TOOL_RESULT_CHARS {
        let head: String = text.chars().take(TOOL_RESULT_CHARS - 1).collect();
        return format!("{head}…");
    }
    text
}

/// The caution added to the opening search's result, or `None` when a keyword matched.
pub fn first_search_note(result: &Value) -> Option<&'static str> {
    let hits = result.get("hits").and_then(Value::as_array).filter(|hits| !hits.is_empty());
    let Some(hits) = hits else { return Some(FIRST_SEARCH_NO_HITS_NOTE) };
    if hits.iter().all(|hit| hit.get("matched_by").and_then(Value::as_str) == Some("vector")) {
        return Some(FIRST_SEARCH_VECTOR_ONLY_NOTE);
    }
    None
}

fn count_text(result: &Value) -> String {
    result.get("count").map_or_else(|| "?".into(), py_str)
}

/// One line for the caller's step list.
pub fn summarize_step(tool: &str, arguments: &Map<String, Value>, result: &Value) -> String {
    match tool {
        "rag_search" => {
            let query = arguments.get("query").map_or_else(String::new, py_str);
            let count = match result.get("count") {
                Some(Value::Null) | None => "?".to_string(),
                Some(count) => py_str(count),
            };
            format!("Searched for \u{201c}{query}\u{201d}: {count} hits")
        }
        "rag_get_document" => {
            let title = result.get("title").filter(|t| !is_falsy(t));
            let location = arguments.get("location").filter(|l| !is_falsy(l));
            let place = match (title, location) {
                (Some(title), _) => py_str(title),
                (None, Some(location)) => py_str(location),
                _ => format!("document {}", arguments.get("document_id").map_or_else(|| "None".into(), py_str)),
            };
            format!("Read {place}")
        }
        "rag_list_sources" => format!("Listed {} sources", count_text(result)),
        "rag_list_authors" => format!("Listed {} authors", count_text(result)),
        "rag_stats" => "Read the corpus statistics".into(),
        other => format!("Called {other}"),
    }
}

fn collect_citations(tool: &str, result: &Value, citations: &mut Vec<Value>, seen: &mut Vec<i64>) {
    let rows: Vec<Map<String, Value>> = match tool {
        "rag_search" => result
            .get("hits")
            .and_then(Value::as_array)
            .map(|hits| hits.iter().filter_map(Value::as_object).cloned().collect())
            .unwrap_or_default(),
        "rag_get_document" => match result.as_object() {
            Some(document) => {
                let mut row = document.clone();
                row.insert("text".into(), document.get("content").cloned().unwrap_or(json!("")));
                vec![row]
            }
            None => Vec::new(),
        },
        _ => return,
    };
    for row in rows {
        let Some(document_id) = row.get("document_id").filter(|id| id.is_i64() || id.is_u64()).and_then(Value::as_i64)
        else {
            continue;
        };
        if seen.contains(&document_id) {
            continue;
        }
        seen.push(document_id);
        let text = row.get("text").filter(|t| !is_falsy(t)).map_or_else(String::new, py_str);
        citations.push(json!({
            "n": citations.len() + 1,
            "document_id": document_id,
            "title": row.get("title").cloned().unwrap_or(Value::Null),
            "location": row.get("location").map_or_else(String::new, py_str),
            "snippet": trim(&text, SNIPPET_CHARS),
            "corpus_class": row.get("corpus_class").map_or_else(String::new, py_str),
        }));
    }
}

/// The arguments to run with: a search from an off-box model host never asks for communications.
pub fn restrict_for_host(
    tool: &str,
    arguments: &Map<String, Value>,
    communications_allowed: bool,
) -> Map<String, Value> {
    if communications_allowed || tool != "rag_search" {
        return arguments.clone();
    }
    let requested = match arguments.get("corpus_class") {
        Some(Value::String(one)) => Some(vec![Value::String(one.clone())]),
        Some(Value::Array(many)) => Some(many.clone()),
        _ => None,
    };
    let local: Vec<Value> = LOCAL_ONLY_CLASSES.iter().map(|c| json!(c)).collect();
    let classes = match requested {
        Some(requested) => {
            let kept: Vec<Value> = requested.into_iter().filter(|c| local.contains(c)).collect();
            if kept.is_empty() { local } else { kept }
        }
        None => local,
    };
    let mut out = arguments.clone();
    out.insert("corpus_class".into(), Value::Array(classes));
    out
}

/// Whether a result may go to the model host: a communication only to a loopback one.
pub fn result_allowed_for_host(tool: &str, result: &Value, communications_allowed: bool) -> bool {
    if communications_allowed {
        return true;
    }
    let communication = |row: &Value| row.get("corpus_class").and_then(Value::as_str) == Some("communication");
    match tool {
        "rag_get_document" if result.is_object() => !communication(result),
        "rag_search" if result.is_object() => {
            result.get("hits").and_then(Value::as_array).is_none_or(|hits| !hits.iter().any(communication))
        }
        _ => true,
    }
}

/// How rag_agent was asked to run.
#[derive(Clone, Debug, PartialEq)]
pub struct Options {
    pub max_steps: usize,
    pub max_tokens: Option<i64>,
    pub temperature: Option<f64>,
    pub search_first: bool,
    /// `identity.name`.
    pub owner: String,
}

/// Runs one read tool for the agent: its result, or the text of its error.
pub type RunTool<'a> = dyn Fn(&str, &Map<String, Value>) -> Result<Value, String> + 'a;

/// Asks `model` the question with `tools` to call; the `AgentResult`.
///
/// # Errors
///
/// [`ChatError`] when the model cannot answer at all.
#[allow(clippy::too_many_lines)]
pub fn run_agent(
    question: &str,
    tools: &[AgentTool],
    model: &dyn Chat,
    run: &RunTool<'_>,
    options: &Options,
) -> Result<Value, ChatError> {
    let communications_allowed = garage_embed::egress::allows_communications(model.host_url());
    let names: Vec<&str> = tools.iter().map(|tool| tool.name.as_str()).collect();
    let mut messages = build_agent_messages(question, tools, &options.owner);
    let mut steps: Vec<Value> = Vec::new();
    let mut citations: Vec<Value> = Vec::new();
    let mut seen: Vec<i64> = Vec::new();
    let (mut prompt_tokens, mut completion_tokens, mut counted) = (0i64, 0i64, false);

    let mut ask = |messages: &[Value]| -> Result<ChatReply, ChatError> {
        let reply = model.complete(messages, options.max_tokens, options.temperature)?;
        if reply.prompt_tokens.is_some() || reply.completion_tokens.is_some() {
            counted = true;
            prompt_tokens += reply.prompt_tokens.unwrap_or(0);
            completion_tokens += reply.completion_tokens.unwrap_or(0);
        }
        Ok(reply)
    };

    let mut call_tool = |messages: &mut Vec<Value>, name: &str, arguments: &Map<String, Value>| -> Option<Value> {
        let call = json!({"tool": name, "arguments": arguments});
        messages.push(json!({"role": "assistant", "content": pyjson::dumps(&call, pyjson::DEFAULT)}));
        let step = |summary: String, ok: bool, steps: &Vec<Value>| json!({"n": steps.len() + 1, "tool": name, "arguments": arguments, "summary": summary, "ok": ok});
        if !names.contains(&name) {
            steps.push(step(format!("No such tool: {name}"), false, &steps));
            messages.push(json!({"role": "user", "content": format!(
                "Error: there is no tool named {}. The tools are: {}.", pyrepr::str_repr(name), names.join(", ")
            )}));
            return None;
        }
        let mut to_run = restrict_for_host(name, arguments, communications_allowed);
        if name == "rag_get_document" && !to_run.contains_key("max_chars") {
            // Ask for no more text than fits in the result, so its `truncated` flag tells the truth.
            to_run.insert("max_chars".into(), json!(TOOL_RESULT_CHARS));
        }
        let result = match run(name, &to_run) {
            Ok(result) => result,
            Err(error) => {
                steps.push(step(format!("{name} failed: {error}"), false, &steps));
                messages.push(json!({"role": "user", "content": format!("Error from {name}: {}", trim(&error, 600))}));
                return None;
            }
        };
        if !result_allowed_for_host(name, &result, communications_allowed) {
            steps.push(step(format!("{name}: a communication stays on this machine"), false, &steps));
            messages.push(json!({"role": "user", "content": format!(
                "Error from {name}: that is a communication, which is only available to a model on this machine."
            )}));
            return None;
        }
        steps.push(step(summarize_step(name, arguments, &result), true, &steps));
        collect_citations(name, &result, &mut citations, &mut seen);
        messages.push(
            json!({"role": "user", "content": format!("Result of {name}:\n{}", render_tool_result(name, &result))}),
        );
        Some(result)
    };

    // The opening search is the harness's, not the model's, so it does not count against max_steps.
    if options.search_first && names.contains(&"rag_search") {
        let mut arguments = Map::new();
        arguments.insert("query".into(), json!(question));
        arguments.insert("limit".into(), json!(FIRST_SEARCH_LIMIT));
        if let Some(result) = call_tool(&mut messages, "rag_search", &arguments)
            && let Some(note) = first_search_note(&result)
            && let Some(last) = messages.last_mut()
        {
            let content = last["content"].as_str().unwrap_or_default().to_string();
            last["content"] = json!(format!("{content}\n{note}"));
        }
    }

    let mut answer: Option<String> = None;
    for _ in 0..options.max_steps {
        let reply = ask(&messages)?;
        match parse_tool_call(&reply.text) {
            None => {
                answer = Some(reply.text);
                break;
            }
            Some((name, arguments)) => {
                call_tool(&mut messages, &name, &arguments);
            }
        }
    }
    let answer = if let Some(answer) = answer {
        answer
    } else {
        messages.push(json!({"role": "user", "content": FINAL_ANSWER_PROMPT}));
        let reply = ask(&messages)?;
        if parse_tool_call(&reply.text).is_some() { NO_ANSWER_TEXT.to_string() } else { reply.text }
    };
    Ok(json!({
        "answer": answer.trim_matches(is_py_space),
        "model": model.model_ref(),
        "provider": model.provider(),
        "question": question,
        "steps": steps,
        "citations": citations,
        "prompt_tokens": if counted { Some(prompt_tokens) } else { None },
        "completion_tokens": if counted { Some(completion_tokens) } else { None },
    }))
}

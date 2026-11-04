//! The tools: their published definitions (`tools.json`, which the Python server publishes and a
//! parity test holds this copy to), their argument checks, and what each one does.
//!
//! The five read tools are GarageService's `Corpus*` calls. rag_ask retrieves through rag_search's
//! call and asks the local model; rag_generate asks it with no retrieval; rag_agent lets it call the
//! read tools itself ([`crate::agent`]).

use std::collections::HashMap;
use std::fmt::Write as _;
use std::sync::{Arc, LazyLock};

use serde_json::{Map, Value, json};

use crate::agent;
use crate::args::{Arguments, ValidationError};
use crate::chat::{Chat, ChatError, ChatSettings, check_content};
use crate::corpus::{Caller, Corpus, CorpusError, DocumentQuery, SearchQuery};

/// The tools' definitions as `tools/list` returns them.
pub static TOOLS: LazyLock<Vec<Value>> = LazyLock::new(|| {
    serde_json::from_str(include_str!("tools.json")).expect("tools.json is a JSON list of tool definitions")
});

static ARGUMENTS: LazyLock<HashMap<String, Arguments>> = LazyLock::new(|| {
    TOOLS
        .iter()
        .filter_map(|tool| {
            let name = tool.get("name")?.as_str()?.to_string();
            Some((name, Arguments::from_schema(tool.get("inputSchema")?)))
        })
        .collect()
});

/// One tool's definition.
pub fn tool_schema(name: &str) -> Option<Value> {
    TOOLS.iter().find(|tool| tool.get("name").and_then(Value::as_str) == Some(name)).cloned()
}

/// `generation`'s system prompt for rag_ask.
pub const ASK_SYSTEM_PROMPT: &str = "You answer questions about the user's personal corpus using only the numbered \
excerpts provided. Cite the excerpts you rely on inline as [n]. If the excerpts do not contain the answer, say so \
plainly instead of guessing.";
/// Each excerpt is trimmed to this many characters before it goes in rag_ask's prompt.
pub const EXCERPT_CHARS: usize = 1200;
/// Citations carry a shorter snippet.
pub const SNIPPET_CHARS: usize = 240;

/// Why a tool call failed.
#[derive(Debug)]
pub enum ToolError {
    /// No tool by that name.
    Unknown(String),
    /// The arguments are not what the schema allows: the client sees pydantic's text.
    Invalid(ValidationError),
    /// The tool failed. The client sees only that it did, as from the Python server; the reason
    /// is logged, and the agent shows it to its model.
    Failed(String),
}

impl From<CorpusError> for ToolError {
    fn from(error: CorpusError) -> Self {
        Self::Failed(error.0)
    }
}

impl From<ChatError> for ToolError {
    fn from(error: ChatError) -> Self {
        Self::Failed(error.0)
    }
}

/// Makes the local model from the configuration: [`crate::chat::ChatModel`] in the service.
pub type ChatFactory = Arc<dyn Fn(&ChatSettings) -> Result<Box<dyn Chat>, ChatError> + Send + Sync>;

/// What the tools run against.
#[derive(Clone)]
pub struct Toolbox {
    pub corpus: Arc<dyn Corpus>,
    pub chat: ChatFactory,
}

/// Python's `str.split()` whitespace: Unicode's, plus the four separators `\x1c`..`\x1f`.
pub fn is_py_space(c: char) -> bool {
    c.is_whitespace() || ('\u{1c}'..='\u{1f}').contains(&c)
}

/// `_trim`: whitespace runs collapsed to one space, and cut to `limit` characters with an ellipsis.
pub fn trim(text: &str, limit: usize) -> String {
    let text = text.split(is_py_space).filter(|word| !word.is_empty()).collect::<Vec<_>>().join(" ");
    if text.chars().count() <= limit {
        return text;
    }
    let head: String = text.chars().take(limit.saturating_sub(1)).collect();
    format!("{}…", head.trim_end_matches(is_py_space))
}

/// A string argument, or `None` for null.
fn text(args: &Map<String, Value>, key: &str) -> Option<String> {
    args.get(key).and_then(Value::as_str).map(str::to_string)
}

fn int(args: &Map<String, Value>, key: &str) -> i64 {
    args.get(key).and_then(Value::as_i64).unwrap_or_default()
}

fn list(args: &Map<String, Value>, key: &str) -> Vec<String> {
    match args.get(key) {
        Some(Value::Array(items)) => items.iter().filter_map(Value::as_str).map(str::to_string).collect(),
        Some(Value::String(one)) => vec![one.clone()],
        _ => Vec::new(),
    }
}

fn i32_of(value: i64) -> i32 {
    i32::try_from(value).unwrap_or(i32::MAX)
}

impl Toolbox {
    /// `tools/call`: the result object, or why there is none.
    ///
    /// # Errors
    ///
    /// [`ToolError`].
    pub fn call(&self, name: &str, given: &Map<String, Value>, caller: &Caller) -> Result<Value, ToolError> {
        let Some(checker) = ARGUMENTS.get(name) else {
            return Err(ToolError::Unknown(name.to_string()));
        };
        let args = checker.validate(given).map_err(ToolError::Invalid)?;
        match name {
            "rag_ask" => self.ask(&args, caller),
            "rag_generate" => self.generate(&args),
            "rag_agent" => self.agent(&args, caller),
            _ => self.read(name, &args, caller),
        }
    }

    /// One of the five read tools, with checked arguments.
    ///
    /// # Errors
    ///
    /// [`ToolError::Failed`] with the read's own message.
    pub fn read(&self, name: &str, args: &Map<String, Value>, caller: &Caller) -> Result<Value, ToolError> {
        match name {
            "rag_search" => Ok(self.corpus.search(caller, &search_query(args, "query"))?),
            "rag_get_document" => {
                let document_id = args.get("document_id").and_then(Value::as_i64);
                let location = text(args, "location").filter(|location| !location.is_empty());
                if document_id.is_none() && location.is_none() {
                    return Err(ToolError::Failed("pass either document_id or location".into()));
                }
                let query = DocumentQuery { document_id, location, max_chars: i32_of(int(args, "max_chars")) };
                Ok(self.corpus.document(caller, &query)?)
            }
            "rag_list_sources" => Ok(self.corpus.sources(caller)?),
            "rag_list_authors" => Ok(self.corpus.authors(caller, i32_of(int(args, "limit")))?),
            "rag_stats" => Ok(self.corpus.stats(caller)?),
            other => Err(ToolError::Unknown(other.to_string())),
        }
    }

    /// A read tool as the agent runs it: its arguments checked, then the read.
    ///
    /// # Errors
    ///
    /// The text the agent shows its model: pydantic's, or the read's.
    pub fn run_read(&self, name: &str, given: &Map<String, Value>, caller: &Caller) -> Result<Value, String> {
        let Some(checker) = ARGUMENTS.get(name) else {
            return Err(format!("Unknown tool: {name}"));
        };
        let args = checker.validate(given).map_err(|error| error.to_string())?;
        self.read(name, &args, caller).map_err(|error| match error {
            ToolError::Failed(message) | ToolError::Unknown(message) => message,
            ToolError::Invalid(error) => error.to_string(),
        })
    }

    fn model(&self) -> Result<(Box<dyn Chat>, ChatSettings), ToolError> {
        let settings = ChatSettings::from_corpus(self.corpus.as_ref());
        Ok(((self.chat)(&settings)?, settings))
    }

    fn ask(&self, args: &Map<String, Value>, caller: &Caller) -> Result<Value, ToolError> {
        let question = text(args, "question").unwrap_or_default();
        let mut query = search_query(args, "question");
        query.author = None;
        query.direction = None;
        let result = self.corpus.search(caller, &query)?;
        let hits = hits_of(&result);
        let (model, _) = self.model()?;
        // The content rule: a communication in the excerpts never goes to a model host off this machine.
        for hit in &hits {
            let class = hit.get("corpus_class").and_then(Value::as_str).unwrap_or_default();
            check_content(model.host_url(), "rag_ask", class).map_err(|blocked| ToolError::Failed(blocked.0))?;
        }
        let reply = model.complete(
            &build_ask_messages(&question, &hits),
            args.get("max_tokens").and_then(Value::as_i64),
            args.get("temperature").and_then(Value::as_f64),
        )?;
        Ok(json!({
            "answer": reply.text,
            "model": model.model_ref(),
            "provider": model.provider(),
            "question": question,
            "citations": citations(&hits),
            "prompt_tokens": reply.prompt_tokens,
            "completion_tokens": reply.completion_tokens,
        }))
    }

    fn generate(&self, args: &Map<String, Value>) -> Result<Value, ToolError> {
        let (model, _) = self.model()?;
        let mut messages = Vec::new();
        if let Some(system) = text(args, "system").filter(|system| !system.is_empty()) {
            messages.push(json!({"role": "system", "content": system}));
        }
        messages.push(json!({"role": "user", "content": text(args, "prompt").unwrap_or_default()}));
        let reply = model.complete(
            &messages,
            args.get("max_tokens").and_then(Value::as_i64),
            args.get("temperature").and_then(Value::as_f64),
        )?;
        Ok(json!({"text": reply.text, "model": model.model_ref(), "provider": model.provider()}))
    }

    fn agent(&self, args: &Map<String, Value>, caller: &Caller) -> Result<Value, ToolError> {
        let (model, settings) = self.model()?;
        let options = agent::Options {
            max_steps: usize::try_from(int(args, "max_steps")).unwrap_or(agent::DEFAULT_MAX_STEPS),
            max_tokens: args.get("max_tokens").and_then(Value::as_i64),
            temperature: args.get("temperature").and_then(Value::as_f64),
            search_first: args.get("search_first").and_then(Value::as_bool).unwrap_or(true),
            owner: settings.self_name,
        };
        let question = text(args, "question").unwrap_or_default();
        let run = |name: &str, given: &Map<String, Value>| self.run_read(name, given, caller);
        Ok(agent::run_agent(&question, &agent::agent_tools(), model.as_ref(), &run, &options)?)
    }
}

/// rag_search's query from checked arguments; `field` names the text (`query`, or rag_ask's `question`).
fn search_query(args: &Map<String, Value>, field: &str) -> SearchQuery {
    SearchQuery {
        query: text(args, field).unwrap_or_default(),
        limit: i32_of(int(args, "limit")),
        mode: text(args, "mode").unwrap_or_else(|| "hybrid".into()),
        corpus_classes: list(args, "corpus_class"),
        trust_tiers: list(args, "trust"),
        sources: list(args, "source"),
        author: text(args, "author"),
        direction: text(args, "direction"),
    }
}

/// A `SearchResult`'s hits.
fn hits_of(result: &Value) -> Vec<Map<String, Value>> {
    result
        .get("hits")
        .and_then(Value::as_array)
        .map(|hits| hits.iter().filter_map(Value::as_object).cloned().collect())
        .unwrap_or_default()
}

fn str_field<'a>(hit: &'a Map<String, Value>, key: &str) -> &'a str {
    hit.get(key).and_then(Value::as_str).unwrap_or_default()
}

/// The chat messages rag_ask sends: the instruction, the numbered excerpts, the question.
pub fn build_ask_messages(question: &str, hits: &[Map<String, Value>]) -> Vec<Value> {
    let excerpts = if hits.is_empty() {
        "(no excerpts were retrieved)".to_string()
    } else {
        hits.iter()
            .enumerate()
            .map(|(i, hit)| {
                let title = hit.get("title").and_then(Value::as_str).filter(|t| !t.is_empty()).unwrap_or("(untitled)");
                let mut header = format!("[{}] {title} \u{2014} {}", i + 1, str_field(hit, "location"));
                if let Some(section) = hit.get("section").and_then(Value::as_str).filter(|s| !s.is_empty()) {
                    let _ = write!(header, " \u{a7} {section}");
                }
                format!("{header}\n{}", trim(str_field(hit, "text"), EXCERPT_CHARS))
            })
            .collect::<Vec<_>>()
            .join("\n\n")
    };
    vec![
        json!({"role": "system", "content": ASK_SYSTEM_PROMPT}),
        json!({"role": "user", "content": format!("Excerpts:\n\n{excerpts}\n\nQuestion: {question}")}),
    ]
}

fn citations(hits: &[Map<String, Value>]) -> Vec<Value> {
    hits.iter()
        .enumerate()
        .map(|(i, hit)| {
            json!({
                "n": i + 1,
                "document_id": hit.get("document_id").cloned().unwrap_or(Value::Null),
                "title": hit.get("title").cloned().unwrap_or(Value::Null),
                "location": str_field(hit, "location"),
                "snippet": trim(str_field(hit, "text"), SNIPPET_CHARS),
                "score": hit.get("score").cloned().unwrap_or(Value::Null),
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_published_tools_are_the_python_servers_eight() {
        let names: Vec<&str> = TOOLS.iter().filter_map(|tool| tool["name"].as_str()).collect();
        assert_eq!(
            names,
            [
                "rag_search",
                "rag_get_document",
                "rag_list_sources",
                "rag_list_authors",
                "rag_stats",
                "rag_ask",
                "rag_generate",
                "rag_agent"
            ]
        );
    }

    #[test]
    fn trimming_matches_python() {
        assert_eq!(trim("  a \n\t b\u{1f}c  ", 100), "a b c");
        assert_eq!(trim("abcdef ghij", 8), "abcdef…");
        assert_eq!(trim("abcdefghij", 5), "abcd…");
    }
}

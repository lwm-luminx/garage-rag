//! MCP's JSON-RPC messages, answered as the Python server (MCP SDK 2.0's `MCPServer`) answers
//! them. Transport-free: [`Server::handle`] takes one message and returns the reply, if any, so
//! stdio, the HTTP transport and the C ABI share it.

use std::sync::Arc;

use garage_embed::Host;
use serde_json::{Map, Value, json};

use crate::chat::{Chat, ChatModel};
use crate::corpus::{Caller, Corpus};
use crate::tools::{ChatFactory, ToolError, Toolbox};

/// Protocol versions the server speaks, oldest first; a client asking for another gets the newest.
pub const SUPPORTED_VERSIONS: [&str; 4] = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"];
pub const LATEST_VERSION: &str = "2025-11-25";
/// The name `serverInfo` gives, as the Python server's.
pub const SERVER_NAME: &str = "garage-rag";

const METHOD_NOT_FOUND: i64 = -32601;
const INVALID_PARAMS: i64 = -32602;
const INTERNAL_ERROR: i64 = -32603;

/// What answers MCP's JSON-RPC messages for a transport ([`crate::http::Endpoint`], [`crate::stdio::serve`]):
/// [`Server`] here, or a handler of another crate that puts its own rules in front of a [`Server`] and still
/// uses these transports.
pub trait Handler: Send + Sync {
    /// The reply to one JSON-RPC message, or `None` when it needs none.
    fn handle(&self, message: &Value, caller: &Caller) -> Option<Value>;
}

impl Handler for Server {
    fn handle(&self, message: &Value, caller: &Caller) -> Option<Value> {
        Server::handle(self, message, caller)
    }
}

/// The MCP server: the tools, and the corpus and model they run against.
pub struct Server {
    toolbox: Toolbox,
}

impl Server {
    /// A server whose rag_ask, rag_generate and rag_agent reach the configured model through `host`.
    pub fn new(corpus: Arc<dyn Corpus>, host: Arc<dyn Host>) -> Self {
        let chat: ChatFactory = Arc::new(move |settings| {
            ChatModel::new(settings, Arc::clone(&host)).map(|model| Box::new(model) as Box<dyn Chat>)
        });
        Self::with_chat(corpus, chat)
    }

    /// A server with its own way of making the model (tests use a stand-in).
    pub fn with_chat(corpus: Arc<dyn Corpus>, chat: ChatFactory) -> Self {
        Self { toolbox: Toolbox { corpus, chat } }
    }

    /// The reply to one JSON-RPC message, or `None` when it needs none: a notification, a
    /// response, or something that is not a JSON-RPC message (which the Python server drops too).
    pub fn handle(&self, message: &Value, caller: &Caller) -> Option<Value> {
        let object = message.as_object()?;
        if object.get("jsonrpc") != Some(&json!("2.0")) {
            return None;
        }
        let method = object.get("method")?.as_str()?;
        let id = object.get("id")?.clone();
        if !(id.is_string() || id.is_i64() || id.is_u64()) {
            return None;
        }
        let params = object.get("params").cloned().unwrap_or_else(|| json!({}));
        let outcome = match method {
            "initialize" => Ok(initialize(&params)),
            "ping" => Ok(json!({})),
            "tools/list" => self.list_tools(caller),
            "tools/call" => self.call_tool(&params, caller),
            "prompts/list" => Ok(json!({"prompts": []})),
            "resources/list" => Ok(json!({"resources": []})),
            "resources/templates/list" => Ok(json!({"resourceTemplates": []})),
            other => Err(json!({"code": METHOD_NOT_FOUND, "message": "Method not found", "data": other})),
        };
        Some(match outcome {
            Ok(result) => json!({"jsonrpc": "2.0", "id": id, "result": result}),
            Err(error) => json!({"jsonrpc": "2.0", "id": id, "error": error}),
        })
    }

    /// The tools the access policy lets `caller` use; when it cannot decide, an error, never the
    /// whole list.
    fn list_tools(&self, caller: &Caller) -> Result<Value, Value> {
        match self.toolbox.list(caller) {
            Ok(tools) => Ok(json!({"tools": tools})),
            Err(error) => {
                eprintln!("garage-mcp: tools/list: {error}");
                Err(
                    json!({"code": INTERNAL_ERROR, "message": "the access policy could not decide which tools to offer"}),
                )
            }
        }
    }

    fn call_tool(&self, params: &Value, caller: &Caller) -> Result<Value, Value> {
        let invalid = || json!({"code": INVALID_PARAMS, "message": "Invalid request parameters", "data": ""});
        let name = params.get("name").and_then(Value::as_str).ok_or_else(invalid)?;
        let arguments = match params.get("arguments") {
            None | Some(Value::Null) => Map::new(),
            Some(Value::Object(arguments)) => arguments.clone(),
            Some(_) => return Err(invalid()),
        };
        Ok(match self.toolbox.call(name, &arguments, caller) {
            Ok(result) => json!({
                "content": [{"text": pretty(&result), "type": "text"}],
                "isError": false,
                "structuredContent": result,
            }),
            Err(ToolError::Unknown(name)) => tool_error(&format!("Unknown tool: {name}")),
            Err(ToolError::Denied(name)) => tool_error(&format!("Tool {name} is not available to this client")),
            Err(ToolError::Invalid(error)) => tool_error(&format!("Error executing tool {name}: {error}")),
            Err(ToolError::Failed(reason)) => {
                // As the Python server: the reason stays here, in the log.
                eprintln!("garage-mcp: {name} failed: {reason}");
                tool_error(&format!("Error executing tool {name}"))
            }
        })
    }
}

fn tool_error(text: &str) -> Value {
    json!({"content": [{"text": text, "type": "text"}], "isError": true})
}

/// A result as the text content the SDK writes beside `structuredContent` (two-space indent,
/// Unicode as it is).
fn pretty(result: &Value) -> String {
    serde_json::to_string_pretty(result).unwrap_or_default()
}

fn initialize(params: &Value) -> Value {
    let asked = params.get("protocolVersion").and_then(Value::as_str).unwrap_or_default();
    let version = if SUPPORTED_VERSIONS.contains(&asked) { asked } else { LATEST_VERSION };
    json!({
        "capabilities": {
            "experimental": {},
            "prompts": {"listChanged": false},
            "resources": {"listChanged": false, "subscribe": false},
            "tools": {"listChanged": false},
        },
        "protocolVersion": version,
        "serverInfo": {"name": SERVER_NAME, "version": ""},
    })
}

/// Whether a message is a request (it has a method and an id), which gets a reply.
pub fn is_request(message: &Value) -> bool {
    message.get("method").is_some() && message.get("id").is_some()
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use serde_json::{Value, json};

    use super::*;
    use crate::chat::{Chat, ChatError};
    use crate::corpus::{Corpus, CorpusError, DocumentQuery, SearchQuery, Transport};

    /// A corpus whose access policy withholds rag_stats from callers without a token, and cannot
    /// decide for the token `broken`.
    struct Withholding;

    impl Corpus for Withholding {
        fn search(&self, _: &Caller, _: &SearchQuery) -> Result<Value, CorpusError> {
            Ok(json!({"query": "", "results": []}))
        }
        fn document(&self, _: &Caller, _: &DocumentQuery) -> Result<Value, CorpusError> {
            Ok(json!({}))
        }
        fn sources(&self, _: &Caller) -> Result<Value, CorpusError> {
            Ok(json!({"sources": []}))
        }
        fn authors(&self, _: &Caller, _: i32) -> Result<Value, CorpusError> {
            Ok(json!({"authors": []}))
        }
        fn stats(&self, _: &Caller) -> Result<Value, CorpusError> {
            Ok(json!({"documents": 1}))
        }
        fn setting(&self, _: &str) -> Result<Value, CorpusError> {
            Ok(Value::Null)
        }
        fn tools(&self, caller: &Caller, tools: &[String]) -> Result<Vec<String>, CorpusError> {
            match caller.registration_token.as_deref() {
                Some("broken") => Err(CorpusError("the policy cannot decide".into())),
                Some(_) => Ok(tools.to_vec()),
                None => Ok(tools.iter().filter(|name| *name != "rag_stats").cloned().collect()),
            }
        }
    }

    fn server() -> Server {
        let chat: ChatFactory = Arc::new(|_| Err::<Box<dyn Chat>, _>(ChatError("no model in tests".into())));
        Server::with_chat(Arc::new(Withholding), chat)
    }

    fn caller(token: Option<&str>) -> Caller {
        let mut caller = Caller::new(Transport::Http);
        caller.registration_token = token.map(str::to_owned);
        caller
    }

    fn names(reply: &Value) -> Vec<String> {
        reply["result"]["tools"].as_array().unwrap().iter().map(|t| t["name"].as_str().unwrap().to_owned()).collect()
    }

    #[test]
    fn the_access_policy_decides_which_tools_a_caller_lists_and_calls() {
        let server = server();
        let list = json!({"jsonrpc": "2.0", "id": 1, "method": "tools/list"});
        let call = json!({"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "rag_stats"}});

        let everything = names(&server.handle(&list, &caller(Some("gmr_1"))).unwrap());
        assert!(everything.contains(&"rag_stats".to_owned()));
        let reply = server.handle(&call, &caller(Some("gmr_1"))).unwrap();
        assert_eq!(reply["result"]["isError"], false, "{reply}");

        let withheld = names(&server.handle(&list, &caller(None)).unwrap());
        assert!(!withheld.contains(&"rag_stats".to_owned()));
        assert_eq!(withheld.len(), everything.len() - 1);
        let reply = server.handle(&call, &caller(None)).unwrap();
        assert_eq!(reply["result"]["isError"], true);
        assert_eq!(reply["result"]["content"][0]["text"], "Tool rag_stats is not available to this client");
    }

    #[test]
    fn a_policy_that_cannot_decide_offers_and_runs_nothing() {
        let server = server();
        let list = json!({"jsonrpc": "2.0", "id": 1, "method": "tools/list"});
        let reply = server.handle(&list, &caller(Some("broken"))).unwrap();
        assert_eq!(reply["error"]["code"], INTERNAL_ERROR, "{reply}");
        let call = json!({"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "rag_stats"}});
        let reply = server.handle(&call, &caller(Some("broken"))).unwrap();
        assert_eq!(reply["result"]["isError"], true);
        assert_eq!(reply["result"]["content"][0]["text"], "Error executing tool rag_stats");
    }
}

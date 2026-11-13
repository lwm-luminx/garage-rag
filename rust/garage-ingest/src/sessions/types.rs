//! Common normalized data model for AI assistant sessions (`025_sessions.sql`), shared between
//! `garage-ingest` (parsers and synthesis) and `garage-service` (relational persistence).

use chrono::{DateTime, TimeZone, Utc};
use serde_json::{Map, Value, json};

/// Source kind for local Claude Code / Cowork transcripts and Claude Web exports.
pub const CLAUDE_KIND: &str = "claude";
/// Source kind for local OpenAI Codex sessions and ChatGPT Web exports.
pub const CHATGPT_KIND: &str = "chatgpt";
/// Source kind for local Antigravity brain directories and archives.
pub const ANTIGRAVITY_KIND: &str = "antigravity";

/// Every session source kind.
pub const SESSION_KINDS: [&str; 3] = [CLAUDE_KIND, CHATGPT_KIND, ANTIGRAVITY_KIND];

/// Chunker name stored on synthesized turn chunks.
pub const CHUNKER: &str = "session_turn";
/// Extractor version for session synthesis.
pub const VERSION: &str = "1";

const MAX_COMMAND_CHARS: usize = 4_000;
const MAX_OUTPUT_PREVIEW_CHARS: usize = 1_000;

/// Relational payload attached to `PersistDocumentRequest.session_json`.
#[derive(Clone, Debug, PartialEq)]
pub enum SessionWritePayload {
    /// Full normalized session graph for a synthesized session document.
    Session(Box<SessionRecord>),
    /// Links a companion deliverable `documents` row back to its `session_artifacts` row.
    ArtifactLink { session_external_id: String, artifact_external_id: String },
}

/// Normalized row for `sessions` plus its child turns, tool calls, and artifacts.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct SessionRecord {
    pub provider: String,
    pub surface: String,
    pub external_id: String,
    pub parent_external_id: Option<String>,
    pub title: Option<String>,
    pub summary: Option<String>,
    pub workspace_path: Option<String>,
    pub workspace_paths: Vec<String>,
    pub git_branch: Option<String>,
    pub git_commit: Option<String>,
    pub primary_model: Option<String>,
    pub started_at_micros: Option<i64>,
    pub updated_at_micros: Option<i64>,
    pub input_tokens: Option<i64>,
    pub output_tokens: Option<i64>,
    pub cache_read_tokens: Option<i64>,
    pub origin_uri: Option<String>,
    pub meta: Map<String, Value>,
    pub turns: Vec<SessionTurnRecord>,
    pub tool_calls: Vec<SessionToolCallRecord>,
    pub artifacts: Vec<SessionArtifactRecord>,
}

/// Normalized row for `session_turns`.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct SessionTurnRecord {
    pub external_id: String,
    pub parent_external_id: Option<String>,
    pub ord: i32,
    pub active_ord: Option<i32>,
    pub role: String,
    pub direction: Option<String>,
    pub is_self: bool,
    pub model: Option<String>,
    pub content: Option<String>,
    pub thinking: Option<String>,
    pub input_tokens: Option<i32>,
    pub output_tokens: Option<i32>,
    pub cache_read_tokens: Option<i32>,
    pub created_at_micros: Option<i64>,
    pub meta: Map<String, Value>,
}

/// Normalized row for `session_tool_calls`.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct SessionToolCallRecord {
    pub turn_external_id: String,
    pub result_turn_external_id: Option<String>,
    pub ord: i32,
    pub external_call_id: Option<String>,
    pub tool_name: String,
    pub tool_kind: String,
    pub target_path: Option<String>,
    pub command: Option<String>,
    pub status: String,
    pub arguments: Map<String, Value>,
    pub output_preview: Option<String>,
    pub output_bytes: Option<i32>,
    pub created_at_micros: Option<i64>,
}

/// Normalized row for `session_artifacts`.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct SessionArtifactRecord {
    pub turn_external_id: Option<String>,
    pub external_id: String,
    pub kind: String,
    pub title: Option<String>,
    pub mime: Option<String>,
    pub uri: Option<String>,
    pub content_sha256: Option<String>,
    pub meta: Map<String, Value>,
}

/// A companion deliverable document (plan, walkthrough, code/markdown artifact) indexed alongside
/// its parent session and linked via `session_artifacts.document_id`.
#[derive(Clone, Debug, PartialEq)]
pub struct CompanionDocument {
    pub artifact_external_id: String,
    pub uri: String,
    pub title: Option<String>,
    pub text: String,
    pub extension: String,
    pub mtime: f64,
    pub source_sha256: String,
    pub meta: Map<String, Value>,
}

/// One parsed session ready for synthesis and ingestion.
#[derive(Clone, Debug, PartialEq)]
pub struct ParsedSession {
    pub uri: String,
    pub source_sha256: String,
    pub mtime: f64,
    pub record: SessionRecord,
    pub companions: Vec<CompanionDocument>,
}

/// Strips NUL bytes so Postgres `text` and `jsonb` columns never reject a string.
#[must_use]
pub fn clean_str(text: &str) -> String {
    if text.contains('\0') { text.replace('\0', "") } else { text.to_owned() }
}

/// Case-insensitive extension check on a path.
pub(super) fn path_has_ext(path: &std::path::Path, ext: &str) -> bool {
    path.extension().is_some_and(|e| e.eq_ignore_ascii_case(ext))
}

/// Case-insensitive extension check on a filename or relative entry path.
pub(super) fn has_ext(name: &str, ext: &str) -> bool {
    path_has_ext(std::path::Path::new(name), ext)
}

/// Cleans an optional string and drops empty/whitespace-only values when `trim_empty` is set.
#[must_use]
pub fn clean_opt(text: Option<&str>, trim_empty: bool) -> Option<String> {
    let cleaned = clean_str(text?);
    if trim_empty && cleaned.trim().is_empty() { None } else { Some(cleaned) }
}

/// Recursively strips NUL bytes from a JSON map in place.
pub fn clean_json_map(map: &mut Map<String, Value>) {
    if map.keys().any(|key| key.contains('\0')) {
        *map = std::mem::take(map).into_iter().map(|(key, value)| (clean_str(&key), value)).collect();
    }
    map.values_mut().for_each(clean_json_value);
}

fn clean_json_value(value: &mut Value) {
    match value {
        Value::String(s) => {
            if s.contains('\0') {
                s.retain(|c| c != '\0');
            }
        }
        Value::Array(items) => items.iter_mut().for_each(clean_json_value),
        Value::Object(map) => clean_json_map(map),
        _ => {}
    }
}

/// Truncates `text` to at most `max_chars` Unicode scalar values cleanly.
#[must_use]
pub fn truncate_chars(text: &str, max_chars: usize) -> String {
    let cleaned = clean_str(text);
    if cleaned.chars().count() <= max_chars {
        cleaned
    } else {
        cleaned.chars().take(max_chars).collect()
    }
}

/// Bounded preview and byte length for tool outputs.
#[must_use]
pub fn preview_output(text: &str) -> (Option<String>, Option<i32>) {
    let cleaned = clean_str(text);
    let bytes = i32::try_from(cleaned.len()).unwrap_or(i32::MAX);
    let trimmed = cleaned.trim();
    if trimmed.is_empty() {
        return (None, (bytes > 0).then_some(bytes));
    }
    let preview = truncate_chars(trimmed, MAX_OUTPUT_PREVIEW_CHARS);
    (Some(preview), Some(bytes))
}

/// Parses an RFC3339 string or numeric epoch (seconds or milliseconds) into Unix microseconds.
#[must_use]
pub fn parse_timestamp_micros(value: &Value) -> Option<i64> {
    match value {
        Value::String(text) => parse_str_timestamp_micros(text),
        Value::Number(num) => {
            let f = num.as_f64()?;
            if !f.is_finite() || f <= 0.0 {
                return None;
            }
            // Values above 1e11 are milliseconds rather than seconds.
            #[allow(clippy::cast_possible_truncation)]
            let micros = if f > 1e11 { (f * 1_000.0).round() as i64 } else { (f * 1_000_000.0).round() as i64 };
            Some(micros)
        }
        _ => None,
    }
}

/// Parses an ISO-8601 / RFC3339 string (or numeric string) into Unix microseconds.
#[must_use]
pub fn parse_str_timestamp_micros(text: &str) -> Option<i64> {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return None;
    }
    if let Ok(dt) = DateTime::parse_from_rfc3339(trimmed) {
        return Some(dt.timestamp_micros());
    }
    // Handle space-separated UTC timestamps such as "2026-04-12 10:15:30Z" or "+00:00".
    let normalized = trimmed.replacen(' ', "T", 1);
    if let Ok(dt) = DateTime::parse_from_rfc3339(&normalized) {
        return Some(dt.timestamp_micros());
    }
    if let Ok(dt) = DateTime::parse_from_rfc3339(&format!("{normalized}Z")) {
        return Some(dt.timestamp_micros());
    }
    if let Ok(secs) = trimmed.parse::<f64>()
        && secs.is_finite()
        && secs > 0.0
    {
        #[allow(clippy::cast_possible_truncation)]
        return Some((secs * 1_000_000.0).round() as i64);
    }
    None
}

/// Converts Unix microseconds into `DateTime<Utc>`.
#[must_use]
pub fn micros_to_utc(micros: i64) -> Option<DateTime<Utc>> {
    Utc.timestamp_micros(micros).single()
}

/// Formats `YYYY-MM-DD HH:MM UTC` for synthesized message headers, matching `messages-markdown`.
#[must_use]
pub fn format_minute_utc(micros: Option<i64>) -> Option<String> {
    let dt = micros.and_then(micros_to_utc)?;
    Some(dt.format("%Y-%m-%d %H:%M UTC").to_string())
}

/// Formats RFC3339 timestamp for metadata maps.
#[must_use]
pub fn format_isoformat(micros: Option<i64>) -> Option<String> {
    let dt = micros.and_then(micros_to_utc)?;
    Some(dt.to_rfc3339())
}

/// Classifies a tool invocation into `(tool_kind, target_path, command)`.
#[must_use]
pub fn classify_tool(tool_name: &str, arguments: &Map<String, Value>) -> (String, Option<String>, Option<String>) {
    let name = tool_name.trim();
    let lower = name.to_ascii_lowercase();
    let kind = if lower.starts_with("mcp_")
        || lower.starts_with("mcp__")
        || matches!(lower.as_str(), "call_mcp_tool" | "list_resources" | "read_resource")
    {
        "mcp"
    } else if matches!(
        lower.as_str(),
        "task"
            | "agent"
            | "dispatch_agent"
            | "invoke_subagent"
            | "define_subagent"
            | "manage_subagents"
            | "swarm"
            | "send_message"
    ) {
        "subagent"
    } else if lower.starts_with("browser_")
        || matches!(lower.as_str(), "webfetch" | "web_fetch" | "open_url" | "navigate_page")
    {
        "browser"
    } else if matches!(
        lower.as_str(),
        "read"
            | "notebookread"
            | "read_file"
            | "view_file"
            | "view_file_outline"
            | "view_code_item"
            | "list_dir"
    ) {
        "read"
    } else if matches!(
        lower.as_str(),
        "write"
            | "edit"
            | "multiedit"
            | "notebookedit"
            | "write_file"
            | "edit_file"
            | "replace_file_content"
            | "multi_replace_file_content"
            | "apply_patch"
            | "canmore.create_textdoc"
            | "canmore.update_textdoc"
    ) {
        "write"
    } else if matches!(
        lower.as_str(),
        "bash"
            | "run_command"
            | "command_status"
            | "send_command_input"
            | "exec_command"
            | "write_stdin"
            | "shell"
            | "local_shell"
            | "container.exec"
            | "python"
    ) {
        "exec"
    } else if matches!(
        lower.as_str(),
        "grep"
            | "glob"
            | "ls"
            | "websearch"
            | "web_search"
            | "toolsearch"
            | "grep_search"
            | "find_by_name"
            | "search_web"
            | "search"
    ) {
        "search"
    } else {
        "other"
    };

    let target_path = extract_target_path(arguments);
    let command = extract_command(arguments);
    (kind.to_owned(), target_path, command)
}

fn extract_target_path(arguments: &Map<String, Value>) -> Option<String> {
    for key in [
        "file_path",
        "path",
        "Path",
        "TargetFile",
        "DirectoryPath",
        "SearchPath",
        "notebook_path",
        "workdir",
        "cwd",
    ] {
        if let Some(val) = arguments.get(key).and_then(Value::as_str)
            && !val.trim().is_empty()
        {
            return Some(truncate_chars(val.trim(), 1_024));
        }
    }
    if let Some(patch) = arguments.get("input").or_else(|| arguments.get("patch")).and_then(Value::as_str) {
        for line in patch.lines() {
            for prefix in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] {
                if let Some(rest) = line.strip_prefix(prefix)
                    && !rest.trim().is_empty()
                {
                    return Some(truncate_chars(rest.trim(), 1_024));
                }
            }
        }
    }
    None
}

fn extract_command(arguments: &Map<String, Value>) -> Option<String> {
    for key in ["command", "CommandLine", "cmd"] {
        if let Some(val) = arguments.get(key) {
            if let Some(s) = val.as_str()
                && !s.trim().is_empty()
            {
                return Some(truncate_chars(s.trim(), MAX_COMMAND_CHARS));
            }
            if let Some(arr) = val.as_array() {
                let joined: Vec<&str> = arr.iter().filter_map(Value::as_str).collect();
                if !joined.is_empty() {
                    return Some(truncate_chars(&joined.join(" "), MAX_COMMAND_CHARS));
                }
            }
        }
    }
    None
}

/// Derives a readable session title from an explicit title or the first active user prompt.
#[must_use]
pub fn derive_title(explicit: Option<&str>, turns: &[SessionTurnRecord], fallback: &str) -> String {
    if let Some(title) = explicit.map(str::trim).filter(|t| !t.is_empty()) {
        return truncate_chars(title, 200);
    }
    for turn in turns {
        if turn.active_ord.is_some()
            && turn.role == "user"
            && let Some(content) = turn.content.as_deref()
        {
            let first_line = content
                .lines()
                .map(str::trim)
                .find(|line| !line.is_empty())
                .unwrap_or_default();
            if !first_line.is_empty() {
                return truncate_chars(first_line, 100);
            }
        }
    }
    clean_str(fallback)
}

impl SessionWritePayload {
    /// Encodes the payload as JSON for `PersistDocumentRequest.session_json`.
    #[must_use]
    pub fn to_json(&self) -> Value {
        match self {
            Self::Session(record) => json!({
                "kind": "session",
                "session": record.to_json(),
            }),
            Self::ArtifactLink { session_external_id, artifact_external_id } => json!({
                "kind": "artifact_link",
                "session_external_id": session_external_id,
                "artifact_external_id": artifact_external_id,
            }),
        }
    }

    /// Decodes a payload produced by [`Self::to_json`].
    ///
    /// # Errors
    ///
    /// Malformed JSON structure or missing required string/integer fields.
    pub fn from_json(value: &Value) -> Result<Self, String> {
        let obj = value.as_object().ok_or("session_json must be a JSON object")?;
        match obj.get("kind").and_then(Value::as_str) {
            Some("session") => {
                let inner = obj.get("session").ok_or("session_json missing 'session'")?;
                Ok(Self::Session(Box::new(SessionRecord::from_json(inner)?)))
            }
            Some("artifact_link") => Ok(Self::ArtifactLink {
                session_external_id: req_str(obj, "session_external_id")?,
                artifact_external_id: req_str(obj, "artifact_external_id")?,
            }),
            other => Err(format!("unknown session_json kind {other:?}")),
        }
    }
}

impl SessionRecord {
    fn to_json(&self) -> Value {
        json!({
            "provider": self.provider,
            "surface": self.surface,
            "external_id": self.external_id,
            "parent_external_id": self.parent_external_id,
            "title": self.title,
            "summary": self.summary,
            "workspace_path": self.workspace_path,
            "workspace_paths": self.workspace_paths,
            "git_branch": self.git_branch,
            "git_commit": self.git_commit,
            "primary_model": self.primary_model,
            "started_at_micros": self.started_at_micros,
            "updated_at_micros": self.updated_at_micros,
            "input_tokens": self.input_tokens,
            "output_tokens": self.output_tokens,
            "cache_read_tokens": self.cache_read_tokens,
            "origin_uri": self.origin_uri,
            "meta": self.meta,
            "turns": self.turns.iter().map(SessionTurnRecord::to_json).collect::<Vec<_>>(),
            "tool_calls": self.tool_calls.iter().map(SessionToolCallRecord::to_json).collect::<Vec<_>>(),
            "artifacts": self.artifacts.iter().map(SessionArtifactRecord::to_json).collect::<Vec<_>>(),
        })
    }

    fn from_json(value: &Value) -> Result<Self, String> {
        let obj = value.as_object().ok_or("session record must be an object")?;
        let workspace_paths = obj
            .get("workspace_paths")
            .and_then(Value::as_array)
            .map(|items| items.iter().filter_map(Value::as_str).map(clean_str).collect())
            .unwrap_or_default();
        let turns = array_items(obj, "turns")?
            .iter()
            .map(SessionTurnRecord::from_json)
            .collect::<Result<Vec<_>, _>>()?;
        let tool_calls = array_items(obj, "tool_calls")?
            .iter()
            .map(SessionToolCallRecord::from_json)
            .collect::<Result<Vec<_>, _>>()?;
        let artifacts = array_items(obj, "artifacts")?
            .iter()
            .map(SessionArtifactRecord::from_json)
            .collect::<Result<Vec<_>, _>>()?;
        Ok(Self {
            provider: req_str(obj, "provider")?,
            surface: req_str(obj, "surface")?,
            external_id: req_str(obj, "external_id")?,
            parent_external_id: opt_str(obj, "parent_external_id"),
            title: opt_str(obj, "title"),
            summary: opt_str(obj, "summary"),
            workspace_path: opt_str(obj, "workspace_path"),
            workspace_paths,
            git_branch: opt_str(obj, "git_branch"),
            git_commit: opt_str(obj, "git_commit"),
            primary_model: opt_str(obj, "primary_model"),
            started_at_micros: opt_i64(obj, "started_at_micros"),
            updated_at_micros: opt_i64(obj, "updated_at_micros"),
            input_tokens: opt_i64(obj, "input_tokens"),
            output_tokens: opt_i64(obj, "output_tokens"),
            cache_read_tokens: opt_i64(obj, "cache_read_tokens"),
            origin_uri: opt_str(obj, "origin_uri"),
            meta: obj_map(obj, "meta"),
            turns,
            tool_calls,
            artifacts,
        })
    }
}

impl SessionTurnRecord {
    fn to_json(&self) -> Value {
        json!({
            "external_id": self.external_id,
            "parent_external_id": self.parent_external_id,
            "ord": self.ord,
            "active_ord": self.active_ord,
            "role": self.role,
            "direction": self.direction,
            "is_self": self.is_self,
            "model": self.model,
            "content": self.content,
            "thinking": self.thinking,
            "input_tokens": self.input_tokens,
            "output_tokens": self.output_tokens,
            "cache_read_tokens": self.cache_read_tokens,
            "created_at_micros": self.created_at_micros,
            "meta": self.meta,
        })
    }

    fn from_json(value: &Value) -> Result<Self, String> {
        let obj = value.as_object().ok_or("session turn must be an object")?;
        Ok(Self {
            external_id: req_str(obj, "external_id")?,
            parent_external_id: opt_str(obj, "parent_external_id"),
            ord: req_i32(obj, "ord")?,
            active_ord: opt_i32(obj, "active_ord"),
            role: req_str(obj, "role")?,
            direction: opt_str(obj, "direction"),
            is_self: obj.get("is_self").and_then(Value::as_bool).unwrap_or(false),
            model: opt_str(obj, "model"),
            content: opt_str(obj, "content"),
            thinking: opt_str(obj, "thinking"),
            input_tokens: opt_i32(obj, "input_tokens"),
            output_tokens: opt_i32(obj, "output_tokens"),
            cache_read_tokens: opt_i32(obj, "cache_read_tokens"),
            created_at_micros: opt_i64(obj, "created_at_micros"),
            meta: obj_map(obj, "meta"),
        })
    }
}

impl SessionToolCallRecord {
    fn to_json(&self) -> Value {
        json!({
            "turn_external_id": self.turn_external_id,
            "result_turn_external_id": self.result_turn_external_id,
            "ord": self.ord,
            "external_call_id": self.external_call_id,
            "tool_name": self.tool_name,
            "tool_kind": self.tool_kind,
            "target_path": self.target_path,
            "command": self.command,
            "status": self.status,
            "arguments": self.arguments,
            "output_preview": self.output_preview,
            "output_bytes": self.output_bytes,
            "created_at_micros": self.created_at_micros,
        })
    }

    fn from_json(value: &Value) -> Result<Self, String> {
        let obj = value.as_object().ok_or("session tool call must be an object")?;
        Ok(Self {
            turn_external_id: req_str(obj, "turn_external_id")?,
            result_turn_external_id: opt_str(obj, "result_turn_external_id"),
            ord: req_i32(obj, "ord")?,
            external_call_id: opt_str(obj, "external_call_id"),
            tool_name: req_str(obj, "tool_name")?,
            tool_kind: opt_str(obj, "tool_kind").unwrap_or_else(|| "other".to_owned()),
            target_path: opt_str(obj, "target_path"),
            command: opt_str(obj, "command"),
            status: opt_str(obj, "status").unwrap_or_else(|| "ok".to_owned()),
            arguments: obj_map(obj, "arguments"),
            output_preview: opt_str(obj, "output_preview"),
            output_bytes: opt_i32(obj, "output_bytes"),
            created_at_micros: opt_i64(obj, "created_at_micros"),
        })
    }
}

impl SessionArtifactRecord {
    fn to_json(&self) -> Value {
        json!({
            "turn_external_id": self.turn_external_id,
            "external_id": self.external_id,
            "kind": self.kind,
            "title": self.title,
            "mime": self.mime,
            "uri": self.uri,
            "content_sha256": self.content_sha256,
            "meta": self.meta,
        })
    }

    fn from_json(value: &Value) -> Result<Self, String> {
        let obj = value.as_object().ok_or("session artifact must be an object")?;
        Ok(Self {
            turn_external_id: opt_str(obj, "turn_external_id"),
            external_id: req_str(obj, "external_id")?,
            kind: opt_str(obj, "kind").unwrap_or_else(|| "document".to_owned()),
            title: opt_str(obj, "title"),
            mime: opt_str(obj, "mime"),
            uri: opt_str(obj, "uri"),
            content_sha256: opt_str(obj, "content_sha256"),
            meta: obj_map(obj, "meta"),
        })
    }
}

fn req_str(obj: &Map<String, Value>, key: &str) -> Result<String, String> {
    obj.get(key)
        .and_then(Value::as_str)
        .map(clean_str)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| format!("missing or empty string field {key:?}"))
}

fn opt_str(obj: &Map<String, Value>, key: &str) -> Option<String> {
    obj.get(key).and_then(Value::as_str).map(clean_str)
}

fn opt_i64(obj: &Map<String, Value>, key: &str) -> Option<i64> {
    obj.get(key).and_then(Value::as_i64)
}

fn opt_i32(obj: &Map<String, Value>, key: &str) -> Option<i32> {
    obj.get(key).and_then(Value::as_i64).and_then(|n| i32::try_from(n).ok())
}

fn req_i32(obj: &Map<String, Value>, key: &str) -> Result<i32, String> {
    opt_i32(obj, key).ok_or_else(|| format!("missing integer field {key:?}"))
}

fn obj_map(obj: &Map<String, Value>, key: &str) -> Map<String, Value> {
    let mut map = obj.get(key).and_then(Value::as_object).cloned().unwrap_or_default();
    clean_json_map(&mut map);
    map
}

fn array_items<'a>(obj: &'a Map<String, Value>, key: &str) -> Result<&'a [Value], String> {
    match obj.get(key) {
        None | Some(Value::Null) => Ok(&[]),
        Some(Value::Array(items)) => Ok(items.as_slice()),
        Some(_) => Err(format!("field {key:?} must be an array")),
    }
}

//! Parser and scanner helpers for `claude` session sources:
//! - Local Claude Code and Cowork `.jsonl` transcripts (`~/.claude/projects/**/*.jsonl`, including
//!   `<session>/subagents/*.jsonl` sidechains).
//! - Claude Web data exports (`conversations.json` or `.zip` archives).

use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};

use serde_json::{Map, Value};

use crate::sha256::hex_digest;

use super::types::{
    CLAUDE_KIND, CompanionDocument, ParsedSession, SessionArtifactRecord, SessionRecord, SessionToolCallRecord,
    SessionTurnRecord, classify_tool, clean_json_map, clean_opt, clean_str, derive_title, has_ext,
    parse_timestamp_micros, path_has_ext, preview_output,
};

const SKIP_DIRS: &[&str] = &[
    "backups",
    "cache",
    "debug",
    "file-history",
    "ide",
    "node_modules",
    "paste-cache",
    "plugins",
    "session-env",
    "shell-snapshots",
    "statsig",
    "tasks",
    "telemetry",
    "todos",
];

/// Counts sessions under `root` for `scan_source`.
pub(super) fn count_claude_items(root: &Path, details: &mut Map<String, Value>, mut tick: impl FnMut(u64)) -> u64 {
    let files = collect_claude_paths(root);
    let (mut total, mut jsonl_count, mut export_files, mut zip_files) = (0_u64, 0_u64, 0_u64, 0_u64);
    for path in files {
        if path_has_ext(&path, "jsonl") {
            jsonl_count += 1;
            total += 1;
        } else if path_has_ext(&path, "json") {
            export_files += 1;
            total += fs::read(&path).ok().map_or(0, |b| count_json_array(&b));
        } else if path_has_ext(&path, "zip") {
            zip_files += 1;
            total += count_zip_conversations(&path);
        }
        tick(total);
    }
    details.insert("jsonl_files".into(), Value::from(jsonl_count));
    details.insert("export_files".into(), Value::from(export_files));
    details.insert("archives".into(), Value::from(zip_files));
    total
}

/// Discovers and parses every Claude session under `root`.
pub(super) fn load_claude_sessions(root: &Path) -> Vec<Result<ParsedSession, String>> {
    let mut out = Vec::new();
    for path in collect_claude_paths(root) {
        let mtime = file_mtime(&path);
        if path_has_ext(&path, "jsonl") {
            match fs::read(&path) {
                Ok(bytes) => {
                    if let Some(res) = parse_claude_jsonl(&path, &bytes, mtime) {
                        out.push(res);
                    }
                }
                Err(err) => out.push(Err(format!("{}: {err}", path.display()))),
            }
        } else if path_has_ext(&path, "json") {
            match fs::read(&path) {
                Ok(bytes) => out.extend(parse_claude_web_json(&path.display().to_string(), &bytes, mtime)),
                Err(err) => out.push(Err(format!("{}: {err}", path.display()))),
            }
        } else if path_has_ext(&path, "zip") {
            out.extend(load_claude_zip(&path, mtime));
        }
    }
    out
}

fn collect_claude_paths(root: &Path) -> Vec<PathBuf> {
    let Ok(meta) = fs::metadata(root) else { return Vec::new() };
    if meta.is_file() {
        return vec![root.to_path_buf()];
    }
    let mut found = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = fs::read_dir(&dir) else { continue };
        let mut subdirs = Vec::new();
        let mut files = Vec::new();
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') {
                continue;
            }
            let Ok(ft) = entry.file_type() else { continue };
            if ft.is_symlink() {
                continue;
            }
            if ft.is_dir() {
                if !SKIP_DIRS.contains(&name.as_str()) {
                    subdirs.push(entry.path());
                }
            } else if ft.is_file() {
                let lower = name.to_ascii_lowercase();
                if has_ext(&name, "jsonl")
                    || has_ext(&name, "zip")
                    || lower == "conversations.json"
                    || (lower.starts_with("conversations-") && has_ext(&name, "json"))
                {
                    files.push(entry.path());
                }
            }
        }
        subdirs.sort();
        files.sort();
        found.extend(files);
        stack.extend(subdirs.into_iter().rev());
    }
    found
}

fn file_mtime(path: &Path) -> f64 {
    fs::metadata(path)
        .ok()
        .and_then(|m| m.modified().ok())
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map_or(0.0, |d| d.as_secs_f64())
}

fn count_json_array(bytes: &[u8]) -> u64 {
    serde_json::from_slice::<Value>(bytes)
        .ok()
        .and_then(|v| v.as_array().map(|a| a.len() as u64))
        .unwrap_or(0)
}

fn count_zip_conversations(path: &Path) -> u64 {
    let Ok(file) = fs::File::open(path) else { return 0 };
    let Ok(mut archive) = zip::ZipArchive::new(file) else { return 0 };
    let mut count = 0_u64;
    for idx in 0..archive.len() {
        let Ok(mut entry) = archive.by_index(idx) else { continue };
        let Ok(raw_name) = entry.name() else { continue };
        let name = raw_name.to_ascii_lowercase();
        if has_ext(&name, "jsonl") {
            count += 1;
        } else if name.ends_with("conversations.json") {
            let mut bytes = Vec::new();
            if entry.read_to_end(&mut bytes).is_ok() {
                count += count_json_array(&bytes);
            }
        }
    }
    count
}

fn load_claude_zip(path: &Path, mtime: f64) -> Vec<Result<ParsedSession, String>> {
    let file = match fs::File::open(path) {
        Ok(f) => f,
        Err(err) => return vec![Err(format!("{}: {err}", path.display()))],
    };
    let mut archive = match zip::ZipArchive::new(file) {
        Ok(a) => a,
        Err(err) => return vec![Err(format!("{}: invalid zip archive: {err}", path.display()))],
    };
    let mut out = Vec::new();
    for idx in 0..archive.len() {
        let Ok(mut entry) = archive.by_index(idx) else { continue };
        if entry.is_dir() {
            continue;
        }
        let Ok(raw_name) = entry.name() else { continue };
        let entry_name = raw_name.into_owned();
        let lower = entry_name.to_ascii_lowercase();
        let is_jsonl = has_ext(&entry_name, "jsonl");
        if !is_jsonl && !lower.ends_with("conversations.json") {
            continue;
        }
        let mut bytes = Vec::new();
        if let Err(err) = entry.read_to_end(&mut bytes) {
            out.push(Err(format!("{}#{entry_name}: {err}", path.display())));
            continue;
        }
        let base_uri = format!("{}#{entry_name}", path.display());
        if is_jsonl {
            if let Some(res) = parse_claude_jsonl(Path::new(&base_uri), &bytes, mtime) {
                out.push(res);
            }
        } else {
            out.extend(parse_claude_web_json(&base_uri, &bytes, mtime));
        }
    }
    out
}

/// Parses a single Claude Code / Cowork `.jsonl` transcript; `None` if it holds no session turns
/// (e.g. an empty or metadata-only sidecar file).
pub(super) fn parse_claude_jsonl(
    path: &Path,
    bytes: &[u8],
    mtime: f64,
) -> Option<Result<ParsedSession, String>> {
    let text = match std::str::from_utf8(bytes) {
        Ok(s) => s,
        Err(err) => return Some(Err(format!("{}: invalid UTF-8: {err}", path.display()))),
    };
    let mut state = JsonlState::from_path(path);
    for raw_line in text.lines() {
        let line = raw_line.trim();
        if line.is_empty() {
            continue;
        }
        let Ok(Value::Object(obj)) = serde_json::from_str::<Value>(line) else { continue };
        state.consume_event(&obj);
    }
    if state.turns.is_empty() {
        return None;
    }
    Some(Ok(state.finish(path, bytes, mtime)))
}

struct JsonlState {
    uri: String,
    stem: String,
    subagent_parent_dir: Option<String>,
    raw_session_id: Option<String>,
    agent_id: Option<String>,
    is_sidechain: bool,
    surface: String,
    title: Option<String>,
    summary: Option<String>,
    workspace_path: Option<String>,
    git_branch: Option<String>,
    model_counts: HashMap<String, usize>,
    started_at: Option<i64>,
    updated_at: Option<i64>,
    input_tokens: i64,
    output_tokens: i64,
    cache_read_tokens: i64,
    has_tokens: bool,
    turns: Vec<SessionTurnRecord>,
    tool_calls: Vec<SessionToolCallRecord>,
    pending_calls: HashMap<String, usize>,
    artifacts: Vec<SessionArtifactRecord>,
    companions: Vec<CompanionDocument>,
}

impl JsonlState {
    fn from_path(path: &Path) -> Self {
        let uri = path.display().to_string();
        let stem = path.file_stem().map_or_else(|| "session".into(), |s| s.to_string_lossy().into_owned());
        let parent_name = path.parent().and_then(|p| p.file_name()).map(|n| n.to_string_lossy().into_owned());
        let subagent_parent_dir = if parent_name.as_deref() == Some("subagents") {
            path.parent()
                .and_then(Path::parent)
                .and_then(|p| p.file_name())
                .map(|n| n.to_string_lossy().into_owned())
        } else {
            None
        };
        let lower_uri = uri.to_ascii_lowercase();
        let surface = if lower_uri.contains("cowork") || lower_uri.contains("claude desktop") {
            "claude_cowork".to_owned()
        } else {
            "claude_code".to_owned()
        };
        Self {
            uri,
            stem,
            subagent_parent_dir,
            raw_session_id: None,
            agent_id: None,
            is_sidechain: false,
            surface,
            title: None,
            summary: None,
            workspace_path: None,
            git_branch: None,
            model_counts: HashMap::new(),
            started_at: None,
            updated_at: None,
            input_tokens: 0,
            output_tokens: 0,
            cache_read_tokens: 0,
            has_tokens: false,
            turns: Vec::new(),
            tool_calls: Vec::new(),
            pending_calls: HashMap::new(),
            artifacts: Vec::new(),
            companions: Vec::new(),
        }
    }

    fn consume_event(&mut self, obj: &Map<String, Value>) {
        if self.raw_session_id.is_none() {
            self.raw_session_id = obj.get("sessionId").and_then(Value::as_str).map(clean_str);
        }
        if self.agent_id.is_none() {
            self.agent_id = obj.get("agentId").and_then(Value::as_str).map(clean_str);
        }
        if obj.get("isSidechain").and_then(Value::as_bool) == Some(true) {
            self.is_sidechain = true;
        }
        if let Some(ep) = obj.get("entrypoint").and_then(Value::as_str)
            && ep.to_ascii_lowercase().contains("cowork")
        {
            "claude_cowork".clone_into(&mut self.surface);
        }
        if self.workspace_path.is_none() {
            self.workspace_path = clean_opt(obj.get("cwd").and_then(Value::as_str), true);
        }
        if self.git_branch.is_none() {
            self.git_branch =
                clean_opt(obj.get("gitBranch").and_then(Value::as_str), true).filter(|b| b != "HEAD");
        }
        let ts = obj.get("timestamp").and_then(parse_timestamp_micros);
        if let Some(t) = ts {
            self.started_at = Some(self.started_at.map_or(t, |cur| cur.min(t)));
            self.updated_at = Some(self.updated_at.map_or(t, |cur| cur.max(t)));
        }
        let kind = obj.get("type").and_then(Value::as_str).unwrap_or_default();
        match kind {
            "summary" => {
                if let Some(s) = clean_opt(obj.get("summary").and_then(Value::as_str), true) {
                    self.summary = Some(s);
                }
            }
            "custom-title" => {
                if let Some(t) = clean_opt(obj.get("customTitle").and_then(Value::as_str), true) {
                    self.title = Some(t);
                }
            }
            "user" | "assistant" => self.consume_message_event(kind, obj, ts),
            _ => {}
        }
    }

    fn consume_message_event(&mut self, kind: &str, obj: &Map<String, Value>, ts: Option<i64>) {
        if obj.get("isMeta").and_then(Value::as_bool) == Some(true) {
            return;
        }
        let Some(msg) = obj.get("message").and_then(Value::as_object) else { return };
        let ord = i32::try_from(self.turns.len()).unwrap_or(i32::MAX);
        let turn_ext_id = obj
            .get("uuid")
            .and_then(Value::as_str)
            .map(clean_str)
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| format!("turn-{ord}"));
        let parent_ext = clean_opt(obj.get("parentUuid").and_then(Value::as_str), true);
        let model = clean_opt(msg.get("model").and_then(Value::as_str), true)
            .filter(|m| !m.starts_with('<'));
        if let Some(m) = &model {
            *self.model_counts.entry(m.clone()).or_insert(0) += 1;
        }
        let (in_tok, out_tok, cache_tok) = extract_usage(msg.get("usage"));
        if in_tok.is_some() || out_tok.is_some() || cache_tok.is_some() {
            self.has_tokens = true;
            self.input_tokens += i64::from(in_tok.unwrap_or(0));
            self.output_tokens += i64::from(out_tok.unwrap_or(0));
            self.cache_read_tokens += i64::from(cache_tok.unwrap_or(0));
        }

        let extracted = extract_message_blocks(msg.get("content"), &turn_ext_id, &self.uri, ts);
        for res in extracted.tool_results {
            if let Some(&idx) = self.pending_calls.get(&res.tool_use_id)
                && let Some(call) = self.tool_calls.get_mut(idx)
            {
                call.result_turn_external_id = Some(turn_ext_id.clone());
                if res.is_error {
                    "error".clone_into(&mut call.status);
                }
                call.output_preview = res.preview;
                call.output_bytes = res.bytes;
            }
        }
        for call in extracted.tool_calls {
            let idx = self.tool_calls.len();
            if let Some(call_id) = &call.external_call_id {
                self.pending_calls.insert(call_id.clone(), idx);
            }
            self.tool_calls.push(call);
        }
        self.artifacts.extend(extracted.artifacts);
        self.companions.extend(extracted.companions);

        let is_tool_only = kind == "user" && extracted.content.is_none() && extracted.had_tool_result;
        let role = if is_tool_only {
            "tool"
        } else if kind == "user" {
            "user"
        } else {
            "assistant"
        };
        let direction = match role {
            "user" => Some("sent".to_owned()),
            "assistant" => Some("received".to_owned()),
            _ => None,
        };
        self.turns.push(SessionTurnRecord {
            external_id: turn_ext_id,
            parent_external_id: parent_ext,
            ord,
            active_ord: None,
            role: role.to_owned(),
            direction,
            is_self: role == "user",
            model,
            content: extracted.content,
            thinking: extracted.thinking,
            input_tokens: in_tok,
            output_tokens: out_tok,
            cache_read_tokens: cache_tok,
            created_at_micros: ts,
            meta: Map::new(),
        });
    }

    fn finish(mut self, path: &Path, bytes: &[u8], mtime: f64) -> ParsedSession {
        assign_active_lineage(&mut self.turns);
        let (external_id, parent_external_id) = self.resolve_ids();
        let primary_model = self
            .model_counts
            .into_iter()
            .max_by_key(|(_, count)| *count)
            .map(|(model, _)| model);
        let explicit_title = self.title.as_deref().or(self.summary.as_deref());
        let title = derive_title(explicit_title, &self.turns, &external_id);
        let workspace_paths = self.workspace_path.iter().cloned().collect();
        let updated = self.updated_at.or_else(|| {
            #[allow(clippy::cast_possible_truncation)]
            let m = (mtime * 1_000_000.0) as i64;
            (m > 0).then_some(m)
        });
        let effective_mtime = updated.map_or(mtime, |u| {
            #[allow(clippy::cast_precision_loss)]
            let secs = u as f64 / 1_000_000.0;
            secs
        });
        let record = SessionRecord {
            provider: CLAUDE_KIND.to_owned(),
            surface: self.surface,
            external_id,
            parent_external_id,
            title: Some(title),
            summary: self.summary,
            workspace_path: self.workspace_path,
            workspace_paths,
            git_branch: self.git_branch,
            git_commit: None,
            primary_model,
            started_at_micros: self.started_at,
            updated_at_micros: updated,
            input_tokens: self.has_tokens.then_some(self.input_tokens),
            output_tokens: self.has_tokens.then_some(self.output_tokens),
            cache_read_tokens: self.has_tokens.then_some(self.cache_read_tokens),
            origin_uri: Some(path.display().to_string()),
            meta: Map::new(),
            turns: self.turns,
            tool_calls: self.tool_calls,
            artifacts: self.artifacts,
        };
        ParsedSession {
            uri: self.uri,
            source_sha256: hex_digest(bytes),
            mtime: effective_mtime,
            record,
            companions: self.companions,
        }
    }

    fn resolve_ids(&self) -> (String, Option<String>) {
        if let Some(parent) = &self.subagent_parent_dir {
            let agent = self.agent_id.as_deref().unwrap_or(&self.stem);
            return (format!("{parent}:{agent}"), Some(parent.clone()));
        }
        if self.is_sidechain
            && let (Some(parent), Some(agent)) = (&self.raw_session_id, &self.agent_id)
        {
            return (format!("{parent}:{agent}"), Some(parent.clone()));
        }
        let ext = self.raw_session_id.clone().filter(|s| !s.is_empty()).unwrap_or_else(|| self.stem.clone());
        (ext, None)
    }
}

fn extract_usage(usage: Option<&Value>) -> (Option<i32>, Option<i32>, Option<i32>) {
    let Some(obj) = usage.and_then(Value::as_object) else { return (None, None, None) };
    let get = |k: &str| obj.get(k).and_then(Value::as_i64).and_then(|n| i32::try_from(n).ok());
    (get("input_tokens"), get("output_tokens"), get("cache_read_input_tokens"))
}

struct ToolResultInfo {
    tool_use_id: String,
    is_error: bool,
    preview: Option<String>,
    bytes: Option<i32>,
}

struct ExtractedBlocks {
    content: Option<String>,
    thinking: Option<String>,
    tool_calls: Vec<SessionToolCallRecord>,
    tool_results: Vec<ToolResultInfo>,
    artifacts: Vec<SessionArtifactRecord>,
    companions: Vec<CompanionDocument>,
    had_tool_result: bool,
}

fn extract_message_blocks(
    raw_content: Option<&Value>,
    turn_ext_id: &str,
    session_uri: &str,
    ts: Option<i64>,
) -> ExtractedBlocks {
    let mut acc = BlockAccumulator::default();
    match raw_content {
        Some(Value::String(s)) => acc.push_text(s, turn_ext_id, session_uri, ts),
        Some(Value::Array(blocks)) => {
            for block in blocks {
                if let Some(b) = block.as_object() {
                    acc.consume_block(b, turn_ext_id, session_uri, ts);
                }
            }
        }
        _ => {}
    }
    acc.finish()
}

#[derive(Default)]
struct BlockAccumulator {
    text_parts: Vec<String>,
    thinking_parts: Vec<String>,
    tool_calls: Vec<SessionToolCallRecord>,
    tool_results: Vec<ToolResultInfo>,
    artifacts: Vec<SessionArtifactRecord>,
    companions: Vec<CompanionDocument>,
    had_tool_result: bool,
}

impl BlockAccumulator {
    fn push_text(&mut self, raw: &str, turn_ext_id: &str, session_uri: &str, ts: Option<i64>) {
        let cleaned = strip_internal_command_tags(&clean_str(raw));
        if !cleaned.trim().is_empty() {
            extract_ant_artifacts(
                &cleaned,
                turn_ext_id,
                session_uri,
                ts,
                &mut self.artifacts,
                &mut self.companions,
            );
            self.text_parts.push(cleaned);
        }
    }

    fn consume_block(
        &mut self,
        b: &Map<String, Value>,
        turn_ext_id: &str,
        session_uri: &str,
        ts: Option<i64>,
    ) {
        match b.get("type").and_then(Value::as_str).unwrap_or_default() {
            "text" => {
                if let Some(t) = b.get("text").and_then(Value::as_str) {
                    self.push_text(t, turn_ext_id, session_uri, ts);
                }
            }
            "thinking" => {
                if let Some(th) = clean_opt(b.get("thinking").and_then(Value::as_str), true) {
                    self.thinking_parts.push(th);
                }
            }
            "tool_use" => {
                let name = clean_opt(b.get("name").and_then(Value::as_str), true)
                    .unwrap_or_else(|| "tool".to_owned());
                let mut args = b.get("input").and_then(Value::as_object).cloned().unwrap_or_default();
                clean_json_map(&mut args);
                let (tool_kind, target_path, command) = classify_tool(&name, &args);
                let ord = i32::try_from(self.tool_calls.len()).unwrap_or(i32::MAX);
                self.tool_calls.push(SessionToolCallRecord {
                    turn_external_id: turn_ext_id.to_owned(),
                    result_turn_external_id: None,
                    ord,
                    external_call_id: clean_opt(b.get("id").and_then(Value::as_str), true),
                    tool_name: name,
                    tool_kind,
                    target_path,
                    command,
                    status: "ok".to_owned(),
                    arguments: args,
                    output_preview: None,
                    output_bytes: None,
                    created_at_micros: ts,
                });
            }
            "tool_result" => {
                self.had_tool_result = true;
                if let Some(id) = clean_opt(b.get("tool_use_id").and_then(Value::as_str), true) {
                    let out_text = flatten_tool_result_content(b.get("content"));
                    let (preview, bytes) = preview_output(&out_text);
                    self.tool_results.push(ToolResultInfo {
                        tool_use_id: id,
                        is_error: b.get("is_error").and_then(Value::as_bool) == Some(true),
                        preview,
                        bytes,
                    });
                }
            }
            _ => {}
        }
    }

    fn finish(self) -> ExtractedBlocks {
        ExtractedBlocks {
            content: (!self.text_parts.is_empty()).then(|| self.text_parts.join("\n\n")),
            thinking: (!self.thinking_parts.is_empty()).then(|| self.thinking_parts.join("\n\n")),
            tool_calls: self.tool_calls,
            tool_results: self.tool_results,
            artifacts: self.artifacts,
            companions: self.companions,
            had_tool_result: self.had_tool_result,
        }
    }
}

fn strip_internal_command_tags(text: &str) -> String {
    if text.trim_start().starts_with("<local-command-caveat>") {
        return String::new();
    }
    text.to_owned()
}

fn flatten_tool_result_content(value: Option<&Value>) -> String {
    match value {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Array(items)) => items
            .iter()
            .filter_map(|item| item.get("text").and_then(Value::as_str))
            .collect::<Vec<_>>()
            .join("\n"),
        Some(other) => other.to_string(),
        None => String::new(),
    }
}

/// Extracts `<antArtifact identifier="..." type="..." title="...">...</antArtifact>` blocks.
fn extract_ant_artifacts(
    text: &str,
    turn_ext_id: &str,
    session_uri: &str,
    ts: Option<i64>,
    artifacts: &mut Vec<SessionArtifactRecord>,
    companions: &mut Vec<CompanionDocument>,
) {
    let mut rest = text;
    while let Some(start) = rest.find("<antArtifact") {
        let after_tag_open = &rest[start..];
        let Some(gt) = after_tag_open.find('>') else { break };
        let header = &after_tag_open[..gt];
        let body_and_more = &after_tag_open[gt + 1..];
        let Some(end) = body_and_more.find("</antArtifact>") else { break };
        let body = body_and_more[..end].trim();
        rest = &body_and_more[end + "</antArtifact>".len()..];

        let identifier = xml_attr(header, "identifier")
            .unwrap_or_else(|| format!("artifact-{}-{}", turn_ext_id, artifacts.len()));
        let mime = xml_attr(header, "type");
        let title = xml_attr(header, "title");
        let is_code = mime.as_deref().is_some_and(|m| m.contains("code") || m.contains("html"));
        let kind = if is_code { "code" } else { "document" };
        let sha = hex_digest(body.as_bytes());
        let artifact_uri = format!("{session_uri}#artifact:{identifier}");
        artifacts.push(SessionArtifactRecord {
            turn_external_id: Some(turn_ext_id.to_owned()),
            external_id: identifier.clone(),
            kind: kind.to_owned(),
            title: title.clone(),
            mime: mime.clone(),
            uri: Some(artifact_uri.clone()),
            content_sha256: Some(sha.clone()),
            meta: Map::new(),
        });
        if body.len() >= 32 {
            #[allow(clippy::cast_precision_loss)]
            let modified = ts.map_or(0.0, |t| t as f64 / 1_000_000.0);
            companions.push(CompanionDocument {
                artifact_external_id: identifier,
                uri: artifact_uri,
                title,
                text: body.to_owned(),
                extension: if is_code { ".txt".into() } else { ".md".into() },
                mtime: modified,
                source_sha256: sha,
                meta: Map::new(),
            });
        }
    }
}

fn xml_attr(tag_header: &str, attr: &str) -> Option<String> {
    let needle = format!("{attr}=\"");
    let start = tag_header.find(&needle)? + needle.len();
    let end = tag_header[start..].find('"')?;
    clean_opt(Some(&tag_header[start..start + end]), true)
}

/// Marks `active_ord = 0, 1, ...` along the active branch ending at the last turn.
pub(super) fn assign_active_lineage(turns: &mut [SessionTurnRecord]) {
    if turns.is_empty() {
        return;
    }
    let id_to_idx: HashMap<&str, usize> =
        turns.iter().enumerate().map(|(i, t)| (t.external_id.as_str(), i)).collect();
    let has_valid_parents = turns
        .iter()
        .any(|t| t.parent_external_id.as_deref().is_some_and(|p| id_to_idx.contains_key(p)));

    let active_indices: HashSet<usize> = if has_valid_parents {
        let mut set = HashSet::new();
        let mut cur = Some(turns.len() - 1);
        while let Some(idx) = cur {
            if !set.insert(idx) {
                break;
            }
            cur = turns[idx]
                .parent_external_id
                .as_deref()
                .and_then(|parent| id_to_idx.get(parent).copied());
        }
        set
    } else {
        (0..turns.len()).collect()
    };

    let mut active_ord = 0_i32;
    for (idx, turn) in turns.iter_mut().enumerate() {
        let visible_prose = matches!(turn.role.as_str(), "user" | "assistant")
            && turn.content.as_deref().is_some_and(|c| !c.trim().is_empty());
        if active_indices.contains(&idx) && visible_prose {
            turn.active_ord = Some(active_ord);
            active_ord += 1;
        } else {
            turn.active_ord = None;
        }
    }
}

/// Parses Claude Web's `conversations.json` array.
pub(super) fn parse_claude_web_json(
    base_uri: &str,
    bytes: &[u8],
    fallback_mtime: f64,
) -> Vec<Result<ParsedSession, String>> {
    let root: Value = match serde_json::from_slice(bytes) {
        Ok(v) => v,
        Err(err) => return vec![Err(format!("{base_uri}: invalid JSON: {err}"))],
    };
    let Some(items) = root.as_array() else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for item in items {
        let Some(conv) = item.as_object() else { continue };
        if let Some(parsed) = parse_one_claude_web_conversation(base_uri, conv, fallback_mtime) {
            out.push(Ok(parsed));
        }
    }
    out
}

fn parse_one_claude_web_conversation(
    base_uri: &str,
    conv: &Map<String, Value>,
    fallback_mtime: f64,
) -> Option<ParsedSession> {
    let ext_id = clean_opt(conv.get("uuid").and_then(Value::as_str), true)?;
    let messages = conv.get("chat_messages").and_then(Value::as_array)?;
    if messages.is_empty() {
        return None;
    }
    let session_uri = format!("{base_uri}#{ext_id}");
    let created = conv.get("created_at").and_then(parse_timestamp_micros);
    let updated = conv.get("updated_at").and_then(parse_timestamp_micros).or(created);
    let mut state = WebConvState::default();
    for msg_val in messages {
        if let Some(msg) = msg_val.as_object() {
            state.consume_message(msg, &session_uri);
        }
    }
    if state.turns.is_empty() {
        return None;
    }
    assign_active_lineage(&mut state.turns);
    let raw_name = clean_opt(conv.get("name").and_then(Value::as_str), true);
    let summary = clean_opt(conv.get("summary").and_then(Value::as_str), true);
    let title = derive_title(raw_name.as_deref(), &state.turns, &ext_id);
    let serialized = serde_json::to_vec(conv).unwrap_or_default();
    let mtime = updated.map_or(fallback_mtime, |u| {
        #[allow(clippy::cast_precision_loss)]
        let s = u as f64 / 1_000_000.0;
        s
    });
    Some(ParsedSession {
        uri: session_uri,
        source_sha256: hex_digest(&serialized),
        mtime,
        record: SessionRecord {
            provider: CLAUDE_KIND.to_owned(),
            surface: "claude_web".to_owned(),
            external_id: ext_id,
            parent_external_id: None,
            title: Some(title),
            summary,
            workspace_path: None,
            workspace_paths: Vec::new(),
            git_branch: None,
            git_commit: None,
            primary_model: clean_opt(conv.get("model").and_then(Value::as_str), true),
            started_at_micros: created,
            updated_at_micros: updated,
            input_tokens: None,
            output_tokens: None,
            cache_read_tokens: None,
            origin_uri: Some(base_uri.to_owned()),
            meta: Map::new(),
            turns: state.turns,
            tool_calls: state.tool_calls,
            artifacts: state.artifacts,
        },
        companions: state.companions,
    })
}

#[derive(Default)]
struct WebConvState {
    turns: Vec<SessionTurnRecord>,
    tool_calls: Vec<SessionToolCallRecord>,
    pending_calls: HashMap<String, usize>,
    artifacts: Vec<SessionArtifactRecord>,
    companions: Vec<CompanionDocument>,
    prev_turn_id: Option<String>,
}

impl WebConvState {
    fn consume_message(&mut self, msg: &Map<String, Value>, session_uri: &str) {
        let ord = i32::try_from(self.turns.len()).unwrap_or(i32::MAX);
        let turn_id = clean_opt(msg.get("uuid").and_then(Value::as_str), true)
            .unwrap_or_else(|| format!("msg-{ord}"));
        let sender = msg.get("sender").and_then(Value::as_str).unwrap_or("assistant");
        let is_human = sender == "human" || sender == "user";
        let ts = msg.get("created_at").and_then(parse_timestamp_micros);

        let mut blocks = extract_message_blocks(msg.get("content"), &turn_id, session_uri, ts);
        if blocks.content.is_none()
            && let Some(text) = clean_opt(msg.get("text").and_then(Value::as_str), true)
        {
            extract_ant_artifacts(&text, &turn_id, session_uri, ts, &mut blocks.artifacts, &mut blocks.companions);
            blocks.content = Some(text);
        }
        for res in blocks.tool_results {
            if let Some(&idx) = self.pending_calls.get(&res.tool_use_id)
                && let Some(call) = self.tool_calls.get_mut(idx)
            {
                call.result_turn_external_id = Some(turn_id.clone());
                if res.is_error {
                    "error".clone_into(&mut call.status);
                }
                call.output_preview = res.preview;
                call.output_bytes = res.bytes;
            }
        }
        for call in blocks.tool_calls {
            let idx = self.tool_calls.len();
            if let Some(cid) = &call.external_call_id {
                self.pending_calls.insert(cid.clone(), idx);
            }
            self.tool_calls.push(call);
        }
        self.artifacts.extend(blocks.artifacts);
        self.companions.extend(blocks.companions);
        collect_web_attachments(msg, &turn_id, &mut self.artifacts);

        self.turns.push(SessionTurnRecord {
            external_id: turn_id.clone(),
            parent_external_id: self.prev_turn_id.replace(turn_id),
            ord,
            active_ord: None,
            role: if is_human { "user".into() } else { "assistant".into() },
            direction: Some(if is_human { "sent".into() } else { "received".into() }),
            is_self: is_human,
            model: clean_opt(msg.get("model").and_then(Value::as_str), true),
            content: blocks.content,
            thinking: blocks.thinking,
            input_tokens: None,
            output_tokens: None,
            cache_read_tokens: None,
            created_at_micros: ts,
            meta: Map::new(),
        });
    }
}

fn collect_web_attachments(
    msg: &Map<String, Value>,
    turn_id: &str,
    artifacts: &mut Vec<SessionArtifactRecord>,
) {
    for key in ["attachments", "files"] {
        let Some(arr) = msg.get(key).and_then(Value::as_array) else { continue };
        for (i, item) in arr.iter().enumerate() {
            let Some(obj) = item.as_object() else { continue };
            let name = clean_opt(
                obj.get("file_name").or_else(|| obj.get("name")).and_then(Value::as_str),
                true,
            );
            let ext_id = clean_opt(obj.get("id").or_else(|| obj.get("uuid")).and_then(Value::as_str), true)
                .unwrap_or_else(|| format!("{turn_id}-{key}-{i}"));
            let mime = clean_opt(obj.get("file_type").and_then(Value::as_str), true);
            let is_image = mime.as_deref().is_some_and(|m| m.starts_with("image/"));
            artifacts.push(SessionArtifactRecord {
                turn_external_id: Some(turn_id.to_owned()),
                external_id: ext_id,
                kind: if is_image { "image".into() } else { "attachment".into() },
                title: name,
                mime,
                uri: None,
                content_sha256: None,
                meta: Map::new(),
            });
        }
    }
}

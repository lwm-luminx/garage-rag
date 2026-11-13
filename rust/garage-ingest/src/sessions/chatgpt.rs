//! Parser and scanner helpers for `chatgpt` session sources:
//! - Local OpenAI Codex `.jsonl` session transcripts (`~/.codex/sessions/**/*.jsonl`,
//!   `~/.codex/archived_sessions/**/*.jsonl`).
//! - ChatGPT Web data exports (`conversations.json`, `conversations-*.json`, or `.zip` archives),
//!   preserving the full `mapping` edit/regeneration tree in `session_turns` while synthesizing
//!   only the `current_node` active lineage into `documents` and `chunks`.

use std::collections::{HashMap, HashSet, VecDeque};
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};

use serde_json::{Map, Value};

use crate::sha256::hex_digest;

use super::types::{
    CHATGPT_KIND, CompanionDocument, ParsedSession, SessionArtifactRecord, SessionRecord, SessionToolCallRecord,
    SessionTurnRecord, classify_tool, clean_json_map, clean_opt, clean_str, derive_title, has_ext,
    parse_timestamp_micros, path_has_ext, preview_output,
};

const SKIP_DIRS: &[&str] = &[
    "cache",
    "log",
    "logs",
    "memories",
    "node_modules",
    "plugins",
    "rules",
    "shell_snapshots",
    "skills",
    "sqlite",
    "tmp",
    "vendor_imports",
];

/// Counts sessions under `root` for `scan_source`.
pub(super) fn count_chatgpt_items(root: &Path, details: &mut Map<String, Value>, mut tick: impl FnMut(u64)) -> u64 {
    let files = collect_chatgpt_paths(root);
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

/// Discovers and parses every Codex / ChatGPT session under `root`.
pub(super) fn load_chatgpt_sessions(root: &Path) -> Vec<Result<ParsedSession, String>> {
    let mut out = Vec::new();
    for path in collect_chatgpt_paths(root) {
        let mtime = file_mtime(&path);
        if path_has_ext(&path, "jsonl") {
            match fs::read(&path) {
                Ok(bytes) => {
                    if let Some(res) = parse_codex_jsonl(&path, &bytes, mtime) {
                        out.push(res);
                    }
                }
                Err(err) => out.push(Err(format!("{}: {err}", path.display()))),
            }
        } else if path_has_ext(&path, "json") {
            match fs::read(&path) {
                Ok(bytes) => out.extend(parse_chatgpt_web_json(&path.display().to_string(), &bytes, mtime)),
                Err(err) => out.push(Err(format!("{}: {err}", path.display()))),
            }
        } else if path_has_ext(&path, "zip") {
            out.extend(load_chatgpt_zip(&path, mtime));
        }
    }
    out
}

fn collect_chatgpt_paths(root: &Path) -> Vec<PathBuf> {
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
                if lower == "history.jsonl" {
                    continue;
                }
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
    serde_json::from_slice::<Value>(bytes).ok().and_then(|v| v.as_array().map(|a| a.len() as u64)).unwrap_or(0)
}

fn is_conversations_entry(lower_name: &str) -> bool {
    let base = lower_name.rsplit('/').next().unwrap_or(lower_name);
    base == "conversations.json" || (base.starts_with("conversations-") && has_ext(base, "json"))
}

fn count_zip_conversations(path: &Path) -> u64 {
    let Ok(file) = fs::File::open(path) else { return 0 };
    let Ok(mut archive) = zip::ZipArchive::new(file) else { return 0 };
    let mut count = 0_u64;
    for idx in 0..archive.len() {
        let Ok(mut entry) = archive.by_index(idx) else { continue };
        let Ok(raw_name) = entry.name() else { continue };
        let lower = raw_name.to_ascii_lowercase();
        if has_ext(&lower, "jsonl") && !lower.ends_with("history.jsonl") {
            count += 1;
        } else if is_conversations_entry(&lower) {
            let mut bytes = Vec::new();
            if entry.read_to_end(&mut bytes).is_ok() {
                count += count_json_array(&bytes);
            }
        }
    }
    count
}

fn load_chatgpt_zip(path: &Path, mtime: f64) -> Vec<Result<ParsedSession, String>> {
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
        let is_jsonl = has_ext(&entry_name, "jsonl") && !lower.ends_with("history.jsonl");
        if !is_jsonl && !is_conversations_entry(&lower) {
            continue;
        }
        let mut bytes = Vec::new();
        if let Err(err) = entry.read_to_end(&mut bytes) {
            out.push(Err(format!("{}#{entry_name}: {err}", path.display())));
            continue;
        }
        let base_uri = format!("{}#{entry_name}", path.display());
        if is_jsonl {
            if let Some(res) = parse_codex_jsonl(Path::new(&base_uri), &bytes, mtime) {
                out.push(res);
            }
        } else {
            out.extend(parse_chatgpt_web_json(&base_uri, &bytes, mtime));
        }
    }
    out
}

// ---------------------------------------------------------------------------
// Local Codex `.jsonl` transcripts
// ---------------------------------------------------------------------------

pub(super) fn parse_codex_jsonl(path: &Path, bytes: &[u8], mtime: f64) -> Option<Result<ParsedSession, String>> {
    let text = match std::str::from_utf8(bytes) {
        Ok(s) => s,
        Err(err) => return Some(Err(format!("{}: invalid UTF-8: {err}", path.display()))),
    };
    let mut state = CodexState::from_path(path);
    for raw_line in text.lines() {
        let line = raw_line.trim();
        if line.is_empty() {
            continue;
        }
        let Ok(Value::Object(obj)) = serde_json::from_str::<Value>(line) else { continue };
        state.consume_line(&obj);
    }
    if state.turns.is_empty() {
        return None;
    }
    Some(Ok(state.finish(path, bytes, mtime)))
}

struct CodexState {
    uri: String,
    stem: String,
    session_id: Option<String>,
    parent_external_id: Option<String>,
    workspace_path: Option<String>,
    workspace_paths: Vec<String>,
    git_branch: Option<String>,
    git_commit: Option<String>,
    current_model: Option<String>,
    primary_model: Option<String>,
    summary: Option<String>,
    started_at: Option<i64>,
    updated_at: Option<i64>,
    input_tokens: Option<i64>,
    output_tokens: Option<i64>,
    cache_read_tokens: Option<i64>,
    pending_thinking: Vec<String>,
    last_assistant_turn_id: Option<String>,
    call_counts_per_turn: HashMap<String, i32>,
    pending_calls: HashMap<String, usize>,
    turns: Vec<SessionTurnRecord>,
    tool_calls: Vec<SessionToolCallRecord>,
    prev_turn_id: Option<String>,
}

impl CodexState {
    fn from_path(path: &Path) -> Self {
        let stem = path.file_stem().map_or_else(|| "codex".into(), |s| s.to_string_lossy().into_owned());
        Self {
            uri: path.display().to_string(),
            stem,
            session_id: None,
            parent_external_id: None,
            workspace_path: None,
            workspace_paths: Vec::new(),
            git_branch: None,
            git_commit: None,
            current_model: None,
            primary_model: None,
            summary: None,
            started_at: None,
            updated_at: None,
            input_tokens: None,
            output_tokens: None,
            cache_read_tokens: None,
            pending_thinking: Vec::new(),
            last_assistant_turn_id: None,
            call_counts_per_turn: HashMap::new(),
            pending_calls: HashMap::new(),
            turns: Vec::new(),
            tool_calls: Vec::new(),
            prev_turn_id: None,
        }
    }

    fn consume_line(&mut self, obj: &Map<String, Value>) {
        let ts = obj.get("timestamp").and_then(parse_timestamp_micros);
        if let Some(t) = ts {
            self.started_at = Some(self.started_at.map_or(t, |cur| cur.min(t)));
            self.updated_at = Some(self.updated_at.map_or(t, |cur| cur.max(t)));
        }
        let kind = obj.get("type").and_then(Value::as_str).unwrap_or_default();
        let payload = obj.get("payload").and_then(Value::as_object);
        match kind {
            "session_meta" => {
                if let Some(p) = payload {
                    self.consume_meta(p);
                }
            }
            "turn_context" => {
                if let Some(p) = payload {
                    if let Some(m) = clean_opt(p.get("model").and_then(Value::as_str), true) {
                        if self.primary_model.is_none() {
                            self.primary_model = Some(m.clone());
                        }
                        self.current_model = Some(m);
                    }
                    if self.workspace_path.is_none() {
                        self.workspace_path = clean_opt(p.get("cwd").and_then(Value::as_str), true);
                    }
                }
            }
            "event_msg" | "token_usage_record" => {
                if let Some(p) = payload {
                    self.consume_tokens(p);
                }
            }
            "response_item" => {
                if let Some(p) = payload {
                    self.consume_response_item(p, ts);
                }
            }
            _ => {}
        }
    }

    fn consume_meta(&mut self, p: &Map<String, Value>) {
        self.session_id = clean_opt(p.get("id").or_else(|| p.get("session_id")).and_then(Value::as_str), true);
        self.parent_external_id = clean_opt(p.get("forked_from_id").and_then(Value::as_str), true);
        if let Some(cwd) = clean_opt(p.get("cwd").and_then(Value::as_str), true) {
            if !self.workspace_paths.contains(&cwd) {
                self.workspace_paths.push(cwd.clone());
            }
            self.workspace_path = Some(cwd);
        }
        if let Some(roots) = p.get("runtime_workspace_roots").and_then(Value::as_array) {
            for r in roots.iter().filter_map(Value::as_str) {
                let cleaned = clean_str(r);
                if !cleaned.is_empty() && !self.workspace_paths.contains(&cleaned) {
                    self.workspace_paths.push(cleaned);
                }
            }
        }
        if let Some(git) = p.get("git").and_then(Value::as_object) {
            self.git_branch = clean_opt(git.get("branch").and_then(Value::as_str), true);
            self.git_commit = clean_opt(git.get("commit_hash").and_then(Value::as_str), true);
        }
        if let Some(ts) = p.get("timestamp").and_then(parse_timestamp_micros) {
            self.started_at = Some(self.started_at.map_or(ts, |cur| cur.min(ts)));
        }
    }

    fn consume_tokens(&mut self, p: &Map<String, Value>) {
        let usage = p
            .get("info")
            .and_then(|i| i.get("total_token_usage"))
            .or_else(|| p.get("thread_token_usage"))
            .or_else(|| p.get("usage"))
            .and_then(Value::as_object);
        let Some(u) = usage else { return };
        if let Some(v) = u.get("input_tokens").and_then(Value::as_i64) {
            self.input_tokens = Some(v);
        }
        if let Some(v) = u.get("output_tokens").and_then(Value::as_i64) {
            self.output_tokens = Some(v);
        }
        if let Some(v) =
            u.get("cached_input_tokens").or_else(|| u.get("cache_read_input_tokens")).and_then(Value::as_i64)
        {
            self.cache_read_tokens = Some(v);
        }
    }

    fn consume_response_item(&mut self, p: &Map<String, Value>, ts: Option<i64>) {
        let item_type = p.get("type").and_then(Value::as_str).unwrap_or_default();
        match item_type {
            "reasoning" => {
                for key in ["summary", "content"] {
                    if let Some(arr) = p.get(key).and_then(Value::as_array) {
                        for entry in arr {
                            if let Some(t) = clean_opt(entry.get("text").and_then(Value::as_str), true) {
                                self.pending_thinking.push(t);
                            }
                        }
                    }
                }
            }
            "message" => self.consume_codex_message(p, ts),
            "function_call" | "custom_tool_call" | "local_shell_call" => self.consume_codex_call(item_type, p, ts),
            "function_call_output" | "custom_tool_call_output" | "local_shell_call_output" => {
                self.consume_codex_call_output(p, ts);
            }
            _ => {}
        }
    }

    fn consume_codex_message(&mut self, p: &Map<String, Value>, ts: Option<i64>) {
        let raw_role = p.get("role").and_then(Value::as_str).unwrap_or("assistant");
        let text = extract_codex_message_text(p.get("content"));
        let is_env_boilerplate = raw_role == "user"
            && text.as_deref().is_some_and(|t| {
                let trimmed = t.trim();
                trimmed.starts_with("<environment_context>") && trimmed.ends_with("</environment_context>")
            });
        let role = match raw_role {
            "user" if !is_env_boilerplate => "user",
            "assistant" => "assistant",
            _ => "system",
        };
        let thinking = if role == "assistant" && !self.pending_thinking.is_empty() {
            Some(std::mem::take(&mut self.pending_thinking).join("\n\n"))
        } else {
            None
        };
        if text.is_none() && thinking.is_none() {
            return;
        }
        let ord = i32::try_from(self.turns.len()).unwrap_or(i32::MAX);
        let turn_id = clean_opt(p.get("id").and_then(Value::as_str), true).unwrap_or_else(|| format!("turn-{ord}"));
        let direction = match role {
            "user" => Some("sent".to_owned()),
            "assistant" => Some("received".to_owned()),
            _ => None,
        };
        if role == "assistant" {
            self.last_assistant_turn_id = Some(turn_id.clone());
        } else if role == "user" {
            self.last_assistant_turn_id = None;
        }
        self.turns.push(SessionTurnRecord {
            external_id: turn_id.clone(),
            parent_external_id: self.prev_turn_id.replace(turn_id),
            ord,
            active_ord: None,
            role: role.to_owned(),
            direction,
            is_self: role == "user",
            model: (role == "assistant").then(|| self.current_model.clone()).flatten(),
            content: text,
            thinking,
            input_tokens: None,
            output_tokens: None,
            cache_read_tokens: None,
            created_at_micros: ts,
            meta: Map::new(),
        });
    }

    fn consume_codex_call(&mut self, item_type: &str, p: &Map<String, Value>, ts: Option<i64>) {
        let host_turn_id = if let Some(id) = &self.last_assistant_turn_id {
            id.clone()
        } else {
            let ord = i32::try_from(self.turns.len()).unwrap_or(i32::MAX);
            let synth_id = format!("turn-{ord}");
            let thinking =
                (!self.pending_thinking.is_empty()).then(|| std::mem::take(&mut self.pending_thinking).join("\n\n"));
            self.turns.push(SessionTurnRecord {
                external_id: synth_id.clone(),
                parent_external_id: self.prev_turn_id.replace(synth_id.clone()),
                ord,
                active_ord: None,
                role: "assistant".to_owned(),
                direction: Some("received".to_owned()),
                is_self: false,
                model: self.current_model.clone(),
                content: None,
                thinking,
                input_tokens: None,
                output_tokens: None,
                cache_read_tokens: None,
                created_at_micros: ts,
                meta: Map::new(),
            });
            self.last_assistant_turn_id = Some(synth_id.clone());
            synth_id
        };

        let name = clean_opt(p.get("name").and_then(Value::as_str), true).unwrap_or_else(|| item_type.to_owned());
        let mut args = parse_codex_call_args(p);
        clean_json_map(&mut args);
        let (tool_kind, target_path, command) = classify_tool(&name, &args);
        let call_ord = self.call_counts_per_turn.entry(host_turn_id.clone()).or_insert(0);
        let ord_val = *call_ord;
        *call_ord += 1;

        let call_id = clean_opt(p.get("call_id").or_else(|| p.get("id")).and_then(Value::as_str), true);
        let idx = self.tool_calls.len();
        if let Some(cid) = &call_id {
            self.pending_calls.insert(cid.clone(), idx);
        }
        self.tool_calls.push(SessionToolCallRecord {
            turn_external_id: host_turn_id,
            result_turn_external_id: None,
            ord: ord_val,
            external_call_id: call_id,
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

    fn consume_codex_call_output(&mut self, p: &Map<String, Value>, ts: Option<i64>) {
        let ord = i32::try_from(self.turns.len()).unwrap_or(i32::MAX);
        let turn_id = format!("tool-{ord}");
        let raw_output = match p.get("output") {
            Some(Value::String(s)) => s.clone(),
            Some(other) => other.to_string(),
            None => String::new(),
        };
        let (preview, bytes) = preview_output(&raw_output);
        if let Some(call_id) = clean_opt(p.get("call_id").or_else(|| p.get("id")).and_then(Value::as_str), true)
            && let Some(&idx) = self.pending_calls.get(&call_id)
            && let Some(call) = self.tool_calls.get_mut(idx)
        {
            call.result_turn_external_id = Some(turn_id.clone());
            call.output_preview.clone_from(&preview);
            call.output_bytes = bytes;
            if raw_output.contains("\"exit_code\":")
                && !raw_output.contains("\"exit_code\":0")
                && !raw_output.contains("\"exit_code\": 0")
            {
                "error".clone_into(&mut call.status);
            }
        }
        self.turns.push(SessionTurnRecord {
            external_id: turn_id.clone(),
            parent_external_id: self.prev_turn_id.replace(turn_id),
            ord,
            active_ord: None,
            role: "tool".to_owned(),
            direction: None,
            is_self: false,
            model: None,
            content: preview,
            thinking: None,
            input_tokens: None,
            output_tokens: None,
            cache_read_tokens: None,
            created_at_micros: ts,
            meta: Map::new(),
        });
    }

    fn finish(mut self, path: &Path, bytes: &[u8], mtime: f64) -> ParsedSession {
        let mut active_ord = 0_i32;
        for turn in &mut self.turns {
            if matches!(turn.role.as_str(), "user" | "assistant")
                && turn.content.as_deref().is_some_and(|c| !c.trim().is_empty())
            {
                turn.active_ord = Some(active_ord);
                active_ord += 1;
            }
        }
        let external_id = self.session_id.unwrap_or_else(|| self.stem.clone());
        let title = derive_title(self.summary.as_deref(), &self.turns, &external_id);
        let updated = self.updated_at.or_else(|| {
            #[allow(clippy::cast_possible_truncation)]
            let m = (mtime * 1_000_000.0) as i64;
            (m > 0).then_some(m)
        });
        let effective_mtime = updated.map_or(mtime, |u| {
            #[allow(clippy::cast_precision_loss)]
            let s = u as f64 / 1_000_000.0;
            s
        });
        ParsedSession {
            uri: self.uri,
            source_sha256: hex_digest(bytes),
            mtime: effective_mtime,
            record: SessionRecord {
                provider: CHATGPT_KIND.to_owned(),
                surface: "codex".to_owned(),
                external_id,
                parent_external_id: self.parent_external_id,
                title: Some(title),
                summary: self.summary,
                workspace_path: self.workspace_path,
                workspace_paths: self.workspace_paths,
                git_branch: self.git_branch,
                git_commit: self.git_commit,
                primary_model: self.primary_model,
                started_at_micros: self.started_at,
                updated_at_micros: updated,
                input_tokens: self.input_tokens,
                output_tokens: self.output_tokens,
                cache_read_tokens: self.cache_read_tokens,
                origin_uri: Some(path.display().to_string()),
                meta: Map::new(),
                turns: self.turns,
                tool_calls: self.tool_calls,
                artifacts: Vec::new(),
            },
            companions: Vec::new(),
        }
    }
}

fn extract_codex_message_text(content: Option<&Value>) -> Option<String> {
    match content {
        Some(Value::String(s)) => clean_opt(Some(s), true),
        Some(Value::Array(items)) => {
            let parts: Vec<String> =
                items.iter().filter_map(|item| clean_opt(item.get("text").and_then(Value::as_str), true)).collect();
            (!parts.is_empty()).then(|| parts.join("\n\n"))
        }
        _ => None,
    }
}

fn parse_codex_call_args(p: &Map<String, Value>) -> Map<String, Value> {
    if let Some(args_str) = p.get("arguments").and_then(Value::as_str)
        && let Ok(Value::Object(map)) = serde_json::from_str::<Value>(args_str)
    {
        return map;
    }
    if let Some(args_obj) = p.get("arguments").and_then(Value::as_object) {
        return args_obj.clone();
    }
    let mut fallback = Map::new();
    if let Some(input) = p.get("input").and_then(Value::as_str) {
        fallback.insert("input".into(), Value::String(input.to_owned()));
    }
    if let Some(action) = p.get("action").and_then(Value::as_object) {
        for (k, v) in action {
            fallback.insert(k.clone(), v.clone());
        }
    }
    fallback
}

// ---------------------------------------------------------------------------
// ChatGPT Web `conversations.json` (`mapping` tree + `current_node` lineage)
// ---------------------------------------------------------------------------

pub(super) fn parse_chatgpt_web_json(
    base_uri: &str,
    bytes: &[u8],
    fallback_mtime: f64,
) -> Vec<Result<ParsedSession, String>> {
    let root: Value = match serde_json::from_slice(bytes) {
        Ok(v) => v,
        Err(err) => return vec![Err(format!("{base_uri}: invalid JSON: {err}"))],
    };
    let Some(items) = root.as_array() else { return Vec::new() };
    let mut out = Vec::new();
    for item in items {
        let Some(conv) = item.as_object() else { continue };
        if let Some(parsed) = parse_one_chatgpt_conversation(base_uri, conv, fallback_mtime) {
            out.push(Ok(parsed));
        }
    }
    out
}

fn parse_one_chatgpt_conversation(
    base_uri: &str,
    conv: &Map<String, Value>,
    fallback_mtime: f64,
) -> Option<ParsedSession> {
    let ext_id = clean_opt(conv.get("conversation_id").or_else(|| conv.get("id")).and_then(Value::as_str), true)?;
    let mapping = conv.get("mapping").and_then(Value::as_object)?;
    if mapping.is_empty() {
        return None;
    }
    let session_uri = format!("{base_uri}#{ext_id}");
    let ordered_ids = bfs_mapping_nodes(mapping);
    let active_nodes = active_branch_set(mapping, conv.get("current_node").and_then(Value::as_str));

    let mut builder = MappingBuilder::default();
    for node_id in &ordered_ids {
        let Some(node) = mapping.get(node_id).and_then(Value::as_object) else { continue };
        builder.visit_node(node_id, node, mapping, active_nodes.contains(node_id.as_str()), &session_uri);
    }
    if builder.turns.is_empty() {
        return None;
    }

    let created = conv.get("create_time").and_then(parse_timestamp_micros);
    let updated = conv.get("update_time").and_then(parse_timestamp_micros).or(created);
    let raw_title = clean_opt(conv.get("title").and_then(Value::as_str), true);
    let title = derive_title(raw_title.as_deref(), &builder.turns, &ext_id);
    let primary_model = clean_opt(conv.get("default_model_slug").and_then(Value::as_str), true).or(builder.first_model);
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
            provider: CHATGPT_KIND.to_owned(),
            surface: "chatgpt_web".to_owned(),
            external_id: ext_id,
            parent_external_id: None,
            title: Some(title),
            summary: None,
            workspace_path: None,
            workspace_paths: Vec::new(),
            git_branch: None,
            git_commit: None,
            primary_model,
            started_at_micros: created,
            updated_at_micros: updated,
            input_tokens: None,
            output_tokens: None,
            cache_read_tokens: None,
            origin_uri: Some(base_uri.to_owned()),
            meta: Map::new(),
            turns: builder.turns,
            tool_calls: builder.tool_calls,
            artifacts: builder.artifacts,
        },
        companions: builder.companions,
    })
}

/// Traverses `mapping` top-down from root nodes so parents always precede children.
fn bfs_mapping_nodes(mapping: &Map<String, Value>) -> Vec<String> {
    let mut roots: Vec<&String> = mapping
        .iter()
        .filter(|(_, node)| node.get("parent").and_then(Value::as_str).is_none_or(|p| !mapping.contains_key(p)))
        .map(|(id, _)| id)
        .collect();
    roots.sort();

    let mut visited = HashSet::new();
    let mut queue: VecDeque<String> = roots.into_iter().cloned().collect();
    let mut order = Vec::with_capacity(mapping.len());
    while let Some(id) = queue.pop_front() {
        if !visited.insert(id.clone()) {
            continue;
        }
        if let Some(children) = mapping.get(&id).and_then(|n| n.get("children")).and_then(Value::as_array) {
            for child in children.iter().filter_map(Value::as_str) {
                if mapping.contains_key(child) && !visited.contains(child) {
                    queue.push_back(child.to_owned());
                }
            }
        }
        order.push(id);
    }
    order
}

/// Walks `current_node` back to root via `parent` pointers to identify the active branch.
fn active_branch_set<'a>(mapping: &'a Map<String, Value>, current_node: Option<&'a str>) -> HashSet<&'a str> {
    let mut set = HashSet::new();
    let start = current_node.filter(|id| mapping.contains_key(*id)).or_else(|| {
        mapping
            .iter()
            .filter_map(|(id, n)| {
                let empty_children = n.get("children").and_then(Value::as_array).is_none_or(Vec::is_empty);
                empty_children.then_some(id.as_str())
            })
            .next_back()
    });
    let mut cur = start;
    while let Some(id) = cur {
        if !set.insert(id) {
            break;
        }
        cur = mapping.get(id).and_then(|n| n.get("parent")).and_then(Value::as_str);
    }
    set
}

/// Finds the nearest ancestor in `mapping` that carries a non-null `message`.
fn nearest_message_ancestor(node: &Map<String, Value>, mapping: &Map<String, Value>) -> Option<String> {
    let mut cur = node.get("parent").and_then(Value::as_str);
    let mut hops = 0_usize;
    while let Some(parent_id) = cur {
        hops += 1;
        if hops > mapping.len() {
            break;
        }
        let parent_node = mapping.get(parent_id)?.as_object()?;
        if parent_node.get("message").is_some_and(|m| !m.is_null()) {
            return Some(clean_str(parent_id));
        }
        cur = parent_node.get("parent").and_then(Value::as_str);
    }
    None
}

#[derive(Default)]
struct MappingBuilder {
    turns: Vec<SessionTurnRecord>,
    tool_calls: Vec<SessionToolCallRecord>,
    artifacts: Vec<SessionArtifactRecord>,
    companions: Vec<CompanionDocument>,
    first_model: Option<String>,
    next_active_ord: i32,
}

impl MappingBuilder {
    fn visit_node(
        &mut self,
        node_id: &str,
        node: &Map<String, Value>,
        mapping: &Map<String, Value>,
        on_active_branch: bool,
        session_uri: &str,
    ) {
        let Some(msg) = node.get("message").and_then(Value::as_object) else { return };
        let author = msg.get("author").and_then(Value::as_object);
        let raw_role = author.and_then(|a| a.get("role")).and_then(Value::as_str).unwrap_or("assistant");
        let role = match raw_role {
            "user" => "user",
            "assistant" => "assistant",
            "tool" => "tool",
            _ => "system",
        };
        let meta_obj = msg.get("metadata").and_then(Value::as_object);
        let visually_hidden =
            meta_obj.and_then(|m| m.get("is_visually_hidden_from_conversation")).and_then(Value::as_bool) == Some(true);
        let model =
            meta_obj.and_then(|m| m.get("model_slug")).and_then(Value::as_str).and_then(|s| clean_opt(Some(s), true));
        if self.first_model.is_none() && model.is_some() {
            self.first_model.clone_from(&model);
        }

        let ts = msg.get("create_time").and_then(parse_timestamp_micros);
        let recipient = msg.get("recipient").and_then(Value::as_str).unwrap_or("all");
        let turn_ext_id = clean_str(node_id);
        let (content, thinking) = self.extract_chatgpt_content(
            msg.get("content").and_then(Value::as_object),
            &turn_ext_id,
            recipient,
            role,
            session_uri,
            ts,
        );
        if let Some(m) = meta_obj {
            self.collect_chatgpt_attachments(m, &turn_ext_id);
        }

        // Skip empty structural system nodes (such as ChatGPT's blank initial system message).
        if role == "system" && content.is_none() && thinking.is_none() {
            return;
        }

        let is_visible_prose = on_active_branch
            && !visually_hidden
            && recipient == "all"
            && matches!(role, "user" | "assistant")
            && content.as_deref().is_some_and(|c| !c.trim().is_empty());
        let active_ord = is_visible_prose.then(|| {
            let cur = self.next_active_ord;
            self.next_active_ord += 1;
            cur
        });

        let ord = i32::try_from(self.turns.len()).unwrap_or(i32::MAX);
        let parent_ext = nearest_message_ancestor(node, mapping);
        let direction = match role {
            "user" => Some("sent".to_owned()),
            "assistant" => Some("received".to_owned()),
            _ => None,
        };
        self.turns.push(SessionTurnRecord {
            external_id: turn_ext_id,
            parent_external_id: parent_ext,
            ord,
            active_ord,
            role: role.to_owned(),
            direction,
            is_self: role == "user",
            model,
            content,
            thinking,
            input_tokens: None,
            output_tokens: None,
            cache_read_tokens: None,
            created_at_micros: ts,
            meta: Map::new(),
        });
    }

    fn extract_chatgpt_content(
        &mut self,
        content_obj: Option<&Map<String, Value>>,
        turn_ext_id: &str,
        recipient: &str,
        role: &str,
        session_uri: &str,
        ts: Option<i64>,
    ) -> (Option<String>, Option<String>) {
        let Some(c) = content_obj else { return (None, None) };
        let ctype = c.get("content_type").and_then(Value::as_str).unwrap_or("text");
        match ctype {
            "thoughts" => {
                let thoughts = c
                    .get("thoughts")
                    .and_then(Value::as_array)
                    .map(|arr| {
                        arr.iter()
                            .filter_map(|t| clean_opt(t.get("content").and_then(Value::as_str), true))
                            .collect::<Vec<_>>()
                            .join("\n\n")
                    })
                    .filter(|s| !s.is_empty());
                (None, thoughts)
            }
            "reasoning_recap" => (None, clean_opt(c.get("content").and_then(Value::as_str), true)),
            "code" => {
                let code_text = clean_opt(c.get("text").and_then(Value::as_str), true);
                if role == "assistant" {
                    self.record_chatgpt_tool_call(turn_ext_id, recipient, code_text.as_deref(), session_uri, ts);
                }
                (None, None)
            }
            _ => {
                let parts_text = extract_parts_text(c.get("parts"), turn_ext_id, &mut self.artifacts);
                let fallback = parts_text.or_else(|| clean_opt(c.get("text").and_then(Value::as_str), true));
                if role == "assistant" && recipient != "all" {
                    self.record_chatgpt_tool_call(turn_ext_id, recipient, fallback.as_deref(), session_uri, ts);
                    return (None, None);
                }
                (fallback, None)
            }
        }
    }

    fn record_chatgpt_tool_call(
        &mut self,
        turn_ext_id: &str,
        recipient: &str,
        raw_input: Option<&str>,
        session_uri: &str,
        ts: Option<i64>,
    ) {
        let tool_name = if recipient == "all" || recipient.is_empty() { "python" } else { recipient };
        let mut args = Map::new();
        if let Some(text) = raw_input {
            if let Ok(Value::Object(parsed)) = serde_json::from_str::<Value>(text) {
                args = parsed;
            } else {
                args.insert("input".into(), Value::String(clean_str(text)));
            }
        }
        clean_json_map(&mut args);
        if tool_name.starts_with("canmore.") {
            self.maybe_record_canvas_doc(turn_ext_id, &args, session_uri, ts);
        }
        let (tool_kind, target_path, command) = classify_tool(tool_name, &args);
        self.tool_calls.push(SessionToolCallRecord {
            turn_external_id: turn_ext_id.to_owned(),
            result_turn_external_id: None,
            ord: 0,
            external_call_id: None,
            tool_name: clean_str(tool_name),
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

    fn maybe_record_canvas_doc(
        &mut self,
        turn_ext_id: &str,
        args: &Map<String, Value>,
        session_uri: &str,
        ts: Option<i64>,
    ) {
        let Some(content) = clean_opt(args.get("content").and_then(Value::as_str), true) else { return };
        let name = clean_opt(args.get("name").and_then(Value::as_str), true);
        let doc_type = args.get("type").and_then(Value::as_str).unwrap_or("document");
        let is_code = doc_type.starts_with("code/");
        let ext_id = format!("canvas-{turn_ext_id}");
        let uri = format!("{session_uri}#canvas:{turn_ext_id}");
        let sha = hex_digest(content.as_bytes());
        self.artifacts.push(SessionArtifactRecord {
            turn_external_id: Some(turn_ext_id.to_owned()),
            external_id: ext_id.clone(),
            kind: if is_code { "code".into() } else { "document".into() },
            title: name.clone(),
            mime: Some(clean_str(doc_type)),
            uri: Some(uri.clone()),
            content_sha256: Some(sha.clone()),
            meta: Map::new(),
        });
        if content.len() >= 32 {
            #[allow(clippy::cast_precision_loss)]
            let mtime = ts.map_or(0.0, |t| t as f64 / 1_000_000.0);
            self.companions.push(CompanionDocument {
                artifact_external_id: ext_id,
                uri,
                title: name,
                text: content,
                extension: if is_code { ".txt".into() } else { ".md".into() },
                mtime,
                source_sha256: sha,
                meta: Map::new(),
            });
        }
    }

    fn collect_chatgpt_attachments(&mut self, meta: &Map<String, Value>, turn_ext_id: &str) {
        let Some(arr) = meta.get("attachments").and_then(Value::as_array) else { return };
        for (i, item) in arr.iter().enumerate() {
            let Some(obj) = item.as_object() else { continue };
            let id = clean_opt(obj.get("id").and_then(Value::as_str), true)
                .unwrap_or_else(|| format!("{turn_ext_id}-att-{i}"));
            let name = clean_opt(obj.get("name").and_then(Value::as_str), true);
            let mime = clean_opt(obj.get("mime_type").and_then(Value::as_str), true);
            let is_img = mime.as_deref().is_some_and(|m| m.starts_with("image/"));
            self.artifacts.push(SessionArtifactRecord {
                turn_external_id: Some(turn_ext_id.to_owned()),
                external_id: id,
                kind: if is_img { "image".into() } else { "attachment".into() },
                title: name,
                mime,
                uri: None,
                content_sha256: None,
                meta: Map::new(),
            });
        }
    }
}

fn extract_parts_text(
    parts: Option<&Value>,
    turn_ext_id: &str,
    artifacts: &mut Vec<SessionArtifactRecord>,
) -> Option<String> {
    let arr = parts?.as_array()?;
    let mut strings = Vec::new();
    for (idx, part) in arr.iter().enumerate() {
        match part {
            Value::String(s) => {
                if let Some(cleaned) = clean_opt(Some(s), true) {
                    strings.push(cleaned);
                }
            }
            Value::Object(obj) => {
                if obj.get("content_type").and_then(Value::as_str) == Some("image_asset_pointer") {
                    let ptr = clean_opt(obj.get("asset_pointer").and_then(Value::as_str), true);
                    artifacts.push(SessionArtifactRecord {
                        turn_external_id: Some(turn_ext_id.to_owned()),
                        external_id: format!("{turn_ext_id}-img-{idx}"),
                        kind: "image".to_owned(),
                        title: None,
                        mime: Some("image/*".to_owned()),
                        uri: ptr,
                        content_sha256: None,
                        meta: Map::new(),
                    });
                }
            }
            _ => {}
        }
    }
    (!strings.is_empty()).then(|| strings.join("\n\n"))
}

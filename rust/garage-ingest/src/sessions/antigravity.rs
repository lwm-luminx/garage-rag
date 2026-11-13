//! Parser and scanner helpers for `antigravity` session sources:
//! - Local Antigravity `brain/<conversation-id>/` directories (`.system_generated/logs/transcript_full.jsonl`
//!   falling back to `transcript.jsonl`) plus companion deliverable Markdown artifacts (`*.md` and
//!   `*.md.metadata.json`).
//! - `.zip` archives of brain directories or standalone `.jsonl` transcripts.

use std::collections::{HashMap, VecDeque};
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};

use serde_json::{Map, Value};

use crate::sha256::hex_digest;

use super::types::{
    ANTIGRAVITY_KIND, CompanionDocument, ParsedSession, SessionArtifactRecord, SessionRecord, SessionToolCallRecord,
    SessionTurnRecord, classify_tool, clean_json_map, clean_opt, clean_str, derive_title, has_ext,
    parse_timestamp_micros, path_has_ext, preview_output,
};

struct DiscoveredBrain {
    conv_id: String,
    conv_dir: Option<PathBuf>,
    transcript_path: PathBuf,
}

/// Counts Antigravity conversations under `root` for `scan_source`.
pub(super) fn count_antigravity_items(
    root: &Path,
    details: &mut Map<String, Value>,
    mut tick: impl FnMut(u64),
) -> u64 {
    let (brains, zips) = discover_antigravity_targets(root);
    let mut total = brains.len() as u64;
    let mut companion_files = 0_u64;
    for b in &brains {
        if let Some(dir) = &b.conv_dir {
            companion_files += list_companion_markdown(dir).len() as u64;
        }
        tick(total);
    }
    for zip_path in &zips {
        total += count_zip_brains(zip_path);
        tick(total);
    }
    details.insert("conversations".into(), Value::from(brains.len() as u64));
    details.insert("companion_artifacts".into(), Value::from(companion_files));
    details.insert("archives".into(), Value::from(zips.len() as u64));
    total
}

/// Discovers and parses every Antigravity conversation (and subagent parent link) under `root`.
pub(super) fn load_antigravity_sessions(root: &Path) -> Vec<Result<ParsedSession, String>> {
    let (brains, zips) = discover_antigravity_targets(root);
    let mut parsed_ok: Vec<(ParsedSession, Vec<String>)> = Vec::new();
    let mut errors: Vec<String> = Vec::new();

    for brain in brains {
        let mtime = file_mtime(&brain.transcript_path);
        let bytes = match fs::read(&brain.transcript_path) {
            Ok(b) => b,
            Err(err) => {
                errors.push(format!("{}: {err}", brain.transcript_path.display()));
                continue;
            }
        };
        let companions = brain.conv_dir.as_deref().map(read_disk_companions).unwrap_or_default();
        let uri = brain
            .conv_dir
            .as_ref()
            .map_or_else(|| brain.transcript_path.display().to_string(), |d| d.display().to_string());
        match parse_antigravity_transcript(&brain.conv_id, &uri, &bytes, mtime, companions) {
            Ok(Some(item)) => parsed_ok.push(item),
            Ok(None) => {}
            Err(err) => errors.push(err),
        }
    }

    for zip_path in zips {
        for item in load_antigravity_zip(&zip_path) {
            match item {
                Ok(pair) => parsed_ok.push(pair),
                Err(err) => errors.push(err),
            }
        }
    }

    // Wire child -> parent subagent relationships discovered via `invoke_subagent`.
    let mut parent_by_child: HashMap<String, String> = HashMap::new();
    for (session, spawned_children) in &parsed_ok {
        for child_id in spawned_children {
            parent_by_child.insert(child_id.clone(), session.record.external_id.clone());
        }
    }
    let mut out: Vec<Result<ParsedSession, String>> = parsed_ok
        .into_iter()
        .map(|(mut session, _)| {
            if session.record.parent_external_id.is_none()
                && let Some(parent) = parent_by_child.get(&session.record.external_id)
            {
                session.record.parent_external_id = Some(parent.clone());
            }
            Ok(session)
        })
        .collect();
    out.extend(errors.into_iter().map(Err));
    out
}

fn discover_antigravity_targets(root: &Path) -> (Vec<DiscoveredBrain>, Vec<PathBuf>) {
    let Ok(meta) = fs::metadata(root) else { return (Vec::new(), Vec::new()) };
    if meta.is_file() {
        if path_has_ext(root, "zip") {
            return (Vec::new(), vec![root.to_path_buf()]);
        }
        if path_has_ext(root, "jsonl") {
            let conv_id = infer_conv_id_from_transcript_path(root);
            return (
                vec![DiscoveredBrain { conv_id, conv_dir: None, transcript_path: root.to_path_buf() }],
                Vec::new(),
            );
        }
        return (Vec::new(), Vec::new());
    }

    if let Some(tx) = find_brain_transcript(root) {
        let conv_id = root.file_name().map_or_else(|| "brain".into(), |n| n.to_string_lossy().into_owned());
        return (
            vec![DiscoveredBrain { conv_id, conv_dir: Some(root.to_path_buf()), transcript_path: tx }],
            Vec::new(),
        );
    }

    let mut brains = Vec::new();
    let mut zips = Vec::new();
    let mut candidate_roots = vec![root.to_path_buf()];
    let nested_brain = root.join("brain");
    if nested_brain.is_dir() {
        candidate_roots.insert(0, nested_brain);
    }

    let mut seen_dirs = std::collections::HashSet::new();
    let mut idx = 0;
    while idx < candidate_roots.len() {
        let base = candidate_roots[idx].clone();
        idx += 1;
        let Ok(entries) = fs::read_dir(&base) else { continue };
        let mut children: Vec<PathBuf> = entries.flatten().map(|e| e.path()).collect();
        children.sort();
        for path in children {
            let Some(name) = path.file_name().map(|n| n.to_string_lossy().into_owned()) else { continue };
            if name.starts_with('.') {
                continue;
            }
            let Ok(ft) = fs::symlink_metadata(&path).map(|m| m.file_type()) else { continue };
            if ft.is_symlink() {
                continue;
            }
            if ft.is_file() && has_ext(&name, "zip") {
                zips.push(path);
            } else if ft.is_dir() {
                if let Some(tx) = find_brain_transcript(&path) {
                    if seen_dirs.insert(path.clone()) {
                        brains.push(DiscoveredBrain { conv_id: name, conv_dir: Some(path), transcript_path: tx });
                    }
                } else {
                    let child_brain = path.join("brain");
                    if child_brain.is_dir() && !candidate_roots.contains(&child_brain) {
                        candidate_roots.push(child_brain);
                    }
                }
            }
        }
    }
    (brains, zips)
}

fn find_brain_transcript(conv_dir: &Path) -> Option<PathBuf> {
    let logs = conv_dir.join(".system_generated").join("logs");
    let full = logs.join("transcript_full.jsonl");
    if full.is_file() {
        return Some(full);
    }
    let compact = logs.join("transcript.jsonl");
    if compact.is_file() {
        return Some(compact);
    }
    None
}

fn infer_conv_id_from_transcript_path(path: &Path) -> String {
    // `<brain>/<conv-id>/.system_generated/logs/transcript_full.jsonl`
    if let Some(conv_dir) = path.parent().and_then(Path::parent).and_then(Path::parent)
        && let Some(name) = conv_dir.file_name().map(|n| n.to_string_lossy().into_owned())
        && !name.is_empty()
    {
        return name;
    }
    path.file_stem().map_or_else(|| "antigravity".into(), |n| n.to_string_lossy().into_owned())
}

fn list_companion_markdown(conv_dir: &Path) -> Vec<PathBuf> {
    let Ok(entries) = fs::read_dir(conv_dir) else { return Vec::new() };
    let mut files: Vec<PathBuf> = entries
        .flatten()
        .filter_map(|e| {
            let name = e.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') || !has_ext(&name, "md") {
                return None;
            }
            e.file_type().ok().filter(|ft| ft.is_file() && !ft.is_symlink()).map(|_| e.path())
        })
        .collect();
    files.sort();
    files
}

struct CompanionInput {
    file_name: String,
    uri: String,
    text: String,
    mtime: f64,
    metadata: Option<Map<String, Value>>,
}

fn read_disk_companions(conv_dir: &Path) -> Vec<CompanionInput> {
    let mut out = Vec::new();
    for md_path in list_companion_markdown(conv_dir) {
        let Ok(text) = fs::read_to_string(&md_path) else { continue };
        if text.trim().is_empty() {
            continue;
        }
        let file_name = md_path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let meta_path = conv_dir.join(format!("{file_name}.metadata.json"));
        let metadata = fs::read(&meta_path)
            .ok()
            .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
            .and_then(|v| v.as_object().cloned());
        out.push(CompanionInput {
            file_name,
            uri: md_path.display().to_string(),
            text,
            mtime: file_mtime(&md_path),
            metadata,
        });
    }
    out
}

fn file_mtime(path: &Path) -> f64 {
    fs::metadata(path)
        .ok()
        .and_then(|m| m.modified().ok())
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map_or(0.0, |d| d.as_secs_f64())
}

fn count_zip_brains(zip_path: &Path) -> u64 {
    let Ok(file) = fs::File::open(zip_path) else { return 0 };
    let Ok(mut archive) = zip::ZipArchive::new(file) else { return 0 };
    let mut convs = std::collections::HashSet::new();
    for idx in 0..archive.len() {
        let Ok(entry) = archive.by_index(idx) else { continue };
        let Ok(raw_name) = entry.name() else { continue };
        if let Some((conv_id, _)) = classify_zip_transcript_entry(&raw_name) {
            convs.insert(conv_id);
        }
    }
    convs.len() as u64
}

fn classify_zip_transcript_entry(entry_name: &str) -> Option<(String, bool)> {
    let parts: Vec<&str> = entry_name.split('/').filter(|p| !p.is_empty()).collect();
    let last = *parts.last()?;
    let is_full = match last {
        "transcript_full.jsonl" => true,
        "transcript.jsonl" => false,
        _ => return None,
    };
    let logs_idx = parts.iter().position(|&p| p == ".system_generated")?;
    let conv_id = if logs_idx > 0 { parts[logs_idx - 1].to_owned() } else { "antigravity".to_owned() };
    Some((conv_id, is_full))
}

#[allow(clippy::type_complexity)]
fn load_antigravity_zip(zip_path: &Path) -> Vec<Result<(ParsedSession, Vec<String>), String>> {
    let mtime = file_mtime(zip_path);
    let file = match fs::File::open(zip_path) {
        Ok(f) => f,
        Err(err) => return vec![Err(format!("{}: {err}", zip_path.display()))],
    };
    let mut archive = match zip::ZipArchive::new(file) {
        Ok(a) => a,
        Err(err) => return vec![Err(format!("{}: invalid zip archive: {err}", zip_path.display()))],
    };

    let mut transcripts: HashMap<String, (bool, String, Vec<u8>)> = HashMap::new();
    let mut md_files: HashMap<String, Vec<(String, String, String)>> = HashMap::new();
    let mut meta_files: HashMap<(String, String), Map<String, Value>> = HashMap::new();

    for idx in 0..archive.len() {
        let Ok(mut entry) = archive.by_index(idx) else { continue };
        if entry.is_dir() {
            continue;
        }
        let Ok(raw_name) = entry.name() else { continue };
        let name = raw_name.into_owned();
        if let Some((conv_id, is_full)) = classify_zip_transcript_entry(&name) {
            if !is_full && transcripts.get(&conv_id).is_some_and(|(already_full, _, _)| *already_full) {
                continue;
            }
            let mut bytes = Vec::new();
            if entry.read_to_end(&mut bytes).is_ok() {
                transcripts.insert(conv_id, (is_full, name, bytes));
            }
            continue;
        }
        collect_zip_companion_entry(&mut entry, &name, zip_path, &mut md_files, &mut meta_files);
    }

    let mut conv_ids: Vec<String> = transcripts.keys().cloned().collect();
    conv_ids.sort();
    let mut out = Vec::new();
    for conv_id in conv_ids {
        let Some((_, entry_name, bytes)) = transcripts.remove(&conv_id) else { continue };
        let companions = md_files
            .remove(&conv_id)
            .unwrap_or_default()
            .into_iter()
            .map(|(fname, uri, text)| {
                let metadata = meta_files.remove(&(conv_id.clone(), fname.clone()));
                CompanionInput { file_name: fname, uri, text, mtime, metadata }
            })
            .collect();
        let uri = format!("{}#{entry_name}", zip_path.display());
        match parse_antigravity_transcript(&conv_id, &uri, &bytes, mtime, companions) {
            Ok(Some(pair)) => out.push(Ok(pair)),
            Ok(None) => {}
            Err(err) => out.push(Err(err)),
        }
    }
    out
}

fn collect_zip_companion_entry(
    entry: &mut zip::read::ZipFile<'_, fs::File>,
    name: &str,
    zip_path: &Path,
    md_files: &mut HashMap<String, Vec<(String, String, String)>>,
    meta_files: &mut HashMap<(String, String), Map<String, Value>>,
) {
    if name.contains(".system_generated/") {
        return;
    }
    let parts: Vec<&str> = name.split('/').filter(|p| !p.is_empty()).collect();
    if parts.len() < 2 {
        return;
    }
    let file_name = parts[parts.len() - 1];
    let conv_id = parts[parts.len() - 2];
    if file_name.starts_with('.') {
        return;
    }
    if let Some(md_name) = file_name.strip_suffix(".metadata.json")
        && has_ext(md_name, "md")
    {
        let mut bytes = Vec::new();
        if entry.read_to_end(&mut bytes).is_ok()
            && let Ok(Value::Object(obj)) = serde_json::from_slice::<Value>(&bytes)
        {
            meta_files.insert((conv_id.to_owned(), md_name.to_owned()), obj);
        }
    } else if has_ext(file_name, "md") {
        let mut text = String::new();
        if entry.read_to_string(&mut text).is_ok() && !text.trim().is_empty() {
            let uri = format!("{}#{name}", zip_path.display());
            md_files.entry(conv_id.to_owned()).or_default().push((file_name.to_owned(), uri, text));
        }
    }
}

fn parse_antigravity_transcript(
    conv_id: &str,
    uri: &str,
    bytes: &[u8],
    mtime: f64,
    companions_in: Vec<CompanionInput>,
) -> Result<Option<(ParsedSession, Vec<String>)>, String> {
    let text = std::str::from_utf8(bytes).map_err(|e| format!("{uri}: invalid UTF-8: {e}"))?;
    let mut state = AntigravityState::new(conv_id, uri);
    for raw_line in text.lines() {
        let line = raw_line.trim();
        if line.is_empty() {
            continue;
        }
        let Ok(Value::Object(obj)) = serde_json::from_str::<Value>(line) else { continue };
        state.consume_step(&obj);
    }
    if state.turns.is_empty() && companions_in.is_empty() {
        return Ok(None);
    }
    Ok(Some(state.finish(bytes, mtime, companions_in)))
}

struct AntigravityState {
    conv_id: String,
    uri: String,
    workspace_path: Option<String>,
    workspace_paths: Vec<String>,
    primary_model: Option<String>,
    started_at: Option<i64>,
    updated_at: Option<i64>,
    input_tokens: i64,
    output_tokens: i64,
    cache_read_tokens: i64,
    has_tokens: bool,
    turns: Vec<SessionTurnRecord>,
    tool_calls: Vec<SessionToolCallRecord>,
    open_calls: VecDeque<usize>,
    spawned_children: Vec<String>,
    prev_turn_id: Option<String>,
}

impl AntigravityState {
    fn new(conv_id: &str, uri: &str) -> Self {
        Self {
            conv_id: clean_str(conv_id),
            uri: clean_str(uri),
            workspace_path: None,
            workspace_paths: Vec::new(),
            primary_model: None,
            started_at: None,
            updated_at: None,
            input_tokens: 0,
            output_tokens: 0,
            cache_read_tokens: 0,
            has_tokens: false,
            turns: Vec::new(),
            tool_calls: Vec::new(),
            open_calls: VecDeque::new(),
            spawned_children: Vec::new(),
            prev_turn_id: None,
        }
    }

    fn consume_step(&mut self, obj: &Map<String, Value>) {
        let ts = obj.get("created_at").or_else(|| obj.get("timestamp")).and_then(parse_timestamp_micros);
        if let Some(t) = ts {
            self.started_at = Some(self.started_at.map_or(t, |cur| cur.min(t)));
            self.updated_at = Some(self.updated_at.map_or(t, |cur| cur.max(t)));
        }
        let raw_content = obj.get("content").and_then(Value::as_str).unwrap_or_default();
        self.extract_workspaces_from_text(raw_content);

        let step_type = obj.get("type").and_then(Value::as_str).unwrap_or_default();
        let source = obj.get("source").and_then(Value::as_str).unwrap_or_default();
        let ord = i32::try_from(self.turns.len()).unwrap_or(i32::MAX);
        let step_idx = obj.get("step_index").and_then(Value::as_i64);
        let turn_id = step_idx.map_or_else(|| format!("step-{ord}"), |idx| format!("step-{idx}"));

        if step_type == "USER_INPUT" || source == "USER_EXPLICIT" {
            self.consume_user_step(&turn_id, ord, raw_content, ts);
        } else if step_type == "PLANNER_RESPONSE" || source == "MODEL" {
            self.consume_model_step(&turn_id, ord, obj, ts);
        } else {
            self.consume_system_or_tool_step(&turn_id, ord, obj, raw_content, ts);
        }
    }

    fn consume_user_step(&mut self, turn_id: &str, ord: i32, raw_content: &str, ts: Option<i64>) {
        let (cleaned, is_compaction_only) = clean_antigravity_user_input(raw_content);
        let Some(content) = clean_opt(Some(&cleaned), true) else { return };
        let role = if is_compaction_only { "system" } else { "user" };
        self.turns.push(SessionTurnRecord {
            external_id: turn_id.to_owned(),
            parent_external_id: self.prev_turn_id.replace(turn_id.to_owned()),
            ord,
            active_ord: None,
            role: role.to_owned(),
            direction: (role == "user").then(|| "sent".to_owned()),
            is_self: role == "user",
            model: None,
            content: Some(content),
            thinking: None,
            input_tokens: None,
            output_tokens: None,
            cache_read_tokens: None,
            created_at_micros: ts,
            meta: Map::new(),
        });
    }

    fn consume_model_step(&mut self, turn_id: &str, ord: i32, obj: &Map<String, Value>, ts: Option<i64>) {
        self.open_calls.clear();
        let content = clean_opt(obj.get("content").and_then(Value::as_str), true);
        let thinking = clean_opt(obj.get("thinking").and_then(Value::as_str), true);
        let model = clean_opt(obj.get("model").and_then(Value::as_str), true);
        if self.primary_model.is_none() && model.is_some() {
            self.primary_model.clone_from(&model);
        }
        let in_tok = obj.get("input_tokens").and_then(Value::as_i64).and_then(|n| i32::try_from(n).ok());
        let out_tok = obj.get("output_tokens").and_then(Value::as_i64).and_then(|n| i32::try_from(n).ok());
        let cache_tok = obj
            .get("cache_read_tokens")
            .and_then(Value::as_i64)
            .and_then(|n| i32::try_from(n).ok());
        if in_tok.is_some() || out_tok.is_some() || cache_tok.is_some() {
            self.has_tokens = true;
            self.input_tokens += i64::from(in_tok.unwrap_or(0));
            self.output_tokens += i64::from(out_tok.unwrap_or(0));
            self.cache_read_tokens += i64::from(cache_tok.unwrap_or(0));
        }

        if let Some(calls) = obj.get("tool_calls").and_then(Value::as_array) {
            for (c_idx, call_val) in calls.iter().enumerate() {
                let Some(call_obj) = call_val.as_object() else { continue };
                let name = clean_opt(call_obj.get("name").and_then(Value::as_str), true)
                    .unwrap_or_else(|| "tool".to_owned());
                let mut args = call_obj
                    .get("args")
                    .or_else(|| call_obj.get("arguments"))
                    .and_then(Value::as_object)
                    .cloned()
                    .unwrap_or_default();
                clean_json_map(&mut args);
                let (tool_kind, target_path, command) = classify_tool(&name, &args);
                let idx = self.tool_calls.len();
                self.tool_calls.push(SessionToolCallRecord {
                    turn_external_id: turn_id.to_owned(),
                    result_turn_external_id: None,
                    ord: i32::try_from(c_idx).unwrap_or(i32::MAX),
                    external_call_id: clean_opt(call_obj.get("id").and_then(Value::as_str), true),
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
                self.open_calls.push_back(idx);
            }
        }

        if content.is_none() && thinking.is_none() && self.open_calls.is_empty() {
            return;
        }
        self.turns.push(SessionTurnRecord {
            external_id: turn_id.to_owned(),
            parent_external_id: self.prev_turn_id.replace(turn_id.to_owned()),
            ord,
            active_ord: None,
            role: "assistant".to_owned(),
            direction: Some("received".to_owned()),
            is_self: false,
            model,
            content,
            thinking,
            input_tokens: in_tok,
            output_tokens: out_tok,
            cache_read_tokens: cache_tok,
            created_at_micros: ts,
            meta: Map::new(),
        });
    }

    fn consume_system_or_tool_step(
        &mut self,
        turn_id: &str,
        ord: i32,
        obj: &Map<String, Value>,
        raw_content: &str,
        ts: Option<i64>,
    ) {
        if let Some(call_idx) = self.open_calls.pop_front() {
            let status_str = obj.get("status").and_then(Value::as_str).unwrap_or("DONE");
            let out_str = if raw_content.is_empty() {
                obj.get("output").and_then(Value::as_str).unwrap_or_default()
            } else {
                raw_content
            };
            let (preview, bytes) = preview_output(out_str);
            if let Some(call) = self.tool_calls.get_mut(call_idx) {
                call.result_turn_external_id = Some(turn_id.to_owned());
                if status_str == "ERROR" {
                    "error".clone_into(&mut call.status);
                } else if status_str == "CANCELLED" || status_str == "CANCELED" {
                    "cancelled".clone_into(&mut call.status);
                }
                call.output_preview.clone_from(&preview);
                call.output_bytes = bytes;
                if call.tool_name == "invoke_subagent"
                    && let Some(child_id) = extract_subagent_conversation_id(out_str)
                {
                    self.spawned_children.push(child_id);
                }
            }
            self.turns.push(SessionTurnRecord {
                external_id: turn_id.to_owned(),
                parent_external_id: self.prev_turn_id.replace(turn_id.to_owned()),
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
    }

    fn extract_workspaces_from_text(&mut self, text: &str) {
        if !text.contains("Active Workspaces:") && !text.contains("Command Working Directory:") {
            return;
        }
        let mut in_workspaces = false;
        for line in text.lines() {
            let trimmed = line.trim();
            if trimmed == "Active Workspaces:" {
                in_workspaces = true;
                continue;
            }
            if in_workspaces {
                if let Some(path) = trimmed.strip_prefix("- ") {
                    let cleaned = clean_str(path.trim());
                    if !cleaned.is_empty() && !self.workspace_paths.contains(&cleaned) {
                        if self.workspace_path.is_none() {
                            self.workspace_path = Some(cleaned.clone());
                        }
                        self.workspace_paths.push(cleaned);
                    }
                    continue;
                }
                in_workspaces = false;
            }
            if let Some(cwd) = trimmed.strip_prefix("Command Working Directory:") {
                let cleaned = clean_str(cwd.trim());
                if !cleaned.is_empty() {
                    if self.workspace_path.is_none() {
                        self.workspace_path = Some(cleaned.clone());
                    }
                    if !self.workspace_paths.contains(&cleaned) {
                        self.workspace_paths.push(cleaned);
                    }
                }
            }
        }
    }

    fn finish(
        mut self,
        bytes: &[u8],
        mtime: f64,
        companions_in: Vec<CompanionInput>,
    ) -> (ParsedSession, Vec<String>) {
        let mut active_ord = 0_i32;
        for turn in &mut self.turns {
            if matches!(turn.role.as_str(), "user" | "assistant")
                && turn.content.as_deref().is_some_and(|c| !c.trim().is_empty())
            {
                turn.active_ord = Some(active_ord);
                active_ord += 1;
            }
        }

        let mut artifacts = Vec::new();
        let mut companions = Vec::new();
        let mut hash_material = bytes.to_vec();
        for comp in companions_in {
            let (art, doc) = build_companion_records(&comp);
            hash_material.extend_from_slice(comp.file_name.as_bytes());
            hash_material.extend_from_slice(doc.source_sha256.as_bytes());
            artifacts.push(art);
            companions.push(doc);
        }

        let fallback_title = companions.first().and_then(|c| c.title.as_deref()).unwrap_or(&self.conv_id);
        let title = derive_title(None, &self.turns, fallback_title);
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
        let session = ParsedSession {
            uri: self.uri.clone(),
            source_sha256: hex_digest(&hash_material),
            mtime: effective_mtime,
            record: SessionRecord {
                provider: ANTIGRAVITY_KIND.to_owned(),
                surface: ANTIGRAVITY_KIND.to_owned(),
                external_id: self.conv_id,
                parent_external_id: None,
                title: Some(title),
                summary: None,
                workspace_path: self.workspace_path,
                workspace_paths: self.workspace_paths,
                git_branch: None,
                git_commit: None,
                primary_model: self.primary_model,
                started_at_micros: self.started_at,
                updated_at_micros: updated,
                input_tokens: self.has_tokens.then_some(self.input_tokens),
                output_tokens: self.has_tokens.then_some(self.output_tokens),
                cache_read_tokens: self.has_tokens.then_some(self.cache_read_tokens),
                origin_uri: Some(self.uri),
                meta: Map::new(),
                turns: self.turns,
                tool_calls: self.tool_calls,
                artifacts,
            },
            companions,
        };
        (session, self.spawned_children)
    }
}

fn clean_antigravity_user_input(raw: &str) -> (String, bool) {
    if let Some(start) = raw.find("<USER_REQUEST>")
        && let Some(end) = raw[start..].find("</USER_REQUEST>")
    {
        let inner = &raw[start + "<USER_REQUEST>".len()..start + end];
        return (clean_str(inner.trim()), false);
    }
    if raw.contains("<CONTEXT_SUMMARY>") && !raw.contains("<USER_REQUEST>") {
        return (clean_str(raw.trim()), true);
    }
    let mut text = raw.to_owned();
    for (open, close) in [
        ("<ADDITIONAL_METADATA>", "</ADDITIONAL_METADATA>"),
        ("<USER_SETTINGS_CHANGE>", "</USER_SETTINGS_CHANGE>"),
        ("<EPHEMERAL_MESSAGE>", "</EPHEMERAL_MESSAGE>"),
    ] {
        while let Some(s) = text.find(open) {
            if let Some(e) = text[s..].find(close) {
                text.replace_range(s..s + e + close.len(), "");
            } else {
                break;
            }
        }
    }
    (clean_str(text.trim()), false)
}

fn extract_subagent_conversation_id(output: &str) -> Option<String> {
    for prefix in ["\"conversationId\":\"", "\"conversationId\": \"", "conversationId: "] {
        if let Some(idx) = output.find(prefix) {
            let rest = &output[idx + prefix.len()..];
            let id: String = rest
                .chars()
                .take_while(|c| c.is_ascii_alphanumeric() || *c == '-')
                .collect();
            if id.len() >= 8 {
                return Some(id);
            }
        }
    }
    None
}

fn build_companion_records(comp: &CompanionInput) -> (SessionArtifactRecord, CompanionDocument) {
    let cleaned_text = clean_str(&comp.text);
    let sha = hex_digest(cleaned_text.as_bytes());
    let lower_name = comp.file_name.to_ascii_lowercase();
    let artifact_type = comp
        .metadata
        .as_ref()
        .and_then(|m| m.get("artifactType"))
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_ascii_uppercase();
    let kind = if lower_name.starts_with("implementation_plan") || artifact_type.contains("PLAN") {
        "plan"
    } else if lower_name.starts_with("walkthrough") || artifact_type.contains("WALKTHROUGH") {
        "walkthrough"
    } else {
        "document"
    };
    let heading_title = cleaned_text
        .lines()
        .find_map(|line| line.trim().strip_prefix("# ").map(str::trim))
        .filter(|s| !s.is_empty())
        .map(clean_str);
    let stem = comp.file_name.strip_suffix(".md").unwrap_or(&comp.file_name).to_owned();
    let title = heading_title.or(Some(stem));

    let mut meta = comp.metadata.clone().unwrap_or_default();
    clean_json_map(&mut meta);
    let artifact = SessionArtifactRecord {
        turn_external_id: None,
        external_id: clean_str(&comp.file_name),
        kind: kind.to_owned(),
        title: title.clone(),
        mime: Some("text/markdown".to_owned()),
        uri: Some(clean_str(&comp.uri)),
        content_sha256: Some(sha.clone()),
        meta: meta.clone(),
    };
    let doc = CompanionDocument {
        artifact_external_id: clean_str(&comp.file_name),
        uri: clean_str(&comp.uri),
        title,
        text: cleaned_text,
        extension: ".md".to_owned(),
        mtime: comp.mtime,
        source_sha256: sha,
        meta,
    };
    (artifact, doc)
}

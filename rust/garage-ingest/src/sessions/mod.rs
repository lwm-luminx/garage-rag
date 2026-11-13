//! AI assistant session sources (`claude`, `chatgpt`, `antigravity`): discovery, scanning,
//! normalization onto `025_sessions.sql`, and synthesis into `documents` and `chunks`.

mod antigravity;
mod chatgpt;
mod claude;
pub mod types;

use std::collections::BTreeSet;
use std::fs;
use std::path::Path;
use std::time::Instant;

use serde_json::{Map, Value, json};

use crate::attribution::SelfIdentity;
use crate::chunking::{ContentKind, chunk_prose, chunk_text};
use crate::pipeline::{AuthorPayload, ChunkPayload, Context, Counters, DocumentPayload};
use crate::scanner::{ScanResult, Ticker};
use crate::sha256::hex_digest;
use crate::source::{SourceHost, SourceStorage};

pub use types::{
    ANTIGRAVITY_KIND, CHATGPT_KIND, CHUNKER, CLAUDE_KIND, CompanionDocument, ParsedSession, SESSION_KINDS,
    SessionArtifactRecord, SessionRecord, SessionToolCallRecord, SessionTurnRecord, SessionWritePayload, VERSION,
    classify_tool, micros_to_utc,
};

/// Whether `kind` is one of the local/export AI session source kinds.
#[must_use]
pub fn is_session_kind(kind: &str) -> bool {
    SESSION_KINDS.contains(&kind)
}

/// Chunker signature stored on synthesized session documents.
#[must_use]
pub fn signature(chunk_size: usize) -> String {
    format!("session:{CHUNKER}:{chunk_size}:v{VERSION}")
}

/// Counts sessions in `root` for `scan_source`.
pub fn scan_sessions(root: &Path, source_slug: &str, kind: &str, ticker: &mut Ticker<'_>) -> ScanResult {
    let started = Instant::now();
    if fs::metadata(root).is_err() {
        let mut missing = ScanResult {
            source_slug: source_slug.to_owned(),
            kind: kind.to_owned(),
            root: root.to_path_buf(),
            item_count: 0,
            item_type: "sessions".to_owned(),
            details: Map::new(),
            duration_seconds: started.elapsed().as_secs_f64(),
            error: Some(format!("path does not exist: {}", root.display())),
        };
        missing.details.insert("sessions".into(), json!(0));
        return missing;
    }

    let mut details = Map::new();
    let count = match kind {
        CLAUDE_KIND => claude::count_claude_items(root, &mut details, |n| ticker.report_count(n)),
        CHATGPT_KIND => chatgpt::count_chatgpt_items(root, &mut details, |n| ticker.report_count(n)),
        ANTIGRAVITY_KIND => antigravity::count_antigravity_items(root, &mut details, |n| ticker.report_count(n)),
        _ => 0,
    };
    details.insert("sessions".into(), json!(count));
    ScanResult {
        source_slug: source_slug.to_owned(),
        kind: kind.to_owned(),
        root: root.to_path_buf(),
        item_count: count,
        item_type: "sessions".to_owned(),
        details,
        duration_seconds: started.elapsed().as_secs_f64(),
        error: None,
    }
}

/// One chunk produced by [`render_session`].
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SynthesizedTurnChunk {
    pub text: String,
    pub char_start: usize,
    pub char_end: usize,
    pub direction: Option<String>,
    pub sender: Option<String>,
    pub turn_external_id: Option<String>,
}

fn provider_display_name(provider: &str, surface: &str) -> &'static str {
    match (provider, surface) {
        (_, "codex") => "Codex",
        ("claude", _) => "Claude",
        ("chatgpt", _) => "ChatGPT",
        ("antigravity", _) => "Antigravity",
        _ => "Assistant",
    }
}

fn speaker_label(record: &SessionRecord, turn: &SessionTurnRecord) -> String {
    if turn.is_self || turn.role == "user" {
        return "Me".to_owned();
    }
    let base = provider_display_name(&record.provider, &record.surface);
    match turn.model.as_deref().filter(|m| !m.is_empty()) {
        Some(model) => format!("{base} ({model})"),
        None => base.to_owned(),
    }
}

fn session_header(record: &SessionRecord) -> String {
    let title = record.title.as_deref().unwrap_or(&record.external_id);
    let mut lines = vec![title.to_owned(), format!("Surface: {}", record.surface)];
    if let Some(ws) = record.workspace_path.as_deref().filter(|w| !w.is_empty()) {
        lines.push(format!("Workspace: {ws}"));
    }
    if let Some(branch) = record.git_branch.as_deref().filter(|b| !b.is_empty()) {
        lines.push(format!("Branch: {branch}"));
    }
    if let Some(model) = record.primary_model.as_deref().filter(|m| !m.is_empty()) {
        lines.push(format!("Model: {model}"));
    }
    lines.join("\n")
}

/// Synthesizes a session's active lineage into prose document text and turn-linked chunks.
///
/// # Errors
///
/// A chunk size rejected by the prose splitter.
pub fn render_session(
    record: &SessionRecord,
    chunk_size: usize,
    max_chunks: usize,
) -> Result<(String, Vec<SynthesizedTurnChunk>), String> {
    let header = session_header(record);
    let mut active_turns: Vec<&SessionTurnRecord> =
        record.turns.iter().filter(|t| t.active_ord.is_some()).collect();
    active_turns.sort_by_key(|t| t.active_ord.unwrap_or(i32::MAX));

    if active_turns.is_empty() {
        let fallback = format!(
            "{header}\n\nTurns: {}, Tool calls: {}",
            record.turns.len(),
            record.tool_calls.len()
        );
        let len = fallback.chars().count();
        return Ok((
            fallback.clone(),
            vec![SynthesizedTurnChunk {
                text: fallback,
                char_start: 0,
                char_end: len,
                direction: None,
                sender: None,
                turn_external_id: None,
            }],
        ));
    }

    let mut offset = header.chars().count();
    let mut parts = vec![header];
    let mut chunks = Vec::new();
    let cap = max_chunks.max(1);

    for turn in active_turns {
        let Some(body) = turn.content.as_deref().filter(|s| !s.trim().is_empty()) else { continue };
        let speaker = speaker_label(record, turn);
        let paragraph = match types::format_minute_utc(turn.created_at_micros) {
            Some(ts) => format!("[{ts}] {speaker}: {body}"),
            None => format!("{speaker}: {body}"),
        };
        offset += 2; // "\n\n" separator
        let length = paragraph.chars().count();
        if chunks.len() < cap {
            append_turn_chunks(
                &paragraph,
                offset,
                chunk_size,
                cap,
                record,
                turn,
                &mut chunks,
            )?;
        }
        parts.push(paragraph);
        offset += length;
    }
    Ok((parts.join("\n\n"), chunks))
}

fn append_turn_chunks(
    paragraph: &str,
    offset: usize,
    chunk_size: usize,
    cap: usize,
    record: &SessionRecord,
    turn: &SessionTurnRecord,
    chunks: &mut Vec<SynthesizedTurnChunk>,
) -> Result<(), String> {
    let pieces: Vec<String> = if paragraph.chars().count() <= chunk_size {
        vec![paragraph.to_owned()]
    } else {
        chunk_prose(paragraph, chunk_size, 0)
            .map_err(|e| e.to_string())?
            .into_iter()
            .map(|c| c.text)
            .collect()
    };
    let sender = if turn.is_self || turn.role == "user" {
        Some("me".to_owned())
    } else {
        turn.model.clone().or_else(|| Some(record.provider.clone()))
    };
    let (mut cursor_byte, mut cursor_char) = (0_usize, 0_usize);
    for piece in pieces {
        if chunks.len() >= cap {
            break;
        }
        let (start_byte, start_char) = match paragraph[cursor_byte..].find(&piece) {
            Some(found) => {
                let sb = cursor_byte + found;
                (sb, cursor_char + paragraph[cursor_byte..sb].chars().count())
            }
            None => (cursor_byte, cursor_char),
        };
        let piece_chars = piece.chars().count();
        cursor_byte = (start_byte + piece.len()).min(paragraph.len());
        cursor_char = start_char + piece_chars;
        chunks.push(SynthesizedTurnChunk {
            text: piece,
            char_start: offset + start_char,
            char_end: offset + start_char + piece_chars,
            direction: turn.direction.clone(),
            sender: sender.clone(),
            turn_external_id: Some(turn.external_id.clone()),
        });
    }
    Ok(())
}

/// Builds `document_authors` payloads (owner + AI model identities) for a session.
#[must_use]
pub fn session_authors(record: &SessionRecord, identity: &SelfIdentity) -> Vec<AuthorPayload> {
    let mut authors = Vec::new();
    let mut models = BTreeSet::new();
    for turn in &record.turns {
        if turn.role == "assistant"
            && let Some(m) = turn.model.as_deref().filter(|s| !s.is_empty())
        {
            models.insert(m.to_owned());
        }
    }
    if models.is_empty()
        && let Some(pm) = record.primary_model.as_deref().filter(|s| !s.is_empty())
    {
        models.insert(pm.to_owned());
    }
    if models.is_empty() && record.turns.iter().any(|t| t.role == "assistant") {
        let fallback_id = record.surface.clone();
        let display = provider_display_name(&record.provider, &record.surface);
        authors.push(AuthorPayload {
            name: display.to_owned(),
            role: "sender".to_owned(),
            confidence: 1.0,
            evidence: format!("{}-session-assistant", record.provider),
            identities: vec![("ai_model".to_owned(), fallback_id)],
            is_self: false,
        });
    } else {
        let base = provider_display_name(&record.provider, &record.surface);
        for model in models {
            authors.push(AuthorPayload {
                name: format!("{base} ({model})"),
                role: "sender".to_owned(),
                confidence: 1.0,
                evidence: format!("{}-session-model", record.provider),
                identities: vec![("ai_model".to_owned(), model)],
                is_self: false,
            });
        }
    }

    if !identity.name.is_empty() {
        let wrote = record.turns.iter().any(|t| t.is_self || t.role == "user");
        authors.push(AuthorPayload {
            name: identity.name.clone(),
            role: if wrote { "sender".into() } else { "recipient".into() },
            confidence: 1.0,
            evidence: format!("{}-session-owner", record.provider),
            identities: Vec::new(),
            is_self: true,
        });
    }
    authors
}

fn build_session_meta(record: &SessionRecord) -> Map<String, Value> {
    let mut meta = record.meta.clone();
    meta.insert("provider".into(), json!(record.provider));
    meta.insert("surface".into(), json!(record.surface));
    meta.insert("session_id".into(), json!(record.external_id));
    if let Some(parent) = &record.parent_external_id {
        meta.insert("parent_session_id".into(), json!(parent));
    }
    if let Some(ws) = &record.workspace_path {
        meta.insert("workspace_path".into(), json!(ws));
    }
    if let Some(branch) = &record.git_branch {
        meta.insert("git_branch".into(), json!(branch));
    }
    if let Some(model) = &record.primary_model {
        meta.insert("primary_model".into(), json!(model));
    }
    meta.insert("turn_count".into(), json!(record.turns.len()));
    meta.insert("tool_call_count".into(), json!(record.tool_calls.len()));
    meta.insert("artifact_count".into(), json!(record.artifacts.len()));
    if let Some(started) = types::format_isoformat(record.started_at_micros) {
        meta.insert("started_at".into(), json!(started));
    }
    if let Some(updated) = types::format_isoformat(record.updated_at_micros) {
        meta.insert("updated_at".into(), json!(updated));
    }
    meta
}

/// Ingests one parsed session and its companion deliverables; returns `(indexed_docs, skipped_docs, chunks_written)`.
fn ingest_parsed_session(
    storage: &mut dyn SourceStorage,
    parsed: ParsedSession,
    context: &Context<'_>,
) -> Result<(u64, u64, u64), String> {
    let size = context.settings.chunk_size;
    let sig = signature(size);
    let (text, synth_chunks) =
        render_session(&parsed.record, size, context.settings.max_chunks_per_document)?;
    let content_hash = hex_digest(text.as_bytes());
    let existing = storage.check_stat(&parsed.uri)?;
    let session_unchanged = existing.exists
        && !context.force
        && existing.source_sha256 == parsed.source_sha256
        && existing.content_sha256 == content_hash
        && existing.chunker == sig
        && existing.state.eq_ignore_ascii_case("OK");

    let (mut indexed, mut skipped, mut written_total) = (0_u64, 0_u64, 0_u64);
    let session_external_id = parsed.record.external_id.clone();
    let authors = session_authors(&parsed.record, context.identity);

    if session_unchanged {
        storage.record_seen(&parsed.uri)?;
        skipped += 1;
    } else {
        let title = parsed
            .record
            .title
            .clone()
            .unwrap_or_else(|| parsed.record.external_id.clone());
        let meta = build_session_meta(&parsed.record);
        let session_json = SessionWritePayload::Session(Box::new(parsed.record)).to_json().to_string();
        let chunks = synth_chunks
            .into_iter()
            .enumerate()
            .map(|(ord, ch)| ChunkPayload {
                ord,
                token_count: (ch.text.chars().count() / 4).max(1),
                char_start: Some(ch.char_start),
                char_end: Some(ch.char_end),
                heading_path: Some(title.clone()),
                chunk_sha256: hex_digest(ch.text.as_bytes()),
                chunker: CHUNKER.to_owned(),
                text: ch.text,
                direction: ch.direction,
                sender: ch.sender,
                session_turn_external_id: ch.turn_external_id,
            })
            .collect();
        let document = DocumentPayload {
            title: Some(title),
            lang: None,
            byte_size: text.len() as u64,
            mtime: parsed.mtime,
            source_sha256: Some(parsed.source_sha256),
            content_sha256: content_hash,
            extractor: "session".to_owned(),
            extractor_version: VERSION.to_owned(),
            chunker: sig,
            content: text,
            meta,
            // Synthesized session transcripts are ALWAYS `communication`, preserving Garage's
            // privacy guarantee (never sent to a non-loopback host).
            corpus_class: "communication".to_owned(),
            trust_tier: context.source.default_trust.as_str().to_owned(),
            authors: authors.clone(),
            chunks,
            session_json: Some(session_json),
        };
        let written = storage.replace_document(&parsed.uri, document)?;
        indexed += 1;
        written_total += written as u64;
    }

    for comp in parsed.companions {
        let (ci, cs, cw) = ingest_companion_document(storage, &session_external_id, comp, &authors, context)?;
        indexed += ci;
        skipped += cs;
        written_total += cw;
    }
    Ok((indexed, skipped, written_total))
}

fn ingest_companion_document(
    storage: &mut dyn SourceStorage,
    session_external_id: &str,
    comp: CompanionDocument,
    authors: &[AuthorPayload],
    context: &Context<'_>,
) -> Result<(u64, u64, u64), String> {
    let is_code = comp.extension != ".md";
    let kind = if is_code { ContentKind::Code } else { ContentKind::Markdown };
    let (size, overlap) = if is_code {
        (context.settings.code_chunk_size, context.settings.code_chunk_overlap)
    } else {
        (context.settings.chunk_size, context.settings.chunk_overlap)
    };
    let raw_chunks = chunk_text(&comp.text, kind, &comp.extension, size, overlap)
        .map_err(|e| e.to_string())?;
    let chunker_name = raw_chunks.first().map_or("markdown", |c| c.chunker.as_str());
    let sig = format!("{}:{chunker_name}:{size}:{overlap}", if is_code { "code" } else { "markdown" });
    let content_hash = hex_digest(comp.text.as_bytes());
    let existing = storage.check_stat(&comp.uri)?;
    if existing.exists
        && !context.force
        && existing.source_sha256 == comp.source_sha256
        && existing.content_sha256 == content_hash
        && existing.chunker == sig
        && existing.state.eq_ignore_ascii_case("OK")
    {
        storage.record_seen(&comp.uri)?;
        return Ok((0, 1, 0));
    }

    let link_json = SessionWritePayload::ArtifactLink {
        session_external_id: session_external_id.to_owned(),
        artifact_external_id: comp.artifact_external_id.clone(),
    }
    .to_json()
    .to_string();
    let chunks: Vec<ChunkPayload> = raw_chunks
        .into_iter()
        .take(context.settings.max_chunks_per_document.max(1))
        .map(|c| ChunkPayload {
            ord: c.ord,
            token_count: (c.text.chars().count() / 4).max(1),
            char_start: c.char_start,
            char_end: c.char_end,
            heading_path: c.heading_path,
            chunk_sha256: hex_digest(c.text.as_bytes()),
            chunker: c.chunker,
            text: c.text,
            direction: None,
            sender: None,
            session_turn_external_id: None,
        })
        .collect();
    // Respect `communication` when the source's default_class is `communication` so nothing from a
    // private session leaves loopback unless the user explicitly configured another default class.
    let corpus_class = if context.source.default_class == "communication" {
        "communication".to_owned()
    } else if is_code {
        "code".to_owned()
    } else {
        "document".to_owned()
    };
    let mut meta = comp.meta;
    meta.insert("session_id".into(), json!(session_external_id));
    meta.insert("artifact_id".into(), json!(comp.artifact_external_id));
    let document = DocumentPayload {
        title: comp.title,
        lang: None,
        byte_size: comp.text.len() as u64,
        mtime: comp.mtime,
        source_sha256: Some(comp.source_sha256),
        content_sha256: content_hash,
        extractor: "session-artifact".to_owned(),
        extractor_version: VERSION.to_owned(),
        chunker: sig,
        content: comp.text,
        meta,
        corpus_class,
        trust_tier: context.source.default_trust.as_str().to_owned(),
        authors: authors.to_vec(),
        chunks,
        session_json: Some(link_json),
    };
    let written = storage.replace_document(&comp.uri, document)?;
    Ok((1, 0, written as u64))
}

/// Ingests every session in a `claude`, `chatgpt`, or `antigravity` source; returns `true` when it
/// walked to completion without hitting `limit` or cancellation.
pub fn ingest_sessions_source(
    host: &mut dyn SourceHost,
    storage: &mut dyn SourceStorage,
    context: &Context<'_>,
    kind: &str,
    limit: Option<u64>,
    counters: &mut Counters,
) -> bool {
    let root = crate::walk::expand_home(&context.source.root);
    let mut items = match kind {
        CLAUDE_KIND => claude::load_claude_sessions(&root),
        CHATGPT_KIND => chatgpt::load_chatgpt_sessions(&root),
        ANTIGRAVITY_KIND => antigravity::load_antigravity_sessions(&root),
        _ => Vec::new(),
    };

    // Order root sessions before subagents so `parent_session_id` resolves immediately on first pass.
    items.sort_by(|a, b| match (a, b) {
        (Ok(sa), Ok(sb)) => sa
            .record
            .parent_external_id
            .is_some()
            .cmp(&sb.record.parent_external_id.is_some())
            .then_with(|| sa.uri.cmp(&sb.uri)),
        (Ok(_), Err(_)) => std::cmp::Ordering::Less,
        (Err(_), Ok(_)) => std::cmp::Ordering::Greater,
        (Err(ea), Err(eb)) => ea.cmp(eb),
    });

    for item in items {
        if host.cancelled() {
            return false;
        }
        counters.seen += 1;
        match item {
            Ok(parsed) => {
                let uri = parsed.uri.clone();
                let label = parsed
                    .record
                    .title
                    .clone()
                    .unwrap_or_else(|| parsed.record.external_id.clone());
                match ingest_parsed_session(storage, parsed, context) {
                    Ok((indexed, skipped, written)) => {
                        counters.indexed += indexed;
                        counters.skipped += skipped;
                        counters.chunks_written += written;
                    }
                    Err(err) => {
                        counters.note_error(format!("{label}: {err}"));
                        let _ = storage.record_seen(&uri);
                    }
                }
                host.progress("ingest", Some(&label), counters);
            }
            Err(err) => {
                counters.note_error(err);
                host.progress("ingest", None, counters);
            }
        }
        if limit.is_some_and(|max| counters.seen >= max) {
            return false;
        }
    }
    true
}

#[cfg(test)]
mod tests;

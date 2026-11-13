//! Relational persistence for AI assistant sessions (`025_sessions.sql`), executed inside
//! [`crate::gateway::replace_document`]'s transaction so `documents`, `chunks` (with
//! `chunks.session_turn_id`), `sessions`, `session_turns`, `session_tool_calls`, and
//! `session_artifacts` commit atomically.

use std::collections::HashMap;

use garage_ingest::sessions::{
    SessionArtifactRecord, SessionRecord, SessionToolCallRecord, SessionTurnRecord, SessionWritePayload, micros_to_utc,
};
use serde_json::Value;
use tokio_postgres::Transaction;

use crate::db::hex_bytes;
use crate::error::{Result, ServiceError};
use crate::gateway::get_or_create_author;

/// Persists `session_json` (when present) inside `replace_document`'s transaction and returns
/// `turn_external_id -> session_turns.id` for wiring `chunks.session_turn_id`.
///
/// # Errors
///
/// Invalid `session_json` structure or a PostgreSQL query error.
pub async fn persist_session_payload(
    tx: &Transaction<'_>,
    source_id: i64,
    doc_id: i64,
    content_hash: &[u8],
    session_json: Option<&str>,
) -> Result<HashMap<String, i64>> {
    let Some(raw) = session_json.filter(|s| !s.trim().is_empty()) else {
        return Ok(HashMap::new());
    };
    let parsed_val: Value =
        serde_json::from_str(raw).map_err(|e| ServiceError::invalid(format!("invalid session_json: {e}")))?;
    let payload = SessionWritePayload::from_json(&parsed_val).map_err(ServiceError::invalid)?;

    match payload {
        SessionWritePayload::ArtifactLink { session_external_id, artifact_external_id } => {
            link_artifact_document(tx, source_id, doc_id, content_hash, &session_external_id, &artifact_external_id)
                .await?;
            Ok(HashMap::new())
        }
        SessionWritePayload::Session(record) => {
            let session_id = upsert_session_row(tx, source_id, doc_id, content_hash, &record).await?;
            let turn_ids = sync_session_turns(tx, session_id, &record.provider, &record.surface, &record.turns).await?;
            replace_session_tool_calls(tx, session_id, &turn_ids, &record.tool_calls).await?;
            sync_session_artifacts(tx, session_id, &turn_ids, &record.artifacts).await?;
            Ok(turn_ids)
        }
    }
}

async fn link_artifact_document(
    tx: &Transaction<'_>,
    source_id: i64,
    doc_id: i64,
    content_hash: &[u8],
    session_external_id: &str,
    artifact_external_id: &str,
) -> Result<()> {
    tx.execute("UPDATE session_artifacts SET document_id = NULL WHERE document_id = $1", &[&doc_id]).await?;
    tx.execute(
        "UPDATE session_artifacts sa \
         SET document_id = $1, content_sha256 = $2 \
         FROM sessions s \
         WHERE sa.session_id = s.id \
           AND s.source_id = $3 \
           AND s.external_id = $4 \
           AND sa.external_id = $5",
        &[&doc_id, &content_hash, &source_id, &session_external_id, &artifact_external_id],
    )
    .await?;
    Ok(())
}

const UPSERT_SESSION_SQL: &str = "\
    INSERT INTO sessions ( \
        source_id, provider, surface, external_id, parent_session_id, parent_external_id, \
        document_id, title, summary, workspace_path, workspace_paths, git_branch, git_commit, \
        primary_model, started_at, updated_at, turn_count, input_tokens, output_tokens, \
        cache_read_tokens, origin_uri, synthesized_sha256, synthesized_at, meta \
    ) VALUES ( \
        $1, $2, $3, $4, $5, $6, \
        $7, $8, $9, $10, $11, $12, $13, \
        $14, $15, $16, $17, $18, $19, \
        $20, $21, $22, now(), $23 \
    ) \
    ON CONFLICT (source_id, external_id) DO UPDATE SET \
        provider = EXCLUDED.provider, \
        surface = EXCLUDED.surface, \
        parent_session_id = COALESCE(EXCLUDED.parent_session_id, sessions.parent_session_id), \
        parent_external_id = EXCLUDED.parent_external_id, \
        document_id = EXCLUDED.document_id, \
        title = EXCLUDED.title, \
        summary = EXCLUDED.summary, \
        workspace_path = EXCLUDED.workspace_path, \
        workspace_paths = EXCLUDED.workspace_paths, \
        git_branch = EXCLUDED.git_branch, \
        git_commit = EXCLUDED.git_commit, \
        primary_model = EXCLUDED.primary_model, \
        started_at = EXCLUDED.started_at, \
        updated_at = EXCLUDED.updated_at, \
        turn_count = EXCLUDED.turn_count, \
        input_tokens = EXCLUDED.input_tokens, \
        output_tokens = EXCLUDED.output_tokens, \
        cache_read_tokens = EXCLUDED.cache_read_tokens, \
        origin_uri = EXCLUDED.origin_uri, \
        synthesized_sha256 = EXCLUDED.synthesized_sha256, \
        synthesized_at = now(), \
        meta = EXCLUDED.meta \
    RETURNING id";

const UPSERT_TURN_SQL: &str = "\
    INSERT INTO session_turns ( \
        session_id, external_id, parent_turn_id, parent_external_id, ord, active_ord, \
        role, direction, author_id, model, content, thinking, \
        input_tokens, output_tokens, cache_read_tokens, created_at, meta \
    ) VALUES ( \
        $1, $2, $3, $4, $5, $6, \
        $7, $8, $9, $10, $11, $12, \
        $13, $14, $15, $16, $17 \
    ) \
    ON CONFLICT (session_id, external_id) DO UPDATE SET \
        parent_turn_id = EXCLUDED.parent_turn_id, \
        parent_external_id = EXCLUDED.parent_external_id, \
        ord = EXCLUDED.ord, \
        active_ord = EXCLUDED.active_ord, \
        role = EXCLUDED.role, \
        direction = EXCLUDED.direction, \
        author_id = EXCLUDED.author_id, \
        model = EXCLUDED.model, \
        content = EXCLUDED.content, \
        thinking = EXCLUDED.thinking, \
        input_tokens = EXCLUDED.input_tokens, \
        output_tokens = EXCLUDED.output_tokens, \
        cache_read_tokens = EXCLUDED.cache_read_tokens, \
        created_at = EXCLUDED.created_at, \
        meta = EXCLUDED.meta \
    RETURNING id";

async fn upsert_session_row(
    tx: &Transaction<'_>,
    source_id: i64,
    doc_id: i64,
    content_hash: &[u8],
    record: &SessionRecord,
) -> Result<i64> {
    let parent_ext = record.parent_external_id.as_deref().filter(|p| !p.is_empty() && *p != record.external_id);
    let parent_session_id = if let Some(p_ext) = parent_ext {
        tx.query_opt("SELECT id FROM sessions WHERE source_id = $1 AND external_id = $2", &[&source_id, &p_ext])
            .await?
            .map(|r| r.get::<_, i64>(0))
    } else {
        None
    };

    tx.execute(
        "UPDATE sessions SET document_id = NULL \
         WHERE document_id = $1 AND NOT (source_id = $2 AND external_id = $3)",
        &[&doc_id, &source_id, &record.external_id],
    )
    .await?;

    let started_at = record.started_at_micros.and_then(micros_to_utc);
    let updated_at = record.updated_at_micros.and_then(micros_to_utc);
    let turn_count = i32::try_from(record.turns.len()).unwrap_or(i32::MAX);
    let meta = Value::Object(record.meta.clone());

    let session_id: i64 = tx
        .query_one(
            UPSERT_SESSION_SQL,
            &[
                &source_id,
                &record.provider,
                &record.surface,
                &record.external_id,
                &parent_session_id,
                &parent_ext,
                &doc_id,
                &record.title,
                &record.summary,
                &record.workspace_path,
                &record.workspace_paths,
                &record.git_branch,
                &record.git_commit,
                &record.primary_model,
                &started_at,
                &updated_at,
                &turn_count,
                &record.input_tokens,
                &record.output_tokens,
                &record.cache_read_tokens,
                &record.origin_uri,
                &content_hash,
                &meta,
            ],
        )
        .await?
        .get(0);

    tx.execute(
        "UPDATE sessions SET parent_session_id = $1 \
         WHERE source_id = $2 AND parent_external_id = $3 AND id <> $1 \
           AND parent_session_id IS DISTINCT FROM $1",
        &[&session_id, &source_id, &record.external_id],
    )
    .await?;

    Ok(session_id)
}

async fn sync_session_turns(
    tx: &Transaction<'_>,
    session_id: i64,
    provider: &str,
    surface: &str,
    turns: &[SessionTurnRecord],
) -> Result<HashMap<String, i64>> {
    let self_author_id: Option<i64> =
        tx.query_opt("SELECT id FROM authors WHERE is_self ORDER BY id LIMIT 1", &[]).await?.map(|r| r.get(0));
    let mut model_authors: HashMap<String, i64> = HashMap::new();
    let mut turn_ids: HashMap<String, i64> = HashMap::with_capacity(turns.len());
    let mut kept_ids: Vec<i64> = Vec::with_capacity(turns.len());
    let mut deferred_parents: Vec<(i64, String)> = Vec::new();
    let stmt = tx.prepare(UPSERT_TURN_SQL).await?;

    for turn in turns {
        let author_id = resolve_turn_author(tx, provider, surface, turn, self_author_id, &mut model_authors).await?;
        let parent_ext = turn.parent_external_id.as_deref().filter(|p| !p.is_empty() && *p != turn.external_id);
        let known_parent_id = parent_ext.and_then(|p| turn_ids.get(p).copied());
        let created_at = turn.created_at_micros.and_then(micros_to_utc);
        let meta = Value::Object(turn.meta.clone());
        let id: i64 = tx
            .query_one(
                &stmt,
                &[
                    &session_id,
                    &turn.external_id,
                    &known_parent_id,
                    &parent_ext,
                    &turn.ord,
                    &turn.active_ord,
                    &turn.role,
                    &turn.direction,
                    &author_id,
                    &turn.model,
                    &turn.content,
                    &turn.thinking,
                    &turn.input_tokens,
                    &turn.output_tokens,
                    &turn.cache_read_tokens,
                    &created_at,
                    &meta,
                ],
            )
            .await?
            .get(0);
        if known_parent_id.is_none()
            && let Some(p_ext) = parent_ext
        {
            deferred_parents.push((id, p_ext.to_owned()));
        }
        turn_ids.insert(turn.external_id.clone(), id);
        kept_ids.push(id);
    }

    if kept_ids.is_empty() {
        tx.execute("DELETE FROM session_turns WHERE session_id = $1", &[&session_id]).await?;
    } else {
        tx.execute("DELETE FROM session_turns WHERE session_id = $1 AND NOT (id = ANY($2))", &[&session_id, &kept_ids])
            .await?;
    }

    for (turn_id, parent_ext) in deferred_parents {
        if let Some(&parent_id) = turn_ids.get(&parent_ext)
            && parent_id != turn_id
        {
            tx.execute("UPDATE session_turns SET parent_turn_id = $2 WHERE id = $1", &[&turn_id, &parent_id]).await?;
        }
    }
    Ok(turn_ids)
}

async fn resolve_turn_author(
    tx: &Transaction<'_>,
    provider: &str,
    surface: &str,
    turn: &SessionTurnRecord,
    self_author_id: Option<i64>,
    model_authors: &mut HashMap<String, i64>,
) -> Result<Option<i64>> {
    if turn.is_self {
        return Ok(self_author_id);
    }
    if turn.role != "assistant" {
        return Ok(None);
    }
    let Some(model) = turn.model.as_deref().filter(|m| !m.is_empty()) else {
        return Ok(None);
    };
    if let Some(&cached) = model_authors.get(model) {
        return Ok(Some(cached));
    }
    let prefix = match (provider, surface) {
        (_, "codex") => "Codex",
        ("claude", _) => "Claude",
        ("chatgpt", _) => "ChatGPT",
        ("antigravity", _) => "Antigravity",
        _ => "Assistant",
    };
    let display = format!("{prefix} ({model})");
    let identities = vec![("ai_model".to_owned(), model.to_owned())];
    let id = get_or_create_author(tx, &display, &identities, false).await?;
    model_authors.insert(model.to_owned(), id);
    Ok(Some(id))
}

async fn replace_session_tool_calls(
    tx: &Transaction<'_>,
    session_id: i64,
    turn_ids: &HashMap<String, i64>,
    calls: &[SessionToolCallRecord],
) -> Result<()> {
    tx.execute("DELETE FROM session_tool_calls WHERE session_id = $1", &[&session_id]).await?;
    if calls.is_empty() {
        return Ok(());
    }
    let stmt = tx
        .prepare(
            "INSERT INTO session_tool_calls ( \
                 session_id, turn_id, result_turn_id, ord, external_call_id, \
                 tool_name, tool_kind, target_path, command, status, \
                 arguments, output_preview, output_bytes, created_at \
             ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14) \
             ON CONFLICT (turn_id, ord) DO UPDATE SET \
                 result_turn_id = EXCLUDED.result_turn_id, \
                 external_call_id = EXCLUDED.external_call_id, \
                 tool_name = EXCLUDED.tool_name, \
                 tool_kind = EXCLUDED.tool_kind, \
                 target_path = EXCLUDED.target_path, \
                 command = EXCLUDED.command, \
                 status = EXCLUDED.status, \
                 arguments = EXCLUDED.arguments, \
                 output_preview = EXCLUDED.output_preview, \
                 output_bytes = EXCLUDED.output_bytes, \
                 created_at = EXCLUDED.created_at",
        )
        .await?;
    let mut per_turn_ord: HashMap<i64, i32> = HashMap::new();
    for call in calls {
        let Some(&turn_id) = turn_ids.get(&call.turn_external_id) else { continue };
        let result_turn_id = call.result_turn_external_id.as_deref().and_then(|ext| turn_ids.get(ext).copied());
        let next_ord = per_turn_ord.entry(turn_id).or_insert(0);
        let ord = if call.ord >= *next_ord { call.ord } else { *next_ord };
        *next_ord = ord + 1;
        let args = Value::Object(call.arguments.clone());
        let created_at = call.created_at_micros.and_then(micros_to_utc);
        tx.execute(
            &stmt,
            &[
                &session_id,
                &turn_id,
                &result_turn_id,
                &ord,
                &call.external_call_id,
                &call.tool_name,
                &call.tool_kind,
                &call.target_path,
                &call.command,
                &call.status,
                &args,
                &call.output_preview,
                &call.output_bytes,
                &created_at,
            ],
        )
        .await?;
    }
    Ok(())
}

async fn sync_session_artifacts(
    tx: &Transaction<'_>,
    session_id: i64,
    turn_ids: &HashMap<String, i64>,
    artifacts: &[SessionArtifactRecord],
) -> Result<()> {
    if artifacts.is_empty() {
        tx.execute("DELETE FROM session_artifacts WHERE session_id = $1", &[&session_id]).await?;
        return Ok(());
    }
    let stmt = tx
        .prepare(
            "INSERT INTO session_artifacts ( \
                 session_id, turn_id, external_id, kind, title, mime, uri, content_sha256, meta \
             ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9) \
             ON CONFLICT (session_id, external_id) DO UPDATE SET \
                 turn_id = EXCLUDED.turn_id, \
                 kind = EXCLUDED.kind, \
                 title = EXCLUDED.title, \
                 mime = EXCLUDED.mime, \
                 uri = EXCLUDED.uri, \
                 content_sha256 = COALESCE(EXCLUDED.content_sha256, session_artifacts.content_sha256), \
                 meta = EXCLUDED.meta \
             RETURNING id",
        )
        .await?;
    let mut kept_ids = Vec::with_capacity(artifacts.len());
    for art in artifacts {
        let turn_id = art.turn_external_id.as_deref().and_then(|ext| turn_ids.get(ext).copied());
        let sha = art.content_sha256.as_deref().filter(|s| !s.is_empty()).map(hex_bytes);
        let meta = Value::Object(art.meta.clone());
        let id: i64 = tx
            .query_one(
                &stmt,
                &[&session_id, &turn_id, &art.external_id, &art.kind, &art.title, &art.mime, &art.uri, &sha, &meta],
            )
            .await?
            .get(0);
        kept_ids.push(id);
    }
    tx.execute("DELETE FROM session_artifacts WHERE session_id = $1 AND NOT (id = ANY($2))", &[&session_id, &kept_ids])
        .await?;
    Ok(())
}

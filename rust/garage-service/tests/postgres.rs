//! Tests against a real Postgres + pgvector server: the former `test_postgres.py`'s cases
//! for what this crate ports (the migrations, the per-model DDL and operator classes, the
//! ingest facade, the search query, the egress filter on pending chunks), each against a fresh
//! `garage_test_*` database that is dropped afterwards. They run when `GARAGE_TEST_DATABASE_URL`
//! names a server reached as a superuser and pass without running when it is unset.

// Test fixtures: sizes of literal strings, and file names of one known shape.
#![allow(clippy::cast_possible_wrap, clippy::case_sensitive_file_extension_comparisons)]

mod common;

use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

use common::*;
use garage_service::db::parse_vector;
use garage_service::embedding::{backfill_distilled, count_pending};
use garage_service::error::ServiceError;
use garage_service::gateway::{
    AuthorPayload, ChunkPayload, DocumentPayload, check_stat, record_extract_failed, record_no_text, replace_document,
};
use garage_service::migrate::{apply_migrations, pending_migrations};
use garage_service::models::{EmbeddingModel, ModelSpec, get_model, register_model};
use garage_service::registry::potential_fact_table_name;
use garage_service::search::{QueryEmbedder, SearchFilters, SearchHit, search};
use serde_json::{Value, json};

// -- migrations -------------------------------------------------------------------------------

#[test]
fn a_migrated_database_has_nothing_pending_and_every_migration_re_applies_cleanly() {
    with_db(|pool| {
        Box::pin(async move {
            let client = pool.get().await.unwrap();
            assert!(pending_migrations(&client, &sql_dir()).await.unwrap().is_empty());
            let applied: BTreeSet<String> = apply_migrations(&client, &sql_dir())
                .await
                .unwrap()
                .iter()
                .map(|p| p.split('.').next().unwrap().to_owned())
                .collect();
            let expected: BTreeSet<String> = std::fs::read_dir(sql_dir())
                .unwrap()
                .filter_map(|e| e.ok().and_then(|e| e.file_name().into_string().ok()))
                .filter(|n| n.starts_with('0') && n.ends_with(".sql") && n != "001_extensions.sql")
                .map(|n| n.trim_end_matches(".sql").to_owned())
                .collect();
            assert!(applied.is_superset(&expected), "{applied:?} lacks some of {expected:?}");
        })
    });
}

#[test]
fn migration_008_moves_scan_data_out_of_config() {
    with_db(|pool| {
        Box::pin(async move {
            let client = pool.get().await.unwrap();
            client.batch_execute("ALTER TABLE sources ADD COLUMN IF NOT EXISTS expected_items bigint").await.unwrap();
            source(
                &client,
                "docs",
                json!({"include_code": false, "item_type": "documents", "scan_details": {"md": 3}, "scanned_at": 1.7e9}),
            )
            .await;
            source(
                &client,
                "odd",
                json!({"item_type": "messages", "scan_details": "not an object", "scanned_at": "noon"}),
            )
            .await;
            source(&client, "plain", json!({"include_code": true})).await;
            apply_twice(&client, "008_source_scan.sql").await;

            let rows: BTreeMap<String, (Value, Option<String>, Value, bool)> = client
                .query("SELECT slug, config, scan_item_type, scan_details, scanned_at IS NOT NULL FROM sources", &[])
                .await
                .unwrap()
                .iter()
                .map(|r| (r.get(0), (r.get(1), r.get(2), r.get(3), r.get(4))))
                .collect();
            assert_eq!(
                rows["docs"],
                (json!({"include_code": false}), Some("documents".into()), json!({"md": 3}), true)
            );
            // Malformed values are dropped from config without being carried over.
            assert_eq!(rows["odd"], (json!({}), Some("messages".into()), json!({}), false));
            assert_eq!(rows["plain"].0, json!({"include_code": true}));
            assert_eq!(rows["plain"].1, None);
            assert!(!columns(&client, "sources").await.contains(&"expected_items".to_owned()));
        })
    });
}

#[test]
fn migration_010_drops_the_cloud_enrichment_column() {
    with_db(|pool| {
        Box::pin(async move {
            let client = pool.get().await.unwrap();
            client
                .batch_execute("ALTER TABLE sources ADD COLUMN allow_cloud_enrichment boolean NOT NULL DEFAULT false")
                .await
                .unwrap();
            source(&client, "docs", json!({})).await;
            apply_twice(&client, "010_drop_cloud_enrichment.sql").await;
            assert!(!columns(&client, "sources").await.contains(&"allow_cloud_enrichment".to_owned()));
            assert_eq!(scalar::<String>(&client, "SELECT slug FROM sources", &[]).await, "docs");
        })
    });
}

#[test]
fn migration_011_drops_empty_placeholder_documents() {
    with_db(|pool| {
        Box::pin(async move {
            let client = pool.get().await.unwrap();
            let source_id = source(&client, "cloud", json!({})).await;
            client
                .execute(
                    "INSERT INTO documents (source_id, uri, corpus_class, trust_tier, title, content_sha256, extractor, \
                     state, error) VALUES ($1, '/stub.pdf', 'document', 'authored', 'stub', '', 'none', 'placeholder', \
                     'not materialized')",
                    &[&source_id],
                )
                .await
                .unwrap();
            let chunk_id =
                chunk(&client, source_id, "Evicted", "Indexed before the sync client evicted it", "document").await;
            client
                .execute(
                    "UPDATE documents SET state = 'placeholder', error = 'not materialized' \
                     WHERE id = (SELECT document_id FROM chunks WHERE id = $1)",
                    &[&chunk_id],
                )
                .await
                .unwrap();
            apply_twice(&client, "011_drop_placeholder_documents.sql").await;
            let rows: Vec<(String, String, Option<String>)> = client
                .query("SELECT title, state::text, error FROM documents", &[])
                .await
                .unwrap()
                .iter()
                .map(|r| (r.get(0), r.get(1), r.get(2)))
                .collect();
            assert_eq!(rows, vec![("Evicted".to_owned(), "ok".to_owned(), None)]);
        })
    });
}

#[test]
#[allow(clippy::too_many_lines)]
fn migration_025_creates_the_common_session_schema_and_cascades_cleanly() {
    with_db(|pool| {
        Box::pin(async move {
            let client = pool.get().await.unwrap();
            apply_twice(&client, "025_sessions.sql").await;

            // Cloud kinds and all three vendor session source kinds are accepted; an unknown kind is still refused.
            for (slug, kind) in [("gm", "gmail"), ("cc", "claude"), ("cx", "chatgpt"), ("agy", "antigravity")] {
                client
                    .execute(
                        "INSERT INTO sources (slug, kind, root, default_class, default_trust) \
                         VALUES ($1, $2, '/tmp', 'communication', 'received')",
                        &[&slug, &kind],
                    )
                    .await
                    .unwrap();
            }
            assert!(
                client
                    .execute(
                        "INSERT INTO sources (slug, kind, root, default_trust) \
                         VALUES ('bad', 'bogus', '/tmp', 'received')",
                        &[],
                    )
                    .await
                    .is_err()
            );

            let agy_source: i64 = scalar(&client, "SELECT id FROM sources WHERE slug = 'agy'", &[]).await;
            let model_author: i64 = scalar(
                &client,
                "INSERT INTO authors (display_name, is_self) VALUES ('Gemini 4 Carbon', false) RETURNING id",
                &[],
            )
            .await;
            client
                .execute(
                    "INSERT INTO author_identities (author_id, kind, value) \
                     VALUES ($1, 'ai_model', 'gemini-4-carbon')",
                    &[&model_author],
                )
                .await
                .unwrap();

            // Synthesized session document + companion plan artifact document.
            let synth_chunk = chunk(&client, agy_source, "session-doc", "Me: build a schema", "communication").await;
            let synth_doc: i64 = scalar(&client, "SELECT document_id FROM chunks WHERE id = $1", &[&synth_chunk]).await;
            let plan_doc = document(&client, agy_source, "plan", "# Implementation Plan", "document").await;

            let parent_session: i64 = scalar(
                &client,
                "INSERT INTO sessions (source_id, provider, surface, external_id, document_id, title, \
                 workspace_path, workspace_paths, primary_model, turn_count) \
                 VALUES ($1, 'antigravity', 'antigravity', 'conv-1', $2, 'Schema design', \
                 '/Users/dev/garage-rag', ARRAY['/Users/dev/garage-rag', '/Users/dev/garage-enterprise'], \
                 'gemini-4-carbon', 2) RETURNING id",
                &[&agy_source, &synth_doc],
            )
            .await;
            let _subagent_session: i64 = scalar(
                &client,
                "INSERT INTO sessions (source_id, provider, surface, external_id, parent_session_id, \
                 parent_external_id) VALUES ($1, 'antigravity', 'antigravity', 'sub-1', $2, 'conv-1') RETURNING id",
                &[&agy_source, &parent_session],
            )
            .await;

            let user_turn: i64 = scalar(
                &client,
                "INSERT INTO session_turns (session_id, external_id, ord, active_ord, role, direction, content) \
                 VALUES ($1, 'step:0', 0, 0, 'user', 'sent', 'build a common schema for the database') RETURNING id",
                &[&parent_session],
            )
            .await;
            let assistant_turn: i64 = scalar(
                &client,
                "INSERT INTO session_turns (session_id, external_id, parent_turn_id, parent_external_id, \
                 ord, active_ord, role, direction, author_id, model, content, thinking, output_tokens) \
                 VALUES ($1, 'step:1', $2, 'step:0', 1, 1, 'assistant', 'received', $3, 'gemini-4-carbon', \
                 'Created 025_sessions.sql.', 'Checking 003_core.sql constraints first.', 412) RETURNING id",
                &[&parent_session, &user_turn, &model_author],
            )
            .await;

            // Full-text tsvector on visible turn content matches `schema`, not `constraints` (in thinking).
            assert_eq!(
                scalar::<i64>(
                    &client,
                    "SELECT count(*) FROM session_turns WHERE tsv @@ plainto_tsquery('english', 'schema')",
                    &[],
                )
                .await,
                1
            );
            assert_eq!(
                scalar::<i64>(
                    &client,
                    "SELECT count(*) FROM session_turns WHERE tsv @@ plainto_tsquery('english', 'constraints')",
                    &[],
                )
                .await,
                0
            );

            client
                .execute("UPDATE chunks SET session_turn_id = $1 WHERE id = $2", &[&user_turn, &synth_chunk])
                .await
                .unwrap();
            client
                .execute(
                    "INSERT INTO session_tool_calls (session_id, turn_id, ord, tool_name, tool_kind, \
                     target_path, status, output_bytes) \
                     VALUES ($1, $2, 0, 'write_file', 'write', '/Users/dev/garage-rag/data/sql/025_sessions.sql', \
                     'ok', 8192)",
                    &[&parent_session, &assistant_turn],
                )
                .await
                .unwrap();
            client
                .execute(
                    "INSERT INTO session_artifacts (session_id, turn_id, external_id, kind, title, document_id) \
                     VALUES ($1, $2, 'implementation_plan.md', 'plan', 'Implementation Plan', $3)",
                    &[&parent_session, &assistant_turn, &plan_doc],
                )
                .await
                .unwrap();

            // Dropping the synthesized search document leaves the normalized session, turns, tool calls,
            // and artifact record intact (`ON DELETE SET NULL`).
            client.execute("DELETE FROM documents WHERE id = $1", &[&synth_doc]).await.unwrap();
            assert_eq!(
                scalar::<Option<i64>>(&client, "SELECT document_id FROM sessions WHERE id = $1", &[&parent_session])
                    .await,
                None
            );
            assert_eq!(
                scalar::<i64>(&client, "SELECT count(*) FROM session_turns WHERE session_id = $1", &[&parent_session])
                    .await,
                2
            );
            assert_eq!(scalar::<i64>(&client, "SELECT count(*) FROM session_tool_calls", &[]).await, 1);
            assert_eq!(scalar::<i64>(&client, "SELECT count(*) FROM session_artifacts", &[]).await, 1);

            // Dropping the source cascades cleanly through sessions, subagents, turns, tool calls, and artifacts.
            client.execute("DELETE FROM sources WHERE id = $1", &[&agy_source]).await.unwrap();
            assert_eq!(scalar::<i64>(&client, "SELECT count(*) FROM sessions", &[]).await, 0);
            assert_eq!(scalar::<i64>(&client, "SELECT count(*) FROM session_turns", &[]).await, 0);
            assert_eq!(scalar::<i64>(&client, "SELECT count(*) FROM session_tool_calls", &[]).await, 0);
            assert_eq!(scalar::<i64>(&client, "SELECT count(*) FROM session_artifacts", &[]).await, 0);
        })
    });
}

#[test]
fn migration_013_scopes_facts_by_prompt() {
    with_db(|pool| {
        Box::pin(async move {
            let client = pool.get().await.unwrap();
            client
                .batch_execute(
                    "DROP TABLE fact_runs; \
                     ALTER TABLE facts DROP CONSTRAINT facts_prompt_ord_unique; \
                     ALTER TABLE facts DROP COLUMN prompt_name, DROP COLUMN prompt_sha256; \
                     ALTER TABLE facts ADD CONSTRAINT facts_ord_unique UNIQUE (document_id, ord)",
                )
                .await
                .unwrap();
            let docs = source(&client, "docs", json!({})).await;
            let memo = document(&client, docs, "memo", "Acme was founded in 1998.", "document").await;
            client
                .execute(
                    "INSERT INTO facts (document_id, ord, fact) VALUES ($1, 0, 'Acme was founded in 1998.')",
                    &[&memo],
                )
                .await
                .unwrap();
            apply_twice(&client, "013_fact_prompts.sql").await;

            // The old facts came from the one built-in prompt; their hash is unknown.
            let row = client.query_one("SELECT prompt_name, prompt_sha256 FROM facts", &[]).await.unwrap();
            assert_eq!((row.get::<_, String>(0), row.get::<_, Option<Vec<u8>>>(1)), ("default".to_owned(), None));
            let constraints: BTreeSet<String> = client
                .query("SELECT conname FROM pg_constraint WHERE conrelid = 'facts'::regclass", &[])
                .await
                .unwrap()
                .iter()
                .map(|r| r.get(0))
                .collect();
            assert!(constraints.contains("facts_prompt_ord_unique") && !constraints.contains("facts_ord_unique"));
            assert!(scalar::<bool>(&client, "SELECT to_regclass('fact_runs') IS NOT NULL", &[]).await);
            // ord now counts within a prompt: another prompt's fact 0 fits beside it.
            client
                .execute(
                    "INSERT INTO facts (document_id, ord, fact, prompt_name) VALUES ($1, 0, 'Acme.', 'people')",
                    &[&memo],
                )
                .await
                .unwrap();
            let error = client
                .execute("INSERT INTO facts (document_id, ord, fact) VALUES ($1, 0, 'dup')", &[&memo])
                .await
                .unwrap_err();
            assert!(
                error.to_string().contains("facts_prompt_ord_unique")
                    || format!("{error:?}").contains("facts_prompt_ord_unique")
            );
        })
    });
}

#[test]
fn fact_runs_go_with_their_document_and_009_defaults_and_checks_distance() {
    with_db(|pool| {
        Box::pin(async move {
            let client = pool.get().await.unwrap();
            let memo = document(&client, source(&client, "docs", json!({})).await, "memo", "Acme.", "document").await;
            let zero: Vec<u8> = vec![0];
            client
                .execute(
                    "INSERT INTO fact_runs (document_id, prompt_name, prompt_sha256, content_sha256, extractor_model) \
                     VALUES ($1, 'default', $2, $2, 'm')",
                    &[&memo, &zero],
                )
                .await
                .unwrap();
            client.execute("DELETE FROM documents WHERE id = $1", &[&memo]).await.unwrap();
            assert_eq!(count(&client, "SELECT count(*) FROM fact_runs").await, 0);

            client
                .batch_execute(
                    "INSERT INTO embedding_models (slug, provider, model_ref, dims, stored_dims, storage_kind, \
                     index_kind, table_name) VALUES ('legacy', 'ollama', 'x', 3, 3, 'vector', 'hnsw', 'emb_legacy')",
                )
                .await
                .unwrap();
            assert_eq!(scalar::<String>(&client, "SELECT distance FROM embedding_models", &[]).await, "cosine");
            let error = client.batch_execute("UPDATE embedding_models SET distance = 'manhattan'").await.unwrap_err();
            assert!(format!("{error:?}").contains("embedding_models_distance_check"));
        })
    });
}

#[test]
fn migration_017_moves_fact_vectors_to_their_own_table() {
    for dims in [8usize, 4096] {
        with_db(move |pool| {
            Box::pin(async move {
                let mut client = pool.get().await.unwrap();
                let model = register_model(&mut client, &ModelSpec::new("old", "old", dims), false).await.unwrap();
                let facts = potential_fact_table_name(&model.table_name).unwrap();
                client.batch_execute(&format!("DROP TABLE {facts}")).await.unwrap();
                let notes = source(&client, "notes", json!({})).await;
                let content =
                    chunk(&client, notes, "heat-pumps", "Heat pumps lose efficiency in deep cold.", "document").await;
                let roof = document(&client, notes, "roof", "The roof is slate.", "document").await;
                let (fact_id, fact_chunk_id) = fact_chunk(&client, roof, "The roof is slate.").await;
                embed(&client, &model.table_name, content, &halves(dims, 1.0), "vector").await;
                embed(&client, &model.table_name, fact_chunk_id, &halves(dims, -1.0), "vector").await;
                apply_twice(&client, "017_fact_vectors.sql").await;

                let chunk_ids: Vec<i64> = client
                    .query(&format!("SELECT chunk_id FROM {}", model.table_name), &[])
                    .await
                    .unwrap()
                    .iter()
                    .map(|r| r.get(0))
                    .collect();
                assert_eq!(chunk_ids, vec![content]);
                let fact_ids: Vec<i64> = client
                    .query(&format!("SELECT fact_id FROM {facts}"), &[])
                    .await
                    .unwrap()
                    .iter()
                    .map(|r| r.get(0))
                    .collect();
                assert_eq!(fact_ids, vec![fact_id]);
                let chunk_index = index_definition(&client, &model.table_name).await;
                let fact_index = index_definition(&client, &facts).await;
                assert_eq!(fact_index, chunk_index.replace(&model.table_name, &facts));
                let column_type: String = scalar(
                    &client,
                    "SELECT format_type(atttypid, atttypmod) FROM pg_attribute WHERE attrelid = CAST($1::text AS regclass) \
                     AND attname = 'embedding'",
                    &[&facts],
                )
                .await;
                assert_eq!(column_type, format!("vector({dims})"));
            })
        });
    }
}

#[test]
fn migration_014_adds_direction_and_sender_to_chunks() {
    with_db(|pool| {
        Box::pin(async move {
            let client = pool.get().await.unwrap();
            let sms = source(&client, "sms", json!({})).await;
            let id = chunk(&client, sms, "thread", "[2026-09-24 12:00 UTC] Me: on my way", "document").await;
            apply_twice(&client, "014_chunk_direction.sql").await;
            let row = client.query_one("SELECT direction, sender FROM chunks WHERE id = $1", &[&id]).await.unwrap();
            assert_eq!((row.get::<_, Option<String>>(0), row.get::<_, Option<String>>(1)), (None, None));
            client.execute("UPDATE chunks SET direction = 'sent', sender = 'me' WHERE id = $1", &[&id]).await.unwrap();
            let error =
                client.execute("UPDATE chunks SET direction = 'sideways' WHERE id = $1", &[&id]).await.unwrap_err();
            assert!(format!("{error:?}").contains("chunks_direction_check"));
        })
    });
}

// -- ingest outcomes --------------------------------------------------------------------------

#[test]
fn no_text_is_remembered_and_updated_in_place() {
    with_db(|pool| {
        Box::pin(async move {
            let mut client = pool.get().await.unwrap();
            source(&client, "outcomes", json!({})).await;
            record_no_text(&mut client, 0, "outcomes", "/pics/photo.png", 10, 1.7e9, &"ab".repeat(32), None)
                .await
                .unwrap();
            record_no_text(&mut client, 0, "outcomes", "/pics/photo.png", 12, 1.8e9, &"cd".repeat(32), None)
                .await
                .unwrap();
            let stat = check_stat(&mut client, "outcomes", "/pics/photo.png", None).await.unwrap();
            assert_eq!(
                (stat.exists, stat.state.as_str(), stat.byte_size, stat.mtime, stat.source_sha256.as_str()),
                (true, "no_text", 12, 1.8e9, "cd".repeat(32).as_str())
            );
            assert_eq!(count(&client, "SELECT count(*) FROM ingest_outcomes").await, 1);
        })
    });
}

#[test]
fn failure_is_remembered_with_its_error() {
    with_db(|pool| {
        Box::pin(async move {
            let mut client = pool.get().await.unwrap();
            source(&client, "outcomes", json!({})).await;
            record_extract_failed(
                &mut client,
                0,
                "outcomes",
                "/docs/broken.pdf",
                "bad xref",
                5,
                1.7e9,
                &"ef".repeat(32),
                None,
            )
            .await
            .unwrap();
            assert_eq!(check_stat(&mut client, "outcomes", "/docs/broken.pdf", None).await.unwrap().state, "failed");
            let row =
                client.query_one("SELECT outcome, error, extractor_revision FROM ingest_outcomes", &[]).await.unwrap();
            assert_eq!(
                (row.get::<_, String>(0), row.get::<_, Option<String>>(1), row.get::<_, String>(2)),
                ("failed".to_owned(), Some("bad xref".to_owned()), "pdf:1".to_owned())
            );
        })
    });
}

#[test]
fn an_outcome_from_another_extractor_version_is_ignored() {
    with_db(|pool| {
        Box::pin(async move {
            let mut client = pool.get().await.unwrap();
            source(&client, "outcomes", json!({})).await;
            record_no_text(&mut client, 0, "outcomes", "/pics/photo.png", 10, 1.7e9, &"ab".repeat(32), None)
                .await
                .unwrap();
            client.batch_execute("UPDATE ingest_outcomes SET extractor_revision = 'image:0'").await.unwrap();
            assert!(!check_stat(&mut client, "outcomes", "/pics/photo.png", None).await.unwrap().exists);
            // A Rust reader's own revision is honoured over the Python table.
            assert!(check_stat(&mut client, "outcomes", "/pics/photo.png", Some("image:0")).await.unwrap().exists);
        })
    });
}

fn payload(content: &str, chunks: Vec<ChunkPayload>, content_sha: &str) -> DocumentPayload {
    DocumentPayload {
        title: Some("a".into()),
        lang: None,
        byte_size: content.len() as i64,
        mtime: 1.8e9,
        source_sha256: content_sha.to_owned(),
        content_sha256: content_sha.to_owned(),
        extractor: "markdown".into(),
        extractor_version: "1".into(),
        chunker: Some("test".into()),
        content: Some(content.to_owned()),
        meta: serde_json::Map::new(),
        corpus_class: "document".into(),
        trust_tier: "authored".into(),
        authors: Vec::new(),
        chunks,
        session_json: None,
    }
}

#[test]
fn indexing_the_file_forgets_its_outcome() {
    with_db(|pool| {
        Box::pin(async move {
            let mut client = pool.get().await.unwrap();
            source(&client, "outcomes", json!({})).await;
            record_no_text(&mut client, 0, "outcomes", "/notes/a.md", 1, 1.7e9, &"ab".repeat(32), None).await.unwrap();
            let mut doc = payload("text", Vec::new(), &"ef".repeat(32));
            doc.source_sha256 = "cd".repeat(32);
            doc.chunker = None;
            replace_document(&mut client, 0, "outcomes", "/notes/a.md", &doc).await.unwrap();
            assert_eq!(count(&client, "SELECT count(*) FROM ingest_outcomes").await, 0);
            assert_eq!(
                check_stat(&mut client, "outcomes", "/notes/a.md", None).await.unwrap().state.to_uppercase(),
                "OK"
            );
        })
    });
}

// -- replacing a document ---------------------------------------------------------------------

async fn chunks_of(
    client: &Client,
    texts: &[&str],
    direction: Option<&str>,
    sender: Option<&str>,
) -> Vec<ChunkPayload> {
    let mut out = Vec::new();
    for (i, text) in texts.iter().enumerate() {
        out.push(ChunkPayload {
            ord: i32::try_from(i).unwrap(),
            text: (*text).to_owned(),
            token_count: None,
            char_start: None,
            char_end: None,
            heading_path: None,
            chunk_sha256: hex(&sha256(client, text).await),
            chunker: Some("test".into()),
            direction: direction.map(str::to_owned),
            sender: sender.map(str::to_owned),
            session_turn_external_id: None,
        });
    }
    out
}

async fn replace(client: &mut Client, chunks: Vec<ChunkPayload>) {
    let content = chunks.iter().map(|c| c.text.as_str()).collect::<Vec<_>>().join("\n");
    let sha = hex(&sha256(client, &content).await);
    replace_document(client, 0, "replace", "/notes/a.md", &payload(&content, chunks, &sha)).await.unwrap();
}

async fn rows(client: &Client) -> BTreeMap<i32, (i64, String)> {
    client
        .query("SELECT id, ord, text FROM chunks ORDER BY ord", &[])
        .await
        .unwrap()
        .iter()
        .map(|r| (r.get::<_, i32>(1), (r.get::<_, i64>(0), r.get::<_, String>(2))))
        .collect()
}

#[test]
fn unchanged_chunks_keep_their_rows_and_vectors() {
    with_db(|pool| {
        Box::pin(async move {
            let mut client = pool.get().await.unwrap();
            let model = register_model(&mut client, &ModelSpec::new("small", "small", 8), false).await.unwrap();
            source(&client, "replace", json!({})).await;
            let first = chunks_of(&client, &["first", "second", "third"], None, None).await;
            replace(&mut client, first).await;
            let before = rows(&client).await;
            for (chunk_id, _) in before.values() {
                embed(&client, &model.table_name, *chunk_id, &halves(8, 1.0), "vector").await;
            }
            let second = chunks_of(&client, &["first", "changed", "third", "fourth"], None, None).await;
            replace(&mut client, second).await;
            let after = rows(&client).await;

            let texts: Vec<&str> = after.values().map(|(_, t)| t.as_str()).collect();
            assert_eq!(texts, ["first", "changed", "third", "fourth"]);
            assert_eq!(after[&0].0, before[&0].0);
            assert_eq!(after[&2].0, before[&2].0);
            assert_ne!(after[&1].0, before[&1].0);
            let embedded: BTreeSet<i64> = client
                .query(&format!("SELECT chunk_id FROM {}", model.table_name), &[])
                .await
                .unwrap()
                .iter()
                .map(|r| r.get(0))
                .collect();
            assert_eq!(embedded, BTreeSet::from([before[&0].0, before[&2].0]));
        })
    });
}

#[test]
fn a_shorter_document_drops_the_chunks_past_its_end() {
    with_db(|pool| {
        Box::pin(async move {
            let mut client = pool.get().await.unwrap();
            source(&client, "replace", json!({})).await;
            let two = chunks_of(&client, &["first", "second"], None, None).await;
            replace(&mut client, two).await;
            let first = rows(&client).await[&0].0;
            let one = chunks_of(&client, &["first"], None, None).await;
            replace(&mut client, one).await;
            assert_eq!(rows(&client).await, BTreeMap::from([(0, (first, "first".to_owned()))]));
        })
    });
}

#[test]
fn a_kept_chunk_takes_its_new_direction_and_sender() {
    with_db(|pool| {
        Box::pin(async move {
            let mut client = pool.get().await.unwrap();
            source(&client, "replace", json!({})).await;
            let plain = chunks_of(&client, &["see you at 7"], None, None).await;
            replace(&mut client, plain).await;
            let before = rows(&client).await[&0].0;
            let directed = chunks_of(&client, &["see you at 7"], Some("received"), Some("+15551234567")).await;
            replace(&mut client, directed).await;
            let row = client.query_one("SELECT id, direction, sender FROM chunks", &[]).await.unwrap();
            assert_eq!(
                (row.get::<_, i64>(0), row.get::<_, Option<String>>(1), row.get::<_, Option<String>>(2)),
                (before, Some("received".into()), Some("+15551234567".into()))
            );
        })
    });
}

// -- model tables -----------------------------------------------------------------------------

fn spec(slug: &str, dims: usize, distance: &str) -> ModelSpec {
    ModelSpec { distance: distance.to_owned(), ..ModelSpec::new(slug, slug, dims) }
}

#[test]
fn the_index_is_built_for_the_models_distance_and_width() {
    with_db(|pool| {
        Box::pin(async move {
            let mut client = pool.get().await.unwrap();
            for (distance, ops) in
                [("cosine", "vector_cosine_ops"), ("l2", "vector_l2_ops"), ("inner_product", "vector_ip_ops")]
            {
                let model =
                    register_model(&mut client, &spec(&format!("small_{distance}"), 8, distance), false).await.unwrap();
                assert_eq!(model.distance, distance);
                assert!(index_definition(&client, &model.table_name).await.contains(ops));
            }
            let wide = register_model(&mut client, &spec("wide", 3000, "l2"), false).await.unwrap();
            assert_eq!((wide.storage_kind.as_str(), wide.index_kind.as_str()), ("halfvec", "hnsw"));
            assert!(index_definition(&client, &wide.table_name).await.contains("halfvec_l2_ops"));
            let huge = register_model(&mut client, &spec("huge", 4096, "cosine"), false).await.unwrap();
            assert_eq!((huge.storage_kind.as_str(), huge.index_kind.as_str()), ("vector", "hnsw_bq"));
            let index = index_definition(&client, &huge.table_name).await;
            assert!(index.contains("binary_quantize(embedding)") && index.contains("bit_hamming_ops"));
        })
    });
}

#[test]
fn potential_facts_get_a_table_and_index_of_their_own() {
    with_db(|pool| {
        Box::pin(async move {
            let mut client = pool.get().await.unwrap();
            for (dims, ops) in [(8usize, "vector_cosine_ops"), (3000, "halfvec_cosine_ops"), (4096, "bit_hamming_ops")]
            {
                let slug = format!("m{dims}");
                let model = register_model(&mut client, &ModelSpec::new(&slug, &slug, dims), false).await.unwrap();
                let table = potential_fact_table_name(&model.table_name).unwrap();
                assert!(index_definition(&client, &table).await.contains(ops));
                let key = client
                    .query_one(
                        "SELECT a.attname, cf.relname FROM pg_constraint k \
                         JOIN pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = k.conkey[1] \
                         JOIN pg_class cf ON cf.oid = k.confrelid WHERE k.conrelid = CAST($1::text AS regclass) AND k.contype = 'f'",
                        &[&table],
                    )
                    .await
                    .unwrap();
                assert_eq!(
                    (key.get::<_, String>(0), key.get::<_, String>(1)),
                    ("fact_id".to_owned(), "facts".to_owned())
                );
            }
        })
    });
}

// -- search -----------------------------------------------------------------------------------

/// Answers every query with the same vector (`MagicMock().embed`).
struct FixedEmbedder(Vec<f32>);

impl QueryEmbedder for FixedEmbedder {
    fn embed_query(&self, _model: &EmbeddingModel, _query: &str) -> garage_service::Result<Vec<f32>> {
        Ok(self.0.clone())
    }
}

/// A corpus of two documents whose vectors point in opposite directions and whose words do not
/// overlap; the query matches the first in both engines.
async fn corpus(client: &mut Client, spec: &ModelSpec, kind: &str) -> (String, usize) {
    let model = register_model(client, spec, false).await.unwrap();
    let notes = source(client, "notes", json!({})).await;
    let heat = chunk(client, notes, "heat-pumps", "Heat pumps lose efficiency in deep cold.", "document").await;
    let bread = chunk(client, notes, "sourdough", "A sourdough starter needs wild yeast and flour.", "document").await;
    let dims = usize::try_from(model.stored_dims).unwrap();
    embed(client, &model.table_name, heat, &halves(dims, 1.0), kind).await;
    embed(client, &model.table_name, bread, &halves(dims, -1.0), kind).await;
    (model.slug, dims)
}

async fn titles(client: &mut Client, slug: &str, dims: usize, mode: &str) -> Vec<String> {
    let embedder = Arc::new(FixedEmbedder(halves(dims, 1.0)));
    let hits =
        search(client, embedder, "heat pump efficiency", 10, mode, Some(slug), "", 0, &SearchFilters::default(), 600)
            .await
            .unwrap();
    hits.iter().map(|h| h.title.clone().unwrap_or_default()).collect()
}

async fn fts(client: &mut Client, query: &str, filters: SearchFilters) -> garage_service::Result<Vec<SearchHit>> {
    let embedder = Arc::new(FixedEmbedder(Vec::new()));
    search(client, embedder, query, 10, "fts", None, "", 0, &filters, 600).await
}

#[test]
fn hybrid_search_ranks_the_matching_document_first() {
    for distance in ["cosine", "l2", "inner_product"] {
        with_db(move |pool| {
            Box::pin(async move {
                let mut client = pool.get().await.unwrap();
                let (slug, dims) = corpus(&mut client, &spec("m", 8, distance), "vector").await;
                assert_eq!(titles(&mut client, &slug, dims, "hybrid").await, ["heat-pumps", "sourdough"]);
            })
        });
    }
}

#[test]
fn halfvec_search_binds_a_halfvec_query_and_binary_quantized_search_re_ranks_on_the_exact_distance() {
    with_db(|pool| {
        Box::pin(async move {
            let mut client = pool.get().await.unwrap();
            let (slug, dims) = corpus(&mut client, &ModelSpec::new("wide", "wide", 3000), "halfvec").await;
            assert_eq!(titles(&mut client, &slug, dims, "vector").await, ["heat-pumps", "sourdough"]);
        })
    });
    with_db(|pool| {
        Box::pin(async move {
            let mut client = pool.get().await.unwrap();
            let (slug, dims) = corpus(&mut client, &ModelSpec::new("huge", "huge", 4096), "vector").await;
            assert_eq!(titles(&mut client, &slug, dims, "vector").await, ["heat-pumps", "sourdough"]);
        })
    });
}

#[test]
fn vector_search_finds_potential_facts_in_their_own_table() {
    for dims in [8usize, 4096] {
        with_db(move |pool| {
            Box::pin(async move {
                let mut client = pool.get().await.unwrap();
                let model = register_model(&mut client, &ModelSpec::new("m", "m", dims), false).await.unwrap();
                let notes = source(&client, "notes", json!({})).await;
                let bread =
                    chunk(&client, notes, "sourdough", "A sourdough starter needs wild yeast and flour.", "document")
                        .await;
                let heat =
                    document(&client, notes, "heat-pumps", "Heat pumps lose efficiency in deep cold.", "document")
                        .await;
                let (fact_id, _) = fact_chunk(&client, heat, "Heat pumps lose efficiency in deep cold.").await;
                embed(&client, &model.table_name, bread, &halves(dims, -1.0), "vector").await;
                embed_fact(&client, &model.table_name, fact_id, &halves(dims, 1.0), "vector").await;
                assert_eq!(titles(&mut client, &model.slug, dims, "vector").await, ["heat-pumps", "sourdough"]);
            })
        });
    }
}

#[test]
fn keyword_search_needs_no_model() {
    with_db(|pool| {
        Box::pin(async move {
            let mut client = pool.get().await.unwrap();
            let notes = source(&client, "notes", json!({})).await;
            chunk(&client, notes, "sourdough", "A sourdough starter needs wild yeast and flour.", "document").await;
            let hits = fts(&mut client, "wild yeast", SearchFilters::default()).await.unwrap();
            assert_eq!(hits.iter().map(|h| h.title.clone().unwrap()).collect::<Vec<_>>(), ["sourdough"]);
            assert_eq!(hits[0].matched_by(), "keyword");
        })
    });
}

#[test]
fn direction_keeps_to_messages_that_went_that_way() {
    with_db(|pool| {
        Box::pin(async move {
            let mut client = pool.get().await.unwrap();
            let notes = source(&client, "notes", json!({})).await;
            chunk(&client, notes, "sourdough", "A sourdough starter needs wild yeast and flour.", "document").await;
            let sent = chunk(&client, notes, "thread", "Me: bring the sourdough", "communication").await;
            let document_id: i64 = scalar(&client, "SELECT document_id FROM chunks WHERE id = $1", &[&sent]).await;
            client
                .execute("UPDATE chunks SET direction = 'sent', sender = 'me' WHERE id = $1", &[&sent])
                .await
                .unwrap();
            let digest = sha256(&client, "received").await;
            client
                .execute(
                    "INSERT INTO chunks (document_id, ord, text, chunk_sha256, chunker, direction, sender) \
                     VALUES ($1, 1, 'friend: sourdough again?', $2, 'test', 'received', 'friend@example.com')",
                    &[&document_id, &digest],
                )
                .await
                .unwrap();

            let everything = fts(&mut client, "sourdough", SearchFilters::default()).await.unwrap();
            assert_eq!(everything.len(), 3);
            let ways: BTreeSet<(Option<String>, Option<String>)> =
                everything.iter().map(|h| (h.direction.clone(), h.sender.clone())).collect();
            assert_eq!(
                ways,
                BTreeSet::from([
                    (None, None),
                    (Some("sent".into()), Some("me".into())),
                    (Some("received".into()), Some("friend@example.com".into())),
                ])
            );
            let direction = |d: &str| SearchFilters { direction: Some(d.to_owned()), ..SearchFilters::default() };
            let sent_hits = fts(&mut client, "sourdough", direction("sent")).await.unwrap();
            assert_eq!(
                sent_hits.iter().map(|h| (h.text.as_str(), h.sender.as_deref())).collect::<Vec<_>>(),
                [("Me: bring the sourdough", Some("me"))]
            );
            let received = fts(&mut client, "sourdough", direction("received")).await.unwrap();
            assert_eq!(received.iter().map(|h| h.sender.as_deref()).collect::<Vec<_>>(), [Some("friend@example.com")]);
            match fts(&mut client, "sourdough", direction("sideways")).await {
                Err(ServiceError::InvalidArgument(message)) => {
                    assert!(message.contains("direction must be one of sent, received"), "{message}");
                }
                other => panic!("expected an invalid-argument error, got {other:?}"),
            }
        })
    });
}

// -- message authors --------------------------------------------------------------------------

fn handle(handle: &str, name: Option<&str>) -> AuthorPayload {
    let kind = if handle.contains('@') { "email" } else { "phone" };
    AuthorPayload {
        name: name.unwrap_or(handle).to_owned(),
        role: "sender".into(),
        confidence: 1.0,
        evidence: Some("imessage-handle".into()),
        identities: vec![(kind.to_owned(), handle.to_owned())],
        is_self: false,
    }
}

async fn thread(client: &mut Client, uri: &str, authors: Vec<AuthorPayload>) {
    let names: Vec<&str> = authors.iter().map(|a| a.name.as_str()).collect();
    let content = format!("thread {uri} {}", names.join(" "));
    let sha = hex(&sha256(client, &content).await);
    let doc = DocumentPayload {
        title: Some(uri.to_owned()),
        lang: None,
        byte_size: content.len() as i64,
        mtime: 1.8e9,
        source_sha256: String::new(),
        content_sha256: sha.clone(),
        extractor: "messages".into(),
        extractor_version: "1".into(),
        chunker: Some("test".into()),
        content: Some(content.clone()),
        meta: serde_json::Map::new(),
        corpus_class: "communication".into(),
        trust_tier: "received".into(),
        authors,
        chunks: vec![ChunkPayload {
            ord: 0,
            text: content,
            token_count: None,
            char_start: None,
            char_end: None,
            heading_path: None,
            chunk_sha256: sha,
            chunker: None,
            direction: None,
            sender: None,
            session_turn_external_id: None,
        }],
        session_json: None,
    };
    replace_document(client, 0, "sms", uri, &doc).await.unwrap();
}

async fn authors(client: &Client) -> BTreeMap<String, BTreeSet<String>> {
    let mut found: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    for row in client
        .query(
            "SELECT a.display_name, ai.value FROM authors a JOIN author_identities ai ON ai.author_id = a.id \
             ORDER BY a.id, ai.value",
            &[],
        )
        .await
        .unwrap()
    {
        found.entry(row.get(0)).or_default().insert(row.get(1));
    }
    found
}

fn names(values: &[(&str, &[&str])]) -> BTreeMap<String, BTreeSet<String>> {
    values.iter().map(|(n, ids)| ((*n).to_owned(), ids.iter().map(|i| (*i).to_owned()).collect())).collect()
}

#[test]
fn a_handle_named_author_is_renamed_and_its_other_handle_merged() {
    with_db(|pool| {
        Box::pin(async move {
            let mut client = pool.get().await.unwrap();
            source(&client, "sms", json!({})).await;
            thread(&mut client, "a", vec![handle("+15551234567", None)]).await;
            thread(&mut client, "b", vec![handle("alex@example.com", None)]).await;
            assert_eq!(
                authors(&client).await,
                names(&[("+15551234567", &["+15551234567"]), ("alex@example.com", &["alex@example.com"])])
            );

            thread(&mut client, "a", vec![handle("+15551234567", Some("Alex Doe"))]).await;
            thread(&mut client, "c", vec![handle("alex@example.com", Some("Alex Doe"))]).await;
            assert_eq!(authors(&client).await, names(&[("Alex Doe", &["+15551234567", "alex@example.com"])]));
            // Thread b was not rebuilt, yet its link followed the merged author.
            let linked: Vec<(String, String)> = client
                .query(
                    "SELECT d.uri, a.display_name FROM document_authors da JOIN documents d ON d.id = da.document_id \
                     JOIN authors a ON a.id = da.author_id ORDER BY d.uri",
                    &[],
                )
                .await
                .unwrap()
                .iter()
                .map(|r| (r.get(0), r.get(1)))
                .collect();
            assert_eq!(
                linked,
                vec![
                    ("a".to_owned(), "Alex Doe".to_owned()),
                    ("b".to_owned(), "Alex Doe".to_owned()),
                    ("c".to_owned(), "Alex Doe".to_owned())
                ]
            );

            // The author filter finds the threads by name and still by number.
            let by = |author: &str| SearchFilters { author: Some(author.to_owned()), ..SearchFilters::default() };
            let by_name: BTreeSet<String> = fts(&mut client, "thread", by("alex doe"))
                .await
                .unwrap()
                .iter()
                .map(|h| h.title.clone().unwrap())
                .collect();
            let by_number: BTreeSet<String> = fts(&mut client, "thread", by("5551234567"))
                .await
                .unwrap()
                .iter()
                .map(|h| h.title.clone().unwrap())
                .collect();
            let all: BTreeSet<String> = ["a", "b", "c"].iter().map(|s| (*s).to_owned()).collect();
            assert_eq!(by_name, all);
            assert_eq!(by_number, all);
        })
    });
}

#[test]
fn a_named_author_is_not_renamed_by_a_handle() {
    with_db(|pool| {
        Box::pin(async move {
            let mut client = pool.get().await.unwrap();
            source(&client, "sms", json!({})).await;
            thread(&mut client, "a", vec![handle("+15551234567", Some("Alex Doe"))]).await;
            thread(&mut client, "b", vec![handle("+15551234567", None)]).await;
            thread(&mut client, "c", vec![handle("+15551234567", Some("Alexander"))]).await;
            assert_eq!(authors(&client).await, names(&[("Alex Doe", &["+15551234567"])]));
        })
    });
}

// -- egress -----------------------------------------------------------------------------------

#[test]
fn off_box_backfill_counts_leave_out_communications() {
    with_db(|pool| {
        Box::pin(async move {
            let mut client = pool.get().await.unwrap();
            let model = register_model(&mut client, &ModelSpec::new("m", "m", 8), false).await.unwrap();
            let mixed = source(&client, "mixed", json!({})).await;
            chunk(&client, mixed, "memo", "A memo about the roof.", "document").await;
            chunk(&client, mixed, "email", "An email about the roof.", "communication").await;
            let row = get_model(&client, Some(&model.slug), "").await.unwrap();
            assert_eq!(count_pending(&client, &row, true).await.unwrap(), 2);
            assert_eq!(count_pending(&client, &row, false).await.unwrap(), 1);
        })
    });
}

// -- distilled facts' vectors -----------------------------------------------------------------

#[test]
fn backfill_averages_each_group_once_every_member_has_a_vector() {
    with_db(|pool| {
        Box::pin(async move {
            let mut client = pool.get().await.unwrap();
            let model = register_model(&mut client, &ModelSpec::new("m", "m", 8), false).await.unwrap();
            let notes = source(&client, "notes", json!({})).await;
            let doc = document(&client, notes, "memo", "Ada wrote the notes. The roof is slate.", "document").await;
            let (ada, _) = fact_chunk(&client, doc, "The notes were written by Ada.").await;
            let (written, _) = fact_chunk(&client, doc, "Ada wrote the notes.").await;
            let (roof, _) = fact_chunk(&client, doc, "The roof is slate.").await;
            let zero: Vec<u8> = vec![0];
            let group: i64 = scalar(
                &client,
                "INSERT INTO distilled_facts (fact_class, statement, members_sha256) VALUES ('general', 'Ada wrote the notes.', $1) RETURNING id",
                &[&zero],
            )
            .await;
            let single: i64 = scalar(
                &client,
                "INSERT INTO distilled_facts (fact_class, statement, members_sha256) VALUES ('general', 'The roof is slate.', $1) RETURNING id",
                &[&zero],
            )
            .await;
            client
                .execute("UPDATE facts SET distilled_fact_id = $1 WHERE id = ANY($2)", &[&group, &vec![ada, written]])
                .await
                .unwrap();
            client.execute("UPDATE facts SET distilled_fact_id = $1 WHERE id = $2", &[&single, &roof]).await.unwrap();
            let axis = |i: usize| -> Vec<f32> { (0..8).map(|j| if j == i { 1.0 } else { 0.0 }).collect() };
            embed_fact(&client, &model.table_name, ada, &axis(2), "vector").await;
            embed_fact(&client, &model.table_name, roof, &axis(6), "vector").await;

            // The group waits until both its members have a vector.
            assert_eq!(backfill_distilled(&client, &model).await.unwrap(), 1);
            embed_fact(&client, &model.table_name, written, &axis(3), "vector").await;
            assert_eq!(backfill_distilled(&client, &model).await.unwrap(), 1);
            assert_eq!(backfill_distilled(&client, &model).await.unwrap(), 0);

            let vectors: BTreeMap<String, Vec<f32>> = client
                .query(
                    "SELECT df.statement, fe.embedding::text FROM fact_emb_m fe \
                     JOIN distilled_facts df ON df.id = fe.distilled_fact_id",
                    &[],
                )
                .await
                .unwrap()
                .iter()
                .map(|r| (r.get::<_, String>(0), parse_vector(&r.get::<_, String>(1))))
                .collect();
            assert_eq!(vectors["The roof is slate."], axis(6));
            let mean = &vectors["Ada wrote the notes."];
            let expected = std::f32::consts::FRAC_1_SQRT_2;
            assert!((mean[2] - expected).abs() < 1e-6 && (mean[3] - expected).abs() < 1e-6, "{mean:?}");
        })
    });
}

// -- AI assistant sessions (025_sessions.sql) -------------------------------------------------

#[allow(clippy::cast_possible_truncation)]
async fn session_doc_payload(client: &Client, record: &garage_ingest::sessions::SessionRecord) -> DocumentPayload {
    let (content, synth_chunks) = garage_ingest::sessions::render_session(record, 512, 200).unwrap();
    let content_sha = hex(&sha256(client, &content).await);
    let identity = garage_ingest::attribution::SelfIdentity::new("Ada Lovelace", &[]);
    let authors = garage_ingest::sessions::session_authors(record, &identity)
        .into_iter()
        .map(|a| AuthorPayload {
            name: a.name,
            role: a.role,
            confidence: a.confidence as f32,
            evidence: Some(a.evidence),
            identities: a.identities,
            is_self: a.is_self,
        })
        .collect();
    let mut chunks = Vec::with_capacity(synth_chunks.len());
    for (ord, ch) in synth_chunks.into_iter().enumerate() {
        let csha = hex(&sha256(client, &ch.text).await);
        chunks.push(ChunkPayload {
            ord: ord as i32,
            text: ch.text,
            token_count: Some(12),
            char_start: Some(ch.char_start as i32),
            char_end: Some(ch.char_end as i32),
            heading_path: record.title.clone(),
            chunk_sha256: csha,
            chunker: Some("session_turn".into()),
            direction: ch.direction,
            sender: ch.sender,
            session_turn_external_id: ch.turn_external_id,
        });
    }
    let session_json =
        garage_ingest::sessions::SessionWritePayload::Session(Box::new(record.clone())).to_json().to_string();
    DocumentPayload {
        title: record.title.clone(),
        lang: None,
        byte_size: content.len() as i64,
        mtime: 1.78e9,
        source_sha256: content_sha.clone(),
        content_sha256: content_sha,
        extractor: "session".into(),
        extractor_version: "1".into(),
        chunker: Some("session:session_turn:512".into()),
        content: Some(content),
        meta: serde_json::Map::new(),
        corpus_class: "communication".into(),
        trust_tier: "received".into(),
        authors,
        chunks,
        session_json: Some(session_json),
    }
}

#[allow(clippy::too_many_lines)]
fn sample_parent_session(extra_turn: bool) -> garage_ingest::sessions::SessionRecord {
    use garage_ingest::sessions::{SessionArtifactRecord, SessionRecord, SessionToolCallRecord, SessionTurnRecord};
    let mut turns = vec![
        SessionTurnRecord {
            external_id: "t-user-1".into(),
            parent_external_id: None,
            ord: 0,
            active_ord: Some(0),
            role: "user".into(),
            direction: Some("sent".into()),
            is_self: true,
            model: None,
            content: Some("Inspect migration 025_sessions.sql.".into()),
            thinking: None,
            input_tokens: None,
            output_tokens: None,
            cache_read_tokens: None,
            created_at_micros: Some(1_780_000_000_000_000),
            meta: serde_json::Map::new(),
        },
        SessionTurnRecord {
            external_id: "t-asst-1".into(),
            parent_external_id: Some("t-user-1".into()),
            ord: 1,
            active_ord: Some(1),
            role: "assistant".into(),
            direction: Some("received".into()),
            is_self: false,
            model: Some("claude-sonnet-4-6".into()),
            content: Some("Migration 025 defines sessions, turns, tool calls, and artifacts.".into()),
            thinking: Some("Uniquexylophone internal reasoning trace.".into()),
            input_tokens: Some(150),
            output_tokens: Some(60),
            cache_read_tokens: Some(400),
            created_at_micros: Some(1_780_000_010_000_000),
            meta: serde_json::Map::new(),
        },
        SessionTurnRecord {
            external_id: "t-tool-1".into(),
            parent_external_id: Some("t-asst-1".into()),
            ord: 2,
            active_ord: None,
            role: "tool".into(),
            direction: None,
            is_self: false,
            model: None,
            content: Some("CREATE TABLE sessions ...".into()),
            thinking: None,
            input_tokens: None,
            output_tokens: None,
            cache_read_tokens: None,
            created_at_micros: Some(1_780_000_012_000_000),
            meta: serde_json::Map::new(),
        },
    ];
    if extra_turn {
        turns.push(SessionTurnRecord {
            external_id: "t-user-2".into(),
            parent_external_id: Some("t-tool-1".into()),
            ord: 3,
            active_ord: Some(2),
            role: "user".into(),
            direction: Some("sent".into()),
            is_self: true,
            model: None,
            content: Some("Now verify cascade behavior on source removal.".into()),
            thinking: None,
            input_tokens: None,
            output_tokens: None,
            cache_read_tokens: None,
            created_at_micros: Some(1_780_000_030_000_000),
            meta: serde_json::Map::new(),
        });
    }
    SessionRecord {
        provider: "claude".into(),
        surface: "claude_code".into(),
        external_id: "sess-root-1".into(),
        parent_external_id: None,
        title: Some("Session Migration Audit".into()),
        summary: Some("Audited 025_sessions.sql".into()),
        workspace_path: Some("/Users/ada/garage-rag".into()),
        workspace_paths: vec!["/Users/ada/garage-rag".into()],
        git_branch: Some("main".into()),
        git_commit: Some("44871c8b".into()),
        primary_model: Some("claude-sonnet-4-6".into()),
        started_at_micros: Some(1_780_000_000_000_000),
        updated_at_micros: Some(1_780_000_030_000_000),
        input_tokens: Some(150),
        output_tokens: Some(60),
        cache_read_tokens: Some(400),
        origin_uri: Some("/tmp/claude/sess-root-1.jsonl".into()),
        meta: serde_json::Map::new(),
        turns,
        tool_calls: vec![SessionToolCallRecord {
            turn_external_id: "t-asst-1".into(),
            result_turn_external_id: Some("t-tool-1".into()),
            ord: 0,
            external_call_id: Some("toolu_sql".into()),
            tool_name: "Read".into(),
            tool_kind: "read".into(),
            target_path: Some("/Users/ada/garage-rag/data/sql/025_sessions.sql".into()),
            command: None,
            status: "ok".into(),
            arguments: json!({"file_path": "/Users/ada/garage-rag/data/sql/025_sessions.sql"})
                .as_object()
                .unwrap()
                .clone(),
            output_preview: Some("CREATE TABLE sessions ...".into()),
            output_bytes: Some(25),
            created_at_micros: Some(1_780_000_010_000_000),
        }],
        artifacts: vec![SessionArtifactRecord {
            turn_external_id: Some("t-asst-1".into()),
            external_id: "implementation_plan.md".into(),
            kind: "plan".into(),
            title: Some("Implementation Plan".into()),
            mime: Some("text/markdown".into()),
            uri: Some("/tmp/claude/implementation_plan.md".into()),
            content_sha256: None,
            meta: serde_json::Map::new(),
        }],
    }
}

#[test]
#[allow(clippy::too_many_lines)]
fn sessions_persist_relationally_link_artifacts_and_preserve_chunk_ids_on_append() {
    with_db(|pool| {
        Box::pin(async move {
            let mut client = pool.get().await.unwrap();
            let model = register_model(&mut client, &ModelSpec::new("m", "m", 8), false).await.unwrap();
            client
                .execute(
                    "INSERT INTO sources (slug, kind, root, default_class, default_trust) \
                     VALUES ('claude', 'claude', '/tmp/claude', 'communication', 'received')",
                    &[],
                )
                .await
                .unwrap();

            // Persist a subagent BEFORE its parent to test backward parent_session_id resolution too.
            let mut child_rec = sample_parent_session(false);
            child_rec.external_id = "sess-root-1:subagent-1".into();
            child_rec.parent_external_id = Some("sess-root-1".into());
            let child_doc = session_doc_payload(&client, &child_rec).await;
            replace_document(&mut client, 0, "claude", "/tmp/claude/sub.jsonl", &child_doc).await.unwrap();

            let parent_rec = sample_parent_session(false);
            let parent_doc = session_doc_payload(&client, &parent_rec).await;
            assert_eq!(
                replace_document(&mut client, 0, "claude", "/tmp/claude/root.jsonl", &parent_doc).await.unwrap(),
                2
            );

            let parent_sid: i64 =
                scalar(&client, "SELECT id FROM sessions WHERE external_id = 'sess-root-1'", &[]).await;
            let linked_parent: Option<i64> = scalar(
                &client,
                "SELECT parent_session_id FROM sessions WHERE external_id = 'sess-root-1:subagent-1'",
                &[],
            )
            .await;
            assert_eq!(linked_parent, Some(parent_sid), "child persisted earlier resolves parent_session_id");

            // Companion deliverable links back to session_artifacts.document_id.
            let plan_text = "# Implementation Plan\n\nRelational session persistence.";
            let plan_sha = hex(&sha256(&client, plan_text).await);
            let link_json = garage_ingest::sessions::SessionWritePayload::ArtifactLink {
                session_external_id: "sess-root-1".into(),
                artifact_external_id: "implementation_plan.md".into(),
            }
            .to_json()
            .to_string();
            let plan_payload = DocumentPayload {
                title: Some("Implementation Plan".into()),
                lang: None,
                byte_size: plan_text.len() as i64,
                mtime: 1.78e9,
                source_sha256: plan_sha.clone(),
                content_sha256: plan_sha.clone(),
                extractor: "session-artifact".into(),
                extractor_version: "1".into(),
                chunker: Some("markdown:markdown:512:50".into()),
                content: Some(plan_text.into()),
                meta: serde_json::Map::new(),
                corpus_class: "communication".into(),
                trust_tier: "received".into(),
                authors: Vec::new(),
                chunks: vec![ChunkPayload {
                    ord: 0,
                    text: plan_text.into(),
                    token_count: Some(8),
                    char_start: Some(0),
                    char_end: Some(i32::try_from(plan_text.len()).unwrap()),
                    heading_path: Some("Implementation Plan".into()),
                    chunk_sha256: plan_sha,
                    chunker: Some("markdown".into()),
                    direction: None,
                    sender: None,
                    session_turn_external_id: None,
                }],
                session_json: Some(link_json),
            };
            replace_document(&mut client, 0, "claude", "/tmp/claude/implementation_plan.md", &plan_payload)
                .await
                .unwrap();

            let art_doc_id: Option<i64> = scalar(
                &client,
                "SELECT document_id FROM session_artifacts WHERE session_id = $1 AND external_id = 'implementation_plan.md'",
                &[&parent_sid],
            )
            .await;
            assert!(art_doc_id.is_some(), "companion artifact linked to documents.id");

            // Thinking stays out of session_turns.tsv (visible content only, docs/schema.md) and out of documents/chunks.
            let thinking_hits: i64 = scalar(
                &client,
                "SELECT count(*) FROM session_turns WHERE session_id = $1 AND tsv @@ plainto_tsquery('english', 'uniquexylophone')",
                &[&parent_sid],
            )
            .await;
            assert_eq!(thinking_hits, 0);
            assert!(fts(&mut client, "uniquexylophone", SearchFilters::default()).await.unwrap().is_empty());

            // AI model author identity + tool call correlation + chunks.session_turn_id.
            let ai_authors: i64 = scalar(
                &client,
                "SELECT count(*) FROM session_turns st JOIN author_identities ai ON ai.author_id = st.author_id \
                 WHERE st.session_id = $1 AND st.external_id = 't-asst-1' AND ai.kind = 'ai_model' AND ai.value = 'claude-sonnet-4-6'",
                &[&parent_sid],
            )
            .await;
            assert_eq!(ai_authors, 1);
            let tool_linked: i64 = scalar(
                &client,
                "SELECT count(*) FROM session_tool_calls tc JOIN session_turns rt ON rt.id = tc.result_turn_id \
                 WHERE tc.session_id = $1 AND tc.tool_kind = 'read' AND rt.external_id = 't-tool-1'",
                &[&parent_sid],
            )
            .await;
            assert_eq!(tool_linked, 1);

            // Embed chunk 0 of the parent session, then append a new turn and re-persist:
            // chunk 0's id, session_turn_id, and vector row in emb_m must survive untouched!
            let (chunk0_id, turn0_id): (i64, i64) = {
                let row = client
                    .query_one(
                        "SELECT c.id, c.session_turn_id FROM chunks c JOIN documents d ON d.id = c.document_id \
                         WHERE d.uri = '/tmp/claude/root.jsonl' AND c.ord = 0",
                        &[],
                    )
                    .await
                    .unwrap();
                (row.get(0), row.get(1))
            };
            embed(&client, &model.table_name, chunk0_id, &[1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0], "vector").await;

            let appended_doc = session_doc_payload(&client, &sample_parent_session(true)).await;
            assert_eq!(
                replace_document(&mut client, 0, "claude", "/tmp/claude/root.jsonl", &appended_doc).await.unwrap(),
                3
            );
            let (chunk0_after, turn0_after): (i64, i64) = {
                let row = client
                    .query_one(
                        "SELECT c.id, c.session_turn_id FROM chunks c JOIN documents d ON d.id = c.document_id \
                         WHERE d.uri = '/tmp/claude/root.jsonl' AND c.ord = 0",
                        &[],
                    )
                    .await
                    .unwrap();
                (row.get(0), row.get(1))
            };
            assert_eq!((chunk0_after, turn0_after), (chunk0_id, turn0_id), "unchanged turn chunk & FK survive append");
            let surviving_vecs: i64 = scalar(
                &client,
                &format!("SELECT count(*) FROM {} WHERE chunk_id = $1", model.table_name),
                &[&chunk0_id],
            )
            .await;
            assert_eq!(surviving_vecs, 1, "existing vector embedding preserved across session append");

            // Privacy guarantee: off-box backfill never sees session chunks (`communication`).
            let model_row = get_model(&client, Some(&model.slug), "").await.unwrap();
            assert_eq!(count_pending(&client, &model_row, false).await.unwrap(), 0);
            assert!(count_pending(&client, &model_row, true).await.unwrap() > 0);
        })
    });
}

// -- spotlight & additional-source linking ----------------------------------------------------

#[derive(Clone)]
struct NoopEmbedder;

impl QueryEmbedder for NoopEmbedder {
    fn embed_query(&self, _: &EmbeddingModel, _: &str) -> garage_service::Result<Vec<f32>> {
        Ok(vec![0.0; 8])
    }
}

async fn typed_source(client: &garage_service::db::Client, slug: &str, kind: &str, root: &str) -> i64 {
    client
        .query_one(
            "INSERT INTO sources (slug, kind, root, default_class, default_trust) \
             VALUES ($1, $2, $3, 'document', 'authored') RETURNING id",
            &[&slug, &kind, &root],
        )
        .await
        .unwrap()
        .get(0)
}

#[allow(clippy::cast_possible_truncation)]
async fn single_chunk_doc(
    client: &garage_service::db::Client,
    title: Option<&str>,
    text: &str,
    mtime: f64,
    meta: serde_json::Map<String, Value>,
) -> DocumentPayload {
    let content_sha = hex(&sha256(client, text).await);
    DocumentPayload {
        title: title.map(str::to_owned),
        lang: Some("en".into()),
        byte_size: text.len() as i64,
        mtime,
        source_sha256: content_sha.clone(),
        content_sha256: content_sha.clone(),
        extractor: "text".into(),
        extractor_version: "1".into(),
        chunker: Some("paragraph".into()),
        content: Some(text.to_owned()),
        meta,
        corpus_class: "document".into(),
        trust_tier: "authored".into(),
        authors: vec![],
        chunks: vec![ChunkPayload {
            ord: 0,
            text: text.to_owned(),
            token_count: Some(3),
            char_start: Some(0),
            char_end: Some(text.chars().count() as i32),
            heading_path: None,
            chunk_sha256: content_sha,
            chunker: Some("paragraph".into()),
            direction: None,
            sender: None,
            session_turn_external_id: None,
        }],
        session_json: None,
    }
}

#[test]
#[allow(clippy::too_many_lines)]
fn spotlight_links_existing_document_without_duplicating_chunks_or_vectors() {
    with_db(|pool| {
        Box::pin(async move {
            use garage_service::config::Config;

            let mut client = pool.get().await.unwrap();
            let model = register_model(&mut client, &ModelSpec::new("m", "m", 8), false).await.unwrap();

            let dir = std::env::temp_dir().join(format!("garage-pg-spotlight-{}", std::process::id()));
            std::fs::create_dir_all(&dir).unwrap();
            let config_path = dir.join("garage.json");
            let raw_cfg = json!({
                "sources": [
                    { "slug": "notes", "root": "/tmp/notes", "kind": "filesystem", "class": "document", "trust": "authored" },
                    {
                        "slug": "mac-spotlight",
                        "root": "/tmp/spotlight",
                        "kind": "spotlight",
                        "class": "document",
                        "trust": "authored",
                        "query": "  kMDItemContentTypeTree == 'public.text'  "
                    }
                ]
            });
            std::fs::write(&config_path, serde_json::to_string_pretty(&raw_cfg).unwrap()).unwrap();
            let cfg = Config::load(Some(&config_path)).unwrap();
            let sync = garage_service::sources::sync_sources(&mut client, &cfg, true).await.unwrap();
            assert_eq!(sync.created, vec!["notes", "mac-spotlight"]);

            // Round-trip via import_sources & scan_targets preserves trimmed query.
            let empty_cfg = dir.join("imported.json");
            std::fs::write(&empty_cfg, "{}").unwrap();
            garage_service::sources::import_sources(&client, &empty_cfg).await.unwrap();
            let imported = Config::load(Some(&empty_cfg)).unwrap().source_specs().unwrap();
            let sp_spec = imported.iter().find(|s| s.slug == "mac-spotlight").unwrap();
            assert_eq!(sp_spec.kind, "spotlight");
            assert_eq!(sp_spec.query.as_deref(), Some("kMDItemContentTypeTree == 'public.text'"));
            let targets = garage_service::sources::scan_targets(&client, "mac-spotlight").await.unwrap();
            assert_eq!(targets.len(), 1);
            assert_eq!(targets[0].3.as_deref(), Some("kMDItemContentTypeTree == 'public.text'"));

            // Primary filesystem source indexes doc with empty title and 1 embedded chunk.
            let uri = "/tmp/notes/alpha.md";
            let payload =
                single_chunk_doc(&client, None, "hello spotlight world", 1_700_000_000.0, serde_json::Map::new()).await;
            assert_eq!(replace_document(&mut client, 0, "notes", uri, &payload).await.unwrap(), 1);

            let doc_id: i64 = scalar(&client, "SELECT id FROM documents WHERE uri = $1", &[&uri]).await;
            let notes_id: i64 = scalar(&client, "SELECT id FROM sources WHERE slug = 'notes'", &[]).await;
            let sp_id: i64 = scalar(&client, "SELECT id FROM sources WHERE slug = 'mac-spotlight'", &[]).await;
            let chunk_id: i64 = scalar(&client, "SELECT id FROM chunks WHERE document_id = $1", &[&doc_id]).await;
            embed(&client, &model.table_name, chunk_id, &[1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0], "vector").await;

            // Spotlight session carries query, and check_stat detects existing primary document.
            let ctx = garage_service::gateway::begin_session(&mut client, &cfg, "mac-spotlight").await.unwrap();
            assert_eq!(ctx.kind, "spotlight");
            assert_eq!(ctx.query, "kMDItemContentTypeTree == 'public.text'");

            let stat = check_stat(&mut client, "mac-spotlight", uri, None).await.unwrap();
            assert!(!stat.exists);
            assert_eq!(stat.state, "ok");
            assert_eq!(stat.existing_document_id, Some(doc_id));
            assert!(!stat.already_linked);

            // link_additional_document links without duplicating document/chunks/vectors,
            // backfills empty title, merges meta, and adds author.
            let mut sp_meta = serde_json::Map::new();
            sp_meta.insert("spotlight".into(), json!({ "finder_comment": "important" }));
            let linked_id = garage_service::gateway::link_additional_document(
                &mut client,
                ctx.run_id,
                "mac-spotlight",
                uri,
                1_700_000_123.0,
                Some("Backfilled Title"),
                &sp_meta,
                &[AuthorPayload { name: "Alice Example".into(), ..Default::default() }],
            )
            .await
            .unwrap();
            assert_eq!(linked_id, doc_id);

            let doc_count: i64 = scalar(&client, "SELECT count(*) FROM documents WHERE uri = $1", &[&uri]).await;
            assert_eq!(doc_count, 1);
            let owner_id: i64 = scalar(&client, "SELECT source_id FROM documents WHERE id = $1", &[&doc_id]).await;
            assert_eq!(owner_id, notes_id);
            let chunk_after: i64 = scalar(&client, "SELECT id FROM chunks WHERE document_id = $1", &[&doc_id]).await;
            assert_eq!(chunk_after, chunk_id);
            let vec_count: i64 = scalar(
                &client,
                &format!("SELECT count(*) FROM {} WHERE chunk_id = $1", model.table_name),
                &[&chunk_id],
            )
            .await;
            assert_eq!(vec_count, 1);

            let ds_count: i64 = scalar(
                &client,
                "SELECT count(*) FROM document_sources WHERE document_id = $1 AND source_id = $2",
                &[&doc_id, &sp_id],
            )
            .await;
            assert_eq!(ds_count, 1);

            let title: String = scalar(&client, "SELECT title FROM documents WHERE id = $1", &[&doc_id]).await;
            assert_eq!(title, "Backfilled Title");
            let meta: Value = scalar(&client, "SELECT meta FROM documents WHERE id = $1", &[&doc_id]).await;
            assert_eq!(meta["spotlight"]["finder_comment"], json!("important"));
            let authors: i64 = scalar(
                &client,
                "SELECT count(*) FROM document_authors da JOIN authors a ON a.id = da.author_id \
                 WHERE da.document_id = $1 AND a.display_name = 'Alice Example'",
                &[&doc_id],
            )
            .await;
            assert_eq!(authors, 1);

            // Non-empty title must NOT be overwritten on a subsequent link.
            garage_service::gateway::link_additional_document(
                &mut client,
                ctx.run_id,
                "mac-spotlight",
                uri,
                1_700_000_200.0,
                Some("Should Not Overwrite"),
                &sp_meta,
                &[],
            )
            .await
            .unwrap();
            let title_after: String = scalar(&client, "SELECT title FROM documents WHERE id = $1", &[&doc_id]).await;
            assert_eq!(title_after, "Backfilled Title");

            let stat_after = check_stat(&mut client, "mac-spotlight", uri, None).await.unwrap();
            assert_eq!(stat_after.existing_document_id, Some(doc_id));
            assert!(stat_after.already_linked);

            let _ = std::fs::remove_dir_all(&dir);
        })
    });
}

#[test]
fn spotlight_then_filesystem_promotes_ownership_and_preserves_chunks_and_vectors() {
    with_db(|pool| {
        Box::pin(async move {
            let mut client = pool.get().await.unwrap();
            let model = register_model(&mut client, &ModelSpec::new("m", "m", 8), false).await.unwrap();
            let sp_id = typed_source(&client, "mac-spotlight", "spotlight", "/tmp/spotlight").await;
            let notes_id = typed_source(&client, "notes", "filesystem", "/tmp/notes").await;

            let uri = "/tmp/notes/order.md";
            let mut sp_meta = serde_json::Map::new();
            sp_meta.insert("spotlight".into(), json!({ "tags": ["work"] }));
            let sp_doc =
                single_chunk_doc(&client, Some("Order Doc"), "shared body text", 1_700_000_000.0, sp_meta).await;
            assert_eq!(replace_document(&mut client, 0, "mac-spotlight", uri, &sp_doc).await.unwrap(), 1);

            let doc_id: i64 = scalar(&client, "SELECT id FROM documents WHERE uri = $1", &[&uri]).await;
            let chunk_id: i64 = scalar(&client, "SELECT id FROM chunks WHERE document_id = $1", &[&doc_id]).await;
            embed(&client, &model.table_name, chunk_id, &[1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0], "vector").await;

            // Now filesystem indexes the same URI: must promote ownership in place, demote spotlight
            // to document_sources, and preserve doc_id, chunk_id, vector, and spotlight metadata.
            let mut fs_meta = serde_json::Map::new();
            fs_meta.insert("fs".into(), json!(1));
            let fs_doc =
                single_chunk_doc(&client, Some("Order Doc"), "shared body text", 1_700_000_050.0, fs_meta).await;
            assert_eq!(replace_document(&mut client, 0, "notes", uri, &fs_doc).await.unwrap(), 1);

            let total_docs: i64 = scalar(&client, "SELECT count(*) FROM documents WHERE uri = $1", &[&uri]).await;
            assert_eq!(total_docs, 1);
            let row =
                client.query_one("SELECT id, source_id, meta FROM documents WHERE uri = $1", &[&uri]).await.unwrap();
            assert_eq!(row.get::<_, i64>(0), doc_id);
            assert_eq!(row.get::<_, i64>(1), notes_id);
            let merged_meta: Value = row.get(2);
            assert_eq!(merged_meta["fs"], json!(1));
            assert_eq!(merged_meta["spotlight"]["tags"], json!(["work"]));

            let chunk_after: i64 = scalar(&client, "SELECT id FROM chunks WHERE document_id = $1", &[&doc_id]).await;
            assert_eq!(chunk_after, chunk_id);
            let vec_count: i64 = scalar(
                &client,
                &format!("SELECT count(*) FROM {} WHERE chunk_id = $1", model.table_name),
                &[&chunk_id],
            )
            .await;
            assert_eq!(vec_count, 1);

            let sp_link: Value = scalar(
                &client,
                "SELECT meta FROM document_sources WHERE document_id = $1 AND source_id = $2",
                &[&doc_id, &sp_id],
            )
            .await;
            assert_eq!(sp_link["spotlight"]["tags"], json!(["work"]));
            let fs_link_count: i64 = scalar(
                &client,
                "SELECT count(*) FROM document_sources WHERE document_id = $1 AND source_id = $2",
                &[&doc_id, &notes_id],
            )
            .await;
            assert_eq!(fs_link_count, 0);
        })
    });
}

#[test]
#[allow(clippy::too_many_lines)]
fn spotlight_additional_source_is_visible_across_search_facts_enrich_and_rpc() {
    with_db_url(|pool, db_url| {
        Box::pin(async move {
            use garage_facade::proto;
            use garage_facade::proto::garage_service_server::GarageService as GarageRpc;
            use garage_service::config::Config;

            let mut client = pool.get().await.unwrap();
            typed_source(&client, "notes", "filesystem", "/tmp/notes").await;
            typed_source(&client, "mac-spotlight", "spotlight", "/tmp/spotlight").await;
            client
                .execute(
                    "UPDATE sources SET config = config || '{\"query\": \"kMDItemFSName == *.md\"}'::jsonb \
                     WHERE slug = 'mac-spotlight'",
                    &[],
                )
                .await
                .unwrap();

            let uri = "/tmp/notes/visible.md";
            let payload = single_chunk_doc(
                &client,
                Some("Visible Note"),
                "obsidian phoenix rises",
                1_700_000_000.0,
                serde_json::Map::new(),
            )
            .await;
            replace_document(&mut client, 0, "notes", uri, &payload).await.unwrap();
            let doc_id: i64 = scalar(&client, "SELECT id FROM documents WHERE uri = $1", &[&uri]).await;
            client
                .execute(
                    "INSERT INTO facts (document_id, ord, fact, fact_class, extractor) \
                     VALUES ($1, 0, 'Alice likes obsidian tea.', 'claim', 'llm')",
                    &[&doc_id],
                )
                .await
                .unwrap();

            // Exercise gRPC handlers directly against this database.
            let mut cfg = Config::default();
            cfg.set_field("database_url", Value::String(db_url));
            let svc = garage_service::service::GarageService::new(
                cfg,
                Arc::new(NoopEmbedder),
                garage_service::service::sql_dir(None),
                true,
            )
            .unwrap();

            let session = GarageRpc::begin_ingest_session(
                &svc,
                tonic::Request::new(proto::BeginIngestSessionRequest {
                    source_slug: "mac-spotlight".into(),
                    include_code: false,
                }),
            )
            .await
            .unwrap()
            .into_inner();
            assert_eq!(session.kind, "spotlight");
            assert_eq!(session.query, "kMDItemFSName == *.md");

            let stat = GarageRpc::check_document_stat(
                &svc,
                tonic::Request::new(proto::CheckDocumentStatRequest {
                    source_slug: "mac-spotlight".into(),
                    uri: uri.into(),
                    extractor_revision: String::new(),
                }),
            )
            .await
            .unwrap()
            .into_inner();
            assert_eq!(stat.existing_document_id, doc_id);
            assert!(!stat.already_linked);

            let persist = GarageRpc::persist_document(
                &svc,
                tonic::Request::new(proto::PersistDocumentRequest {
                    run_id: session.run_id,
                    source_slug: "mac-spotlight".into(),
                    uri: uri.into(),
                    action: "link_additional".into(),
                    title: "Visible Note".into(),
                    mtime: 1_700_000_100.0,
                    meta_json: r#"{"spotlight":{"kMDItemDisplayName":"Visible Note"}}"#.into(),
                    ..Default::default()
                }),
            )
            .await
            .unwrap()
            .into_inner();
            assert!(persist.success);

            // Search (FTS), Facts, Enrich all match via additional source slug.
            let hits = fts(
                &mut client,
                "obsidian",
                SearchFilters { sources: vec!["mac-spotlight".into()], ..Default::default() },
            )
            .await
            .unwrap();
            assert_eq!(hits.len(), 1);
            assert_eq!(hits[0].document_id, doc_id);

            let facts_page = garage_service::facts::list_facts(
                &client,
                &garage_service::facts::FactFilters { source: "mac-spotlight".into(), ..Default::default() },
                10,
                0,
                false,
                None,
            )
            .await
            .unwrap();
            assert_eq!(facts_page.total, 1);

            let enrich_docs =
                garage_service::enrich::documents_to_enrich(&client, "mac-spotlight", None).await.unwrap();
            assert_eq!(enrich_docs.len(), 1);
            assert_eq!(enrich_docs[0].id, doc_id);

            // RPC visibility: list_sources, list_documents, get_document.
            let srcs = GarageRpc::list_sources(&svc, tonic::Request::new(proto::ListSourcesRequest::default()))
                .await
                .unwrap()
                .into_inner()
                .sources;
            let sp = srcs.iter().find(|s| s.slug == "mac-spotlight").unwrap();
            assert_eq!(sp.document_count, 0);
            assert_eq!(sp.additional_document_count, 1);

            let docs = GarageRpc::list_documents(
                &svc,
                tonic::Request::new(proto::ListDocumentsRequest {
                    source: "mac-spotlight".into(),
                    ..Default::default()
                }),
            )
            .await
            .unwrap()
            .into_inner()
            .documents;
            assert_eq!(docs.len(), 1);
            assert_eq!(docs[0].id, doc_id);
            assert_eq!(docs[0].source_slug, "notes");
            assert_eq!(docs[0].additional_sources, vec!["mac-spotlight"]);

            let detail =
                GarageRpc::get_document(&svc, tonic::Request::new(proto::GetDocumentRequest { document_id: doc_id }))
                    .await
                    .unwrap()
                    .into_inner()
                    .document
                    .unwrap();
            assert_eq!(detail.additional_sources, vec!["mac-spotlight"]);
            drop(svc);
        })
    });
}

#[test]
#[allow(clippy::too_many_lines)]
fn remove_source_promotes_spotlight_and_reconcile_unlinks_stale_links() {
    with_db(|pool| {
        Box::pin(async move {
            let mut client = pool.get().await.unwrap();
            typed_source(&client, "notes", "filesystem", "/tmp/notes").await;
            let sp_id = typed_source(&client, "mac-spotlight", "spotlight", "/tmp/spotlight").await;
            let disabled_sp_id = typed_source(&client, "disabled-sp", "spotlight", "/tmp/disabled-sp").await;
            client.execute("UPDATE sources SET enabled = false WHERE id = $1", &[&disabled_sp_id]).await.unwrap();

            // Doc 1: owned by notes, linked to enabled mac-spotlight -> promoted on remove_source.
            let uri1 = "/tmp/notes/one.md";
            let doc1 =
                single_chunk_doc(&client, Some("One"), "one body", 1_700_000_000.0, serde_json::Map::new()).await;
            replace_document(&mut client, 0, "notes", uri1, &doc1).await.unwrap();
            let doc1_id: i64 = scalar(&client, "SELECT id FROM documents WHERE uri = $1", &[&uri1]).await;
            garage_service::gateway::link_additional_document(
                &mut client,
                0,
                "mac-spotlight",
                uri1,
                1_700_000_000.0,
                None,
                &serde_json::Map::new(),
                &[],
            )
            .await
            .unwrap();

            // Doc 2: owned by notes, linked only to disabled spotlight -> NOT promoted (deleted).
            let uri2 = "/tmp/notes/two.md";
            let doc2 =
                single_chunk_doc(&client, Some("Two"), "two body", 1_700_000_000.0, serde_json::Map::new()).await;
            replace_document(&mut client, 0, "notes", uri2, &doc2).await.unwrap();
            garage_service::gateway::link_additional_document(
                &mut client,
                0,
                "disabled-sp",
                uri2,
                1_700_000_000.0,
                None,
                &serde_json::Map::new(),
                &[],
            )
            .await
            .unwrap();

            // Doc 3: owned by notes, no links -> deleted.
            let uri3 = "/tmp/notes/three.md";
            let doc3 =
                single_chunk_doc(&client, Some("Three"), "three body", 1_700_000_000.0, serde_json::Map::new()).await;
            replace_document(&mut client, 0, "notes", uri3, &doc3).await.unwrap();

            let removed = garage_service::sources::remove_source(&mut client, None, "notes").await.unwrap();
            assert_eq!(removed.deleted_documents, 2);
            assert_eq!(
                scalar::<i64>(&client, "SELECT source_id FROM documents WHERE id = $1", &[&doc1_id]).await,
                sp_id
            );
            assert_eq!(
                scalar::<i64>(
                    &client,
                    "SELECT count(*) FROM document_sources WHERE document_id = $1 AND source_id = $2",
                    &[&doc1_id, &sp_id],
                )
                .await,
                0
            );
            assert_eq!(scalar::<i64>(&client, "SELECT count(*) FROM documents", &[]).await, 1);

            // Re-add notes with two linked docs: reconcile on mac-spotlight unlinks unseen link
            // without deleting the primary document, and retains the seen link.
            typed_source(&client, "notes", "filesystem", "/tmp/notes").await;
            let uri4 = "/tmp/notes/four.md";
            let uri5 = "/tmp/notes/five.md";
            for (uri, title) in [(uri4, "Four"), (uri5, "Five")] {
                let doc = single_chunk_doc(&client, Some(title), "body", 1_700_000_000.0, serde_json::Map::new()).await;
                replace_document(&mut client, 0, "notes", uri, &doc).await.unwrap();
                garage_service::gateway::link_additional_document(
                    &mut client,
                    0,
                    "mac-spotlight",
                    uri,
                    1_700_000_000.0,
                    None,
                    &serde_json::Map::new(),
                    &[],
                )
                .await
                .unwrap();
            }

            let run_id: i64 = client
                .query_one("INSERT INTO ingest_runs (source_id, completed) VALUES ($1, true) RETURNING id", &[&sp_id])
                .await
                .unwrap()
                .get(0);
            for seen_uri in [uri1, uri5] {
                client
                    .execute("INSERT INTO ingest_seen (run_id, uri) VALUES ($1, $2)", &[&run_id, &seen_uri])
                    .await
                    .unwrap();
            }

            let rec = garage_service::sources::reconcile_source(&mut client, "mac-spotlight", false, false, 0.5)
                .await
                .unwrap();
            assert!(!rec.refused);
            assert_eq!(rec.deleted, 0);

            assert_eq!(
                scalar::<i64>(
                    &client,
                    "SELECT count(*) FROM document_sources WHERE source_id = $1 AND uri = $2",
                    &[&sp_id, &uri4],
                )
                .await,
                0
            );
            assert_eq!(
                scalar::<i64>(
                    &client,
                    "SELECT count(*) FROM document_sources WHERE source_id = $1 AND uri = $2",
                    &[&sp_id, &uri5],
                )
                .await,
                1
            );
            assert_eq!(scalar::<i64>(&client, "SELECT count(*) FROM documents WHERE uri = $1", &[&uri4]).await, 1);
        })
    });
}

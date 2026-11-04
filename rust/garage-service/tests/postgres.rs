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
        }],
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

//! A throwaway database per test, as `test_postgres.py`'s fixtures made one per module: created
//! on the server `GARAGE_TEST_DATABASE_URL` names, migrated from `data/sql`, dropped afterwards.
//! Unset, every test passes without running (pytest skips; cargo has no skip), and says so.

#![allow(dead_code)]

use std::future::Future;
use std::path::PathBuf;
use std::pin::Pin;

use deadpool_postgres::Pool;
use garage_service::db::{DatabaseUrl, pool_for, vector_text};
use garage_service::migrate::{apply_migrations, default_sql_dir};
use tokio_postgres::NoTls;
use tokio_postgres::types::ToSql;

pub const TEST_URL_ENV: &str = "GARAGE_TEST_DATABASE_URL";

/// The server URL, or none when the tests are to be skipped.
pub fn database_url() -> Option<String> {
    std::env::var(TEST_URL_ENV).ok().filter(|url| !url.trim().is_empty())
}

pub fn sql_dir() -> PathBuf {
    default_sql_dir()
}

pub type Client = deadpool_postgres::Object;

async fn admin(url: &DatabaseUrl) -> tokio_postgres::Client {
    let (client, connection) = url.to_config().connect(NoTls).await.expect("connect to the test server");
    tokio::spawn(connection);
    client
}

/// Runs `test` against a fresh, migrated database, dropped afterwards even when the test panics.
pub fn with_db<F>(test: F)
where
    F: FnOnce(Pool) -> Pin<Box<dyn Future<Output = ()> + Send>>,
{
    with_db_url(|pool, _| test(pool));
}

/// [`with_db`], with the database's own URL too (`database_url`), for a server built on it.
pub fn with_db_url<F>(test: F)
where
    F: FnOnce(Pool, String) -> Pin<Box<dyn Future<Output = ()> + Send>>,
{
    let Some(url) = database_url() else {
        eprintln!("{TEST_URL_ENV} is not set; see 'Testing against Postgres' in CLAUDE.md");
        return;
    };
    let runtime = tokio::runtime::Builder::new_multi_thread().enable_all().build().unwrap();
    let outcome = runtime.block_on(async {
        let server = DatabaseUrl::parse(&url).expect("a database URL");
        let name = format!("garage_test_{}", nonce());
        admin(&server).await.batch_execute(&format!("CREATE DATABASE \"{name}\"")).await.expect("create database");
        let url = server.with_database(&name).to_url();
        let pool = pool_for(&url).expect("pool");
        let migrated = async {
            let client = pool.get().await.expect("connect to the test database");
            apply_migrations(&client, &sql_dir()).await.expect("apply data/sql");
        };
        migrated.await;
        let outcome = tokio::spawn(test(pool.clone(), url)).await;
        pool.close();
        admin(&server)
            .await
            .batch_execute(&format!("DROP DATABASE IF EXISTS \"{name}\" WITH (FORCE)"))
            .await
            .expect("drop database");
        outcome
    });
    if let Err(error) = outcome
        && let Ok(panic) = error.try_into_panic()
    {
        std::panic::resume_unwind(panic);
    }
}

/// A few hex digits that do not repeat within a run: the clock alone does not do (macOS counts
/// microseconds, and parallel tests start together), so a counter tells them apart.
pub fn nonce() -> String {
    static NEXT: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
    let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.subsec_nanos());
    let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    format!("{:x}{:x}{n:x}", std::process::id(), nanos)
}

/// A source of kind `filesystem` at `/tmp` (`_source`).
pub async fn source(client: &Client, slug: &str, config: serde_json::Value) -> i64 {
    client
        .query_one(
            "INSERT INTO sources (slug, kind, root, default_trust, config) \
             VALUES ($1, 'filesystem', '/tmp', 'authored', CAST($2::text AS jsonb)) RETURNING id",
            &[&slug, &config.to_string()],
        )
        .await
        .unwrap()
        .get(0)
}

/// `hashlib.sha256(text).digest()`, by the server.
pub async fn sha256(client: &Client, text: &str) -> Vec<u8> {
    client.query_one("SELECT sha256($1)", &[&text.as_bytes()]).await.unwrap().get(0)
}

pub fn hex(bytes: &[u8]) -> String {
    use std::fmt::Write;
    bytes.iter().fold(String::with_capacity(bytes.len() * 2), |mut out, b| {
        let _ = write!(out, "{b:02x}");
        out
    })
}

/// A document of one chunk; the chunk's id (`_chunk`).
pub async fn chunk(client: &Client, source_id: i64, title: &str, body: &str, corpus_class: &str) -> i64 {
    let digest = sha256(client, body).await;
    let uri = format!("test://{title}");
    let document_id: i64 = client
        .query_one(
            "INSERT INTO documents (source_id, uri, corpus_class, trust_tier, title, content_sha256, extractor) \
             VALUES ($1, $2, CAST($3::text AS corpus_class), 'authored', $4, $5, 'test') RETURNING id",
            &[&source_id, &uri, &corpus_class, &title, &digest],
        )
        .await
        .unwrap()
        .get(0);
    client
        .query_one(
            "INSERT INTO chunks (document_id, ord, text, chunk_sha256, chunker) \
             VALUES ($1, 0, $2, $3, 'test') RETURNING id",
            &[&document_id, &body, &digest],
        )
        .await
        .unwrap()
        .get(0)
}

/// A document with content and no chunks (`_document`).
pub async fn document(client: &Client, source_id: i64, title: &str, content: &str, corpus_class: &str) -> i64 {
    let digest = sha256(client, content).await;
    let uri = format!("test://{title}");
    client
        .query_one(
            "INSERT INTO documents (source_id, uri, corpus_class, trust_tier, title, content, content_sha256, extractor) \
             VALUES ($1, $2, CAST($3::text AS corpus_class), 'authored', $4, $5, $6, 'test') RETURNING id",
            &[&source_id, &uri, &corpus_class, &title, &content, &digest],
        )
        .await
        .unwrap()
        .get(0)
}

/// A chunk's vector in `table` (`_embed`); `kind` is `vector` or `halfvec`.
pub async fn embed(client: &Client, table: &str, chunk_id: i64, vector: &[f32], kind: &str) {
    client
        .execute(
            &format!(
                "INSERT INTO {table} (chunk_id, embedding) VALUES ($1, CAST($2::text AS {kind}({})))",
                vector.len()
            ),
            &[&chunk_id, &vector_text(vector)],
        )
        .await
        .unwrap();
}

/// A potential fact's vector, in the model's potential-fact table (`_embed_fact`).
pub async fn embed_fact(client: &Client, model_table: &str, fact_id: i64, vector: &[f32], kind: &str) {
    let table = garage_service::registry::potential_fact_table_name(model_table).unwrap();
    client
        .execute(
            &format!(
                "INSERT INTO {table} (fact_id, embedding) VALUES ($1, CAST($2::text AS {kind}({})))",
                vector.len()
            ),
            &[&fact_id, &vector_text(vector)],
        )
        .await
        .unwrap();
}

/// A potential fact of `document_id` and its chunk: `(fact_id, chunk_id)` (`_fact_chunk`).
pub async fn fact_chunk(client: &Client, document_id: i64, fact: &str) -> (i64, i64) {
    let ord: i64 =
        client.query_one("SELECT count(*) FROM facts WHERE document_id = $1", &[&document_id]).await.unwrap().get(0);
    let ord = i32::try_from(ord).unwrap();
    let fact_id: i64 = client
        .query_one(
            "INSERT INTO facts (document_id, ord, fact) VALUES ($1, $2, $3) RETURNING id",
            &[&document_id, &ord, &fact],
        )
        .await
        .unwrap()
        .get(0);
    let digest = sha256(client, fact).await;
    let chunk_ord = 1000 + ord;
    let chunk_id: i64 = client
        .query_one(
            "INSERT INTO chunks (document_id, ord, text, chunk_sha256, chunker, fact_id) \
             VALUES ($1, $2, $3, $4, 'facts:test', $5) RETURNING id",
            &[&document_id, &chunk_ord, &fact, &digest, &fact_id],
        )
        .await
        .unwrap()
        .get(0);
    (fact_id, chunk_id)
}

/// +sign on the first half, -sign on the second: far apart under every metric, and far apart
/// after binary quantization too (`_halves`).
pub fn halves(dims: usize, sign: f32) -> Vec<f32> {
    let half = dims / 2;
    (0..dims).map(|i| if i < half { sign } else { -sign }).collect()
}

pub async fn index_definition(client: &Client, table: &str) -> String {
    let pattern = format!("{table}_hnsw%");
    client
        .query_one("SELECT indexdef FROM pg_indexes WHERE tablename = $1 AND indexname LIKE $2", &[&table, &pattern])
        .await
        .unwrap()
        .get(0)
}

pub async fn scalar<T>(client: &Client, sql: &str, params: &[&(dyn ToSql + Sync)]) -> T
where
    T: for<'a> tokio_postgres::types::FromSql<'a>,
{
    client.query_one(sql, params).await.unwrap().get(0)
}

pub async fn count(client: &Client, sql: &str) -> i64 {
    scalar(client, sql, &[]).await
}

/// Runs a migration file's SQL twice: once, and again to show it idempotent.
pub async fn apply_twice(client: &Client, file: &str) {
    let sql = std::fs::read_to_string(sql_dir().join(file)).unwrap();
    client.batch_execute(&sql).await.unwrap_or_else(|e| panic!("{file}: {e}"));
    client.batch_execute(&sql).await.unwrap_or_else(|e| panic!("{file} again: {e}"));
}

/// The column names of `table`.
pub async fn columns(client: &Client, table: &str) -> Vec<String> {
    client
        .query("SELECT column_name FROM information_schema.columns WHERE table_name = $1", &[&table])
        .await
        .unwrap()
        .iter()
        .map(|r| r.get(0))
        .collect()
}

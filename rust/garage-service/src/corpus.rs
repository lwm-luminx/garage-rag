//! The corpus reads the MCP server runs (`Corpus*`): the Python tools' bodies (`mcp_server.server`:
//! `rag_search`, `rag_get_document`, `rag_list_sources`, `rag_list_authors`, `rag_stats`), each
//! answering with the JSON its dataclass produced, field for field and in the same order, so the
//! MCP clients see the same results.

use std::sync::Arc;

use garage_access::SqlFilter;
use serde_json::{Map, Value, json};

use crate::access::{Param, document_condition, refs};
use crate::db::Client;
use crate::db::assert_safe_table;
use crate::error::{Result, ServiceError};
use crate::models::{count_vectors, list_models};
use crate::registry::potential_fact_table_name;
use crate::search::{QueryEmbedder, SearchFilters, corpus_overview, search};

/// Home is collapsed to `~` in returned paths: absolute paths leak the account name into
/// transcripts and are no more useful to the caller (`_tidy`).
pub fn tidy(uri: &str, home: &str) -> String {
    if !home.is_empty() && uri.starts_with(home) { uri.replacen(home, "~", 1) } else { uri.to_owned() }
}

/// The inverse: only a leading `~` is expanded (`_untidy`).
pub fn untidy(location: &str, home: &str) -> String {
    if location == "~" || location.starts_with("~/") {
        format!("{home}{}", &location[1..])
    } else {
        location.to_owned()
    }
}

fn home() -> String {
    std::env::var("HOME").unwrap_or_default()
}

/// `round(x, 6)` as Python rounds a score for the result.
fn round6(x: f64) -> f64 {
    (x * 1_000_000.0).round() / 1_000_000.0
}

/// `rag_search`.
///
/// # Errors
///
/// What `search` fails with.
#[allow(clippy::too_many_arguments)]
pub async fn rag_search(
    client: &mut Client,
    embedder: Arc<dyn QueryEmbedder>,
    query: &str,
    limit: i64,
    mode: &str,
    configured_default: &str,
    hnsw_ef_search: i64,
    filters: &SearchFilters,
) -> Result<Value> {
    let hits =
        search(client, embedder, query, limit, mode, None, configured_default, hnsw_ef_search, filters, 600).await?;
    let models = list_models(client).await?;
    let default = models.iter().find(|m| m.is_default).map_or("none", |m| m.slug.as_str());
    let model = if mode == "fts" { "n/a" } else { default };
    let home = home();
    let hits: Vec<Value> = hits
        .iter()
        .map(|h| {
            json!({
                "chunk_id": h.chunk_id,
                "document_id": h.document_id,
                "location": tidy(&h.uri, &home),
                "title": h.title,
                "corpus_class": h.corpus_class,
                "trust_tier": h.trust_tier,
                "section": h.heading_path,
                "authors": h.authors,
                "matched_by": h.matched_by(),
                "score": round6(h.score),
                "text": h.text,
                "direction": h.direction,
                "sender": h.sender,
            })
        })
        .collect();
    Ok(json!({"query": query, "mode": mode, "model": model, "count": hits.len(), "hits": hits}))
}

/// `rag_get_document`: by id, or else by location (`~` accepted).
///
/// # Errors
///
/// Neither given, or no such document (`ValueError`, so `INVALID_ARGUMENT`).
pub async fn rag_get_document(
    client: &Client,
    document_id: Option<i64>,
    location: Option<&str>,
    max_chars: usize,
    access: Option<&SqlFilter>,
) -> Result<Value> {
    let location = location.filter(|l| !l.is_empty());
    if document_id.is_none() && location.is_none() {
        return Err(ServiceError::invalid("pass either document_id or location"));
    }
    let home = home();
    let columns = "id, uri, title, corpus_class::text, trust_tier::text, extractor, byte_size, content";
    // A document the caller may not see reads exactly as a missing one.
    let mut params: Vec<Param> = Vec::new();
    let key = match (document_id, location) {
        (Some(id), _) => {
            params.push(Box::new(id));
            "id"
        }
        (_, location) => {
            params.push(Box::new(untidy(location.unwrap_or_default(), &home)));
            "uri"
        }
    };
    let visible = document_condition("documents.id", access, &mut params)?;
    let row = client
        .query_opt(&format!("SELECT {columns} FROM documents WHERE {key} = $1 AND {visible}"), &refs(&params))
        .await?;
    let Some(row) = row else {
        let shown = document_id.map_or_else(|| location.unwrap_or_default().to_owned(), |id| id.to_string());
        return Err(ServiceError::invalid(format!("no such document: {shown}")));
    };
    let id: i64 = row.get(0);
    let authors: Vec<String> = client
        .query(
            "SELECT a.display_name FROM authors a JOIN document_authors da ON da.author_id = a.id \
             WHERE da.document_id = $1 ORDER BY da.confidence DESC",
            &[&id],
        )
        .await?
        .iter()
        .map(|r| r.get(0))
        .collect();
    let chunk_count: i64 = client.query_one("SELECT count(*) FROM chunks WHERE document_id = $1", &[&id]).await?.get(0);
    let content: String = row.get::<_, Option<String>>(7).unwrap_or_default();
    let chars = content.chars().count();
    let truncated = chars > max_chars;
    let shown: String = if truncated { content.chars().take(max_chars).collect() } else { content };
    Ok(json!({
        "document_id": id,
        "location": tidy(&row.get::<_, String>(1), &home),
        "title": row.get::<_, Option<String>>(2),
        "corpus_class": row.get::<_, String>(3),
        "trust_tier": row.get::<_, String>(4),
        "authors": authors,
        "extractor": row.get::<_, String>(5),
        "byte_size": row.get::<_, Option<i64>>(6),
        "chunk_count": chunk_count,
        "truncated": truncated,
        "content": shown,
    }))
}

/// `rag_list_sources`: each source with its `ok` documents and their chunks, most documented first.
///
/// # Errors
///
/// The server.
pub async fn rag_list_sources(client: &Client, access: Option<&SqlFilter>) -> Result<Value> {
    let home = home();
    let mut params: Vec<Param> = Vec::new();
    let visible = document_condition("d.id", access, &mut params)?;
    // With a policy, a source shows only when the caller may see one of its documents.
    let having = if access.is_some() { "HAVING count(DISTINCT d.id) > 0" } else { "" };
    let rows = client
        .query(
            &format!(
                "SELECT s.slug, s.kind, s.default_class::text, s.default_trust::text, s.root, \
                        count(DISTINCT d.id) AS documents, count(c.id) AS chunks
                 FROM sources s
                 LEFT JOIN documents d ON d.source_id = s.id AND d.state = 'ok' AND {visible}
                 LEFT JOIN chunks c ON c.document_id = d.id
                 GROUP BY s.id, s.slug, s.kind, s.default_class, s.default_trust, s.root
                 {having}
                 ORDER BY count(DISTINCT d.id) DESC"
            ),
            &refs(&params),
        )
        .await?;
    let sources: Vec<Value> = rows
        .iter()
        .map(|r| {
            json!({
                "slug": r.get::<_, String>(0),
                "kind": r.get::<_, String>(1),
                "corpus_class": r.get::<_, String>(2),
                "trust_tier": r.get::<_, String>(3),
                "root": tidy(&r.get::<_, String>(4), &home),
                "documents": r.get::<_, i64>(5),
                "chunks": r.get::<_, i64>(6),
            })
        })
        .collect();
    Ok(json!({"count": sources.len(), "sources": sources}))
}

/// `rag_list_authors`: most documented first, with each one's identities as `kind:value`.
///
/// # Errors
///
/// The server.
pub async fn rag_list_authors(client: &Client, limit: i64, access: Option<&SqlFilter>) -> Result<Value> {
    let mut params: Vec<Param> = vec![Box::new(limit)];
    let visible = document_condition("da.document_id", access, &mut params)?;
    // With a policy, an author shows only when the caller may see one of their documents, so the
    // addresses of a hidden mail's sender stay hidden too.
    let having = if access.is_some() { "HAVING count(DISTINCT da.document_id) > 0" } else { "" };
    let rows = client
        .query(
            &format!(
                "SELECT a.display_name, a.is_self, count(DISTINCT da.document_id) AS documents, \
                        array_agg(DISTINCT ai.kind || ':' || ai.value) FILTER (WHERE ai.id IS NOT NULL) AS identities
                 FROM authors a
                 LEFT JOIN document_authors da ON da.author_id = a.id AND {visible}
                 LEFT JOIN author_identities ai ON ai.author_id = a.id
                 GROUP BY a.id, a.display_name, a.is_self
                 {having}
                 ORDER BY count(DISTINCT da.document_id) DESC, a.display_name
                 LIMIT $1"
            ),
            &refs(&params),
        )
        .await?;
    let authors: Vec<Value> = rows
        .iter()
        .map(|r| {
            json!({
                "name": r.get::<_, String>(0),
                "is_self": r.get::<_, bool>(1),
                "documents": r.get::<_, i64>(2),
                "identities": r.get::<_, Option<Vec<String>>>(3).unwrap_or_default(),
            })
        })
        .collect();
    Ok(json!({"count": authors.len(), "authors": authors}))
}

/// `sql`'s count, with `{visible}` replaced by the condition on `column` for what `access` lets
/// through.
async fn count(client: &Client, sql: &str, column: &str, access: Option<&SqlFilter>) -> Result<i64> {
    let mut params: Vec<Param> = Vec::new();
    let visible = document_condition(column, access, &mut params)?;
    Ok(client.query_one(&sql.replace("{visible}", &visible), &refs(&params)).await?.get(0))
}

/// The vectors under the model whose table is `table_name` that belong to documents the caller may
/// see: its chunks' and its potential facts'.
async fn count_visible_vectors(client: &Client, table_name: &str, access: Option<&SqlFilter>) -> Result<i64> {
    let table = assert_safe_table(table_name)?;
    let facts = potential_fact_table_name(table)?;
    let mut params: Vec<Param> = Vec::new();
    let visible = document_condition("c.document_id", access, &mut params)?;
    let exists: bool = client.query_one(&format!("SELECT to_regclass('{facts}') IS NOT NULL"), &[]).await?.get(0);
    let fact_count = if exists {
        format!(" + (SELECT count(*) FROM {facts} e JOIN chunks c ON c.fact_id = e.fact_id WHERE {visible})")
    } else {
        String::new()
    };
    let sql = format!(
        "SELECT (SELECT count(*) FROM {table} e JOIN chunks c ON c.id = e.chunk_id WHERE {visible}){fact_count}"
    );
    Ok(client.query_one(&sql, &refs(&params)).await?.get(0))
}

/// `rag_stats`: size, composition and embedding coverage.
///
/// # Errors
///
/// The server.
pub async fn rag_stats(client: &Client, access: Option<&SqlFilter>) -> Result<Value> {
    let documents =
        count(client, "SELECT count(*) FROM documents WHERE state = 'ok' AND {visible}", "id", access).await?;
    let chunks = count(client, "SELECT count(*) FROM chunks WHERE {visible}", "document_id", access).await?;
    // With a policy, the authors of documents the caller may see; without one, every author.
    let authors = if access.is_some() {
        count(client, "SELECT count(DISTINCT author_id) FROM document_authors WHERE {visible}", "document_id", access)
            .await?
    } else {
        count(client, "SELECT count(*) FROM authors", "id", None).await?
    };
    let pending =
        count(client, "SELECT count(*) FROM documents WHERE state = 'placeholder' AND {visible}", "id", access).await?;
    let overview = corpus_overview(client, access).await?;
    let mut models: Vec<Value> = Vec::new();
    for m in list_models(client).await? {
        let have = match access {
            None => count_vectors(client, &m.table_name).await?,
            Some(_) => count_visible_vectors(client, &m.table_name, access).await?,
        };
        models.push(json!({
            "slug": m.slug,
            "dims": m.dims,
            "stored_dims": m.stored_dims,
            "storage": m.storage_kind,
            "index": m.index_kind,
            "is_default": m.is_default,
            "vectors": have,
            "pending": (chunks - have).max(0),
        }));
    }
    let mut result = Map::new();
    result.insert("documents".into(), json!(documents));
    result.insert("chunks".into(), json!(chunks));
    result.insert("authors".into(), json!(authors));
    result.insert("placeholders_pending".into(), json!(pending));
    result.insert("by_class_and_trust".into(), Value::Array(overview));
    result.insert("models".into(), Value::Array(models));
    Ok(Value::Object(result))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn home_is_collapsed_and_expanded() {
        assert_eq!(tidy("/Users/me/Notes/a.md", "/Users/me"), "~/Notes/a.md");
        assert_eq!(tidy("/opt/a.md", "/Users/me"), "/opt/a.md");
        assert_eq!(tidy("/opt/a.md", ""), "/opt/a.md");
        assert_eq!(untidy("~/Notes/a.md", "/Users/me"), "/Users/me/Notes/a.md");
        assert_eq!(untidy("~", "/Users/me"), "/Users/me");
        assert_eq!(untidy("~bob/x", "/Users/me"), "~bob/x");
        assert!((round6(0.016_393_442_6) - 0.016_393).abs() < 1e-12);
    }
}

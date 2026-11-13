//! Hybrid retrieval (`garage_rag.search.hybrid`): vector KNN fused with Postgres full-text search by
//! Reciprocal Rank Fusion, with the same SQL, the same filters and the same three storage paths
//! (`vector`, `halfvec`, binary-quantized).

use std::sync::Arc;

use garage_access::SqlFilter;
use tokio_postgres::types::ToSql;

use crate::db::{Client, vector_text};
use crate::error::{Result, ServiceError};
use crate::models::{EmbeddingModel, get_model};
use crate::registry::{distance_operator, potential_fact_table_name, truncate_vector};

/// RRF constant from Cormack et al.
pub const RRF_K: i32 = 60;
/// Candidates drawn from each engine before fusion.
pub const CANDIDATE_DEPTH: i64 = 200;
/// Binary-quantized models: how many Hamming-nearest rows the first stage fetches per `CANDIDATE_DEPTH`.
pub const BQ_OVERFETCH: i64 = 4;
/// `SearchHit.text` is this much of the chunk.
pub const SNIPPET_CHARS_DEFAULT: i32 = 600;
/// `snippet()`'s one-line preview length.
pub const SNIPPET_CHARS: usize = 300;
/// `chunks.direction` values.
pub const DIRECTIONS: [&str; 2] = ["sent", "received"];
pub const MODES: [&str; 3] = ["hybrid", "vector", "fts"];

/// One-line preview of a hit for listings (`snippet`).
pub fn snippet(text: &str) -> String {
    text.chars().take(SNIPPET_CHARS).collect::<String>().replace('\n', " ")
}

/// One result, best first (`SearchHit`).
#[derive(Clone, Debug, PartialEq)]
pub struct SearchHit {
    pub chunk_id: i64,
    pub document_id: i64,
    pub uri: String,
    pub title: Option<String>,
    pub corpus_class: String,
    pub trust_tier: String,
    pub heading_path: Option<String>,
    pub text: String,
    pub score: f64,
    pub vector_rank: Option<i64>,
    pub fts_rank: Option<i64>,
    pub authors: Vec<String>,
    pub direction: Option<String>,
    pub sender: Option<String>,
}

impl SearchHit {
    /// `both` | `vector` | `keyword`.
    pub fn matched_by(&self) -> &'static str {
        match (self.vector_rank, self.fts_rank) {
            (Some(_), Some(_)) => "both",
            (Some(_), None) => "vector",
            _ => "keyword",
        }
    }
}

/// The filters shared by both engines (`search`'s keyword arguments).
#[derive(Clone, Debug, Default)]
pub struct SearchFilters {
    pub corpus_classes: Vec<String>,
    pub trust_tiers: Vec<String>,
    pub sources: Vec<String>,
    pub author: Option<String>,
    pub direction: Option<String>,
    /// The access policy's condition for the caller (`docs/plans/access-hooks.md`), inside both
    /// engines' candidate queries so it applies before fusion. `None`: no condition.
    pub access: Option<SqlFilter>,
}

/// Turns the query into the model's vector: the process's embedder, or a stub in tests.
pub trait QueryEmbedder: Send + Sync {
    /// The raw embedding of `query` under `model` (the plan's truncation is applied by the caller).
    ///
    /// # Errors
    ///
    /// Why the model could not be asked.
    fn embed_query(&self, model: &EmbeddingModel, query: &str) -> Result<Vec<f32>>;
}

/// SQL producing the tsquery for the keyword half (`tsquery_expr`), with the text as `$param`.
/// Terms are ORed so the keyword side favours recall; a query with quotes, `OR` or a leading `-` is
/// taken as written.
pub fn tsquery_expr(query: &str, param: usize) -> String {
    if ["\"", " OR ", " or ", " -"].iter().any(|token| query.contains(token)) {
        format!("websearch_to_tsquery('english', ${param}::text)")
    } else {
        format!("replace(plainto_tsquery('english', ${param}::text)::text, ' & ', ' | ')::tsquery")
    }
}

type Param = Box<dyn ToSql + Sync + Send>;

struct Params(Vec<Param>);

impl Params {
    fn push(&mut self, value: impl ToSql + Sync + Send + 'static) -> usize {
        self.0.push(Box::new(value));
        self.0.len()
    }

    fn refs(&self) -> Vec<&(dyn ToSql + Sync)> {
        self.0.iter().map(|p| p.as_ref() as &(dyn ToSql + Sync)).collect()
    }
}

/// Searches the corpus (`search`); hits best first. An empty query finds nothing; `fts` needs no
/// model.
///
/// # Errors
///
/// A bad mode or direction, no model for the vector side, the embedder, or the server.
#[allow(clippy::too_many_lines)]
#[allow(clippy::too_many_arguments)] // the Python signature, kept for its callers
pub async fn search(
    client: &mut Client,
    embedder: Arc<dyn QueryEmbedder>,
    query: &str,
    limit: i64,
    mode: &str,
    model_slug: Option<&str>,
    configured_default: &str,
    hnsw_ef_search: i64,
    filters: &SearchFilters,
    snippet_chars: i32,
) -> Result<Vec<SearchHit>> {
    if !MODES.contains(&mode) {
        return Err(ServiceError::invalid(format!("mode must be one of {}, not {mode:?}", MODES.join(", "))));
    }
    if let Some(direction) = filters.direction.as_deref().filter(|d| !d.is_empty())
        && !DIRECTIONS.contains(&direction)
    {
        return Err(ServiceError::invalid(format!(
            "direction must be one of {}, not {direction:?}",
            DIRECTIONS.join(", ")
        )));
    }
    if query.trim().is_empty() {
        return Ok(Vec::new());
    }
    let need_vector = mode != "fts";
    let model = if need_vector { Some(get_model(client, model_slug, configured_default).await?) } else { None };
    // The vector first, since it is the slow, fallible part: the embedder is sync and may block.
    let query_vector = match &model {
        Some(model) => {
            let plan = model.plan();
            let (embedder, model, text) = (embedder, model.clone(), query.to_owned());
            let raw = tokio::task::spawn_blocking(move || embedder.embed_query(&model, &text))
                .await
                .map_err(|e| ServiceError::failed(format!("embedding the query: {e}")))??;
            Some(vector_text(&truncate_vector(&raw, &plan)?))
        }
        None => None,
    };

    let mut params = Params(Vec::new());
    let q = params.push(query.to_owned());
    let limit_p = params.push(limit);
    let depth = params.push(CANDIDATE_DEPTH);
    let k = params.push(RRF_K);
    let snippet_p = params.push(snippet_chars);

    let mut where_parts = vec!["d.state = 'ok'".to_owned()];
    if !filters.corpus_classes.is_empty() {
        let p = params.push(filters.corpus_classes.clone());
        where_parts.push(format!("d.corpus_class = ANY(CAST(${p}::text[] AS corpus_class[]))"));
    }
    if !filters.trust_tiers.is_empty() {
        let p = params.push(filters.trust_tiers.clone());
        where_parts.push(format!("d.trust_tier = ANY(CAST(${p}::text[] AS trust_tier[]))"));
    }
    if !filters.sources.is_empty() {
        let p = params.push(filters.sources.clone());
        where_parts.push(format!(
            "(s.slug = ANY(${p}::text[]) OR EXISTS (SELECT 1 FROM document_sources ds \
             JOIN sources s2 ON s2.id = ds.source_id WHERE ds.document_id = d.id AND s2.slug = ANY(${p}::text[])))"
        ));
    }
    if let Some(author) = filters.author.as_deref().filter(|a| !a.is_empty()) {
        let p = params.push(format!("%{author}%"));
        where_parts.push(format!(
            "EXISTS (SELECT 1 FROM document_authors da JOIN authors a ON a.id = da.author_id \
             WHERE da.document_id = d.id AND (a.display_name ILIKE ${p}::text OR EXISTS \
             (SELECT 1 FROM author_identities ai WHERE ai.author_id = a.id AND ai.value ILIKE ${p}::text)))"
        ));
    }
    if let Some(direction) = filters.direction.as_deref().filter(|d| !d.is_empty()) {
        let p = params.push(direction.to_owned());
        where_parts.push(format!("c.direction = ${p}::text"));
    }
    if let Some(access) = &filters.access {
        let condition = access
            .render(params.0.len())
            .map_err(|e| ServiceError::failed(format!("the access policy's filter: {e}")))?;
        for value in &access.params {
            params.push(value.clone());
        }
        where_parts.push(condition);
    }
    let where_clause = where_parts.join(" AND ");

    let mut vector_cte = String::new();
    if let (Some(model), Some(qv)) = (&model, query_vector) {
        let table = model.table()?.to_owned();
        let fact_table = potential_fact_table_name(&table)?;
        let op = distance_operator(&model.distance)?;
        let qv_p = params.push(qv);
        let column_type = model.plan().column_type();
        let qvec = format!("CAST(${qv_p}::text AS {column_type})");
        if model.index_kind == "hnsw_bq" {
            let bits = model.stored_dims;
            let bq_depth = params.push(CANDIDATE_DEPTH * BQ_OVERFETCH);
            vector_cte = format!(
                "vec_bq_chunks AS (
                    SELECT c.id AS chunk_id, e.embedding
                    FROM {table} e
                    JOIN chunks c    ON c.id = e.chunk_id
                    JOIN documents d ON d.id = c.document_id
                    JOIN sources s   ON s.id = d.source_id
                    WHERE {where_clause}
                    ORDER BY binary_quantize(e.embedding)::bit({bits}) <~> binary_quantize({qvec})::bit({bits})
                    LIMIT ${bq_depth}
                ),
                vec_bq_facts AS (
                    SELECT c.id AS chunk_id, e.embedding
                    FROM {fact_table} e
                    JOIN chunks c    ON c.fact_id = e.fact_id
                    JOIN documents d ON d.id = c.document_id
                    JOIN sources s   ON s.id = d.source_id
                    WHERE {where_clause}
                    ORDER BY binary_quantize(e.embedding)::bit({bits}) <~> binary_quantize({qvec})::bit({bits})
                    LIMIT ${bq_depth}
                ),
                vec AS (
                    SELECT b.chunk_id, row_number() OVER (ORDER BY b.embedding {op} {qvec}, b.chunk_id) AS rnk
                    FROM (SELECT * FROM vec_bq_chunks UNION ALL SELECT * FROM vec_bq_facts) b
                    ORDER BY b.embedding {op} {qvec}, b.chunk_id
                    LIMIT ${depth}
                )"
            );
        } else {
            vector_cte = format!(
                "vec_chunks AS (
                    SELECT c.id AS chunk_id, e.embedding {op} {qvec} AS dist
                    FROM {table} e
                    JOIN chunks c    ON c.id = e.chunk_id
                    JOIN documents d ON d.id = c.document_id
                    JOIN sources s   ON s.id = d.source_id
                    WHERE {where_clause}
                    ORDER BY e.embedding {op} {qvec}
                    LIMIT ${depth}
                ),
                vec_facts AS (
                    SELECT c.id AS chunk_id, e.embedding {op} {qvec} AS dist
                    FROM {fact_table} e
                    JOIN chunks c    ON c.fact_id = e.fact_id
                    JOIN documents d ON d.id = c.document_id
                    JOIN sources s   ON s.id = d.source_id
                    WHERE {where_clause}
                    ORDER BY e.embedding {op} {qvec}
                    LIMIT ${depth}
                ),
                vec AS (
                    SELECT v.chunk_id, row_number() OVER (ORDER BY v.dist, v.chunk_id) AS rnk
                    FROM (SELECT * FROM vec_chunks UNION ALL SELECT * FROM vec_facts) v
                    ORDER BY v.dist, v.chunk_id
                    LIMIT ${depth}
                )"
            );
        }
    }
    let tsq = tsquery_expr(query, q);
    let fts_cte = format!(
        "fts AS (
            SELECT c.id AS chunk_id, row_number() OVER (ORDER BY ts_rank_cd(c.tsv, {tsq}) DESC) AS rnk
            FROM chunks c
            JOIN documents d ON d.id = c.document_id
            JOIN sources s   ON s.id = d.source_id
            WHERE c.tsv @@ {tsq}
              AND {where_clause}
            ORDER BY rnk
            LIMIT ${depth}
        )"
    );
    let (ctes, join, matched, score, vrank, frank) = match mode {
        "hybrid" => (
            format!("WITH {vector_cte}, {fts_cte}"),
            "LEFT JOIN vec ON vec.chunk_id = c.id LEFT JOIN fts ON fts.chunk_id = c.id",
            "WHERE vec.chunk_id IS NOT NULL OR fts.chunk_id IS NOT NULL".to_owned(),
            format!("COALESCE(1.0/(${k}::int + vec.rnk), 0) + COALESCE(1.0/(${k}::int + fts.rnk), 0)"),
            "vec.rnk",
            "fts.rnk",
        ),
        "vector" => (
            format!("WITH {vector_cte}"),
            "JOIN vec ON vec.chunk_id = c.id",
            // The query text is bound for both engines; the vector side has to name it once, or
            // the server cannot type the parameter.
            format!("WHERE ${q}::text IS NOT NULL"),
            format!("1.0/(${k}::int + vec.rnk)"),
            "vec.rnk",
            "NULL::bigint",
        ),
        _ => (
            format!("WITH {fts_cte}"),
            "JOIN fts ON fts.chunk_id = c.id",
            String::new(),
            format!("1.0/(${k}::int + fts.rnk)"),
            "NULL::bigint",
            "fts.rnk",
        ),
    };
    let sql = format!(
        "{ctes}
        SELECT c.id            AS chunk_id,
               d.id            AS document_id,
               d.uri,
               d.title,
               d.corpus_class::text AS corpus_class,
               d.trust_tier::text   AS trust_tier,
               c.heading_path,
               c.direction,
               c.sender,
               left(c.text, ${snippet_p}::int) AS snippet,
               ({score})::float8 AS score,
               {vrank}         AS vector_rank,
               {frank}         AS fts_rank,
               COALESCE(
                   (SELECT array_agg(DISTINCT a.display_name)
                    FROM document_authors da
                    JOIN authors a ON a.id = da.author_id
                    WHERE da.document_id = d.id),
                   '{{}}'
               )               AS authors
        FROM chunks c
        JOIN documents d ON d.id = c.document_id
        JOIN sources s   ON s.id = d.source_id
        {join}
        {matched}
        ORDER BY score DESC, c.id
        LIMIT ${limit_p}"
    );

    // The probe width is per transaction (`SET LOCAL`), as `apply_search_tuning` set it.
    let tx = client.transaction().await?;
    tx.batch_execute(&format!("SET LOCAL hnsw.ef_search = {}", hnsw_ef_search.clamp(1, 1000))).await?;
    if filters.access.is_some() {
        // A filtered HNSW scan stops at ef_search candidates, most of which the filter may drop;
        // pgvector 0.8's iterative scan keeps walking until the filtered candidates fill the depth.
        tx.batch_execute("SET LOCAL hnsw.iterative_scan = relaxed_order").await?;
    }
    let rows = tx.query(&sql, &params.refs()).await?;
    tx.commit().await?;
    Ok(rows
        .iter()
        .map(|row| SearchHit {
            chunk_id: row.get("chunk_id"),
            document_id: row.get("document_id"),
            uri: row.get("uri"),
            title: row.get("title"),
            corpus_class: row.get("corpus_class"),
            trust_tier: row.get("trust_tier"),
            heading_path: row.get("heading_path"),
            text: row.get("snippet"),
            score: row.get("score"),
            vector_rank: row.get("vector_rank"),
            fts_rank: row.get("fts_rank"),
            authors: row.get("authors"),
            direction: row.get("direction"),
            sender: row.get("sender"),
        })
        .collect())
}

/// Counts by `(corpus_class, trust_tier)` over the documents in state `ok` (`corpus_overview`) that
/// `access` lets through.
///
/// # Errors
///
/// The server.
pub async fn corpus_overview(client: &Client, access: Option<&SqlFilter>) -> Result<Vec<serde_json::Value>> {
    let mut params: Vec<crate::access::Param> = Vec::new();
    let visible = crate::access::document_condition("d.id", access, &mut params)?;
    let rows = client
        .query(
            &format!(
                "SELECT d.corpus_class::text, d.trust_tier::text, count(DISTINCT d.id) AS documents, count(c.id) AS chunks
                 FROM documents d LEFT JOIN chunks c ON c.document_id = d.id
                 WHERE d.state = 'ok' AND {visible}
                 GROUP BY d.corpus_class, d.trust_tier
                 ORDER BY count(DISTINCT d.id) DESC"
            ),
            &crate::access::refs(&params),
        )
        .await?;
    Ok(rows
        .iter()
        .map(|row| {
            serde_json::json!({
                "corpus_class": row.get::<_, String>(0),
                "trust_tier": row.get::<_, String>(1),
                "documents": row.get::<_, i64>(2),
                "chunks": row.get::<_, i64>(3),
            })
        })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_keyword_query_ors_terms_unless_the_user_wrote_operators() {
        assert!(tsquery_expr("heat pump", 1).starts_with("replace(plainto_tsquery"));
        assert!(tsquery_expr("\"heat pump\"", 1).starts_with("websearch_to_tsquery"));
        assert!(tsquery_expr("heat -pump", 1).starts_with("websearch_to_tsquery"));
        assert_eq!(snippet("a\nb"), "a b");
    }
}

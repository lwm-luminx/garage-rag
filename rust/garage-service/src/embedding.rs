//! What the embed worker asks the database for (`garage_rag.embed.ollama`'s SQL): the chunks a
//! model has no vector for, writing vectors to the right table, and the distilled facts' centroids.

use crate::db::{Client, assert_safe_table, vector_text};
use crate::error::Result;
use crate::models::{EmbeddingModel, ensure_fact_table};
use crate::registry::{potential_fact_table_name, truncate_vector};

/// The chunker of the one chunk an image document carries for image models.
pub const IMAGE_CHUNKER: &str = "image";

/// What a batch carries per chunk: its text for a text model, the image file's path for an image
/// model (`PENDING_SELECT`).
pub fn pending_select(modality: &str) -> &'static str {
    if modality == "image" { "c.id, d.uri" } else { "c.id, c.text" }
}

/// `SELECT <select>` over the chunks the model of chunk table `table` has no vector for
/// (`pending_chunks_sql`). A content chunk's vector is in `table`; a potential fact's in the
/// model's potential-fact table. `include_communications = false` leaves out communication
/// documents' chunks, for a provider that is not on this machine.
///
/// # Errors
///
/// An unsafe table name.
pub fn pending_chunks_sql(table: &str, select: &str, include_communications: bool, modality: &str) -> Result<String> {
    assert_safe_table(table)?;
    if modality == "image" {
        let withheld = if include_communications { "" } else { " AND d.corpus_class <> 'communication'" };
        return Ok(format!(
            "SELECT {select} FROM chunks c JOIN documents d ON d.id = c.document_id LEFT JOIN {table} e ON e.chunk_id = c.id \
             WHERE e.chunk_id IS NULL AND c.chunker = '{IMAGE_CHUNKER}'{withheld}"
        ));
    }
    let withheld = if include_communications {
        ""
    } else {
        " AND NOT EXISTS (SELECT 1 FROM documents d WHERE d.id = c.document_id AND d.corpus_class = 'communication')"
    };
    let facts = potential_fact_table_name(table)?;
    Ok(format!(
        "SELECT {select} FROM chunks c LEFT JOIN {table} e ON c.fact_id IS NULL AND e.chunk_id = c.id \
         LEFT JOIN {facts} pe ON c.fact_id IS NOT NULL AND pe.fact_id = c.fact_id \
         WHERE e.chunk_id IS NULL AND pe.fact_id IS NULL AND c.chunker <> '{IMAGE_CHUNKER}'{withheld}"
    ))
}

/// How many chunks the model still lacks (`count_pending`).
///
/// # Errors
///
/// The server.
pub async fn count_pending(client: &Client, model: &EmbeddingModel, include_communications: bool) -> Result<i64> {
    let sql = pending_chunks_sql(model.table()?, "count(*)", include_communications, model.modality())?;
    Ok(client.query_one(&sql, &[]).await?.get(0))
}

/// The next `limit` pending chunks, by id: `(chunk_id, text or image path)`.
///
/// # Errors
///
/// The server.
pub async fn pending_chunks(
    client: &Client,
    model: &EmbeddingModel,
    include_communications: bool,
    limit: i64,
) -> Result<Vec<(i64, String)>> {
    let modality = model.modality();
    let sql = pending_chunks_sql(model.table()?, pending_select(modality), include_communications, modality)?
        + " ORDER BY c.id LIMIT $1";
    let rows = client.query(&sql, &[&limit]).await?;
    Ok(rows.iter().map(|row| (row.get(0), row.get(1))).collect())
}

/// Stores `(chunk_id, vector)` pairs in the model's tables (`store_vectors`): a content chunk's
/// vector in the chunk table, a potential fact's chunk's in the potential-fact table keyed on its
/// fact. `replace` overwrites a vector already there. How many were given.
///
/// # Errors
///
/// A vector narrower than the model stores, or the server.
pub async fn store_vectors(
    client: &mut Client,
    model: &EmbeddingModel,
    vectors: &[(i64, Vec<f32>)],
    replace: bool,
) -> Result<usize> {
    if vectors.is_empty() {
        return Ok(0);
    }
    let table = model.table()?.to_owned();
    let facts = potential_fact_table_name(&table)?;
    let plan = model.plan();
    let ids: Vec<i64> = vectors.iter().map(|(id, _)| *id).collect();
    let fact_of: std::collections::HashMap<i64, Option<i64>> = client
        .query("SELECT id, fact_id FROM chunks WHERE id = ANY($1)", &[&ids])
        .await?
        .iter()
        .map(|row| (row.get::<_, i64>(0), row.get::<_, Option<i64>>(1)))
        .collect();
    let on_conflict =
        if replace { "DO UPDATE SET embedding = EXCLUDED.embedding, embedded_at = now()" } else { "DO NOTHING" };
    let coltype = plan.column_type();
    let tx = client.transaction().await?;
    let content = tx
        .prepare(&format!(
            "INSERT INTO {table} (chunk_id, embedding) VALUES ($1, CAST($2::text AS {coltype})) ON CONFLICT (chunk_id) {on_conflict}"
        ))
        .await?;
    let fact_rows = tx
        .prepare(&format!(
            "INSERT INTO {facts} (fact_id, embedding) VALUES ($1, CAST($2::text AS {coltype})) ON CONFLICT (fact_id) {on_conflict}"
        ))
        .await?;
    for (chunk_id, vector) in vectors {
        let text = vector_text(&truncate_vector(vector, &plan)?);
        match fact_of.get(chunk_id).copied().flatten() {
            Some(fact_id) => tx.execute(&fact_rows, &[&fact_id, &text]).await?,
            None => tx.execute(&content, &[chunk_id, &text]).await?,
        };
    }
    tx.commit().await?;
    Ok(vectors.len())
}

/// Gives every distilled fact a vector in the model's `fact_emb_` table (`backfill_distilled`):
/// the normalized mean of its representatives' vectors under this model, once every one of them
/// has one; an anchored distilled fact takes its representative's. Nothing is embedded. How many
/// were made; an image model makes none, since facts are text.
///
/// # Errors
///
/// The server.
pub async fn backfill_distilled(client: &Client, model: &EmbeddingModel) -> Result<i64> {
    if model.modality() != "text" {
        return Ok(0);
    }
    let table = potential_fact_table_name(model.table()?)?;
    let fact_table = ensure_fact_table(client, model).await?;
    let made = client
        .query(
            &format!(
                "INSERT INTO {fact_table} (distilled_fact_id, embedding)
                 SELECT f.distilled_fact_id, l2_normalize(avg(e.embedding))
                 FROM facts f
                 JOIN distilled_facts df ON df.id = f.distilled_fact_id
                 LEFT JOIN {table} e ON e.fact_id = f.id
                 WHERE f.restates_fact_id IS NULL AND (df.anchor_key IS NULL OR f.id = df.representative_fact_id)
                   AND NOT EXISTS (SELECT 1 FROM {fact_table} fe WHERE fe.distilled_fact_id = f.distilled_fact_id)
                 GROUP BY f.distilled_fact_id
                 HAVING count(e.fact_id) = count(*)
                 ON CONFLICT (distilled_fact_id) DO NOTHING
                 RETURNING distilled_fact_id"
            ),
            &[],
        )
        .await?;
    Ok(i64::try_from(made.len()).unwrap_or(i64::MAX))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_pending_query_withholds_communications_and_routes_facts() {
        let sql = pending_chunks_sql("emb_m", "count(*)", false, "text").unwrap();
        assert!(sql.contains("potential_fact_emb_m pe"));
        assert!(sql.contains("corpus_class = 'communication'"));
        assert!(!pending_chunks_sql("emb_m", "c.id, c.text", true, "text").unwrap().contains("communication"));
        let image = pending_chunks_sql("emb_m", pending_select("image"), false, "image").unwrap();
        assert!(image.contains("d.uri") && image.contains("c.chunker = 'image'"));
        assert!(pending_chunks_sql("chunks", "1", true, "text").is_err());
    }
}

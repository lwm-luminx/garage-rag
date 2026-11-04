//! The embedding model registry and the per-model tables (`garage_rag.db.emb_tables`).
//!
//! Registering a model makes three tables with a vector index each: `emb_<slug>` (chunk vectors,
//! keyed on the chunk), `potential_fact_emb_<slug>` (potential facts' vectors, keyed on the fact) and
//! `fact_emb_<slug>` (distilled facts' centroids, keyed on the distilled fact). Each key cascades,
//! so deleting a chunk or a fact drops its vectors everywhere at once.

use tokio_postgres::Row;

use crate::db::{Client, assert_safe_table};
use crate::error::{Result, ServiceError};
use crate::registry::{
    StoragePlan, check_distance, check_modality, fact_table_name, index_ddl, plan_storage, potential_fact_table_name,
    table_name_for,
};

/// One row of `embedding_models`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EmbeddingModel {
    pub id: i16,
    pub slug: String,
    pub provider: String,
    pub model_ref: String,
    pub model_id: Option<String>,
    pub dims: i32,
    pub stored_dims: i32,
    pub storage_kind: String,
    pub index_kind: String,
    pub normalized: bool,
    pub table_name: String,
    pub is_default: bool,
    pub distance: String,
    pub modality: String,
}

const COLUMNS: &str = "id, slug, provider, model_ref, model_id, dims, stored_dims, storage_kind, index_kind, normalized, \
                       table_name, is_default, distance, modality";

impl EmbeddingModel {
    fn from_row(row: &Row) -> Self {
        Self {
            id: row.get("id"),
            slug: row.get("slug"),
            provider: row.get("provider"),
            model_ref: row.get("model_ref"),
            model_id: row.get("model_id"),
            dims: row.get("dims"),
            stored_dims: row.get("stored_dims"),
            storage_kind: row.get("storage_kind"),
            index_kind: row.get("index_kind"),
            normalized: row.get("normalized"),
            table_name: row.get("table_name"),
            is_default: row.get("is_default"),
            distance: row.get("distance"),
            modality: row.get("modality"),
        }
    }

    /// The plan the model's tables were made with (`stored_plan`).
    pub fn plan(&self) -> StoragePlan {
        StoragePlan::from_row(
            usize::try_from(self.dims).unwrap_or(0),
            usize::try_from(self.stored_dims).unwrap_or(0),
            &self.storage_kind,
            &self.index_kind,
        )
    }

    /// `text` or `image`; a row from before 014_model_modality.sql reads as text (`model_modality`).
    pub fn modality(&self) -> &str {
        if self.modality == "image" { "image" } else { "text" }
    }

    /// The chunk table's name, checked (`assert_safe_table`).
    ///
    /// # Errors
    ///
    /// A row whose table name is not registry-shaped.
    pub fn table(&self) -> Result<&str> {
        assert_safe_table(&self.table_name)
    }
}

/// A model as asked for, before storage decisions (`ModelSpec`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ModelSpec {
    pub slug: String,
    pub model_ref: String,
    pub dims: usize,
    pub provider: String,
    pub normalized: bool,
    pub supports_mrl: bool,
    pub model_id: Option<String>,
    pub distance: String,
    pub modality: String,
}

impl ModelSpec {
    /// A text model of `dims` on `llama_xpc` with cosine distance, as the Python default.
    pub fn new(slug: &str, model_ref: &str, dims: usize) -> Self {
        Self {
            slug: slug.to_owned(),
            model_ref: model_ref.to_owned(),
            dims,
            provider: "llama_xpc".to_owned(),
            normalized: true,
            supports_mrl: false,
            model_id: None,
            distance: "cosine".to_owned(),
            modality: "text".to_owned(),
        }
    }
}

/// Which of a model's three tables (`TABLE_KINDS`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TableKind {
    Chunks,
    PotentialFacts,
    DistilledFacts,
}

pub const TABLE_KINDS: [TableKind; 3] = [TableKind::Chunks, TableKind::PotentialFacts, TableKind::DistilledFacts];

/// Creates one per-model table and its index (`create_embedding_table`); `table` is the chunk
/// table's name whichever kind is made.
///
/// # Errors
///
/// An unsafe name, or the server refusing the DDL.
pub async fn create_embedding_table(
    client: &Client,
    table: &str,
    plan: &StoragePlan,
    distance: &str,
    kind: TableKind,
) -> Result<()> {
    assert_safe_table(table)?;
    let coltype = plan.column_type();
    let (table, key, extra) = match kind {
        TableKind::DistilledFacts => (
            fact_table_name(table)?,
            "distilled_fact_id bigint PRIMARY KEY REFERENCES distilled_facts(id) ON DELETE CASCADE",
            format!("seed        {coltype},"),
        ),
        TableKind::PotentialFacts => (
            potential_fact_table_name(table)?,
            "fact_id     bigint PRIMARY KEY REFERENCES facts(id) ON DELETE CASCADE",
            String::new(),
        ),
        TableKind::Chunks => {
            (table.to_owned(), "chunk_id    bigint PRIMARY KEY REFERENCES chunks(id) ON DELETE CASCADE", String::new())
        }
    };
    client
        .batch_execute(&format!(
            "CREATE TABLE IF NOT EXISTS {table} (\n    {key},\n    embedding   {coltype} NOT NULL,\n    {extra}\n    embedded_at timestamptz NOT NULL DEFAULT now()\n)"
        ))
        .await?;
    if let Some(ddl) = index_ddl(&table, plan, distance) {
        client.batch_execute(&ddl).await?;
    }
    Ok(())
}

/// Registers a model and makes its tables (`register_model`); idempotent on the slug.
///
/// # Errors
///
/// A bad spec, or the server.
pub async fn register_model(client: &mut Client, spec: &ModelSpec, make_default: bool) -> Result<EmbeddingModel> {
    check_distance(&spec.distance)?;
    check_modality(&spec.modality)?;
    if let Some(existing) = find_model(client, &spec.slug).await? {
        if make_default {
            set_default_model(client, &existing.slug).await?;
        }
        return Ok(existing);
    }
    let plan = plan_storage(spec.dims, spec.supports_mrl)?;
    let table = table_name_for(&spec.slug)?;
    let tx = client.transaction().await?;
    for kind in TABLE_KINDS {
        create_embedding_table_in(&tx, &table, &plan, &spec.distance, kind).await?;
    }
    let dims = i32::try_from(spec.dims).map_err(|_| ServiceError::invalid("dims too large"))?;
    let stored = i32::try_from(plan.stored_dims).map_err(|_| ServiceError::invalid("dims too large"))?;
    tx.execute(
        "INSERT INTO embedding_models (slug, provider, model_ref, model_id, dims, stored_dims, storage_kind, index_kind, \
         distance, modality, normalized, table_name, is_default) \
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, false)",
        &[
            &spec.slug,
            &spec.provider,
            &spec.model_ref,
            &spec.model_id,
            &dims,
            &stored,
            &plan.storage_kind,
            &plan.index_kind,
            &spec.distance,
            &spec.modality,
            &spec.normalized,
            &table,
        ],
    )
    .await?;
    let count: i64 = tx.query_one("SELECT count(*) FROM embedding_models", &[]).await?.get(0);
    if make_default || count == 1 {
        tx.execute("UPDATE embedding_models SET is_default = false WHERE is_default", &[]).await?;
        tx.execute("UPDATE embedding_models SET is_default = true WHERE slug = $1", &[&spec.slug]).await?;
    }
    tx.commit().await?;
    find_model(client, &spec.slug).await?.ok_or_else(|| ServiceError::failed("model vanished after registration"))
}

async fn create_embedding_table_in(
    tx: &tokio_postgres::Transaction<'_>,
    table: &str,
    plan: &StoragePlan,
    distance: &str,
    kind: TableKind,
) -> Result<()> {
    // The same DDL as `create_embedding_table`, inside the registration's transaction.
    let coltype = plan.column_type();
    let (table, key, extra) = match kind {
        TableKind::DistilledFacts => (
            fact_table_name(table)?,
            "distilled_fact_id bigint PRIMARY KEY REFERENCES distilled_facts(id) ON DELETE CASCADE",
            format!("seed        {coltype},"),
        ),
        TableKind::PotentialFacts => (
            potential_fact_table_name(table)?,
            "fact_id     bigint PRIMARY KEY REFERENCES facts(id) ON DELETE CASCADE",
            String::new(),
        ),
        TableKind::Chunks => {
            (table.to_owned(), "chunk_id    bigint PRIMARY KEY REFERENCES chunks(id) ON DELETE CASCADE", String::new())
        }
    };
    tx.batch_execute(&format!(
        "CREATE TABLE IF NOT EXISTS {table} (\n    {key},\n    embedding   {coltype} NOT NULL,\n    {extra}\n    embedded_at timestamptz NOT NULL DEFAULT now()\n)"
    ))
    .await?;
    if let Some(ddl) = index_ddl(&table, plan, distance) {
        tx.batch_execute(&ddl).await?;
    }
    Ok(())
}

/// Points the default at `slug` (`set_default_model`): two statements, because a partial unique
/// index allows one default and a single UPDATE could pass through two.
///
/// # Errors
///
/// The server.
pub async fn set_default_model(client: &mut Client, slug: &str) -> Result<()> {
    let tx = client.transaction().await?;
    tx.execute("UPDATE embedding_models SET is_default = false WHERE is_default", &[]).await?;
    tx.execute("UPDATE embedding_models SET is_default = true WHERE slug = $1", &[&slug]).await?;
    tx.commit().await?;
    Ok(())
}

/// The model registered under `slug`, if any.
///
/// # Errors
///
/// The server.
pub async fn find_model(client: &Client, slug: &str) -> Result<Option<EmbeddingModel>> {
    let row = client.query_opt(&format!("SELECT {COLUMNS} FROM embedding_models WHERE slug = $1"), &[&slug]).await?;
    Ok(row.as_ref().map(EmbeddingModel::from_row))
}

/// A model by slug, or with none the default: the row flagged `is_default`, else the configured
/// `embedding.default_model` when it is registered (`get_model`).
///
/// # Errors
///
/// [`ServiceError::NotFound`] when there is no such model, with Python's wording.
pub async fn get_model(client: &Client, slug: Option<&str>, configured_default: &str) -> Result<EmbeddingModel> {
    if let Some(slug) = slug.filter(|s| !s.is_empty()) {
        return find_model(client, slug).await?.ok_or_else(|| {
            ServiceError::not_found(format!("no model {slug:?} registered; run 'garage register-model' first"))
        });
    }
    let row = client.query_opt(&format!("SELECT {COLUMNS} FROM embedding_models WHERE is_default"), &[]).await?;
    if let Some(row) = row {
        return Ok(EmbeddingModel::from_row(&row));
    }
    if !configured_default.is_empty() {
        if let Some(model) = find_model(client, configured_default).await? {
            return Ok(model);
        }
        return Err(ServiceError::not_found(format!(
            "no default model registered, and the configured embedding.default_model {configured_default:?} is not registered either; run 'garage register-model' first"
        )));
    }
    Err(ServiceError::not_found("no default model registered; run 'garage register-model' first"))
}

/// Every model, in registration order (`list_models`).
///
/// # Errors
///
/// The server.
pub async fn list_models(client: &Client) -> Result<Vec<EmbeddingModel>> {
    let rows = client.query(&format!("SELECT {COLUMNS} FROM embedding_models ORDER BY id"), &[]).await?;
    Ok(rows.iter().map(EmbeddingModel::from_row).collect())
}

/// The chunk and potential-fact vectors stored for a model (`count_vectors`).
///
/// # Errors
///
/// An unsafe table name, or the server.
pub async fn count_vectors(client: &Client, table_name: &str) -> Result<i64> {
    let table = assert_safe_table(table_name)?;
    let facts = potential_fact_table_name(table)?;
    let row = client
        .query_one(
            &format!(
                "SELECT (SELECT count(*) FROM {table}) + CASE WHEN to_regclass('{facts}') IS NULL THEN 0 ELSE (SELECT count(*) FROM {facts}) END"
            ),
            &[],
        )
        .await?;
    Ok(row.get(0))
}

/// Creates the model's distilled-fact table when it has none (a model from before 015), with its
/// `seed` column (016); the table's name (`ensure_fact_table`).
///
/// # Errors
///
/// The server.
pub async fn ensure_fact_table(client: &Client, model: &EmbeddingModel) -> Result<String> {
    let plan = model.plan();
    create_embedding_table(client, model.table()?, &plan, &model.distance, TableKind::DistilledFacts).await?;
    let table = fact_table_name(&model.table_name)?;
    client.batch_execute(&format!("ALTER TABLE {table} ADD COLUMN IF NOT EXISTS seed {}", plan.column_type())).await?;
    Ok(table)
}

/// Deregisters a model and drops its tables (`drop_model`).
///
/// # Errors
///
/// No such model, or the server.
pub async fn drop_model(client: &mut Client, slug: &str, configured_default: &str) -> Result<()> {
    let model = get_model(client, Some(slug), configured_default).await?;
    let table = model.table()?.to_owned();
    let tx = client.transaction().await?;
    tx.batch_execute(&format!("DROP TABLE IF EXISTS {}", fact_table_name(&table)?)).await?;
    tx.batch_execute(&format!("DROP TABLE IF EXISTS {}", potential_fact_table_name(&table)?)).await?;
    tx.batch_execute(&format!("DROP TABLE IF EXISTS {table}")).await?;
    tx.execute("DELETE FROM embedding_models WHERE id = $1", &[&model.id]).await?;
    tx.commit().await?;
    Ok(())
}

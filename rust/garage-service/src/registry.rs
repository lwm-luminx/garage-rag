//! A model's width mapped onto pgvector storage (`garage_rag.db.registry`), and the names of its
//! tables (`db.emb_tables`).
//!
//! pgvector 0.8's HNSW ceilings drive it: `vector` indexes to 2000 dimensions, `halfvec` to 4000,
//! `bit` to 64000. A wider model is truncated to 4000 when it is Matryoshka-trained, and otherwise
//! stored full width with its HNSW index on the binary quantization, re-ranked on the exact
//! distance at query time.

use crate::db::assert_safe_table;
use crate::error::{Result, ServiceError};

pub const DISTANCES: [&str; 3] = ["cosine", "l2", "inner_product"];
pub const MODALITIES: [&str; 2] = ["text", "image"];
pub const HNSW_MAX_VECTOR_DIMS: usize = 2000;
pub const HNSW_MAX_HALFVEC_DIMS: usize = 4000;
const MAX_IDENTIFIER: usize = 63;

/// How a model's vectors are stored and indexed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StoragePlan {
    pub stored_dims: usize,
    /// `vector` | `halfvec`.
    pub storage_kind: String,
    /// `hnsw` | `hnsw_bq` | `none`.
    pub index_kind: String,
    /// The model's own width when `stored_dims` is less than it.
    pub truncated_from: Option<usize>,
}

impl StoragePlan {
    pub fn is_truncated(&self) -> bool {
        self.truncated_from.is_some()
    }

    /// The plan a registered model's tables were made with (`stored_plan`, `_plan_from_row`).
    pub fn from_row(dims: usize, stored_dims: usize, storage_kind: &str, index_kind: &str) -> Self {
        Self {
            stored_dims,
            storage_kind: storage_kind.to_owned(),
            index_kind: index_kind.to_owned(),
            truncated_from: (stored_dims < dims).then_some(dims),
        }
    }

    /// DDL fragment for the embedding column: `vector(1024)`, `halfvec(3000)`.
    pub fn column_type(&self) -> String {
        format!("{}({})", self.storage_kind, self.stored_dims)
    }
}

/// `distance` when it is a metric pgvector indexes (`check_distance`).
///
/// # Errors
///
/// [`ServiceError::InvalidArgument`] otherwise.
pub fn check_distance(distance: &str) -> Result<&str> {
    if DISTANCES.contains(&distance) {
        Ok(distance)
    } else {
        Err(ServiceError::invalid(format!("unknown distance {distance:?}; choose one of {}", DISTANCES.join(", "))))
    }
}

/// `modality` when the backfill knows how to feed it (`check_modality`).
///
/// # Errors
///
/// [`ServiceError::InvalidArgument`] otherwise.
pub fn check_modality(modality: &str) -> Result<&str> {
    if MODALITIES.contains(&modality) {
        Ok(modality)
    } else {
        Err(ServiceError::invalid(format!("unknown modality {modality:?}; choose one of {}", MODALITIES.join(", "))))
    }
}

/// The pgvector operator that orders by `distance` (`distance_operator`).
///
/// # Errors
///
/// An unknown metric.
pub fn distance_operator(distance: &str) -> Result<&'static str> {
    Ok(match check_distance(distance)? {
        "cosine" => "<=>",
        "l2" => "<->",
        _ => "<#>",
    })
}

fn ops_suffix(distance: &str) -> &'static str {
    match distance {
        "cosine" => "cosine_ops",
        "l2" => "l2_ops",
        _ => "ip_ops",
    }
}

/// The per-model table name (`table_name_for`): `emb_` and the slug lowercased, runs of anything
/// but `[a-z0-9]` as one `_`, cut to Postgres's 63 bytes.
///
/// # Errors
///
/// A slug with nothing usable in it.
pub fn table_name_for(slug: &str) -> Result<String> {
    let mut normalized = String::new();
    let mut pending_sep = false;
    for ch in slug.trim().to_lowercase().chars() {
        if ch.is_ascii_lowercase() || ch.is_ascii_digit() {
            if pending_sep && !normalized.is_empty() {
                normalized.push('_');
            }
            pending_sep = false;
            normalized.push(ch);
        } else {
            pending_sep = true;
        }
    }
    if normalized.is_empty() {
        return Err(ServiceError::invalid(format!("model slug {slug:?} normalizes to an empty identifier")));
    }
    let mut name = format!("emb_{normalized}");
    name.truncate(MAX_IDENTIFIER);
    Ok(name.trim_end_matches('_').to_owned())
}

/// The table of distilled-fact vectors beside the chunk table `model_table` (`fact_table_name`).
///
/// # Errors
///
/// An unsafe table name.
pub fn fact_table_name(model_table: &str) -> Result<String> {
    let mut name = format!("fact_{}", assert_safe_table(model_table)?);
    name.truncate(MAX_IDENTIFIER);
    Ok(name)
}

/// The table of potential-fact vectors beside the chunk table `model_table`.
///
/// # Errors
///
/// An unsafe table name.
pub fn potential_fact_table_name(model_table: &str) -> Result<String> {
    let mut name = format!("potential_fact_{}", assert_safe_table(model_table)?);
    name.truncate(MAX_IDENTIFIER);
    Ok(name)
}

/// Storage type and index strategy for a model of width `dims` (`plan_storage`).
///
/// # Errors
///
/// A width that is not positive.
pub fn plan_storage(dims: usize, supports_mrl: bool) -> Result<StoragePlan> {
    if dims == 0 {
        return Err(ServiceError::invalid("dims must be positive, got 0"));
    }
    let plan = |stored_dims, storage_kind: &str, index_kind: &str, truncated_from| StoragePlan {
        stored_dims,
        storage_kind: storage_kind.into(),
        index_kind: index_kind.into(),
        truncated_from,
    };
    Ok(if dims <= HNSW_MAX_VECTOR_DIMS {
        plan(dims, "vector", "hnsw", None)
    } else if dims <= HNSW_MAX_HALFVEC_DIMS {
        plan(dims, "halfvec", "hnsw", None)
    } else if supports_mrl {
        plan(HNSW_MAX_HALFVEC_DIMS, "halfvec", "hnsw", Some(dims))
    } else {
        plan(dims, "vector", "hnsw_bq", None)
    })
}

/// DDL for the vector index of `table`, or `None` for an unindexed model (`index_ddl`).
pub fn index_ddl(table: &str, plan: &StoragePlan, distance: &str) -> Option<String> {
    match plan.index_kind.as_str() {
        "none" => None,
        "hnsw" => Some(format!(
            "CREATE INDEX IF NOT EXISTS {table}_hnsw ON {table} USING hnsw (embedding {}_{}) WITH (m = 16, ef_construction = 64)",
            plan.storage_kind,
            ops_suffix(distance)
        )),
        _ => Some(format!(
            "CREATE INDEX IF NOT EXISTS {table}_hnsw_bq ON {table} USING hnsw ((binary_quantize(embedding)::bit({})) bit_hamming_ops)",
            plan.stored_dims
        )),
    }
}

/// The plan's dimensional reduction applied to one embedding, re-normalized (`truncate_vector`).
///
/// # Errors
///
/// A vector shorter than the plan stores.
pub fn truncate_vector(values: &[f32], plan: &StoragePlan) -> Result<Vec<f32>> {
    if values.len() == plan.stored_dims {
        return Ok(values.to_vec());
    }
    if values.len() < plan.stored_dims {
        return Err(ServiceError::invalid(format!(
            "embedding has {} dims, expected at least {}",
            values.len(),
            plan.stored_dims
        )));
    }
    let head = &values[..plan.stored_dims];
    let norm = head.iter().map(|v| f64::from(*v) * f64::from(*v)).sum::<f64>().sqrt();
    if norm == 0.0 {
        return Ok(head.to_vec());
    }
    #[allow(clippy::cast_possible_truncation)] // back to the vector's own precision
    Ok(head.iter().map(|v| (f64::from(*v) / norm) as f32).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn widths_map_onto_storage_as_python_did() {
        assert_eq!(plan_storage(1024, false).unwrap().column_type(), "vector(1024)");
        let wide = plan_storage(3000, false).unwrap();
        assert_eq!((wide.storage_kind.as_str(), wide.index_kind.as_str()), ("halfvec", "hnsw"));
        let mrl = plan_storage(4096, true).unwrap();
        assert_eq!((mrl.stored_dims, mrl.truncated_from), (4000, Some(4096)));
        let huge = plan_storage(4096, false).unwrap();
        assert_eq!((huge.storage_kind.as_str(), huge.index_kind.as_str()), ("vector", "hnsw_bq"));
        assert!(plan_storage(0, false).is_err());
        assert!(index_ddl("emb_m", &huge, "cosine").unwrap().contains("bit_hamming_ops"));
        assert!(index_ddl("emb_m", &wide, "l2").unwrap().contains("halfvec_l2_ops"));
    }

    #[test]
    fn table_names_are_normalized_and_bounded() {
        assert_eq!(table_name_for("BGE-M3").unwrap(), "emb_bge_m3");
        assert_eq!(table_name_for("  nomic/embed-text:v1.5 ").unwrap(), "emb_nomic_embed_text_v1_5");
        assert!(table_name_for("---").is_err());
        assert_eq!(table_name_for(&"a".repeat(80)).unwrap().len(), 63);
        assert_eq!(fact_table_name("emb_m").unwrap(), "fact_emb_m");
        assert_eq!(potential_fact_table_name("emb_m").unwrap(), "potential_fact_emb_m");
        assert!(fact_table_name("documents").is_err());
    }

    #[test]
    fn truncation_renormalizes() {
        let plan = plan_storage(4096, true).unwrap();
        let mut values = vec![0.0; 4096];
        values[0] = 3.0;
        values[1] = 4.0;
        let reduced = truncate_vector(&values, &plan).unwrap();
        assert_eq!(reduced.len(), 4000);
        assert!((reduced[0] - 0.6).abs() < 1e-6 && (reduced[1] - 0.8).abs() < 1e-6);
        assert!(truncate_vector(&[1.0; 10], &plan).is_err());
        assert_eq!(distance_operator("inner_product").unwrap(), "<#>");
        assert!(check_modality("audio").is_err());
    }
}

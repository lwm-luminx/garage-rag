//! The embedding-model catalog, `data/models/models.json` (`garage_rag.db.catalog`).
//!
//! One file describes every model the app offers: its width, the metric it was trained for,
//! whether it is Matryoshka-trained, and how each provider names it. Reading it here is what lets
//! `RegisterModel bge-m3` arrive with no width. The file is found through `GARAGE_MODEL_MANIFEST`
//! (the app points it at the copy it last fetched from the website, else the one in its bundle)
//! or beside the SQL in `data/`. Entries without `native_dims` (the generative models) are not
//! embedding models and are skipped.

use std::collections::BTreeMap;
use std::path::PathBuf;

use serde_json::{Map, Value};

use crate::error::{Result, ServiceError};
use crate::migrate::default_sql_dir;
use crate::models::ModelSpec;
use crate::registry::{check_distance, check_modality};

pub const MANIFEST_ENV: &str = "GARAGE_MODEL_MANIFEST";

/// The catalog sections that describe embedding models, and what their models embed.
const EMBEDDING_SECTIONS: [(&str, &str); 2] = [("text_embedding", "text"), ("image_embedding", "image")];

/// A catalogued model: the spec and the name each provider knows it by.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CatalogModel {
    pub spec: ModelSpec,
    pub provider_refs: BTreeMap<String, String>,
}

impl CatalogModel {
    /// The model's name under `provider` (`ModelSpec.ref_for`).
    pub fn ref_for(&self, provider: &str) -> &str {
        self.provider_refs.get(provider).map_or(self.spec.model_ref.as_str(), String::as_str)
    }
}

/// The models.json in use, or none when there is none to read (`manifest_path`).
pub fn manifest_path() -> Option<PathBuf> {
    if let Some(path) = std::env::var_os(MANIFEST_ENV).filter(|p| !p.is_empty()) {
        return Some(crate::config::expand_home(&PathBuf::from(path)));
    }
    let candidate = default_sql_dir().parent()?.join("models").join("models.json");
    candidate.is_file().then_some(candidate)
}

/// The spec a `text_embedding` or `image_embedding` entry describes, or none for an entry that
/// is not an embedding model (`spec_from_entry`).
///
/// # Errors
///
/// An entry with no slug, or an unknown distance or modality.
pub fn spec_from_entry(entry: &Map<String, Value>, section_modality: &str) -> Result<Option<CatalogModel>> {
    let dims = entry.get("native_dims").and_then(Value::as_u64).unwrap_or(0);
    if dims == 0 {
        return Ok(None);
    }
    let text = |key: &str| entry.get(key).and_then(Value::as_str).filter(|s| !s.is_empty()).map(str::to_owned);
    let slug = text("slug").ok_or_else(|| ServiceError::invalid("models.json: an embedding model has no slug"))?;
    let modality = check_modality(&text("modality").unwrap_or_else(|| section_modality.to_owned()))?.to_owned();
    let default_provider = if modality == "image" { "image_xpc" } else { "llama_xpc" };
    let spec = ModelSpec {
        model_ref: text("model_ref").unwrap_or_else(|| slug.clone()),
        dims: usize::try_from(dims).map_err(|_| ServiceError::invalid("models.json: native_dims too large"))?,
        provider: text("provider").unwrap_or_else(|| default_provider.to_owned()),
        normalized: true,
        supports_mrl: entry.get("supports_mrl").and_then(Value::as_bool).unwrap_or(false),
        model_id: text("model_id"),
        distance: check_distance(&text("distance").unwrap_or_else(|| "cosine".to_owned()))?.to_owned(),
        modality,
        slug,
    };
    let provider_refs = entry
        .get("provider_refs")
        .and_then(Value::as_object)
        .map(|refs| refs.iter().filter_map(|(k, v)| v.as_str().map(|v| (k.clone(), v.to_owned()))).collect())
        .unwrap_or_default();
    Ok(Some(CatalogModel { spec, provider_refs }))
}

/// Every embedding model a catalog document describes, by slug.
///
/// # Errors
///
/// A malformed entry.
pub fn models_in(document: &Value) -> Result<BTreeMap<String, CatalogModel>> {
    let mut models = BTreeMap::new();
    let sections: Vec<(&Vec<Value>, &str)> = match document {
        Value::Object(map) => EMBEDDING_SECTIONS
            .iter()
            .filter_map(|(name, modality)| map.get(*name).and_then(Value::as_array).map(|entries| (entries, *modality)))
            .collect(),
        Value::Array(entries) => vec![(entries, "text")],
        _ => Vec::new(),
    };
    for (entries, modality) in sections {
        for entry in entries.iter().filter_map(Value::as_object) {
            if let Some(model) = spec_from_entry(entry, modality)? {
                models.insert(model.spec.slug.clone(), model);
            }
        }
    }
    Ok(models)
}

/// Every embedding model in the catalog, by slug; empty when there is no catalog (`known_models`).
///
/// # Errors
///
/// A catalog that cannot be read or parsed.
pub fn known_models() -> Result<BTreeMap<String, CatalogModel>> {
    let Some(path) = manifest_path() else { return Ok(BTreeMap::new()) };
    let text = std::fs::read_to_string(&path)
        .map_err(|e| ServiceError::failed(format!("cannot read {}: {e}", path.display())))?;
    let document: Value = serde_json::from_str(&text)
        .map_err(|e| ServiceError::failed(format!("{} is not valid JSON: {e}", path.display())))?;
    models_in(&document)
}

/// What `RegisterModel` was asked for, each field explicit or left to the catalog.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ModelRequest {
    pub slug: String,
    pub dims: Option<usize>,
    pub model_ref: Option<String>,
    pub provider: Option<String>,
    pub model_id: Option<String>,
    pub distance: Option<String>,
    pub modality: Option<String>,
}

/// The catalog's model adjusted by the explicit arguments, or a spec built from the arguments
/// alone for a model the catalog does not list (`resolve_spec`).
///
/// # Errors
///
/// An uncatalogued model with no width, or an unknown distance or modality.
pub fn resolve_spec(request: &ModelRequest, catalog: &BTreeMap<String, CatalogModel>) -> Result<ModelSpec> {
    let distance = request.distance.as_deref().map(check_distance).transpose()?;
    let modality = request.modality.as_deref().map(check_modality).transpose()?;
    if let Some(known) = catalog.get(&request.slug) {
        let provider = request.provider.clone().unwrap_or_else(|| known.spec.provider.clone());
        let model_ref = request.model_ref.clone().unwrap_or_else(|| known.ref_for(&provider).to_owned());
        return Ok(ModelSpec {
            slug: known.spec.slug.clone(),
            model_ref,
            // Trust the caller's width: a quantized or MRL-truncated pull can differ.
            dims: request.dims.unwrap_or(known.spec.dims),
            provider,
            normalized: known.spec.normalized,
            supports_mrl: known.spec.supports_mrl,
            model_id: request.model_id.clone().or_else(|| known.spec.model_id.clone()),
            distance: distance.map_or_else(|| known.spec.distance.clone(), str::to_owned),
            modality: modality.map_or_else(|| known.spec.modality.clone(), str::to_owned),
        });
    }
    let Some(dims) = request.dims else {
        return Err(ServiceError::invalid(format!(
            "model {} is not in models.json; pass --dims explicitly",
            garage_mcp::pyrepr::str_repr(&request.slug)
        )));
    };
    Ok(ModelSpec {
        slug: request.slug.clone(),
        model_ref: request.model_ref.clone().unwrap_or_else(|| request.slug.clone()),
        dims,
        provider: request.provider.clone().unwrap_or_else(|| "llama_xpc".to_owned()),
        normalized: true,
        supports_mrl: false,
        model_id: request.model_id.clone(),
        distance: distance.unwrap_or("cosine").to_owned(),
        modality: modality.unwrap_or("text").to_owned(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn catalog() -> BTreeMap<String, CatalogModel> {
        models_in(&json!({
            "text_embedding": [
                {"slug": "bge-m3", "model_ref": "bge-m3", "native_dims": 1024, "distance": "cosine",
                 "provider_refs": {"ollama": "bge-m3:latest"}, "model_id": "BAAI/bge-m3"},
                {"slug": "qwen3-8b", "native_dims": 4096, "supports_mrl": true},
                {"slug": "gemma", "name": "a chat model"}
            ],
            "image_embedding": [{"slug": "clip", "native_dims": 512}]
        }))
        .unwrap()
    }

    #[test]
    fn catalog_entries_become_specs() {
        let models = catalog();
        assert_eq!(models.len(), 3);
        let bge = &models["bge-m3"];
        assert_eq!((bge.spec.dims, bge.spec.provider.as_str()), (1024, "llama_xpc"));
        assert_eq!(bge.ref_for("ollama"), "bge-m3:latest");
        assert_eq!(bge.ref_for("lmstudio"), "bge-m3");
        assert_eq!(
            (models["clip"].spec.provider.as_str(), models["clip"].spec.modality.as_str()),
            ("image_xpc", "image")
        );
        assert!(models["qwen3-8b"].spec.supports_mrl);
        assert!(models_in(&json!({"text_embedding": [{"slug": "x", "native_dims": 8, "distance": "dot"}]})).is_err());
    }

    #[test]
    fn requests_resolve_against_the_catalog() {
        let models = catalog();
        let request = |slug: &str| ModelRequest { slug: slug.to_owned(), ..ModelRequest::default() };
        let spec = resolve_spec(&request("bge-m3"), &models).unwrap();
        assert_eq!((spec.model_ref.as_str(), spec.model_id.as_deref()), ("bge-m3", Some("BAAI/bge-m3")));
        let on_ollama = resolve_spec(
            &ModelRequest { provider: Some("ollama".into()), dims: Some(1000), ..request("bge-m3") },
            &models,
        )
        .unwrap();
        assert_eq!((on_ollama.model_ref.as_str(), on_ollama.dims), ("bge-m3:latest", 1000));
        let err = resolve_spec(&request("mystery"), &models).unwrap_err();
        assert_eq!(err.message(), "model 'mystery' is not in models.json; pass --dims explicitly");
        let own =
            resolve_spec(&ModelRequest { dims: Some(384), distance: Some("l2".into()), ..request("mystery") }, &models)
                .unwrap();
        assert_eq!((own.provider.as_str(), own.distance.as_str(), own.modality.as_str()), ("llama_xpc", "l2", "text"));
        assert!(resolve_spec(&ModelRequest { modality: Some("audio".into()), ..request("bge-m3") }, &models).is_err());
    }
}

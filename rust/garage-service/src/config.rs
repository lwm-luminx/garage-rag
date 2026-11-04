//! `garage.json`, as far as the service reads it (`garage_rag.config`).
//!
//! The file is nested (`{"embedding": {"ollama_host": ...}}`); the code reads it flat. [`SECTIONS`]
//! is the one table that knows both shapes, as Python's `SECTIONS` was, so `GetSetting` answers
//! for every key the file accepts and an unknown key is an error, not a silent no-op. Settings the
//! service does not read yet are carried as the JSON they were written as.
//!
//! Writing (`SetSetting`, the schema) comes with the operations stage of
//! docs/plans/python-removal.md.

use std::path::{Path, PathBuf};

use serde_json::{Map, Value, json};

use crate::error::{Result, ServiceError};

/// The project-local file name, looked for in the working directory first.
pub const CONFIG_FILENAME: &str = "garage.json";
/// The per-user file, `~/.garage.json`.
pub const USER_CONFIG_FILENAME: &str = ".garage.json";
/// The app's database credential, applied over the file and never written to it.
pub const DATABASE_URL_ENV: &str = "GARAGE_DATABASE_URL";

/// One setting: its section and key in the file, its flat field name, and its default.
#[derive(Debug)]
pub struct Setting {
    pub section: &'static str,
    pub key: &'static str,
    pub field: &'static str,
    default: fn() -> Value,
}

impl Setting {
    pub fn default_value(&self) -> Value {
        (self.default)()
    }

    /// `section.key`.
    pub fn name(&self) -> String {
        format!("{}.{}", self.section, self.key)
    }
}

macro_rules! setting {
    ($section:literal, $key:literal, $field:literal, $default:expr) => {
        Setting { section: $section, key: $key, field: $field, default: || json!($default) }
    };
}

/// Every setting the file accepts, in file order (`garage_rag.config.SECTIONS` with each
/// field's default beside it).
pub static SECTIONS: &[Setting] = &[
    setting!("database", "url", "database_url", "postgresql+psycopg:///rag"),
    setting!("database", "hnsw_ef_search", "hnsw_ef_search", 100),
    setting!("identity", "name", "self_name", ""),
    setting!("identity", "identities", "self_identities", Value::Array(Vec::new())),
    setting!("embedding", "ollama_host", "ollama_host", "http://localhost:11434"),
    setting!("embedding", "lmstudio_host", "lmstudio_host", "http://localhost:1234/v1"),
    setting!("embedding", "llama_host", "llama_host", "http://127.0.0.1:8790"),
    setting!("embedding", "lmstudio_api_token_file", "lmstudio_api_token_file", Value::Null),
    setting!("embedding", "default_model", "default_embedding_model", "bge-m3"),
    setting!("embedding", "batch_size", "embed_batch_size", 64),
    setting!("chunking", "size", "chunk_size", 1000),
    setting!("chunking", "overlap", "chunk_overlap", 150),
    setting!("chunking", "code_size", "code_chunk_size", 1200),
    setting!("chunking", "code_overlap", "code_chunk_overlap", 100),
    setting!("placeholders", "materialize", "materialize_placeholders", false),
    setting!("placeholders", "limit", "materialize_limit", 2000),
    setting!("placeholders", "max_bytes", "materialize_max_bytes", 20u64 * 1024 * 1024 * 1024),
    setting!("placeholders", "timeout_seconds", "materialize_timeout_seconds", 120.0),
    setting!("quality", "max_chunks_per_document", "max_chunks_per_document", 1500),
    setting!("quality", "reject_machine_generated", "reject_machine_generated", true),
    setting!("extraction", "max_file_bytes", "max_file_bytes", 64 * 1024 * 1024),
    setting!("extraction", "pdf_min_chars_per_page", "pdf_min_chars_per_page", 32),
    setting!("extraction", "ocr_min_chars", "ocr_min_chars", 16),
    setting!("extraction", "index_images", "index_images", true),
    setting!("extraction", "plugins", "extraction_plugins", Value::Array(Vec::new())),
    setting!("mcp", "host", "mcp_host", "127.0.0.1"),
    setting!("mcp", "port", "mcp_port", 8787),
    setting!("mcp", "path", "mcp_http_path", "/mcp"),
    setting!("facts", "model", "fact_model", "gemma2-2b"),
    setting!("facts", "provider", "fact_provider", "llama_xpc"),
    setting!("facts", "prompts", "fact_prompts", Value::Array(Vec::new())),
    setting!("facts", "cluster_threshold", "fact_cluster_threshold", 0.9),
    setting!("facts", "cluster_restate_threshold", "fact_cluster_restate_threshold", 0.92),
    setting!("facts", "cluster_neighbors", "fact_cluster_neighbors", 10),
    setting!("facts", "cluster_seed_threshold", "fact_cluster_seed_threshold", 0.95),
    setting!("facts", "cluster_max_drift", "fact_cluster_max_drift", 0.05),
    setting!("facts", "cluster_tight_similarity", "fact_cluster_tight_similarity", 0.97),
    setting!("facts", "cluster_growth_neighbors", "fact_cluster_growth_neighbors", 50),
    setting!("facts", "cluster_growth_rounds", "fact_cluster_growth_rounds", 4),
    setting!("facts", "cluster_attach_candidates", "fact_cluster_attach_candidates", 5),
    setting!("facts", "cluster_distill_facts", "fact_cluster_distill_facts", 20),
    setting!("facts", "cluster_max_pairwise", "fact_cluster_max_pairwise", 300),
    setting!("inference", "model", "inference_model", ""),
    setting!("inference", "provider", "inference_provider", ""),
];

/// Keys older files may still carry, ignored with a warning (`RETIRED_KEYS`). A section listed
/// here and absent from [`SECTIONS`] is retired whole.
pub static RETIRED_KEYS: &[(&str, &[&str])] = &[
    ("embedding", &["max_inflight"]),
    ("chunking", &["comms_window_minutes", "comms_window_messages"]),
    ("extraction", &["workers", "ocr_min_confidence"]),
    ("cloud", &["enable_ocr", "model", "api_key_file", "max_images"]),
    ("sources", &["allow_cloud_enrichment"]),
];

fn sections() -> Vec<&'static str> {
    let mut names: Vec<&'static str> = Vec::new();
    for setting in SECTIONS {
        if !names.contains(&setting.section) {
            names.push(setting.section);
        }
    }
    names
}

fn keys_of(section: &str) -> Vec<&'static str> {
    SECTIONS.iter().filter(|s| s.section == section).map(|s| s.key).collect()
}

fn retired(section: &str) -> &'static [&'static str] {
    RETIRED_KEYS.iter().find(|(name, _)| *name == section).map_or(&[], |(_, keys)| keys)
}

/// `"section.key"` -> the setting (`resolve_setting`), or the error naming the valid keys.
///
/// # Errors
///
/// [`ServiceError::InvalidArgument`] (Python's `ConfigError`) for a malformed or unknown name.
pub fn resolve_setting(name: &str) -> Result<&'static Setting> {
    let Some((section, key)) = name.split_once('.').filter(|(s, k)| !s.is_empty() && !k.is_empty()) else {
        let valid: Vec<String> = SECTIONS.iter().map(Setting::name).collect();
        return Err(ServiceError::invalid(format!(
            "expected SECTION.KEY, got {name:?}; valid keys: {}",
            valid.join(", ")
        )));
    };
    if !sections().contains(&section) {
        return Err(ServiceError::invalid(format!(
            "unknown section {section:?}; expected one of: {}",
            sections().join(", ")
        )));
    }
    SECTIONS.iter().find(|s| s.section == section && s.key == key).ok_or_else(|| {
        ServiceError::invalid(format!(
            "unknown key {key:?} in section {section:?}; expected one of: {}",
            keys_of(section).join(", ")
        ))
    })
}

/// The configuration in effect: the file's values over the defaults, with
/// `GARAGE_DATABASE_URL` applied.
#[derive(Clone, Debug, Default)]
pub struct Config {
    /// Flat field name -> value, for the fields the file set.
    values: Map<String, Value>,
    /// The `sources` list as written.
    pub sources: Vec<Value>,
    /// The file the values came from, when there was one.
    pub path: Option<PathBuf>,
}

impl Config {
    /// The defaults, as a process with no `garage.json` runs (`Settings()`), with the
    /// environment's database URL applied.
    pub fn defaults() -> Self {
        apply_database_url_environment(Self::default())
    }

    /// Loads `path`, or with none the first of `./garage.json`, `~/.garage.json`; no file at all
    /// means the defaults (`load_config`).
    ///
    /// # Errors
    ///
    /// [`ServiceError::InvalidArgument`] when an explicit path is missing or the file is malformed,
    /// has an unknown section or key, or `GARAGE_DATABASE_URL` is set but empty.
    pub fn load(path: Option<&Path>) -> Result<Self> {
        let resolved = match path {
            Some(path) => {
                let path = expand_home(path);
                if !path.is_file() {
                    return Err(ServiceError::invalid(format!(
                        "no config file found (looked at: {}); create one with 'garage config init'",
                        path.display()
                    )));
                }
                path
            }
            None => match candidate_paths().into_iter().find(|p| p.is_file()) {
                Some(path) => path,
                None => return Ok(Self::defaults()),
            },
        };
        let text = std::fs::read_to_string(&resolved)
            .map_err(|e| ServiceError::invalid(format!("cannot read {}: {e}", resolved.display())))?;
        let raw: Value = serde_json::from_str(&text)
            .map_err(|e| ServiceError::invalid(format!("{} is not valid JSON: {e}", resolved.display())))?;
        let Value::Object(document) = raw else {
            return Err(ServiceError::invalid(format!("{} must contain a JSON object", resolved.display())));
        };
        let mut config = flatten(&document)?;
        config.path = Some(resolved);
        Ok(apply_database_url_environment(config))
    }

    /// The effective value of the field `field` (its default when the file did not set it).
    /// Sets a flat field in memory, as a test or a later `SetSetting` does; nothing is written.
    pub fn set_field(&mut self, field: &str, value: Value) {
        self.values.insert(field.to_owned(), value);
    }

    pub fn field(&self, field: &str) -> Value {
        if let Some(value) = self.values.get(field) {
            return value.clone();
        }
        SECTIONS.iter().find(|s| s.field == field).map_or(Value::Null, Setting::default_value)
    }

    /// The effective value of `SECTION.KEY` as JSON (`ops.settings.get_setting`).
    ///
    /// # Errors
    ///
    /// An unknown name.
    pub fn setting(&self, name: &str) -> Result<Value> {
        Ok(self.field(resolve_setting(name)?.field))
    }

    fn text(&self, field: &str) -> String {
        match self.field(field) {
            Value::String(text) => text,
            Value::Null => String::new(),
            other => other.to_string(),
        }
    }

    #[allow(clippy::cast_possible_truncation)] // a setting's number as `int()` reads it
    fn integer(&self, field: &str) -> i64 {
        self.field(field).as_i64().or_else(|| self.field(field).as_f64().map(|f| f as i64)).unwrap_or(0)
    }

    /// `database.url`, the SQLAlchemy-shaped URL (`postgresql+psycopg://...`).
    pub fn database_url(&self) -> String {
        self.text("database_url")
    }

    /// `database.hnsw_ef_search`.
    pub fn hnsw_ef_search(&self) -> i64 {
        self.integer("hnsw_ef_search")
    }

    /// `identity.name`, the corpus owner's display name.
    pub fn self_name(&self) -> String {
        self.text("self_name")
    }

    /// `identity.identities` parsed into `(kind, value)` pairs (`Settings.self_identity_pairs`).
    pub fn self_identity_pairs(&self) -> Vec<(String, String)> {
        let Value::Array(items) = self.field("self_identities") else { return Vec::new() };
        items
            .iter()
            .filter_map(Value::as_str)
            .filter_map(|raw| {
                let (kind, value) = raw.split_once(':')?;
                let value = value.trim();
                (!value.is_empty()).then(|| (kind.trim().to_owned(), value.to_owned()))
            })
            .collect()
    }

    /// `embedding.default_model`.
    pub fn default_embedding_model(&self) -> String {
        self.text("default_embedding_model")
    }

    /// The model servers as the embed worker names them (`embedding.*`), the way the worker reads
    /// them from a running service.
    pub fn embed_settings(&self) -> garage_embed::Settings {
        garage_embed::Settings::from_service(|key| self.setting(key))
    }
}

/// Nested file layout -> flat values (`flatten`): unknown sections and keys are errors, retired
/// ones warnings, `$`-prefixed keys editor metadata.
fn flatten(document: &Map<String, Value>) -> Result<Config> {
    let mut config = Config::default();
    let known = sections();
    for (section, body) in document {
        if section.starts_with('$') {
            continue;
        }
        if section == "sources" {
            let Value::Array(items) = body else {
                return Err(ServiceError::invalid("'sources' must be a list"));
            };
            config.sources.clone_from(items);
            continue;
        }
        let retired_section = RETIRED_KEYS.iter().any(|(name, _)| name == section);
        if !known.contains(&section.as_str()) && !retired_section {
            let mut expected: Vec<&str> = known.clone();
            expected.push("sources");
            return Err(ServiceError::invalid(format!(
                "unknown section {section:?}; expected one of: {}",
                expected.join(", ")
            )));
        }
        let Value::Object(body) = body else {
            return Err(ServiceError::invalid(format!("section {section:?} must be an object")));
        };
        for (key, value) in body {
            match SECTIONS.iter().find(|s| s.section == section && s.key == key) {
                Some(setting) => {
                    config.values.insert(setting.field.to_owned(), value.clone());
                }
                None if retired(section).contains(&key.as_str()) => {
                    eprintln!("config: {section}.{key} is no longer a setting and was ignored; remove it");
                }
                None => {
                    return Err(ServiceError::invalid(format!(
                        "unknown key {key:?} in section {section:?}; expected one of: {}",
                        keys_of(section).join(", ")
                    )));
                }
            }
        }
    }
    Ok(config)
}

fn apply_database_url_environment(mut config: Config) -> Config {
    if let Ok(url) = std::env::var(DATABASE_URL_ENV) {
        // Python refused an empty value; here it is a defect of the launcher and is reported by
        // the connection failing to parse rather than by refusing to start.
        config.values.insert("database_url".to_owned(), Value::String(url));
    }
    config
}

/// `~/.garage.json`.
pub fn default_config_path() -> PathBuf {
    home().join(USER_CONFIG_FILENAME)
}

/// The search order: `./garage.json`, then `~/.garage.json`.
pub fn candidate_paths() -> Vec<PathBuf> {
    vec![std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")).join(CONFIG_FILENAME), default_config_path()]
}

fn home() -> PathBuf {
    std::env::var_os("HOME").map_or_else(|| PathBuf::from("/"), PathBuf::from)
}

/// `~` and `~/...` as the home folder (`expand_home`); anything else unchanged.
pub fn expand_home(path: &Path) -> PathBuf {
    let Some(text) = path.to_str() else { return path.to_path_buf() };
    if text == "~" {
        return home();
    }
    text.strip_prefix("~/").map_or_else(|| path.to_path_buf(), |rest| home().join(rest))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn from_json(text: &str) -> Result<Config> {
        let Value::Object(document) = serde_json::from_str(text).unwrap() else { panic!() };
        flatten(&document)
    }

    #[test]
    fn every_setting_has_a_section_key_and_default() {
        let config = Config::default();
        for setting in SECTIONS {
            assert_eq!(config.setting(&setting.name()).unwrap(), setting.default_value());
        }
        assert_eq!(SECTIONS.len(), 44);
    }

    #[test]
    fn file_values_replace_defaults_and_retired_keys_are_ignored() {
        let config = from_json(
            r#"{"$schema": "x", "embedding": {"ollama_host": "http://gpu:11434", "max_inflight": 4},
                "identity": {"identities": ["git_email:me@example.com", "bad", "phone: +1555 "]},
                "sources": [{"slug": "notes", "root": "~/Notes"}]}"#,
        )
        .unwrap();
        assert_eq!(config.setting("embedding.ollama_host").unwrap(), json!("http://gpu:11434"));
        assert_eq!(config.setting("embedding.batch_size").unwrap(), json!(64));
        assert_eq!(
            config.self_identity_pairs(),
            vec![("git_email".to_owned(), "me@example.com".to_owned()), ("phone".to_owned(), "+1555".to_owned())]
        );
        assert_eq!(config.sources.len(), 1);
        assert_eq!(config.embed_settings().ollama_host, "http://gpu:11434");
    }

    #[test]
    fn unknown_sections_and_keys_are_errors() {
        assert!(from_json(r#"{"embeddings": {}}"#).unwrap_err().message().starts_with("unknown section"));
        assert!(from_json(r#"{"embedding": {"host": 1}}"#).unwrap_err().message().starts_with("unknown key"));
        assert!(from_json(r#"{"embedding": []}"#).unwrap_err().message().contains("must be an object"));
        assert!(from_json(r#"{"cloud": {"model": "x"}}"#).is_ok());
    }

    #[test]
    fn setting_names_are_checked() {
        assert!(resolve_setting("facts").unwrap_err().message().starts_with("expected SECTION.KEY"));
        assert!(resolve_setting("nope.model").unwrap_err().message().starts_with("unknown section"));
        assert!(resolve_setting("facts.nope").unwrap_err().message().starts_with("unknown key"));
        assert_eq!(resolve_setting("facts.model").unwrap().field, "fact_model");
    }
}

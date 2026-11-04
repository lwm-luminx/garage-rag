//! `garage.json`, as far as the service reads it (`garage_rag.config`).
//!
//! The file is nested (`{"embedding": {"ollama_host": ...}}`); the code reads it flat. [`SECTIONS`]
//! is the one table that knows both shapes, as Python's `SECTIONS` was, so `GetSetting` answers
//! for every key the file accepts and an unknown key is an error, not a silent no-op. Settings the
//! service does not read yet are carried as the JSON they were written as.
//!
//! Writing (`SetSetting`, Sync's import, Remove's drop) rebuilds the nested file from what it
//! already says plus the one change, never from the loaded values, which carry the app-managed
//! database URL from the environment ([`update_config`], [`save_config`]).

use std::path::{Path, PathBuf};

use serde_json::{Map, Value, json};

use crate::error::{Result, ServiceError};

/// The project-local file name, looked for in the working directory first.
pub const CONFIG_FILENAME: &str = "garage.json";
/// The per-user file, `~/.garage.json`.
pub const USER_CONFIG_FILENAME: &str = ".garage.json";
/// The app's database credential, applied over the file and never written to it.
pub const DATABASE_URL_ENV: &str = "GARAGE_DATABASE_URL";

/// The type a setting's field has in Python's `Settings`, which decides how `SetSetting`'s text
/// is read (`coerce_setting`) and what the file may hold.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Str,
    /// `str | None`: `""`, `none` and `null` store `null`.
    OptStr,
    Bool,
    Int,
    Float,
    /// `list[str]`, comma-separated on the command line.
    StrList,
    /// `facts.prompts`: a JSON array of prompt objects.
    Prompts,
    /// A `Literal[...]` of these words.
    Choice(&'static [&'static str]),
}

/// One setting: its section and key in the file, its flat field name, its type and its default.
#[derive(Debug)]
pub struct Setting {
    pub section: &'static str,
    pub key: &'static str,
    pub field: &'static str,
    pub kind: Kind,
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
    ($section:literal, $key:literal, $field:literal, $kind:expr, $default:expr) => {
        Setting { section: $section, key: $key, field: $field, kind: $kind, default: || json!($default) }
    };
}

const PROVIDERS: &[&str] = &["llama_xpc", "ollama", "lmstudio"];
const INFERENCE_PROVIDERS: &[&str] = &["", "llama_xpc", "ollama", "lmstudio"];

/// Every setting the file accepts, in file order (`garage_rag.config.SECTIONS` with each
/// field's default beside it).
pub static SECTIONS: &[Setting] = &[
    setting!("database", "url", "database_url", Kind::Str, "postgresql+psycopg:///rag"),
    setting!("database", "hnsw_ef_search", "hnsw_ef_search", Kind::Int, 100),
    setting!("identity", "name", "self_name", Kind::Str, ""),
    setting!("identity", "identities", "self_identities", Kind::StrList, Value::Array(Vec::new())),
    setting!("embedding", "ollama_host", "ollama_host", Kind::Str, "http://localhost:11434"),
    setting!("embedding", "lmstudio_host", "lmstudio_host", Kind::Str, "http://localhost:1234/v1"),
    setting!("embedding", "llama_host", "llama_host", Kind::Str, "http://127.0.0.1:8790"),
    setting!("embedding", "lmstudio_api_token_file", "lmstudio_api_token_file", Kind::OptStr, Value::Null),
    setting!("embedding", "default_model", "default_embedding_model", Kind::Str, "bge-m3"),
    setting!("embedding", "batch_size", "embed_batch_size", Kind::Int, 64),
    setting!("chunking", "size", "chunk_size", Kind::Int, 1000),
    setting!("chunking", "overlap", "chunk_overlap", Kind::Int, 150),
    setting!("chunking", "code_size", "code_chunk_size", Kind::Int, 1200),
    setting!("chunking", "code_overlap", "code_chunk_overlap", Kind::Int, 100),
    setting!("placeholders", "materialize", "materialize_placeholders", Kind::Bool, false),
    setting!("placeholders", "limit", "materialize_limit", Kind::Int, 2000),
    setting!("placeholders", "max_bytes", "materialize_max_bytes", Kind::Int, 20u64 * 1024 * 1024 * 1024),
    setting!("placeholders", "timeout_seconds", "materialize_timeout_seconds", Kind::Float, 120.0),
    setting!("quality", "max_chunks_per_document", "max_chunks_per_document", Kind::Int, 1500),
    setting!("quality", "reject_machine_generated", "reject_machine_generated", Kind::Bool, true),
    setting!("extraction", "max_file_bytes", "max_file_bytes", Kind::Int, 64 * 1024 * 1024),
    setting!("extraction", "pdf_min_chars_per_page", "pdf_min_chars_per_page", Kind::Int, 32),
    setting!("extraction", "ocr_min_chars", "ocr_min_chars", Kind::Int, 16),
    setting!("extraction", "index_images", "index_images", Kind::Bool, true),
    setting!("extraction", "plugins", "extraction_plugins", Kind::StrList, Value::Array(Vec::new())),
    setting!("mcp", "host", "mcp_host", Kind::Str, "127.0.0.1"),
    setting!("mcp", "port", "mcp_port", Kind::Int, 8787),
    setting!("mcp", "path", "mcp_http_path", Kind::Str, "/mcp"),
    setting!("facts", "model", "fact_model", Kind::Str, "gemma2-2b"),
    setting!("facts", "provider", "fact_provider", Kind::Choice(PROVIDERS), "llama_xpc"),
    setting!("facts", "prompts", "fact_prompts", Kind::Prompts, Value::Array(Vec::new())),
    setting!("facts", "cluster_threshold", "fact_cluster_threshold", Kind::Float, 0.9),
    setting!("facts", "cluster_restate_threshold", "fact_cluster_restate_threshold", Kind::Float, 0.92),
    setting!("facts", "cluster_neighbors", "fact_cluster_neighbors", Kind::Int, 10),
    setting!("facts", "cluster_seed_threshold", "fact_cluster_seed_threshold", Kind::Float, 0.95),
    setting!("facts", "cluster_max_drift", "fact_cluster_max_drift", Kind::Float, 0.05),
    setting!("facts", "cluster_tight_similarity", "fact_cluster_tight_similarity", Kind::Float, 0.97),
    setting!("facts", "cluster_growth_neighbors", "fact_cluster_growth_neighbors", Kind::Int, 50),
    setting!("facts", "cluster_growth_rounds", "fact_cluster_growth_rounds", Kind::Int, 4),
    setting!("facts", "cluster_attach_candidates", "fact_cluster_attach_candidates", Kind::Int, 5),
    setting!("facts", "cluster_distill_facts", "fact_cluster_distill_facts", Kind::Int, 20),
    setting!("facts", "cluster_max_pairwise", "fact_cluster_max_pairwise", Kind::Int, 300),
    setting!("inference", "model", "inference_model", Kind::Str, ""),
    setting!("inference", "provider", "inference_provider", Kind::Choice(INFERENCE_PROVIDERS), ""),
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

    /// Sets a flat field in memory, as a test does; nothing is written.
    pub fn set_field(&mut self, field: &str, value: Value) {
        self.values.insert(field.to_owned(), value);
    }

    /// The effective value of the field `field` (its default when the file did not set it).
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

    /// `mcp.host`, `mcp.port`, `mcp.path`.
    pub fn mcp_endpoint(&self) -> (String, i64, String) {
        (self.text("mcp_host"), self.integer("mcp_port"), self.text("mcp_http_path"))
    }

    /// The `sources` list as [`SourceSpec`]s (`Settings.sources`).
    ///
    /// # Errors
    ///
    /// An entry that is not a source (`SourceSpec`'s validation).
    pub fn source_specs(&self) -> Result<Vec<SourceSpec>> {
        self.sources.iter().map(SourceSpec::from_value).collect()
    }

    /// The file as it would be saved: the nested layout with every section at its full set of
    /// keys (`nest(settings)`).
    pub fn nest(&self) -> Value {
        nest(&self.values, &self.sources)
    }
}

/// A source declared in the config file (`SourceSpec`). Declared sources are authoritative:
/// Sync re-applies them; sources only in the database are left alone.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SourceSpec {
    pub slug: String,
    pub root: String,
    pub kind: String,
    pub corpus_class: String,
    pub trust: String,
    pub include_code: bool,
    pub enabled: bool,
}

const SOURCE_KEYS: [&str; 7] = ["slug", "root", "kind", "class", "trust", "include_code", "enabled"];

impl SourceSpec {
    /// A spec with the defaults (`filesystem`, `document`, `authored`, no code, enabled).
    pub fn new(slug: &str, root: &str) -> Self {
        Self {
            slug: slug.to_owned(),
            root: root.to_owned(),
            kind: "filesystem".to_owned(),
            corpus_class: "document".to_owned(),
            trust: "authored".to_owned(),
            include_code: false,
            enabled: true,
        }
    }

    /// One `sources[]` entry as written; retired keys are dropped with a warning, anything else
    /// unknown is an error (`extra = "forbid"`).
    ///
    /// # Errors
    ///
    /// Not an object, a missing `slug` or `root`, an unknown key, or a field of the wrong type.
    pub fn from_value(value: &Value) -> Result<Self> {
        let Value::Object(map) = value else {
            return Err(ServiceError::invalid("sources[]: each source must be an object"));
        };
        let text = |key: &str| -> Result<Option<String>> {
            match map.get(key) {
                None => Ok(None),
                Some(Value::String(s)) => Ok(Some(s.clone())),
                Some(_) => Err(ServiceError::invalid(format!("sources[].{key}: expected a string"))),
            }
        };
        let flag = |key: &str, default: bool| -> Result<bool> {
            match map.get(key) {
                None => Ok(default),
                Some(Value::Bool(b)) => Ok(*b),
                Some(_) => Err(ServiceError::invalid(format!("sources[].{key}: expected true or false"))),
            }
        };
        for key in map.keys() {
            if retired("sources").contains(&key.as_str()) {
                eprintln!("config: sources[].{key} is no longer a setting and was ignored; remove it");
            } else if !SOURCE_KEYS.contains(&key.as_str()) {
                return Err(ServiceError::invalid(format!(
                    "sources[]: unknown key {key:?}; expected one of: {}",
                    SOURCE_KEYS.join(", ")
                )));
            }
        }
        let slug = text("slug")?.ok_or_else(|| ServiceError::invalid("sources[]: slug is required"))?;
        let root = text("root")?.ok_or_else(|| ServiceError::invalid(format!("sources[{slug}]: root is required")))?;
        let mut spec = Self::new(&slug, &root);
        if let Some(kind) = text("kind")? {
            spec.kind = kind;
        }
        if let Some(class) = text("class")? {
            spec.corpus_class = class;
        }
        if let Some(trust) = text("trust")? {
            spec.trust = trust;
        }
        spec.include_code = flag("include_code", false)?;
        spec.enabled = flag("enabled", true)?;
        Ok(spec)
    }

    /// The entry as the file holds it (`model_dump(by_alias=True)`), every field written.
    pub fn to_value(&self) -> Value {
        json!({
            "slug": self.slug,
            "root": self.root,
            "kind": self.kind,
            "class": self.corpus_class,
            "trust": self.trust,
            "include_code": self.include_code,
            "enabled": self.enabled,
        })
    }

    /// `root` with a leading `~` expanded.
    pub fn expanded_root(&self) -> PathBuf {
        expand_home(Path::new(&self.root))
    }
}

/// `https://garagerag.app/.data/garage.schema.json`, written into every config's `$schema` so an
/// editor validates it with nothing else installed.
pub const SCHEMA_URL: &str = "https://garagerag.app/.data/garage.schema.json";

/// Flat values -> the nested file layout (`nest` with `include_defaults=True`): `$schema` first,
/// every section with all of its keys, `facts.prompts` left out when empty, then `sources`.
pub fn nest(values: &Map<String, Value>, sources: &[Value]) -> Value {
    let mut document = Map::new();
    document.insert("$schema".to_owned(), Value::String(SCHEMA_URL.to_owned()));
    for section in sections() {
        let mut body = Map::new();
        for setting in SECTIONS.iter().filter(|s| s.section == section) {
            let value = values.get(setting.field).cloned().unwrap_or_else(|| setting.default_value());
            if setting.kind == Kind::Prompts && value.as_array().is_none_or(Vec::is_empty) {
                continue;
            }
            body.insert(setting.key.to_owned(), value);
        }
        if !body.is_empty() {
            document.insert(section.to_owned(), Value::Object(body));
        }
    }
    if !sources.is_empty() {
        document.insert("sources".to_owned(), Value::Array(sources.to_vec()));
    }
    Value::Object(document)
}

/// The nested JSON document at `path`, or an empty one when the file does not exist
/// (`read_config_document`). No environment override is applied, so what is written back is
/// what the file already said plus the change.
///
/// # Errors
///
/// A file that cannot be read or is not a JSON object.
pub fn read_config_document(path: &Path) -> Result<Map<String, Value>> {
    let path = expand_home(path);
    if !path.is_file() {
        return Ok(Map::new());
    }
    let text = std::fs::read_to_string(&path)
        .map_err(|e| ServiceError::invalid(format!("cannot read {}: {e}", path.display())))?;
    let raw: Value = serde_json::from_str(&text)
        .map_err(|e| ServiceError::invalid(format!("{} is not valid JSON: {e}", path.display())))?;
    match raw {
        Value::Object(map) => Ok(map),
        _ => Err(ServiceError::invalid(format!("{} must contain a JSON object", path.display()))),
    }
}

/// The config file at `path` as a [`Config`] with no environment applied: what a write starts
/// from (`Settings(**flatten(read_config_document(path)))`).
///
/// # Errors
///
/// A malformed file.
pub fn read_config_file(path: &Path) -> Result<Config> {
    let mut config = flatten(&read_config_document(path)?)?;
    validate(&mut config.values, "config")?;
    config.path = Some(expand_home(path));
    Ok(config)
}

/// Writes `document` to `path` atomically (`save_config`): the JSON with two-space indentation
/// and a trailing newline, through a `.tmp` beside it.
///
/// # Errors
///
/// The file system.
pub fn save_document(document: &Value, path: &Path) -> Result<()> {
    let path = expand_home(path);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| ServiceError::failed(format!("cannot create {}: {e}", parent.display())))?;
    }
    let mut payload = serde_json::to_string_pretty(document).map_err(ServiceError::from)?;
    payload.push('\n');
    let temp = temp_path(&path);
    std::fs::write(&temp, payload)
        .map_err(|e| ServiceError::failed(format!("cannot write {}: {e}", temp.display())))?;
    std::fs::rename(&temp, &path)
        .map_err(|e| ServiceError::failed(format!("cannot replace {}: {e}", path.display())))?;
    Ok(())
}

/// `<path>.tmp` (`path.with_suffix(path.suffix + ".tmp")`).
pub fn temp_path(path: &Path) -> PathBuf {
    let mut name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    name.push_str(".tmp");
    path.with_file_name(name)
}

/// Saves `config` (its values and sources) to `path` in the file layout (`save_config`).
///
/// # Errors
///
/// The file system.
pub fn save_config(config: &Config, path: &Path) -> Result<()> {
    save_document(&config.nest(), path)
}

const TRUE_WORDS: [&str; 4] = ["true", "yes", "on", "1"];
const FALSE_WORDS: [&str; 4] = ["false", "no", "off", "0"];

/// A command-line string as the value the setting's field holds (`coerce_setting`).
///
/// # Errors
///
/// Text that does not read as the field's type.
pub fn coerce_setting(setting: &Setting, raw: &str) -> Result<Value> {
    let text = raw.trim();
    let field = setting.field;
    let repr = garage_mcp::pyrepr::str_repr(raw);
    Ok(match setting.kind {
        Kind::Bool => {
            let lowered = text.to_lowercase();
            if TRUE_WORDS.contains(&lowered.as_str()) {
                Value::Bool(true)
            } else if FALSE_WORDS.contains(&lowered.as_str()) {
                Value::Bool(false)
            } else {
                return Err(ServiceError::invalid(format!(
                    "{field}: expected true/false, yes/no, on/off or 1/0, got {repr}"
                )));
            }
        }
        Kind::Int => Value::from(
            text.parse::<i64>()
                .map_err(|_| ServiceError::invalid(format!("{field}: expected an integer, got {repr}")))?,
        ),
        Kind::Float => {
            let number = text
                .parse::<f64>()
                .map_err(|_| ServiceError::invalid(format!("{field}: expected a number, got {repr}")))?;
            serde_json::Number::from_f64(number).map_or(Value::Null, Value::Number)
        }
        Kind::StrList => Value::Array(
            text.split(',')
                .map(str::trim)
                .filter(|item| !item.is_empty())
                .map(|item| Value::String(item.to_owned()))
                .collect(),
        ),
        Kind::Prompts => {
            if text.is_empty() {
                Value::Array(Vec::new())
            } else {
                serde_json::from_str(text).map_err(|e| {
                    ServiceError::invalid(format!("{field}: expected a JSON array of prompts, got invalid JSON: {e}"))
                })?
            }
        }
        Kind::OptStr if matches!(text.to_lowercase().as_str(), "" | "none" | "null") => Value::Null,
        Kind::Str | Kind::OptStr | Kind::Choice(_) => Value::String(raw.to_owned()),
    })
}

/// `postgresql+psycopg://...`, whatever Postgres scheme the URL came with
/// (`ensure_psycopg_database_url`).
pub fn ensure_psycopg_database_url(url: &str) -> String {
    let trimmed = url.trim();
    if trimmed.is_empty() || trimmed.starts_with("postgresql+psycopg://") {
        return trimmed.to_owned();
    }
    match trimmed.split_once("://") {
        Some((scheme, rest)) if scheme.starts_with("postgres") => format!("postgresql+psycopg://{rest}"),
        _ => trimmed.to_owned(),
    }
}

/// What pydantic's `Settings` checked on every value (`field_validator`s and the field types):
/// each value has its field's type, the database URL is normalized, `llama_host` is loopback,
/// the choices are among theirs, and prompt names are unique with each non-built-in prompt
/// described. `context` prefixes the error as Python's `ConfigError` did (`"{name}: ..."`).
///
/// # Errors
///
/// [`ServiceError::InvalidArgument`] naming the field.
pub fn validate(values: &mut Map<String, Value>, context: &str) -> Result<()> {
    for setting in SECTIONS {
        let Some(value) = values.get_mut(setting.field) else { continue };
        let field = setting.field;
        let bad = |expected: &str| ServiceError::invalid(format!("{context}: {field}: expected {expected}"));
        match setting.kind {
            Kind::Str => {
                if !value.is_string() {
                    return Err(bad("a string"));
                }
            }
            Kind::OptStr => {
                if !(value.is_string() || value.is_null()) {
                    return Err(bad("a string or null"));
                }
            }
            Kind::Bool => {
                if !value.is_boolean() {
                    return Err(bad("true or false"));
                }
            }
            Kind::Int => {
                if value.as_i64().is_none() {
                    return Err(bad("an integer"));
                }
            }
            Kind::Float => {
                if value.as_f64().is_none() {
                    return Err(bad("a number"));
                }
            }
            Kind::StrList => {
                if !value.as_array().is_some_and(|items| items.iter().all(Value::is_string)) {
                    return Err(bad("a list of strings"));
                }
            }
            Kind::Prompts => validate_prompts(value).map_err(|e| ServiceError::invalid(format!("{context}: {e}")))?,
            Kind::Choice(choices) => {
                if !value.as_str().is_some_and(|s| choices.contains(&s)) {
                    let shown: Vec<String> = choices.iter().map(|c| garage_mcp::pyrepr::str_repr(c)).collect();
                    return Err(bad(&format!("one of {}", shown.join(", "))));
                }
            }
        }
        if field == "database_url"
            && let Value::String(url) = value
        {
            *url = ensure_psycopg_database_url(url);
        }
        if field == "llama_host" && !value.as_str().is_some_and(garage_embed::egress::is_loopback_url) {
            return Err(ServiceError::invalid(format!(
                "{context}: embedding.llama_host must be a loopback URL (localhost, 127.0.0.1 or ::1); got {}",
                garage_mcp::pyrepr::str_repr(value.as_str().unwrap_or_default())
            )));
        }
    }
    Ok(())
}

/// `validate_prompt_list` over the file's `facts.prompts`: the entries' shape, unique names, a prompt
/// that is not built in with its own text, and the graph schema (`crate::prompts`).
fn validate_prompts(value: &Value) -> std::result::Result<(), String> {
    crate::prompts::parse_prompts(value).map(|_| ()).map_err(|e| e.message().to_owned())
}

/// Sets `SECTION.KEY` to `raw_value` in the file at `path` and saves it (`update_config`): the
/// file is read (defaults when absent), the one value coerced and substituted, the whole
/// validated, and written back in the layout `config init` produces. The saved configuration
/// (with no environment applied) and the stored value.
///
/// # Errors
///
/// An unknown name, text that does not read as the field, a value the validation refuses, or
/// the file system.
pub fn update_config(path: &Path, name: &str, raw_value: &str) -> Result<(Config, Value)> {
    let setting = resolve_setting(name)?;
    let value = coerce_setting(setting, raw_value)?;
    let mut config = flatten(&read_config_document(path)?)?;
    config.values.insert(setting.field.to_owned(), value);
    validate(&mut config.values, name)?;
    save_config(&config, path)?;
    config.path = Some(expand_home(path));
    let stored = config.field(setting.field);
    Ok((config, stored))
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

/// `~` and `~/...` as the account's home folder (`expand_home`); anything else unchanged. In a
/// sandboxed process (the App Store build's XPC services) `$HOME` is the container, so the folder
/// comes from the account record, as the ingest crate reads it.
pub fn expand_home(path: &Path) -> PathBuf {
    garage_ingest::walk::expand_home(path)
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

    #[test]
    fn command_line_text_is_coerced_by_field_type() {
        let coerce = |name: &str, raw: &str| coerce_setting(resolve_setting(name).unwrap(), raw);
        assert_eq!(coerce("extraction.index_images", " Yes ").unwrap(), json!(true));
        assert_eq!(coerce("extraction.index_images", "0").unwrap(), json!(false));
        assert!(coerce("extraction.index_images", "maybe").unwrap_err().message().contains("expected true/false"));
        assert_eq!(coerce("mcp.port", "8790").unwrap(), json!(8790));
        assert!(coerce("mcp.port", "x").unwrap_err().message().starts_with("mcp_port: expected an integer, got 'x'"));
        assert_eq!(coerce("facts.cluster_threshold", "0.5").unwrap(), json!(0.5));
        assert_eq!(coerce("identity.identities", "a:b, c:d,,").unwrap(), json!(["a:b", "c:d"]));
        assert_eq!(coerce("identity.identities", "").unwrap(), json!([]));
        assert_eq!(coerce("embedding.lmstudio_api_token_file", "none").unwrap(), Value::Null);
        assert_eq!(coerce("embedding.lmstudio_api_token_file", "~/t").unwrap(), json!("~/t"));
        assert_eq!(coerce("facts.prompts", "").unwrap(), json!([]));
        assert!(coerce("facts.prompts", "[").unwrap_err().message().contains("JSON array of prompts"));
        assert_eq!(coerce("facts.provider", "ollama").unwrap(), json!("ollama"));
    }

    #[test]
    fn values_are_validated_as_pydantic_did() {
        let check = |field: &str, value: Value| {
            let mut values = Map::new();
            values.insert(field.to_owned(), value);
            validate(&mut values, "t").map(|()| values.remove(field).unwrap())
        };
        assert_eq!(check("database_url", json!("postgres://u@h/db")).unwrap(), json!("postgresql+psycopg://u@h/db"));
        assert_eq!(check("llama_host", json!("http://[::1]:8790")).unwrap(), json!("http://[::1]:8790"));
        assert!(
            check("llama_host", json!("http://gpu:8790")).unwrap_err().message().contains("must be a loopback URL")
        );
        assert!(
            check("fact_provider", json!("openai"))
                .unwrap_err()
                .message()
                .contains("'llama_xpc', 'ollama', 'lmstudio'")
        );
        assert!(check("inference_provider", json!("")).is_ok());
        assert!(check("mcp_port", json!("8787")).unwrap_err().message().ends_with("mcp_port: expected an integer"));
        assert!(check("fact_prompts", json!([{"name": "default", "enabled": false}])).is_ok());
        assert!(
            check("fact_prompts", json!([{"name": "default"}, {"name": "default"}]))
                .unwrap_err()
                .message()
                .contains("used twice")
        );
        assert!(
            check("fact_prompts", json!([{"name": "mine"}]))
                .unwrap_err()
                .message()
                .contains("needs description and examples")
        );
        assert!(
            check("fact_prompts", json!([{"name": "mine", "description": "d", "examples": [{"text": "t"}]}])).is_ok()
        );
        assert_eq!(
            check("fact_prompts", json!([{"name": "mine", "description": "d", "examples": []}])).unwrap_err().message(),
            "t: facts.prompts: 'mine': examples must not be empty; LangExtract needs at least one"
        );
    }

    #[test]
    fn settings_are_written_in_the_file_layout() {
        let dir = std::env::temp_dir().join(format!("garage-config-{}", std::process::id()));
        let path = dir.join("nested").join("garage.json");
        let _ = std::fs::remove_dir_all(&dir);
        let (config, stored) = update_config(&path, "embedding.ollama_host", "http://gpu:11434").unwrap();
        assert_eq!(stored, json!("http://gpu:11434"));
        assert_eq!(config.path.as_deref(), Some(path.as_path()));
        let text = std::fs::read_to_string(&path).unwrap();
        assert!(
            text.starts_with(
                "{\n  \"$schema\": \"https://garagerag.app/.data/garage.schema.json\",\n  \"database\": {"
            )
        );
        assert!(text.ends_with("}\n"));
        let document: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(document["embedding"]["ollama_host"], json!("http://gpu:11434"));
        assert_eq!(document["embedding"]["batch_size"], json!(64));
        assert_eq!(document["facts"].get("prompts"), None);
        assert_eq!(document.get("sources"), None);
        let (_, stored) = update_config(&path, "facts.provider", "ollama").unwrap();
        assert_eq!(stored, json!("ollama"));
        let reloaded = Config::load(Some(&path)).unwrap();
        assert_eq!(reloaded.setting("embedding.ollama_host").unwrap(), json!("http://gpu:11434"));
        assert_eq!(reloaded.setting("facts.provider").unwrap(), json!("ollama"));
        assert!(update_config(&path, "facts.provider", "cloud").unwrap_err().message().starts_with("facts.provider: "));
        assert_eq!(Config::load(Some(&path)).unwrap().setting("facts.provider").unwrap(), json!("ollama"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn source_specs_round_trip() {
        let spec = SourceSpec::from_value(
            &json!({"slug": "notes", "root": "~/Notes", "class": "code", "allow_cloud_enrichment": true}),
        )
        .unwrap();
        assert_eq!(
            (spec.kind.as_str(), spec.corpus_class.as_str(), spec.trust.as_str()),
            ("filesystem", "code", "authored")
        );
        assert!(spec.enabled && !spec.include_code);
        assert_eq!(
            spec.to_value(),
            json!({"slug": "notes", "root": "~/Notes", "kind": "filesystem", "class": "code", "trust": "authored",
                   "include_code": false, "enabled": true})
        );
        assert!(SourceSpec::from_value(&json!({"slug": "x"})).unwrap_err().message().contains("root is required"));
        assert!(
            SourceSpec::from_value(&json!({"slug": "x", "root": "/", "colour": 1}))
                .unwrap_err()
                .message()
                .contains("unknown key")
        );
        assert_eq!(ensure_psycopg_database_url("postgresql+psycopg://a"), "postgresql+psycopg://a");
        assert_eq!(ensure_psycopg_database_url("mysql://a"), "mysql://a");
        assert_eq!(temp_path(Path::new("/x/garage.json")), PathBuf::from("/x/garage.json.tmp"));
    }
}

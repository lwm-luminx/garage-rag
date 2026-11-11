//! Registering, removing, syncing and reconciling sources (`garage_rag.ops.sources`,
//! `ingest.reconcile`): the operations behind `AddSource`, `RemoveSource`, `SyncSources`,
//! `ImportSourcesToConfig` and `Reconcile`, each answering with Python's message.

use std::path::{Path, PathBuf};

use serde_json::{Map, Value, json};

use crate::config::{Config, SourceSpec, expand_home, read_config_file, save_config};
use crate::db::Client;
use crate::error::{Result, ServiceError};
use crate::service::thousands;

pub const CORPUS_CLASSES: [&str; 3] = ["document", "code", "communication"];
pub const TRUST_TIERS: [&str; 3] = ["authored", "reference", "received"];

fn check_choice<'a>(value: &'a str, choices: &[&str], what: &str) -> Result<&'a str> {
    if choices.contains(&value) {
        Ok(value)
    } else {
        Err(ServiceError::invalid(format!(
            "{} is not a valid {what}; choose one of {}",
            garage_mcp::pyrepr::str_repr(value),
            choices.join(", ")
        )))
    }
}

/// `AddSource`'s outcome.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AddSourceResult {
    pub slug: String,
    pub root: PathBuf,
    pub corpus_class: String,
    pub trust: String,
    pub created: bool,
}

impl AddSourceResult {
    pub fn message(&self) -> String {
        if self.created {
            format!("added source {} -> {} ({}/{})", self.slug, self.root.display(), self.corpus_class, self.trust)
        } else {
            format!("updated source {} -> {}", self.slug, self.root.display())
        }
    }
}

/// Registers a source root, or updates the one already registered under `slug` (`add_source`).
/// A root the process may not look at (a sandboxed caller) is accepted; one that does not exist
/// is refused.
///
/// # Errors
///
/// An unknown class or tier, a missing root, or the server.
pub async fn add_source(
    client: &mut Client,
    slug: &str,
    root: &str,
    kind: &str,
    corpus_class: &str,
    trust: &str,
) -> Result<AddSourceResult> {
    check_choice(trust, &TRUST_TIERS, "TrustTier")?;
    check_choice(corpus_class, &CORPUS_CLASSES, "CorpusClass")?;
    let dropbox = kind == garage_ingest::dropbox::KIND;
    let expanded = if dropbox {
        // A folder in the Dropbox: whether it exists is Dropbox's to say, at the first ingest.
        std::path::PathBuf::from(garage_ingest::dropbox::display_root(root))
    } else {
        expand_home(Path::new(root))
    };
    if !dropbox
        && let Err(e) = std::fs::metadata(&expanded)
        && e.kind() != std::io::ErrorKind::PermissionDenied
    {
        return Err(ServiceError::invalid(format!("{} does not exist", expanded.display())));
    }
    let root_text = expanded.to_string_lossy().into_owned();
    let tx = client.transaction().await?;
    let existing = tx.query_opt("SELECT id FROM sources WHERE slug = $1", &[&slug]).await?;
    if existing.is_some() {
        tx.execute(
            "UPDATE sources SET root = $2, kind = $3, default_trust = CAST($4::text AS trust_tier), \
             default_class = CAST($5::text AS corpus_class) WHERE slug = $1",
            &[&slug, &root_text, &kind, &trust, &corpus_class],
        )
        .await?;
    } else {
        tx.execute(
            "INSERT INTO sources (slug, kind, root, default_trust, default_class) \
             VALUES ($1, $2, $3, CAST($4::text AS trust_tier), CAST($5::text AS corpus_class))",
            &[&slug, &kind, &root_text, &trust, &corpus_class],
        )
        .await?;
    }
    tx.commit().await?;
    Ok(AddSourceResult {
        slug: slug.to_owned(),
        root: expanded,
        corpus_class: corpus_class.to_owned(),
        trust: trust.to_owned(),
        created: existing.is_none(),
    })
}

/// `RemoveSource`'s outcome.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RemoveSourceResult {
    pub slug: String,
    pub deleted_documents: i64,
    /// The config file the source was also dropped from, when it was declared there.
    pub config_path: Option<PathBuf>,
    /// Why the config file could not be updated, when it could not.
    pub config_error: Option<String>,
}

impl RemoveSourceResult {
    pub fn message(&self) -> String {
        let mut text = format!("removed {} ({} documents)", self.slug, thousands(self.deleted_documents));
        if let Some(path) = &self.config_path {
            let _ = std::fmt::Write::write_fmt(&mut text, format_args!(" and dropped it from {}", path.display()));
        }
        if let Some(error) = &self.config_error {
            text.push_str("; ");
            text.push_str(error);
        }
        text
    }
}

/// Deregisters a source; its documents, chunks and vectors cascade away with it, and the config
/// file in use (`config_path`) forgets it too, since Sync would otherwise bring it back
/// (`remove_source`).
///
/// # Errors
///
/// [`ServiceError::NotFound`] when neither the database nor the file knows the slug; the file's
/// error when the database had no such source and the file could not be read.
pub async fn remove_source(client: &mut Client, config_path: Option<&Path>, slug: &str) -> Result<RemoveSourceResult> {
    let tx = client.transaction().await?;
    let source = tx.query_opt("SELECT id FROM sources WHERE slug = $1", &[&slug]).await?;
    let mut count = 0i64;
    if let Some(row) = &source {
        let id: i64 = row.get(0);
        count = tx.query_one("SELECT count(*) FROM documents WHERE source_id = $1", &[&id]).await?.get(0);
        tx.execute("DELETE FROM sources WHERE id = $1", &[&id]).await?;
    }
    tx.commit().await?;
    let dropped = match config_path {
        Some(path) => drop_from_config(path, slug),
        None => Ok(None),
    };
    match dropped {
        Ok(None) if source.is_none() => Err(ServiceError::not_found(format!("no such source: {slug}"))),
        Ok(config_path) => {
            Ok(RemoveSourceResult { slug: slug.to_owned(), deleted_documents: count, config_path, config_error: None })
        }
        Err(e) if source.is_none() => Err(e),
        Err(e) => Ok(RemoveSourceResult {
            slug: slug.to_owned(),
            deleted_documents: count,
            config_path: None,
            config_error: Some(format!("it is still declared in the config file, so Sync will add it again: {e}")),
        }),
    }
}

/// Removes `slug` from the file's sources; the file's path when it was declared there
/// (`_drop_from_config`). The file is rebuilt from what it already says.
///
/// # Errors
///
/// A malformed file, or the file system.
pub fn drop_from_config(path: &Path, slug: &str) -> Result<Option<PathBuf>> {
    let path = expand_home(path);
    let mut config = read_config_file(&path)?;
    let specs = config.source_specs()?;
    let kept: Vec<Value> = specs.iter().filter(|s| s.slug != slug).map(SourceSpec::to_value).collect();
    if kept.len() == specs.len() {
        return Ok(None);
    }
    config.sources = kept;
    save_config(&config, &path)?;
    Ok(Some(path))
}

/// `SyncSources`'s outcome.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SyncResult {
    pub config_path: Option<PathBuf>,
    pub declared: usize,
    pub applied: bool,
    pub created: Vec<String>,
    pub updated: Vec<String>,
    pub undeclared: Vec<(String, i64)>,
}

impl SyncResult {
    /// The report, line by line (`SyncResult.lines`).
    pub fn lines(&self) -> Vec<String> {
        if self.declared == 0 {
            let shown =
                self.config_path.as_ref().map_or_else(|| "the config file".to_owned(), |p| p.display().to_string());
            return vec![format!("no sources declared in {shown}")];
        }
        let verb = if self.applied { "" } else { "would " };
        let mut out = Vec::new();
        if !self.created.is_empty() {
            out.push(format!("{verb}create: {}", self.created.join(", ")));
        }
        if !self.updated.is_empty() {
            out.push(format!("{verb}update: {}", self.updated.join(", ")));
        }
        if self.created.is_empty() && self.updated.is_empty() {
            out.push("database already matches the config".to_owned());
        }
        if !self.undeclared.is_empty() {
            out.push("in the database but not declared (left untouched):".to_owned());
            out.extend(
                self.undeclared.iter().map(|(slug, count)| format!("  {slug} ({} documents)", thousands(*count))),
            );
        }
        out
    }
}

/// Applies the sources the config file declares to the database (`sync_sources`). Declared
/// sources win: each is created or updated to match the file. Sources only in the database are
/// reported, never deleted.
///
/// # Errors
///
/// A malformed source, an unknown class or tier, or the server.
pub async fn sync_sources(client: &mut Client, config: &Config, apply: bool) -> Result<SyncResult> {
    let specs = config.source_specs()?;
    let mut result =
        SyncResult { config_path: config.path.clone(), declared: specs.len(), applied: apply, ..Default::default() };
    if specs.is_empty() {
        return Ok(result);
    }
    let tx = client.transaction().await?;
    for spec in &specs {
        check_choice(&spec.corpus_class, &CORPUS_CLASSES, "CorpusClass")?;
        check_choice(&spec.trust, &TRUST_TIERS, "TrustTier")?;
        let root = spec.expanded_root().to_string_lossy().into_owned();
        let row = tx
            .query_opt(
                "SELECT kind, root, default_class::text, default_trust::text, enabled, config FROM sources WHERE slug = $1",
                &[&spec.slug],
            )
            .await?;
        let Some(row) = row else {
            if apply {
                tx.execute(
                    "INSERT INTO sources (slug, kind, root, default_class, default_trust, enabled, config) \
                     VALUES ($1, $2, $3, CAST($4::text AS corpus_class), CAST($5::text AS trust_tier), $6, CAST($7::text AS jsonb))",
                    &[
                        &spec.slug,
                        &spec.kind,
                        &root,
                        &spec.corpus_class,
                        &spec.trust,
                        &spec.enabled,
                        &json!({"include_code": spec.include_code}).to_string(),
                    ],
                )
                .await?;
            }
            result.created.push(spec.slug.clone());
            continue;
        };
        let stored_config: Value = row.get(5);
        let include_code = stored_config.get("include_code").and_then(Value::as_bool).unwrap_or(false);
        let changed = row.get::<_, String>(0) != spec.kind
            || row.get::<_, String>(1) != root
            || row.get::<_, String>(2) != spec.corpus_class
            || row.get::<_, String>(3) != spec.trust
            || row.get::<_, bool>(4) != spec.enabled
            || include_code != spec.include_code;
        if changed {
            if apply {
                let mut merged = match stored_config {
                    Value::Object(map) => map,
                    _ => Map::new(),
                };
                merged.insert("include_code".to_owned(), Value::Bool(spec.include_code));
                tx.execute(
                    "UPDATE sources SET kind = $2, root = $3, default_class = CAST($4::text AS corpus_class), \
                     default_trust = CAST($5::text AS trust_tier), enabled = $6, config = CAST($7::text AS jsonb) WHERE slug = $1",
                    &[
                        &spec.slug,
                        &spec.kind,
                        &root,
                        &spec.corpus_class,
                        &spec.trust,
                        &spec.enabled,
                        &Value::Object(merged).to_string(),
                    ],
                )
                .await?;
            }
            result.updated.push(spec.slug.clone());
        }
    }
    let rows = tx
        .query(
            "SELECT s.slug, count(d.id) FROM sources s LEFT JOIN documents d ON d.source_id = s.id GROUP BY s.slug ORDER BY s.slug",
            &[],
        )
        .await?;
    tx.commit().await?;
    result.undeclared = rows
        .iter()
        .map(|r| (r.get::<_, String>(0), r.get::<_, i64>(1)))
        .filter(|(slug, _)| !specs.iter().any(|s| &s.slug == slug))
        .collect();
    Ok(result)
}

/// `ImportSourcesToConfig`'s outcome.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ImportSourcesResult {
    pub path: PathBuf,
    pub added: Vec<String>,
}

impl ImportSourcesResult {
    pub fn message(&self) -> String {
        if self.added.is_empty() {
            "config already lists every database source".to_owned()
        } else {
            format!("added {} sources to {}: {}", self.added.len(), self.path.display(), self.added.join(", "))
        }
    }
}

/// Copies the database's sources into the config file at `target`, so it becomes the source of
/// truth (`import_sources_into_config`). The file is rebuilt from what it already says.
///
/// # Errors
///
/// A malformed file, the file system, or the server.
pub async fn import_sources(client: &Client, target: &Path) -> Result<ImportSourcesResult> {
    let target = expand_home(target);
    let mut config = read_config_file(&target)?;
    let mut specs = config.source_specs()?;
    let rows = client
        .query(
            "SELECT slug, root, kind, default_class::text, default_trust::text, config, enabled FROM sources ORDER BY slug",
            &[],
        )
        .await?;
    let mut added = Vec::new();
    for row in &rows {
        let slug: String = row.get(0);
        if specs.iter().any(|s| s.slug == slug) {
            continue;
        }
        let stored: Value = row.get(5);
        specs.push(SourceSpec {
            slug: slug.clone(),
            root: row.get(1),
            kind: row.get(2),
            corpus_class: row.get(3),
            trust: row.get(4),
            include_code: stored.get("include_code").and_then(Value::as_bool).unwrap_or(false),
            enabled: row.get(6),
        });
        added.push(slug);
    }
    if !added.is_empty() {
        config.sources = specs.iter().map(SourceSpec::to_value).collect();
        save_config(&config, &target)?;
    }
    Ok(ImportSourcesResult { path: target, added })
}

/// Refuse to delete more than this share of a source without `force`.
pub const DEFAULT_MAX_DELETE_FRACTION: f64 = 0.25;

/// `Reconcile`'s outcome (`ReconcileResult`).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ReconcileResult {
    pub source: String,
    pub candidates: i64,
    pub deleted: i64,
    pub total_documents: i64,
    pub refused: bool,
    pub reason: String,
}

impl ReconcileResult {
    #[allow(clippy::cast_precision_loss)] // document counts
    pub fn fraction(&self) -> f64 {
        if self.total_documents == 0 { 0.0 } else { self.candidates as f64 / self.total_documents as f64 }
    }

    /// The handler's message for the outcome.
    pub fn message(&self, apply: bool) -> String {
        if self.refused {
            format!("refused: {}", self.reason)
        } else if self.candidates == 0 {
            format!("nothing to reconcile for {}", self.source)
        } else if apply {
            format!(
                "deleted {} of {} documents from {}",
                thousands(self.deleted),
                thousands(self.total_documents),
                self.source
            )
        } else {
            format!(
                "dry run: {} of {} documents in {} are missing ({:.1}%)",
                thousands(self.candidates),
                thousands(self.total_documents),
                self.source,
                self.fraction() * 100.0
            )
        }
    }
}

/// Deletes (or, dry, counts) the documents of `slug` absent from its latest complete ingest run
/// (`reconcile_source`). Only a run that walked to exhaustion counts, and more than
/// `max_delete_fraction` of the source is refused without `force`.
///
/// # Errors
///
/// [`ServiceError::NotFound`] for an unknown slug, or the server.
pub async fn reconcile_source(
    client: &mut Client,
    slug: &str,
    dry_run: bool,
    force: bool,
    max_delete_fraction: f64,
) -> Result<ReconcileResult> {
    let tx = client.transaction().await?;
    let source = tx
        .query_opt("SELECT id FROM sources WHERE slug = $1", &[&slug])
        .await?
        .ok_or_else(|| ServiceError::not_found(format!("no such source: {slug}")))?;
    let source_id: i64 = source.get(0);
    let mut result = ReconcileResult { source: slug.to_owned(), ..Default::default() };
    let run = tx
        .query_opt(
            "SELECT id FROM ingest_runs WHERE source_id = $1 AND completed ORDER BY started_at DESC LIMIT 1",
            &[&source_id],
        )
        .await?;
    let Some(run) = run else {
        result.refused = true;
        "no completed scan on record; run a full `garage ingest` (without --limit) before reconciling"
            .clone_into(&mut result.reason);
        return Ok(result);
    };
    let run_id: i64 = run.get(0);
    result.total_documents =
        tx.query_one("SELECT count(*) FROM documents WHERE source_id = $1", &[&source_id]).await?.get(0);
    let ids: Vec<i64> = tx
        .query(
            "SELECT d.id FROM documents d WHERE d.source_id = $1 AND NOT EXISTS \
             (SELECT 1 FROM ingest_seen s WHERE s.run_id = $2 AND s.uri = d.uri)",
            &[&source_id, &run_id],
        )
        .await?
        .iter()
        .map(|r| r.get(0))
        .collect();
    result.candidates = i64::try_from(ids.len()).unwrap_or(i64::MAX);
    if ids.is_empty() {
        return Ok(result);
    }
    if !force && result.fraction() > max_delete_fraction {
        result.refused = true;
        result.reason = format!(
            "would delete {} of {} documents ({:.0}% > {:.0}%); if the source really shrank that much, re-run with --force",
            thousands(result.candidates),
            thousands(result.total_documents),
            result.fraction() * 100.0,
            max_delete_fraction * 100.0
        );
        return Ok(result);
    }
    if dry_run {
        return Ok(result);
    }
    // Cascades through chunks into every per-model embedding table.
    tx.execute("DELETE FROM documents WHERE id = ANY($1)", &[&ids]).await?;
    tx.commit().await?;
    result.deleted = result.candidates;
    Ok(result)
}

/// The sources a scan covers (`scan_sources`' query): `*` or empty is every enabled source; a
/// slug names one, enabled or not. `(slug, kind, root)` each.
///
/// # Errors
///
/// [`ServiceError::NotFound`] for an unknown slug, or the server.
pub async fn scan_targets(client: &Client, source: &str) -> Result<Vec<(String, String, PathBuf)>> {
    let rows = if source.is_empty() || source == "*" {
        client.query("SELECT slug, kind, root FROM sources WHERE enabled ORDER BY id", &[]).await?
    } else {
        let rows = client.query("SELECT slug, kind, root FROM sources WHERE slug = $1", &[&source]).await?;
        if rows.is_empty() {
            return Err(ServiceError::not_found(format!("no such source: {source}")));
        }
        rows
    };
    Ok(rows.iter().map(|r| (r.get(0), r.get(1), PathBuf::from(r.get::<_, String>(2)))).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn messages_match_python() {
        let result =
            ReconcileResult { source: "notes".into(), candidates: 3, total_documents: 8, ..Default::default() };
        assert_eq!(result.message(false), "dry run: 3 of 8 documents in notes are missing (37.5%)");
        assert_eq!(
            ReconcileResult { source: "n".into(), ..Default::default() }.message(true),
            "nothing to reconcile for n"
        );
        let sync = SyncResult { declared: 0, ..Default::default() };
        assert_eq!(sync.lines(), vec!["no sources declared in the config file"]);
        let sync = SyncResult {
            declared: 2,
            applied: false,
            created: vec!["a".into()],
            undeclared: vec![("old".into(), 1234)],
            ..Default::default()
        };
        assert_eq!(
            sync.lines(),
            vec!["would create: a", "in the database but not declared (left untouched):", "  old (1,234 documents)"]
        );
        assert!(
            check_choice("secret", &TRUST_TIERS, "TrustTier")
                .unwrap_err()
                .message()
                .contains("'secret' is not a valid TrustTier")
        );
    }

    #[test]
    fn sources_are_dropped_from_the_file() {
        let dir = std::env::temp_dir().join(format!("garage-sources-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("garage.json");
        std::fs::write(&path, r#"{"sources": [{"slug": "a", "root": "/a"}, {"slug": "b", "root": "/b"}]}"#).unwrap();
        assert_eq!(drop_from_config(&path, "zzz").unwrap(), None);
        assert_eq!(drop_from_config(&path, "a").unwrap(), Some(path.clone()));
        let document: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(document["sources"].as_array().unwrap().len(), 1);
        assert_eq!(document["sources"][0]["slug"], json!("b"));
        assert_eq!(document["sources"][0]["kind"], json!("filesystem"));
        let _ = std::fs::remove_dir_all(&dir);
    }
}

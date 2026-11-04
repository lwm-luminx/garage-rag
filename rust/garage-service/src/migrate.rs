//! Applying `data/sql` (`garage_rag.db.migrate`).
//!
//! The files are idempotent (`IF NOT EXISTS`, `duplicate_object` guards), so applying them again is
//! the migration story. The extension file (001) goes first on its own, the rest in lexical order,
//! and each is recorded in `schema_migrations`.

use std::path::{Path, PathBuf};

use crate::db::Client;
use crate::error::{Result, ServiceError};

/// Where the SQL is when a caller names no folder: `GARAGE_SQL_DIR`, else a `data/sql` beside the
/// program or above the working directory, else the repository this crate was built from.
pub fn default_sql_dir() -> PathBuf {
    if let Some(dir) = std::env::var_os("GARAGE_SQL_DIR") {
        return PathBuf::from(dir);
    }
    let mut starts: Vec<PathBuf> = Vec::new();
    if let Ok(exe) = std::env::current_exe() {
        starts.push(exe);
    }
    if let Ok(cwd) = std::env::current_dir() {
        starts.push(cwd);
    }
    for start in starts {
        for ancestor in start.ancestors() {
            let candidate = ancestor.join("data").join("sql");
            if candidate.is_dir() {
                return candidate;
            }
        }
    }
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../data/sql")
}

/// The numbered SQL files of `dir`, in lexical (so numeric) order (`migration_files`).
///
/// # Errors
///
/// [`ServiceError::Failed`] when `dir` is not a folder: with no DDL, nothing can be judged ready.
pub fn migration_files(dir: &Path) -> Result<Vec<PathBuf>> {
    let entries = std::fs::read_dir(dir)
        .map_err(|_| ServiceError::failed(format!("SQL directory not found: {}", dir.display())))?;
    let mut files: Vec<PathBuf> = entries
        .filter_map(std::result::Result::ok)
        .map(|entry| entry.path())
        .filter(|path| {
            let name = path.file_name().and_then(|n| n.to_str()).unwrap_or_default();
            let digits =
                name.len() > 4 && name.as_bytes()[..3].iter().all(u8::is_ascii_digit) && name.as_bytes()[3] == b'_';
            digits && std::path::Path::new(name).extension().is_some_and(|ext| ext.eq_ignore_ascii_case("sql"))
        })
        .collect();
    files.sort();
    Ok(files)
}

fn file_name(path: &Path) -> String {
    path.file_name().and_then(|n| n.to_str()).unwrap_or_default().to_owned()
}

fn stem(path: &Path) -> String {
    path.file_stem().and_then(|n| n.to_str()).unwrap_or_default().to_owned()
}

/// Whether the file sets up extensions (001), which runs before everything else.
pub fn is_extension_migration(path: &Path) -> bool {
    let name = file_name(path).to_lowercase();
    name.contains("extension") || name.starts_with("001")
}

async fn record(client: &Client, version: &str) -> Result<()> {
    client
        .execute("INSERT INTO schema_migrations (version) VALUES ($1) ON CONFLICT (version) DO NOTHING", &[&version])
        .await?;
    Ok(())
}

/// Applies every migration file of `dir` (`apply_migrations`); the names applied, in order.
///
/// # Errors
///
/// A missing folder, an unreadable file or the server refusing one.
pub async fn apply_migrations(client: &Client, dir: &Path) -> Result<Vec<String>> {
    let files = migration_files(dir)?;
    client
        .batch_execute(
            "CREATE TABLE IF NOT EXISTS schema_migrations (version text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())",
        )
        .await?;
    let mut applied = Vec::new();
    let (extensions, rest): (Vec<&PathBuf>, Vec<&PathBuf>) = files.iter().partition(|f| is_extension_migration(f));
    if extensions.is_empty() {
        client.batch_execute("CREATE EXTENSION IF NOT EXISTS vector; CREATE EXTENSION IF NOT EXISTS pg_trgm;").await?;
        record(client, "001_extensions").await?;
        applied.push("default_extensions".to_owned());
    }
    for path in extensions.into_iter().chain(rest) {
        let sql = std::fs::read_to_string(path)
            .map_err(|e| ServiceError::failed(format!("cannot read {}: {e}", path.display())))?;
        client.batch_execute(&sql).await.map_err(|e| ServiceError::failed(format!("{}: {e}", file_name(path))))?;
        record(client, &stem(path)).await?;
        applied.push(file_name(path));
    }
    Ok(applied)
}

/// The migration files not yet recorded in `schema_migrations` (`pending_migrations`); every file
/// when the table is missing.
///
/// # Errors
///
/// A missing folder, or the server not answering.
pub async fn pending_migrations(client: &Client, dir: &Path) -> Result<Vec<PathBuf>> {
    let files = migration_files(dir)?;
    let exists: bool = client
        .query_one(
            "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'schema_migrations')",
            &[],
        )
        .await?
        .get(0);
    if !exists {
        return Ok(files);
    }
    let applied: Vec<String> =
        client.query("SELECT version FROM schema_migrations", &[]).await?.iter().map(|row| row.get(0)).collect();
    Ok(files.into_iter().filter(|f| !applied.contains(&stem(f)) && !applied.contains(&file_name(f))).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A folder of SQL files is read in name order, with 001 first. The repository's own `data/sql`
    /// is held to the same when it is reachable (a Cargo run; Bazel's sandbox has no checkout).
    #[test]
    fn migrations_are_found_and_ordered() {
        let dir = std::env::temp_dir().join(format!("garage-service-migrate-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        for name in ["003_core.sql", "001_extensions.sql", "010_facts.sql", "002_types.sql", "README.md"] {
            std::fs::write(dir.join(name), "SELECT 1;\n").unwrap();
        }
        let files = migration_files(&dir).unwrap();
        assert_eq!(
            files.iter().map(|f| file_name(f)).collect::<Vec<_>>(),
            ["001_extensions.sql", "002_types.sql", "003_core.sql", "010_facts.sql"]
        );
        assert!(is_extension_migration(&files[0]));
        assert!(!is_extension_migration(&files[1]));
        std::fs::remove_dir_all(&dir).unwrap();
        assert!(migration_files(Path::new("/nonexistent")).is_err());

        let repository = default_sql_dir();
        if repository.is_dir() {
            let files = migration_files(&repository).unwrap();
            assert!(files.len() >= 18, "{files:?}");
            assert!(is_extension_migration(&files[0]));
            assert!(files.windows(2).all(|pair| pair[0] < pair[1]));
        }
    }
}

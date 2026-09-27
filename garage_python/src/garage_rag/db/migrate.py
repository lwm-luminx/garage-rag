"""Schema application.

The SQL files are written to be idempotent (``IF NOT EXISTS`` plus
``duplicate_object`` guards for enum types), so applying them repeatedly is the
migration story. That is sufficient for a single-user local corpus and avoids a
migration framework; the day a destructive change is needed, a numbered file
that performs it explicitly is added.
"""

from __future__ import annotations

import logging
from pathlib import Path
from urllib.parse import quote, urlencode

from sqlalchemy import text
from sqlalchemy.engine import make_url
from sqlalchemy.orm import Session

from garage_rag.config import get_settings, repo_root

log = logging.getLogger(__name__)


def _connect(conninfo: str):
    """A direct autocommit connection (DDL, extension creation, reachability checks).

    psycopg is imported here rather than at module scope: it loads libpq on
    import, and modules that only reference the migration helpers (the gRPC
    service, status checks) must import without a database driver.
    """
    import psycopg

    return psycopg.connect(conninfo, autocommit=True)


def sql_dir() -> Path:
    """The committed DDL: ``data/sql/`` at the repository root."""
    return repo_root() / "data" / "sql"


def redact_url(url: str) -> str:
    """``url`` with its password hidden, for logs and terminal output.

    The app injects the Keychain password through ``GARAGE_DATABASE_URL``, so
    the raw URL must never be printed.
    """
    try:
        return make_url(url).render_as_string(hide_password=True)
    except Exception:
        # Not a URL SQLAlchemy understands (a libpq conninfo string, say); the
        # only safe thing to show is nothing.
        return "<database url>"


def to_psycopg_conninfo(url: str) -> str:
    """Convert an engine database URL (e.g. postgresql+psycopg://...) to psycopg conninfo/URL.

    The query is re-encoded with ``%20`` for spaces: SQLAlchemy writes ``+``,
    which libpq keeps literally, and the app's socket directory
    (``?host=.../Group Containers/...``) has a space in it.
    """
    try:
        parsed = make_url(url)
        if "+" in parsed.drivername:
            parsed = parsed.set(drivername=parsed.drivername.split("+")[0])
        rendered = parsed.set(query={}).render_as_string(hide_password=False)
        if not parsed.query:
            return rendered
        return f"{rendered}?{urlencode(parsed.query, doseq=True, quote_via=quote, safe='/')}"
    except Exception:
        if url.startswith("postgresql+"):
            prefix, rest = url.split("://", 1)
            base_driver = prefix.split("+")[0]
            return f"{base_driver}://{rest}"
        return url


def migration_files(schema_dir: Path | None = None) -> list[Path]:
    """Numbered SQL files, in lexical (therefore numeric) order."""
    directory = schema_dir if schema_dir is not None else sql_dir()
    if not directory.is_dir():
        raise FileNotFoundError(f"SQL directory not found: {directory}")
    return sorted(directory.glob("[0-9][0-9][0-9]_*.sql"))


def is_extension_migration(path: Path) -> bool:
    """Check if a migration file is for extensions / bootstrap (e.g. 001)."""
    name = path.name.lower()
    return "extension" in name or name.startswith("001")


def init_extensions(database_url: str | None = None, schema_dir: Path | None = None) -> list[str]:
    """Execute extension setup outside of SQLAlchemy on a direct raw connection."""
    raw_url = database_url or get_settings().database_url
    url = to_psycopg_conninfo(raw_url)
    applied: list[str] = []
    # A missing SQL directory is an installation problem and must surface as
    # one: silently creating the extensions and reporting success would leave
    # an empty database that later reports itself as ready.
    files = migration_files(schema_dir)
    extension_files = [f for f in files if is_extension_migration(f)]

    with _connect(url) as conn, conn.cursor() as cur:
        # Ensure schema_migrations table exists
        cur.execute(
            """
                CREATE TABLE IF NOT EXISTS schema_migrations (
                    version text PRIMARY KEY,
                    applied_at timestamptz NOT NULL DEFAULT now()
                );
                """
        )
        if extension_files:
            for path in extension_files:
                log.info("applying extension migration outside sqlalchemy: %s", path.name)
                cur.execute(path.read_text(encoding="utf-8"))
                cur.execute(
                    "INSERT INTO schema_migrations (version) VALUES (%s) ON CONFLICT (version) DO NOTHING;",
                    (path.stem,),
                )
                applied.append(path.name)
        else:
            log.info("creating default extensions outside sqlalchemy")
            cur.execute("CREATE EXTENSION IF NOT EXISTS vector;")
            cur.execute("CREATE EXTENSION IF NOT EXISTS pg_trgm;")
            cur.execute(
                "INSERT INTO schema_migrations (version) VALUES (%s) ON CONFLICT (version) DO NOTHING;",
                ("001_extensions",),
            )
            applied.append("default_extensions")
    return applied


def apply_migrations(
    session: Session | None = None,
    schema_dir: Path | None = None,
    database_url: str | None = None,
) -> list[str]:
    """Apply every migration file. Returns the names applied.

    Extension creation (migration 001) is executed outside of SQLAlchemy on a
    direct psycopg connection to prevent vector operations or type-registration
    listeners from running before the extension is installed.
    """
    from garage_rag.db.engine import reset_engine

    raw_url = database_url or get_settings().database_url

    # Always ensure extensions (001) are initialized outside normal SQLAlchemy
    ext_applied = init_extensions(database_url=raw_url, schema_dir=schema_dir)

    files = migration_files(schema_dir)
    applied: list[str] = list(ext_applied)

    remaining_files = [f for f in files if f.name not in ext_applied and not is_extension_migration(f)]

    if session is not None:
        for path in remaining_files:
            log.info("applying %s", path.name)
            # exec_driver_sql: these files contain multiple statements and
            # dollar-quoted DO blocks, which SQLAlchemy's text() would try to parse
            # for bind parameters.
            session.connection().exec_driver_sql(path.read_text(encoding="utf-8"))
            session.connection().exec_driver_sql(
                f"INSERT INTO schema_migrations (version) VALUES ('{path.stem}') ON CONFLICT (version) DO NOTHING;"
            )
            applied.append(path.name)
    else:
        if remaining_files:
            conninfo = to_psycopg_conninfo(raw_url)
            with _connect(conninfo) as conn, conn.cursor() as cur:
                for path in remaining_files:
                    log.info("applying %s", path.name)
                    cur.execute(path.read_text(encoding="utf-8"))
                    cur.execute(
                        "INSERT INTO schema_migrations (version) VALUES (%s) ON CONFLICT (version) DO NOTHING;",
                        (path.stem,),
                    )
                    applied.append(path.name)
        reset_engine()

    return applied


def pending_migrations(
    database_url: str | None = None,
    schema_dir: Path | None = None,
) -> list[Path]:
    """Return list of migration files that have not yet been applied to the database."""
    raw_url = database_url or get_settings().database_url
    url = to_psycopg_conninfo(raw_url)
    # Propagates FileNotFoundError: with no DDL to compare against, "nothing
    # pending" would be a lie.
    files = migration_files(schema_dir)

    try:
        with _connect(url) as conn, conn.cursor() as cur:
            cur.execute(
                "SELECT EXISTS (SELECT 1 FROM information_schema.tables "
                "WHERE table_schema = 'public' AND table_name = 'schema_migrations');"
            )
            row = cur.fetchone()
            exists = bool(row and row[0])
            if not exists:
                return files

            cur.execute("SELECT version FROM schema_migrations;")
            applied = {r[0] for r in cur.fetchall()}

            pending: list[Path] = []
            for f in files:
                if f.stem not in applied and f.name not in applied:
                    pending.append(f)
            return pending
    except Exception:
        return files


def has_pending_migrations(
    database_url: str | None = None,
    schema_dir: Path | None = None,
) -> bool:
    """Check whether there are unapplied database migrations."""
    return len(pending_migrations(database_url=database_url, schema_dir=schema_dir)) > 0


def schema_summary(session: Session) -> dict[str, int]:
    """Row counts for the core tables, for `garage stats` and smoke checks."""
    tables = [
        "sources",
        "authors",
        "author_identities",
        "documents",
        "document_authors",
        "chunks",
        "facts",
        "conversations",
        "messages",
        "embedding_models",
        "ingest_runs",
    ]
    out: dict[str, int] = {}
    for table in tables:
        result = session.execute(text(f"SELECT count(*) FROM {table}")).scalar_one()
        out[table] = int(result)
    return out


def database_exists(url: str) -> bool:
    """Whether the target database is reachable."""
    conninfo = to_psycopg_conninfo(url)
    try:
        with _connect(conninfo) as conn, conn.cursor() as cur:
            cur.execute("SELECT 1")
        return True
    except Exception:  # unreachable, refused, bad credentials, no driver: all "not there"
        return False

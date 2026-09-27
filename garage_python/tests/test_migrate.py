from pathlib import Path
from unittest.mock import MagicMock, patch
from urllib.parse import quote

import pytest

from garage_rag.config import repo_root
from garage_rag.db.migrate import (
    apply_migrations,
    database_exists,
    has_pending_migrations,
    init_extensions,
    migration_files,
    pending_migrations,
    redact_url,
    sql_dir,
    to_psycopg_conninfo,
)


def test_redact_url_hides_the_password() -> None:
    assert redact_url("postgresql+psycopg://garage:s3cret@localhost:5432/rag") == (
        "postgresql+psycopg://garage:***@localhost:5432/rag"
    )
    assert redact_url("postgresql+psycopg:///rag") == "postgresql+psycopg:///rag"
    # A libpq conninfo string is not something make_url understands; show nothing.
    assert "s3cret" not in redact_url("host=localhost password=s3cret dbname=rag")


def test_sql_dir_is_the_committed_ddl() -> None:
    """`garage init-db` without --schema-dir must find the real files."""
    assert sql_dir() == repo_root() / "data" / "sql"
    names = [p.name for p in migration_files()]
    assert names[0] == "001_extensions.sql"
    assert "004_registry.sql" in names


def test_missing_sql_dir_is_an_error_everywhere(tmp_path: Path) -> None:
    """Swallowing it would create extensions and then report an empty database as ready."""
    missing = tmp_path / "nowhere"
    with patch("garage_rag.db.migrate._connect") as mock_connect:
        with pytest.raises(FileNotFoundError):
            init_extensions(database_url="postgresql://u:p@localhost/db", schema_dir=missing)
        with pytest.raises(FileNotFoundError):
            pending_migrations(database_url="postgresql://u:p@localhost/db", schema_dir=missing)
        mock_connect.assert_not_called()


def test_to_psycopg_conninfo() -> None:
    assert (
        to_psycopg_conninfo("postgresql+psycopg://user:pass@localhost:14824/garage-rag")
        == "postgresql://user:pass@localhost:14824/garage-rag"
    )
    assert to_psycopg_conninfo("postgresql+psycopg:///rag") == "postgresql:///rag"
    assert (
        to_psycopg_conninfo("postgresql://user:pass@localhost:5432/test")
        == "postgresql://user:pass@localhost:5432/test"
    )
    assert to_psycopg_conninfo("host=localhost port=5432 dbname=rag") == "host=localhost port=5432 dbname=rag"


def test_to_psycopg_conninfo_keeps_a_socket_directory_with_spaces() -> None:
    """The app's Postgres listens in the App Group container, whose path has a space."""
    import psycopg.conninfo

    socket_dir = "/Users/me/Library/Group Containers/TEAM.group.x/s"
    url = f"postgresql+psycopg://me:p%40ss@/garage-rag?host={quote(socket_dir, safe='')}&port=14824"
    info = psycopg.conninfo.conninfo_to_dict(to_psycopg_conninfo(url))
    assert info == {"user": "me", "password": "p@ss", "dbname": "garage-rag", "host": socket_dir, "port": "14824"}


def test_migration_files_uses_supplied_schema_directory(tmp_path: Path) -> None:
    (tmp_path / "001_schema.sql").write_text("-- schema", encoding="utf-8")
    (tmp_path / "notes.sql").write_text("-- ignored", encoding="utf-8")

    assert migration_files(tmp_path) == [tmp_path / "001_schema.sql"]


def test_init_extensions_executes_outside_sqlalchemy(tmp_path: Path) -> None:
    (tmp_path / "001_extensions.sql").write_text(
        "CREATE EXTENSION IF NOT EXISTS vector;\nCREATE EXTENSION IF NOT EXISTS pg_trgm;",
        encoding="utf-8",
    )

    mock_conn = MagicMock()
    mock_cursor = MagicMock()
    mock_conn.__enter__.return_value = mock_conn
    mock_conn.cursor.return_value.__enter__.return_value = mock_cursor

    with patch("garage_rag.db.migrate._connect", return_value=mock_conn) as mock_connect:
        applied = init_extensions(
            database_url="postgresql+psycopg://user:pass@localhost:5432/testdb",
            schema_dir=tmp_path,
        )

        mock_connect.assert_called_once_with("postgresql://user:pass@localhost:5432/testdb")
        # Bootstraps the schema_migrations ledger, runs the extension file, then records it.
        assert mock_cursor.execute.call_count == 3
        executed = [c.args[0] for c in mock_cursor.execute.call_args_list]
        assert "CREATE TABLE IF NOT EXISTS schema_migrations" in executed[0]
        assert executed[1] == "CREATE EXTENSION IF NOT EXISTS vector;\nCREATE EXTENSION IF NOT EXISTS pg_trgm;"
        assert executed[2].startswith("INSERT INTO schema_migrations")
        assert mock_cursor.execute.call_args_list[2].args[1] == ("001_extensions",)
        assert "001_extensions.sql" in applied


def test_apply_migrations_without_session(tmp_path: Path) -> None:
    (tmp_path / "001_extensions.sql").write_text("CREATE EXTENSION IF NOT EXISTS vector;", encoding="utf-8")
    (tmp_path / "003_core.sql").write_text("CREATE TABLE test_table (id int);", encoding="utf-8")

    mock_conn = MagicMock()
    mock_cursor = MagicMock()
    mock_conn.__enter__.return_value = mock_conn
    mock_conn.cursor.return_value.__enter__.return_value = mock_cursor

    with (
        patch("garage_rag.db.migrate._connect", return_value=mock_conn) as mock_connect,
        patch("garage_rag.db.engine.reset_engine") as mock_reset,
    ):
        applied = apply_migrations(
            schema_dir=tmp_path,
            database_url="postgresql+psycopg://user:pass@localhost:5432/testdb",
        )

        assert mock_connect.call_count == 2
        mock_connect.assert_called_with("postgresql://user:pass@localhost:5432/testdb")
        assert applied == ["001_extensions.sql", "003_core.sql"]
        mock_reset.assert_called_once()


def test_apply_migrations_with_session(tmp_path: Path) -> None:
    (tmp_path / "001_extensions.sql").write_text("CREATE EXTENSION IF NOT EXISTS vector;", encoding="utf-8")
    (tmp_path / "003_core.sql").write_text("CREATE TABLE test_table (id int);", encoding="utf-8")

    mock_conn = MagicMock()
    mock_cursor = MagicMock()
    mock_conn.__enter__.return_value = mock_conn
    mock_conn.cursor.return_value.__enter__.return_value = mock_cursor

    mock_session = MagicMock()
    mock_driver = MagicMock()
    mock_session.connection.return_value = mock_driver

    with patch("garage_rag.db.migrate._connect", return_value=mock_conn) as mock_connect:
        applied = apply_migrations(
            session=mock_session,
            schema_dir=tmp_path,
            database_url="postgresql+psycopg://user:pass@localhost:5432/testdb",
        )

        mock_connect.assert_called_once_with("postgresql://user:pass@localhost:5432/testdb")
        # Extensions go through raw psycopg: ledger bootstrap, extension SQL, ledger insert.
        assert mock_cursor.execute.call_count == 3
        assert mock_cursor.execute.call_args_list[1].args[0] == "CREATE EXTENSION IF NOT EXISTS vector;"
        # The remaining migration runs on the SQLAlchemy session, followed by its ledger insert.
        driver_sql = [c.args[0] for c in mock_driver.exec_driver_sql.call_args_list]
        assert driver_sql == [
            "CREATE TABLE test_table (id int);",
            "INSERT INTO schema_migrations (version) VALUES ('003_core') ON CONFLICT (version) DO NOTHING;",
        ]
        assert applied == ["001_extensions.sql", "003_core.sql"]


def test_database_exists() -> None:
    mock_conn = MagicMock()
    mock_cursor = MagicMock()
    mock_conn.__enter__.return_value = mock_conn
    mock_conn.cursor.return_value.__enter__.return_value = mock_cursor

    with patch("garage_rag.db.migrate._connect", return_value=mock_conn):
        assert database_exists("postgresql://user:pass@localhost:5432/testdb") is True

    with patch("garage_rag.db.migrate._connect", side_effect=ConnectionRefusedError("connection failed")):
        assert database_exists("postgresql://user:pass@localhost:5432/testdb") is False


def test_pending_migrations_and_has_pending_migrations(tmp_path: Path) -> None:
    (tmp_path / "001_extensions.sql").write_text("CREATE EXTENSION IF NOT EXISTS vector;", encoding="utf-8")
    (tmp_path / "002_types.sql").write_text("CREATE TYPE corpus_class AS ENUM ('document');", encoding="utf-8")
    (tmp_path / "003_core.sql").write_text("CREATE TABLE sources (id serial);", encoding="utf-8")

    mock_conn = MagicMock()
    mock_cursor = MagicMock()
    mock_conn.__enter__.return_value = mock_conn
    mock_conn.cursor.return_value.__enter__.return_value = mock_cursor

    # Scenario 1: schema_migrations does not exist
    mock_cursor.fetchone.return_value = (False,)
    with patch("garage_rag.db.migrate._connect", return_value=mock_conn):
        assert (
            has_pending_migrations(
                database_url="postgresql://user:pass@localhost:5432/testdb",
                schema_dir=tmp_path,
            )
            is True
        )
        pending = pending_migrations(
            database_url="postgresql://user:pass@localhost:5432/testdb",
            schema_dir=tmp_path,
        )
        assert len(pending) == 3

    # Scenario 2: schema_migrations exists, only 001 is applied
    mock_cursor.fetchone.return_value = (True,)
    mock_cursor.fetchall.return_value = [("001_extensions",)]
    with patch("garage_rag.db.migrate._connect", return_value=mock_conn):
        assert (
            has_pending_migrations(
                database_url="postgresql://user:pass@localhost:5432/testdb",
                schema_dir=tmp_path,
            )
            is True
        )
        pending = pending_migrations(
            database_url="postgresql://user:pass@localhost:5432/testdb",
            schema_dir=tmp_path,
        )
        assert [p.name for p in pending] == ["002_types.sql", "003_core.sql"]

    # Scenario 3: all migrations applied
    mock_cursor.fetchone.return_value = (True,)
    mock_cursor.fetchall.return_value = [("001_extensions",), ("002_types",), ("003_core",)]
    with patch("garage_rag.db.migrate._connect", return_value=mock_conn):
        assert (
            has_pending_migrations(
                database_url="postgresql://user:pass@localhost:5432/testdb",
                schema_dir=tmp_path,
            )
            is False
        )
        pending = pending_migrations(
            database_url="postgresql://user:pass@localhost:5432/testdb",
            schema_dir=tmp_path,
        )
        assert pending == []


def test_persist_scan_result() -> None:
    from garage_rag.db.models import Source
    from garage_rag.ingest.scanner import SourceScanResult, persist_scan_result

    mock_source = Source(slug="test-src", expected_elements=0, config={"include_code": True})
    mock_session = MagicMock()
    mock_query = mock_session.query.return_value
    mock_filter = mock_query.filter_by.return_value
    mock_filter.one_or_none.return_value = mock_source

    scan_res = SourceScanResult(
        source_slug="test-src",
        kind="filesystem",
        root=Path("/tmp/test"),
        item_count=42,
        item_type="files",
        details={"scanned": 42},
    )

    persist_scan_result(mock_session, scan_res)

    assert mock_source.expected_elements == 42
    assert mock_source.scan_item_type == "files"
    assert mock_source.scan_details == {"scanned": 42}
    assert mock_source.scanned_at is not None
    # Scan bookkeeping stays out of the user-facing config.
    assert mock_source.config == {"include_code": True}

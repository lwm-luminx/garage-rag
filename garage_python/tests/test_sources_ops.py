"""Removing a source drops it from the config file too: the app lists config-declared sources and
Sync registers them again, so a source removed only from the database would come straight back."""

from __future__ import annotations

import json
from contextlib import contextmanager
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import pytest

from garage_rag.config import load_config
from garage_rag.ops import sources as ops


def _config(path: Path, slugs: list[str]) -> Path:
    path.write_text(
        json.dumps({"sources": [{"slug": slug, "root": str(path.parent), "kind": "filesystem"} for slug in slugs]}),
        encoding="utf-8",
    )
    return path


@contextmanager
def _database(documents: int = 3, *, registered: bool = True):
    """A session that finds the source (unless not `registered`) and counts `documents` for it."""
    session = MagicMock()
    row = SimpleNamespace(id=7) if registered else None
    session.query.return_value.filter_by.return_value.one_or_none.return_value = row
    session.query.return_value.filter.return_value.scalar.return_value = documents

    @contextmanager
    def scope():
        yield session

    with patch.object(ops, "session_scope", scope):
        yield session


def _removing(slug: str, config: Path | None) -> ops.RemoveSourceResult:
    settings = load_config(config) if config else SimpleNamespace(config_path=None)
    with _database() as session, patch.object(ops, "get_settings", return_value=settings):
        result = ops.remove_source(slug)
    session.delete.assert_called_once()
    return result


def test_removing_a_declared_source_drops_it_from_the_config(tmp_path: Path) -> None:
    config = _config(tmp_path / "garage.json", ["notes", "mail"])
    result = _removing("notes", config)
    assert result.config_path == config
    assert [s["slug"] for s in json.loads(config.read_text())["sources"]] == ["mail"]
    assert result.message == f"removed notes (3 documents) and dropped it from {config}"


def test_a_source_the_config_does_not_declare_leaves_the_file_alone(tmp_path: Path) -> None:
    config = _config(tmp_path / "garage.json", ["mail"])
    before = config.read_text()
    result = _removing("notes", config)
    assert result.config_path is None
    assert config.read_text() == before
    assert result.message == "removed notes (3 documents)"


def test_no_config_file_removes_from_the_database_only() -> None:
    result = _removing("notes", None)
    assert result.config_path is None
    assert result.config_error is None


def test_an_unwritable_config_still_removes_and_says_sync_will_re_add_it(tmp_path: Path) -> None:
    config = _config(tmp_path / "garage.json", ["notes"])
    with patch.object(ops, "save_config", side_effect=PermissionError("read-only")):
        result = _removing("notes", config)
    assert result.config_path is None
    assert "Sync will add it again" in result.message
    assert "read-only" in result.message


def test_the_config_never_gains_the_database_url(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("GARAGE_DATABASE_URL", "postgresql://garage:secret@127.0.0.1:14824/garage")
    config = _config(tmp_path / "garage.json", ["notes", "mail"])
    _removing("notes", config)
    assert "secret" not in config.read_text()


def test_a_source_only_the_config_declares_is_removed_from_the_file(tmp_path: Path) -> None:
    config = _config(tmp_path / "garage.json", ["notes", "mail"])
    with _database(registered=False) as session, patch.object(ops, "get_settings", return_value=load_config(config)):
        result = ops.remove_source("notes")
    session.delete.assert_not_called()
    assert result.deleted_documents == 0
    assert result.config_path == config
    assert [s["slug"] for s in json.loads(config.read_text())["sources"]] == ["mail"]


def test_a_source_neither_declares_nor_registers_is_unknown(tmp_path: Path) -> None:
    config = _config(tmp_path / "garage.json", ["mail"])
    with (
        _database(registered=False),
        patch.object(ops, "get_settings", return_value=load_config(config)),
        pytest.raises(LookupError, match="no such source: notes"),
    ):
        ops.remove_source("notes")


def test_adding_a_missing_root_is_an_argument_error(tmp_path: Path) -> None:
    with _database(registered=False), pytest.raises(ops.SourceArgumentError, match="does not exist"):
        ops.add_source("notes", tmp_path / "nope")


def test_a_root_the_sandbox_may_not_look_at_is_still_added(tmp_path: Path) -> None:
    """The App Store build's XPC service cannot stat outside its container; the ingest service, which
    holds the folder grant, is the one that reads the root."""
    root = tmp_path / "Documents"
    with (
        _database(registered=False) as session,
        patch.object(Path, "stat", side_effect=PermissionError("Operation not permitted")),
    ):
        result = ops.add_source("notes", root)
    session.add.assert_called_once()
    assert result.root == root
    assert result.created

"""The `garage` subcommands not covered elsewhere: sources, models, schema, stats, search,
backfill, reconcile, extract, and the config inspection commands.

Each command is a thin presenter over a function in ``garage_rag.ops`` (or a
query), so these tests patch that function or the session and check what the
command passes it, what it prints, and the exit code it ends with.
"""

from __future__ import annotations

import json
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import pytest
from typer.testing import CliRunner

from garage_rag import cli
from garage_rag.cli import app
from garage_rag.config import reset_settings
from garage_rag.db.models import Source
from garage_rag.ingest.reconcile import ReconcileResult
from garage_rag.ops.backfill import BackfillEvent
from garage_rag.ops.models import RegisteredModel
from garage_rag.ops.sources import (
    AddSourceResult,
    ImportSourcesResult,
    RemoveSourceResult,
    SourceArgumentError,
    SyncResult,
)
from garage_rag.search.hybrid import SearchHit

runner = CliRunner()


@pytest.fixture(autouse=True)
def _wide_console_and_fresh_settings(monkeypatch: pytest.MonkeyPatch):
    # Rich wraps to the terminal width, 80 columns under the runner. Make it wide enough that every
    # table cell and every path prints whole, Bazel's sandbox paths (often past 240 columns) included.
    monkeypatch.setattr(cli.console, "_width", 10_000)
    monkeypatch.delenv("GARAGE_DATABASE_URL", raising=False)
    yield
    reset_settings()


@pytest.fixture
def cfg(tmp_path: Path) -> Path:
    path = tmp_path / "garage.json"
    path.write_text("{}")
    return path


def _invoke(cfg: Path, *args: str, input: str | None = None):
    return runner.invoke(app, ["--config", str(cfg), *args], input=input)


def _scope(session: MagicMock) -> MagicMock:
    """A stand-in for ``session_scope`` that yields ``session``."""
    scope = MagicMock()
    scope.return_value.__enter__.return_value = session
    return scope


def _model_row(slug: str = "bge-m3", *, is_default: bool = True) -> SimpleNamespace:
    return SimpleNamespace(
        slug=slug,
        provider="llama_xpc",
        model_ref=slug,
        model_id="BAAI/bge-m3",
        dims=1024,
        stored_dims=1024,
        storage_kind="vector",
        index_kind="hnsw",
        distance="cosine",
        modality="text",
        table_name=f"emb_{slug.replace('-', '_')}",
        is_default=is_default,
    )


# ---------------------------------------------------------------------------
# sync
# ---------------------------------------------------------------------------
class TestSync:
    def test_reports_created_updated_and_undeclared(self, cfg: Path) -> None:
        result = SyncResult(
            config_path=cfg, declared=2, applied=True, created=["notes"], updated=["mail"], undeclared=[("old", 1234)]
        )
        with patch("garage_rag.ops.sources.sync_sources", return_value=result) as op:
            out = _invoke(cfg, "sync")
        assert out.exit_code == 0, out.output
        op.assert_called_once_with(apply=True)
        assert "create: notes" in out.output
        assert "update: mail" in out.output
        assert "old (1,234 documents)" in out.output
        assert "would" not in out.output

    def test_dry_run_says_would(self, cfg: Path) -> None:
        result = SyncResult(config_path=cfg, declared=1, applied=False, created=["notes"])
        with patch("garage_rag.ops.sources.sync_sources", return_value=result) as op:
            out = _invoke(cfg, "sync", "--dry-run")
        assert out.exit_code == 0, out.output
        op.assert_called_once_with(apply=False)
        assert "would create: notes" in out.output

    def test_nothing_declared(self, cfg: Path) -> None:
        with patch("garage_rag.ops.sources.sync_sources", return_value=SyncResult(None, 0, True)):
            out = _invoke(cfg, "sync")
        assert out.exit_code == 0
        assert "no sources declared" in out.output

    def test_database_already_matches(self, cfg: Path) -> None:
        with patch("garage_rag.ops.sources.sync_sources", return_value=SyncResult(cfg, 1, True)):
            out = _invoke(cfg, "sync")
        assert "database already matches the config" in out.output

    def test_a_bad_declaration_exits_1(self, cfg: Path) -> None:
        error = SourceArgumentError("root does not exist: /nope", param_hint="root")
        with patch("garage_rag.ops.sources.sync_sources", side_effect=error):
            out = _invoke(cfg, "sync")
        assert out.exit_code == 1
        assert "root does not exist" in out.output


# ---------------------------------------------------------------------------
# init-db / stats
# ---------------------------------------------------------------------------
class TestSchemaAndStats:
    def test_init_db_lists_applied_migrations_and_redacts_the_url(self, tmp_path: Path) -> None:
        cfg = tmp_path / "garage.json"
        cfg.write_text(json.dumps({"database": {"url": "postgresql://rick:s3cret@localhost:5432/garage"}}))
        with patch("garage_rag.cli.apply_migrations", return_value=["001_extensions.sql", "002_core.sql"]) as op:
            out = _invoke(cfg, "init-db", "--schema-dir", str(tmp_path))
        assert out.exit_code == 0, out.output
        op.assert_called_once_with(schema_dir=tmp_path)
        assert "applied 001_extensions.sql" in out.output
        assert "applied 002_core.sql" in out.output
        assert "schema ready" in out.output
        assert "s3cret" not in out.output

    def test_init_db_with_nothing_to_apply(self, cfg: Path) -> None:
        with patch("garage_rag.cli.apply_migrations", return_value=[]) as op:
            out = _invoke(cfg, "init-db")
        assert out.exit_code == 0, out.output
        op.assert_called_once_with(schema_dir=None)
        assert "applied" not in out.output
        assert "schema ready" in out.output

    def test_stats_prints_tables_and_models(self, cfg: Path) -> None:
        with (
            patch("garage_rag.cli.session_scope", _scope(MagicMock())),
            patch("garage_rag.cli.schema_summary", return_value={"documents": 1234, "chunks": 56789}),
            patch("garage_rag.cli.list_models", return_value=[_model_row()]),
            patch("garage_rag.cli.count_vectors", return_value=4321),
        ):
            out = _invoke(cfg, "stats")
        assert out.exit_code == 0, out.output
        assert "1,234" in out.output and "56,789" in out.output
        assert "embedding models" in out.output
        assert "bge-m3" in out.output and "vector(1024)" in out.output and "4,321" in out.output

    def test_stats_without_models_has_no_model_table(self, cfg: Path) -> None:
        with (
            patch("garage_rag.cli.session_scope", _scope(MagicMock())),
            patch("garage_rag.cli.schema_summary", return_value={"documents": 0}),
            patch("garage_rag.cli.list_models", return_value=[]),
        ):
            out = _invoke(cfg, "stats")
        assert out.exit_code == 0, out.output
        assert "corpus" in out.output
        assert "embedding models" not in out.output


# ---------------------------------------------------------------------------
# models
# ---------------------------------------------------------------------------
def _registered(**overrides) -> RegisteredModel:
    values = {
        "slug": "big",
        "provider": "llama_xpc",
        "model_ref": "big",
        "model_id": None,
        "dims": 4096,
        "stored_dims": 2000,
        "storage_kind": "halfvec",
        "index_kind": "hnsw",
        "table_name": "emb_big",
        "is_default": False,
        "distance": "cosine",
        "notes": ["truncated 4096 -> 2000 (Matryoshka)"],
    }
    values.update(overrides)
    return RegisteredModel(**values)


class TestModels:
    def test_register_model_passes_options_and_prints_notes(self, cfg: Path) -> None:
        with patch("garage_rag.ops.models.register_model", return_value=_registered()) as op:
            out = _invoke(
                cfg, "register-model", "big", "--dims", "4096", "--provider", "llama_xpc", "--distance", "cosine"
            )
        assert out.exit_code == 0, out.output
        op.assert_called_once_with(
            "big",
            dims=4096,
            model_ref=None,
            provider="llama_xpc",
            model_id=None,
            distance="cosine",
            modality=None,
            make_default=False,
        )
        assert "registered big: 4096-dim -> halfvec(2000)" in out.output
        assert "table=emb_big" in out.output
        assert "truncated 4096 -> 2000" in out.output

    def test_register_model_default_flag(self, cfg: Path) -> None:
        with patch("garage_rag.ops.models.register_model", return_value=_registered(notes=[])) as op:
            out = _invoke(cfg, "register-model", "big", "--default")
        assert out.exit_code == 0, out.output
        assert op.call_args.kwargs["make_default"] is True

    def test_register_model_refusal_exits_2(self, cfg: Path) -> None:
        with patch("garage_rag.ops.models.register_model", side_effect=ValueError("dims required for unknown model")):
            out = _invoke(cfg, "register-model", "mystery")
        assert out.exit_code == 2
        assert "dims required" in out.output

    def test_list_models_json(self, cfg: Path) -> None:
        with (
            patch("garage_rag.cli.session_scope", _scope(MagicMock())),
            patch("garage_rag.cli.list_models", return_value=[_model_row()]),
        ):
            out = _invoke(cfg, "list-models", "--json")
        assert out.exit_code == 0, out.output
        rows = json.loads(out.output)
        assert rows == [
            {
                "slug": "bge-m3",
                "provider": "llama_xpc",
                "model_ref": "bge-m3",
                "model_id": "BAAI/bge-m3",
                "dims": 1024,
                "stored_dims": 1024,
                "storage_kind": "vector",
                "index_kind": "hnsw",
                "distance": "cosine",
                "modality": "text",
                "table_name": "emb_bge_m3",
                "is_default": True,
            }
        ]

    def test_list_models_table(self, cfg: Path) -> None:
        with (
            patch("garage_rag.cli.session_scope", _scope(MagicMock())),
            patch("garage_rag.cli.list_models", return_value=[_model_row(), _model_row("nomic", is_default=False)]),
        ):
            out = _invoke(cfg, "list-models")
        assert out.exit_code == 0, out.output
        assert "bge-m3" in out.output and "nomic" in out.output
        assert "emb_bge_m3" in out.output

    def test_list_models_empty(self, cfg: Path) -> None:
        with (
            patch("garage_rag.cli.session_scope", _scope(MagicMock())),
            patch("garage_rag.cli.list_models", return_value=[]),
        ):
            out = _invoke(cfg, "list-models")
        assert out.exit_code == 0
        assert "no models registered" in out.output

    def test_set_default_model(self, cfg: Path) -> None:
        with patch("garage_rag.ops.models.set_default_model") as op:
            out = _invoke(cfg, "set-default-model", "bge-m3")
        assert out.exit_code == 0, out.output
        op.assert_called_once_with("bge-m3")
        assert "default model = bge-m3" in out.output

    def test_drop_model_with_yes(self, cfg: Path) -> None:
        with patch("garage_rag.ops.models.drop_model") as op:
            out = _invoke(cfg, "drop-model", "bge-m3", "--yes")
        assert out.exit_code == 0, out.output
        op.assert_called_once_with("bge-m3")
        assert "dropped bge-m3" in out.output

    def test_drop_model_declined_keeps_the_model(self, cfg: Path) -> None:
        with patch("garage_rag.ops.models.drop_model") as op:
            out = _invoke(cfg, "drop-model", "bge-m3", input="n\n")
        assert out.exit_code == 1
        assert "Drop model bge-m3" in out.output
        op.assert_not_called()


# ---------------------------------------------------------------------------
# sources
# ---------------------------------------------------------------------------
class TestSources:
    def test_add_source_passes_its_options(self, cfg: Path, tmp_path: Path) -> None:
        result = AddSourceResult(
            slug="mail", root=tmp_path, corpus_class="communication", trust="received", created=True
        )
        with patch("garage_rag.ops.sources.add_source", return_value=result) as op:
            out = _invoke(
                cfg,
                "add-source",
                "mail",
                str(tmp_path),
                "--kind",
                "maildir",
                "--class",
                "communication",
                "--trust",
                "received",
            )
        assert out.exit_code == 0, out.output
        op.assert_called_once_with("mail", tmp_path, kind="maildir", corpus_class="communication", trust="received")
        assert "added source mail" in out.output
        assert "communication/received" in out.output

    def test_add_source_again_updates_it(self, cfg: Path, tmp_path: Path) -> None:
        result = AddSourceResult(slug="notes", root=tmp_path, corpus_class="document", trust="authored", created=False)
        with patch("garage_rag.ops.sources.add_source", return_value=result):
            out = _invoke(cfg, "add-source", "notes", str(tmp_path))
        assert out.exit_code == 0, out.output
        assert "updated source notes" in out.output

    def test_add_source_bad_argument_is_a_usage_error(self, cfg: Path, tmp_path: Path) -> None:
        error = SourceArgumentError("unknown kind 'ftp'", param_hint="--kind")
        with patch("garage_rag.ops.sources.add_source", side_effect=error):
            out = _invoke(cfg, "add-source", "x", str(tmp_path), "--kind", "ftp")
        assert out.exit_code == 2
        assert "unknown kind 'ftp'" in out.output

    def test_remove_source_with_yes(self, cfg: Path) -> None:
        with (
            patch("garage_rag.ops.sources.document_count", return_value=12) as count,
            patch("garage_rag.ops.sources.remove_source", return_value=RemoveSourceResult("notes", 12)) as op,
        ):
            out = _invoke(cfg, "remove-source", "notes", "--yes")
        assert out.exit_code == 0, out.output
        count.assert_called_once_with("notes")
        op.assert_called_once_with("notes")
        assert "removed notes (12 documents)" in out.output

    def test_remove_source_declined_keeps_it(self, cfg: Path) -> None:
        with (
            patch("garage_rag.ops.sources.document_count", return_value=3),
            patch("garage_rag.ops.sources.remove_source") as op,
        ):
            out = _invoke(cfg, "remove-source", "notes", input="n\n")
        assert out.exit_code == 1
        assert "delete 3 documents" in out.output
        op.assert_not_called()

    def test_remove_unknown_source_exits_1(self, cfg: Path) -> None:
        with (
            patch("garage_rag.ops.sources.document_count", side_effect=LookupError("no such source: nope")),
            patch("garage_rag.ops.sources.remove_source") as op,
        ):
            out = _invoke(cfg, "remove-source", "nope", "--yes")
        assert out.exit_code == 1
        assert "no such source" in out.output
        op.assert_not_called()

    @staticmethod
    def _sources_session(sources: list, counts: list[tuple[int, int]]) -> MagicMock:
        session = MagicMock()
        source_query = MagicMock()
        source_query.order_by.return_value.all.return_value = sources
        count_query = MagicMock()
        count_query.group_by.return_value.all.return_value = counts
        session.query.side_effect = lambda *entities: source_query if entities[0] is Source else count_query
        return session

    def test_list_sources_table(self, cfg: Path) -> None:
        sources = [
            SimpleNamespace(
                id=1,
                slug="notes",
                kind="filesystem",
                default_class="document",
                default_trust="authored",
                enabled=True,
                root="/Users/rick/Notes",
            ),
            SimpleNamespace(
                id=2,
                slug="mail",
                kind="maildir",
                default_class="communication",
                default_trust="received",
                enabled=False,
                root="/Users/rick/Library/Mail",
            ),
        ]
        with patch("garage_rag.cli.session_scope", _scope(self._sources_session(sources, [(1, 1500)]))):
            out = _invoke(cfg, "list-sources")
        assert out.exit_code == 0, out.output
        lines = out.output.splitlines()
        notes = next(line for line in lines if "notes" in line)
        mail = next(line for line in lines if "maildir" in line)
        assert "1,500" in notes and "yes" in notes and "/Users/rick/Notes" in notes
        assert " 0 " in mail and "no" in mail and "communication" in mail

    def test_list_sources_empty(self, cfg: Path) -> None:
        with patch("garage_rag.cli.session_scope", _scope(self._sources_session([], []))):
            out = _invoke(cfg, "list-sources")
        assert out.exit_code == 0
        assert "no sources registered" in out.output

    def test_config_import_sources(self, cfg: Path) -> None:
        with patch(
            "garage_rag.ops.sources.import_sources_into_config",
            return_value=ImportSourcesResult(cfg, ["notes", "mail"]),
        ) as op:
            out = _invoke(cfg, "config", "import-sources", "--path", str(cfg))
        assert out.exit_code == 0, out.output
        op.assert_called_once_with(cfg)
        assert "added 2 sources" in out.output
        assert "notes" in out.output and "mail" in out.output

    def test_config_import_sources_with_nothing_new(self, cfg: Path) -> None:
        with patch("garage_rag.ops.sources.import_sources_into_config", return_value=ImportSourcesResult(cfg, [])):
            out = _invoke(cfg, "config", "import-sources")
        assert out.exit_code == 0
        assert "config already lists every database source" in out.output


# ---------------------------------------------------------------------------
# backfill / reconcile
# ---------------------------------------------------------------------------
class TestBackfill:
    def test_prints_each_model_outcome(self, cfg: Path) -> None:
        received = {}

        def fake(model=None, *, batch_size=None, limit=None, verify=True, on_event):
            received.update(model=model, batch_size=batch_size, limit=limit, verify=verify)
            on_event(BackfillEvent("done", "complete"))
            on_event(BackfillEvent("broken", "skipped", message="broken: model file missing"))
            on_event(BackfillEvent("m", "started", total=10))
            on_event(BackfillEvent("m", "progress", total=10, embedded=4, batches=1))
            on_event(BackfillEvent("m", "finished", total=10, embedded=8, failed=1, batches=2))
            return []

        with patch("garage_rag.ops.backfill.backfill", side_effect=fake):
            out = _invoke(cfg, "backfill", "--model", "m", "--batch-size", "16", "--limit", "10", "--no-verify")
        assert out.exit_code == 0, out.output
        assert received == {"model": "m", "batch_size": 16, "limit": 10, "verify": False}
        assert "done: already complete" in out.output
        assert "broken: model file missing" in out.output
        assert "m: embedding 10 chunks" in out.output
        assert "m: embedded 8, failed 1, remaining 1" in out.output

    def test_defaults_embed_every_model(self, cfg: Path) -> None:
        with patch("garage_rag.ops.backfill.backfill", return_value=[]) as op:
            out = _invoke(cfg, "backfill")
        assert out.exit_code == 0, out.output
        assert op.call_args.args == (None,)
        assert op.call_args.kwargs["batch_size"] is None
        assert op.call_args.kwargs["verify"] is True

    def test_no_models_exits_1(self, cfg: Path) -> None:
        with patch("garage_rag.ops.backfill.backfill", side_effect=LookupError("no models registered")):
            out = _invoke(cfg, "backfill")
        assert out.exit_code == 1
        assert "no models registered" in out.output

    def test_an_unknown_model_is_not_swallowed(self, cfg: Path) -> None:
        with patch("garage_rag.ops.backfill.backfill", side_effect=LookupError("no model 'x' registered")):
            out = _invoke(cfg, "backfill", "--model", "x")
        assert out.exit_code != 0
        assert isinstance(out.exception, LookupError)


class TestReconcile:
    def _run(self, cfg: Path, result: ReconcileResult, *args: str):
        with (
            patch("garage_rag.cli.session_scope", _scope(MagicMock())),
            patch("garage_rag.ingest.reconcile.reconcile_source", return_value=result) as op,
        ):
            out = _invoke(cfg, "reconcile", "--source", "notes", *args)
        return out, op

    def test_dry_run_counts_missing_documents(self, cfg: Path) -> None:
        out, op = self._run(cfg, ReconcileResult(source="notes", candidates=3, total_documents=100))
        assert out.exit_code == 0, out.output
        assert op.call_args.kwargs == {"dry_run": True, "force": False}
        assert "dry run: 3 of 100 documents in notes are missing (3.0%)" in out.output
        assert "--apply" in out.output

    def test_apply_deletes(self, cfg: Path) -> None:
        out, op = self._run(
            cfg, ReconcileResult(source="notes", candidates=3, deleted=3, total_documents=100), "--apply"
        )
        assert out.exit_code == 0, out.output
        assert op.call_args.kwargs == {"dry_run": False, "force": False}
        assert "deleted 3 of 100 documents from notes" in out.output

    def test_nothing_missing(self, cfg: Path) -> None:
        out, _ = self._run(cfg, ReconcileResult(source="notes", total_documents=100))
        assert out.exit_code == 0
        assert "nothing to reconcile for notes" in out.output

    def test_mass_deletion_guard_refuses(self, cfg: Path) -> None:
        refused = ReconcileResult(
            source="notes",
            candidates=90,
            total_documents=100,
            refused=True,
            reason="90% missing; is the drive mounted?",
        )
        out, op = self._run(cfg, refused, "--apply", "--force")
        assert out.exit_code == 1
        assert op.call_args.kwargs == {"dry_run": False, "force": True}
        assert "refused: 90% missing" in out.output


# ---------------------------------------------------------------------------
# search
# ---------------------------------------------------------------------------
class TestSearch:
    def test_prints_ranked_hits_and_passes_filters(self, cfg: Path) -> None:
        hit = SearchHit(
            chunk_id=1,
            document_id=2,
            uri="/tmp/notes/architecture.md",
            title="Architecture",
            corpus_class="document",
            trust_tier="authored",
            heading_path="Design > Storage",
            text="Embeddings live one table per model.",
            score=0.0325,
            vector_rank=1,
            fts_rank=2,
            authors=["Rick"],
            direction="sent",
            sender="me",
        )
        with (
            patch("garage_rag.cli.session_scope", _scope(MagicMock())),
            patch("garage_rag.search.hybrid.search", return_value=[hit]) as op,
        ):
            out = _invoke(
                cfg,
                "search",
                "storage",
                "--limit",
                "5",
                "--mode",
                "fts",
                "--class",
                "document",
                "--trust",
                "authored",
                "--source",
                "notes",
                "--author",
                "Rick",
                "--direction",
                "sent",
                "--full",
            )
        assert out.exit_code == 0, out.output
        assert op.call_args.args[1] == "storage"
        assert op.call_args.kwargs == {
            "limit": 5,
            "mode": "fts",
            "model_slug": None,
            "corpus_classes": ["document"],
            "trust_tiers": ["authored"],
            "sources": ["notes"],
            "author": "Rick",
            "direction": "sent",
        }
        assert "1. Architecture" in out.output
        assert "document/authored, both, score 0.0325" in out.output
        assert "section: Design > Storage" in out.output
        assert "authors: Rick" in out.output
        assert "sent by me" in out.output
        assert "Embeddings live one table per model." in out.output

    def test_no_results(self, cfg: Path) -> None:
        with (
            patch("garage_rag.cli.session_scope", _scope(MagicMock())),
            patch("garage_rag.search.hybrid.search", return_value=[]) as op,
        ):
            out = _invoke(cfg, "search", "nothing")
        assert out.exit_code == 0
        assert op.call_args.kwargs["mode"] == "hybrid"
        assert op.call_args.kwargs["corpus_classes"] is None
        assert op.call_args.kwargs["direction"] is None
        assert "no results" in out.output


# ---------------------------------------------------------------------------
# extract
# ---------------------------------------------------------------------------
class TestExtract:
    def test_extracts_and_chunks_a_markdown_file(self, cfg: Path, tmp_path: Path) -> None:
        note = tmp_path / "note.md"
        note.write_text(
            "# Garage\n\nGarage keeps a local index of personal documents.\n\n## Search\n\nHybrid search.\n"
        )
        out = _invoke(cfg, "extract", str(note), "--show", "1")
        assert out.exit_code == 0, out.output
        assert "extractor :" in out.output
        assert "chunks    :" in out.output
        assert "--- chunk 0" in out.output

    def test_extraction_failure_exits_1(self, cfg: Path, tmp_path: Path) -> None:
        from garage_rag.extract.base import ExtractionError

        note = tmp_path / "broken.md"
        note.write_text("x")
        with patch("garage_rag.extract.dispatch.extract", side_effect=ExtractionError("parser crashed")):
            out = _invoke(cfg, "extract", str(note))
        assert out.exit_code == 1
        assert "extraction failed: parser crashed" in out.output

    def test_no_text_is_not_an_error(self, cfg: Path, tmp_path: Path) -> None:
        from garage_rag.extract.base import NoTextFound

        image = tmp_path / "blank.png"
        image.write_bytes(b"")
        with patch("garage_rag.extract.dispatch.extract", side_effect=NoTextFound("no text in image")):
            out = _invoke(cfg, "extract", str(image))
        assert out.exit_code == 0
        assert "no text" in out.output


# ---------------------------------------------------------------------------
# config show / path / schema
# ---------------------------------------------------------------------------
class TestConfigInspection:
    def test_show_diff_prints_only_overrides(self, tmp_path: Path) -> None:
        cfg = tmp_path / "garage.json"
        cfg.write_text(json.dumps({"facts": {"model": "phi-4-mini"}}))
        out = _invoke(cfg, "config", "show", "--diff")
        assert out.exit_code == 0, out.output
        assert f"loaded from: {cfg}" in out.output
        body = json.loads(out.output[out.output.index("{") :])
        assert body["facts"]["model"] == "phi-4-mini"
        assert "chunking" not in body

    def test_show_with_defaults_prints_every_section(self, cfg: Path) -> None:
        out = _invoke(cfg, "config", "show")
        assert out.exit_code == 0, out.output
        body = json.loads(out.output[out.output.index("{") :])
        assert {"facts", "embedding", "database"} <= set(body)

    def test_path_names_the_file_in_use_and_the_search_order(self, cfg: Path) -> None:
        out = _invoke(cfg, "config", "path")
        assert out.exit_code == 0, out.output
        assert f"in use : {cfg}" in out.output
        assert "search order:" in out.output

    def test_schema_writes_the_json_schema(self, cfg: Path, tmp_path: Path) -> None:
        target = tmp_path / "schema.json"
        out = _invoke(cfg, "config", "schema", "--path", str(target))
        assert out.exit_code == 0, out.output
        assert f"wrote {target}" in out.output.replace("\n", "")
        schema = json.loads(target.read_text())
        assert "facts" in schema["properties"]
        assert "sources" in schema["properties"]

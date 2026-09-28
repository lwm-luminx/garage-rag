"""The operation RPCs the app calls instead of shelling out to `garage`.

Each handler is a thin translation over a garage_rag.ops function; these tests
check the request/response mapping, the status codes errors turn into, and the
streaming of progress events. Operations that need no database run for real.
"""

from __future__ import annotations

import json
import threading
import time
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import grpc
import pytest

from garage_rag.config import Settings, reset_settings, set_settings
from garage_rag.ingest.reconcile import ReconcileResult
from garage_rag.ingest.scanner import SourceScanResult
from garage_rag.ops.backfill import BackfillEvent
from garage_rag.ops.facts import EnrichEvent, EnrichSummary
from garage_rag.ops.models import RegisteredModel
from garage_rag.ops.sources import AddSourceResult, RemoveSourceResult, ScanEvent, SyncResult
from garage_rag.proto.garage_pb2 import (
    AddSourceRequest,
    BackfillRequest,
    EnrichFactsRequest,
    McpInstallRequest,
    McpUninstallRequest,
    ReconcileRequest,
    RegisterModelRequest,
)
from garage_rag.proto.garage_pb2_grpc import GarageServiceStub
from garage_rag.service.client import GarageClient
from garage_rag.service.server import create_grpc_server


@pytest.fixture
def client() -> GarageClient:
    return GarageClient(in_process=True)


@pytest.fixture(autouse=True)
def _fresh_settings():
    yield
    reset_settings()


class TestSources:
    def test_add_source_maps_request_and_defaults(self, client: GarageClient, tmp_path: Path) -> None:
        result = AddSourceResult(slug="docs", root=tmp_path, corpus_class="document", trust="authored", created=True)
        with patch("garage_rag.ops.sources.add_source", return_value=result) as op:
            res = client.add_source(AddSourceRequest(slug="docs", root=str(tmp_path)))
        op.assert_called_once_with(
            "docs",
            str(tmp_path),
            kind="filesystem",
            corpus_class="document",
            trust="authored",
        )
        assert res.created is True
        assert res.root == str(tmp_path)
        assert res.message.startswith("added source docs")

    def test_remove_unknown_source_is_not_found(self, client: GarageClient) -> None:
        with (
            patch("garage_rag.ops.sources.remove_source", side_effect=LookupError("no such source: gone")),
            pytest.raises(RuntimeError, match="NOT_FOUND.*gone"),
        ):
            client.remove_source("gone")

    def test_remove_source_reports_deleted_documents(self, client: GarageClient) -> None:
        with patch("garage_rag.ops.sources.remove_source", return_value=RemoveSourceResult("docs", 12)):
            res = client.remove_source("docs")
        assert res.deleted_documents == 12
        assert res.message == "removed docs (12 documents)"

    def test_scan_streams_running_count_then_summary(self, client: GarageClient, tmp_path: Path) -> None:
        done = SourceScanResult("docs", "filesystem", tmp_path, item_count=1234, item_type="files")

        def fake(source, *, include_code, on_event):
            on_event(ScanEvent("progress", "docs", 0, 0))
            on_event(ScanEvent("progress", "docs", 1000, 1000))
            on_event(ScanEvent("source", "docs", 1234, 1234, done))
            return [done]

        with patch("garage_rag.ops.sources.scan_sources", side_effect=fake) as op:
            statuses = list(client.scan("docs"))
        assert op.call_args.args == ("docs",)
        assert [s.phase for s in statuses] == ["progress", "progress", "source", "finished"]
        assert statuses[1].source == "docs" and statuses[1].source_items == 1000
        assert statuses[2].result.item_count == 1234
        assert not statuses[1].HasField("result")
        summary = statuses[-1].summary
        assert summary.total_items == 1234 and [s.source for s in summary.sources] == ["docs"]
        assert summary.message == "Scanned 1 source(s): 1,234 items"

    def test_scan_unknown_source_is_not_found(self, client: GarageClient) -> None:
        with (
            patch("garage_rag.ops.sources.scan_sources", side_effect=LookupError("no such source: gone")),
            pytest.raises(RuntimeError, match="NOT_FOUND"),
        ):
            list(client.scan("gone"))

    def test_sync_reports_lines_and_undeclared(self, client: GarageClient) -> None:
        result = SyncResult(
            config_path=Path("/tmp/garage.json"),
            declared=2,
            applied=False,
            created=["a"],
            updated=["b"],
            undeclared=[("old", 3)],
        )
        with patch("garage_rag.ops.sources.sync_sources", return_value=result) as op:
            res = client.sync_sources(dry_run=True)
        op.assert_called_once_with(apply=False)
        assert list(res.created) == ["a"]
        assert res.undeclared[0].slug == "old" and res.undeclared[0].document_count == 3
        assert "would create: a" in res.message

    def test_import_sources_never_writes_the_database_url(
        self, client: GarageClient, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """The app exports its Postgres password as GARAGE_DATABASE_URL; saving the file must not persist it."""
        config = tmp_path / "garage.json"
        config.write_text(json.dumps({"identity": {"name": "Rick"}}), encoding="utf-8")
        monkeypatch.chdir(tmp_path)
        monkeypatch.setenv("GARAGE_DATABASE_URL", "postgresql://garage:s3cret@127.0.0.1:14824/garage")
        row = SimpleNamespace(
            slug="notes",
            root=str(tmp_path),
            kind="filesystem",
            default_class="document",
            default_trust="authored",
            config={},
            enabled=True,
        )
        session = MagicMock()
        session.query.return_value.order_by.return_value.all.return_value = [row]
        with patch("garage_rag.ops.sources.session_scope") as scope:
            scope.return_value.__enter__.return_value = session
            res = client.import_sources_to_config(str(config))

        assert list(res.added) == ["notes"]
        saved = json.loads(config.read_text(encoding="utf-8"))
        assert "s3cret" not in config.read_text(encoding="utf-8")
        assert saved["database"]["url"] == Settings().database_url
        assert saved["identity"]["name"] == "Rick"
        assert [source["slug"] for source in saved["sources"]] == ["notes"]


class TestModels:
    def test_register_model_returns_model_and_notes(self, client: GarageClient) -> None:
        row = RegisteredModel(
            slug="big",
            provider="llama_xpc",
            model_ref="big",
            model_id=None,
            dims=4096,
            stored_dims=2000,
            storage_kind="halfvec",
            index_kind="hnsw",
            table_name="emb_big",
            is_default=False,
            notes=["truncated 4096 -> 2000 (Matryoshka) to fit the halfvec HNSW ceiling"],
        )
        with patch("garage_rag.ops.models.register_model", return_value=row) as op:
            res = client.register_model(
                RegisterModelRequest(slug="big", dims=4096, provider="llama_xpc", distance="inner_product")
            )
        op.assert_called_once_with(
            "big",
            dims=4096,
            model_ref=None,
            provider="llama_xpc",
            model_id=None,
            distance="inner_product",
            make_default=False,
        )
        assert res.model.stored_dims == 2000
        assert res.model.distance == "cosine"  # what the (mocked) registration reports
        assert list(res.notes) == row.notes
        assert "truncated" in res.message

    def test_drop_unknown_model_is_not_found(self, client: GarageClient) -> None:
        with (
            patch("garage_rag.ops.models.drop_model", side_effect=LookupError("no model 'x' registered")),
            pytest.raises(RuntimeError, match="NOT_FOUND"),
        ):
            client.drop_model("x")


def _fake_backfill(model=None, *, batch_size=None, limit=None, verify=True, on_event):
    on_event(BackfillEvent("m", "started", total=4, message="m: embedding 4 chunks"))
    on_event(BackfillEvent("m", "progress", total=4, embedded=2, batches=1))
    on_event(BackfillEvent("m", "finished", total=4, embedded=4, batches=2, message="m: embedded 4"))
    return []


class TestStreaming:
    def test_backfill_streams_every_event_in_order(self, client: GarageClient) -> None:
        with patch("garage_rag.ops.backfill.backfill", side_effect=_fake_backfill) as op:
            statuses = list(client.backfill(BackfillRequest(model="m", batch_size=16)))
        assert [s.phase for s in statuses] == ["started", "progress", "finished"]
        assert statuses[1].embedded == 2 and statuses[1].remaining == 2
        assert statuses[-1].message == "m: embedded 4"
        assert op.call_args.kwargs["batch_size"] == 16
        assert op.call_args.kwargs["verify"] is True

    def test_backfill_error_after_events_still_delivers_them(self, client: GarageClient) -> None:
        def failing(model=None, *, on_event, **_kwargs):
            on_event(BackfillEvent("m", "complete", message="m: already complete"))
            raise LookupError("no model 'n' registered")

        seen = []
        with (
            patch("garage_rag.ops.backfill.backfill", side_effect=failing),
            pytest.raises(RuntimeError, match="NOT_FOUND"),
        ):
            for status in client.backfill(BackfillRequest(model="n")):
                seen.append(status.phase)
        assert seen == ["complete"]

    def test_enrich_facts_streams_start_documents_and_summary(self, client: GarageClient) -> None:
        received: dict = {}

        def fake(*, source, document_id, model, provider, prompts, stale_only, on_start, on_event):
            received.update(prompts=prompts, stale_only=stale_only)
            on_start(3, "gemma2-2b", "llama_xpc")
            on_event(EnrichEvent(index=1, total=3, document_id=7, uri="/a.md", facts=3, prompts=["people"]))
            on_event(EnrichEvent(index=2, total=3, document_id=8, uri="/b.md", error="boom"))
            on_event(EnrichEvent(index=3, total=3, document_id=9, uri="/c.md", skipped=True))
            return EnrichSummary(
                "gemma2-2b", "llama_xpc", total=3, enriched=1, facts=3, failed=1, skipped=1, prompts=["people"]
            )

        with patch("garage_rag.ops.facts.enrich_facts", side_effect=fake):
            request = EnrichFactsRequest(source="docs", prompts=["people"], stale_only=True)
            statuses = list(client.enrich_facts(request))
        assert received == {"prompts": ["people"], "stale_only": True}
        assert [s.phase for s in statuses] == ["started", "document", "document", "document", "finished"]
        assert statuses[0].provider == "llama_xpc"
        assert list(statuses[1].prompts) == ["people"]
        assert statuses[2].error == "boom"
        assert statuses[3].skipped == 1 and statuses[3].message.endswith(": skipped")
        assert statuses[-1].enriched == 1 and statuses[-1].failed == 1 and statuses[-1].skipped == 1
        assert list(statuses[-1].prompts) == ["people"]
        assert statuses[-1].message == "1/3 documents enriched, 3 facts extracted, 1 skipped, 1 failed"

    def test_enrich_facts_defaults_to_every_enabled_prompt(self, client: GarageClient) -> None:
        received: dict = {}

        def fake(**kwargs):
            received.update(kwargs)
            return EnrichSummary("m", "ollama", total=0, enriched=0, facts=0, failed=0)

        with patch("garage_rag.ops.facts.enrich_facts", side_effect=fake):
            list(client.enrich_facts(EnrichFactsRequest()))
        assert received["prompts"] is None and received["stale_only"] is False

    def test_backfill_streams_over_a_real_channel(self) -> None:
        stop = threading.Event()
        server, _ = create_grpc_server(host="127.0.0.1", port=0, stop_event=stop)
        port = server.add_insecure_port("127.0.0.1:0")
        server.start()
        try:
            with (
                patch("garage_rag.ops.backfill.backfill", side_effect=_fake_backfill),
                grpc.insecure_channel(f"127.0.0.1:{port}") as channel,
            ):
                statuses = list(GarageServiceStub(channel).Backfill(BackfillRequest(model="m")))
            assert [s.phase for s in statuses] == ["started", "progress", "finished"]
        finally:
            server.stop(grace=None)

    def test_cancelling_the_call_stops_the_operation(self) -> None:
        """Cancel in the app has to stop the work, as killing `garage backfill` did."""
        reported: list[int] = []
        stopped = threading.Event()
        first_seen = threading.Event()

        def endless(model=None, *, on_event, **_kwargs):
            try:
                for batch in range(1, 10_000):
                    on_event(BackfillEvent("m", "progress", total=10_000, embedded=batch, batches=batch))
                    reported.append(batch)
                    first_seen.wait(timeout=5)
                    time.sleep(0.01)
            finally:
                stopped.set()
            return []

        stop = threading.Event()
        server, _ = create_grpc_server(host="127.0.0.1", port=0, stop_event=stop)
        port = server.add_insecure_port("127.0.0.1:0")
        server.start()
        try:
            with (
                patch("garage_rag.ops.backfill.backfill", side_effect=endless),
                grpc.insecure_channel(f"127.0.0.1:{port}") as channel,
            ):
                call = GarageServiceStub(channel).Backfill(BackfillRequest(model="m"))
                assert next(call).phase == "progress"
                first_seen.set()
                call.cancel()
                assert stopped.wait(timeout=5), "the operation kept running after the call was cancelled"
            assert len(reported) < 10_000
        finally:
            server.stop(grace=None)


class TestFactPrompts:
    def test_lists_the_built_in_default_without_configuration(self, client: GarageClient) -> None:
        set_settings(Settings())
        try:
            response = client.list_fact_prompts()
        finally:
            reset_settings()
        assert [p.name for p in response.prompts] == ["default"]
        default = response.prompts[0]
        assert default.builtin and default.enabled and not default.customized
        assert default.description.startswith("Extract every standalone fact")
        assert json.loads(default.examples_json)[0]["extractions"][0]["class"] == "fact"
        assert len(default.sha256) == 64
        assert json.loads(response.configured_json) == []

    def test_set_setting_writes_prompts_the_list_then_reflects(self, client: GarageClient, tmp_path: Path) -> None:
        config = tmp_path / "garage.json"
        prompts = [
            {"name": "default", "enabled": False},
            {
                "name": "people",
                "description": "List every person named.",
                "examples": [{"text": "Jane met Bob.", "extractions": [{"class": "person", "text": "Jane"}]}],
            },
        ]
        try:
            client.set_setting("facts.prompts", json.dumps(prompts), path=str(config))
            response = client.list_fact_prompts()
        finally:
            reset_settings()
        assert [(p.name, p.enabled, p.builtin, p.customized) for p in response.prompts] == [
            ("default", False, True, True),
            ("people", True, False, False),
        ]
        assert [entry["name"] for entry in json.loads(response.configured_json)] == ["default", "people"]
        assert json.loads(config.read_text())["facts"]["prompts"][0] == {
            "name": "default",
            "corpus_classes": [],
            "sources": [],
            "enabled": False,
        }

    def test_an_invalid_prompt_list_is_refused(self, client: GarageClient, tmp_path: Path) -> None:
        config = tmp_path / "garage.json"
        with pytest.raises(RuntimeError, match="INVALID_ARGUMENT"):
            client.set_setting("facts.prompts", json.dumps([{"name": "x", "description": "d"}]), path=str(config))
        assert not config.exists()


class TestSettings:
    def test_set_then_get_round_trips(self, client: GarageClient, tmp_path: Path) -> None:
        config = tmp_path / "garage.json"
        res = client.set_setting("facts.model", "phi-4-mini", path=str(config))
        assert res.path == str(config)
        assert json.loads(res.value_json) == "phi-4-mini"
        assert json.loads(client.get_setting("facts.model").value_json) == "phi-4-mini"

    def test_unknown_setting_is_invalid_argument(self, client: GarageClient, tmp_path: Path) -> None:
        with pytest.raises(RuntimeError, match="INVALID_ARGUMENT"):
            client.set_setting("facts.nope", "x", path=str(tmp_path / "garage.json"))


class TestMcp:
    def test_install_dry_run_into_a_custom_file(self, client: GarageClient, tmp_path: Path) -> None:
        target = tmp_path / "mcp.json"
        res = client.mcp_install(McpInstallRequest(path=str(target), host="127.0.0.1", port=8787, dry_run=True))
        assert res.url == "http://127.0.0.1:8787/mcp"
        assert len(res.outcomes) == 1
        preview = json.loads(res.outcomes[0].preview_json)
        assert preview["mcpServers"]["garage-rag"]["url"] == "http://127.0.0.1:8787/mcp"
        assert not target.exists()

    def test_install_writes_without_prompting(self, client: GarageClient, tmp_path: Path) -> None:
        target = tmp_path / "mcp.json"
        res = client.mcp_install(McpInstallRequest(path=str(target), host="127.0.0.1", port=8787))
        assert res.outcomes[0].written and res.outcomes[0].created_file
        assert "garage-rag" in json.loads(target.read_text())["mcpServers"]

    def test_status_lists_known_clients(self, client: GarageClient) -> None:
        res = client.mcp_status()
        assert res.server_command
        assert "project" in [c.key for c in res.clients]

    def test_uninstall_removes_the_entry_then_reports_it_gone(self, client: GarageClient, tmp_path: Path) -> None:
        target = tmp_path / "mcp.json"
        client.mcp_install(McpInstallRequest(path=str(target), host="127.0.0.1", port=8787))

        res = client.mcp_uninstall(McpUninstallRequest(path=str(target)))
        assert res.removed
        assert res.path == str(target.resolve())
        assert res.message == f"removed garage-rag from {target.resolve()}"
        assert "garage-rag" not in json.loads(target.read_text()).get("mcpServers", {})

        again = client.mcp_uninstall(McpUninstallRequest(path=str(target)))
        assert not again.removed
        assert again.message == f"garage-rag was not configured in {target.resolve()}"

    def test_uninstall_passes_name_and_target(self, client: GarageClient, tmp_path: Path) -> None:
        with patch("garage_rag.ops.mcp.uninstall_mcp_server", return_value=(tmp_path / "c.json", True)) as op:
            res = client.mcp_uninstall(McpUninstallRequest(target="claude-desktop", name="garage-dev"))
        op.assert_called_once_with(target="claude-desktop", path=None, name="garage-dev")
        assert res.removed and res.message.startswith("removed garage-dev from")

    def test_uninstall_unknown_target_is_invalid_argument(self, client: GarageClient) -> None:
        with pytest.raises(RuntimeError, match="INVALID_ARGUMENT"):
            client.mcp_uninstall(McpUninstallRequest(target="no-such-client"))


class TestModelDefaults:
    def test_set_default_model(self, client: GarageClient) -> None:
        with patch("garage_rag.ops.models.set_default_model") as op:
            res = client.set_default_model("bge-m3")
        op.assert_called_once_with("bge-m3")
        assert res.message == "default model = bge-m3"

    def test_set_default_to_an_unknown_model_is_not_found(self, client: GarageClient) -> None:
        with (
            patch("garage_rag.ops.models.set_default_model", side_effect=LookupError("no model 'x' registered")),
            pytest.raises(RuntimeError, match="NOT_FOUND"),
        ):
            client.set_default_model("x")


class TestInitDb:
    def test_lists_what_it_applied_and_redacts_the_url(self, client: GarageClient, tmp_path: Path) -> None:
        set_settings(Settings(database_url="postgresql+psycopg://rick:s3cret@localhost:5432/garage"))
        with patch(
            "garage_rag.db.migrate.apply_migrations", return_value=["001_extensions.sql", "013_fact_prompts.sql"]
        ) as op:
            res = client.init_db(schema_dir=str(tmp_path))
        op.assert_called_once_with(schema_dir=tmp_path)
        assert list(res.applied) == ["001_extensions.sql", "013_fact_prompts.sql"]
        assert res.message.splitlines()[:2] == ["applied 001_extensions.sql", "applied 013_fact_prompts.sql"]
        assert res.message.splitlines()[-1].startswith("schema ready (")
        assert "s3cret" not in res.message

    def test_default_schema_dir_and_nothing_pending(self, client: GarageClient) -> None:
        set_settings(Settings())
        with patch("garage_rag.db.migrate.apply_migrations", return_value=[]) as op:
            res = client.init_db()
        op.assert_called_once_with(schema_dir=None)
        assert list(res.applied) == []
        assert res.message.startswith("schema ready (")


class TestReconcile:
    def _reconcile(self, client: GarageClient, result: ReconcileResult, **request):
        with (
            patch("garage_rag.db.engine.session_scope"),
            patch("garage_rag.ingest.reconcile.reconcile_source", return_value=result) as op,
        ):
            res = client.reconcile(ReconcileRequest(source="notes", **request))
        return res, op

    def test_dry_run_counts_what_is_missing(self, client: GarageClient) -> None:
        res, op = self._reconcile(client, ReconcileResult(source="notes", candidates=5, total_documents=200))
        assert op.call_args.args[1] == "notes"
        assert op.call_args.kwargs == {"dry_run": True, "force": False}
        assert (res.candidates, res.total_documents, res.deleted) == (5, 200, 0)
        assert res.fraction == pytest.approx(0.025)
        assert res.message == "dry run: 5 of 200 documents in notes are missing (2.5%)"

    def test_apply_deletes(self, client: GarageClient) -> None:
        res, op = self._reconcile(
            client, ReconcileResult(source="notes", candidates=5, deleted=5, total_documents=200), apply=True
        )
        assert op.call_args.kwargs == {"dry_run": False, "force": False}
        assert res.deleted == 5
        assert res.message == "deleted 5 of 200 documents from notes"

    def test_nothing_to_reconcile(self, client: GarageClient) -> None:
        res, _ = self._reconcile(client, ReconcileResult(source="notes", total_documents=200))
        assert res.message == "nothing to reconcile for notes"

    def test_refusal_is_reported_not_raised(self, client: GarageClient) -> None:
        refused = ReconcileResult(
            source="notes", candidates=180, total_documents=200, refused=True, reason="90% missing"
        )
        res, op = self._reconcile(client, refused, apply=True, force=True)
        assert op.call_args.kwargs == {"dry_run": False, "force": True}
        assert res.refused and res.reason == "90% missing"
        assert res.message == "refused: 90% missing"

    def test_unknown_source_is_not_found(self, client: GarageClient) -> None:
        with (
            patch("garage_rag.db.engine.session_scope"),
            patch("garage_rag.ingest.reconcile.reconcile_source", side_effect=LookupError("no such source: nope")),
            pytest.raises(RuntimeError, match="NOT_FOUND"),
        ):
            client.reconcile(ReconcileRequest(source="nope"))

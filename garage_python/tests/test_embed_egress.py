"""Embedding never posts a communication to a provider that is not on this machine.

Embedding a chunk sends its text to the model's provider. ``llama_xpc`` is
loopback by construction; ``ollama``/``lmstudio`` are local only while their
host is (the egress guard's ``allows_communications``). When one is pointed
off-box, backfill (in-process and through the embed worker's
GetEmbeddingBatches) must leave communication chunks out.
"""

from __future__ import annotations

from unittest.mock import MagicMock, patch

import pytest

from garage_rag.config import Settings, reset_settings, set_settings
from garage_rag.embed.factory import provider_is_local
from garage_rag.embed.ollama import backfill_model, pending_chunks_sql
from garage_rag.proto.garage_pb2 import GetEmbeddingBatchesRequest
from garage_rag.service.server import GarageRpcServicer

COMMUNICATION_FILTER = "d.corpus_class = 'communication'"


@pytest.fixture(autouse=True)
def _fresh_settings():
    yield
    reset_settings()


def _off_box(**overrides) -> Settings:
    """Settings with an off-box model server."""
    return Settings(**overrides)


def _model(provider: str = "ollama") -> MagicMock:
    model = MagicMock()
    model.slug = "m"
    model.provider = provider
    model.model_ref = "nomic-embed-text"
    model.table_name = "emb_m"
    model.dims = 3
    model.stored_dims = 3
    model.storage_kind = "vector"
    model.index_kind = "hnsw"
    return model


class TestProviderIsLocal:
    def test_llama_xpc_is_always_local(self) -> None:
        set_settings(Settings(llama_host="http://127.0.0.1:8790"))
        assert provider_is_local("llama_xpc")

    def test_default_hosts_are_local(self) -> None:
        set_settings(Settings())
        assert provider_is_local("ollama")
        assert provider_is_local("lmstudio")

    @pytest.mark.parametrize(
        ("field", "host", "provider"),
        [
            ("ollama_host", "http://gpu-box:11434", "ollama"),
            ("ollama_host", "10.0.0.5:11434", "ollama"),
            ("lmstudio_host", "https://lmstudio.example.com/v1", "lmstudio"),
        ],
    )
    def test_off_box_hosts_are_remote(self, field: str, host: str, provider: str) -> None:
        set_settings(_off_box(**{field: host}))
        assert not provider_is_local(provider)

    def test_bare_loopback_host_port_is_local(self) -> None:
        """Ollama accepts `localhost:11434` without a scheme; that is still this machine."""
        set_settings(Settings(ollama_host="localhost:11434"))
        assert provider_is_local("ollama")

    def test_unknown_provider_counts_as_remote(self) -> None:
        assert not provider_is_local("somecloud")


class TestPendingQuery:
    def test_off_box_query_leaves_out_communications(self) -> None:
        sql = pending_chunks_sql("emb_m", select="c.id, c.text", include_communications=False)
        assert COMMUNICATION_FILTER in sql
        assert "NOT EXISTS" in sql

    def test_local_query_includes_everything(self) -> None:
        sql = pending_chunks_sql("emb_m", select="count(*)", include_communications=True)
        assert "communication" not in sql


class TestBackfill:
    def _run(self, model: MagicMock, counts: list[int]):
        embedder = MagicMock()
        embedder.embed.return_value = [[0.1, 0.2, 0.3]]
        batches = MagicMock(return_value=iter([[(1, "a document chunk")]]))
        with (
            patch("garage_rag.embed.factory.get_embedder", return_value=embedder),
            patch("garage_rag.embed.ollama.count_pending", side_effect=counts) as count,
            patch("garage_rag.embed.ollama._pending_chunk_batches", batches),
            # Distilled facts are embedded against the database; test_postgres.py covers them.
            patch("garage_rag.embed.ollama.backfill_distilled"),
        ):
            state = backfill_model(MagicMock(), model)
        return state, batches, count

    def test_off_box_provider_withholds_communication_chunks(self) -> None:
        set_settings(_off_box(ollama_host="http://gpu-box:11434"))
        state, batches, count = self._run(_model("ollama"), counts=[1, 3])

        assert batches.call_args.kwargs["include_communications"] is False
        assert count.call_args_list[0].kwargs == {"include_communications": False}
        assert state.total == 1
        assert state.withheld == 2
        assert state.embedded == 1

    def test_local_provider_embeds_everything(self) -> None:
        set_settings(Settings())
        state, batches, count = self._run(_model("ollama"), counts=[3])

        assert batches.call_args.kwargs["include_communications"] is True
        assert count.call_count == 1
        assert state.withheld == 0


class TestEmbedWorkerBatches:
    """The XPC embed worker gets its texts from GetEmbeddingBatches."""

    def _batches_sql(self, provider: str) -> str:
        session = MagicMock()
        session.execute.return_value.all.return_value = []
        with (
            patch("garage_rag.db.engine.session_scope") as scope,
            patch("garage_rag.db.emb_tables.get_model", return_value=_model(provider)),
            patch("garage_rag.embed.ollama.count_pending", return_value=0),
        ):
            scope.return_value.__enter__.return_value = session
            GarageRpcServicer().GetEmbeddingBatches(GetEmbeddingBatchesRequest(model_slug="m"), MagicMock())
        return str(session.execute.call_args.args[0])

    def test_off_box_provider_gets_no_communications(self) -> None:
        set_settings(_off_box(lmstudio_host="https://lmstudio.example.com/v1"))
        assert COMMUNICATION_FILTER in self._batches_sql("lmstudio")

    def test_local_provider_gets_everything(self) -> None:
        set_settings(Settings())
        assert "communication" not in self._batches_sql("llama_xpc")

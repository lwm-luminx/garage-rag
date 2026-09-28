"""Tests for dedicated RPC functions on GarageRpcServicer and GarageClient."""

from __future__ import annotations

from unittest.mock import patch

import pytest

from garage_rag.proto.garage_pb2 import ChunkEmbeddingItem, UpdateEmbeddingsRequest
from garage_rag.service.client import GarageClient


def test_dedicated_rpc_ping():
    client = GarageClient(in_process=True)
    res = client.ping("hello")
    assert res.message == "hello"
    assert res.timestamp > 0


def test_dedicated_rpc_version():
    client = GarageClient(in_process=True)
    res = client.get_version()
    assert res.version == "1.5.0"


def test_dedicated_rpc_status():
    client = GarageClient(in_process=True)
    # GetStatus probes the database (SELECT 1 + pending-migration check); mock that
    # boundary so readiness does not depend on a live Postgres.
    with (
        patch("garage_rag.db.engine.get_engine"),
        patch("garage_rag.db.migrate.has_pending_migrations", return_value=False),
    ):
        res = client.get_status()
    assert res.is_ready is True
    assert res.db_status == "connected"
    assert res.version == "1.5.0"


def test_dedicated_rpc_status_not_ready_when_migrations_pending():
    client = GarageClient(in_process=True)
    with (
        patch("garage_rag.db.engine.get_engine"),
        patch("garage_rag.db.migrate.has_pending_migrations", return_value=True),
    ):
        res = client.get_status()
    assert res.is_ready is False
    assert res.db_status == "needs_migration"


def test_dedicated_rpc_status_not_ready_when_db_unreachable():
    client = GarageClient(in_process=True)
    with patch("garage_rag.db.engine.get_engine", side_effect=RuntimeError("no database")):
        res = client.get_status()
    assert res.is_ready is False
    assert res.db_status.startswith("error:")
    assert "no database" in res.db_status


def test_model_info_proto_model_id():
    from garage_rag.proto.garage_pb2 import ModelInfo

    m = ModelInfo(
        slug="test-slug",
        provider="ollama",
        model_ref="test-ref",
        dims=1024,
        stored_dims=1024,
        storage_kind="vector",
        index_kind="hnsw",
        table_name="emb_test_slug",
        is_default=False,
        model_id="test-org/test-slug",
    )
    assert m.model_id == "test-org/test-slug"


def test_source_info_proto_document_count():
    from garage_rag.proto.garage_pb2 import SourceInfo

    s = SourceInfo(
        slug="test-source",
        kind="filesystem",
        corpus_class="document",
        trust_tier="authored",
        enabled=True,
        root="/path/to/source",
        document_count=42,
    )
    assert s.slug == "test-source"
    assert s.document_count == 42


def test_dedicated_rpc_update_embeddings_unknown_model_aborts_not_found():
    """UpdateEmbeddings aborts NOT_FOUND for an unregistered model (in-process context raises)."""
    client = GarageClient(in_process=True)
    req = UpdateEmbeddingsRequest(
        model_slug="missing",
        embeddings=[ChunkEmbeddingItem(chunk_id=1, vector=[0.1, 0.2])],
    )
    with (
        patch("garage_rag.db.engine.session_scope"),
        patch("garage_rag.db.emb_tables.get_model", side_effect=LookupError("no model 'missing' registered")),
        pytest.raises(RuntimeError, match="NOT_FOUND"),
    ):
        client.update_embeddings(req)


def test_dedicated_rpc_update_embeddings_db_error_propagates():
    """Anything other than a missing model is not swallowed into a soft failure."""
    client = GarageClient(in_process=True)
    req = UpdateEmbeddingsRequest(model_slug="bge-m3")
    with (
        patch("garage_rag.db.engine.session_scope"),
        patch("garage_rag.db.emb_tables.get_model", side_effect=RuntimeError("connection refused")),
        pytest.raises(RuntimeError, match="connection refused"),
    ):
        client.update_embeddings(req)

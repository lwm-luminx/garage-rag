"""Tests for embedding batch retrieval, update embeddings RPCs, and gRPC embedding proxy."""

from __future__ import annotations

import threading
from unittest.mock import MagicMock, patch

import pytest

from garage_rag.embed.xpc import embed_via_grpc
from garage_rag.proto.garage_pb2 import (
    ChunkEmbeddingItem,
    EmbeddingChunkItem,
    GetEmbeddingBatchesRequest,
    GetEmbeddingBatchesResponse,
    UpdateEmbeddingsRequest,
    UpdateEmbeddingsResponse,
)
from garage_rag.service.client import GarageClient
from garage_rag.service.server import GarageRpcServicer, create_grpc_server


@pytest.fixture
def grpc_server():
    """Start an in-memory / local gRPC server on an ephemeral port."""
    stop_event = threading.Event()
    server, servicer = create_grpc_server(host="127.0.0.1", port=0, stop_event=stop_event)
    bound_port = server.add_insecure_port("127.0.0.1:0")
    server.start()
    yield bound_port, servicer
    server.stop(grace=None)


def test_servicer_get_embedding_batches_and_update():
    servicer = GarageRpcServicer()
    mock_context = MagicMock()

    mock_model = MagicMock()
    mock_model.slug = "test-model"
    mock_model.table_name = "emb_test_model"
    mock_model.provider = "fastembed"
    mock_model.model_ref = "mxbai-embed-xsmall"
    mock_model.dims = 384
    mock_model.stored_dims = 384
    mock_model.storage_kind = "vector"
    mock_model.index_kind = "hnsw"

    with (
        patch("garage_rag.db.engine.session_scope") as mock_scope,
        patch("garage_rag.db.emb_tables.get_model", return_value=mock_model),
        patch("garage_rag.embed.ollama.count_pending", return_value=2),
        patch("garage_rag.embed.ollama.assert_safe_table", return_value="emb_test_model"),
        patch("garage_rag.embed.ollama._plan_from_row"),
        patch("garage_rag.embed.ollama._adapt", side_effect=lambda v, p: v),
    ):
        mock_session = MagicMock()
        mock_scope.return_value.__enter__.return_value = mock_session
        mock_session.execute.return_value.all.return_value = [(10, "Hello chunk 1"), (11, "Hello chunk 2")]

        # 1. Test GetEmbeddingBatches
        get_req = GetEmbeddingBatchesRequest(model_slug="test-model", batch_size=64, limit=100)
        get_resp = servicer.GetEmbeddingBatches(get_req, mock_context)

        assert get_resp.model_slug == "test-model"
        assert get_resp.table_name == "emb_test_model"
        assert get_resp.dims == 384
        assert len(get_resp.chunks) == 2
        assert get_resp.chunks[0].chunk_id == 10
        assert get_resp.chunks[0].text == "Hello chunk 1"
        assert get_resp.chunks[1].chunk_id == 11
        assert get_resp.chunks[1].text == "Hello chunk 2"
        assert get_resp.has_more is False

        # 2. Test UpdateEmbeddings
        items = [
            ChunkEmbeddingItem(chunk_id=10, vector=[0.1, 0.2, 0.3]),
            ChunkEmbeddingItem(chunk_id=11, vector=[0.4, 0.5, 0.6]),
        ]
        up_req = UpdateEmbeddingsRequest(model_slug="test-model", embeddings=items)
        # Chunk 10 is a content chunk; chunk 11 is potential fact 7's.
        mock_session.execute.reset_mock()
        mock_session.execute.return_value.all.return_value = [(10, None), (11, 7)]
        up_resp = servicer.UpdateEmbeddings(up_req, mock_context)

        assert up_resp.success is True
        assert up_resp.count == 2
        lookup, content, fact = mock_session.execute.call_args_list
        assert "INSERT INTO emb_test_model (chunk_id" in str(content.args[0])
        assert [row["key"] for row in content.args[1]] == [10]
        assert "INSERT INTO potential_fact_emb_test_model (fact_id" in str(fact.args[0])
        assert [row["key"] for row in fact.args[1]] == [7]


def test_embed_via_grpc_workflow():
    mock_client = MagicMock(spec=GarageClient)

    # First batch returns 2 chunks, second batch returns empty (finished)
    batch_1 = GetEmbeddingBatchesResponse(
        model_slug="mxbai-embed-xsmall",
        table_name="emb_mxbai_embed_xsmall",
        provider="fastembed",
        model_ref="mxbai-embed-xsmall",
        dims=3,
        total_pending=2,
        chunks=[
            EmbeddingChunkItem(chunk_id=1, text="Text one"),
            EmbeddingChunkItem(chunk_id=2, text="Text two"),
        ],
        has_more=False,
    )

    mock_client.get_embedding_batches.return_value = batch_1
    mock_client.update_embeddings.return_value = UpdateEmbeddingsResponse(success=True, count=2)

    mock_embedder = MagicMock()
    mock_embedder.embed.return_value = [
        [0.1, 0.2, 0.3],
        [0.4, 0.5, 0.6],
    ]

    with (
        patch("garage_rag.service.client.GarageClient", return_value=mock_client),
        patch("garage_rag.embed.xpc.get_embedder", return_value=mock_embedder) as mock_get_embedder,
    ):
        result = embed_via_grpc(
            model_slug="mxbai-embed-xsmall",
            batch_size=10,
            grpc_host="127.0.0.1",
            grpc_port=50051,
        )

        assert result["status"] == "ok"
        assert result["count"] == 2
        mock_get_embedder.assert_called_once_with("fastembed", "mxbai-embed-xsmall")
        mock_embedder.embed.assert_called_once_with(["Text one", "Text two"])
        mock_client.update_embeddings.assert_called_once()
        update_call_arg = mock_client.update_embeddings.call_args[0][0]
        assert update_call_arg.model_slug == "mxbai-embed-xsmall"
        assert len(update_call_arg.embeddings) == 2
        assert update_call_arg.embeddings[0].chunk_id == 1
        assert list(update_call_arg.embeddings[0].vector) == pytest.approx([0.1, 0.2, 0.3])


def test_embed_via_live_grpc_server(grpc_server):
    port, servicer = grpc_server

    mock_model = MagicMock()
    mock_model.slug = "test-live-model"
    mock_model.table_name = "emb_test_live_model"
    mock_model.provider = "fastembed"
    mock_model.model_ref = "mxbai-embed-xsmall"
    mock_model.dims = 3
    mock_model.stored_dims = 3
    mock_model.storage_kind = "vector"
    mock_model.index_kind = "hnsw"

    call_count = 0

    def fake_execute(stmt, *args, **kwargs):
        nonlocal call_count
        call_count += 1
        res = MagicMock()
        if call_count == 1:
            res.all.return_value = [(1, "Text one"), (2, "Text two")]
        else:
            res.all.return_value = []
        return res

    mock_session = MagicMock()
    mock_session.execute.side_effect = fake_execute

    mock_embedder = MagicMock()
    mock_embedder.embed.return_value = [
        [0.1, 0.2, 0.3],
        [0.4, 0.5, 0.6],
    ]

    with (
        patch("garage_rag.db.engine.session_scope") as mock_scope,
        patch("garage_rag.db.emb_tables.get_model", return_value=mock_model),
        patch("garage_rag.embed.ollama.count_pending", side_effect=[2, 0]),
        patch("garage_rag.embed.ollama.assert_safe_table", return_value="emb_test_live_model"),
        patch("garage_rag.embed.ollama._plan_from_row"),
        patch("garage_rag.embed.ollama._adapt", side_effect=lambda v, p: v),
        patch("garage_rag.embed.xpc.get_embedder", return_value=mock_embedder),
    ):
        mock_scope.return_value.__enter__.return_value = mock_session

        result = embed_via_grpc(
            model_slug="test-live-model",
            batch_size=10,
            grpc_host="127.0.0.1",
            grpc_port=port,
        )

        assert result["status"] == "ok"
        assert result["count"] == 2
        mock_embedder.embed.assert_called_once_with(["Text one", "Text two"])

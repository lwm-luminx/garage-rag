"""XPC and proxy embedding pipeline that interacts solely via gRPC service (no DB connection)."""

from __future__ import annotations

import logging
from typing import Any

from garage_rag.embed.base import EmbeddingError
from garage_rag.embed.factory import get_embedder
from garage_rag.proto.garage_pb2 import (
    ChunkEmbeddingItem,
    GetEmbeddingBatchesRequest,
    UpdateEmbeddingsRequest,
)

logger = logging.getLogger(__name__)


def embed_via_grpc(
    model_slug: str | None = None,
    limit: int | None = None,
    batch_size: int | None = None,
    grpc_host: str = "127.0.0.1",
    grpc_port: int = 50051,
    grpc_socket: str | None = None,
) -> dict[str, Any]:
    """Fetch unembedded chunks via gRPC, compute embeddings locally, and persist vectors via gRPC.

    Zero direct database access is used in this workflow.
    """
    # Imported here, not at module scope: garage_rag.service depends on search,
    # which depends on embed, so a top-level import would be a cycle.
    # gazelle:ignore garage_rag.service.client
    from garage_rag.service.client import GarageClient

    # GarageClient opens a gRPC channel on first use; close it on the way out,
    # including on error. (try/finally rather than ``with`` so a spec'd mock
    # client in tests is the object the loop actually talks to.)
    client = GarageClient(host=grpc_host, port=grpc_port, in_process=False, socket_path=grpc_socket)
    try:
        total_embedded = _embed_loop(client, model_slug=model_slug, limit=limit, batch_size=batch_size)
    finally:
        client.close()

    return {
        "status": "ok",
        "count": total_embedded,
        "message": f"Successfully embedded {total_embedded} chunk(s) via gRPC proxy",
    }


def _embed_loop(client: Any, *, model_slug: str | None, limit: int | None, batch_size: int | None) -> int:
    """Fetch, embed and write back batches until the service reports none left."""
    b_size = batch_size if batch_size and batch_size > 0 else 64
    remaining_limit = limit if limit and limit > 0 else None

    total_embedded = 0
    embedder = None
    loaded_model_key = None

    while True:
        current_batch_size = b_size
        if remaining_limit is not None:
            if remaining_limit <= 0:
                break
            current_batch_size = min(b_size, remaining_limit)

        req = GetEmbeddingBatchesRequest(
            model_slug=model_slug or "",
            batch_size=current_batch_size,
            limit=current_batch_size,
        )
        resp = client.get_embedding_batches(req)
        if not resp.chunks:
            break

        provider = resp.provider
        model_ref = resp.model_ref
        model_key = (provider, model_ref)
        if embedder is None or loaded_model_key != model_key:
            embedder = get_embedder(provider, model_ref)
            loaded_model_key = model_key

        texts = [chunk.text for chunk in resp.chunks]
        vectors = embedder.embed(texts)
        if len(vectors) != len(resp.chunks):
            raise EmbeddingError(
                f"{model_ref} returned {len(vectors)} vectors for {len(resp.chunks)} chunks; refusing to write"
            )

        items = [
            ChunkEmbeddingItem(chunk_id=chunk.chunk_id, vector=[float(x) for x in vec])
            for chunk, vec in zip(resp.chunks, vectors, strict=True)
        ]

        update_req = UpdateEmbeddingsRequest(
            model_slug=resp.model_slug,
            embeddings=items,
        )
        update_resp = client.update_embeddings(update_req)
        if not update_resp.success:
            raise RuntimeError(f"Failed to update embeddings via gRPC: {update_resp.error}")

        total_embedded += len(items)
        if remaining_limit is not None:
            remaining_limit -= len(items)

        if not resp.has_more or len(resp.chunks) < current_batch_size:
            break

    return total_embedded

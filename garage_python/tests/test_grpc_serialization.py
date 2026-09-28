"""Tests for the GarageClient in-process mode and proto round-tripping."""

from __future__ import annotations

from unittest.mock import patch

from garage_rag.proto.garage_pb2 import SearchRequest
from garage_rag.service.client import GarageClient


def test_dedicated_protobuf_messages():
    """Verify dedicated request and response protobufs serialize and deserialize properly."""
    search_req = SearchRequest(
        query="neural network",
        limit=5,
        mode="hybrid",
        model="bge-m3",
        corpus_classes=["document", "code"],
        trust_tiers=["authored"],
        sources=["docs"],
        author="rick",
        full=True,
        direction="received",
    )
    serialized = search_req.SerializeToString()
    deserialized = SearchRequest()
    deserialized.ParseFromString(serialized)
    assert deserialized.query == "neural network"
    assert deserialized.limit == 5
    assert deserialized.mode == "hybrid"
    assert deserialized.model == "bge-m3"
    assert list(deserialized.corpus_classes) == ["document", "code"]
    assert list(deserialized.trust_tiers) == ["authored"]
    assert list(deserialized.sources) == ["docs"]
    assert deserialized.author == "rick"
    assert deserialized.full is True
    assert deserialized.direction == "received"


def test_client_in_process_version():
    """Verify GarageClient.get_version() runs in-process with protobuf serialization."""
    client = GarageClient(in_process=True)
    resp = client.get_version()
    assert resp.version
    assert len(resp.version) > 0


def test_client_in_process_ping():
    """Verify GarageClient.ping() returns pong and timestamp."""
    client = GarageClient(in_process=True)
    resp = client.ping("test ping")
    assert resp.message == "test ping"
    assert resp.timestamp > 0


def test_client_in_process_status():
    """Verify GarageClient.get_status() returns server details."""
    client = GarageClient(in_process=True)
    # Readiness is derived from a live DB probe; mock that boundary.
    with (
        patch("garage_rag.db.engine.get_engine"),
        patch("garage_rag.db.migrate.has_pending_migrations", return_value=False),
    ):
        resp = client.get_status()
    assert resp.is_ready is True
    assert resp.pid > 0
    assert resp.version


def test_client_close_is_idempotent_and_context_managed():
    """close() releases the channel; the client is usable as a context manager."""
    with GarageClient(host="127.0.0.1", port=1, in_process=False) as client:
        stub = client._get_stub()
        assert stub is client._get_stub()
        assert client._channel is not None
    assert client._channel is None
    assert client._stub is None
    client.close()  # second close is a no-op

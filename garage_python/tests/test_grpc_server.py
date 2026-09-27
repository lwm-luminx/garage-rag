"""Tests for gRPC Server and live dedicated RPC calls."""

from __future__ import annotations

import threading
from unittest.mock import patch

import grpc
import pytest

from garage_rag.proto.garage_pb2 import (
    BackfillRequest,
    EnsureLlamaModelRequest,
    GetEmbeddingBatchesRequest,
    PingRequest,
    SetSettingRequest,
    StatusRequest,
    VersionRequest,
)
from garage_rag.proto.garage_pb2_grpc import GarageServiceStub
from garage_rag.service.auth import CONFIG_CHANGING_METHODS, METADATA_KEY, TOKEN_ENV, config_change_allowed
from garage_rag.service.client import GarageClient
from garage_rag.service.server import GarageRpcServicer, create_grpc_server

TOKEN = "0123456789abcdef" * 4


@pytest.fixture
def grpc_server(monkeypatch):
    """Start an in-memory / local gRPC server on an ephemeral port."""
    monkeypatch.delenv(TOKEN_ENV, raising=False)
    stop_event = threading.Event()
    # Port 0 lets OS assign an ephemeral available port
    server, servicer = create_grpc_server(host="127.0.0.1", port=0, stop_event=stop_event)
    bound_port = server.add_insecure_port("127.0.0.1:0")
    server.start()
    yield bound_port, servicer
    server.stop(grace=None)


def test_grpc_ping(grpc_server):
    port, _ = grpc_server
    with grpc.insecure_channel(f"127.0.0.1:{port}") as channel:
        stub = GarageServiceStub(channel)
        response = stub.Ping(PingRequest(message="hello garage"))
        assert response.message == "hello garage"
        assert response.timestamp > 0


def test_grpc_get_status(grpc_server):
    port, _ = grpc_server
    # The servicer runs in this process, so patching the DB boundary here applies to it.
    with (
        patch("garage_rag.db.engine.get_engine"),
        patch("garage_rag.db.migrate.has_pending_migrations", return_value=False),
        grpc.insecure_channel(f"127.0.0.1:{port}") as channel,
    ):
        stub = GarageServiceStub(channel)
        response = stub.GetStatus(StatusRequest())
        assert response.is_ready is True
        assert response.db_status == "connected"
        assert response.server_type == "grpc"
        assert response.pid > 0
        assert len(response.version) > 0


def test_grpc_get_version(grpc_server):
    port, _ = grpc_server
    with grpc.insecure_channel(f"127.0.0.1:{port}") as channel:
        stub = GarageServiceStub(channel)
        response = stub.GetVersion(VersionRequest())
        assert response.version
        assert len(response.version) > 0


def test_grpc_get_embedding_batches_unknown_model_is_not_found(grpc_server):
    """An unregistered model aborts with NOT_FOUND instead of an empty OK response."""
    port, _ = grpc_server
    with (
        patch("garage_rag.db.engine.session_scope"),
        patch("garage_rag.db.emb_tables.get_model", side_effect=LookupError("no model 'nope' registered")),
        grpc.insecure_channel(f"127.0.0.1:{port}") as channel,
    ):
        stub = GarageServiceStub(channel)
        with pytest.raises(grpc.RpcError) as excinfo:
            stub.GetEmbeddingBatches(GetEmbeddingBatchesRequest(model_slug="nope", batch_size=8))
    assert excinfo.value.code() == grpc.StatusCode.NOT_FOUND
    assert "nope" in excinfo.value.details()


def test_grpc_get_embedding_batches_db_outage_is_an_error(grpc_server):
    """A database failure must surface as an RPC error, not as "nothing pending"."""
    port, _ = grpc_server
    with (
        patch("garage_rag.db.engine.session_scope", side_effect=RuntimeError("connection refused")),
        grpc.insecure_channel(f"127.0.0.1:{port}") as channel,
    ):
        stub = GarageServiceStub(channel)
        with pytest.raises(grpc.RpcError) as excinfo:
            stub.GetEmbeddingBatches(GetEmbeddingBatchesRequest(model_slug="bge-m3"))
    assert excinfo.value.code() != grpc.StatusCode.OK


# ---------------------------------------------------------------------------
# Per-launch token (GARAGE_GRPC_TOKEN / x-garage-token)
# ---------------------------------------------------------------------------


@pytest.fixture
def token_server(monkeypatch):
    """A server started with ``GARAGE_GRPC_TOKEN`` set, as the app starts it."""
    monkeypatch.setenv(TOKEN_ENV, TOKEN)
    server, _ = create_grpc_server(host="127.0.0.1", port=0, stop_event=threading.Event())
    port = server.add_insecure_port("127.0.0.1:0")
    server.start()
    yield port
    server.stop(grace=None)


def test_token_server_rejects_a_call_without_the_token(token_server):
    with grpc.insecure_channel(f"127.0.0.1:{token_server}") as channel, pytest.raises(grpc.RpcError) as excinfo:
        GarageServiceStub(channel).Ping(PingRequest(message="hi"))
    assert excinfo.value.code() == grpc.StatusCode.UNAUTHENTICATED


def test_token_server_rejects_a_wrong_token(token_server):
    with grpc.insecure_channel(f"127.0.0.1:{token_server}") as channel, pytest.raises(grpc.RpcError) as excinfo:
        GarageServiceStub(channel).Ping(PingRequest(message="hi"), metadata=[(METADATA_KEY, "nope")])
    assert excinfo.value.code() == grpc.StatusCode.UNAUTHENTICATED


def test_token_server_rejects_a_streaming_call_without_the_token(token_server):
    with grpc.insecure_channel(f"127.0.0.1:{token_server}") as channel, pytest.raises(grpc.RpcError) as excinfo:
        list(GarageServiceStub(channel).Backfill(BackfillRequest(model="m")))
    assert excinfo.value.code() == grpc.StatusCode.UNAUTHENTICATED


def test_token_server_accepts_the_token(token_server):
    with grpc.insecure_channel(f"127.0.0.1:{token_server}") as channel:
        response = GarageServiceStub(channel).Ping(PingRequest(message="hi"), metadata=[(METADATA_KEY, TOKEN)])
    assert response.message == "hi"


def test_token_server_lets_ensure_llama_model_through_without_the_token(token_server):
    """A stdio garage-mcp outside the app has no token but still asks the app to load its model."""
    with grpc.insecure_channel(f"127.0.0.1:{token_server}") as channel, pytest.raises(grpc.RpcError) as excinfo:
        GarageServiceStub(channel).EnsureLlamaModel(EnsureLlamaModelRequest(model="m"))
    # No loader is installed in this process, so the servicer itself answers.
    assert excinfo.value.code() == grpc.StatusCode.FAILED_PRECONDITION


def test_garage_client_sends_the_token_from_the_environment(token_server):
    client = GarageClient(host="127.0.0.1", port=token_server, in_process=False)
    try:
        assert client.ping("hi").message == "hi"
    finally:
        client.close()


def test_garage_client_without_the_token_is_rejected(token_server, monkeypatch):
    monkeypatch.delenv(TOKEN_ENV)
    client = GarageClient(host="127.0.0.1", port=token_server, in_process=False)
    try:
        with pytest.raises(grpc.RpcError) as excinfo:
            client.ping("hi")
    finally:
        client.close()
    assert excinfo.value.code() == grpc.StatusCode.UNAUTHENTICATED


def test_server_without_the_token_accepts_any_call(grpc_server):
    port, _ = grpc_server
    with grpc.insecure_channel(f"127.0.0.1:{port}") as channel:
        stub = GarageServiceStub(channel)
        assert stub.Ping(PingRequest(message="a")).message == "a"
        assert stub.Ping(PingRequest(message="b"), metadata=[(METADATA_KEY, "anything")]).message == "b"


# ---------------------------------------------------------------------------
# Config-changing methods (auth.CONFIG_CHANGING_METHODS)
# ---------------------------------------------------------------------------


def _set_setting(channel, metadata=None):
    return GarageServiceStub(channel).SetSetting(SetSettingRequest(name="facts.model", value="m"), metadata=metadata)


def test_every_config_changing_method_is_guarded():
    for name in CONFIG_CHANGING_METHODS:
        assert getattr(getattr(GarageRpcServicer, name), "__garage_config_change__", False), name
    # Reads and the ingest facade are not: any caller the token admits may use them.
    assert not hasattr(GarageRpcServicer.Search, "__garage_config_change__")
    assert not hasattr(GarageRpcServicer.PersistDocument, "__garage_config_change__")


def test_config_change_allowed_by_token_or_unix_peer():
    assert config_change_allowed("ipv4:127.0.0.1:50000", token_configured=True)
    assert config_change_allowed("unix:", token_configured=False)
    assert config_change_allowed("unix:/tmp/s/grpc", token_configured=False)
    assert not config_change_allowed("ipv4:127.0.0.1:50000", token_configured=False)
    assert not config_change_allowed("ipv6:[::1]:50000", token_configured=False)
    assert not config_change_allowed(None, token_configured=False)


def test_config_changes_are_refused_on_tcp_without_the_token(grpc_server):
    """A port with no token is open to every account, so it cannot widen the egress allowlist."""
    port, _ = grpc_server
    with (
        patch("garage_rag.ops.settings.set_setting") as set_setting,
        grpc.insecure_channel(f"127.0.0.1:{port}") as channel,
    ):
        with pytest.raises(grpc.RpcError) as excinfo:
            _set_setting(channel)
        assert excinfo.value.code() == grpc.StatusCode.PERMISSION_DENIED
        assert "Unix socket" in excinfo.value.details()
        set_setting.assert_not_called()
        # Reads are still answered.
        assert GarageServiceStub(channel).Ping(PingRequest(message="a")).message == "a"


def test_config_changes_are_answered_with_the_token(token_server):
    from pathlib import Path

    with (
        patch("garage_rag.ops.settings.set_setting", return_value=(Path("/tmp/garage.json"), "m")) as set_setting,
        grpc.insecure_channel(f"127.0.0.1:{token_server}") as channel,
    ):
        response = _set_setting(channel, metadata=[(METADATA_KEY, TOKEN)])
    assert response.value_json == '"m"'
    set_setting.assert_called_once()


def test_config_changes_are_answered_over_the_unix_socket(socket_dir, monkeypatch):
    """The owner-only socket folder is the peer check when there is no token."""
    import os
    from pathlib import Path

    monkeypatch.delenv(TOKEN_ENV, raising=False)
    path = os.path.join(socket_dir, "grpc")
    server, _ = create_grpc_server(socket_path=path)
    server.start()
    try:
        with (
            patch("garage_rag.ops.settings.set_setting", return_value=(Path("/tmp/garage.json"), "m")),
            grpc.insecure_channel(f"unix:{path}") as channel,
        ):
            assert _set_setting(channel).value_json == '"m"'
    finally:
        server.stop(grace=None)


@pytest.fixture
def socket_dir():
    """A short folder for sockets: ``sun_path`` holds only 104 bytes on macOS (108 on Linux)."""
    import shutil
    import tempfile

    directory = tempfile.mkdtemp(prefix="garage-", dir=_short_temp_root())
    yield directory
    shutil.rmtree(directory, ignore_errors=True)


def test_grpc_over_a_unix_socket(socket_dir):
    """The app serves the facade on a socket in its App Group container, not on a TCP port."""
    import os
    import stat

    from garage_rag.service.client import GarageClient

    path = os.path.join(socket_dir, "s", "grpc")
    server, _ = create_grpc_server(socket_path=path)
    server.start()
    try:
        assert stat.S_IMODE(os.stat(path).st_mode) == 0o600
        assert stat.S_IMODE(os.stat(os.path.dirname(path)).st_mode) == 0o700
        with GarageClient(socket_path=path) as client:
            assert not client.in_process
            assert client.address == f"unix:{path}"
            assert client.ping("over the socket").message == "over the socket"
    finally:
        server.stop(grace=None)


def test_grpc_socket_replaces_a_stale_socket_but_nothing_else(socket_dir):
    import os
    import socket

    path = os.path.join(socket_dir, "grpc")
    stale = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    stale.bind(path)
    stale.close()  # the file stays behind, as after a crash
    server, _ = create_grpc_server(socket_path=path)
    server.start()
    server.stop(grace=None)

    regular = os.path.join(socket_dir, "not-a-socket")
    with open(regular, "w") as handle:
        handle.write("keep me")
    with pytest.raises(RuntimeError, match="bind"):
        create_grpc_server(socket_path=regular)
    with open(regular) as handle:
        assert handle.read() == "keep me"


def test_grpc_socket_path_must_be_absolute():
    with pytest.raises(ValueError, match="absolute"):
        create_grpc_server(socket_path="relative/grpc")


def _short_temp_root() -> str:
    """The temporary folder, or /tmp when its path leaves too little room in sun_path (104 bytes on macOS)."""
    import tempfile

    root = tempfile.gettempdir()
    return root if len(root) <= 60 else "/tmp"

"""Tests for gRPC Server and live dedicated RPC calls."""

from __future__ import annotations

import threading
from unittest.mock import patch

import grpc
import pytest

from garage_rag.proto.garage_pb2 import (
    GetEmbeddingBatchesRequest,
    PingRequest,
    StatusRequest,
    VersionRequest,
)
from garage_rag.proto.garage_pb2_grpc import GarageServiceStub
from garage_rag.service.server import create_grpc_server


@pytest.fixture
def grpc_server():
    """Start an in-memory / local gRPC server on an ephemeral port."""
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


def test_grpc_socket_is_not_taken_from_a_running_server(socket_dir):
    """Two Garages (or an old and a new build) overlapping must not steal each other's socket."""
    import os

    from garage_rag.service.client import GarageClient

    path = os.path.join(socket_dir, "grpc")
    first, _ = create_grpc_server(socket_path=path)
    first.start()
    try:
        with pytest.raises(RuntimeError, match="another server is listening"):
            create_grpc_server(socket_path=path)
        # The first server still answers on its socket.
        with GarageClient(socket_path=path) as client:
            assert client.ping("still here").message == "still here"
    finally:
        first.stop(grace=None)


def test_grpc_socket_recovery_waits_for_the_lock(socket_dir):
    """Probe, unlink and bind run under ``<socket>.lock``, so a server recovering the path holds off another."""
    import fcntl
    import os
    import stat
    import threading

    path = os.path.join(socket_dir, "grpc")
    lock_fd = os.open(path + ".lock", os.O_RDWR | os.O_CREAT, 0o600)
    fcntl.flock(lock_fd, fcntl.LOCK_EX)
    bound = threading.Event()
    result: list = []

    def bind() -> None:
        result.append(create_grpc_server(socket_path=path))
        bound.set()

    thread = threading.Thread(target=bind, daemon=True)
    thread.start()
    try:
        assert not bound.wait(0.5), "the bind went ahead while another process held the recovery lock"
        assert not os.path.exists(path)
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        assert bound.wait(10)
        assert stat.S_ISSOCK(os.lstat(path).st_mode)
    finally:
        os.close(lock_fd)
        thread.join(10)
        for server, _ in result:
            server.stop(grace=None)


def test_grpc_socket_recovery_race_leaves_one_live_server(socket_dir):
    """Two servers recovering the same stale socket at once: one binds, the other refuses, nobody unlinks a live one."""
    import os
    import socket
    import threading

    from garage_rag.service.client import GarageClient

    path = os.path.join(socket_dir, "grpc")
    stale = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    stale.bind(path)
    stale.close()

    outcomes: list = []
    barrier = threading.Barrier(2)

    def race() -> None:
        barrier.wait()
        try:
            server, _ = create_grpc_server(socket_path=path)
            server.start()
            outcomes.append(server)
        except RuntimeError as error:
            outcomes.append(error)

    threads = [threading.Thread(target=race) for _ in range(2)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(30)
    servers = [outcome for outcome in outcomes if not isinstance(outcome, Exception)]
    errors = [outcome for outcome in outcomes if isinstance(outcome, Exception)]
    try:
        assert len(servers) == 1, outcomes
        assert len(errors) == 1 and "another server is listening" in str(errors[0]), outcomes
        with GarageClient(socket_path=path) as client:
            assert client.ping("survivor").message == "survivor"
    finally:
        for server in servers:
            server.stop(grace=None)


def test_grpc_socket_path_must_be_absolute():
    with pytest.raises(ValueError, match="absolute"):
        create_grpc_server(socket_path="relative/grpc")


def _short_temp_root() -> str:
    """The temporary folder, or /tmp when its path leaves too little room in sun_path (104 bytes on macOS)."""
    import tempfile

    root = tempfile.gettempdir()
    return root if len(root) <= 60 else "/tmp"

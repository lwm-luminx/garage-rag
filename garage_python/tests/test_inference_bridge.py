"""The NSXPC bridge the app's XPC services install for the ``llama_xpc`` provider."""

from __future__ import annotations

import ctypes
import ctypes.util
import json
from collections.abc import Iterator

import pytest

from garage_rag.inference import Backend, BackendKind, InferenceClient, InferenceRefused, InferenceUnreachable, bridge
from garage_rag.xpc.llama_xpc import LlamaXPCClient


@pytest.fixture
def calls() -> Iterator[list[tuple[str, str, object, float]]]:
    """A fake bridge answering like LlamaXPCService's route table, recording each request."""
    seen: list[tuple[str, str, object, float]] = []

    def request(method: str, path: str, body: bytes | None, timeout: float) -> tuple[int, bytes]:
        seen.append((method, path, json.loads(body) if body else None, timeout))
        if path == "/health":
            return 200, b'{"status": "ok"}'
        return 404, b'{"error": {"message": "unknown route", "code": 404}}'

    bridge.set_bridge(request)
    try:
        yield seen
    finally:
        bridge.set_bridge(None)


def test_llama_client_goes_over_the_bridge(calls) -> None:
    client = LlamaXPCClient("http://127.0.0.1:8790", timeout=7.0)
    assert client.health()["status"] == "ok"
    assert calls == [("GET", "/health", None, 7.0)]


def test_request_bodies_are_json(calls) -> None:
    client = LlamaXPCClient("http://127.0.0.1:8790", ensure=lambda _model: "loaded")
    with pytest.raises(Exception, match="unknown route"):
        client.embed(["hello"], model="bge-m3")
    method, path, body, _timeout = calls[0]
    assert (method, path) == ("POST", "/v1/embeddings")
    assert body["input"] == ["hello"]


def test_other_providers_never_use_the_bridge(calls) -> None:
    client = InferenceClient(Backend(BackendKind.OLLAMA, "http://127.0.0.1:1", timeout=1.0))
    with pytest.raises(InferenceUnreachable):
        client.list_models()
    assert calls == []


def test_the_bridge_does_not_widen_the_destination_rules(calls) -> None:
    with pytest.raises(InferenceRefused, match="loopback"):
        InferenceClient(Backend(BackendKind.LLAMA_XPC, "http://gpu-box:8790"))
    assert calls == []


def test_no_reply_is_unreachable() -> None:
    def request(method: str, path: str, body: bytes | None, timeout: float) -> tuple[int, bytes]:
        raise bridge.BridgeError("LlamaXPCService is not running")

    bridge.set_bridge(request)
    try:
        with pytest.raises(InferenceUnreachable, match="not running") as info:
            LlamaXPCClient("http://127.0.0.1:8790").health()
        assert info.value.status_code == 503
    finally:
        bridge.set_bridge(None)


def test_install_calls_the_c_functions_and_releases_every_reply() -> None:
    """The Swift host's side, played by C function pointers made with ctypes and libc's strdup/free."""
    libc = ctypes.CDLL(ctypes.util.find_library("c"))
    libc.strdup.restype = ctypes.c_void_p
    libc.strdup.argtypes = [ctypes.c_char_p]
    libc.free.argtypes = [ctypes.c_void_p]
    released: list[int] = []

    @bridge._REQUEST
    def c_request(method, path, body, timeout, status, reply):
        if path == b"/fail":
            reply[0] = libc.strdup(b"the XPC connection was interrupted")
            return 1
        status[0] = 200
        reply[0] = libc.strdup(json.dumps({"method": method.decode(), "body": (body or b"").decode()}).encode())
        return 0

    @bridge._RELEASE
    def c_release(pointer):
        released.append(pointer)
        libc.free(pointer)

    bridge.install(ctypes.cast(c_request, ctypes.c_void_p).value, ctypes.cast(c_release, ctypes.c_void_p).value)
    try:
        request = bridge.current()
        assert request is not None
        status, body = request("POST", "/v1/embeddings", b'{"input": "x"}', 5.0)
        assert status == 200
        assert json.loads(body) == {"method": "POST", "body": '{"input": "x"}'}
        with pytest.raises(bridge.BridgeError, match="interrupted"):
            request("GET", "/fail", None, 5.0)
        assert len(released) == 2
    finally:
        bridge.set_bridge(None)


def test_install_refuses_a_null_address() -> None:
    with pytest.raises(ValueError, match="null"):
        bridge.install(0, 1)

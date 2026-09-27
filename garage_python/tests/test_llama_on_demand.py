"""On-demand loading of llama_xpc models (``garage_rag.xpc.host`` and ``LlamaXPCClient``).

LlamaXPCService answers only for resident models and loads them over NSXPC.
When a request finds its model missing, the client asks the host to load it
(the Swift loader installed through ctypes, or the app over gRPC) and retries
once. Nothing here needs the app: the Swift loader is stood in for by a ctypes
callback with the same C signature, and the transport by a scripted fake.
"""

from __future__ import annotations

import ctypes
import json
from collections.abc import Iterator
from typing import Any

import pytest

from garage_rag.embed.base import EmbeddingError
from garage_rag.embed.llama_xpc import LlamaXPCEmbedder
from garage_rag.inference.client import InferenceHTTPError
from garage_rag.inference.transport import RawResponse
from garage_rag.proto.garage_pb2 import EnsureLlamaModelResponse
from garage_rag.service.client import GarageClient
from garage_rag.xpc import host
from garage_rag.xpc.host import ModelLoadError, ensure_model
from garage_rag.xpc.llama_xpc import LlamaXPCClient, is_model_not_loaded


@pytest.fixture(autouse=True)
def no_loader() -> Iterator[None]:
    """Each test starts without a host loader and leaves none behind."""
    host.set_model_loader(None)
    yield
    host.set_model_loader(None)


class ScriptedTransport:
    """LlamaXPCService's HTTP side: answers "not loaded" until ``resident`` holds the model."""

    def __init__(self, *, resident: set[str] | None = None) -> None:
        self.resident = resident if resident is not None else set()
        self.requests: list[tuple[str, str, dict[str, Any] | None]] = []

    def request(self, method: str, path: str, body: dict[str, Any] | None = None) -> RawResponse:
        self.requests.append((method, path, body))
        model = (body or {}).get("model")
        if model not in self.resident:
            if not self.resident:
                return self._reply(503, {"error": {"message": "no model loaded", "code": 503}})
            loaded = ", ".join(sorted(self.resident))
            return self._reply(404, {"error": {"message": f"model {model} is not loaded (loaded: {loaded})"}})
        if path == "/v1/embeddings":
            data = [{"index": i, "embedding": [1.0, 0.0]} for i, _ in enumerate(body["input"])]
            return self._reply(200, {"object": "list", "data": data})
        if path == "/v1/chat/completions":
            return self._reply(200, {"choices": [{"message": {"content": "hello"}, "finish_reason": "stop"}]})
        return self._reply(404, {"error": {"message": f"unknown route {path}"}})

    @staticmethod
    def _reply(status: int, payload: dict[str, Any]) -> RawResponse:
        return RawResponse(status=status, body=json.dumps(payload).encode())

    def close(self) -> None:
        pass


def _client(transport: ScriptedTransport, ensure=None) -> LlamaXPCClient:
    client = LlamaXPCClient("http://127.0.0.1:8790", ensure=ensure)
    client._transport = transport  # the guarded transport is covered by test_egress_block
    return client


# ---- the C bridge ------------------------------------------------------------

# The message buffer is taken as a raw address: a ``c_char_p`` argument would arrive as a copy.
_LOADER = ctypes.CFUNCTYPE(ctypes.c_int32, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t)


def _c_loader(status: int, message: str, seen: list[str]):
    """A C function with the Swift entry point's signature; returns it and its address."""

    def body(alias: bytes, buffer: int, capacity: int) -> int:
        seen.append(alias.decode())
        encoded = message.encode()[: capacity - 1] + b"\0"
        ctypes.memmove(buffer, encoded, len(encoded))
        return status

    function = _LOADER(body)
    return function, ctypes.cast(function, ctypes.c_void_p).value


def test_installed_c_loader_is_called_with_the_alias() -> None:
    seen: list[str] = []
    function, address = _c_loader(0, "Model loaded successfully", seen)
    host.install_model_loader(address)
    assert host.has_model_loader()
    assert ensure_model(" bge-m3 ") == "Model loaded successfully"
    assert seen == ["bge-m3"]
    del function


def test_installed_c_loader_failure_carries_its_message() -> None:
    seen: list[str] = []
    text = "The model bge-m3 (BGE-M3) is not downloaded. Download BGE-M3 on the Models page of the Garage app."
    function, address = _c_loader(1, text, seen)
    host.install_model_loader(address)
    with pytest.raises(ModelLoadError, match="Download BGE-M3 on the Models page"):
        ensure_model("bge-m3")
    del function


def test_null_loader_address_is_refused() -> None:
    with pytest.raises(ValueError):
        host.install_model_loader(0)


def test_empty_alias_is_refused() -> None:
    with pytest.raises(ModelLoadError):
        ensure_model("  ")


def test_without_a_loader_and_without_remote_says_to_open_garage() -> None:
    with pytest.raises(ModelLoadError, match="Models page"):
        ensure_model("bge-m3", allow_remote=False)


# ---- the gRPC fallback -------------------------------------------------------


class _FakeRpcError(Exception):
    def __init__(self, code: str, details: str) -> None:
        super().__init__(details)
        self._code = type("Code", (), {"name": code})()
        self._details = details

    def code(self):
        return self._code

    def details(self) -> str:
        return self._details


class _FakeGarageClient:
    calls: list[tuple[str, str, int, float | None]] = []
    outcome: Any = None

    def __init__(
        self,
        host: str | None = None,
        port: int | None = None,
        in_process: bool = True,
        socket_path: str | None = None,
    ) -> None:
        self.host, self.port, self.socket_path = host, port, socket_path
        self.address = f"unix:{socket_path}" if socket_path else f"{host}:{port}"

    def ensure_llama_model(self, model: str, *, timeout: float | None = None) -> EnsureLlamaModelResponse:
        type(self).calls.append((model, self.host or "", self.port or 0, timeout))
        if isinstance(type(self).outcome, Exception):
            raise type(self).outcome
        return EnsureLlamaModelResponse(message=type(self).outcome)

    def close(self) -> None:
        pass


@pytest.fixture
def fake_grpc(monkeypatch: pytest.MonkeyPatch) -> type[_FakeGarageClient]:
    import garage_rag.service.client as service_client

    _FakeGarageClient.calls = []
    _FakeGarageClient.outcome = "loaded"
    monkeypatch.setattr(service_client, "GarageClient", _FakeGarageClient)
    monkeypatch.delenv("GARAGE_GRPC_HOST", raising=False)
    monkeypatch.delenv("GARAGE_GRPC_SOCKET", raising=False)
    monkeypatch.setenv("GARAGE_GRPC_PORT", "50123")
    return _FakeGarageClient


def test_without_a_loader_the_app_is_asked_over_grpc(fake_grpc: type[_FakeGarageClient]) -> None:
    assert ensure_model("bge-m3") == "loaded"
    (model, grpc_host, grpc_port, timeout) = fake_grpc.calls[0]
    assert (model, grpc_host, grpc_port) == ("bge-m3", "127.0.0.1", 50123)
    assert timeout and timeout >= 600


def test_the_launchers_socket_wins_over_the_port(
    fake_grpc: type[_FakeGarageClient], monkeypatch: pytest.MonkeyPatch
) -> None:
    created: list[_FakeGarageClient] = []
    original_init = _FakeGarageClient.__init__

    def recording_init(self, *args, **kwargs) -> None:
        original_init(self, *args, **kwargs)
        created.append(self)

    monkeypatch.setattr(_FakeGarageClient, "__init__", recording_init)
    monkeypatch.setenv("GARAGE_GRPC_SOCKET", "/tmp/garage-test/s/grpc")
    assert ensure_model("bge-m3") == "loaded"
    assert created[0].socket_path == "/tmp/garage-test/s/grpc"


def test_app_not_running_says_to_open_garage(fake_grpc: type[_FakeGarageClient]) -> None:
    fake_grpc.outcome = _FakeRpcError("UNAVAILABLE", "failed to connect to all addresses")
    with pytest.raises(ModelLoadError, match="Open Garage"):
        ensure_model("bge-m3")


def test_app_refusal_passes_its_reason_through(fake_grpc: type[_FakeGarageClient]) -> None:
    fake_grpc.outcome = _FakeRpcError("FAILED_PRECONDITION", "Download BGE-M3 on the Models page of the Garage app.")
    with pytest.raises(ModelLoadError, match="^Download BGE-M3 on the Models page"):
        ensure_model("bge-m3")


def test_installed_loader_wins_over_grpc(fake_grpc: type[_FakeGarageClient]) -> None:
    host.set_model_loader(lambda alias: f"local {alias}")
    assert ensure_model("bge-m3") == "local bge-m3"
    assert fake_grpc.calls == []


# ---- the EnsureLlamaModel RPC ------------------------------------------------


def test_rpc_uses_the_host_loader() -> None:
    seen: list[str] = []
    host.set_model_loader(lambda alias: seen.append(alias) or f"{alias} is already loaded")
    response = GarageClient(in_process=True).ensure_llama_model("gemma2-2b")
    assert response.message == "gemma2-2b is already loaded"
    assert seen == ["gemma2-2b"]


def test_rpc_without_a_loader_fails_precondition_and_does_not_call_itself(fake_grpc) -> None:
    with pytest.raises(RuntimeError, match="FAILED_PRECONDITION"):
        GarageClient(in_process=True).ensure_llama_model("gemma2-2b")
    assert fake_grpc.calls == []


def test_rpc_requires_a_model() -> None:
    with pytest.raises(RuntimeError, match="INVALID_ARGUMENT"):
        GarageClient(in_process=True).ensure_llama_model("")


# ---- LlamaXPCClient ----------------------------------------------------------


def test_is_model_not_loaded() -> None:
    assert is_model_not_loaded(InferenceHTTPError("POST /v1/embeddings: no model loaded", status_code=503))
    assert is_model_not_loaded(
        InferenceHTTPError("POST /v1/embeddings: model x is not loaded (loaded: y)", status_code=404)
    )
    assert not is_model_not_loaded(InferenceHTTPError("GET /nope: Endpoint not found", status_code=404))
    assert not is_model_not_loaded(InferenceHTTPError("boom", status_code=500))
    assert not is_model_not_loaded(RuntimeError("no model loaded"))


def test_embed_loads_a_missing_model_and_retries_once() -> None:
    transport = ScriptedTransport()
    loads: list[str] = []

    def ensure(alias: str) -> str:
        loads.append(alias)
        transport.resident.add(alias)
        return "loaded"

    vectors = _client(transport, ensure).embed(["a", "b"], "bge-m3")
    assert vectors == [[1.0, 0.0], [1.0, 0.0]]
    assert loads == ["bge-m3"]
    assert len(transport.requests) == 2


def test_embed_with_a_resident_model_does_not_load() -> None:
    transport = ScriptedTransport(resident={"bge-m3"})
    loads: list[str] = []
    _client(transport, lambda alias: loads.append(alias) or "").embed(["a"], "bge-m3")
    assert loads == []
    assert len(transport.requests) == 1


def test_chat_loads_the_facts_model_beside_the_embedding_model() -> None:
    """A 404 names the resident models; the facts model is loaded next to them, nothing unloaded."""
    transport = ScriptedTransport(resident={"bge-m3"})

    def ensure(alias: str) -> str:
        transport.resident.add(alias)
        return "loaded"

    result = _client(transport, ensure).chat([{"role": "user", "content": "hi"}], "gemma2-2b")
    assert result.text == "hello"
    assert transport.resident == {"bge-m3", "gemma2-2b"}


def test_load_failure_explains_how_to_fix_it() -> None:
    transport = ScriptedTransport()

    def ensure(alias: str) -> str:
        raise ModelLoadError(f"Download {alias} on the Models page of the Garage app.")

    expected = "loading it on demand failed: Download bge-m3 on the Models page"
    with pytest.raises(InferenceHTTPError, match=expected) as info:
        _client(transport, ensure).embed(["a"], "bge-m3")
    assert info.value.status_code == 503
    assert len(transport.requests) == 1


def test_still_missing_after_loading_is_not_retried_again() -> None:
    transport = ScriptedTransport()
    loads: list[str] = []
    with pytest.raises(InferenceHTTPError, match="no model loaded"):
        _client(transport, lambda alias: loads.append(alias) or "claimed").embed(["a"], "bge-m3")
    assert loads == ["bge-m3"]
    assert len(transport.requests) == 2


def test_without_a_model_name_nothing_is_loaded() -> None:
    transport = ScriptedTransport()
    loads: list[str] = []
    with pytest.raises(InferenceHTTPError, match="no model loaded"):
        _client(transport, lambda alias: loads.append(alias) or "").embed(["a"])
    assert loads == []


def test_embedder_error_names_the_fix_when_nothing_can_load(fake_grpc: type[_FakeGarageClient]) -> None:
    """A venv ``garage search`` with no app: the EmbeddingError says what to do."""
    fake_grpc.outcome = _FakeRpcError("UNAVAILABLE", "connection refused")
    transport = ScriptedTransport()
    embedder = LlamaXPCEmbedder("bge-m3", client=_client(transport))
    with pytest.raises(EmbeddingError, match="Open Garage") as info:
        embedder.embed(["query"])
    assert "llama_xpc embed failed for bge-m3" in str(info.value)
    assert "Models page" in str(info.value)


def test_embedder_loads_through_the_installed_host_loader() -> None:
    transport = ScriptedTransport()

    def load(alias: str) -> str:
        transport.resident.add(alias)
        return "loaded"

    host.set_model_loader(load)
    embedder = LlamaXPCEmbedder("bge-m3", client=_client(transport))
    assert embedder.embed(["query"]) == [[1.0, 0.0]]

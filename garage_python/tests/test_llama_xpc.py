"""Tests for the LlamaXPC HTTP client against a fake llama-server.

The fake speaks the same routes and body shapes as the app's LlamaXPCService
(llama-server / OpenAI compatible) with deterministic replies, and records
every request so the wire format can be asserted, not just the return values.
"""

from __future__ import annotations

import json
import socket
import socketserver
import threading
from collections.abc import Iterator
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any

import pytest

from garage_rag.config import Settings, reset_settings, set_settings
from garage_rag.inference import InferenceUnsupported
from garage_rag.xpc.llama_xpc import (
    DEFAULT_LLAMA_HTTP_URL,
    LlamaXPCClient,
    LlamaXPCError,
    is_loopback_url,
)

ALIAS = "bge-m3"


@dataclass
class FakeState:
    """Mutable knobs for the fake server, shared with the handler."""

    # "ok" | "no_model" | "loading" | "error" | "not_json"
    mode: str = "ok"
    requests: list[tuple[str, str, Any]] = field(default_factory=list)


def _vector(index: int, dims: int) -> list[float]:
    vec = [0.0] * dims
    vec[index % dims] = 1.0
    return vec


class _Handler(BaseHTTPRequestHandler):
    state: FakeState  # set on the class by the fixture

    def log_message(self, *_args: Any) -> None:  # keep pytest output clean
        pass

    def _send(self, status: int, payload: Any, *, raw: bytes | None = None) -> None:
        body = raw if raw is not None else json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json" if raw is None else "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self) -> Any:
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        return json.loads(raw) if raw else None

    def do_GET(self) -> None:  # noqa: N802 - http.server API
        self.state.requests.append(("GET", self.path, None))
        mode = self.state.mode
        if self.path == "/health":
            if mode == "no_model":
                self._send(503, {"status": "no_model_loaded", "slots_idle": 0, "slots_processing": 0})
            elif mode == "loading":
                self._send(503, {"status": "loading model"})
            else:
                self._send(200, {"status": "ok", "slots_idle": 1, "slots_processing": 0})
            return
        if mode == "not_json":
            self._send(200, None, raw=b"<html>not json</html>")
            return
        if self.path == "/props":
            self._send(
                200,
                {
                    "model_alias": ALIAS,
                    "model_path": "/models/bge-m3.gguf",
                    "total_slots": 1,
                    "modal_capabilities": ["embeddings", "completion", "chat"],
                    "default_generation_settings": {"temperature": 0.8},
                    "n_ctx": 8192,
                    "n_embd": 1024,
                    "http_url": DEFAULT_LLAMA_HTTP_URL,
                },
            )
            return
        if self.path == "/v1/models":
            self._send(
                200,
                {
                    "object": "list",
                    "data": [{"id": ALIAS, "object": "model", "created": 1710000000, "owned_by": "garage"}],
                },
            )
            return
        self._send(404, {"error": {"message": f"unknown route {self.path}", "code": 404}})

    def do_POST(self) -> None:  # noqa: N802 - http.server API
        body = self._read_json()
        self.state.requests.append(("POST", self.path, body))
        mode = self.state.mode
        if mode == "no_model":
            self._send(503, {"error": {"message": "no model loaded", "code": 503}})
            return
        if mode == "error":
            self._send(500, {"error": {"message": "boom", "code": 500}})
            return
        if mode == "not_json":
            self._send(200, None, raw=b"garbage")
            return

        if self.path == "/v1/embeddings":
            raw_input = body.get("input")
            inputs = [raw_input] if isinstance(raw_input, str) else list(raw_input)
            if not inputs:
                self._send(400, {"error": {"message": "input is empty", "code": 400}})
                return
            dims = body.get("dimensions") or 4
            # Deliberately out of order: the client must sort by ``index``.
            data = [
                {"object": "embedding", "index": i, "embedding": _vector(i, dims)} for i in reversed(range(len(inputs)))
            ]
            tokens = sum(len(t.split()) for t in inputs)
            self._send(
                200,
                {
                    "object": "list",
                    "data": data,
                    "model": ALIAS,
                    "usage": {"prompt_tokens": tokens, "total_tokens": tokens},
                },
            )
            return
        if self.path == "/v1/chat/completions":
            last = body["messages"][-1]["content"]
            self._send(
                200,
                {
                    "id": "chatcmpl-1",
                    "object": "chat.completion",
                    "created": 1710000000,
                    "model": body.get("model") or ALIAS,
                    "choices": [
                        {
                            "index": 0,
                            "message": {"role": "assistant", "content": f"echo: {last}"},
                            "finish_reason": "stop",
                        }
                    ],
                    "usage": {"prompt_tokens": 3, "completion_tokens": 2, "total_tokens": 5},
                },
            )
            return
        if self.path == "/completion":
            self._send(
                200,
                {
                    "content": f"completed: {body['prompt']}",
                    "stop": True,
                    "tokens_predicted": 2,
                    "tokens_evaluated": 3,
                    "model": ALIAS,
                    "stop_type": "limit" if body.get("n_predict") else "eos",
                },
            )
            return
        if self.path == "/tokenize":
            content = body["content"]
            tokens = [ord(c) for c in content]
            if body.get("with_pieces"):
                self._send(200, {"tokens": [{"id": t, "piece": c} for t, c in zip(tokens, content, strict=True)]})
            else:
                self._send(200, {"tokens": tokens})
            return
        if self.path == "/detokenize":
            self._send(200, {"content": "".join(chr(t) for t in body["tokens"])})
            return
        if self.path == "/v1/rerank":
            docs = body["documents"]
            results = [{"index": i, "relevance_score": 1.0 - i * 0.1} for i in range(len(docs))]
            top_n = body.get("top_n")
            if top_n is not None:
                results = results[:top_n]
            self._send(
                200,
                {
                    "model": ALIAS,
                    "object": "list",
                    "results": results,
                    "usage": {"prompt_tokens": 4, "total_tokens": 4},
                },
            )
            return
        self._send(404, {"error": {"message": f"unknown route {self.path}", "code": 404}})


@dataclass
class FakeServer:
    url: str
    state: FakeState


@pytest.fixture
def fake_server() -> Iterator[FakeServer]:
    state = FakeState()
    handler = type("Handler", (_Handler,), {"state": state})
    server = HTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield FakeServer(url=f"http://127.0.0.1:{server.server_address[1]}", state=state)
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


@pytest.fixture
def client(fake_server: FakeServer) -> LlamaXPCClient:
    return LlamaXPCClient(fake_server.url, timeout=5.0)


def _free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


# ---- construction / guard ----------------------------------------------------


def test_default_base_url_comes_from_settings(fake_server: FakeServer) -> None:
    set_settings(Settings(llama_host=fake_server.url + "/"))
    try:
        client = LlamaXPCClient()
        assert client.base_url == fake_server.url  # trailing slash stripped
        assert client.health()["status"] == "ok"
    finally:
        reset_settings()


def test_default_setting_is_loopback() -> None:
    assert Settings().llama_host == DEFAULT_LLAMA_HTTP_URL
    assert is_loopback_url(DEFAULT_LLAMA_HTTP_URL)


@pytest.mark.parametrize(
    ("url", "expected"),
    [
        ("http://127.0.0.1:8790", True),
        ("http://localhost:8790", True),
        ("http://LOCALHOST:8790", True),
        ("http://[::1]:8790", True),
        ("http://127.5.6.7:8790", True),
        ("http://llama.example:8790", False),
        ("http://10.0.0.5:8790", False),
        ("http://0.0.0.0:8790", False),
        ("not a url", False),
    ],
)
def test_is_loopback_url(url: str, expected: bool) -> None:
    assert is_loopback_url(url) is expected


@pytest.mark.parametrize("url", ["http://llama.example:8790", "http://10.0.0.5:8790", "http://0.0.0.0:8790"])
def test_rejects_non_loopback_base_url(url: str) -> None:
    with pytest.raises(LlamaXPCError, match="loopback") as info:
        LlamaXPCClient(url)
    assert info.value.status_code == 400


def test_rejects_non_loopback_setting() -> None:
    """The configuration refuses the host before a client is ever built; the
    client checks again for settings that bypassed validation."""
    with pytest.raises(ValueError, match="loopback"):
        Settings(llama_host="http://llama.example:8790")
    set_settings(Settings.model_construct(llama_host="http://llama.example:8790"))
    try:
        with pytest.raises(LlamaXPCError, match="loopback"):
            LlamaXPCClient()
    finally:
        reset_settings()


def test_client_ignores_http_proxy(monkeypatch: pytest.MonkeyPatch, fake_server: FakeServer) -> None:
    """A proxy from the environment must never sit between the client and loopback."""
    monkeypatch.setenv("http_proxy", "http://proxy.example:3128")
    monkeypatch.setenv("HTTP_PROXY", "http://proxy.example:3128")
    monkeypatch.delenv("no_proxy", raising=False)
    monkeypatch.delenv("NO_PROXY", raising=False)
    client = LlamaXPCClient(fake_server.url, timeout=5.0)
    assert client.health()["status"] == "ok"
    assert fake_server.state.requests == [("GET", "/health", None)]


# ---- status routes -----------------------------------------------------------


def test_health_ok(client: LlamaXPCClient, fake_server: FakeServer) -> None:
    assert client.health() == {"status": "ok", "slots_idle": 1, "slots_processing": 0}
    assert fake_server.state.requests == [("GET", "/health", None)]


def test_health_returns_body_on_503(client: LlamaXPCClient, fake_server: FakeServer) -> None:
    fake_server.state.mode = "no_model"
    assert client.health()["status"] == "no_model_loaded"
    fake_server.state.mode = "loading"
    assert client.health()["status"] == "loading model"


def test_health_unreachable_raises() -> None:
    client = LlamaXPCClient(f"http://127.0.0.1:{_free_port()}", timeout=2.0)
    with pytest.raises(LlamaXPCError, match="cannot reach") as info:
        client.health()
    assert info.value.status_code == 503


def test_get_props(client: LlamaXPCClient, fake_server: FakeServer) -> None:
    props = client.get_props()
    assert props["model_alias"] == ALIAS
    assert props["n_embd"] == 1024
    assert "embeddings" in props["modal_capabilities"]
    assert fake_server.state.requests == [("GET", "/props", None)]


def test_list_models(client: LlamaXPCClient, fake_server: FakeServer) -> None:
    assert client.list_models() == [ALIAS]
    assert fake_server.state.requests == [("GET", "/v1/models", None)]


# ---- embeddings --------------------------------------------------------------


def test_embed_wire_format_and_ordering(client: LlamaXPCClient, fake_server: FakeServer) -> None:
    vectors = client.embed(["alpha", "beta", "gamma"], ALIAS)
    assert fake_server.state.requests == [
        ("POST", "/v1/embeddings", {"input": ["alpha", "beta", "gamma"], "model": ALIAS}),
    ]
    # The fake replies in reverse order; the client restores input order by ``index``.
    assert vectors == [_vector(0, 4), _vector(1, 4), _vector(2, 4)]


def test_embed_omits_model_when_unset(client: LlamaXPCClient, fake_server: FakeServer) -> None:
    """Never ``dimensions`` either: Garage truncates on its side, servers are not trusted to."""
    client.embed(["alpha"])
    _, _, body = fake_server.state.requests[0]
    assert body == {"input": ["alpha"]}


def test_embed_empty_batch_sends_nothing(client: LlamaXPCClient, fake_server: FakeServer) -> None:
    assert client.embed([]) == []
    assert fake_server.state.requests == []


def test_embed_no_model_is_503(client: LlamaXPCClient, fake_server: FakeServer) -> None:
    fake_server.state.mode = "no_model"
    with pytest.raises(LlamaXPCError, match="no model loaded") as info:
        client.embed(["alpha"])
    assert info.value.status_code == 503


def test_embed_server_error_is_500_with_message(client: LlamaXPCClient, fake_server: FakeServer) -> None:
    fake_server.state.mode = "error"
    with pytest.raises(LlamaXPCError, match="boom") as info:
        client.embed(["alpha"])
    assert info.value.status_code == 500


def test_non_json_reply_raises(client: LlamaXPCClient, fake_server: FakeServer) -> None:
    fake_server.state.mode = "not_json"
    with pytest.raises(LlamaXPCError, match="non-JSON") as info:
        client.get_props()
    assert info.value.status_code == 502
    with pytest.raises(LlamaXPCError, match="non-JSON"):
        client.embed(["alpha"])


def test_unknown_route_is_404(client: LlamaXPCClient) -> None:
    with pytest.raises(LlamaXPCError, match="unknown route") as info:
        client._call("GET", "/nope")
    assert info.value.status_code == 404


# ---- generation --------------------------------------------------------------


def test_chat(client: LlamaXPCClient, fake_server: FakeServer) -> None:
    messages = [{"role": "system", "content": "be terse"}, {"role": "user", "content": "hi"}]
    result = client.chat(messages, "gemma", max_tokens=16, temperature=0.2)
    assert fake_server.state.requests == [
        (
            "POST",
            "/v1/chat/completions",
            {"messages": messages, "model": "gemma", "max_tokens": 16, "temperature": 0.2},
        )
    ]
    assert result.raw["object"] == "chat.completion"
    assert result.model == "gemma"
    assert result.text == "echo: hi"
    assert result.finish_reason == "stop"


def test_chat_minimal_body(client: LlamaXPCClient, fake_server: FakeServer) -> None:
    client.chat([{"role": "user", "content": "hi"}])
    _, _, body = fake_server.state.requests[0]
    assert body == {"messages": [{"role": "user", "content": "hi"}]}


def test_completion(client: LlamaXPCClient, fake_server: FakeServer) -> None:
    resp = client.completion("Once upon", max_tokens=8, temperature=0.5)
    assert fake_server.state.requests == [
        ("POST", "/completion", {"prompt": "Once upon", "n_predict": 8, "temperature": 0.5})
    ]
    assert resp["content"] == "completed: Once upon"
    assert resp["stop"] is True
    assert resp["stop_type"] == "limit"


def test_tokenize_and_detokenize(client: LlamaXPCClient, fake_server: FakeServer) -> None:
    tokens = client.tokenize("hi!")
    assert tokens == {"tokens": [104, 105, 33]}
    pieces = client.tokenize("hi!", with_pieces=True)
    assert pieces["tokens"] == [{"id": 104, "piece": "h"}, {"id": 105, "piece": "i"}, {"id": 33, "piece": "!"}]
    assert client.detokenize([104, 105, 33]) == "hi!"
    assert fake_server.state.requests == [
        ("POST", "/tokenize", {"content": "hi!", "with_pieces": False}),
        ("POST", "/tokenize", {"content": "hi!", "with_pieces": True}),
        ("POST", "/detokenize", {"tokens": [104, 105, 33]}),
    ]


def test_rerank(client: LlamaXPCClient, fake_server: FakeServer) -> None:
    docs = ["a", "b", "c"]
    resp = client.rerank("q", docs, top_n=2)
    assert fake_server.state.requests == [("POST", "/v1/rerank", {"query": "q", "documents": docs, "top_n": 2})]
    assert [r["index"] for r in resp["results"]] == [0, 1]
    assert resp["results"][0]["relevance_score"] >= resp["results"][1]["relevance_score"]


def test_rerank_omits_top_n_when_unset(client: LlamaXPCClient, fake_server: FakeServer) -> None:
    client.rerank("q", ["a"])
    _, _, body = fake_server.state.requests[0]
    assert body == {"query": "q", "documents": ["a"]}


def test_generation_errors_carry_status(client: LlamaXPCClient, fake_server: FakeServer) -> None:
    fake_server.state.mode = "error"
    for call in (
        lambda: client.chat([{"role": "user", "content": "x"}]),
        lambda: client.completion("x"),
        lambda: client.tokenize("x"),
        lambda: client.detokenize([1]),
        lambda: client.rerank("q", ["a"]),
    ):
        with pytest.raises(LlamaXPCError, match="boom") as info:
            call()
        assert info.value.status_code == 500


def test_stub_engine_is_gone() -> None:
    """The in-process fake and its XPC service name must not come back."""
    import garage_rag.xpc.llama_xpc as module

    assert not hasattr(module, "LlamaServiceEngine")
    assert not hasattr(module, "DEFAULT_LLAMA_XPC_SERVICE_NAME")


def test_model_management_is_not_an_http_operation(client: LlamaXPCClient, fake_server: FakeServer) -> None:
    """Loading happens over NSXPC from the app; the LM Studio routes are refused without a request."""
    for call in (
        lambda: client.load_model(ALIAS),
        lambda: client.unload_model(ALIAS),
        lambda: client.download_model(ALIAS),
        lambda: client.lmstudio_models(),
    ):
        with pytest.raises(InferenceUnsupported) as info:
            call()
        assert info.value.status_code == 501
    assert fake_server.state.requests == []


# ---- Unix-domain socket ------------------------------------------------------


class _UnixHTTPServer(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True


@pytest.fixture
def socket_server() -> Iterator[tuple[str, FakeState]]:
    """The fake llama-server on a Unix-domain socket, as the app's LlamaXPCService serves it."""
    import shutil
    import tempfile

    state = FakeState()

    class Handler(_Handler):
        # A Unix peer has no (host, port) address for the default request log.
        def address_string(self) -> str:
            return "unix"

    Handler.state = state
    directory = tempfile.mkdtemp(prefix="garage-", dir=_short_temp_root())  # sun_path is short
    path = f"{directory}/llama"
    server = _UnixHTTPServer(path, Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield path, state
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
        shutil.rmtree(directory, ignore_errors=True)


def test_client_talks_to_the_socket_the_app_exports(
    socket_server: tuple[str, FakeState], monkeypatch: pytest.MonkeyPatch
) -> None:
    path, state = socket_server
    monkeypatch.setenv("GARAGE_LLAMA_SOCKET", path)
    # Nothing listens on the TCP port; the request can only have reached the socket.
    client = LlamaXPCClient(f"http://127.0.0.1:{_free_port()}", timeout=5.0)
    assert client.backend.socket_path == path
    assert client.health()["status"] == "ok"
    assert state.requests[-1][:2] == ("GET", "/health")


def test_socket_is_ignored_for_a_host_that_is_not_loopback(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("GARAGE_LLAMA_SOCKET", "/tmp/garage-test/llama")
    with pytest.raises(LlamaXPCError, match="loopback"):
        LlamaXPCClient("http://gpu-box:8790")


def test_relative_socket_path_is_not_used(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("GARAGE_LLAMA_SOCKET", "s/llama")
    assert LlamaXPCClient("http://127.0.0.1:8790").backend.socket_path is None


def test_unreachable_socket_names_the_socket(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("GARAGE_LLAMA_SOCKET", "/tmp/garage-no-such-dir/llama")
    client = LlamaXPCClient("http://127.0.0.1:8790", timeout=2.0)
    with pytest.raises(LlamaXPCError, match="unix:/tmp/garage-no-such-dir/llama") as info:
        client.health()
    assert info.value.status_code == 503


def _short_temp_root() -> str:
    """The temporary folder, or /tmp when its path leaves too little room in sun_path (104 bytes on macOS)."""
    import tempfile

    root = tempfile.gettempdir()
    return root if len(root) <= 60 else "/tmp"

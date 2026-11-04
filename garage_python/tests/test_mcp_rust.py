"""The Rust MCP server (``rust/garage-mcp``) against the Python one, message for message.

The Rust server reads the corpus through GarageService's ``Corpus*`` calls, whose handlers run the
Python tools themselves, and reaches the local model through its host. Here it runs in-process
through ``libgarage_mcp_ffi``'s C ABI against ``create_grpc_server`` on a Unix socket, with the
per-launch token required, so the messages, the socket and the token are the ones
GarageMCPServerService uses. Each case sends the same JSON-RPC message to both servers and expects
the same reply:

* the protocol (``initialize``, ``tools/list``, ``ping``, unknown methods) against the Python server
  spawned on stdio, as an MCP client spawns it;
* every tool call, valid or not, against ``mcp.call_tool`` in this process, over one fake corpus
  (the search engine and the per-tool queries are replaced; their SQL is ``test_postgres.py``'s)
  and one scripted model, which the Rust side reaches over the host's HTTP callback.

The library is found through ``GARAGE_MCP_FFI_LIBRARY`` or in ``rust/target/{release,debug}``;
without it the tests skip (``cargo build -p garage-mcp-ffi`` in ``rust/`` makes it).
"""

from __future__ import annotations

import asyncio
import contextlib
import ctypes
import json
import os
import subprocess
import sys
import threading
import urllib.request
from pathlib import Path
from typing import Any

import pytest

from garage_rag.enrich.generation import ChatReply
from garage_rag.mcp_server import server as mcp_server
from garage_rag.search.hybrid import SearchHit
from garage_rag.service import server as service

REPO = Path(__file__).resolve().parents[2]
_NAME = {"darwin": "libgarage_mcp_ffi.dylib", "win32": "garage_mcp_ffi.dll"}.get(sys.platform, "libgarage_mcp_ffi.so")


def _library() -> Path | None:
    if value := os.environ.get("GARAGE_MCP_FFI_LIBRARY"):
        return Path(value)
    for profile in ("release", "debug"):
        candidate = REPO / "rust" / "target" / profile / _NAME
        if candidate.exists():
            return candidate
    return None


LIBRARY = _library()
pytestmark = [
    pytest.mark.skipif(LIBRARY is None, reason="libgarage_mcp_ffi is not built (cargo build -p garage-mcp-ffi)"),
    pytest.mark.skipif(sys.platform == "win32", reason="the facade's socket is a Unix-domain socket"),
]

_CALL = ctypes.CFUNCTYPE(ctypes.c_int32, ctypes.c_void_p, ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p))
_RELEASE = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_void_p)


class _Host(ctypes.Structure):
    _fields_ = [("context", ctypes.c_void_p), ("http", _CALL), ("ensure_llama_model", _CALL), ("release", _RELEASE)]


# ---------------------------------------------------------------------------
# the corpus both servers read, and the model both ask
# ---------------------------------------------------------------------------
HOME = str(Path.home())


def _hit(n: int, **fields: Any) -> SearchHit:
    base: dict[str, Any] = {
        "chunk_id": 100 + n,
        "document_id": n,
        "uri": f"{HOME}/notes/doc{n}.md",
        "title": f"Doc {n}",
        "corpus_class": "document",
        "trust_tier": "authored",
        "heading_path": "Intro > Part" if n % 2 else None,
        "text": f"Text of document {n}, with   some\nwhitespace and café. " * (n * 20),
        "score": 1 / (60 + n) + 1e-9 * n,
        "vector_rank": n,
        "fts_rank": n if n % 2 else None,
        "authors": ["Rick"] if n % 2 else [],
    }
    base.update(fields)
    return SearchHit(**base)


HITS = [_hit(1), _hit(2), _hit(3, corpus_class="communication", direction="sent", sender="me", title=None)]


class _Model:
    slug = "nomic"
    is_default = True


class Recorder:
    """What the tools were asked, by either server: the backend's handlers and ``mcp.call_tool`` both
    end in the same Python functions, so the two lists must match."""

    def __init__(self) -> None:
        self.calls: list[tuple[str, dict[str, Any]]] = []
        self.hits = list(HITS)

    def search(self, session, query, **filters):
        self.calls.append(("search", {"query": query, **filters}))
        return self.hits[: filters["limit"]]

    def document(self, **kwargs):
        self.calls.append(("rag_get_document", kwargs))
        if kwargs.get("document_id") is None and not kwargs.get("location"):
            raise ValueError("pass either document_id or location")
        if kwargs.get("document_id") == 404:
            raise ValueError("no such document: 404")
        return mcp_server.DocumentResult(
            document_id=kwargs.get("document_id") or 7,
            location="~/notes/doc7.md",
            title="Doc 7",
            corpus_class="document",
            trust_tier="authored",
            authors=["Rick"],
            extractor="text",
            byte_size=1234,
            chunk_count=3,
            truncated=False,
            content="Seven ünïcode\ttext.",
        )

    def sources(self, **kwargs):
        self.calls.append(("rag_list_sources", kwargs))
        return mcp_server.SourceList(
            count=1,
            sources=[mcp_server.SourceInfo("notes", "filesystem", "document", "authored", "~/notes", 3, 9)],
        )

    def authors(self, **kwargs):
        self.calls.append(("rag_list_authors", kwargs))
        return mcp_server.AuthorList(count=1, authors=[mcp_server.AuthorInfo("Rick", True, 3, ["email:r@x"])])

    def stats(self, **kwargs):
        self.calls.append(("rag_stats", kwargs))
        return mcp_server.CorpusStats(
            documents=3,
            chunks=9,
            authors=1,
            placeholders_pending=0,
            by_class_and_trust=[{"corpus_class": "document", "trust_tier": "authored", "documents": 3}],
            models=[mcp_server.ModelInfo("nomic", 768, 768, "vector", "hnsw", True, 9, 0)],
        )


class Script:
    """The model's replies, in order, and the messages each request carried."""

    def __init__(self, replies: list[str]) -> None:
        self.replies = list(replies)
        self.asked: list[dict[str, Any]] = []

    def next(self, body: dict[str, Any]) -> dict[str, Any]:
        self.asked.append(body)
        text = self.replies.pop(0) if self.replies else "out of replies"
        return {
            "choices": [{"message": {"role": "assistant", "content": f"  {text}  "}, "finish_reason": "stop"}],
            "usage": {"prompt_tokens": 11, "completion_tokens": 5},
        }


class FakeChatModel:
    """``LocalChatModel`` for the Python server: the defaults (llama_xpc, gemma2-2b, LlamaXPCService's
    host), answering from the script as the Rust server's HTTP host does."""

    script: Script

    def __init__(self, *args, **kwargs) -> None:
        self.provider = "llama_xpc"
        self.model_ref = "gemma2-2b"
        self.host = "http://127.0.0.1:8790"

    def chat(self, messages, **kwargs):
        return self.complete(messages, **kwargs).text


def _complete(self, messages, *, max_tokens=None, temperature=None):
    body: dict[str, Any] = {"messages": [dict(m) for m in messages], "model": self.model_ref}
    if max_tokens is not None:
        body["max_tokens"] = max_tokens
    if temperature is not None:
        body["temperature"] = temperature
    reply = FakeChatModel.script.next(body)
    usage = reply["usage"]
    return ChatReply(
        text=reply["choices"][0]["message"]["content"].strip(),
        prompt_tokens=usage["prompt_tokens"],
        completion_tokens=usage["completion_tokens"],
    )


FakeChatModel.complete = _complete  # type: ignore[attr-defined]


@contextlib.contextmanager
def _no_session():
    yield None


@pytest.fixture
def corpus(monkeypatch, tmp_path):
    """GarageService on a socket, its tools over the fake corpus; yields (socket, recorder)."""
    recorder = Recorder()
    monkeypatch.setattr(mcp_server, "session_scope", _no_session)
    monkeypatch.setattr(mcp_server, "run_search", recorder.search)
    monkeypatch.setattr(mcp_server, "list_models", lambda session: [_Model()])
    monkeypatch.setattr(mcp_server, "LocalChatModel", FakeChatModel)
    monkeypatch.setattr(mcp_server, "_HOME", HOME)
    tools = mcp_server.mcp._tool_manager
    for name, fake in (
        ("rag_get_document", recorder.document),
        ("rag_list_sources", recorder.sources),
        ("rag_list_authors", recorder.authors),
        ("rag_stats", recorder.stats),
    ):
        # The backend's handler calls the module's function; the Python server, its registered one.
        monkeypatch.setattr(mcp_server, name, fake)
        monkeypatch.setattr(tools.get_tool(name), "fn", fake)
    monkeypatch.setenv("GARAGE_GRPC_TOKEN", "launch-token")
    socket = tmp_path / "grpc.sock"
    server, _ = service.create_grpc_server(socket_path=str(socket))
    server.start()
    yield socket, recorder
    server.stop(0)


# ---------------------------------------------------------------------------
# the two servers
# ---------------------------------------------------------------------------
class RustServer:
    def __init__(self, socket: Path, script: Script | None = None, token: str = "launch-token") -> None:
        self.library = ctypes.CDLL(str(LIBRARY))
        for name in ("garage_mcp_handle",):
            fn = getattr(self.library, name)
            fn.argtypes = [ctypes.c_char_p, ctypes.POINTER(_Host), ctypes.POINTER(ctypes.c_void_p)]
            fn.restype = ctypes.c_int32
        self.library.garage_mcp_string_free.argtypes = [ctypes.c_void_p]
        self.grpc = {"socket": str(socket), "token": token}
        self.script = script or Script([])
        self.requests: list[dict[str, Any]] = []
        self._replies: dict[int, ctypes.Array] = {}
        self._lock = threading.Lock()

        def reply_with(out, text: str) -> None:
            buffer = ctypes.create_string_buffer(text.encode())
            with self._lock:
                self._replies[ctypes.addressof(buffer)] = buffer
            out[0] = ctypes.addressof(buffer)

        def http(_context, raw, out):
            asked = json.loads(raw)
            self.requests.append(asked)
            body = json.loads(asked["body"])
            reply_with(out, json.dumps({"status": 200, "body": json.dumps(self.script.next(body))}))
            return 0

        def release(_context, pointer):
            with self._lock:
                self._replies.pop(pointer, None)

        self.host = _Host(None, _CALL(http), _CALL(), _RELEASE(release))

    def handle(self, message: dict[str, Any], **extra: Any) -> dict[str, Any] | None:
        payload = {"grpc": self.grpc, "message": message} | extra
        result = ctypes.c_void_p()
        status = self.library.garage_mcp_handle(
            json.dumps(payload).encode(), ctypes.byref(self.host), ctypes.byref(result)
        )
        try:
            outcome = json.loads(ctypes.string_at(result.value))
        finally:
            self.library.garage_mcp_string_free(result)
        assert status == 0, outcome
        return outcome["reply"]

    def call(self, name: str, arguments: dict[str, Any]) -> dict[str, Any]:
        reply = self.handle(
            {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": name, "arguments": arguments}}
        )
        assert reply is not None
        return reply["result"]


def python_call(name: str, arguments: dict[str, Any]) -> dict[str, Any]:
    """``tools/call`` on the Python server, as its JSON-RPC result."""
    try:
        result = asyncio.run(mcp_server.mcp.call_tool(name, arguments))
    except Exception as exc:  # ToolError and UnexpectedToolError carry the text the client sees
        return {"content": [{"type": "text", "text": str(exc)}], "isError": True}
    dumped = result.model_dump(by_alias=True, mode="json", exclude_unset=True)
    return {"content": dumped["content"], "isError": False, "structuredContent": dumped["structuredContent"]}


def _same(rust: dict[str, Any], python: dict[str, Any]) -> None:
    assert rust["isError"] == python["isError"], (rust, python)
    assert rust.get("structuredContent") == python.get("structuredContent")
    assert [c["type"] for c in rust["content"]] == [c["type"] for c in python["content"]]
    rust_text = rust["content"][0]["text"]
    python_text = python["content"][0]["text"]
    if rust["isError"]:
        assert rust_text == python_text
    else:
        # The SDK's text is the structured content, indented; equal as JSON and as text.
        assert json.loads(rust_text) == json.loads(python_text)
        assert rust_text == python_text


# ---------------------------------------------------------------------------
# the protocol, against the Python server on stdio
# ---------------------------------------------------------------------------
def _python_stdio(messages: list[dict[str, Any]], tmp_path: Path) -> list[dict[str, Any]]:
    config = tmp_path / "garage.json"
    config.write_text("{}")
    env = {k: v for k, v in os.environ.items() if not k.startswith("GARAGE_")}
    env["GARAGE_DATABASE_URL"] = "postgresql://garage@127.0.0.1:1/garage"
    env["PYTHONPATH"] = os.pathsep.join(sys.path)
    lines = "".join(json.dumps(m) + "\n" for m in messages)
    done = subprocess.run(
        [sys.executable, "-m", "garage_rag.mcp_server.server", "--config", str(config)],
        input=lines,
        capture_output=True,
        text=True,
        env=env,
        cwd=tmp_path,
        timeout=120,
        check=False,
    )
    return [json.loads(line) for line in done.stdout.splitlines() if line.strip()]


def _initialize(version: str, n: int) -> dict[str, Any]:
    params = {"protocolVersion": version, "capabilities": {}, "clientInfo": {"name": "t", "version": "1"}}
    return {"jsonrpc": "2.0", "id": n, "method": "initialize", "params": params}


PROTOCOL = [
    _initialize("2025-06-18", 1),
    {"jsonrpc": "2.0", "method": "notifications/initialized"},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
    {"jsonrpc": "2.0", "id": "three", "method": "ping"},
    {"jsonrpc": "2.0", "id": 4, "method": "prompts/list"},
    {"jsonrpc": "2.0", "id": 5, "method": "resources/list"},
    {"jsonrpc": "2.0", "id": 6, "method": "no/such/method"},
    _initialize("2024-11-05", 7),
    _initialize("2099-01-01", 8),
]


def test_the_protocol_answers_as_the_python_server_does(corpus, tmp_path):
    socket, _ = corpus
    rust = RustServer(socket)
    python = {reply["id"]: reply for reply in _python_stdio(PROTOCOL, tmp_path)}
    replies = [rust.handle(message) for message in PROTOCOL]
    assert replies[1] is None, "a notification gets no reply"
    for message, reply in zip(PROTOCOL, replies, strict=True):
        if "id" in message:
            assert reply == python[message["id"]], message["method"]


# ---------------------------------------------------------------------------
# the tools, against the Python server's own call_tool
# ---------------------------------------------------------------------------
READ_CASES = [
    ("rag_search", {"query": "café notes"}),
    (
        "rag_search",
        {"query": "x", "limit": "2", "mode": "fts", "corpus_class": "code", "trust": ["authored", "received"]},
    ),
    ("rag_search", {"query": "x", "source": "notes", "author": "Rick", "direction": "sent", "extra": True}),
    ("rag_search", {"query": "x", "corpus_class": '["document"]', "limit": 12.0}),
    ("rag_get_document", {"document_id": 7}),
    ("rag_get_document", {"location": "~/notes/doc7.md", "max_chars": "900"}),
    ("rag_list_sources", {}),
    ("rag_list_authors", {"limit": 5}),
    ("rag_stats", {}),
]

INVALID_CASES = [
    ("rag_search", {}),
    ("rag_search", {"query": "x", "limit": 0}),
    ("rag_search", {"query": "x", "limit": 99}),
    ("rag_search", {"query": "x", "limit": "abc"}),
    ("rag_search", {"query": "x", "limit": 2.5}),
    ("rag_search", {"query": "x", "limit": None}),
    ("rag_search", {"query": 5}),
    ("rag_search", {"query": "x", "mode": "bad"}),
    ("rag_search", {"query": "x", "corpus_class": "bad"}),
    ("rag_search", {"query": "x", "corpus_class": ["code", "bad"]}),
    ("rag_search", {"query": "x", "source": 5}),
    ("rag_search", {"query": "x", "direction": "up"}),
    ("rag_search", {"query": "x" * 100, "mode": "it's"}),
    ("rag_get_document", {"document_id": "x"}),
    ("rag_get_document", {"document_id": 1, "max_chars": 10}),
    ("rag_list_authors", {"limit": 1e3}),
    ("rag_ask", {"question": "q", "temperature": 3}),
    ("rag_agent", {"question": "q", "search_first": "maybe"}),
    ("rag_generate", {}),
]

FAILING_CASES = [
    ("rag_nope", {}),
    ("rag_get_document", {}),
    ("rag_get_document", {"document_id": 404}),
]


@pytest.mark.parametrize(("name", "arguments"), READ_CASES)
def test_read_tools_answer_and_ask_as_the_python_server_does(corpus, name, arguments):
    socket, recorder = corpus
    python = python_call(name, arguments)
    asked_by_python = list(recorder.calls)
    recorder.calls.clear()
    rust = RustServer(socket).call(name, arguments)
    _same(rust, python)
    assert recorder.calls == asked_by_python


@pytest.mark.parametrize(("name", "arguments"), INVALID_CASES + FAILING_CASES)
def test_bad_calls_fail_as_they_do_in_python(corpus, name, arguments):
    socket, _ = corpus
    _same(RustServer(socket).call(name, arguments), python_call(name, arguments))


GENERATING_CASES = [
    ("rag_generate", {"prompt": "Say hi", "system": "Be brief", "max_tokens": 32}, ["Hi."]),
    ("rag_generate", {"prompt": "Say hi", "temperature": "1"}, ["Hi there."]),
    ("rag_ask", {"question": "What is in doc 1?", "limit": 2}, ["Doc 1 says [1]."]),
    ("rag_ask", {"question": "Everything", "corpus_class": "document"}, ["All of it [1][2][3]."]),
    ("rag_agent", {"question": "What did I write?"}, ["It says things."]),
    (
        "rag_agent",
        {"question": "Open doc 7", "search_first": False, "max_steps": 3},
        [
            '{"tool": "rag_get_document", "arguments": {"document_id": 7}}',
            '```json\n{"tool": "rag_list_sources"}\n```',
            '{"tool": "rag_nope", "arguments": {}}',
            "Doc 7 is about ünïcode.",
        ],
    ),
    (
        "rag_agent",
        {"question": "Stats?", "max_steps": 2},
        [
            '{"name": "rag_stats", "arguments": null}',
            '{"tool": "rag_get_document", "arguments": {"document_id": 404}}',
            '{"tool": "rag_search", "arguments": {"query": "x"}}',
        ],
    ),
    (
        "rag_agent",
        {"question": "Bad args", "max_steps": 1},
        ['{"tool": "rag_search", "arguments": {"limit": 0}}', "Done."],
    ),
]


@pytest.mark.parametrize(("name", "arguments", "replies"), GENERATING_CASES)
def test_generating_tools_prompt_and_answer_as_the_python_server_does(corpus, name, arguments, replies):
    socket, recorder = corpus
    FakeChatModel.script = Script(replies)
    python = python_call(name, arguments)
    python_asked = FakeChatModel.script.asked
    asked_by_python = list(recorder.calls)
    recorder.calls.clear()

    rust_server = RustServer(socket, Script(replies))
    rust = rust_server.call(name, arguments)
    _same(rust, python)
    assert rust_server.script.asked == python_asked
    assert recorder.calls == asked_by_python
    # The default model: LlamaXPCService's chat route, on loopback.
    assert {(r["backend"], r["url"]) for r in rust_server.requests} <= {
        ("llama_xpc", "http://127.0.0.1:8790/v1/chat/completions")
    }


def test_the_token_is_required(corpus):
    socket, _ = corpus
    reply = RustServer(socket, token="wrong").call("rag_stats", {})
    assert reply == {"content": [{"text": "Error executing tool rag_stats", "type": "text"}], "isError": True}


def test_a_communication_never_goes_to_an_off_box_model(corpus, monkeypatch):
    socket, recorder = corpus
    from garage_rag.config import get_settings, set_settings

    settings = get_settings()
    off_box = settings.model_copy(update={"fact_provider": "ollama", "ollama_host": "http://gpu-box:11434"})
    set_settings(off_box)
    try:
        rust_server = RustServer(socket, Script(["never"]))
        reply = rust_server.call("rag_ask", {"question": "anything"})
    finally:
        set_settings(settings)
    assert reply["isError"] is True
    assert rust_server.requests == [], "nothing was sent"
    assert recorder.calls and recorder.calls[0][0] == "search"


# ---------------------------------------------------------------------------
# the HTTP transport
# ---------------------------------------------------------------------------
class RustHttp:
    def __init__(self, socket: Path) -> None:
        self.inner = RustServer(socket)
        lib = self.inner.library
        lib.garage_mcp_http_start.argtypes = [
            ctypes.c_char_p,
            ctypes.POINTER(_Host),
            ctypes.POINTER(ctypes.c_void_p),
            ctypes.POINTER(ctypes.c_void_p),
        ]
        lib.garage_mcp_http_start.restype = ctypes.c_int32
        lib.garage_mcp_http_stop.argtypes = [ctypes.c_void_p]
        lib.garage_mcp_http_is_running.argtypes = [ctypes.c_void_p]
        lib.garage_mcp_http_is_running.restype = ctypes.c_bool
        self.server = ctypes.c_void_p()
        result = ctypes.c_void_p()
        payload = {"grpc": self.inner.grpc, "http": {"host": "127.0.0.1", "port": 0, "path": "/mcp"}}
        status = lib.garage_mcp_http_start(
            json.dumps(payload).encode(), ctypes.byref(self.inner.host), ctypes.byref(self.server), ctypes.byref(result)
        )
        outcome = json.loads(ctypes.string_at(result.value))
        lib.garage_mcp_string_free(result)
        assert status == 0, outcome
        self.address = outcome["address"]
        self.port = int(self.address.rsplit(":", 1)[1])

    def post(self, message: dict[str, Any], headers: dict[str, str] | None = None):
        request = urllib.request.Request(
            f"http://127.0.0.1:{self.port}/mcp",
            data=json.dumps(message).encode(),
            method="POST",
            headers={"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
            | (headers or {}),
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as reply:  # noqa: S310 (loopback, test only)
                return reply.status, dict(reply.headers), reply.read().decode()
        except urllib.error.HTTPError as error:
            return error.code, dict(error.headers), error.read().decode()

    def stop(self) -> None:
        self.inner.library.garage_mcp_http_stop(self.server)


def test_http_serves_sessions_and_checks_the_host(corpus):
    socket, _ = corpus
    http = RustHttp(socket)
    try:
        status, headers, body = http.post(PROTOCOL[0])
        assert status == 200
        assert headers["content-type"] == "text/event-stream"
        session = headers["mcp-session-id"]
        event = body.split("data: ", 1)[1].strip()
        assert json.loads(event)["result"]["serverInfo"]["name"] == "garage-rag"

        status, _, body = http.post(PROTOCOL[2])
        assert status == 400 and "Missing session ID" in body
        status, _, body = http.post(PROTOCOL[2], {"mcp-session-id": "nope"})
        assert status == 404 and "Session not found" in body

        status, _, body = http.post(
            {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "rag_stats", "arguments": {}}},
            {"mcp-session-id": session, "Authorization": "Bearer gmr_test"},
        )
        assert status == 200
        result = json.loads(body.split("data: ", 1)[1])["result"]
        assert result["structuredContent"]["documents"] == 3

        status, _, _ = http.post(PROTOCOL[1], {"mcp-session-id": session})
        assert status == 202
        status, _, body = http.post(PROTOCOL[3], {"mcp-session-id": session, "Host": "evil.example:80"})
        assert (status, body) == (421, "Invalid Host header")
        status, _, body = http.post(PROTOCOL[3], {"mcp-session-id": session, "Origin": "https://evil.example"})
        assert (status, body) == (403, "Invalid Origin header")
        assert http.inner.library.garage_mcp_http_is_running(http.server)
    finally:
        http.stop()

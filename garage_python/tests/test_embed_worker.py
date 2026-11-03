"""The Rust embed worker (``rust/garage-embed``) against Python's GarageService.

The worker reaches the database only through the facade: it lists the models, fetches batches with
``GetEmbeddingBatches``, stores vectors with ``UpdateEmbeddings`` and finishes a model with
``BackfillDistilled``. Here it runs in-process through ``libgarage_embed_ffi``'s C ABI against
``create_grpc_server`` on a Unix socket, with the per-launch token required, so the messages, the
socket and the token are the ones the app's embed service uses. The servicer's four facade methods
keep their chunks in memory (the SQL behind them is ``test_postgres.py``'s); the model server is the
host's HTTP callback, an Ollama that embeds each text as its length.

The library is found through ``GARAGE_EMBED_FFI_LIBRARY`` or in ``rust/target/{release,debug}``;
without it the tests skip (``cargo build -p garage-embed-ffi`` in ``rust/`` makes it).
"""

from __future__ import annotations

import ctypes
import json
import os
import sys
import threading
from pathlib import Path

import pytest

from garage_rag.proto.garage_pb2 import (
    BackfillDistilledResponse,
    EmbeddingChunkItem,
    GetEmbeddingBatchesResponse,
    ListModelsResponse,
    ModelInfo,
    UpdateEmbeddingsResponse,
)
from garage_rag.service import server as service

REPO = Path(__file__).resolve().parents[2]
_NAME = {"darwin": "libgarage_embed_ffi.dylib", "win32": "garage_embed_ffi.dll"}.get(
    sys.platform, "libgarage_embed_ffi.so"
)


def _library() -> Path | None:
    if value := os.environ.get("GARAGE_EMBED_FFI_LIBRARY"):
        return Path(value)
    for profile in ("release", "debug"):
        candidate = REPO / "rust" / "target" / profile / _NAME
        if candidate.exists():
            return candidate
    return None


LIBRARY = _library()
pytestmark = [
    pytest.mark.skipif(LIBRARY is None, reason="libgarage_embed_ffi is not built (cargo build -p garage-embed-ffi)"),
    pytest.mark.skipif(sys.platform == "win32", reason="the facade's socket is a Unix-domain socket"),
]

_CALL = ctypes.CFUNCTYPE(ctypes.c_int32, ctypes.c_void_p, ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p))
_RELEASE = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_void_p)
_PROGRESS = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_char_p)
_CANCELLED = ctypes.CFUNCTYPE(ctypes.c_bool, ctypes.c_void_p)


class _Host(ctypes.Structure):
    _fields_ = [
        ("context", ctypes.c_void_p),
        ("http", _CALL),
        ("ensure_llama_model", _CALL),
        ("embed_images", _CALL),
        ("embed_image_texts", _CALL),
        ("release", _RELEASE),
        ("progress", _PROGRESS),
        ("cancelled", _CANCELLED),
    ]


class Corpus:
    """The facade's four methods over chunks in memory: chunk id -> (text, is a communication)."""

    def __init__(self, chunks: dict[int, tuple[str, bool]], *, dims: int = 3, local: bool = True) -> None:
        self.chunks = chunks
        self.dims = dims
        self.local = local
        self.stored: dict[int, list[float]] = {}
        self.distilled: list[str] = []
        self.tokens: list[str | None] = []

    def _record(self, context) -> None:
        self.tokens.append(dict(context.invocation_metadata()).get("x-garage-token"))

    def _pending(self, include_communications: bool) -> list[int]:
        return [
            cid
            for cid, (_, communication) in sorted(self.chunks.items())
            if cid not in self.stored and (include_communications or not communication)
        ]

    def ListModels(self, request, context):
        self._record(context)
        return ListModelsResponse(models=[ModelInfo(slug="m", provider="ollama", model_ref="nomic", dims=self.dims)])

    def GetEmbeddingBatches(self, request, context):
        self._record(context)
        if request.model_slug != "m":
            context.abort(service.grpc.StatusCode.NOT_FOUND, f"no model {request.model_slug!r} registered")
        pending = self._pending(self.local)
        chunks = [EmbeddingChunkItem(chunk_id=cid, text=self.chunks[cid][0]) for cid in pending[: request.batch_size]]
        return GetEmbeddingBatchesResponse(
            model_slug="m",
            provider="ollama",
            model_ref="nomic",
            dims=self.dims,
            total_pending=len(pending),
            chunks=chunks,
            has_more=len(pending) > len(chunks),
            modality="text",
            withheld=len(self._pending(True)) - len(pending),
        )

    def UpdateEmbeddings(self, request, context):
        self._record(context)
        for item in request.embeddings:
            self.stored[item.chunk_id] = list(item.vector)
        return UpdateEmbeddingsResponse(success=True, count=len(request.embeddings))

    def BackfillDistilled(self, request, context):
        self._record(context)
        self.distilled.append(request.model_slug)
        return BackfillDistilledResponse(distilled=0)


@pytest.fixture
def serve(monkeypatch, tmp_path):
    """Starts GarageService on a socket with ``corpus`` behind its facade; yields the socket's path."""
    servers = []

    def start(corpus: Corpus) -> Path:
        for name in ("ListModels", "GetEmbeddingBatches", "UpdateEmbeddings", "BackfillDistilled"):
            monkeypatch.setattr(service.GarageRpcServicer, name, lambda self, r, c, _n=name: getattr(corpus, _n)(r, c))
        monkeypatch.setenv("GARAGE_GRPC_TOKEN", "launch-token")
        socket = tmp_path / "grpc.sock"
        server, _ = service.create_grpc_server(socket_path=str(socket))
        server.start()
        servers.append(server)
        return socket

    yield start
    for server in servers:
        server.stop(0)


def _backfill(socket: Path, *, token: str = "launch-token", dims: int = 3, **request) -> tuple[int, dict, list[dict]]:
    """Runs ``garage_embed_backfill`` with an Ollama that embeds a text as ``[len, 0, ...]``."""
    library = ctypes.CDLL(str(LIBRARY))
    library.garage_embed_backfill.argtypes = [ctypes.c_char_p, ctypes.POINTER(_Host), ctypes.POINTER(ctypes.c_void_p)]
    library.garage_embed_backfill.restype = ctypes.c_int32
    library.garage_embed_string_free.argtypes = [ctypes.c_void_p]
    events: list[dict] = []
    replies: dict[int, ctypes.Array] = {}
    lock = threading.Lock()

    def reply_with(out, text: str) -> None:
        buffer = ctypes.create_string_buffer(text.encode())
        with lock:
            replies[ctypes.addressof(buffer)] = buffer
        out[0] = ctypes.addressof(buffer)

    def http(_context, raw, out):
        asked = json.loads(raw)
        assert (asked["backend"], asked["url"]) == ("ollama", "http://localhost:11434/api/embed")
        inputs = json.loads(asked["body"])["input"]
        vectors = [[float(len(text))] + [0.0] * (dims - 1) for text in inputs]
        reply_with(out, json.dumps({"status": 200, "body": json.dumps({"embeddings": vectors})}))
        return 0

    def release(_context, pointer):
        with lock:
            replies.pop(pointer, None)

    host = _Host(
        None,
        _CALL(http),
        _CALL(),
        _CALL(),
        _CALL(),
        _RELEASE(release),
        _PROGRESS(lambda _context, event: events.append(json.loads(event))),
        _CANCELLED(),
    )
    payload = {"grpc": {"socket": str(socket), "token": token}, "settings": {"batch_size": 2}, **request}
    result = ctypes.c_void_p()
    status = library.garage_embed_backfill(json.dumps(payload).encode(), ctypes.byref(host), ctypes.byref(result))
    try:
        outcome = json.loads(ctypes.string_at(result.value))
    finally:
        library.garage_embed_string_free(result)
    return status, outcome, events


def test_embeds_every_pending_chunk_through_the_facade(serve):
    corpus = Corpus({cid: (f"chunk {'x' * cid}", False) for cid in range(1, 6)})
    status, outcome, events = _backfill(serve(corpus))
    assert status == 0, outcome
    assert sorted(corpus.stored) == [1, 2, 3, 4, 5]
    assert corpus.stored[3] == [9.0, 0.0, 0.0]
    assert corpus.distilled == ["m"]
    assert set(corpus.tokens) == {"launch-token"}
    assert [(e["phase"], e["message"]) for e in events] == [
        ("started", "m: embedding 5 chunks"),
        ("progress", "m: 2/5 (1 batches)"),
        ("progress", "m: 4/5 (2 batches)"),
        ("progress", "m: 5/5 (3 batches)"),
        ("finished", "m: embedded 5"),
    ]
    finished = outcome["outcomes"][0]
    assert (finished["model_slug"], finished["embedded"], finished["remaining"], finished["batches"]) == ("m", 5, 0, 3)


def test_off_box_withholding_is_reported_as_python_reports_it(serve):
    corpus = Corpus({1: ("a", False), 2: ("mail", True)}, local=False)
    status, outcome, _ = _backfill(serve(corpus))
    assert status == 0, outcome
    assert 2 not in corpus.stored
    assert outcome["outcomes"][0]["message"] == (
        "m: embedded 1; 1 communication chunk(s) withheld: the provider is not on this machine"
    )


def test_a_mis_registered_width_skips_the_model(serve):
    corpus = Corpus({1: ("a", False)}, dims=4)
    status, outcome, _ = _backfill(serve(corpus), dims=3)
    assert status == 0, outcome
    assert corpus.stored == {}
    assert outcome["outcomes"][0]["phase"] == "skipped"
    assert outcome["outcomes"][0]["message"] == (
        "m: registered 4 dims but the model emits 3. Re-register with --dims 3."
    )


def test_the_token_is_required(serve):
    corpus = Corpus({1: ("a", False)})
    status, outcome, _ = _backfill(serve(corpus), token="wrong")
    assert status == 3, outcome
    assert "missing or invalid x-garage-token" in outcome["error"]
    assert corpus.stored == {}


def test_an_unknown_model_is_not_found(serve):
    status, outcome, _ = _backfill(serve(Corpus({})), model="other")
    assert status == 4, outcome
    assert "no model 'other' registered" in outcome["error"]

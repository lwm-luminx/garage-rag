"""Loading a ``llama_xpc`` model on demand, through the app rather than over HTTP.

LlamaXPCService only answers for models that are resident, and models are
loaded over NSXPC (its ``ensureModel`` call), never through the HTTP API the
Python side talks to. So when a request finds its model missing,
:class:`~garage_rag.xpc.llama_xpc.LlamaXPCClient` asks :func:`ensure_model` to
have it loaded and retries once. Two ways to reach an NSXPC client:

* **In process.** The app's XPC services that embed this interpreter
  (``GarageXPCService``: search, backfill, enrich-facts; ``GarageMCPServerService``:
  ``rag_search``/``rag_ask``; the embed worker) hand Python the address of a C
  function at start-up (:func:`install_model_loader`). It is called through
  ctypes, which releases the GIL while the Swift side waits for the load.
* **Over gRPC.** Everything else (the ``garage``/``garage-mcp`` launchers
  that stdio MCP clients spawn, or ``garage`` from a venv while the app runs)
  asks the app's ``GarageService`` (``EnsureLlamaModel`` on the socket the
  launchers export as ``GARAGE_GRPC_SOCKET``, else on loopback), whose
  handler runs in ``GarageXPCService`` and uses the loader installed there.

Nothing here opens a network connection of its own: the C function is local
and the gRPC client is the facade's loopback client
(:class:`garage_rag.service.client.GarageClient`).

Models are only ever loaded here, never unloaded. The engine keeps several
resident at once (usually the embedding model and the facts model); the app's
Models page unloads them.
"""

from __future__ import annotations

import ctypes
import logging
import os
import threading
from collections.abc import Callable

log = logging.getLogger(__name__)

__all__ = [
    "LOADER_MESSAGE_CAPACITY",
    "ModelLoadError",
    "ensure_model",
    "has_model_loader",
    "install_model_loader",
    "set_model_loader",
]

# ``int32_t loader(const char *alias, char *message, size_t capacity)``: 0 when the
# model is resident, nonzero with the reason in ``message`` otherwise.
_LOADER_CFUNC = ctypes.CFUNCTYPE(ctypes.c_int32, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_size_t)
LOADER_MESSAGE_CAPACITY = 4096

# How long the gRPC fallback waits for the app to load a model (a large GGUF is slow to map).
_GRPC_LOAD_TIMEOUT_SECONDS = 660.0

_lock = threading.Lock()
# Kept in a module global so the ctypes function object lives as long as the interpreter.
_c_loader: object | None = None
_loader: Callable[[str], str] | None = None


class ModelLoadError(RuntimeError):
    """A ``llama_xpc`` model could not be loaded; the message says what to do."""


def install_model_loader(address: int) -> None:
    """Called by the Swift host with the address of its loader function."""
    if not address:
        raise ValueError("model loader address is null")
    c_loader = _LOADER_CFUNC(address)

    def load(alias: str) -> str:
        buffer = ctypes.create_string_buffer(LOADER_MESSAGE_CAPACITY)
        status = c_loader(alias.encode("utf-8"), buffer, LOADER_MESSAGE_CAPACITY)
        message = buffer.value.decode("utf-8", "replace")
        if status != 0:
            raise ModelLoadError(message or f"loading {alias} failed (status {status})")
        return message

    global _c_loader
    with _lock:
        _c_loader = c_loader
    set_model_loader(load)
    log.info("llama_xpc model loader installed by the host process")


def set_model_loader(loader: Callable[[str], str] | None) -> None:
    """Sets (or with None, clears) the in-process loader: ``loader(alias)`` returns a message
    or raises :class:`ModelLoadError`."""
    global _loader
    with _lock:
        _loader = loader


def has_model_loader() -> bool:
    """Whether this process's host installed a loader."""
    with _lock:
        return _loader is not None


def ensure_model(alias: str, *, allow_remote: bool = True) -> str:
    """Have ``alias`` (a model's slug) loaded in LlamaXPCService; returns the loader's message.

    Uses the in-process loader when the host installed one, else (when
    ``allow_remote``) the app's ``EnsureLlamaModel`` RPC. Raises
    :class:`ModelLoadError` with instructions when neither can load it.
    """
    alias = alias.strip()
    if not alias:
        raise ModelLoadError("no model named; set the model's slug so it can be loaded")
    with _lock:
        loader = _loader
    if loader is not None:
        return loader(alias)
    if not allow_remote:
        raise ModelLoadError(
            f"this process cannot load {alias}: it is not running inside the Garage app. "
            f"Open Garage and load {alias} on the Models page."
        )
    return _ensure_via_grpc(alias)


def _grpc_address() -> tuple[str, int, str | None]:
    """``(host, port, socket path)``: the app's socket (``GARAGE_GRPC_SOCKET``) wins over host and port."""
    host = os.environ.get("GARAGE_GRPC_HOST") or "127.0.0.1"
    try:
        port = int(os.environ.get("GARAGE_GRPC_PORT") or 50051)
    except ValueError:
        port = 50051
    return host, port, os.environ.get("GARAGE_GRPC_SOCKET") or None


def _ensure_via_grpc(alias: str) -> str:
    # Imported here, not at module scope: garage_rag.service depends on search,
    # which depends on embed and so on this module, so a top-level import would be a cycle.
    # gazelle:ignore garage_rag.service.client
    from garage_rag.service.client import GarageClient

    host, port, socket_path = _grpc_address()
    client = GarageClient(host=host, port=port, in_process=False, socket_path=socket_path)
    try:
        return client.ensure_llama_model(alias, timeout=_GRPC_LOAD_TIMEOUT_SECONDS).message
    except Exception as exc:  # grpc.RpcError; grpc itself is only imported by the facade's client
        code, details = _rpc_error_detail(exc)
        if code in (None, "UNAVAILABLE", "UNIMPLEMENTED", "DEADLINE_EXCEEDED"):
            raise ModelLoadError(
                f"{alias} is not loaded, and the Garage app could not load it (gRPC {client.address}: "
                f"{details or code or exc}). Open Garage, which loads models on demand, or load {alias} "
                f"on its Models page."
            ) from exc
        raise ModelLoadError(details or f"loading {alias} failed ({code})") from exc
    finally:
        client.close()


def _rpc_error_detail(exc: BaseException) -> tuple[str | None, str | None]:
    """``(status code name, details)`` of a ``grpc.RpcError``; ``(None, None)`` for anything else."""
    code_fn = getattr(exc, "code", None)
    details_fn = getattr(exc, "details", None)
    if not callable(code_fn):
        return None, None
    try:
        code = code_fn()
        details = details_fn() if callable(details_fn) else None
    except Exception:  # noqa: BLE001 - a malformed error is reported as unknown
        return None, None
    return getattr(code, "name", None) or (str(code) if code is not None else None), details

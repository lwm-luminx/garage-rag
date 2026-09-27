"""Embedding with the app's image embedding service, through the process's Swift host.

``GarageImageEmbedXPCService`` is an XPC service of the app, so only the app can
look it up by name; the helpers whose Python runs backfill and search
(``GarageXPCService``, ``GarageMCPServerService``, the embed worker) reach it
through the listener endpoint the app hands them, and the Python in those
processes reaches it through two C functions their Swift host installs at
start-up (:func:`install_image_embedder`), as :mod:`garage_rag.xpc.host` does
for llama model loads. ctypes releases the GIL for the calls, so an embedding
batch running on the Neural Engine does not stall the interpreter's other
threads.

Nothing here opens a network connection: the functions are local, and the
service is NSXPC on the other side of them. A process whose host installed no
bridge (``garage`` from a venv, the stdio launchers) cannot embed with an image
model; :class:`ImageEmbedUnavailable` says so and where it works.

C signatures (JSON and raw buffers, no Python objects cross):

``int32_t describe(const char *model_ref, char *json, size_t capacity)``
    Loads the model when it is not resident and writes a JSON object
    (``{"dims": 768, "image_size": 256, "text_length": 64}``) into ``json``.
    Nonzero on failure, with the reason in ``json``.

``int32_t embed(const char *request_json, const uint8_t *const *blobs, const size_t *sizes,
size_t count, float *out, size_t out_capacity, char *message, size_t capacity)``
    ``request_json`` is ``{"model": ref, "texts": [...]}`` or ``{"model": ref, "images": n}``;
    for images, ``blobs``/``sizes`` carry ``n`` encoded image files. Writes the
    vectors, one after another, into ``out`` (``out_capacity`` floats). Nonzero on
    failure, with the reason in ``message``.
"""

from __future__ import annotations

import ctypes
import json
import logging
import threading
from collections.abc import Sequence

log = logging.getLogger(__name__)

__all__ = [
    "MESSAGE_CAPACITY",
    "ImageEmbedUnavailable",
    "ImageModelInfo",
    "describe",
    "embed_images",
    "embed_texts",
    "has_image_embedder",
    "install_image_embedder",
    "set_image_embedder",
]

MESSAGE_CAPACITY = 4096

_DESCRIBE_CFUNC = ctypes.CFUNCTYPE(ctypes.c_int32, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_size_t)
_EMBED_CFUNC = ctypes.CFUNCTYPE(
    ctypes.c_int32,
    ctypes.c_char_p,  # request json
    ctypes.POINTER(ctypes.c_char_p),  # blobs
    ctypes.POINTER(ctypes.c_size_t),  # blob sizes
    ctypes.c_size_t,  # blob count
    ctypes.POINTER(ctypes.c_float),  # out
    ctypes.c_size_t,  # out capacity (floats)
    ctypes.c_char_p,  # message
    ctypes.c_size_t,  # message capacity
)


class ImageEmbedUnavailable(RuntimeError):
    """This process cannot embed with an image model; the message says where it works."""


class ImageModelInfo:
    """What the service says about a loaded image model."""

    __slots__ = ("dims", "image_size", "text_length")

    def __init__(self, dims: int, image_size: int, text_length: int) -> None:
        self.dims = dims
        self.image_size = image_size
        self.text_length = text_length


class _Bridge:
    """The two installed functions, plus the ctypes objects that keep them alive."""

    def __init__(self, describe_fn, embed_fn) -> None:
        self.describe_fn = describe_fn
        self.embed_fn = embed_fn


_lock = threading.Lock()
_bridge: _Bridge | None = None
_NO_BRIDGE = (
    "this process has no image embedding bridge: image models embed inside the Garage app "
    "(its backfill, search and MCP server), not from a terminal. Open Garage and run the backfill there."
)


def install_image_embedder(describe_address: int, embed_address: int) -> None:
    """Called by the Swift host with the addresses of its two functions."""
    if not describe_address or not embed_address:
        raise ValueError("image embedder addresses must not be null")
    bridge = _Bridge(_DESCRIBE_CFUNC(describe_address), _EMBED_CFUNC(embed_address))
    global _bridge
    with _lock:
        _bridge = bridge
    log.info("image embedding bridge installed by the host process")


def set_image_embedder(describe_fn, embed_fn) -> None:
    """Sets (or with ``None, None`` clears) the bridge; tests install Python callables
    with the C functions' signatures."""
    global _bridge
    with _lock:
        _bridge = _Bridge(describe_fn, embed_fn) if describe_fn is not None else None


def has_image_embedder() -> bool:
    """Whether this process's host installed the bridge."""
    with _lock:
        return _bridge is not None


def _get_bridge() -> _Bridge:
    with _lock:
        bridge = _bridge
    if bridge is None:
        raise ImageEmbedUnavailable(_NO_BRIDGE)
    return bridge


def describe(model_ref: str) -> ImageModelInfo:
    """Has ``model_ref`` loaded in the service and returns its widths."""
    bridge = _get_bridge()
    buffer = ctypes.create_string_buffer(MESSAGE_CAPACITY)
    status = bridge.describe_fn(model_ref.encode("utf-8"), buffer, MESSAGE_CAPACITY)
    message = buffer.value.decode("utf-8", "replace")
    if status != 0:
        raise ImageEmbedUnavailable(message or f"loading image model {model_ref} failed (status {status})")
    info = json.loads(message)
    return ImageModelInfo(int(info["dims"]), int(info.get("image_size", 0)), int(info.get("text_length", 0)))


def _call_embed(model_ref: str, request: dict, blobs: Sequence[bytes], count: int) -> list[list[float]]:
    bridge = _get_bridge()
    info = describe(model_ref)
    out_len = info.dims * count
    out = (ctypes.c_float * max(out_len, 1))()
    message = ctypes.create_string_buffer(MESSAGE_CAPACITY)
    blob_array = (ctypes.c_char_p * max(len(blobs), 1))(*blobs)
    size_array = (ctypes.c_size_t * max(len(blobs), 1))(*(len(blob) for blob in blobs))
    status = bridge.embed_fn(
        json.dumps({"model": model_ref, **request}).encode("utf-8"),
        blob_array,
        size_array,
        len(blobs),
        out,
        out_len,
        message,
        MESSAGE_CAPACITY,
    )
    if status != 0:
        text = message.value.decode("utf-8", "replace")
        raise RuntimeError(text or f"image_xpc embed failed (status {status})")
    values = list(out[:out_len])
    return [values[i * info.dims : (i + 1) * info.dims] for i in range(count)]


def embed_texts(model_ref: str, texts: Sequence[str]) -> list[list[float]]:
    """Embed ``texts`` with the model's text tower."""
    texts = list(texts)
    if not texts:
        return []
    return _call_embed(model_ref, {"texts": texts}, [], len(texts))


def embed_images(model_ref: str, images: Sequence[bytes]) -> list[list[float]]:
    """Embed encoded image files (JPEG, PNG, HEIC, ...) with the model's image tower."""
    images = list(images)
    if not images:
        return []
    return _call_embed(model_ref, {"images": len(images)}, images, len(images))

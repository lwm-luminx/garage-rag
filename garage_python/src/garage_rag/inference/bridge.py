"""LlamaXPCService over NSXPC, for the Python the app's XPC services embed.

The ``llama_xpc`` provider normally speaks HTTP to LlamaXPCService's
llama-server API (on its socket in the App Group container). Inside the app's
own XPC services (``GarageXPCService``, the embed worker,
``GarageMCPServerService``) there is a shorter way: the Swift host hands Python
the addresses of two C functions at start-up (:func:`install`), and a request
goes straight over the host's NSXPC connection to LlamaXPCService
(``handleServerRequest``), which XPC restricts to processes signed by the same
team. No socket or port is involved.

``int32_t request(const char *method, const char *path, const char *body,
double timeout, int32_t *status, char **reply)`` returns 0 with the HTTP status
and the reply body, or nonzero with the reason in ``reply``; either way
``reply`` is freed with ``void release(char *)``. ctypes releases the GIL for
the call, so a long embedding batch does not stall the interpreter.
"""

from __future__ import annotations

import ctypes
import logging
import threading
from collections.abc import Callable

log = logging.getLogger(__name__)

__all__ = ["BridgeError", "BridgeRequest", "current", "install", "set_bridge"]

_REQUEST = ctypes.CFUNCTYPE(
    ctypes.c_int32,
    ctypes.c_char_p,
    ctypes.c_char_p,
    ctypes.c_char_p,
    ctypes.c_double,
    ctypes.POINTER(ctypes.c_int32),
    ctypes.POINTER(ctypes.c_void_p),
)
_RELEASE = ctypes.CFUNCTYPE(None, ctypes.c_void_p)

# ``request(method, path, body, timeout) -> (status, body)``; raises BridgeError when no reply came.
BridgeRequest = Callable[[str, str, bytes | None, float], tuple[int, bytes]]

_lock = threading.Lock()
_bridge: BridgeRequest | None = None
# The ctypes function objects must live as long as the interpreter.
_c_functions: tuple[object, object] | None = None


class BridgeError(RuntimeError):
    """LlamaXPCService could not be asked (not running, XPC connection lost, timed out)."""


def install(request_address: int, release_address: int) -> None:
    """Called by the Swift host with the addresses of its request and release functions."""
    if not request_address or not release_address:
        raise ValueError("inference bridge address is null")
    c_request = _REQUEST(request_address)
    c_release = _RELEASE(release_address)

    def request(method: str, path: str, body: bytes | None, timeout: float) -> tuple[int, bytes]:
        status = ctypes.c_int32(0)
        reply = ctypes.c_void_p(None)
        result = c_request(method.encode("ascii"), path.encode("utf-8"), body, timeout, status, reply)
        try:
            text = ctypes.string_at(reply.value) if reply.value else b""
        finally:
            if reply.value:
                c_release(reply.value)
        if result != 0:
            raise BridgeError(text.decode("utf-8", "replace") or f"LlamaXPCService request failed ({result})")
        return status.value, text

    global _c_functions
    with _lock:
        _c_functions = (c_request, c_release)
    set_bridge(request)
    log.info("llama_xpc NSXPC bridge installed by the host process")


def set_bridge(bridge: BridgeRequest | None) -> None:
    """Sets (or with None, clears) the bridge; tests install a fake one."""
    global _bridge
    with _lock:
        _bridge = bridge


def current() -> BridgeRequest | None:
    """The installed bridge, or None outside the app's XPC services."""
    with _lock:
        return _bridge

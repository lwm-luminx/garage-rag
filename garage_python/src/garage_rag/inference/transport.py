"""The HTTP transport under :mod:`garage_rag.inference.client`.

The client builds requests and reads replies; this module sends them, and it
does so only through a client from the egress guard,
:func:`garage_rag.net.egress.http_client`. :func:`open_transport` is the one
constructor, so every inference client is checked before any connection exists:

* ``llama_xpc`` is loopback only; Ollama and LM Studio may be loopback or
  exactly the origin configured as ``embedding.ollama_host`` /
  ``embedding.lmstudio_host``;
* given the ``corpus_class`` of what will be sent, a communication is refused
  for any destination that is not loopback;
* the guard's clients ignore proxy variables, never follow redirects and
  refuse any request to another origin.

A refusal is :class:`garage_rag.net.egress.EgressBlocked`.

Inside the app's XPC services a loopback ``llama_xpc`` backend skips HTTP: the
Swift host installs :mod:`garage_rag.inference.bridge`, and requests go over
its NSXPC connection to LlamaXPCService instead. The destination rules are the
same (that is only ever this machine), so nothing else changes.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import TYPE_CHECKING, Any, Protocol

from garage_rag.config import Settings, is_loopback_url
from garage_rag.db.models import CorpusClass
from garage_rag.inference import bridge
from garage_rag.net import egress

if TYPE_CHECKING:
    from garage_rag.inference.client import Backend

__all__ = [
    "RawResponse",
    "Transport",
    "TransportError",
    "open_transport",
]


class TransportError(RuntimeError):
    """The request never produced an HTTP reply (refused, reset, timed out)."""


@dataclass(frozen=True)
class RawResponse:
    status: int
    body: bytes


class Transport(Protocol):
    """What :class:`~garage_rag.inference.client.InferenceClient` needs from HTTP."""

    def request(self, method: str, path: str, body: dict[str, Any] | None = None) -> RawResponse: ...

    def close(self) -> None: ...


class _GuardedTransport:
    def __init__(self, backend: Backend, corpus_class: CorpusClass | None, settings: Settings | None) -> None:
        headers = {"Accept": "application/json"}
        if backend.token:
            headers["Authorization"] = f"Bearer {backend.token}"
        self._client = egress.http_client(
            purpose=f"inference:{backend.kind}",
            base_url=backend.base_url,
            corpus_class=corpus_class,
            loopback_only=str(backend.kind) == "llama_xpc",
            timeout=backend.timeout,
            headers=headers,
            settings=settings,
            uds=backend.socket_path,
        )

    def request(self, method: str, path: str, body: dict[str, Any] | None = None) -> RawResponse:
        content = None
        headers = {}
        if body is not None:
            content = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        try:
            response = self._client.request(method, path, content=content, headers=headers)
        except egress.TransportTimeout as exc:
            raise TransportError(f"timed out ({type(exc).__name__})") from exc
        except egress.TransportError as exc:
            raise TransportError(str(exc) or type(exc).__name__) from exc
        return RawResponse(status=response.status_code, body=response.content)

    def close(self) -> None:
        self._client.close()


class _BridgeTransport:
    """LlamaXPCService over the host's NSXPC connection (:mod:`garage_rag.inference.bridge`)."""

    def __init__(self, request: bridge.BridgeRequest, timeout: float) -> None:
        self._request = request
        self._timeout = timeout

    def request(self, method: str, path: str, body: dict[str, Any] | None = None) -> RawResponse:
        content = json.dumps(body).encode("utf-8") if body is not None else None
        try:
            status, reply = self._request(method, path, content, self._timeout)
        except bridge.BridgeError as exc:
            raise TransportError(str(exc)) from exc
        return RawResponse(status=status, body=reply)

    def close(self) -> None:
        pass


def open_transport(
    backend: Backend, *, corpus_class: CorpusClass | None = None, settings: Settings | None = None
) -> Transport:
    """The one way an inference client gets a connection: through the egress guard.

    ``settings`` names the approved hosts (default: the loaded configuration). A
    loopback ``llama_xpc`` backend uses the host's NSXPC bridge when one is installed.
    """
    request = bridge.current()
    if request is not None and str(backend.kind) == "llama_xpc" and is_loopback_url(backend.base_url):
        return _BridgeTransport(request, backend.timeout)
    return _GuardedTransport(backend, corpus_class, settings)

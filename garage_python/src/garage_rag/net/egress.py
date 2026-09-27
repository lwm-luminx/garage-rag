"""The single point through which anything leaves this process over the network.

This is the only module allowed to import an outbound network client library
(``httpx``, ``urllib.request``, ...); ``tests/test_egress_block.py``
scans every source file's AST, function-local imports included, and fails if
another module does. Every outbound client is therefore built here, and every one
is checked before it is built:

1. **Content rule, first.** Content of ``corpus_class = 'communication'`` never
   goes to a destination that is not loopback. A caller that knows what it is
   about to send passes ``corpus_class``; :func:`check_destination` refuses a
   communication before looking at anything else, and :func:`allows_communications`
   answers the question for callers that filter content themselves (backfill).
2. **Destination allowlist.** A destination is approved when it is loopback --
   the app's own services (``llama_xpc`` on ``embedding.llama_host``) and local
   Ollama / LM Studio -- or when it is exactly the origin configured as
   ``embedding.ollama_host`` or ``embedding.lmstudio_host``, which may be another
   machine. Anything else raises :class:`EgressBlocked`. There is no setting that
   adds other hosts.
3. **Hardened clients.** The clients built here ignore proxy environment
   variables and never follow redirects, and the ``httpx``-based ones re-check
   every request's URL against the origin they were built for, so neither a
   ``http_proxy`` nor a server's ``Location`` header can send content elsewhere.

Inbound and local infrastructure does not go through here: the gRPC server and
the generated stubs, the MCP server (uvicorn), and psycopg's connection to
Postgres. The gRPC *client* of the app's facade checks its address with
:func:`check_destination` (``loopback_only=True``).

Public API: :func:`check_destination`, :func:`allows_communications`,
:func:`approved_destinations`, :func:`is_loopback_url`, the client builders
:func:`http_client` and :func:`url_opener`, and the
exceptions :class:`EgressBlocked`, :data:`TransportError` and
:data:`TransportTimeout`.
"""

from __future__ import annotations

import logging
import urllib.error
import urllib.request
from collections.abc import Mapping
from typing import Any, NamedTuple
from urllib.parse import urlsplit

import httpx

from garage_rag.config import Settings, get_settings, is_loopback_url
from garage_rag.db.models import CorpusClass

log = logging.getLogger(__name__)

__all__ = [
    "EgressBlocked",
    "TransportError",
    "TransportTimeout",
    "UrlOpener",
    "allows_communications",
    "approved_destinations",
    "check_destination",
    "http_client",
    "is_loopback_url",
    "url_opener",
]

# Failures of the httpx-based clients built here, for callers that must not
# import httpx themselves.
TransportError = httpx.HTTPError
TransportTimeout = httpx.TimeoutException


class EgressBlocked(PermissionError):
    """Sending to this destination, or sending this content there, is not permitted."""


class _Origin(NamedTuple):
    scheme: str
    host: str
    port: int


def _origin(url: str) -> _Origin | None:
    """``(scheme, host, port)`` of ``url``; a bare ``host:port`` counts as http."""
    if "://" not in url:
        url = f"http://{url}"
    try:
        parts = urlsplit(url)
        port = parts.port
    except ValueError:
        return None
    scheme = (parts.scheme or "http").lower()
    host = (parts.hostname or "").lower().rstrip(".")
    if not host or scheme not in ("http", "https"):
        return None
    return _Origin(scheme, host, port if port is not None else (443 if scheme == "https" else 80))


def approved_destinations(settings: Settings | None = None) -> list[str]:
    """The configured model-server origins approved in addition to any loopback URL."""
    settings = settings or get_settings()
    return [settings.ollama_host, settings.lmstudio_host]


def _approved(url: str, settings: Settings | None) -> bool:
    if is_loopback_url(url):
        return True
    origin = _origin(url)
    return origin is not None and origin in {_origin(u) for u in approved_destinations(settings)}


def allows_communications(url: str) -> bool:
    """Whether communication content may be sent to ``url``: only when it is loopback."""
    return is_loopback_url(url)


def check_destination(
    url: str,
    *,
    purpose: str,
    corpus_class: CorpusClass | None = None,
    loopback_only: bool = False,
    settings: Settings | None = None,
) -> str:
    """Return ``url`` if content for ``purpose`` may go there, else raise :class:`EgressBlocked`.

    ``corpus_class`` names what will be sent, when the caller knows; a
    communication is refused for any destination that is not loopback, before
    anything else is considered. ``loopback_only`` is for the app's own services,
    which are never anywhere else.
    """
    if corpus_class is CorpusClass.COMMUNICATION and not allows_communications(url):
        raise EgressBlocked(f"{purpose}: communications may never be sent off this machine (to {url!r})")
    if loopback_only:
        if not is_loopback_url(url):
            raise EgressBlocked(f"{purpose}: {url!r} must be a loopback URL (localhost, 127.0.0.1 or ::1)")
        return url
    if not _approved(url, settings):
        raise EgressBlocked(
            f"{purpose}: {url!r} is not an approved destination; content goes only to loopback or to "
            "the model servers configured as embedding.ollama_host / embedding.lmstudio_host"
        )
    return url


def _pinned_hook(purpose: str, origin: _Origin):
    """An httpx request hook that refuses any request not addressed to ``origin``."""

    def check(request: httpx.Request) -> None:
        if _origin(str(request.url)) != origin:
            raise EgressBlocked(f"{purpose}: request to {request.url} leaves the approved origin")

    return check


def http_client(
    *,
    purpose: str,
    base_url: str,
    corpus_class: CorpusClass | None = None,
    loopback_only: bool = False,
    timeout: float = 120.0,
    headers: Mapping[str, str] | None = None,
    settings: Settings | None = None,
    uds: str | None = None,
) -> httpx.Client:
    """An ``httpx.Client`` for ``base_url``, after :func:`check_destination`.

    No proxies, no redirects, and every request is re-checked against the origin
    of ``base_url``. With ``uds`` (an absolute path) the client connects to that
    Unix-domain socket instead of ``base_url``'s host, which then must be loopback:
    a socket is on this machine, and the origin check still applies to every request.
    """
    if uds is not None:
        if not uds.startswith("/"):
            raise EgressBlocked(f"{purpose}: socket path must be absolute: {uds!r}")
        loopback_only = True
    check_destination(
        base_url, purpose=purpose, corpus_class=corpus_class, loopback_only=loopback_only, settings=settings
    )
    origin = _origin(base_url)
    assert origin is not None  # check_destination refused anything unparseable
    return httpx.Client(
        transport=httpx.HTTPTransport(uds=uds) if uds is not None else None,
        base_url=base_url.rstrip("/"),
        timeout=timeout,
        headers=dict(headers or {}),
        trust_env=False,
        follow_redirects=False,
        event_hooks={"request": [_pinned_hook(purpose, origin)]},
    )


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Surface a 3xx as an HTTP error instead of following it somewhere else."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: ANN001, ANN201
        return None


class UrlOpener:
    """A stdlib (``urllib``) client pinned to one approved origin; see :func:`url_opener`."""

    def __init__(self, purpose: str, base_url: str) -> None:
        self.purpose = purpose
        self._origin = _origin(base_url)
        self._opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect())

    def request(
        self,
        method: str,
        url: str,
        *,
        data: bytes | None = None,
        headers: Mapping[str, str] | None = None,
        timeout: float,
    ) -> tuple[int, bytes]:
        """Send one request; return ``(status, body)`` for any HTTP status.

        Raises :class:`OSError` when the server cannot be reached, and
        :class:`EgressBlocked` when ``url`` is not on the pinned origin.
        """
        if _origin(url) != self._origin:
            raise EgressBlocked(f"{self.purpose}: request to {url} leaves the approved origin")
        request = urllib.request.Request(url, data=data, headers=dict(headers or {}), method=method)
        try:
            with self._opener.open(request, timeout=timeout) as response:
                return response.status, response.read()
        except urllib.error.HTTPError as exc:
            return exc.code, exc.read()
        except urllib.error.URLError as exc:
            reason: Any = exc.reason
            raise OSError(str(reason)) from exc


def url_opener(*, purpose: str, base_url: str, loopback_only: bool = False) -> UrlOpener:
    """A :class:`UrlOpener` for ``base_url``, after :func:`check_destination`."""
    check_destination(base_url, purpose=purpose, loopback_only=loopback_only)
    return UrlOpener(purpose, base_url)

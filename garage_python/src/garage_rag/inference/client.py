"""One HTTP client for the three local inference servers Garage talks to.

* ``lmstudio`` -- LM Studio. Inference on its OpenAI-compatible ``/v1``
  routes; model management (list, load, unload, download) on its native REST
  API under ``/api/v1``. Both take the same optional bearer token.
* ``ollama`` -- Ollama. Chat and the model list on its OpenAI-compatible
  ``/v1`` routes; embeddings on ``/api/embed`` by default (see
  :attr:`Backend.ollama_embed_route`).
* ``llama_xpc`` -- the llama-server-compatible API the app's LlamaXPCService
  serves on loopback (``embedding.llama_host``). Its llama-server-only routes
  live on :class:`garage_rag.xpc.llama_xpc.LlamaXPCClient`, a subclass.

Every route answers JSON, and every failure comes out as an
:class:`InferenceError` subclass carrying an HTTP-ish ``status_code``:

* :class:`InferenceUnreachable` (503) -- no HTTP reply at all;
* :class:`InferenceHTTPError` -- a non-2xx reply, with the server's message and
  error ``type`` when it gives one; :class:`InferenceAuthError` for 401/403;
* :class:`InferenceErrorBody` -- a 2xx reply whose body is an ``{"error": ...}``
  object. LM Studio answers unknown routes that way (HTTP 200,
  ``{"error": "Unexpected endpoint or method. ..."}``), so a 2xx is not trusted
  on its own;
* :class:`InferenceBadReply` (502) -- non-JSON, or JSON missing what the route
  promises;
* :class:`InferenceUnsupported` (501) -- the operation does not exist on this
  kind of server (model management on anything but LM Studio);
* :class:`InferenceRefused` (400) -- the egress guard refused the server, or
  refused this content for it; also a
  :class:`~garage_rag.net.egress.EgressBlocked`.

What the client deliberately does not do:

* It never sends ``dimensions`` for embeddings. LM Studio ignores it and
  returns full-width vectors; Garage truncates on its side
  (``db.registry.truncate_vector``), so the server is never relied on for it.
* It never adds a ``response_format`` of its own. Callers may pass one, but
  ``{"type": "json_object"}`` is rejected by LM Studio with HTTP 400; use
  :func:`json_schema_format` there, or no response format at all.

The socket side is :mod:`garage_rag.inference.transport`, which gets its HTTP
client from the egress guard (:mod:`garage_rag.net.egress`): ``llama_xpc`` is
loopback only, Ollama and LM Studio are loopback or their configured origin,
and a client built with ``corpus_class=COMMUNICATION`` refuses any server that
is not loopback. Pass the class of what you are about to send when you know it.
"""

from __future__ import annotations

import json
import time
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
from enum import StrEnum
from typing import Any, Literal, Self, cast

from garage_rag.config import Settings, get_settings, is_loopback_url, llama_socket_path
from garage_rag.db.models import CorpusClass
from garage_rag.inference.transport import Transport, TransportError, open_transport
from garage_rag.net.egress import EgressBlocked

__all__ = [
    "Backend",
    "BackendKind",
    "ChatResult",
    "DownloadJob",
    "InferenceAuthError",
    "InferenceBadReply",
    "InferenceClient",
    "InferenceError",
    "InferenceErrorBody",
    "InferenceHTTPError",
    "InferenceRefused",
    "InferenceUnreachable",
    "InferenceUnsupported",
    "LMStudioModel",
    "LoadedInstance",
    "LoadResult",
    "is_loopback_url",
    "json_schema_format",
]


class BackendKind(StrEnum):
    LMSTUDIO = "lmstudio"
    OLLAMA = "ollama"
    LLAMA_XPC = "llama_xpc"


_LABELS = {
    BackendKind.LMSTUDIO: "LM Studio",
    BackendKind.OLLAMA: "Ollama",
    BackendKind.LLAMA_XPC: "LlamaXPCService",
}


def _normalise_base_url(url: str) -> str:
    """Scheme added when missing; no trailing slash; no trailing ``/v1``.

    ``embedding.lmstudio_host`` is documented as the ``/v1`` URL, but the
    native REST API lives under ``/api/v1`` on the same server, so the client
    keeps the server root and adds the prefix per route.
    """
    url = url.strip()
    if "://" not in url:
        url = f"http://{url}"
    url = url.rstrip("/")
    if url.endswith("/v1"):
        url = url[: -len("/v1")]
    return url


@dataclass(frozen=True)
class Backend:
    """Where one inference server is and how to talk to it."""

    kind: BackendKind
    base_url: str
    token: str | None = field(default=None, repr=False)
    # Generous: a first request may JIT-load a model (LM Studio took 20 s for
    # an embedding model), and fact distillation of a long document is slow.
    timeout: float = 600.0
    # Retries after no reply or HTTP 408/409/429/5xx, with a short backoff
    # (0.5 s, 1 s, ...). Off by default; the LM Studio embedder keeps the two
    # the openai SDK it replaced made.
    max_retries: int = 0
    # Ollama embeddings: "native" is ``POST /api/embed`` (what the ``ollama``
    # package called, so the vectors already stored came from it); "openai" is
    # ``POST /v1/embeddings``. Parity between the two is unproven -- see
    # tests/test_inference_live.py -- so native stays the default.
    ollama_embed_route: Literal["native", "openai"] = "native"
    # LlamaXPCService on its Unix-domain socket (``GARAGE_LLAMA_SOCKET``, which the
    # app's processes export) rather than on ``base_url``'s TCP port; ``base_url``
    # still names the origin every request is checked against.
    socket_path: str | None = None

    def __post_init__(self) -> None:
        object.__setattr__(self, "kind", BackendKind(self.kind))
        object.__setattr__(self, "base_url", _normalise_base_url(self.base_url))
        if self.socket_path is None and self.kind is BackendKind.LLAMA_XPC and is_loopback_url(self.base_url):
            object.__setattr__(self, "socket_path", llama_socket_path())

    @classmethod
    def from_settings(
        cls,
        kind: BackendKind | str,
        settings: Settings | None = None,
        *,
        base_url: str | None = None,
        token: str | None = None,
    ) -> Backend:
        """The backend the configuration names for ``kind``.

        ``lmstudio`` reads its token through ``Settings.read_lmstudio_api_token``
        (``GARAGE_LMSTUDIO_API_TOKEN`` or ``embedding.lmstudio_api_token_file``).
        """
        settings = settings or get_settings()
        kind = BackendKind(kind)
        if kind is BackendKind.LMSTUDIO:
            return cls(
                kind,
                base_url or settings.lmstudio_host,
                token=token or settings.read_lmstudio_api_token(),
            )
        if kind is BackendKind.OLLAMA:
            return cls(kind, base_url or settings.ollama_host, token=token)
        return cls(kind, base_url or settings.llama_host, token=token)

    @property
    def label(self) -> str:
        return _LABELS[self.kind]

    @property
    def where(self) -> str:
        """Where requests go, for messages: the socket when there is one, else ``base_url``."""
        return f"unix:{self.socket_path}" if self.socket_path else self.base_url

    @property
    def is_local(self) -> bool:
        """Whether the server is on this machine, so communications may be sent to it."""
        return is_loopback_url(self.base_url)


# ---- errors ----------------------------------------------------------------


class InferenceError(RuntimeError):
    """An inference server refused, failed, or could not be reached."""

    def __init__(self, message: str, *, status_code: int = 500, error_type: str | None = None) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.error_type = error_type


class InferenceUnreachable(InferenceError):
    """No HTTP reply: connection refused or reset, or a timeout."""


class InferenceHTTPError(InferenceError):
    """The server answered with an error."""


class InferenceAuthError(InferenceHTTPError):
    """HTTP 401/403: the server wants a (different) token."""


class InferenceErrorBody(InferenceHTTPError):
    """HTTP 2xx whose body is an ``{"error": ...}`` object (LM Studio's unknown routes)."""


class InferenceBadReply(InferenceError):
    """The reply is not JSON, or lacks what the route promises."""


class InferenceUnsupported(InferenceError):
    """This kind of server does not offer the operation."""


class InferenceRefused(InferenceError, EgressBlocked):
    """The egress guard refused the server, or this content for it; nothing was sent.

    Also a :class:`~garage_rag.net.egress.EgressBlocked`, so callers that catch
    the guard's refusal catch this one too.
    """


def _error_detail(payload: Any) -> tuple[str | None, str | None]:
    """``(message, type)`` out of an error body in any of the shapes the servers use.

    OpenAI / llama-server / LM Studio REST: ``{"error": {"message", "type"}}``;
    Ollama and LM Studio's unknown routes: ``{"error": "text"}``.
    """
    if not isinstance(payload, dict):
        return None, None
    error = payload.get("error")
    if isinstance(error, dict):
        message = error.get("message")
        kind = error.get("type") or error.get("code")
        return (str(message) if message else None), (str(kind) if kind else None)
    if isinstance(error, str) and error:
        return error, None
    return None, None


# ---- results ---------------------------------------------------------------


@dataclass(frozen=True)
class ChatResult:
    """One chat completion."""

    text: str
    finish_reason: str | None = None
    prompt_tokens: int | None = None
    completion_tokens: int | None = None
    model: str | None = None
    raw: Mapping[str, Any] = field(default_factory=dict, repr=False, compare=False)


@dataclass(frozen=True)
class LoadedInstance:
    id: str
    config: Mapping[str, Any] = field(default_factory=dict)


@dataclass(frozen=True)
class LMStudioModel:
    """One downloaded model, from LM Studio's ``GET /api/v1/models``."""

    key: str
    type: str | None
    loaded_instances: tuple[LoadedInstance, ...] = ()
    max_context_length: int | None = None
    raw: Mapping[str, Any] = field(default_factory=dict, repr=False, compare=False)

    @property
    def is_loaded(self) -> bool:
        return bool(self.loaded_instances)


@dataclass(frozen=True)
class LoadResult:
    """LM Studio's reply to ``POST /api/v1/models/load``.

    ``load_config`` is what the server actually applied. Read it rather than
    trusting the request: ``context_length`` is silently ignored for some
    models (MLX, on the M3 probe).
    """

    instance_id: str
    type: str | None
    status: str | None
    load_time_seconds: float | None
    load_config: Mapping[str, Any] = field(default_factory=dict)
    raw: Mapping[str, Any] = field(default_factory=dict, repr=False, compare=False)


DownloadStatus = Literal["downloading", "paused", "completed", "failed", "already_downloaded"]


@dataclass(frozen=True)
class DownloadJob:
    """LM Studio's reply to ``POST /api/v1/models/download``.

    ``job_id`` is absent when there is nothing to do (``already_downloaded``).
    """

    status: str
    job_id: str | None = None
    total_size_bytes: int | None = None
    started_at: str | None = None
    completed_at: str | None = None
    raw: Mapping[str, Any] = field(default_factory=dict, repr=False, compare=False)

    @property
    def finished(self) -> bool:
        return self.status in ("completed", "already_downloaded", "failed")


def json_schema_format(name: str, schema: Mapping[str, Any], *, strict: bool = True) -> dict[str, Any]:
    """A ``response_format`` every backend accepts (LM Studio refuses ``json_object``)."""
    return {"type": "json_schema", "json_schema": {"name": name, "strict": strict, "schema": dict(schema)}}


def _int_or_none(value: Any) -> int | None:
    try:
        return int(value) if value is not None else None
    except (TypeError, ValueError):
        return None


def _float_or_none(value: Any) -> float | None:
    try:
        return float(value) if value is not None else None
    except (TypeError, ValueError):
        return None


def _str_or_none(value: Any) -> str | None:
    return str(value) if value is not None else None


# ---- the client ------------------------------------------------------------

_RETRY_STATUSES = frozenset({408, 409, 429})


class InferenceClient:
    """Embeddings, chat and model listing on any backend; model management on LM Studio."""

    def __init__(
        self,
        backend: Backend,
        *,
        corpus_class: CorpusClass | None = None,
        settings: Settings | None = None,
        transport: Transport | None = None,
    ) -> None:
        """``corpus_class`` is the class of the content this client will carry, when known;
        ``settings`` supplies the approved hosts (default: the loaded configuration)."""
        self.backend = backend
        if transport is None:
            try:
                transport = open_transport(backend, corpus_class=corpus_class, settings=settings)
            except EgressBlocked as exc:
                raise InferenceRefused(str(exc), status_code=400) from exc
        self._transport = transport

    @classmethod
    def from_settings(cls, kind: BackendKind | str, settings: Settings | None = None, **overrides: Any) -> Self:
        return cls(Backend.from_settings(kind, settings, **overrides), settings=settings)

    @property
    def kind(self) -> BackendKind:
        return self.backend.kind

    @property
    def base_url(self) -> str:
        return self.backend.base_url

    def close(self) -> None:
        self._transport.close()

    def __enter__(self) -> Self:
        return self

    def __exit__(self, *_exc: object) -> None:
        self.close()

    # ---- transport -------------------------------------------------------

    def _send(self, method: str, path: str, body: dict[str, Any] | None) -> Any:
        """One reply, after up to ``backend.max_retries`` retries of a transient failure."""
        for attempt in range(self.backend.max_retries + 1):
            last = attempt == self.backend.max_retries
            try:
                reply = self._transport.request(method, path, body)
            except TransportError as exc:
                if last:
                    raise InferenceUnreachable(
                        f"cannot reach {self.backend.label} at {self.backend.where}: {exc}", status_code=503
                    ) from exc
            else:
                if last or not (reply.status in _RETRY_STATUSES or reply.status >= 500):
                    return reply
            time.sleep(0.5 * 2**attempt)
        raise AssertionError("unreachable")

    def _request(self, method: str, path: str, body: dict[str, Any] | None = None) -> tuple[int, Any]:
        """``(status, decoded JSON)``; raises only for no reply, or a 2xx that is not JSON."""
        reply = self._send(method, path, body)
        try:
            payload = json.loads(reply.body) if reply.body else {}
        except ValueError as exc:
            if 200 <= reply.status < 300:
                raise InferenceBadReply(
                    f"{method} {path}: non-JSON reply from {self.backend.label} (HTTP {reply.status})",
                    status_code=502,
                ) from exc
            # An error page from a proxy or a crashed server: keep a readable snippet.
            payload = {"error": reply.body[:200].decode("utf-8", "replace").strip()}
        return reply.status, payload

    def _call(self, method: str, path: str, body: dict[str, Any] | None = None) -> dict[str, Any]:
        """One request whose reply must be a 2xx JSON object without an ``error`` key."""
        status, payload = self._request(method, path, body)
        message, error_type = _error_detail(payload)
        where = f"{method} {path}"
        if not 200 <= status < 300:
            text = message or f"HTTP {status}"
            if status in (401, 403):
                hint = (
                    "; set GARAGE_LMSTUDIO_API_TOKEN or embedding.lmstudio_api_token_file"
                    if self.kind is BackendKind.LMSTUDIO
                    else ""
                )
                raise InferenceAuthError(
                    f"{where}: {self.backend.label} refused the request (HTTP {status}): {text}{hint}",
                    status_code=status,
                    error_type=error_type,
                )
            raise InferenceHTTPError(f"{where}: {text}", status_code=status, error_type=error_type)
        if isinstance(payload, dict) and payload.get("error"):
            # LM Studio: HTTP 200 {"error": "Unexpected endpoint or method. ..."}.
            raise InferenceErrorBody(
                f"{where}: {self.backend.label} replied HTTP {status} with an error: {message or payload['error']}",
                status_code=status,
                error_type=error_type,
            )
        if not isinstance(payload, dict):
            raise InferenceBadReply(f"{where}: expected a JSON object, got {type(payload).__name__}", status_code=502)
        return payload

    def _require_lmstudio(self, operation: str) -> None:
        if self.kind is not BackendKind.LMSTUDIO:
            raise InferenceUnsupported(
                f"{operation} is an LM Studio operation; {self.backend.label} does not offer it", status_code=501
            )

    # ---- models ----------------------------------------------------------

    def list_models(self) -> list[str]:
        """``GET /v1/models``: the model ids the server will answer for."""
        payload = self._call("GET", "/v1/models")
        data = payload.get("data")
        if not isinstance(data, list):
            raise InferenceBadReply("GET /v1/models: reply has no 'data' list", status_code=502)
        return [str(item["id"]) for item in data if isinstance(item, dict) and item.get("id")]

    def has_model(self, model: str) -> bool:
        """Whether ``model`` is among :meth:`list_models`.

        Ollama lists tagged names, so an untagged ``name`` matches ``name:latest``.
        """
        served = set(self.list_models())
        if model in served:
            return True
        return self.kind is BackendKind.OLLAMA and ":" not in model and f"{model}:latest" in served

    # ---- inference -------------------------------------------------------

    def embed(self, texts: Sequence[str], model: str | None = None) -> list[list[float]]:
        """One vector per text, in input order. An empty batch sends nothing."""
        inputs = list(texts)
        if not inputs:
            return []
        if self.kind is BackendKind.OLLAMA and self.backend.ollama_embed_route == "native":
            return self._embed_ollama_native(inputs, model)
        body: dict[str, Any] = {"input": inputs}
        if model:
            body["model"] = model
        payload = self._call("POST", "/v1/embeddings", body)
        data = payload.get("data")
        if not isinstance(data, list):
            raise InferenceBadReply("POST /v1/embeddings: reply has no 'data' list", status_code=502)
        items = cast(list[dict[str, Any]], data)
        try:
            ordered = sorted(items, key=lambda item: int(item["index"]))
            vectors = [[float(x) for x in item["embedding"]] for item in ordered]
        except (KeyError, TypeError, ValueError) as exc:
            raise InferenceBadReply(f"POST /v1/embeddings: malformed embedding item: {exc}", status_code=502) from exc
        return self._check_count(vectors, inputs, "/v1/embeddings")

    def _embed_ollama_native(self, inputs: list[str], model: str | None) -> list[list[float]]:
        if not model:
            raise ValueError("Ollama embeddings need a model name")
        payload = self._call("POST", "/api/embed", {"model": model, "input": inputs})
        embeddings = payload.get("embeddings")
        if not isinstance(embeddings, list):
            raise InferenceBadReply("POST /api/embed: reply has no 'embeddings' list", status_code=502)
        try:
            vectors = [[float(x) for x in vector] for vector in embeddings]
        except (TypeError, ValueError) as exc:
            raise InferenceBadReply(f"POST /api/embed: malformed embedding: {exc}", status_code=502) from exc
        return self._check_count(vectors, inputs, "/api/embed")

    @staticmethod
    def _check_count(vectors: list[list[float]], inputs: list[str], path: str) -> list[list[float]]:
        if len(vectors) != len(inputs):
            raise InferenceBadReply(f"POST {path}: {len(vectors)} vectors for {len(inputs)} inputs", status_code=502)
        return vectors

    def chat(
        self,
        messages: Sequence[Mapping[str, Any]],
        model: str | None = None,
        *,
        max_tokens: int | None = None,
        temperature: float | None = None,
        response_format: Mapping[str, Any] | None = None,
    ) -> ChatResult:
        """``POST /v1/chat/completions``; the first choice's text plus token accounting."""
        body: dict[str, Any] = {"messages": [dict(message) for message in messages]}
        if model:
            body["model"] = model
        if max_tokens is not None:
            body["max_tokens"] = max_tokens
        if temperature is not None:
            body["temperature"] = temperature
        if response_format is not None:
            body["response_format"] = dict(response_format)
        payload = self._call("POST", "/v1/chat/completions", body)
        try:
            choice = payload["choices"][0]
            content = choice["message"].get("content")
        except (KeyError, IndexError, TypeError, AttributeError) as exc:
            raise InferenceBadReply(f"POST /v1/chat/completions: malformed reply ({exc!r})", status_code=502) from exc
        usage = payload.get("usage")
        if not isinstance(usage, dict):
            usage = {}
        return ChatResult(
            text=str(content or ""),
            finish_reason=_str_or_none(choice.get("finish_reason")),
            prompt_tokens=_int_or_none(usage.get("prompt_tokens")),
            completion_tokens=_int_or_none(usage.get("completion_tokens")),
            model=_str_or_none(payload.get("model")),
            raw=payload,
        )

    # ---- LM Studio model management (native REST, /api/v1) ---------------

    def lmstudio_models(self) -> list[LMStudioModel]:
        """``GET /api/v1/models``: every downloaded model, its type and what is loaded."""
        self._require_lmstudio("listing models with their load state")
        payload = self._call("GET", "/api/v1/models")
        models = payload.get("models")
        if not isinstance(models, list):
            raise InferenceBadReply("GET /api/v1/models: reply has no 'models' list", status_code=502)
        result: list[LMStudioModel] = []
        for item in models:
            if not isinstance(item, dict) or not item.get("key"):
                continue
            instances = tuple(
                LoadedInstance(id=str(inst["id"]), config=dict(inst.get("config") or {}))
                for inst in item.get("loaded_instances") or []
                if isinstance(inst, dict) and inst.get("id")
            )
            result.append(
                LMStudioModel(
                    key=str(item["key"]),
                    type=_str_or_none(item.get("type")),
                    loaded_instances=instances,
                    max_context_length=_int_or_none(item.get("max_context_length")),
                    raw=item,
                )
            )
        return result

    def load_model(self, model: str, *, context_length: int | None = None) -> LoadResult:
        """``POST /api/v1/models/load``; returns what was actually loaded, with its config echoed."""
        self._require_lmstudio("load_model")
        body: dict[str, Any] = {"model": model, "echo_load_config": True}
        if context_length is not None:
            body["context_length"] = context_length
        payload = self._call("POST", "/api/v1/models/load", body)
        instance_id = payload.get("instance_id")
        if not instance_id:
            raise InferenceBadReply("POST /api/v1/models/load: reply has no 'instance_id'", status_code=502)
        return LoadResult(
            instance_id=str(instance_id),
            type=_str_or_none(payload.get("type")),
            status=_str_or_none(payload.get("status")),
            load_time_seconds=_float_or_none(payload.get("load_time_seconds")),
            load_config=dict(payload.get("load_config") or {}),
            raw=payload,
        )

    def unload_model(self, instance_id: str) -> str:
        """``POST /api/v1/models/unload``; returns the unloaded instance id.

        An unknown id is HTTP 404 with ``error.type == "model_not_found"``,
        raised as :class:`InferenceHTTPError`.
        """
        self._require_lmstudio("unload_model")
        payload = self._call("POST", "/api/v1/models/unload", {"instance_id": instance_id})
        return str(payload.get("instance_id") or instance_id)

    def download_model(self, model: str, *, quantization: str | None = None) -> DownloadJob:
        """``POST /api/v1/models/download``: start a download and return the job as the server reports it.

        TODO: polling a job's progress. The status route is not confirmed on
        LM Studio 0.4.25, so none is guessed at here; until it is, call again
        and read ``status`` (``already_downloaded`` once it is on disk), or
        watch :meth:`lmstudio_models`.
        """
        self._require_lmstudio("download_model")
        body: dict[str, Any] = {"model": model}
        if quantization:
            body["quantization"] = quantization
        payload = self._call("POST", "/api/v1/models/download", body)
        status = payload.get("status")
        if not status:
            raise InferenceBadReply("POST /api/v1/models/download: reply has no 'status'", status_code=502)
        return DownloadJob(
            status=str(status),
            job_id=_str_or_none(payload.get("job_id")),
            total_size_bytes=_int_or_none(payload.get("total_size_bytes")),
            started_at=_str_or_none(payload.get("started_at")),
            completed_at=_str_or_none(payload.get("completed_at")),
            raw=payload,
        )

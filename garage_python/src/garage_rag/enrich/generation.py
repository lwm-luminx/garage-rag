"""Local text generation for the ``rag_ask`` / ``rag_generate`` MCP tools and ``garage ask``.

:class:`LocalChatModel` is a small provider-neutral chat client built from the
``facts`` section of the configuration (``facts.provider`` / ``facts.model``).
Every provider is a **local inference server**, the app's own or the owner's,
reached through :class:`garage_rag.inference.InferenceClient` (built through the
egress guard, :mod:`garage_rag.net.egress`) on its OpenAI-compatible
``/v1/chat/completions`` route; there is no cloud path here at all
(``test_egress_block`` fails the build if any module imports a cloud AI SDK):

* ``llama_xpc`` -- the llama.cpp HTTP API the app's ``LlamaXPCService`` serves
  on ``embedding.llama_host`` (default ``http://127.0.0.1:8790``). The engine
  holds several models at once and picks one by the ``model`` alias in each
  request, so every call names ``facts.model``. Loopback only.
* ``ollama`` -- an Ollama server on ``embedding.ollama_host`` (default
  ``http://localhost:11434``). It may be another machine.
* ``lmstudio`` -- a local LM Studio server on ``embedding.lmstudio_host``
  (default ``http://localhost:1234/v1``), with the same optional token as its
  embeddings. LM Studio loads the model on first use. It may be another machine.

Retrieved chunks -- communications included -- may be placed in a prompt to a
loopback server; that is local inference on the owner's own machine, the same
as embedding them. For a server that is not loopback the caller checks each
chunk's class with :func:`garage_rag.net.egress.check_destination` first
(``rag_ask`` does), so a communication never goes there.
"""

from __future__ import annotations

import logging
from collections.abc import Sequence
from dataclasses import dataclass

from garage_rag.config import Settings, get_settings
from garage_rag.inference import Backend, InferenceClient, InferenceError
from garage_rag.net import egress
from garage_rag.xpc.llama_xpc import LlamaXPCClient

log = logging.getLogger(__name__)

__all__ = [
    "PROVIDERS",
    "ChatReply",
    "LocalChatModel",
    "LocalModelUnavailable",
]

PROVIDERS = ("llama_xpc", "ollama", "lmstudio")

_PROVIDER_LABEL = {
    "llama_xpc": "the app's LlamaXPCService",
    "ollama": "the local Ollama server",
    "lmstudio": "the local LM Studio server",
}

_HINTS = {
    "llama_xpc": "download it on the app's Models page (Fact distillation); Garage loads it when needed",
    "ollama": "pull it with 'ollama pull {model}'",
    "lmstudio": "download it in LM Studio (or 'lms get {model}')",
}


class LocalModelUnavailable(RuntimeError):
    """The configured local model could not answer.

    The message names the provider, host and model that were tried and how to
    fix it, because from an MCP client the only thing the person sees is this
    string.
    """


@dataclass
class ChatReply:
    """One completion plus whatever token accounting the server reported."""

    text: str
    prompt_tokens: int | None = None
    completion_tokens: int | None = None


class LocalChatModel:
    """Chat completions against the configured local model.

    ``provider`` and ``model_ref`` default to ``inference.provider`` and
    ``inference.model``, and to ``facts.*`` while ``inference.model`` is empty;
    the host is the matching ``embedding.*_host`` setting.
    Construction is cheap and makes no network call; :meth:`is_available`
    probes the server, :meth:`chat` runs a completion.
    """

    def __init__(
        self,
        *,
        provider: str | None = None,
        model_ref: str | None = None,
        settings: Settings | None = None,
    ) -> None:
        self._settings = settings or get_settings()
        # inference.* names the chat model; left empty, the distillation model (facts.*) answers.
        chosen = self._settings.inference_model
        self.provider = provider or (chosen and self._settings.inference_provider) or self._settings.fact_provider
        if self.provider not in PROVIDERS:
            raise ValueError(f"unknown generation provider {self.provider!r}; expected one of {PROVIDERS}")
        self.model_ref = model_ref or chosen or self._settings.fact_model
        setting = {"llama_xpc": "llama_host", "ollama": "ollama_host", "lmstudio": "lmstudio_host"}[self.provider]
        self.host = getattr(self._settings, setting)
        # Fail at construction, not at the first request, when the host is not approved.
        egress.check_destination(
            self.host,
            purpose=f"generation:{self.provider}",
            loopback_only=self.provider == "llama_xpc",
            settings=self._settings,
        )
        self._client: InferenceClient | None = None

    # ---- description ----------------------------------------------------

    def describe(self) -> str:
        return f"{self.provider}/{self.model_ref} at {self.host}"

    def _unavailable(self, reason: str) -> LocalModelUnavailable:
        hint = _HINTS[self.provider].format(model=self.model_ref)
        return LocalModelUnavailable(
            f"local model {self.model_ref!r} is not available from {_PROVIDER_LABEL[self.provider]} "
            f"({self.provider} at {self.host}): {reason}. "
            f"Check the model name in facts.model and {hint}; or switch facts.provider."
        )

    # ---- client ---------------------------------------------------------

    def _inference_client(self) -> InferenceClient:
        if self._client is None:
            if self.provider == "llama_xpc":
                self._client = LlamaXPCClient(self.host)
            else:
                self._client = InferenceClient(
                    Backend.from_settings(self.provider, self._settings), settings=self._settings
                )
        return self._client

    # ---- probing --------------------------------------------------------

    def is_available(self) -> bool:
        """Whether the server is up and serves ``model_ref``. Never raises."""
        try:
            client = self._inference_client()
            if isinstance(client, LlamaXPCClient):
                if str(client.health().get("status", "")).lower() != "ok":
                    return False
                served = client.list_models()
                # An engine that does not enumerate its models cannot be
                # checked further; the request itself decides then.
                return not served or self.model_ref in served
            return client.has_model(self.model_ref)
        except Exception as exc:  # any transport, HTTP or configuration failure means "no"
            log.debug("%s unavailable: %s", self.describe(), exc)
            return False

    # ---- generation -----------------------------------------------------

    def complete(
        self,
        messages: Sequence[dict[str, str]],
        *,
        max_tokens: int | None = None,
        temperature: float | None = None,
    ) -> ChatReply:
        """Run one chat completion; ``messages`` are OpenAI-style role/content dicts."""
        try:
            result = self._inference_client().chat(
                list(messages),
                self.model_ref,
                max_tokens=max_tokens,
                temperature=temperature,
            )
        except InferenceError as exc:
            raise self._unavailable(str(exc)) from exc
        return ChatReply(
            text=result.text.strip(),
            prompt_tokens=result.prompt_tokens,
            completion_tokens=result.completion_tokens,
        )

    def chat(
        self,
        messages: Sequence[dict[str, str]],
        *,
        max_tokens: int | None = None,
        temperature: float | None = None,
    ) -> str:
        """:meth:`complete`, returning only the reply text."""
        return self.complete(messages, max_tokens=max_tokens, temperature=temperature).text

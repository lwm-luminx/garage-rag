"""Provider-agnostic embedder construction.

Call :func:`get_embedder` with a provider name and model reference to get the
right backend without the caller knowing which SDK is behind it.

Backends are imported lazily; the text backends talk HTTP through
:mod:`garage_rag.inference` (``image_xpc`` talks to the app's image embedding
service through the bridge its host installs, :mod:`garage_rag.xpc.image_host`),
but ``embed.ollama`` also carries the backfill machinery (SQLAlchemy, pgvector)
that a caller asking for another backend need not import.
"""

from __future__ import annotations

from garage_rag.embed.base import Embedder

# Providers recognised by the factory. Extend this when a new backend is added.
PROVIDERS: set[str] = {"ollama", "lmstudio", "llama_xpc", "image_xpc"}


def provider_is_local(provider: str) -> bool:
    """Whether *provider* embeds on this machine, so communications may be sent to it.

    ``llama_xpc`` is loopback by construction (its client refuses anything else),
    and ``image_xpc`` is the app's own image embedding service, reached over
    NSXPC and nothing else. ``ollama`` and ``lmstudio`` are local only while
    ``ollama_host`` / ``lmstudio_host`` point at loopback; an unknown provider
    counts as remote.
    """
    from garage_rag.config import get_settings
    from garage_rag.net.egress import allows_communications

    if provider in ("llama_xpc", "image_xpc"):
        return True
    settings = get_settings()
    hosts = {"ollama": settings.ollama_host, "lmstudio": settings.lmstudio_host}
    host = hosts.get(provider)
    return host is not None and allows_communications(host)


def get_embedder(provider: str, model_ref: str) -> Embedder:
    """Construct the embedder for *provider* and *model_ref*.

    Raises ``ValueError`` for an unknown provider so registration catches
    typos immediately instead of failing at embed time.
    """
    if provider == "ollama":
        from garage_rag.embed.ollama import OllamaEmbedder

        return OllamaEmbedder(model_ref)
    if provider == "lmstudio":
        from garage_rag.embed.lmstudio import LMStudioEmbedder

        return LMStudioEmbedder(model_ref)
    if provider == "llama_xpc":
        from garage_rag.embed.llama_xpc import LlamaXPCEmbedder

        return LlamaXPCEmbedder(model_ref)
    if provider == "image_xpc":
        from garage_rag.embed.image_xpc import ImageXPCEmbedder

        return ImageXPCEmbedder(model_ref)
    raise ValueError(f"unknown embedding provider {provider!r}; supported: {', '.join(sorted(PROVIDERS))}")

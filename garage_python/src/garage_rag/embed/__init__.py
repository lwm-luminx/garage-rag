"""Embedding providers package.

Only the provider-agnostic surface is imported here. The concrete backends
(``OllamaEmbedder``, ``LMStudioEmbedder``, ``LlamaXPCEmbedder``, ``ImageXPCEmbedder``) each import
their own SDK, so they are reached through :func:`get_embedder` or imported
from their own modules rather than eagerly loaded with the package.
"""

from garage_rag.embed.base import Embedder, EmbeddingError, ImageEmbedder
from garage_rag.embed.factory import PROVIDERS, get_embedder
from garage_rag.embed.xpc import embed_via_grpc

__all__ = [
    "PROVIDERS",
    "Embedder",
    "EmbeddingError",
    "ImageEmbedder",
    "embed_via_grpc",
    "get_embedder",
]

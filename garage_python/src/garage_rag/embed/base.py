"""Embedding provider base class.

Every provider implements the same two-method interface so the rest of the
pipeline -- backfill, search, dimension verification -- stays provider-agnostic.

The scaffolding that every backend needs -- short-circuiting an empty batch,
wrapping backend exceptions in :class:`EmbeddingError`, checking that one
vector came back per input, and probing the output width -- lives here once.
A backend only implements :meth:`Embedder._embed_raw`.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from collections.abc import Sequence
from pathlib import Path


class EmbeddingError(RuntimeError):
    """The embedding backend could not produce vectors.

    The one exception type callers (CLI, gRPC service, backfill) catch, no
    matter which backend produced the failure.
    """


class Embedder(ABC):
    """Minimal contract every embedding backend must satisfy."""

    model_ref: str
    # Short backend name used in error messages, e.g. "ollama".
    provider_name: str = "embedder"

    @abstractmethod
    def _embed_raw(self, texts: list[str]) -> Sequence[Sequence[float]]:
        """Call the backend for a non-empty batch and return one vector per text.

        Any exception may propagate; :meth:`embed` wraps it in
        :class:`EmbeddingError` with the backend and model named.
        """

    def embed(self, texts: Sequence[str]) -> list[list[float]]:
        """Embed a batch of texts, preserving order."""
        if not texts:
            return []
        batch = list(texts)
        try:
            vectors = self._embed_raw(batch)
        except EmbeddingError:
            raise
        except Exception as exc:  # noqa: BLE001 - surface backend detail to caller
            raise EmbeddingError(f"{self.provider_name} embed failed for {self.model_ref}: {exc}") from exc

        if vectors is None or len(vectors) != len(batch):
            raise EmbeddingError(f"{self.model_ref} returned {len(vectors or [])} vectors for {len(batch)} inputs")
        return [list(vector) for vector in vectors]

    def probe_dims(self) -> int:
        """Return the actual output width by embedding a short probe string."""
        vectors = self.embed(["dimension probe"])
        if not vectors or not vectors[0]:
            raise EmbeddingError(f"{self.provider_name} probe returned an empty embedding for {self.model_ref!r}")
        return len(vectors[0])


class ImageEmbedder(Embedder):
    """An embedder whose model maps images and text into one space.

    :meth:`embed` (the text tower) embeds queries; :meth:`embed_images` (the
    image tower) embeds the files behind image chunks. Backfill calls the one
    the model's ``modality`` asks for.
    """

    @abstractmethod
    def _embed_images_raw(self, images: list[bytes]) -> Sequence[Sequence[float]]:
        """Embed a non-empty batch of encoded image files, one vector per image."""

    def embed_images(self, paths: Sequence[str]) -> list[list[float]]:
        """Embed the image files at ``paths``, preserving order.

        Reads the files here, where the pipeline has access to the user's folders,
        so the backend only ever sees bytes. An unreadable file fails the batch,
        as an unreachable backend would.
        """
        if not paths:
            return []
        batch = list(paths)
        try:
            images = [Path(path).read_bytes() for path in batch]
            vectors = self._embed_images_raw(images)
        except EmbeddingError:
            raise
        except Exception as exc:  # noqa: BLE001 - surface backend detail to caller
            raise EmbeddingError(f"{self.provider_name} image embed failed for {self.model_ref}: {exc}") from exc

        if vectors is None or len(vectors) != len(batch):
            raise EmbeddingError(f"{self.model_ref} returned {len(vectors or [])} vectors for {len(batch)} images")
        return [list(vector) for vector in vectors]

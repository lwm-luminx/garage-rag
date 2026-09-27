"""Embedding images, and the text that searches them, with the app's image embedding service.

``GarageImageEmbedXPCService`` runs a CLIP-style model (two Core ML towers, one
for images and one for short texts, mapping both into one space; SigLIP 2 in
the catalog) on the Neural Engine or GPU. Python does not reach it over the
network: the Swift host of the process this interpreter runs in installs a
bridge function (:mod:`garage_rag.xpc.image_host`), the same way llama_xpc
models are loaded on demand, and the service itself is reached over NSXPC
through the listener endpoint the app hands each helper.

Outside the app (``garage`` from a venv) there is no bridge, so every call
fails with :class:`~garage_rag.embed.base.EmbeddingError` saying so: image
models are the app's, and backfill and search for them run inside it.
"""

from __future__ import annotations

from collections.abc import Sequence

from garage_rag.embed.base import EmbeddingError, ImageEmbedder
from garage_rag.xpc import image_host


class ImageXPCEmbedder(ImageEmbedder):
    """The ``image_xpc`` provider: text queries through the model's text tower,
    image files through its image tower, both in the app's image embedding service."""

    provider_name = "image_xpc"

    def __init__(self, model_ref: str) -> None:
        self.model_ref = model_ref

    def _embed_raw(self, texts: list[str]) -> Sequence[Sequence[float]]:
        try:
            return image_host.embed_texts(self.model_ref, texts)
        except image_host.ImageEmbedUnavailable as exc:
            raise EmbeddingError(str(exc)) from exc

    def _embed_images_raw(self, images: list[bytes]) -> Sequence[Sequence[float]]:
        try:
            return image_host.embed_images(self.model_ref, images)
        except image_host.ImageEmbedUnavailable as exc:
            raise EmbeddingError(str(exc)) from exc

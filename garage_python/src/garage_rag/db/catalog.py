"""The embedding-model catalog: ``data/models/models.json``.

One file describes every model the app offers and the pipeline knows by name:
its width, the metric it was trained for (``distance``), whether it is
Matryoshka-trained (``supports_mrl``), and how each provider names it. The app
reads it for its presets and downloads; this module reads the same file so
``garage register-model bge-m3`` needs no ``--dims``, and so a model's
distance is chosen once, where the model is described.

The file is found through ``GARAGE_MODEL_MANIFEST`` (the app points it at the
copy it last fetched from the website, else the one in its bundle) or at
``data/models/models.json`` in the repository, which the site serves as
https://garagerag.app/.data/models.json.
Entries without ``native_dims`` (the generative models listed there) are not
embedding models and are skipped.

Two sections describe embedding models: ``text_embedding`` and
``image_embedding``. An image model (a CLIP-style pair of towers run by the
app's image embedding service, provider ``image_xpc``) is registered with
``modality = 'image'``, so backfill embeds image files with it and search
embeds the query with its text tower.
"""

from __future__ import annotations

import json
import logging
import os
from functools import lru_cache
from pathlib import Path
from typing import Any

from garage_rag.config import data_dir
from garage_rag.db.registry import Modality, ModelSpec, check_distance, check_modality

log = logging.getLogger(__name__)

MANIFEST_ENV = "GARAGE_MODEL_MANIFEST"


def manifest_path() -> Path | None:
    """The models.json in use, or None when there is none to read."""
    override = os.environ.get(MANIFEST_ENV)
    if override:
        return Path(override).expanduser()
    candidate = data_dir() / "models" / "models.json"
    return candidate if candidate.is_file() else None


# The catalog sections that describe embedding models, and what their models embed.
EMBEDDING_SECTIONS: dict[str, Modality] = {"text_embedding": "text", "image_embedding": "image"}
# The provider an entry gets when it names none, per modality.
_DEFAULT_PROVIDERS: dict[Modality, str] = {"text": "llama_xpc", "image": "image_xpc"}


def spec_from_entry(entry: dict[str, Any], *, modality: Modality = "text") -> ModelSpec | None:
    """The ModelSpec a models.json ``text_embedding`` or ``image_embedding`` entry
    describes, or None for an entry that is not an embedding model."""
    dims = entry.get("native_dims")
    if not dims:
        return None
    slug = entry["slug"]
    modality = check_modality(entry.get("modality", modality))
    return ModelSpec(
        slug=slug,
        model_ref=entry.get("model_ref") or slug,
        dims=int(dims),
        provider=entry.get("provider") or _DEFAULT_PROVIDERS[modality],
        supports_mrl=bool(entry.get("supports_mrl", False)),
        model_id=entry.get("model_id"),
        distance=check_distance(entry.get("distance", "cosine")),
        provider_refs=dict(entry.get("provider_refs") or {}),
        modality=modality,
    )


@lru_cache(maxsize=4)
def _load(path: str) -> dict[str, ModelSpec]:
    document = json.loads(Path(path).read_text(encoding="utf-8"))
    sections: list[tuple[list[dict[str, Any]], Modality]]
    if isinstance(document, dict):
        sections = [(document.get(name, []), modality) for name, modality in EMBEDDING_SECTIONS.items()]
    else:
        sections = [(document, "text")]
    specs: dict[str, ModelSpec] = {}
    for entries, modality in sections:
        for entry in entries:
            spec = spec_from_entry(entry, modality=modality)
            if spec is not None:
                specs[spec.slug] = spec
    return specs


def known_models() -> dict[str, ModelSpec]:
    """Every embedding model in the catalog, by slug; empty when there is no catalog."""
    path = manifest_path()
    if path is None:
        log.debug("no models.json found; only explicitly described models can be registered")
        return {}
    return _load(str(path))

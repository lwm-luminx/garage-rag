"""Registering, re-pointing and dropping embedding models."""

from __future__ import annotations

from dataclasses import dataclass, field

from garage_rag.db import emb_tables
from garage_rag.db.engine import session_scope


@dataclass
class RegisteredModel:
    slug: str
    provider: str
    model_ref: str
    model_id: str | None
    dims: int
    stored_dims: int
    storage_kind: str
    index_kind: str
    table_name: str
    is_default: bool
    distance: str = "cosine"
    modality: str = "text"
    notes: list[str] = field(default_factory=list)

    @property
    def message(self) -> str:
        kind = "image model" if self.modality == "image" else ""
        return (
            f"registered {self.slug}{f' ({kind})' if kind else ''}: {self.dims}-dim -> "
            f"{self.storage_kind}({self.stored_dims}), index={self.index_kind}, distance={self.distance}, "
            f"table={self.table_name}"
        )


def register_model(
    slug: str,
    *,
    dims: int | None = None,
    model_ref: str | None = None,
    provider: str | None = None,
    model_id: str | None = None,
    distance: str | None = None,
    modality: str | None = None,
    make_default: bool = False,
) -> RegisteredModel:
    """Register an embedding model and create its table and index. Idempotent on ``slug``.

    Width, distance, modality and the rest come from models.json for a catalogued
    model; explicit arguments override them. ValueError for an unknown distance or
    modality, or for a model outside the catalog registered without ``dims``.
    """
    spec = emb_tables.resolve_spec(
        slug,
        dims=dims,
        model_ref=model_ref,
        provider=provider,
        model_id=model_id,
        distance=distance,
        modality=modality,
    )
    with session_scope() as session:
        row = emb_tables.register_model(session, spec, make_default=make_default)
        notes: list[str] = []
        if row.stored_dims < row.dims:
            notes.append(f"truncated {row.dims} -> {row.stored_dims} (Matryoshka) to fit the halfvec HNSW ceiling")
        if row.index_kind == "hnsw_bq":
            notes.append(f"binary-quantized index; queries re-rank on exact {row.distance} distance")
        return RegisteredModel(
            slug=row.slug,
            provider=row.provider,
            model_ref=row.model_ref,
            model_id=row.model_id,
            dims=row.dims,
            stored_dims=row.stored_dims,
            storage_kind=row.storage_kind,
            index_kind=row.index_kind,
            table_name=row.table_name,
            is_default=bool(row.is_default),
            distance=row.distance,
            modality=row.modality,
            notes=notes,
        )


def set_default_model(slug: str) -> None:
    """Point the default embedding model at ``slug`` (LookupError if unregistered)."""
    with session_scope() as session:
        emb_tables.get_model(session, slug)
        emb_tables.set_default_model(session, slug)


@dataclass
class EmbeddedText:
    """One text embedded by a registered model: what the app's Test an Embedding shows."""

    model: str
    provider: str
    model_ref: str
    native_dims: int
    vector: list[float]


def embed_text(text: str, slug: str | None = None, *, dimensions: int | None = None) -> EmbeddedText:
    """Embed ``text`` with the model registered as ``slug`` (the default model when None).

    The vector is the model's own; ``dimensions`` keeps only its first so many values and
    renormalizes them, as a Matryoshka model's stored prefix is. The text goes to the model's
    provider through the same embedder backfill and search use, so the egress allowlist applies.
    ValueError for an empty text or a width the vector does not have; LookupError for an
    unregistered model.
    """
    from garage_rag.db.registry import StoragePlan, truncate_vector
    from garage_rag.embed.factory import get_embedder

    if not text.strip():
        raise ValueError("nothing to embed: the text is empty")
    with session_scope() as session:
        row = emb_tables.get_model(session, slug)
        provider, model_ref, model = row.provider, row.model_ref, row.slug
    vector = get_embedder(provider, model_ref).embed([text])[0]
    native = len(vector)
    if dimensions:
        if not 0 < dimensions <= native:
            raise ValueError(f"{model} gives {native} dimensions; {dimensions} is not between 1 and {native}")
        vector = truncate_vector(
            vector, StoragePlan(stored_dims=dimensions, storage_kind="vector", index_kind="hnsw", truncated_from=native)
        )
    return EmbeddedText(model=model, provider=provider, model_ref=model_ref, native_dims=native, vector=vector)


def drop_model(slug: str) -> None:
    """Deregister a model and drop its table, discarding its vectors."""
    with session_scope() as session:
        emb_tables.drop_model(session, slug)

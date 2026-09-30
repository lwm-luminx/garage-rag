"""Embedding model registry: mapping a model's width onto pgvector storage.

pgvector 0.8.x index ceilings drive every decision here:

======== =============== ==================
type     max stored dims max HNSW dims
======== =============== ==================
vector   16000           2000
halfvec  16000           4000
bit      --              64000
======== =============== ==================

So a 4096-dim model (Qwen3-Embedding-8B) cannot be HNSW-indexed as-is. Two ways
out, in preference order:

1. Matryoshka truncation to <= 4000 and store as ``halfvec``. Only valid for
   models trained with MRL, where prefixes of the vector are themselves valid
   embeddings. Truncating a non-MRL model silently destroys retrieval quality,
   which is why ``supports_mrl`` must be declared per model rather than assumed.
2. Store the full-width ``vector`` unindexed, and put the HNSW index on
   ``binary_quantize(embedding)::bit(dims)`` with ``bit_hamming_ops``. Queries
   over-fetch on Hamming distance, then re-rank on the model's exact distance.

These functions are pure so the mapping can be tested without a database.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Literal, cast

from garage_rag.db.models import IndexKind, StorageKind

# The similarity a model was trained for. It picks the HNSW operator class the
# table is indexed with and the operator search orders by, which must agree for
# the index to be used at all; models.json declares it per model.
Distance = Literal["cosine", "l2", "inner_product"]
DISTANCES: tuple[Distance, ...] = ("cosine", "l2", "inner_product")
# What a model embeds. A text model gets a chunk's text; an image model (a CLIP-style
# pair of towers) gets the image file behind an image chunk, and embeds a text query
# with its text tower.
Modality = Literal["text", "image"]
MODALITIES: tuple[Modality, ...] = ("text", "image")

# pgvector's ordering operator for each metric (smaller sorts first; `<#>` is the
# negated inner product, so ascending order is still best-first).
_DISTANCE_OPERATORS: dict[str, str] = {"cosine": "<=>", "l2": "<->", "inner_product": "<#>"}
# Suffix of the HNSW operator class: vector_cosine_ops, halfvec_ip_ops, ...
_DISTANCE_OPS_SUFFIX: dict[str, str] = {"cosine": "cosine_ops", "l2": "l2_ops", "inner_product": "ip_ops"}

# pgvector HNSW ceilings.
HNSW_MAX_VECTOR_DIMS = 2000
HNSW_MAX_HALFVEC_DIMS = 4000
_SLUG_RE = re.compile(r"[^a-z0-9]+")


@dataclass(frozen=True)
class ModelSpec:
    """A model as the user asks for it, before storage decisions are made."""

    slug: str
    model_ref: str
    dims: int
    provider: str = "llama_xpc"
    normalized: bool = True
    # True only for models documented as Matryoshka-trained (e.g. Qwen3-Embedding).
    supports_mrl: bool = False
    model_id: str | None = None
    distance: Distance = "cosine"
    # Where a provider names the model differently from model_ref (Ollama tags).
    provider_refs: dict[str, str] = field(default_factory=dict)
    modality: Modality = "text"

    def ref_for(self, provider: str) -> str:
        """The model's name under ``provider``."""
        return self.provider_refs.get(provider, self.model_ref)


def check_distance(distance: str) -> Distance:
    """``distance`` if it is a metric pgvector can index, else ValueError."""
    if distance not in DISTANCES:
        raise ValueError(f"unknown distance {distance!r}; choose one of {', '.join(DISTANCES)}")
    return cast(Distance, distance)


def check_modality(modality: str) -> Modality:
    """``modality`` if it is one backfill knows how to feed, else ValueError."""
    if modality not in MODALITIES:
        raise ValueError(f"unknown modality {modality!r}; choose one of {', '.join(MODALITIES)}")
    return cast(Modality, modality)


def distance_operator(distance: str) -> str:
    """The pgvector operator that orders by ``distance``."""
    return _DISTANCE_OPERATORS[check_distance(distance)]


@dataclass(frozen=True)
class StoragePlan:
    """How a model's vectors will physically be stored and indexed."""

    stored_dims: int
    storage_kind: StorageKind
    index_kind: IndexKind
    # Set when stored_dims < dims, explaining the reduction.
    truncated_from: int | None = None

    @property
    def is_truncated(self) -> bool:
        return self.truncated_from is not None


def table_name_for(slug: str) -> str:
    """Derive the per-model table name.

    Constrained to ``^emb_[a-z0-9_]+$`` and matched by a CHECK constraint in
    ``data/sql/004_registry.sql``, because this identifier is interpolated into DDL
    and search SQL where bind parameters cannot be used.
    """
    normalized = _SLUG_RE.sub("_", slug.strip().lower()).strip("_")
    if not normalized:
        raise ValueError(f"model slug {slug!r} normalizes to an empty identifier")
    name = f"emb_{normalized}"
    # Postgres truncates identifiers at 63 bytes; truncating here keeps the
    # registry's table_name in agreement with what Postgres actually created.
    return name[:63].rstrip("_")


def plan_storage(dims: int, *, supports_mrl: bool = False) -> StoragePlan:
    """Choose storage type and index strategy for a model of width ``dims``."""
    if dims <= 0:
        raise ValueError(f"dims must be positive, got {dims}")

    if dims <= HNSW_MAX_VECTOR_DIMS:
        return StoragePlan(stored_dims=dims, storage_kind=StorageKind.VECTOR, index_kind=IndexKind.HNSW)

    if dims <= HNSW_MAX_HALFVEC_DIMS:
        # Too wide for an indexed `vector`, but halfvec's ceiling covers it.
        # Half precision costs little for retrieval and halves index size.
        return StoragePlan(stored_dims=dims, storage_kind=StorageKind.HALFVEC, index_kind=IndexKind.HNSW)

    if supports_mrl:
        # Truncate to the halfvec ceiling; MRL guarantees the prefix is valid.
        return StoragePlan(
            stored_dims=HNSW_MAX_HALFVEC_DIMS,
            storage_kind=StorageKind.HALFVEC,
            index_kind=IndexKind.HNSW,
            truncated_from=dims,
        )

    # Cannot truncate safely and cannot index directly: keep full fidelity and
    # index a binary quantization, re-ranking on the exact distance at query time.
    return StoragePlan(stored_dims=dims, storage_kind=StorageKind.VECTOR, index_kind=IndexKind.HNSW_BQ)


def column_type_sql(plan: StoragePlan) -> str:
    """DDL fragment for the embedding column."""
    return f"{plan.storage_kind}({plan.stored_dims})"


def index_ddl(table: str, plan: StoragePlan, distance: str = "cosine") -> str | None:
    """DDL for the vector index, or ``None`` when the model is unindexed.

    The operator class follows the model's ``distance``: an index built for one
    metric is not used by a query ordering on another.
    """
    if plan.index_kind == "none":
        return None

    if plan.index_kind == "hnsw":
        ops = f"{plan.storage_kind}_{_DISTANCE_OPS_SUFFIX[check_distance(distance)]}"
        return (
            f"CREATE INDEX IF NOT EXISTS {table}_hnsw ON {table} "
            f"USING hnsw (embedding {ops}) WITH (m = 16, ef_construction = 64)"
        )

    # Binary quantization: index the quantized bits, not the vector itself. Hamming
    # distance pre-selects whatever the metric; search re-ranks on ``distance``.
    return (
        f"CREATE INDEX IF NOT EXISTS {table}_hnsw_bq ON {table} "
        f"USING hnsw ((binary_quantize(embedding)::bit({plan.stored_dims})) bit_hamming_ops)"
    )


def truncate_vector(values: list[float], plan: StoragePlan) -> list[float]:
    """Apply the plan's dimensional reduction to one embedding.

    Re-normalizes after truncation: a prefix of a unit vector is not itself unit
    length, and cosine distance in pgvector does not normalize for you.
    """
    if len(values) == plan.stored_dims:
        return values
    if len(values) < plan.stored_dims:
        raise ValueError(f"embedding has {len(values)} dims, expected at least {plan.stored_dims}")

    head = values[: plan.stored_dims]
    norm = sum(v * v for v in head) ** 0.5
    if norm == 0.0:
        return head
    return [v / norm for v in head]

"""Creation and lookup of the per-model embedding tables.

Registering a model creates exactly one table plus its index. Because the table
is keyed on ``chunk_id`` with ``ON DELETE CASCADE``, deleting a chunk removes its
vectors from every model table at once, with no application bookkeeping. That is
what makes re-indexing safe and idempotency cheap.
"""

from __future__ import annotations

import logging
import re
from dataclasses import replace

from sqlalchemy import text
from sqlalchemy.orm import Session

from garage_rag.config import get_settings
from garage_rag.db.catalog import known_models
from garage_rag.db.models import EmbeddingModel
from garage_rag.db.registry import (
    ModelSpec,
    StoragePlan,
    check_distance,
    check_modality,
    column_type_sql,
    index_ddl,
    plan_storage,
    table_name_for,
)

log = logging.getLogger(__name__)

# Matches the CHECK constraint in data/sql/004_registry.sql. Validated again here
# because these identifiers are interpolated into DDL and search SQL, where bind
# parameters are not usable.
_TABLE_RE = re.compile(r"^emb_[a-z0-9_]+$")


def assert_safe_table(name: str) -> str:
    """Reject any table name that is not a registry-shaped identifier."""
    if not _TABLE_RE.match(name):
        raise ValueError(f"unsafe embedding table name: {name!r}")
    return name


def create_embedding_table(session: Session, table: str, plan: StoragePlan, distance: str = "cosine") -> None:
    """Create one per-model embedding table and its vector index (built for ``distance``)."""
    assert_safe_table(table)
    coltype = column_type_sql(plan)

    session.execute(
        text(
            f"""
            CREATE TABLE IF NOT EXISTS {table} (
                chunk_id    bigint PRIMARY KEY REFERENCES chunks(id) ON DELETE CASCADE,
                embedding   {coltype} NOT NULL,
                embedded_at timestamptz NOT NULL DEFAULT now()
            )
            """
        )
    )

    ddl = index_ddl(table, plan, distance)
    if ddl:
        session.execute(text(ddl))
    else:
        log.warning("model table %s created without a vector index", table)


def resolve_spec(
    slug: str,
    *,
    dims: int | None = None,
    model_ref: str | None = None,
    provider: str | None = None,
    model_id: str | None = None,
    distance: str | None = None,
    modality: str | None = None,
) -> ModelSpec:
    """The catalog's model (models.json), adjusted by explicit arguments, or a
    spec built from the arguments alone for a model the catalog does not list."""
    known = known_models().get(slug)
    if known is not None:
        chosen_provider = provider or known.provider
        return replace(
            known,
            # Trust the caller's width: a quantized or MRL-truncated pull can differ.
            dims=dims if dims is not None else known.dims,
            provider=chosen_provider,
            model_ref=model_ref or known.ref_for(chosen_provider),
            model_id=model_id or known.model_id,
            distance=check_distance(distance) if distance else known.distance,
            modality=check_modality(modality) if modality else known.modality,
        )

    if dims is None:
        raise ValueError(f"model {slug!r} is not in models.json; pass --dims explicitly")
    return ModelSpec(
        slug=slug,
        model_ref=model_ref or slug,
        dims=dims,
        provider=provider or "llama_xpc",
        model_id=model_id,
        distance=check_distance(distance) if distance else "cosine",
        modality=check_modality(modality) if modality else "text",
    )


def register_model(
    session: Session,
    spec: ModelSpec,
    *,
    make_default: bool = False,
) -> EmbeddingModel:
    """Register a model and create its table. Idempotent on ``slug``."""
    existing = session.query(EmbeddingModel).filter_by(slug=spec.slug).one_or_none()
    if existing is not None:
        if make_default:
            set_default_model(session, existing.slug)
        return existing

    plan = plan_storage(spec.dims, supports_mrl=spec.supports_mrl)
    table = table_name_for(spec.slug)

    if plan.is_truncated:
        log.warning(
            "%s is %d-dim, above the halfvec HNSW ceiling; storing %d dims via Matryoshka truncation",
            spec.slug,
            spec.dims,
            plan.stored_dims,
        )
    if plan.index_kind == "hnsw_bq":
        log.warning(
            "%s is %d-dim and not MRL-capable; indexing a binary quantization "
            "and re-ranking on exact %s distance at query time",
            spec.slug,
            spec.dims,
            spec.distance,
        )

    create_embedding_table(session, table, plan, spec.distance)

    row = EmbeddingModel(
        slug=spec.slug,
        provider=spec.provider,
        model_ref=spec.model_ref,
        model_id=spec.model_id,
        dims=spec.dims,
        stored_dims=plan.stored_dims,
        storage_kind=plan.storage_kind,
        index_kind=plan.index_kind,
        distance=spec.distance,
        modality=spec.modality,
        normalized=spec.normalized,
        table_name=table,
        is_default=False,
    )
    session.add(row)
    session.flush()

    # First model registered becomes the default unless told otherwise.
    if make_default or session.query(EmbeddingModel).count() == 1:
        set_default_model(session, spec.slug)

    return row


def set_default_model(session: Session, slug: str) -> None:
    """Point the default at ``slug``, clearing any previous default first.

    Two statements rather than one, because a partial unique index enforces at
    most one default and a single UPDATE could transiently violate it.
    """
    session.query(EmbeddingModel).filter(EmbeddingModel.is_default.is_(True)).update(
        {"is_default": False}, synchronize_session=False
    )
    session.query(EmbeddingModel).filter(EmbeddingModel.slug == slug).update(
        {"is_default": True}, synchronize_session=False
    )


def count_vectors(session: Session, model: EmbeddingModel | str) -> int:
    """Count vectors stored in a model's embedding table."""
    table_name = model.table_name if isinstance(model, EmbeddingModel) else model
    table = assert_safe_table(table_name)
    return int(session.execute(text(f"SELECT count(*) FROM {table}")).scalar_one())


def get_model(session: Session, slug: str | None = None) -> EmbeddingModel:
    """Fetch a model by slug, or the default when ``slug`` is None.

    The default is the row flagged ``is_default``; when no row is flagged, the
    configured ``embedding.default_model`` is tried, so a config that names a
    registered model works without a separate ``set-default-model`` step.
    """
    query = session.query(EmbeddingModel)
    if slug:
        row = query.filter_by(slug=slug).one_or_none()
        if row is None:
            raise LookupError(f"no model {slug!r} registered; run 'garage register-model' first")
        return row

    row = query.filter_by(is_default=True).one_or_none()
    if row is not None:
        return row
    configured = get_settings().default_embedding_model
    if configured:
        row = query.filter_by(slug=configured).one_or_none()
        if row is not None:
            return row
        raise LookupError(
            f"no default model registered, and the configured embedding.default_model "
            f"{configured!r} is not registered either; run 'garage register-model' first"
        )
    raise LookupError("no default model registered; run 'garage register-model' first")


def list_models(session: Session) -> list[EmbeddingModel]:
    return session.query(EmbeddingModel).order_by(EmbeddingModel.id).all()


def drop_model(session: Session, slug: str) -> None:
    """Deregister a model and drop its table, discarding its vectors."""
    row = get_model(session, slug)
    table = assert_safe_table(row.table_name)
    session.execute(text(f"DROP TABLE IF EXISTS {table}"))
    session.delete(row)

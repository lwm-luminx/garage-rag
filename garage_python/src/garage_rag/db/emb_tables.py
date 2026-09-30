"""Creation and lookup of the per-model embedding tables.

Registering a model creates three tables, each with its own vector index:

* ``emb_<slug>``, the content chunks' vectors, keyed on ``chunk_id``;
* ``potential_fact_emb_<slug>``, the potential facts' vectors (``017_fact_vectors.sql``),
  keyed on ``fact_id``;
* ``fact_emb_<slug>``, the distilled facts' vectors (``015_distilled_facts.sql``),
  keyed on ``distilled_fact_id``.

Each key is ``ON DELETE CASCADE``, so deleting a chunk or a fact removes its
vectors from every model's tables at once, with no application bookkeeping. That
is what makes re-indexing safe and idempotency cheap. Keeping facts apart from
content chunks gives each its own index: the fact-to-fact neighbour queries of
``garage cluster-facts`` walk a graph of facts only, and passage search a graph
of passages only.
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
# A model's distilled-fact vectors (data/sql/015_distilled_facts.sql): its table name, prefixed.
FACT_TABLE_PREFIX = "fact_"
# A model's potential-fact vectors (data/sql/017_fact_vectors.sql): its table name, prefixed.
POTENTIAL_FACT_TABLE_PREFIX = "potential_fact_"
# Postgres truncates identifiers at 63 bytes; the prefixed names are cut the same way
# (017_fact_vectors.sql computes them with left(..., 63)).
_MAX_IDENTIFIER = 63


def assert_safe_table(name: str) -> str:
    """Reject any table name that is not a registry-shaped identifier."""
    if not _TABLE_RE.match(name):
        raise ValueError(f"unsafe embedding table name: {name!r}")
    return name


def fact_table_name(model_table: str) -> str:
    """The table of distilled-fact vectors beside a model's chunk table ``model_table``."""
    return (FACT_TABLE_PREFIX + assert_safe_table(model_table))[:_MAX_IDENTIFIER]


def potential_fact_table_name(model_table: str) -> str:
    """The table of potential-fact vectors beside a model's chunk table ``model_table``."""
    return (POTENTIAL_FACT_TABLE_PREFIX + assert_safe_table(model_table))[:_MAX_IDENTIFIER]


# What each kind of per-model table holds, keyed on what.
TABLE_KINDS = ("chunks", "potential_facts", "distilled_facts")


def create_embedding_table(
    session: Session, table: str, plan: StoragePlan, distance: str = "cosine", *, kind: str = "chunks"
) -> None:
    """Create one per-model embedding table and its vector index (built for ``distance``).

    ``table`` is the model's chunk table's name. ``kind`` picks which of its
    tables (:data:`TABLE_KINDS`): the chunks' own, keyed on ``chunk_id``; the
    potential facts', keyed on ``fact_id``; or the distilled facts', keyed on
    ``distilled_fact_id``.
    """
    assert_safe_table(table)
    coltype = column_type_sql(plan)
    extra = ""
    if kind == "distilled_facts":
        table = fact_table_name(table)
        key = "distilled_fact_id bigint PRIMARY KEY REFERENCES distilled_facts(id) ON DELETE CASCADE"
        # ``embedding`` is the centroid of the distilled fact's representatives; ``seed``
        # is where the corpus pass started the group (NULL for a vector the backfill made).
        extra = f"seed        {coltype},"
    elif kind == "potential_facts":
        table = potential_fact_table_name(table)
        key = "fact_id     bigint PRIMARY KEY REFERENCES facts(id) ON DELETE CASCADE"
    elif kind == "chunks":
        key = "chunk_id    bigint PRIMARY KEY REFERENCES chunks(id) ON DELETE CASCADE"
    else:
        raise ValueError(f"kind must be one of {', '.join(TABLE_KINDS)}, not {kind!r}")

    session.execute(
        text(
            f"""
            CREATE TABLE IF NOT EXISTS {table} (
                {key},
                embedding   {coltype} NOT NULL,
                {extra}
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

    for kind in TABLE_KINDS:
        create_embedding_table(session, table, plan, spec.distance, kind=kind)

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
    """Count the chunk and potential-fact vectors stored for a model."""
    table_name = model.table_name if isinstance(model, EmbeddingModel) else model
    table = assert_safe_table(table_name)
    facts = potential_fact_table_name(table)
    return int(
        session.execute(
            text(
                f"SELECT (SELECT count(*) FROM {table})"
                f" + CASE WHEN to_regclass('{facts}') IS NULL THEN 0 ELSE (SELECT count(*) FROM {facts}) END"
            )
        ).scalar_one()
    )


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
    """Deregister a model and drop its tables, discarding its vectors."""
    row = get_model(session, slug)
    table = assert_safe_table(row.table_name)
    session.execute(text(f"DROP TABLE IF EXISTS {fact_table_name(table)}"))
    session.execute(text(f"DROP TABLE IF EXISTS {potential_fact_table_name(table)}"))
    session.execute(text(f"DROP TABLE IF EXISTS {table}"))
    session.delete(row)


def stored_plan(model: EmbeddingModel) -> StoragePlan:
    """The storage plan ``model``'s tables were created with."""
    return StoragePlan(
        stored_dims=model.stored_dims,
        storage_kind=model.storage_kind,
        index_kind=model.index_kind,
        truncated_from=model.dims if model.stored_dims < model.dims else None,
    )


def ensure_fact_table(session: Session, model: EmbeddingModel) -> str:
    """Create ``model``'s distilled-fact table if it has none (a model registered before 015); its name."""
    plan = stored_plan(model)
    create_embedding_table(session, model.table_name, plan, model.distance, kind="distilled_facts")
    table = fact_table_name(model.table_name)
    # A table made before 016 has no seed column.
    session.execute(text(f"ALTER TABLE {table} ADD COLUMN IF NOT EXISTS seed {column_type_sql(plan)}"))
    return table

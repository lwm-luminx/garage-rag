"""Embedding via a local Ollama server.

Ollama serializes model execution, so client-side fan-out adds contention rather
than throughput. One batching producer is the right shape: large batches per
request, requests issued one at a time.

Embeddings are written through :func:`backfill_model`, which inserts only chunks
the target model is missing. That single property is what makes "index with a
cheap model now, re-index with a better one later" a routine operation instead of
a migration -- adding a model never touches another model's vectors, and never
re-reads a source file.
"""

from __future__ import annotations

import logging
from collections.abc import Iterator, Sequence
from dataclasses import dataclass

from pgvector import HalfVector
from sqlalchemy import text
from sqlalchemy.orm import Session

from garage_rag.config import get_settings
from garage_rag.db.emb_tables import assert_safe_table, ensure_fact_table
from garage_rag.db.models import EmbeddingModel
from garage_rag.db.registry import StoragePlan, truncate_vector
from garage_rag.embed.base import Embedder, EmbeddingError
from garage_rag.inference import Backend, BackendKind, InferenceClient

log = logging.getLogger(__name__)
logging.getLogger("httpx").setLevel(logging.WARNING)

# ``EmbeddingError`` is defined once in ``embed.base``; it stays importable from
# here because the CLI and the gRPC service catch it under this name.
__all__ = [
    "BackfillProgress",
    "EmbeddingError",
    "OllamaEmbedder",
    "backfill_model",
    "count_pending",
    "verify_model_dims",
]


@dataclass
class BackfillProgress:
    total: int = 0
    embedded: int = 0
    failed: int = 0
    batches: int = 0
    # Communication chunks left unembedded because the provider is off-box.
    withheld: int = 0
    # Distilled facts given a vector (data/sql/015_distilled_facts.sql): copied from their
    # representative's chunk, or embedded when the local model wrote their statement.
    distilled: int = 0

    @property
    def remaining(self) -> int:
        return max(0, self.total - self.embedded - self.failed)


class OllamaEmbedder(Embedder):
    """Batched embedding client for one registered model.

    Posts to Ollama's native ``/api/embed`` -- the route the ``ollama`` package
    used, so vectors already stored are reproduced exactly -- through
    :class:`garage_rag.inference.InferenceClient`. ``/v1/embeddings`` is one
    ``Backend.ollama_embed_route`` away once parity is proven on a Mac
    (``tests/test_inference_live.py``).
    """

    provider_name = "ollama"

    def __init__(self, model_ref: str, *, host: str | None = None, client: InferenceClient | None = None) -> None:
        self.model_ref = model_ref
        self.client = client or InferenceClient(Backend.from_settings(BackendKind.OLLAMA, base_url=host))

    def _embed_raw(self, texts: list[str]) -> Sequence[Sequence[float]]:
        return self.client.embed(texts, self.model_ref)


def _plan_from_row(row: EmbeddingModel) -> StoragePlan:
    return StoragePlan(
        stored_dims=row.stored_dims,
        storage_kind=row.storage_kind,
        index_kind=row.index_kind,
        truncated_from=row.dims if row.stored_dims < row.dims else None,
    )


def _adapt(values: list[float], plan: StoragePlan):
    """Convert one embedding into the value type its column expects."""
    reduced = truncate_vector(values, plan)
    # halfvec columns need an explicit HalfVector; plain lists bind as vector.
    return HalfVector(reduced) if plan.storage_kind == "halfvec" else reduced


def pending_chunks_sql(table: str, *, select: str, include_communications: bool) -> str:
    """``SELECT <select>`` over the chunks ``table`` has no vector for.

    ``include_communications=False`` leaves out chunks of communication
    documents: the query for a provider that is not on this machine, since
    embedding a chunk means posting its text to the provider.
    """
    withheld = (
        ""
        if include_communications
        else (
            " AND NOT EXISTS (SELECT 1 FROM documents d"
            " WHERE d.id = c.document_id AND d.corpus_class = 'communication')"
        )
    )
    return f"SELECT {select} FROM chunks c LEFT JOIN {table} e ON e.chunk_id = c.id WHERE e.chunk_id IS NULL{withheld}"


def _pending_chunk_batches(
    session: Session, table: str, batch_size: int, *, include_communications: bool = True
) -> Iterator[list[tuple[int, str]]]:
    """Yield batches of (chunk_id, text) that ``table`` has no vector for.

    Re-queried each iteration rather than held open: the anti-join shrinks as
    rows are inserted, so this converges without keeping a long-lived cursor
    across the write transactions.
    """
    sql = text(
        pending_chunks_sql(table, select="c.id, c.text", include_communications=include_communications)
        + " ORDER BY c.id LIMIT :limit"
    )
    while True:
        rows = session.execute(sql, {"limit": batch_size}).all()
        if not rows:
            return
        yield [(int(cid), txt) for cid, txt in rows]


def count_pending(session: Session, model: EmbeddingModel, *, include_communications: bool = True) -> int:
    table = assert_safe_table(model.table_name)
    sql = pending_chunks_sql(table, select="count(*)", include_communications=include_communications)
    return int(session.execute(text(sql)).scalar_one())


def backfill_model(
    session: Session,
    model: EmbeddingModel,
    *,
    batch_size: int | None = None,
    limit: int | None = None,
    progress=None,
) -> BackfillProgress:
    """Embed every chunk this model is missing.

    Pure insert: existing vectors are never touched, so this is safe to run
    repeatedly and safe to interrupt.

    When the provider is not on this machine (``ollama_host`` / ``lmstudio_host``
    pointed off-box), chunks of communication documents are withheld: embedding
    posts the chunk's text, and communications never leave the machine. They
    stay pending for this model and are counted in ``withheld``.
    """
    from garage_rag.embed.factory import get_embedder, provider_is_local

    settings = get_settings()
    size = batch_size or settings.embed_batch_size
    table = assert_safe_table(model.table_name)
    plan = _plan_from_row(model)
    local = provider_is_local(model.provider)
    embedder = get_embedder(model.provider, model.model_ref)

    state = BackfillProgress(total=count_pending(session, model, include_communications=local))
    if not local:
        state.withheld = count_pending(session, model) - state.total
        if state.withheld:
            log.warning("%s embeds off this machine; withholding %d communication chunk(s)", model.slug, state.withheld)
    if state.total == 0:
        backfill_distilled(session, model, embedder, plan, state, size, include_communications=local)
        return state

    insert_sql = text(
        f"INSERT INTO {table} (chunk_id, embedding) VALUES (:chunk_id, :embedding) ON CONFLICT (chunk_id) DO NOTHING"
    )

    for batch in _pending_chunk_batches(session, table, size, include_communications=local):
        ids = [cid for cid, _ in batch]
        texts = [txt for _, txt in batch]
        try:
            vectors = embedder.embed(texts)
            # Check the width before touching the column: a vector of the wrong
            # size would be rejected by pgvector anyway, and a model that emits
            # the wrong width does so for every batch.
            for vec in vectors:
                if len(vec) != model.dims:
                    raise EmbeddingError(
                        f"{model.model_ref} returned a {len(vec)}-dim vector; registered as {model.dims}"
                    )
        except Exception as exc:  # noqa: BLE001 - logged and counted, never re-raised
            log.error("batch failed (%d chunks): %s", len(batch), exc)
            state.failed += len(batch)
            # A backend that is down (or mis-registered) will fail every
            # subsequent batch too.
            break

        session.execute(
            insert_sql,
            [{"chunk_id": cid, "embedding": _adapt(vec, plan)} for cid, vec in zip(ids, vectors, strict=True)],
        )
        session.commit()

        state.embedded += len(batch)
        state.batches += 1
        if progress is not None:
            progress(state)
        if limit is not None and state.embedded >= limit:
            break

    if not state.failed and (limit is None or state.embedded < limit):
        backfill_distilled(session, model, embedder, plan, state, size, include_communications=local)
    return state


def backfill_distilled(
    session: Session,
    model: EmbeddingModel,
    embedder: Embedder,
    plan: StoragePlan,
    state: BackfillProgress,
    batch_size: int,
    *,
    include_communications: bool,
) -> None:
    """Give every distilled fact a vector in the model's ``fact_emb_`` table.

    A distilled fact stated by one of its potential facts' own text has that
    fact's vector already, on its chunk: it is copied, not embedded again. One
    whose statement the local model wrote is embedded, unless a member is a
    communication and the provider is off this machine. Pure insert, like the
    chunk backfill.
    """
    table = assert_safe_table(model.table_name)
    fact_table = ensure_fact_table(session, model)
    copied = session.execute(
        text(
            f"""
            INSERT INTO {fact_table} (distilled_fact_id, embedding)
            SELECT df.id, e.embedding
            FROM distilled_facts df
            JOIN chunks c ON c.fact_id = df.representative_fact_id
            JOIN {table} e ON e.chunk_id = c.id
            WHERE NOT df.statement_generated
              AND NOT EXISTS (SELECT 1 FROM {fact_table} fe WHERE fe.distilled_fact_id = df.id)
            ON CONFLICT (distilled_fact_id) DO NOTHING
            RETURNING distilled_fact_id
            """
        )
    ).all()
    session.commit()
    state.distilled += len(copied)

    withheld = (
        ""
        if include_communications
        else (
            " AND NOT EXISTS (SELECT 1 FROM facts f JOIN documents d ON d.id = f.document_id"
            " WHERE f.distilled_fact_id = df.id AND d.corpus_class = 'communication')"
        )
    )
    pending = text(
        f"SELECT df.id, df.statement FROM distilled_facts df WHERE df.statement_generated"
        f" AND NOT EXISTS (SELECT 1 FROM {fact_table} fe WHERE fe.distilled_fact_id = df.id){withheld}"
        " ORDER BY df.id LIMIT :limit"
    )
    insert_sql = text(
        f"INSERT INTO {fact_table} (distilled_fact_id, embedding) VALUES (:id, :embedding)"
        " ON CONFLICT (distilled_fact_id) DO NOTHING"
    )
    while rows := session.execute(pending, {"limit": batch_size}).all():
        try:
            vectors = embedder.embed([statement for _, statement in rows])
            for vec in vectors:
                if len(vec) != model.dims:
                    raise EmbeddingError(
                        f"{model.model_ref} returned a {len(vec)}-dim vector; registered as {model.dims}"
                    )
        except Exception as exc:  # noqa: BLE001 - logged, never re-raised, as for chunks
            log.error("distilled-fact batch failed (%d statements): %s", len(rows), exc)
            return
        session.execute(
            insert_sql,
            [{"id": int(did), "embedding": _adapt(vec, plan)} for (did, _), vec in zip(rows, vectors, strict=True)],
        )
        session.commit()
        state.distilled += len(rows)


def verify_model_dims(model: EmbeddingModel) -> tuple[bool, int]:
    """Check the registered width against what the model actually emits.

    A mismatch means every vector would be rejected by the column type, so it is
    worth one probe request before spending hours on a backfill.
    """
    from garage_rag.embed.factory import get_embedder

    actual = get_embedder(model.provider, model.model_ref).probe_dims()
    return actual == model.dims, actual

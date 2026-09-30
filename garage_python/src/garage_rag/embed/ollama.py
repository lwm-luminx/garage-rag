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
from garage_rag.db.emb_tables import assert_safe_table, ensure_fact_table, potential_fact_table_name
from garage_rag.db.models import EmbeddingModel
from garage_rag.db.registry import StoragePlan, truncate_vector
from garage_rag.embed.base import Embedder, EmbeddingError, ImageEmbedder
from garage_rag.inference import Backend, BackendKind, InferenceClient

log = logging.getLogger(__name__)
logging.getLogger("httpx").setLevel(logging.WARNING)

# ``EmbeddingError`` is defined once in ``embed.base``; it stays importable from
# here because the CLI and the gRPC service catch it under this name.
__all__ = [
    "IMAGE_CHUNKER",
    "PENDING_SELECT",
    "BackfillProgress",
    "EmbeddingError",
    "OllamaEmbedder",
    "backfill_model",
    "count_pending",
    "model_modality",
    "pending_chunks_sql",
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
    # Distilled facts given a vector (data/sql/015_distilled_facts.sql): the mean of their
    # representatives' vectors, so nothing is embedded for them.
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


# The chunker name of the one chunk an image document carries for image models
# (ingest.chunking.IMAGE_CHUNKER); text models never see it.
IMAGE_CHUNKER = "image"
# What a batch carries per chunk: its text for a text model, the path of the
# image file behind it (documents.uri) for an image model.
PENDING_SELECT = {"text": "c.id, c.text", "image": "c.id, d.uri"}


def pending_chunks_sql(table: str, *, select: str, include_communications: bool, modality: str = "text") -> str:
    """``SELECT <select>`` over the chunks the model of chunk table ``table`` has no vector for.

    A content chunk's vector goes in ``table``, keyed on the chunk; a potential
    fact's chunk (``chunks.fact_id``) has its vector in the model's potential-fact
    table, keyed on the fact (:func:`store_vectors` routes them).

    ``include_communications=False`` leaves out chunks of communication
    documents: the query for a provider that is not on this machine, since
    embedding a chunk means posting its text to the provider.

    ``modality`` picks the chunks: a text model gets every chunk but the image
    chunks; an image model gets only those, joined to their documents so the
    caller can select the image file's path (``d.uri``).
    """
    if modality == "image":
        return (
            f"SELECT {select} FROM chunks c JOIN documents d ON d.id = c.document_id"
            f" LEFT JOIN {table} e ON e.chunk_id = c.id"
            f" WHERE e.chunk_id IS NULL AND c.chunker = '{IMAGE_CHUNKER}'"
            + ("" if include_communications else " AND d.corpus_class <> 'communication'")
        )
    withheld = (
        ""
        if include_communications
        else (
            " AND NOT EXISTS (SELECT 1 FROM documents d"
            " WHERE d.id = c.document_id AND d.corpus_class = 'communication')"
        )
    )
    facts = potential_fact_table_name(table)
    return (
        f"SELECT {select} FROM chunks c"
        f" LEFT JOIN {table} e ON c.fact_id IS NULL AND e.chunk_id = c.id"
        f" LEFT JOIN {facts} pe ON c.fact_id IS NOT NULL AND pe.fact_id = c.fact_id"
        f" WHERE e.chunk_id IS NULL AND pe.fact_id IS NULL AND c.chunker <> '{IMAGE_CHUNKER}'{withheld}"
    )


def store_vectors(
    session: Session, model: EmbeddingModel, vectors: Sequence[tuple[int, Sequence[float]]], *, replace: bool = False
) -> int:
    """Store ``(chunk_id, vector)`` pairs in ``model``'s tables; how many were given.

    A content chunk's vector goes in the chunk table; a potential fact's chunk's in
    the potential-fact table, keyed on its fact. ``replace`` overwrites a vector
    already there, otherwise it is kept.
    """
    if not vectors:
        return 0
    table = assert_safe_table(model.table_name)
    facts = potential_fact_table_name(table)
    plan = _plan_from_row(model)
    fact_of = {
        int(cid): (int(fid) if fid is not None else None)
        for cid, fid in session.execute(
            text("SELECT id, fact_id FROM chunks WHERE id = ANY(CAST(:ids AS bigint[]))"),
            {"ids": [int(cid) for cid, _ in vectors]},
        ).all()
    }
    content = [{"key": cid, "embedding": _adapt(list(vec), plan)} for cid, vec in vectors if fact_of.get(cid) is None]
    fact_rows = [
        {"key": fact_of[cid], "embedding": _adapt(list(vec), plan)}
        for cid, vec in vectors
        if fact_of.get(cid) is not None
    ]
    on_conflict = "DO UPDATE SET embedding = EXCLUDED.embedding, embedded_at = now()" if replace else "DO NOTHING"
    if content:
        session.execute(
            text(
                f"INSERT INTO {table} (chunk_id, embedding) VALUES (:key, :embedding) "
                f"ON CONFLICT (chunk_id) {on_conflict}"
            ),
            content,
        )
    if fact_rows:
        session.execute(
            text(
                f"INSERT INTO {facts} (fact_id, embedding) VALUES (:key, :embedding) "
                f"ON CONFLICT (fact_id) {on_conflict}"
            ),
            fact_rows,
        )
    return len(vectors)


def _pending_chunk_batches(
    session: Session, table: str, batch_size: int, *, include_communications: bool = True, modality: str = "text"
) -> Iterator[list[tuple[int, str]]]:
    """Yield batches of (chunk_id, text) that ``table`` has no vector for; for an
    image model, (chunk_id, path of the image file).

    Re-queried each iteration rather than held open: the anti-join shrinks as
    rows are inserted, so this converges without keeping a long-lived cursor
    across the write transactions.
    """
    sql = text(
        pending_chunks_sql(
            table, select=PENDING_SELECT[modality], include_communications=include_communications, modality=modality
        )
        + " ORDER BY c.id LIMIT :limit"
    )
    while True:
        rows = session.execute(sql, {"limit": batch_size}).all()
        if not rows:
            return
        yield [(int(cid), txt) for cid, txt in rows]


def model_modality(model: EmbeddingModel) -> str:
    """``text`` or ``image``; rows from before 014_model_modality.sql read as text."""
    modality = getattr(model, "modality", None)
    return modality if modality in PENDING_SELECT else "text"


def count_pending(session: Session, model: EmbeddingModel, *, include_communications: bool = True) -> int:
    table = assert_safe_table(model.table_name)
    sql = pending_chunks_sql(
        table, select="count(*)", include_communications=include_communications, modality=model_modality(model)
    )
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
    local = provider_is_local(model.provider)
    embedder = get_embedder(model.provider, model.model_ref)
    modality = model_modality(model)
    if modality == "image" and not isinstance(embedder, ImageEmbedder):
        raise EmbeddingError(f"{model.slug} is an image model but provider {model.provider!r} embeds text only")

    state = BackfillProgress(total=count_pending(session, model, include_communications=local))
    if not local:
        state.withheld = count_pending(session, model) - state.total
        if state.withheld:
            log.warning("%s embeds off this machine; withholding %d communication chunk(s)", model.slug, state.withheld)
    if state.total == 0:
        backfill_distilled(session, model, state)
        return state

    for batch in _pending_chunk_batches(session, table, size, include_communications=local, modality=modality):
        ids = [cid for cid, _ in batch]
        texts = [txt for _, txt in batch]
        try:
            if modality == "image":
                assert isinstance(embedder, ImageEmbedder)  # checked above; for the type checker
                vectors = embedder.embed_images(texts)
            else:
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

        store_vectors(session, model, list(zip(ids, vectors, strict=True)))
        session.commit()

        state.embedded += len(batch)
        state.batches += 1
        if progress is not None:
            progress(state)
        if limit is not None and state.embedded >= limit:
            break

    if not state.failed and (limit is None or state.embedded < limit):
        backfill_distilled(session, model, state)
    return state


def backfill_distilled(session: Session, model: EmbeddingModel, state: BackfillProgress) -> None:
    """Give every distilled fact a vector in the model's ``fact_emb_`` table.

    Its vector is the normalized centroid of its representatives' vectors under
    this model (``garage cluster-facts`` writes the clustering model's own, with
    the group's seed). Nothing is embedded, so nothing leaves the machine; a
    distilled fact waits until every one of its representatives has a vector
    here, so its centroid is not skewed toward the ones embedded first. Pure
    insert, like the chunk backfill.
    """
    # Facts are text: an image model embeds none, so it has no distilled-fact vectors.
    if model_modality(model) != "text":
        return
    table = potential_fact_table_name(assert_safe_table(model.table_name))
    fact_table = ensure_fact_table(session, model)
    made = session.execute(
        text(
            f"""
            INSERT INTO {fact_table} (distilled_fact_id, embedding)
            SELECT f.distilled_fact_id, l2_normalize(avg(e.embedding))
            FROM facts f
            LEFT JOIN {table} e ON e.fact_id = f.id
            WHERE f.distilled_fact_id IS NOT NULL AND f.restates_fact_id IS NULL
              AND NOT EXISTS (SELECT 1 FROM {fact_table} fe WHERE fe.distilled_fact_id = f.distilled_fact_id)
            GROUP BY f.distilled_fact_id
            HAVING count(e.fact_id) = count(*)
            ON CONFLICT (distilled_fact_id) DO NOTHING
            RETURNING distilled_fact_id
            """
        )
    ).all()
    session.commit()
    state.distilled += len(made)


def verify_model_dims(model: EmbeddingModel) -> tuple[bool, int]:
    """Check the registered width against what the model actually emits.

    A mismatch means every vector would be rejected by the column type, so it is
    worth one probe request before spending hours on a backfill.
    """
    from garage_rag.embed.factory import get_embedder

    actual = get_embedder(model.provider, model.model_ref).probe_dims()
    return actual == model.dims, actual

"""Fact distillation over a set of documents, reported per document; the prompts it runs; and the
listing and counts the app's Facts page and ``garage facts list|stats`` browse them through."""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any

from sqlalchemy import text
from sqlalchemy.orm import Session

from garage_rag.config.fact_prompts import EffectivePrompt, select_prompts
from garage_rag.db.engine import session_scope
from garage_rag.db.models import CorpusClass, Document, FactRun, Source


@dataclass
class EnrichEvent:
    """One document processed: ``index`` of ``total``, with its fact count or error.

    ``prompts`` are the prompts that ran on it; ``skipped`` is true when none
    did (none applies, or with ``stale_only`` every one is up to date).
    """

    index: int
    total: int
    document_id: int
    uri: str
    facts: int = 0
    error: str | None = None
    prompts: list[str] = field(default_factory=list)
    skipped: bool = False


@dataclass
class EnrichSummary:
    model_id: str
    provider: str
    total: int
    enriched: int
    facts: int
    failed: int
    skipped: int = 0
    prompts: list[str] = field(default_factory=list)

    @property
    def message(self) -> str:
        text = f"{self.enriched}/{self.total} documents enriched, {self.facts:,} facts extracted"
        if self.skipped:
            text += f", {self.skipped} skipped"
        if self.failed:
            text += f", {self.failed} failed"
        return text


def list_fact_prompts() -> list[EffectivePrompt]:
    """The effective prompts: built-ins (as overridden) then the configured ones, enabled or not."""
    from garage_rag.enrich.facts import configured_prompts

    return configured_prompts()


def get_fact_prompt(name: str) -> EffectivePrompt:
    """One effective prompt by name; ``LookupError`` when there is none."""
    return select_prompts(list_fact_prompts(), [name])[0]


def enrich_facts(
    *,
    source: str = "*",
    document_id: int | None = None,
    model: str | None = None,
    provider: str | None = None,
    prompts: list[str] | None = None,
    stale_only: bool = False,
    on_start: Callable[[int, str, str], None] | None = None,
    on_event: Callable[[EnrichEvent], None] | None = None,
) -> EnrichSummary:
    """Distill documents into atomic facts, once per prompt.

    Runs every enabled prompt of ``facts.prompts`` that applies to a document
    (its ``corpus_classes``/``sources`` scope), or exactly the prompts named in
    ``prompts``. Re-extraction replaces only that prompt's prior facts for the
    document. With ``stale_only``, a prompt whose last run on the document had
    the same prompt text, document content and model is skipped.

    ``document_id`` picks one document and ignores ``source``. ``model``/``provider``
    default to facts.model/facts.provider. One failing document is recorded and
    the run continues. Raises LookupError when there is nothing to enrich or a
    named prompt does not exist.
    """
    from garage_rag.enrich.facts import configured_backend, extract_and_store_facts, is_stale

    model_id, provider = configured_backend(model, provider)
    selected = select_prompts(list_fact_prompts(), prompts)
    if not selected:
        raise LookupError("no fact prompts are enabled")

    with session_scope() as session:
        if document_id:
            document = session.get(Document, document_id)
            if document is None:
                raise LookupError(f"document {document_id} not found")
            documents = [document]
        else:
            query = session.query(Document)
            if source and source != "*":
                query = query.join(Source, Document.source_id == Source.id).filter(Source.slug == source)
            documents = query.order_by(Document.id).all()
        if not documents:
            raise LookupError("no documents to enrich")
        slugs = dict(session.query(Source.id, Source.slug).all())

        if on_start is not None:
            on_start(len(documents), model_id, provider)
        failed = 0
        skipped = 0
        total_facts = 0
        for index, document in enumerate(documents, start=1):
            event = EnrichEvent(index=index, total=len(documents), document_id=document.id, uri=document.uri or "")
            corpus_class = getattr(document.corpus_class, "value", document.corpus_class)
            applicable = [p for p in selected if p.applies_to(corpus_class, slugs.get(document.source_id))]
            if stale_only and applicable:
                runs = {
                    run.prompt_name: run
                    for run in session.query(FactRun).filter(FactRun.document_id == document.id).all()
                }
                applicable = [p for p in applicable if is_stale(runs.get(p.name), document, p, model_id)]
            errors: list[str] = []
            for prompt in applicable:
                try:
                    facts = extract_and_store_facts(
                        session, document, prompt=prompt, model_id=model_id, provider=provider
                    )
                    session.commit()
                    event.facts += len(facts)
                    event.prompts.append(prompt.name)
                except Exception as exc:
                    session.rollback()
                    errors.append(f"{prompt.name}: {exc}" if len(applicable) > 1 else str(exc))
            total_facts += event.facts
            if errors:
                failed += 1
                event.error = "; ".join(errors)
            elif not applicable:
                skipped += 1
                event.skipped = True
            if on_event is not None:
                on_event(event)

        return EnrichSummary(
            model_id=model_id,
            provider=provider,
            total=len(documents),
            enriched=len(documents) - failed - skipped,
            facts=total_facts,
            failed=failed,
            skipped=skipped,
            prompts=[prompt.name for prompt in selected],
        )


# Characters of documents.content shown either side of a fact's grounded span.
EXCERPT_CONTEXT = 200


@dataclass
class FactRow:
    """One fact with the document it was distilled from."""

    id: int
    document_id: int
    ord: int
    fact: str
    fact_class: str
    attributes: dict
    char_start: int | None
    char_end: int | None
    extractor: str
    extractor_model: str | None
    created_at: datetime | None
    document_title: str | None
    document_uri: str
    source_slug: str
    corpus_class: str
    # The grounded span with EXCERPT_CONTEXT characters either side, and where it
    # starts in documents.content; None when the fact has no span or the
    # document keeps no content.
    excerpt: str | None = None
    excerpt_start: int = 0
    # The fact's cluster (garage cluster-facts), if it is in one: how many
    # facts it groups, and the local model's statement of their shared claim.
    cluster_id: int | None = None
    cluster_size: int = 0
    cluster_statement: str | None = None


@dataclass
class FactPage:
    facts: list[FactRow]
    total: int
    # Every fact class under the other filters, with its count, so a picker can
    # offer the classes the current search would find.
    classes: list[tuple[str, int]] = field(default_factory=list)


def _like_pattern(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
    return f"%{escaped}%"


_FACT_JOINS = "FROM facts f JOIN documents d ON d.id = f.document_id JOIN sources s ON s.id = d.source_id"

# A fact's cluster, for the columns list_facts adds; LEFT JOINed onto _FACT_JOINS.
_CLUSTER_JOINS = """
    LEFT JOIN fact_cluster_members fcm ON fcm.fact_id = f.id
    LEFT JOIN fact_clusters fc ON fc.id = fcm.cluster_id
"""

# With collapse_clusters, a clustered fact is listed only when it is its cluster's representative
# (or, when the representative is gone, the cluster's lowest id).
_COLLAPSED = """(fcm.cluster_id IS NULL OR f.id = COALESCE(fc.representative_fact_id,
    (SELECT min(m2.fact_id) FROM fact_cluster_members m2 WHERE m2.cluster_id = fcm.cluster_id)))"""


def _where(clauses: list[str]) -> str:
    return ("WHERE " + " AND ".join(clauses)) if clauses else ""


def _fact_filters(
    *, query: str, source: str, fact_class: str, corpus_class: str, document_id: int | None
) -> tuple[list[str], list[str], dict[str, object]]:
    """The WHERE clauses for the filters: without fact_class, with it, and their parameters.

    Raises ValueError for a corpus class that does not exist, rather than a cast error from the database.
    """
    params: dict[str, object] = {}
    base: list[str] = []
    if query:
        base.append("(f.tsv @@ websearch_to_tsquery('english', :q) OR f.fact ILIKE :like)")
        params["q"] = query
        params["like"] = _like_pattern(query)
    if source:
        base.append("s.slug = :source")
        params["source"] = source
    if corpus_class:
        if corpus_class not in {c.value for c in CorpusClass}:
            choices = ", ".join(c.value for c in CorpusClass)
            raise ValueError(f"unknown corpus class {corpus_class!r} (expected one of {choices})")
        base.append("d.corpus_class = CAST(:corpus_class AS corpus_class)")
        params["corpus_class"] = corpus_class
    if document_id:
        base.append("f.document_id = :document_id")
        params["document_id"] = document_id
    filtered = [*base]
    if fact_class:
        filtered.append("f.fact_class = :fact_class")
        params["fact_class"] = fact_class
    return base, filtered, params


def _fact_row_values(row) -> dict[str, Any]:
    """A result row as FactRow's keyword arguments, with NULL attributes and extractor made empty."""
    values: dict[str, Any] = dict(row)
    values["attributes"] = values["attributes"] or {}
    values["extractor"] = values["extractor"] or ""
    return values


def list_facts(
    session: Session,
    *,
    query: str = "",
    source: str = "",
    fact_class: str = "",
    corpus_class: str = "",
    document_id: int | None = None,
    limit: int = 100,
    offset: int = 0,
    collapse_clusters: bool = False,
    cluster_id: int | None = None,
) -> FactPage:
    """Facts matching the filters, newest first, or best match first given ``query``.

    ``query`` matches a fact's words (Postgres full-text search, stemmed) or any
    substring of it, so a partial word still finds something. Empty filters
    match everything. ``collapse_clusters`` lists each cluster of restatements
    once, as its representative fact; ``cluster_id`` lists one cluster's facts.
    """
    query = query.strip()
    base, filtered, params = _fact_filters(
        query=query, source=source, fact_class=fact_class, corpus_class=corpus_class, document_id=document_id
    )
    extra: list[str] = []
    if collapse_clusters:
        extra.append(_COLLAPSED)
    if cluster_id:
        extra.append("fcm.cluster_id = :cluster_id")
        params["cluster_id"] = cluster_id
    base = [*base, *extra]
    filtered = [*filtered, *extra]
    joins = _FACT_JOINS + _CLUSTER_JOINS
    params["ctx"] = EXCERPT_CONTEXT

    order = (
        "ts_rank(f.tsv, websearch_to_tsquery('english', :q)) DESC, f.id DESC"
        if query
        else "f.created_at DESC, f.document_id DESC, f.ord ASC"
    )
    params["limit"] = max(limit, 1)
    params["offset"] = max(offset, 0)

    rows = session.execute(
        text(
            f"""
            SELECT f.id, f.document_id, f.ord, f.fact, f.fact_class, f.attributes,
                   f.char_start, f.char_end, f.extractor, f.extractor_model, f.created_at,
                   d.title AS document_title, d.uri AS document_uri, s.slug AS source_slug,
                   d.corpus_class::text AS corpus_class,
                   CASE WHEN f.char_start IS NOT NULL AND f.char_end IS NOT NULL AND d.content IS NOT NULL
                        THEN substr(d.content, GREATEST(f.char_start - :ctx, 0) + 1,
                                    f.char_end - GREATEST(f.char_start - :ctx, 0) + :ctx)
                   END AS excerpt,
                   GREATEST(COALESCE(f.char_start, 0) - :ctx, 0) AS excerpt_start,
                   fcm.cluster_id,
                   CASE WHEN fcm.cluster_id IS NULL THEN 0 ELSE
                        (SELECT count(*) FROM fact_cluster_members m3 WHERE m3.cluster_id = fcm.cluster_id)
                   END AS cluster_size,
                   fc.statement AS cluster_statement
            {joins}
            {_where(filtered)}
            ORDER BY {order}
            LIMIT :limit OFFSET :offset
            """
        ),
        params,
    ).mappings()
    facts = [FactRow(**_fact_row_values(row)) for row in rows]

    total = session.execute(text(f"SELECT count(*) {joins} {_where(filtered)}"), params).scalar_one()
    classes = [
        (name, count)
        for name, count in session.execute(
            text(f"SELECT f.fact_class, count(*) {joins} {_where(base)} GROUP BY f.fact_class ORDER BY 2 DESC, 1"),
            params,
        ).all()
    ]
    return FactPage(facts=facts, total=int(total), classes=classes)


@dataclass
class FactStats:
    facts: int
    documents: int
    by_source: dict[str, int]
    by_class: dict[str, int]
    # Clusters of restatements among these facts, and how many facts they group.
    clusters: int = 0
    clustered_facts: int = 0

    @property
    def message(self) -> str:
        text = f"{self.facts:,} facts across {self.documents:,} documents"
        if self.clusters:
            text += f"; {self.clustered_facts:,} of them in {self.clusters:,} clusters"
        return text


def fact_stats(
    session: Session,
    *,
    query: str = "",
    source: str = "",
    fact_class: str = "",
    corpus_class: str = "",
    document_id: int | None = None,
) -> FactStats:
    """How many facts match the filters (the same ones ``list_facts`` takes), over how many documents,
    per source and per class."""
    _, filtered, params = _fact_filters(
        query=query.strip(), source=source, fact_class=fact_class, corpus_class=corpus_class, document_id=document_id
    )
    scope = f"{_FACT_JOINS} {_where(filtered)}"
    facts, documents = session.execute(text(f"SELECT count(*), count(DISTINCT f.document_id) {scope}"), params).one()
    by_source = {
        slug: int(count)
        for slug, count in session.execute(
            text(f"SELECT s.slug, count(*) {scope} GROUP BY s.slug ORDER BY 2 DESC, 1"), params
        ).all()
    }
    by_class = {
        name: int(count)
        for name, count in session.execute(
            text(f"SELECT f.fact_class, count(*) {scope} GROUP BY f.fact_class ORDER BY 2 DESC, 1"), params
        ).all()
    }
    clusters, clustered = session.execute(
        text(
            f"SELECT count(DISTINCT fcm.cluster_id), count(fcm.cluster_id) {_FACT_JOINS}"
            f" JOIN fact_cluster_members fcm ON fcm.fact_id = f.id {_where(filtered)}"
        ),
        params,
    ).one()
    return FactStats(
        facts=int(facts or 0),
        documents=int(documents or 0),
        by_source=by_source,
        by_class=by_class,
        clusters=int(clusters or 0),
        clustered_facts=int(clustered or 0),
    )


@dataclass
class ClusterSummary:
    """The outcome of one ``cluster-facts`` run (see :mod:`garage_rag.enrich.clusters`)."""

    model: str
    threshold: float
    distill_model: str
    facts: int
    unembedded: int
    clusters: int
    clustered_facts: int
    kept: int
    dissolved: int
    failed: int
    withheld: int
    errors: list[str] = field(default_factory=list)

    @property
    def message(self) -> str:
        text = f"{self.clusters:,} clusters over {self.clustered_facts:,} of {self.facts:,} facts"
        if self.dissolved:
            text += f", {self.dissolved} rejected by the model"
        if self.failed:
            text += f", {self.failed} not distilled (model error)"
        if self.withheld:
            text += f", {self.withheld} not sent (communications stay on this machine)"
        if self.unembedded:
            text += f"; {self.unembedded:,} facts have no vector yet (run the backfill)"
        return text


def cluster_facts(
    *,
    model: str | None = None,
    threshold: float | None = None,
    neighbors: int | None = None,
    distill: bool = True,
    source: str = "*",
    fact_class: str = "",
    on_progress: Callable[[object], None] | None = None,
) -> ClusterSummary:
    """Group the facts that state the same claim and have the local model state each group once.

    ``model`` is the embedding model whose vectors are compared (default: the
    default model); ``threshold``/``neighbors`` default to
    facts.cluster_threshold/facts.cluster_neighbors. Without ``distill`` no chat
    model is asked and the clusters keep no statement. Raises LookupError for an
    unknown model, ValueError for a threshold outside 0..1.
    """
    from garage_rag.config import get_settings
    from garage_rag.db.emb_tables import get_model
    from garage_rag.enrich.clusters import Distiller
    from garage_rag.enrich.clusters import cluster_facts as run_clusters

    settings = get_settings()
    threshold = settings.fact_cluster_threshold if threshold is None else threshold
    neighbors = neighbors or settings.fact_cluster_neighbors
    if not 0.0 < threshold <= 1.0:
        raise ValueError(f"threshold must be above 0 and at most 1, not {threshold}")
    if neighbors < 1:
        raise ValueError(f"neighbors must be at least 1, not {neighbors}")
    distiller = Distiller() if distill else None
    with session_scope() as session:
        row = get_model(session, model)
        state = run_clusters(
            session,
            row,
            threshold=threshold,
            neighbors=neighbors,
            distiller=distiller,
            source=source,
            fact_class=fact_class or None,
            progress=on_progress,
        )
        return ClusterSummary(
            model=row.slug,
            threshold=threshold,
            distill_model=distiller.model_id if distiller is not None else "",
            facts=state.facts,
            unembedded=state.unembedded,
            clusters=int(state.clusters),
            clustered_facts=int(state.clustered_facts),
            kept=state.kept,
            dissolved=state.dissolved,
            failed=state.failed,
            withheld=state.withheld,
            errors=list(state.errors),
        )

"""Fact distillation over a set of documents, and browsing the facts it stored."""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime
from typing import Any

from sqlalchemy import and_, case, distinct, func, literal_column, or_, select
from sqlalchemy.orm import Session

from garage_rag.db.engine import session_scope
from garage_rag.db.models import CorpusClass, Document, Fact, Source


@dataclass
class EnrichEvent:
    """One document processed: ``index`` of ``total``, with its fact count or error."""

    index: int
    total: int
    document_id: int
    uri: str
    facts: int = 0
    error: str | None = None


@dataclass
class EnrichSummary:
    model_id: str
    provider: str
    total: int
    enriched: int
    facts: int
    failed: int

    @property
    def message(self) -> str:
        text = f"{self.enriched}/{self.total} documents enriched, {self.facts:,} facts extracted"
        if self.failed:
            text += f", {self.failed} failed"
        return text


def enrich_facts(
    *,
    source: str = "*",
    document_id: int | None = None,
    model: str | None = None,
    provider: str | None = None,
    on_start: Callable[[int, str, str], None] | None = None,
    on_event: Callable[[EnrichEvent], None] | None = None,
) -> EnrichSummary:
    """Distill documents into atomic facts; re-extraction replaces a document's prior facts.

    ``document_id`` picks one document and ignores ``source``. ``model``/``provider``
    default to facts.model/facts.provider. One failing document is recorded and
    the run continues. Raises LookupError when there is nothing to enrich.
    """
    from garage_rag.enrich.facts import configured_backend, extract_and_store_facts

    model_id, provider = configured_backend(model, provider)

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

        if on_start is not None:
            on_start(len(documents), model_id, provider)
        failed = 0
        total_facts = 0
        for index, document in enumerate(documents, start=1):
            event = EnrichEvent(index=index, total=len(documents), document_id=document.id, uri=document.uri or "")
            try:
                facts = extract_and_store_facts(session, document, model_id=model_id, provider=provider)
                session.commit()
                event.facts = len(facts)
                total_facts += len(facts)
            except Exception as exc:
                session.rollback()
                failed += 1
                event.error = str(exc)
            if on_event is not None:
                on_event(event)

        return EnrichSummary(
            model_id=model_id,
            provider=provider,
            total=len(documents),
            enriched=len(documents) - failed,
            facts=total_facts,
            failed=failed,
        )


# ---------------------------------------------------------------------------
# Browsing distilled facts
# ---------------------------------------------------------------------------

#: How a page of facts is ordered. ``relevance`` ranks by the full-text match and
#: falls back to ``newest`` when there is no query to rank against.
FACT_SORTS = ("newest", "document", "relevance")

#: Characters of document text shown on each side of a fact's grounding span.
DEFAULT_CONTEXT_CHARS = 200
MAX_CONTEXT_CHARS = 2000
DEFAULT_FACT_PAGE = 50
MAX_FACT_PAGE = 500

# The generated tsvector column (006_facts.sql), which the ORM does not map.
_FACT_TSV = literal_column("facts.tsv")


@dataclass(frozen=True)
class FactFilters:
    """What to narrow a fact listing to; a field left empty matches everything.

    A new provenance column becomes one more field here and one more clause in
    ``_apply_fact_filters``: the listing, its count and the stats all go through it.
    """

    query: str | None = None
    source: str | None = None
    document_id: int | None = None
    fact_class: str | None = None
    corpus_class: str | None = None


@dataclass
class FactRow:
    """One fact with its document, and the text around the span it was grounded to."""

    id: int
    document_id: int
    ord: int
    fact: str
    fact_class: str
    attributes: dict[str, Any]
    char_start: int | None
    char_end: int | None
    extractor: str
    extractor_model: str | None
    created_at: datetime | None
    document_title: str
    document_uri: str
    source_slug: str
    corpus_class: str
    trust_tier: str
    # ``excerpt`` is documents.content around the span, or "" when the fact has no
    # span or its document no stored text. ``excerpt_span_*`` locate the grounded
    # text inside the excerpt, in code points (Python str offsets, like char_start).
    excerpt: str = ""
    excerpt_span_start: int | None = None
    excerpt_span_end: int | None = None
    excerpt_truncated_before: bool = False
    excerpt_truncated_after: bool = False

    @property
    def evidence(self) -> str:
        """The grounded text itself, when the excerpt carries it."""
        if self.excerpt_span_start is None or self.excerpt_span_end is None:
            return ""
        return self.excerpt[self.excerpt_span_start : self.excerpt_span_end]


@dataclass
class FactPage:
    facts: list[FactRow]
    total: int
    limit: int
    offset: int

    @property
    def message(self) -> str:
        if not self.total:
            return "no facts"
        if not self.facts:
            return f"no facts past {self.offset:,} of {self.total:,}"
        return f"facts {self.offset + 1:,}-{self.offset + len(self.facts):,} of {self.total:,}"


@dataclass
class FactStats:
    facts: int
    documents: int
    by_source: dict[str, int]
    by_class: dict[str, int]

    @property
    def message(self) -> str:
        return f"{self.facts:,} facts across {self.documents:,} documents"


def _fact_tsquery(query: str):
    return func.websearch_to_tsquery("english", query)


def _joined(*columns):
    """``select(columns)`` over facts ⋈ documents ⋈ sources."""
    return (
        select(*columns)
        .select_from(Fact)
        .join(Document, Fact.document_id == Document.id)
        .join(Source, Document.source_id == Source.id)
    )


def _apply_fact_filters(stmt, filters: FactFilters):
    """Narrow a select over ``_joined`` to ``filters``. Raises ValueError for an unknown corpus class."""
    query = (filters.query or "").strip()
    if query:
        # Full text for words (stemmed, websearch syntax), substring for the rest:
        # a partial word, or an identifier the english parser splits apart.
        stmt = stmt.where(or_(_FACT_TSV.op("@@")(_fact_tsquery(query)), Fact.fact.icontains(query, autoescape=True)))
    if filters.source:
        stmt = stmt.where(Source.slug == filters.source)
    if filters.document_id:
        stmt = stmt.where(Fact.document_id == filters.document_id)
    if filters.fact_class:
        stmt = stmt.where(Fact.fact_class == filters.fact_class)
    if filters.corpus_class:
        try:
            corpus_class = CorpusClass(filters.corpus_class)
        except ValueError:
            choices = ", ".join(c.value for c in CorpusClass)
            raise ValueError(f"unknown corpus class {filters.corpus_class!r} (expected one of {choices})") from None
        stmt = stmt.where(Document.corpus_class == corpus_class)
    return stmt


def _fact_order(filters: FactFilters, sort: str) -> list:
    query = (filters.query or "").strip()
    if sort == "relevance" and query:
        rank = func.ts_rank(_FACT_TSV, _fact_tsquery(query))
        return [rank.desc(), Fact.created_at.desc(), Fact.id.desc()]
    if sort == "document":
        title = func.coalesce(func.nullif(Document.title, ""), Document.uri)
        return [title.asc(), Fact.document_id.asc(), Fact.ord.asc()]
    return [Fact.created_at.desc(), Fact.id.desc()]


def list_facts(
    session: Session,
    filters: FactFilters | None = None,
    *,
    sort: str = "newest",
    limit: int = DEFAULT_FACT_PAGE,
    offset: int = 0,
    context_chars: int = DEFAULT_CONTEXT_CHARS,
) -> FactPage:
    """One page of facts matching ``filters``, with the total across every page.

    Each fact comes with its document and ``context_chars`` of the document's text
    on either side of its grounding span, cut in SQL so a long document's content
    never leaves the database whole. ``limit`` is clamped to 1..MAX_FACT_PAGE (0
    means the default). Raises ValueError for an unknown ``sort`` or corpus class.
    """
    filters = filters or FactFilters()
    if sort not in FACT_SORTS:
        raise ValueError(f"unknown sort {sort!r} (expected one of {', '.join(FACT_SORTS)})")
    limit = min(max(limit, 1), MAX_FACT_PAGE) if limit else DEFAULT_FACT_PAGE
    offset = max(offset, 0)
    context = min(max(context_chars, 0), MAX_CONTEXT_CHARS)

    total = session.execute(_apply_fact_filters(_joined(func.count(Fact.id)), filters)).scalar_one()

    grounded = and_(Fact.char_start.isnot(None), Fact.char_end.isnot(None), Document.content.isnot(None))
    window_start = func.greatest(Fact.char_start - context, 0)
    # substr counts characters from 1; char_start/char_end count code points from 0.
    excerpt = case(
        (grounded, func.substr(Document.content, window_start + 1, Fact.char_end + context - window_start)),
        else_=None,
    )
    content_length = case((grounded, func.char_length(Document.content)), else_=None)
    stmt = _joined(
        Fact.id,
        Fact.document_id,
        Fact.ord,
        Fact.fact,
        Fact.fact_class,
        Fact.attributes,
        Fact.char_start,
        Fact.char_end,
        Fact.extractor,
        Fact.extractor_model,
        Fact.created_at,
        Document.title,
        Document.uri,
        Document.corpus_class,
        Document.trust_tier,
        Source.slug,
        excerpt.label("excerpt"),
        content_length.label("content_length"),
    )
    stmt = _apply_fact_filters(stmt, filters).order_by(*_fact_order(filters, sort)).limit(limit).offset(offset)

    rows = [_fact_row(row, context) for row in session.execute(stmt).mappings()]
    return FactPage(facts=rows, total=int(total or 0), limit=limit, offset=offset)


def _fact_row(row, context: int) -> FactRow:
    fact = FactRow(
        id=row["id"],
        document_id=row["document_id"],
        ord=row["ord"],
        fact=row["fact"],
        fact_class=row["fact_class"] or "fact",
        attributes=dict(row["attributes"] or {}),
        char_start=row["char_start"],
        char_end=row["char_end"],
        extractor=row["extractor"] or "",
        extractor_model=row["extractor_model"],
        created_at=row["created_at"],
        document_title=row["title"] or "",
        document_uri=row["uri"] or "",
        source_slug=row["slug"] or "",
        corpus_class=_label(row["corpus_class"]),
        trust_tier=_label(row["trust_tier"]),
    )
    excerpt = row["excerpt"]
    if excerpt is not None and fact.char_start is not None and fact.char_end is not None:
        window_start = max(fact.char_start - context, 0)
        fact.excerpt = excerpt
        fact.excerpt_span_start = min(max(fact.char_start - window_start, 0), len(excerpt))
        fact.excerpt_span_end = min(max(fact.char_end - window_start, fact.excerpt_span_start), len(excerpt))
        fact.excerpt_truncated_before = window_start > 0
        fact.excerpt_truncated_after = fact.char_end + context < (row["content_length"] or 0)
    return fact


def _label(value: object) -> str:
    return str(getattr(value, "value", value) or "")


def fact_stats(session: Session, filters: FactFilters | None = None) -> FactStats:
    """How many facts match ``filters``, over how many documents, per source and per class."""
    filters = filters or FactFilters()

    def scoped(*columns):
        return _apply_fact_filters(_joined(*columns), filters)

    facts, documents = session.execute(scoped(func.count(Fact.id), func.count(distinct(Fact.document_id)))).one()
    by_source = {
        slug: int(count)
        for slug, count in session.execute(
            scoped(Source.slug, func.count(Fact.id)).group_by(Source.slug).order_by(Source.slug)
        ).all()
    }
    by_class = {
        fact_class: int(count)
        for fact_class, count in session.execute(
            scoped(Fact.fact_class, func.count(Fact.id)).group_by(Fact.fact_class).order_by(Fact.fact_class)
        ).all()
    }
    return FactStats(facts=int(facts or 0), documents=int(documents or 0), by_source=by_source, by_class=by_class)

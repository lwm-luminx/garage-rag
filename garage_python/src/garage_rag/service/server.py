"""gRPC server for ``GarageService``: how the macOS app drives the Python pipeline.

The app reads the corpus through it, runs every operation it would otherwise shell
out to ``garage`` for (sources, models, backfill, fact distillation, schema,
settings, MCP client registration), and the ingest and embed XPC workers persist
through its database facade. The servicer carries no copies of CLI command bodies:
each handler translates protobuf to and from the garage_rag.ops function the CLI
command also calls.
"""

from __future__ import annotations

import contextlib
import functools
import inspect
import json
import logging
import os
import queue
import signal
import stat
import threading
import time
from collections.abc import Callable, Iterator
from concurrent import futures
from pathlib import Path
from typing import TYPE_CHECKING, Any, cast

import grpc

from garage_rag.proto.garage_pb2 import (
    AddSourceRequest,
    AddSourceResponse,
    BackfillRequest,
    BackfillStatus,
    BeginIngestSessionRequest,
    BeginIngestSessionResponse,
    CheckDocumentStatRequest,
    CheckDocumentStatResponse,
    DocumentAuthorInfo,
    DocumentChunkInfo,
    DocumentDetail,
    DocumentFactInfo,
    DocumentSummary,
    DropModelRequest,
    DropModelResponse,
    EmbeddingChunkItem,
    EnrichFactsRequest,
    EnrichFactsStatus,
    EnsureLlamaModelRequest,
    EnsureLlamaModelResponse,
    FactClassCount,
    FactPrompt,
    FactSummary,
    FinalizeIngestSessionRequest,
    FinalizeIngestSessionResponse,
    GetDocumentRequest,
    GetDocumentResponse,
    GetEmbeddingBatchesRequest,
    GetEmbeddingBatchesResponse,
    GetSettingRequest,
    GetSettingResponse,
    ImportSourcesToConfigRequest,
    ImportSourcesToConfigResponse,
    InitDbRequest,
    InitDbResponse,
    ListDocumentsRequest,
    ListDocumentsResponse,
    ListFactPromptsRequest,
    ListFactPromptsResponse,
    ListFactsRequest,
    ListFactsResponse,
    ListModelsRequest,
    ListModelsResponse,
    ListSourcesRequest,
    ListSourcesResponse,
    McpClientInfo,
    McpInstallRequest,
    McpInstallResponse,
    McpStatusRequest,
    McpStatusResponse,
    McpTargetOutcome,
    McpUninstallRequest,
    McpUninstallResponse,
    ModelInfo,
    PersistDocumentRequest,
    PersistDocumentResponse,
    PersistScanRequest,
    PersistScanResponse,
    PingRequest,
    PingResponse,
    ReconcileRequest,
    ReconcileResponse,
    RegisterModelRequest,
    RegisterModelResponse,
    RemoveSourceRequest,
    RemoveSourceResponse,
    ScanRequest,
    ScanResponse,
    ScanStatus,
    SearchHit,
    SearchRequest,
    SearchResponse,
    SetDefaultModelRequest,
    SetDefaultModelResponse,
    SetSettingRequest,
    SetSettingResponse,
    SourceInfo,
    SourceScanStatus,
    StatsRequest,
    StatsResponse,
    StatusRequest,
    StatusResponse,
    SyncSourcesRequest,
    SyncSourcesResponse,
    UndeclaredSource,
    UpdateEmbeddingsRequest,
    UpdateEmbeddingsResponse,
    VersionRequest,
    VersionResponse,
)
from garage_rag.proto.garage_pb2_grpc import (
    GarageServiceServicer,
    add_GarageServiceServicer_to_server,
)
from garage_rag.service.auth import (
    CONFIG_CHANGING_METHODS,
    METADATA_KEY,
    UNAUTHENTICATED_METHODS,
    config_change_allowed,
    token_from_env,
    token_matches,
)

if TYPE_CHECKING:
    from garage_rag.ingest.scanner import SourceScanResult

logger = logging.getLogger(__name__)


def _version() -> str:
    """Package version as reported by the CLI (``garage version``)."""
    # Imported here, not at module scope: garage_rag/__init__ pulls in the
    # submodules that import this one, so a top-level import would be a cycle.
    # gazelle:ignore garage_rag
    import garage_rag

    # ty only sees this target's sources, and garage_rag/__init__.py is not one
    # of them (that dependency is the cycle the local import breaks), so the
    # package resolves here without its attributes.
    return garage_rag.__version__  # ty: ignore[unresolved-attribute]


# Exceptions the plain functions raise, in the gRPC status they mean. Order matters:
# FileExistsError and PermissionError are OSErrors and must not fall through to a
# broader match, and only these four are translated; anything else is a server
# fault and stays UNKNOWN so it is never mistaken for a client error.
_STATUS_FOR_EXCEPTION: tuple[tuple[type[Exception], grpc.StatusCode], ...] = (
    (FileExistsError, grpc.StatusCode.ALREADY_EXISTS),
    (PermissionError, grpc.StatusCode.PERMISSION_DENIED),
    (LookupError, grpc.StatusCode.NOT_FOUND),
    (ValueError, grpc.StatusCode.INVALID_ARGUMENT),
)


def _abort_for(context: grpc.ServicerContext, exc: Exception) -> None:
    from garage_rag.config import ConfigError

    if isinstance(exc, ConfigError):
        context.abort(grpc.StatusCode.INVALID_ARGUMENT, str(exc))
    for exc_type, code in _STATUS_FOR_EXCEPTION:
        if isinstance(exc, exc_type):
            context.abort(code, str(exc))


def _grpc_errors[**P, R](handler: Callable[P, R]) -> Callable[P, R]:
    """Abort the RPC with the status code an exception from the handler implies.

    Streaming handlers are generators whose exceptions surface while the response
    is iterated, not when the handler is called, so those are wrapped as generators.
    """
    if inspect.isgeneratorfunction(handler):

        @functools.wraps(handler)
        def stream_wrapper(*args: P.args, **kwargs: P.kwargs) -> Iterator[Any]:
            context = cast(grpc.ServicerContext, args[2] if len(args) > 2 else kwargs["context"])
            try:
                yield from cast(Iterator[Any], handler(*args, **kwargs))
            except Exception as exc:
                _abort_for(context, exc)
                raise

        return cast(Callable[P, R], stream_wrapper)

    @functools.wraps(handler)
    def wrapper(*args: P.args, **kwargs: P.kwargs) -> R:
        context = cast(grpc.ServicerContext, args[2] if len(args) > 2 else kwargs["context"])
        try:
            return handler(*args, **kwargs)
        except Exception as exc:
            _abort_for(context, exc)
            raise

    return wrapper


_DONE = object()


class _StreamCancelled(BaseException):
    """Raised inside a streaming op's callback once its RPC has ended.

    A BaseException so an op's per-item ``except Exception`` (enrich_facts records
    a failed document and moves on) cannot swallow it: cancelling the call has to
    stop the work, as killing the `garage` process used to.
    """


def _stream_events[E](
    run: Callable[[Callable[[E], None]], object], context: grpc.ServicerContext | None = None
) -> Iterator[E]:
    """Yield the events ``run`` reports to its callback, as it reports them.

    The ops functions report progress through a callback; a gRPC streaming
    handler has to yield. ``run`` executes on a worker thread and the events cross
    a queue; an exception in ``run`` is re-raised here, in the handler, after the
    events that preceded it. When the call ends early (the client cancelled, the
    deadline passed) the next event ``run`` reports raises instead, so the work
    stops at its next progress step rather than running on unobserved.
    """
    events: queue.Queue[Any] = queue.Queue()
    failure: list[BaseException] = []
    ended = threading.Event()
    add_callback = getattr(context, "add_callback", None)
    if add_callback is not None:
        add_callback(ended.set)

    def emit(event: E) -> None:
        if ended.is_set():
            raise _StreamCancelled
        events.put(event)

    def worker() -> None:
        try:
            run(emit)
        except _StreamCancelled:
            pass
        except BaseException as exc:  # re-raised on the handler thread below
            failure.append(exc)
        finally:
            events.put(_DONE)

    threading.Thread(target=worker, name="garage-grpc-stream", daemon=True).start()
    try:
        while (item := events.get()) is not _DONE:
            yield item
    finally:
        # Reached on completion and when gRPC closes the generator of a call that ended early.
        ended.set()
    if failure:
        raise failure[0]


def _enum_value(value: Any) -> str:
    return value.value if hasattr(value, "value") else str(value)


def _config_change[**P, R](handler: Callable[P, R]) -> Callable[P, R]:
    """Refuse a config-changing method to a caller the server cannot vouch for.

    See :data:`garage_rag.service.auth.CONFIG_CHANGING_METHODS`: with no token
    configured, only a server bound to the owner-only Unix socket answers them
    (``GarageRpcServicer.callers_vouched_for``). Applied outside ``_grpc_errors`` so
    its abort is not re-mapped.
    """
    name = cast(Any, handler).__name__
    assert name in CONFIG_CHANGING_METHODS, name

    @functools.wraps(handler)
    def wrapper(*args: P.args, **kwargs: P.kwargs) -> R:
        servicer = cast("GarageRpcServicer", args[0])
        context = cast(grpc.ServicerContext, args[2] if len(args) > 2 else kwargs["context"])
        if not servicer.callers_vouched_for:
            context.abort(
                grpc.StatusCode.PERMISSION_DENIED,
                f"{name} changes configuration; it needs the {METADATA_KEY} token or the Unix socket",
            )
        return handler(*args, **kwargs)

    cast(Any, wrapper).__garage_config_change__ = True  # the test checks every listed method carries it
    return wrapper


class GarageRpcServicer(GarageServiceServicer):
    """gRPC servicer implementing ``GarageService``."""

    def __init__(self, stop_event: threading.Event | None = None, *, callers_vouched_for: bool = True) -> None:
        self.stop_event = stop_event or threading.Event()
        # Whether every caller of this server is one it can vouch for (see
        # ``_config_change``): the per-launch token guards it, or it is bound to the
        # owner-only Unix socket. A servicer built directly, as the in-process client and
        # the tests do, is trusted.
        self.callers_vouched_for = callers_vouched_for

    # -----------------------------------------------------------------------
    # System / Lifecycle
    # -----------------------------------------------------------------------

    @_grpc_errors
    def Ping(self, request: PingRequest, context: grpc.ServicerContext) -> PingResponse:
        """Ping / Healthcheck."""
        return PingResponse(
            message=request.message or "pong",
            timestamp=int(time.time()),
        )

    @_grpc_errors
    def GetStatus(self, request: StatusRequest, context: grpc.ServicerContext) -> StatusResponse:
        """Retrieve server and database status."""
        db_status = "unknown"
        is_ready = True
        try:
            from sqlalchemy import text

            from garage_rag.db.engine import get_engine
            from garage_rag.db.migrate import has_pending_migrations

            with get_engine().connect() as conn:
                conn.execute(text("SELECT 1"))

            if has_pending_migrations():
                db_status = "needs_migration"
                is_ready = False
            else:
                db_status = "connected"
                is_ready = True
        except Exception as e:
            db_status = f"error: {e}"
            is_ready = False

        return StatusResponse(
            version=_version(),
            is_ready=is_ready,
            pid=os.getpid(),
            db_status=db_status,
            server_type="grpc",
        )

    @_grpc_errors
    def GetVersion(self, request: VersionRequest, context: grpc.ServicerContext) -> VersionResponse:
        """Get the garage version."""
        return VersionResponse(version=_version())

    # -----------------------------------------------------------------------
    # Search
    # -----------------------------------------------------------------------

    @_grpc_errors
    def Search(self, request: SearchRequest, context: grpc.ServicerContext) -> SearchResponse:
        """Search the corpus with hybrid vector + keyword retrieval."""
        from garage_rag.db.engine import session_scope
        from garage_rag.search.hybrid import SearchMode, snippet
        from garage_rag.search.hybrid import search as run_search

        with session_scope() as session:
            hits = run_search(
                session,
                request.query,
                limit=request.limit or 10,
                mode=cast(SearchMode, request.mode or "hybrid"),
                model_slug=request.model or None,
                corpus_classes=list(request.corpus_classes) or None,
                trust_tiers=list(request.trust_tiers) or None,
                sources=list(request.sources) or None,
                author=request.author or None,
                direction=request.direction or None,
            )

        proto_hits: list[SearchHit] = []
        for rank, hit in enumerate(hits, start=1):
            proto_hits.append(
                SearchHit(
                    rank=rank,
                    title=hit.title or "(untitled)",
                    uri=hit.uri,
                    corpus_class=str(hit.corpus_class),
                    trust_tier=str(hit.trust_tier),
                    matched_by=str(hit.matched_by),
                    score=float(hit.score),
                    heading_path=hit.heading_path or "",
                    authors=hit.authors or [],
                    text=hit.text or "",
                    snippet=hit.text if request.full else snippet(hit.text),
                    direction=hit.direction or "",
                    sender=hit.sender or "",
                )
            )

        return SearchResponse(
            hits=proto_hits,
            total_hits=len(proto_hits),
            formatted_output=f"Found {len(proto_hits)} results for {request.query!r}",
        )

    # -----------------------------------------------------------------------
    # Documents & Chunks
    # -----------------------------------------------------------------------

    @_grpc_errors
    def ListDocuments(self, request: ListDocumentsRequest, context: grpc.ServicerContext) -> ListDocumentsResponse:
        """List documents, optionally filtered by source/class/trust/query."""
        from sqlalchemy import func, or_

        from garage_rag.db.engine import session_scope
        from garage_rag.db.models import Chunk, Document, Fact, Source

        with session_scope() as session:
            query = session.query(Document).join(Source, Document.source_id == Source.id)

            if request.source:
                query = query.filter(Source.slug == request.source)
            if request.corpus_class:
                query = query.filter(Document.corpus_class == request.corpus_class)
            if request.trust_tier:
                query = query.filter(Document.trust_tier == request.trust_tier)
            if request.query:
                like = f"%{request.query}%"
                query = query.filter(or_(Document.title.ilike(like), Document.uri.ilike(like)))

            total_count = query.with_entities(func.count(Document.id)).scalar() or 0

            limit = request.limit or 100
            offset = max(request.offset, 0)
            documents = (
                query.order_by(Document.ingested_at.desc(), Document.id.desc()).offset(offset).limit(limit).all()
            )

            doc_ids = [d.id for d in documents]
            chunk_counts: dict[int, int] = {}
            fact_counts: dict[int, int] = {}
            slugs_by_doc_id: dict[int, str] = {}
            if doc_ids:
                chunk_counts = dict(
                    session.query(Chunk.document_id, func.count(Chunk.id))
                    .filter(Chunk.document_id.in_(doc_ids))
                    .group_by(Chunk.document_id)
                    .all()
                )
                fact_counts = dict(
                    session.query(Fact.document_id, func.count(Fact.id))
                    .filter(Fact.document_id.in_(doc_ids))
                    .group_by(Fact.document_id)
                    .all()
                )
                slugs_by_doc_id = dict(
                    session.query(Document.id, Source.slug)
                    .join(Source, Document.source_id == Source.id)
                    .filter(Document.id.in_(doc_ids))
                    .all()
                )

            summaries = [
                DocumentSummary(
                    id=d.id,
                    uri=d.uri,
                    title=d.title or "",
                    source_slug=slugs_by_doc_id.get(d.id, ""),
                    corpus_class=str(d.corpus_class),
                    trust_tier=str(d.trust_tier),
                    mime=d.mime or "",
                    lang=d.lang or "",
                    byte_size=d.byte_size or 0,
                    chunk_count=chunk_counts.get(d.id, 0),
                    state=str(d.state),
                    ingested_at=d.ingested_at.isoformat() if d.ingested_at else "",
                    fact_count=fact_counts.get(d.id, 0),
                )
                for d in documents
            ]

        return ListDocumentsResponse(
            documents=summaries,
            total_count=total_count,
            formatted_output=f"{len(summaries)} of {total_count} documents",
        )

    @_grpc_errors
    def GetDocument(self, request: GetDocumentRequest, context: grpc.ServicerContext) -> GetDocumentResponse:
        """Fetch a single document's metadata and its chunks."""
        from garage_rag.db.engine import session_scope
        from garage_rag.db.models import Chunk, Document, Fact, Source

        with session_scope() as session:
            document = session.get(Document, request.document_id)
            if document is None:
                context.abort(grpc.StatusCode.NOT_FOUND, f"document {request.document_id} not found")

            source = session.get(Source, document.source_id)

            chunks = session.query(Chunk).filter(Chunk.document_id == document.id).order_by(Chunk.ord.asc()).all()

            facts = session.query(Fact).filter(Fact.document_id == document.id).order_by(Fact.ord.asc()).all()

            authors = [
                DocumentAuthorInfo(
                    name=da.author.display_name,
                    role=str(da.role),
                    confidence=float(da.confidence),
                )
                for da in document.authors
            ]

            detail = DocumentDetail(
                id=document.id,
                uri=document.uri,
                title=document.title or "",
                source_slug=source.slug if source else "",
                corpus_class=str(document.corpus_class),
                trust_tier=str(document.trust_tier),
                mime=document.mime or "",
                lang=document.lang or "",
                byte_size=document.byte_size or 0,
                extractor=document.extractor or "",
                extractor_version=document.extractor_version or "",
                chunker=document.chunker or "",
                meta_json=json.dumps(document.meta) if document.meta else "",
                state=str(document.state),
                error=document.error or "",
                ingested_at=document.ingested_at.isoformat() if document.ingested_at else "",
                authors=authors,
            )

            proto_chunks = [
                DocumentChunkInfo(
                    id=c.id,
                    ord=c.ord,
                    text=c.text,
                    token_count=c.token_count or 0,
                    char_start=c.char_start,
                    char_end=c.char_end,
                    heading_path=c.heading_path or "",
                )
                for c in chunks
            ]

            proto_facts = [
                DocumentFactInfo(
                    id=f.id,
                    ord=f.ord,
                    fact=f.fact,
                    fact_class=f.fact_class or "",
                    attributes_json=json.dumps(f.attributes) if f.attributes else "",
                    char_start=f.char_start,
                    char_end=f.char_end,
                    extractor=f.extractor or "",
                )
                for f in facts
            ]

        return GetDocumentResponse(
            document=detail,
            chunks=proto_chunks,
            formatted_output=f"{detail.title or detail.uri}: {len(proto_chunks)} chunks, {len(proto_facts)} facts",
            facts=proto_facts,
        )

    # -----------------------------------------------------------------------
    # Facts
    # -----------------------------------------------------------------------

    @_grpc_errors
    def ListFacts(self, request: ListFactsRequest, context: grpc.ServicerContext) -> ListFactsResponse:
        """List facts with their documents, optionally filtered and searched."""
        from garage_rag.db.engine import session_scope
        from garage_rag.ops.facts import list_facts

        with session_scope() as session:
            page = list_facts(
                session,
                query=request.query,
                source=request.source,
                fact_class=request.fact_class,
                corpus_class=request.corpus_class,
                document_id=request.document_id or None,
                limit=request.limit or 200,
                offset=request.offset,
            )

        summaries = [
            FactSummary(
                id=f.id,
                document_id=f.document_id,
                ord=f.ord,
                fact=f.fact,
                fact_class=f.fact_class or "",
                attributes_json=json.dumps(f.attributes) if f.attributes else "",
                char_start=f.char_start,
                char_end=f.char_end,
                extractor=f.extractor,
                extractor_model=f.extractor_model or "",
                created_at=f.created_at.isoformat() if f.created_at else "",
                document_title=f.document_title or "",
                document_uri=f.document_uri or "",
                source_slug=f.source_slug or "",
                corpus_class=f.corpus_class or "",
                excerpt=f.excerpt or "",
                excerpt_start=f.excerpt_start if f.excerpt else 0,
            )
            for f in page.facts
        ]
        return ListFactsResponse(
            facts=summaries,
            total_count=page.total,
            classes=[FactClassCount(fact_class=name, count=count) for name, count in page.classes],
            formatted_output=f"{len(summaries)} of {page.total} facts",
        )

    # -----------------------------------------------------------------------
    # Sources
    # -----------------------------------------------------------------------

    @_grpc_errors
    def ListSources(self, request: ListSourcesRequest, context: grpc.ServicerContext) -> ListSourcesResponse:
        """List registered sources."""
        from sqlalchemy import func

        from garage_rag.db.engine import session_scope
        from garage_rag.db.models import Document, Source

        with session_scope() as session:
            sources = session.query(Source).order_by(Source.id).all()
            doc_counts = dict(
                session.query(Document.source_id, func.count(Document.id)).group_by(Document.source_id).all()
            )
            proto_sources: list[SourceInfo] = [
                SourceInfo(
                    slug=s.slug,
                    kind=s.kind,
                    corpus_class=str(s.default_class),
                    trust_tier=str(s.default_trust),
                    enabled=bool(s.enabled),
                    root=s.root,
                    document_count=doc_counts.get(s.id, 0),
                    expected_elements=getattr(s, "expected_elements", 0) or 0,
                )
                for s in sources
            ]

        return ListSourcesResponse(
            sources=proto_sources,
            formatted_output=f"{len(proto_sources)} sources registered",
        )

    # -----------------------------------------------------------------------
    # Embedding models & stats
    # -----------------------------------------------------------------------

    @_grpc_errors
    def ListModels(self, request: ListModelsRequest, context: grpc.ServicerContext) -> ListModelsResponse:
        """List registered embedding models."""
        from garage_rag.db.emb_tables import list_models
        from garage_rag.db.engine import session_scope

        with session_scope() as session:
            models = list_models(session)
            proto_models: list[ModelInfo] = [
                ModelInfo(
                    slug=m.slug,
                    provider=m.provider,
                    model_ref=m.model_ref,
                    dims=m.dims,
                    stored_dims=m.stored_dims,
                    storage_kind=m.storage_kind,
                    index_kind=m.index_kind,
                    table_name=m.table_name,
                    is_default=m.is_default,
                    model_id=m.model_id or "",
                    distance=m.distance,
                    modality=getattr(m, "modality", None) or "text",
                )
                for m in models
            ]

        return ListModelsResponse(
            models=proto_models,
            formatted_output=f"{len(proto_models)} models registered",
        )

    @_grpc_errors
    def GetStats(self, request: StatsRequest, context: grpc.ServicerContext) -> StatsResponse:
        """Row counts across the corpus, per source and per embedding model."""
        from sqlalchemy import func

        from garage_rag.db.emb_tables import count_vectors, list_models
        from garage_rag.db.engine import session_scope
        from garage_rag.db.models import Chunk, Document, Source

        with session_scope() as session:
            doc_count = session.query(func.count(Document.id)).scalar() or 0
            chunk_count = session.query(func.count(Chunk.id)).scalar() or 0
            source_count = session.query(func.count(Source.id)).scalar() or 0
            documents_by_source = {
                slug: int(count)
                for slug, count in session.query(Source.slug, func.count(Document.id))
                .outerjoin(Document, Document.source_id == Source.id)
                .group_by(Source.slug)
                .all()
            }
            models = list_models(session)
            chunks_by_model = {m.slug: count_vectors(session, m) for m in models}

        return StatsResponse(
            documents=doc_count,
            chunks=chunk_count,
            sources=source_count,
            models=len(models),
            chunks_by_model=chunks_by_model,
            documents_by_source=documents_by_source,
            formatted_output=(
                f"Corpus: {doc_count:,} documents, {chunk_count:,} chunks across "
                f"{source_count} sources, {len(models)} embedding models"
            ),
        )

    # -----------------------------------------------------------------------
    # Source operations (the app's `garage add-source` / `remove-source` / `scan` /
    # `sync` / `config import-sources` / `reconcile`)
    # -----------------------------------------------------------------------

    @_config_change
    @_grpc_errors
    def AddSource(self, request: AddSourceRequest, context: grpc.ServicerContext) -> AddSourceResponse:
        """Register a source root, or update the one registered under the slug."""
        from garage_rag.ops.sources import add_source

        result = add_source(
            request.slug,
            request.root,
            kind=request.kind or "filesystem",
            corpus_class=request.corpus_class or "document",
            trust=request.trust or "authored",
        )
        return AddSourceResponse(
            slug=result.slug, root=str(result.root), created=result.created, message=result.message
        )

    @_config_change
    @_grpc_errors
    def RemoveSource(self, request: RemoveSourceRequest, context: grpc.ServicerContext) -> RemoveSourceResponse:
        """Deregister a source and delete its documents, chunks and vectors."""
        from garage_rag.ops.sources import remove_source

        result = remove_source(request.slug)
        return RemoveSourceResponse(
            slug=result.slug, deleted_documents=result.deleted_documents, message=result.message
        )

    @_grpc_errors
    def Scan(self, request: ScanRequest, context: grpc.ServicerContext) -> Iterator[ScanStatus]:
        """Count items per source and record the expected totals, streaming the running count."""
        from garage_rag.ops.sources import ScanEvent, scan_sources

        def source_status(r: SourceScanResult) -> SourceScanStatus:
            return SourceScanStatus(
                source=r.source_slug,
                kind=r.kind,
                root=str(r.root),
                item_count=r.item_count,
                item_type=r.item_type,
                duration_seconds=r.duration_seconds,
                error=r.error or "",
            )

        def run(emit: Callable[[ScanStatus], None]) -> object:
            def on_event(event: ScanEvent) -> None:
                emit(
                    ScanStatus(
                        phase=event.phase,
                        source=event.source,
                        source_items=event.source_items,
                        total_items=event.total_items,
                        result=source_status(event.result) if event.result is not None else None,
                    )
                )

            results = scan_sources(request.source or "*", include_code=request.include_code, on_event=on_event)
            total = sum(r.item_count for r in results)
            emit(
                ScanStatus(
                    phase="finished",
                    total_items=total,
                    summary=ScanResponse(
                        sources=[source_status(r) for r in results],
                        total_items=total,
                        message=(
                            f"Scanned {len(results)} source(s): {total:,} items"
                            if results
                            else "no sources registered to scan"
                        ),
                    ),
                )
            )
            return results

        yield from _stream_events(run, context)

    @_grpc_errors
    def SyncSources(self, request: SyncSourcesRequest, context: grpc.ServicerContext) -> SyncSourcesResponse:
        """Apply the sources declared in the config file to the database."""
        from garage_rag.ops.sources import sync_sources

        result = sync_sources(apply=not request.dry_run)
        return SyncSourcesResponse(
            config_path=str(result.config_path or ""),
            declared=result.declared,
            applied=result.applied,
            created=result.created,
            updated=result.updated,
            undeclared=[UndeclaredSource(slug=slug, document_count=count) for slug, count in result.undeclared],
            message="\n".join(result.lines),
        )

    @_config_change
    @_grpc_errors
    def ImportSourcesToConfig(
        self, request: ImportSourcesToConfigRequest, context: grpc.ServicerContext
    ) -> ImportSourcesToConfigResponse:
        """Copy the database's sources into the config file."""
        from garage_rag.ops.sources import import_sources_into_config

        result = import_sources_into_config(Path(request.path) if request.path else None)
        return ImportSourcesToConfigResponse(path=str(result.path), added=result.added, message=result.message)

    @_grpc_errors
    def Reconcile(self, request: ReconcileRequest, context: grpc.ServicerContext) -> ReconcileResponse:
        """Delete (or, without apply, count) documents whose files no longer exist."""
        from garage_rag.db.engine import session_scope
        from garage_rag.ingest.reconcile import reconcile_source

        with session_scope() as session:
            result = reconcile_source(session, request.source, dry_run=not request.apply, force=request.force)
        if result.refused:
            message = f"refused: {result.reason}"
        elif not result.candidates:
            message = f"nothing to reconcile for {result.source}"
        elif request.apply:
            message = f"deleted {result.deleted:,} of {result.total_documents:,} documents from {result.source}"
        else:
            message = (
                f"dry run: {result.candidates:,} of {result.total_documents:,} documents in {result.source} "
                f"are missing ({result.fraction:.1%})"
            )
        return ReconcileResponse(
            source=result.source,
            total_documents=result.total_documents,
            candidates=result.candidates,
            deleted=result.deleted,
            fraction=result.fraction,
            refused=result.refused,
            reason=result.reason,
            message=message,
        )

    # -----------------------------------------------------------------------
    # Model operations
    # -----------------------------------------------------------------------

    @_config_change
    @_grpc_errors
    def RegisterModel(self, request: RegisterModelRequest, context: grpc.ServicerContext) -> RegisterModelResponse:
        """Register an embedding model and create its table and index."""
        from garage_rag.ops.models import register_model

        row = register_model(
            request.slug,
            dims=request.dims or None,
            model_ref=request.model_ref or None,
            provider=request.provider or None,
            model_id=request.model_id or None,
            distance=request.distance or None,
            modality=request.modality or None,
            make_default=request.make_default,
        )
        return RegisterModelResponse(
            model=ModelInfo(
                slug=row.slug,
                provider=row.provider,
                model_ref=row.model_ref,
                dims=row.dims,
                stored_dims=row.stored_dims,
                storage_kind=row.storage_kind,
                index_kind=row.index_kind,
                table_name=row.table_name,
                is_default=row.is_default,
                model_id=row.model_id or "",
                distance=row.distance,
                modality=row.modality,
            ),
            notes=row.notes,
            message="\n".join([row.message, *row.notes]),
        )

    @_config_change
    @_grpc_errors
    def SetDefaultModel(
        self, request: SetDefaultModelRequest, context: grpc.ServicerContext
    ) -> SetDefaultModelResponse:
        """Point the default embedding model at a registered slug."""
        from garage_rag.ops.models import set_default_model

        set_default_model(request.slug)
        return SetDefaultModelResponse(message=f"default model = {request.slug}")

    @_config_change
    @_grpc_errors
    def DropModel(self, request: DropModelRequest, context: grpc.ServicerContext) -> DropModelResponse:
        """Deregister a model and drop its vectors."""
        from garage_rag.ops.models import drop_model

        drop_model(request.slug)
        return DropModelResponse(message=f"dropped {request.slug}")

    @_grpc_errors
    def Backfill(self, request: BackfillRequest, context: grpc.ServicerContext) -> Iterator[BackfillStatus]:
        """Embed pending chunks, streaming each model's progress."""
        from garage_rag.ops.backfill import BackfillEvent, backfill

        def run(emit: Callable[[BackfillEvent], None]) -> object:
            return backfill(
                request.model or None,
                batch_size=request.batch_size or None,
                limit=request.limit or None,
                verify=not request.skip_verify,
                on_event=emit,
            )

        for event in _stream_events(run, context):
            yield BackfillStatus(
                model_slug=event.model,
                phase=event.phase,
                total=event.total,
                embedded=event.embedded,
                failed=event.failed,
                remaining=event.remaining,
                batches=event.batches,
                message=event.message,
            )

    @_grpc_errors
    def EnsureLlamaModel(
        self, request: EnsureLlamaModelRequest, context: grpc.ServicerContext
    ) -> EnsureLlamaModelResponse:
        """Have LlamaXPCService load a model unless it is resident, through this process's host.

        Only the loader the host installed is used (never this RPC again), so a server
        outside the app answers FAILED_PRECONDITION rather than calling itself.
        """
        from garage_rag.xpc.host import ModelLoadError, ensure_model

        if not request.model.strip():
            raise ValueError("model is required")
        try:
            message = ensure_model(request.model, allow_remote=False)
        except ModelLoadError as exc:
            context.abort(grpc.StatusCode.FAILED_PRECONDITION, str(exc))
            raise  # abort raises; this keeps type checkers from seeing a fall-through
        return EnsureLlamaModelResponse(message=message)

    # -----------------------------------------------------------------------
    # Fact distillation
    # -----------------------------------------------------------------------

    @_grpc_errors
    def EnrichFacts(self, request: EnrichFactsRequest, context: grpc.ServicerContext) -> Iterator[EnrichFactsStatus]:
        """Distill documents into facts, streaming a status per document."""
        from garage_rag.ops.facts import enrich_facts

        def run(emit: Callable[[EnrichFactsStatus], None]) -> object:
            def on_start(total: int, model: str, provider: str) -> None:
                emit(
                    EnrichFactsStatus(
                        phase="started",
                        total=total,
                        model=model,
                        provider=provider,
                        message=f"enriching {total:,} document(s) via {provider}/{model}",
                    )
                )

            def on_event(event) -> None:
                emit(
                    EnrichFactsStatus(
                        phase="document",
                        total=event.total,
                        index=event.index,
                        document_id=event.document_id,
                        document_uri=event.uri,
                        facts=event.facts,
                        error=event.error or "",
                        skipped=int(event.skipped),
                        prompts=event.prompts,
                        message=(
                            f"{event.index}/{event.total}: {event.uri or event.document_id}"
                            + (
                                f": {event.error}"
                                if event.error
                                else ": skipped"
                                if event.skipped
                                else f": {event.facts} facts"
                            )
                        ),
                    )
                )

            summary = enrich_facts(
                source=request.source or "*",
                document_id=request.document_id or None,
                model=request.model or None,
                provider=request.provider or None,
                prompts=list(request.prompts) or None,
                stale_only=request.stale_only,
                on_start=on_start,
                on_event=on_event,
            )
            emit(
                EnrichFactsStatus(
                    phase="finished",
                    total=summary.total,
                    facts=summary.facts,
                    model=summary.model_id,
                    provider=summary.provider,
                    enriched=summary.enriched,
                    failed=summary.failed,
                    skipped=summary.skipped,
                    prompts=summary.prompts,
                    message=summary.message,
                )
            )
            return summary

        yield from _stream_events(run, context)

    @_grpc_errors
    def ListFactPrompts(
        self, request: ListFactPromptsRequest, context: grpc.ServicerContext
    ) -> ListFactPromptsResponse:
        """The effective fact prompts, and facts.prompts as configured (what SetSetting takes back)."""
        from garage_rag.ops.facts import list_fact_prompts
        from garage_rag.ops.settings import get_setting

        prompts = [
            FactPrompt(
                name=prompt.name,
                description=prompt.description,
                examples_json=json.dumps(prompt.to_config()["examples"], ensure_ascii=False),
                corpus_classes=list(prompt.corpus_classes),
                sources=list(prompt.sources),
                enabled=prompt.enabled,
                builtin=prompt.builtin,
                customized=prompt.customized,
                sha256=prompt.sha256.hex(),
            )
            for prompt in list_fact_prompts()
        ]
        return ListFactPromptsResponse(
            prompts=prompts, configured_json=json.dumps(get_setting("facts.prompts"), ensure_ascii=False)
        )

    # -----------------------------------------------------------------------
    # Schema & settings
    # -----------------------------------------------------------------------

    @_config_change
    @_grpc_errors
    def InitDb(self, request: InitDbRequest, context: grpc.ServicerContext) -> InitDbResponse:
        """Apply the schema migrations (idempotent). Guarded: ``schema_dir`` names SQL the server runs."""
        from garage_rag.config import get_settings
        from garage_rag.db.migrate import apply_migrations, redact_url

        applied = apply_migrations(schema_dir=Path(request.schema_dir) if request.schema_dir else None)
        lines = [f"applied {name}" for name in applied]
        lines.append(f"schema ready ({redact_url(get_settings().database_url)})")
        return InitDbResponse(applied=list(applied), message="\n".join(lines))

    @_grpc_errors
    def GetSetting(self, request: GetSettingRequest, context: grpc.ServicerContext) -> GetSettingResponse:
        """One effective setting, JSON-encoded."""
        from garage_rag.ops.settings import get_setting

        return GetSettingResponse(name=request.name, value_json=json.dumps(get_setting(request.name)))

    @_config_change
    @_grpc_errors
    def SetSetting(self, request: SetSettingRequest, context: grpc.ServicerContext) -> SetSettingResponse:
        """Change one setting in the config file, validated before writing."""
        from garage_rag.ops.settings import set_setting

        written, stored = set_setting(request.name, request.value, path=Path(request.path) if request.path else None)
        return SetSettingResponse(name=request.name, value_json=json.dumps(stored), path=str(written))

    # -----------------------------------------------------------------------
    # MCP client registration
    # -----------------------------------------------------------------------

    @_config_change
    @_grpc_errors
    def McpInstall(self, request: McpInstallRequest, context: grpc.ServicerContext) -> McpInstallResponse:
        """Register this MCP server with a client (no prompts: the app asked)."""
        from garage_rag.ops.mcp import install_mcp_server

        report = install_mcp_server(
            target=request.target or "project",
            path=Path(request.path) if request.path else None,
            all_configs=request.all,
            name=request.name or "garage-rag",
            stdio=request.stdio,
            host=request.host or None,
            port=request.port or None,
            route=request.route or None,
            force=request.force,
            dry_run=request.dry_run,
        )
        return McpInstallResponse(
            url=report.url or "",
            command=report.command or "",
            args=report.args,
            fell_back=report.fell_back,
            outcomes=[
                McpTargetOutcome(
                    key=o.key,
                    label=o.label,
                    path=str(o.path),
                    written=o.written,
                    created_file=o.created_file,
                    replaced_entry=o.replaced_entry,
                    backup_path=str(o.backup or ""),
                    skipped=o.skipped or "",
                    preview_json=json.dumps(o.preview) if o.preview is not None else "",
                )
                for o in report.outcomes
            ],
            message="\n".join(report.lines),
        )

    @_config_change
    @_grpc_errors
    def McpUninstall(self, request: McpUninstallRequest, context: grpc.ServicerContext) -> McpUninstallResponse:
        """Remove this server from one client's config."""
        from garage_rag.ops.mcp import uninstall_mcp_server

        name = request.name or "garage-rag"
        config, removed = uninstall_mcp_server(
            target=request.target or "project", path=Path(request.path) if request.path else None, name=name
        )
        message = f"removed {name} from {config}" if removed else f"{name} was not configured in {config}"
        return McpUninstallResponse(path=str(config), removed=removed, message=message)

    @_grpc_errors
    def McpStatus(self, request: McpStatusRequest, context: grpc.ServicerContext) -> McpStatusResponse:
        """Which known clients have this server registered."""
        from garage_rag.ops.mcp import mcp_status

        report = mcp_status()
        return McpStatusResponse(
            server_command=report.server_command,
            clients=[
                McpClientInfo(
                    key=c.key,
                    label=c.label,
                    path=str(c.path),
                    registered=c.registered,
                    config_exists=c.config_exists,
                )
                for c in report.clients
            ],
        )

    # -----------------------------------------------------------------------
    # Database facade for the ingest worker
    #
    # ``GrpcIngestStorageGateway`` (ingest/gateway.py) is the client side of these
    # RPCs; the server side is the SQLAlchemy gateway the in-process pipeline uses,
    # so both paths persist through one implementation.
    # -----------------------------------------------------------------------

    @staticmethod
    def _ingest_gateway():
        from garage_rag.db.engine import session_scope
        from garage_rag.ingest.gateway import SqlAlchemyIngestStorageGateway

        return SqlAlchemyIngestStorageGateway(session_scope)

    @_grpc_errors
    def BeginIngestSession(
        self, request: BeginIngestSessionRequest, context: grpc.ServicerContext
    ) -> BeginIngestSessionResponse:
        """Open an ingest run for a source (or ``*`` for every enabled one)."""
        ctx = self._ingest_gateway().begin_session(request.source_slug, include_code=request.include_code)
        return BeginIngestSessionResponse(
            source_id=ctx.source_id,
            slug=ctx.slug,
            root=str(ctx.root),
            default_class=_enum_value(ctx.default_class),
            default_trust=_enum_value(ctx.default_trust),
            run_id=ctx.run_id,
            source_slugs=ctx.source_slugs,
            kind=ctx.kind,
        )

    @_grpc_errors
    def PersistScan(self, request: PersistScanRequest, context: grpc.ServicerContext) -> PersistScanResponse:
        """Record a source scan's expected element count."""
        from garage_rag.db.engine import session_scope
        from garage_rag.db.models import Source
        from garage_rag.ingest.scanner import ScanResult

        with session_scope() as session:
            src = session.query(Source).filter_by(slug=request.source_slug).one_or_none()
            if src is None:
                raise LookupError(f"No such source: {request.source_slug}")
            kind, root = src.kind, Path(src.root)
        self._ingest_gateway().persist_scan(
            request.source_slug,
            ScanResult(
                source_slug=request.source_slug,
                kind=kind,
                root=root,
                item_count=request.item_count,
                item_type=request.item_type,
                duration_seconds=request.duration_seconds,
                details=json.loads(request.details_json) if request.details_json else {},
                error=request.error or None,
            ),
        )
        return PersistScanResponse(success=True)

    @_grpc_errors
    def CheckDocumentStat(
        self, request: CheckDocumentStatRequest, context: grpc.ServicerContext
    ) -> CheckDocumentStatResponse:
        """Existing stat and hashes of a document, for change detection."""
        stat = self._ingest_gateway().check_stat(request.source_slug, request.uri)
        return CheckDocumentStatResponse(
            exists=stat.exists,
            byte_size=stat.byte_size,
            mtime=stat.mtime,
            content_sha256=stat.content_sha256,
            chunker=stat.chunker,
            state=stat.state,
            source_sha256=stat.source_sha256,
        )

    @_grpc_errors
    def PersistDocument(
        self, request: PersistDocumentRequest, context: grpc.ServicerContext
    ) -> PersistDocumentResponse:
        """Apply one ingest outcome to a document; ``action`` picks the gateway method."""
        from garage_rag.ingest.gateway import AuthorPayload, ChunkPayload

        gw = self._ingest_gateway()
        run_id, slug, uri = request.run_id, request.source_slug, request.uri
        chunks_written = 0
        match request.action:
            case "placeholder":
                gw.record_placeholder(run_id, slug, uri, request.mtime, request.title, request.error)
            case "extract_failed":
                gw.record_extract_failed(
                    run_id,
                    slug,
                    uri,
                    request.error or "extraction failed",
                    byte_size=request.byte_size,
                    mtime=request.mtime,
                    source_sha256=request.source_sha256,
                )
            case "no_text":
                gw.record_no_text(
                    run_id,
                    slug,
                    uri,
                    byte_size=request.byte_size,
                    mtime=request.mtime,
                    source_sha256=request.source_sha256,
                )
            case "rejected":
                gw.record_rejected(run_id, slug, uri)
            case "seen":
                gw.record_seen(run_id, slug, uri)
            case "refresh_metadata":
                gw.refresh_metadata(
                    run_id,
                    slug,
                    uri,
                    byte_size=request.byte_size,
                    mtime=request.mtime,
                    source_sha256=request.source_sha256,
                    corpus_class=request.corpus_class,
                    trust_tier=request.trust_tier,
                )
            case "replace":
                chunks_written = gw.replace_document(
                    run_id,
                    slug,
                    uri,
                    title=request.title or None,
                    lang=request.lang or None,
                    byte_size=request.byte_size,
                    mtime=request.mtime,
                    source_sha256=request.source_sha256 or None,
                    content_sha256=request.content_sha256,
                    extractor=request.extractor,
                    extractor_version=request.extractor_version or "1",
                    chunker=request.chunker or None,
                    content=request.content or None,
                    meta=json.loads(request.meta_json) if request.meta_json else {},
                    corpus_class=request.corpus_class,
                    trust_tier=request.trust_tier,
                    authors=[
                        AuthorPayload(
                            name=a.name,
                            role=a.role or "author",
                            confidence=a.confidence or 1.0,
                            evidence=a.evidence or None,
                            identities=dict(a.identities),
                            is_self=a.is_self,
                        )
                        for a in request.authors
                    ],
                    chunks=[
                        ChunkPayload(
                            ord=c.ord,
                            text=c.text,
                            token_count=c.token_count or None,
                            char_start=c.char_start if c.HasField("char_start") else None,
                            char_end=c.char_end if c.HasField("char_end") else None,
                            heading_path=c.heading_path or None,
                            chunk_sha256=c.chunk_sha256,
                            chunker=c.chunker or None,
                            direction=c.direction or None,
                            sender=c.sender or None,
                        )
                        for c in request.chunks
                    ],
                )
            case other:
                raise ValueError(f"unknown PersistDocument action {other!r}")
        return PersistDocumentResponse(success=True, chunks_written=chunks_written)

    @_grpc_errors
    def FinalizeIngestSession(
        self, request: FinalizeIngestSessionRequest, context: grpc.ServicerContext
    ) -> FinalizeIngestSessionResponse:
        """Close the ingest run with its final counts."""
        self._ingest_gateway().finalize_session(
            request.run_id,
            completed=request.completed,
            seen=request.seen_count,
            indexed=request.indexed_count,
            skipped=request.skipped_count,
            failed=request.failed_count,
            placeholders=request.placeholder_count,
            materialized=request.materialized_count,
            materialized_bytes=request.materialized_bytes,
            errors=list(request.errors),
        )
        return FinalizeIngestSessionResponse(success=True)

    # -----------------------------------------------------------------------
    # Database facade for the embed worker
    # -----------------------------------------------------------------------

    @_grpc_errors
    def GetEmbeddingBatches(
        self, request: GetEmbeddingBatchesRequest, context: grpc.ServicerContext
    ) -> GetEmbeddingBatchesResponse:
        """Fetch pending unembedded text chunks for a target embedding model."""
        from sqlalchemy import text

        from garage_rag.db.emb_tables import get_model
        from garage_rag.db.engine import session_scope
        from garage_rag.embed.factory import provider_is_local
        from garage_rag.embed.ollama import (
            PENDING_SELECT,
            assert_safe_table,
            count_pending,
            model_modality,
            pending_chunks_sql,
        )

        with session_scope() as session:
            # get_model raises LookupError (NOT_FOUND) for an unknown slug only; a DB
            # outage propagates as an error rather than an empty "nothing to embed".
            model = get_model(session, request.model_slug or None)
            table = assert_safe_table(model.table_name)
            # The worker posts these texts to the model's provider: an off-box one
            # never gets communication chunks (see embed.ollama.backfill_model).
            local = provider_is_local(model.provider or "")
            modality = model_modality(model)
            pending_total = count_pending(session, model, include_communications=local)

            fetch_limit = request.batch_size if request.batch_size > 0 else 64
            if request.limit > 0 and request.limit < fetch_limit:
                fetch_limit = request.limit

            # For an image model each item's text is the image file's path.
            sql = text(
                pending_chunks_sql(
                    table, select=PENDING_SELECT[modality], include_communications=local, modality=modality
                )
                + " ORDER BY c.id LIMIT :limit"
            )
            rows = session.execute(sql, {"limit": fetch_limit}).all()
            chunk_items = [EmbeddingChunkItem(chunk_id=int(r[0]), text=r[1]) for r in rows]
            has_more = (pending_total - len(chunk_items)) > 0
            return GetEmbeddingBatchesResponse(
                model_slug=model.slug,
                table_name=model.table_name,
                provider=model.provider or "",
                model_ref=model.model_ref or "",
                dims=model.dims or 0,
                stored_dims=model.stored_dims or 0,
                storage_kind=model.storage_kind or "",
                index_kind=model.index_kind or "",
                total_pending=pending_total,
                chunks=chunk_items,
                has_more=has_more,
                modality=modality,
            )

    @_grpc_errors
    def UpdateEmbeddings(
        self, request: UpdateEmbeddingsRequest, context: grpc.ServicerContext
    ) -> UpdateEmbeddingsResponse:
        """Upsert computed embedding vectors for the given model table."""
        from sqlalchemy import text

        from garage_rag.db.emb_tables import get_model
        from garage_rag.db.engine import session_scope
        from garage_rag.embed.ollama import _adapt, _plan_from_row, assert_safe_table

        with session_scope() as session:
            model = get_model(session, request.model_slug or None)
            if not request.embeddings:
                return UpdateEmbeddingsResponse(success=True, count=0)

            table = assert_safe_table(model.table_name)
            plan = _plan_from_row(model)

            insert_sql = text(
                f"INSERT INTO {table} (chunk_id, embedding) VALUES (:chunk_id, :embedding) "
                "ON CONFLICT (chunk_id) DO UPDATE SET embedding = EXCLUDED.embedding"
            )

            params = [
                {"chunk_id": item.chunk_id, "embedding": _adapt(list(item.vector), plan)} for item in request.embeddings
            ]
            session.execute(insert_sql, params)
            return UpdateEmbeddingsResponse(success=True, count=len(params))


# Largest request the server accepts.
MAX_REQUEST_BYTES = 256 * 1024 * 1024


def _deny_unauthenticated(request: Any, context: grpc.ServicerContext) -> Any:
    context.abort(grpc.StatusCode.UNAUTHENTICATED, f"missing or invalid {METADATA_KEY}")


class TokenAuthInterceptor(grpc.ServerInterceptor):
    """Rejects every call whose ``x-garage-token`` metadata is not the per-launch token.

    Installed by :func:`create_grpc_server` when ``GARAGE_GRPC_TOKEN`` is set; see
    :mod:`garage_rag.service.auth`.
    """

    def __init__(self, token: str) -> None:
        self._token = token

    def _authorized(self, metadata: Any) -> bool:
        for key, value in metadata or ():
            if key == METADATA_KEY:
                return token_matches(value, self._token)
        return False

    def intercept_service(self, continuation: Any, handler_call_details: grpc.HandlerCallDetails) -> Any:
        method = (handler_call_details.method or "").rsplit("/", 1)[-1]
        handler = continuation(handler_call_details)
        if handler is None or method in UNAUTHENTICATED_METHODS:
            return handler
        if self._authorized(handler_call_details.invocation_metadata):
            return handler
        # Answer with the same cardinality as the real method, so the client sees
        # UNAUTHENTICATED rather than a protocol error.
        if handler.request_streaming and handler.response_streaming:
            return grpc.stream_stream_rpc_method_handler(_deny_unauthenticated)
        if handler.request_streaming:
            return grpc.stream_unary_rpc_method_handler(_deny_unauthenticated)
        if handler.response_streaming:
            return grpc.unary_stream_rpc_method_handler(_deny_unauthenticated)
        return grpc.unary_unary_rpc_method_handler(_deny_unauthenticated)


def create_grpc_server(
    host: str = "127.0.0.1",
    port: int = 50051,
    max_workers: int = 10,
    stop_event: threading.Event | None = None,
    stop_grace: float = 2.0,
    socket_path: str | None = None,
) -> tuple[grpc.Server, GarageRpcServicer]:
    """Create and configure a gRPC server for Garage.

    With ``socket_path`` the server listens on that Unix-domain socket instead of
    ``host:port``. The app puts it in an owner-only folder of its App Group
    container, so only this account's Garage processes reach it; a loopback TCP
    port is open to every account on the Mac.

    When ``stop_event`` is given, setting it stops the server with ``stop_grace``
    seconds of grace; ``serve_grpc`` sets it from SIGINT/SIGTERM.

    When ``GARAGE_GRPC_TOKEN`` is set, every call must carry it as ``x-garage-token``
    metadata (the app sets a fresh one each launch). Unset, the server takes any call
    except the config-changing ones (``auth.CONFIG_CHANGING_METHODS``), which it then
    answers only over the Unix socket, where the folder's mode is the peer check.
    """
    token = token_from_env()
    server = grpc.server(
        futures.ThreadPoolExecutor(max_workers=max_workers),
        interceptors=[TokenAuthInterceptor(token)] if token else None,
        # PersistDocument carries a document's whole text and every chunk; a
        # years-long Messages thread outgrows gRPC's 4 MiB default.
        options=[("grpc.max_receive_message_length", MAX_REQUEST_BYTES)],
    )
    servicer = GarageRpcServicer(
        stop_event=stop_event,
        callers_vouched_for=config_change_allowed(token_configured=token is not None, unix_socket=bool(socket_path)),
    )
    add_GarageServiceServicer_to_server(servicer, server)

    if socket_path:
        _bind_unix_socket(server, socket_path)
    else:
        server.add_insecure_port(f"{host}:{port}")

    if stop_event is not None:
        # The CLI loop polls the event, the Swift host calls server.stop() itself;
        # watching the event here makes it effective for both.
        def _stop_on_event() -> None:
            stop_event.wait()
            server.stop(grace=stop_grace)

        threading.Thread(target=_stop_on_event, name="garage-grpc-stop-watcher", daemon=True).start()
    return server, servicer


def _bind_unix_socket(server: grpc.Server, socket_path: str) -> None:
    """Binds ``server`` to ``socket_path``, owner-only.

    A socket file left by a server that died is removed first (gRPC will not
    bind over it). A socket something still answers on is another server's (a
    second Garage, or an older build still running): unlinking it would take the
    path from under that server's clients, so the bind fails instead. Anything
    else at the path is left alone and the bind fails too.

    The probe, the unlink and the bind run under an exclusive lock on the file
    beside the socket (``<socket_path>.lock``), so two servers recovering the
    same stale socket at once take turns: the second sees the first's live
    socket and fails, instead of unlinking it after both probes found the old
    one dead.
    """
    path = Path(socket_path)
    if not path.is_absolute():
        raise ValueError(f"gRPC socket path must be absolute: {socket_path!r}")
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with _socket_recovery_lock(path):
        try:
            if stat.S_ISSOCK(path.lstat().st_mode):
                if _unix_socket_is_stale(socket_path):
                    path.unlink()
                else:
                    raise RuntimeError(
                        f"another server is listening on the gRPC socket {socket_path}; not binding over it"
                    )
        except FileNotFoundError:
            pass
        if not server.add_insecure_port(f"unix:{socket_path}"):
            raise RuntimeError(f"could not bind the gRPC socket {socket_path}")
        path.chmod(0o600)


@contextlib.contextmanager
def _socket_recovery_lock(socket_path: Path) -> Iterator[None]:
    """Holds ``<socket_path>.lock`` exclusively across probe, unlink and bind.

    The lock file is left in place: it lives in the owner-only socket folder and
    any process on the path takes the same one, so removing it would let a
    third server lock a fresh inode while another still holds the old one.
    """
    import fcntl  # advisory file lock, not a network client

    lock_path = socket_path.with_name(socket_path.name + ".lock")
    fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)


def _unix_socket_is_stale(socket_path: str) -> bool:
    """True when nothing accepts connections on the socket file: a connect is refused."""
    import socket  # a probe of this server's own listening path, not egress (test_egress_block lists it)

    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as probe:
        probe.settimeout(1.0)
        try:
            probe.connect(socket_path)
        except ConnectionRefusedError:
            return True
        except FileNotFoundError:
            return True
        except OSError:
            return False  # in use, or not ours to judge: leave it alone and let the bind fail
    return False


def serve_grpc(
    host: str = "127.0.0.1",
    port: int = 50051,
    stop_event: threading.Event | None = None,
    socket_path: str | None = None,
) -> None:
    """Start the gRPC server and block until stopped."""
    stop_evt = stop_event or threading.Event()
    server, servicer = create_grpc_server(host=host, port=port, stop_event=stop_evt, socket_path=socket_path)
    server.start()
    where = f"unix:{socket_path}" if socket_path else f"{host}:{port}"
    print(f"Garage gRPC server listening on {where} (PID: {os.getpid()})")

    def handle_signal(sig, frame):
        print("\nShutting down gRPC server...")
        stop_evt.set()

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    try:
        while not stop_evt.is_set():
            time.sleep(0.5)
    finally:
        server.stop(grace=2.0)
        print("Garage gRPC server stopped.")

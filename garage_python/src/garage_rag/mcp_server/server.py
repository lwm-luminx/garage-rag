"""MCP server exposing the corpus to Claude.

Two details of the MCP 2.0 Python SDK shape this module:

* The entry point is ``MCPServer``. ``FastMCP`` was removed in 2.0 -- the old
  import path does not exist, it is not merely deprecated.
* Return **annotations** are the output schema. Dataclasses, Pydantic models, and
  TypedDicts map field-for-field, whereas bare scalars, lists, and unions get
  wrapped in ``{"result": ...}``. Every tool here therefore returns a dataclass,
  so clients see named fields rather than an opaque wrapper.

stdout is the protocol wire. Logging goes to stderr, and nothing here may
``print``.
"""

from __future__ import annotations

import logging
import sys
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Annotated, Literal, cast

from mcp.server import MCPServer
from pydantic import BeforeValidator, Field
from sqlalchemy import func

from garage_rag.config import get_settings
from garage_rag.db.emb_tables import count_vectors, list_models
from garage_rag.db.engine import session_scope
from garage_rag.db.migrate import redact_url
from garage_rag.db.models import (
    Author,
    AuthorIdentity,
    Chunk,
    CorpusClass,
    Document,
    DocumentAuthor,
    IngestState,
    Source,
)
from garage_rag.enrich.generation import LocalChatModel
from garage_rag.mcp_server import agent as _agent
from garage_rag.mcp_server.agent import AgentResult
from garage_rag.net import egress
from garage_rag.search.hybrid import SearchHit, corpus_overview
from garage_rag.search.hybrid import search as run_search

# stderr only: anything on stdout corrupts the JSON-RPC stream.
logging.basicConfig(
    level=logging.INFO,
    stream=sys.stderr,
    format="%(levelname)s %(name)s: %(message)s",
)
log = logging.getLogger("garage_rag.mcp")

mcp = MCPServer("garage-rag")

# Home is collapsed to ~ in returned paths: absolute paths leak the account name
# into transcripts and are no more useful to the caller.
_HOME = str(Path.home())


def _tidy(uri: str) -> str:
    return uri.replace(_HOME, "~") if uri.startswith(_HOME) else uri


def _untidy(location: str) -> str:
    """Inverse of :func:`_tidy`: expand only a leading ``~``."""
    if location == "~" or location.startswith("~/"):
        return _HOME + location[1:]
    return location


def _as_list(value: object) -> object:
    """Accept a single value where a list is expected.

    ``{"trust": "reference"}`` is how a person -- and a language model -- writes a
    single filter, but a bare ``list[...]`` annotation rejects it with
    "Input should be a valid list". Coercing here, and advertising both shapes in
    the schema below, makes the obvious spelling work instead of failing the whole
    call over a pair of brackets.
    """
    if isinstance(value, str):
        return [value]
    return value


# Filter parameters accept either one value or several. The union is what puts
# both shapes in the published input schema; the validator normalizes them.
ClassFilter = Annotated[
    list[Literal["document", "code", "communication"]] | Literal["document", "code", "communication"] | None,
    BeforeValidator(_as_list),
]
TrustFilter = Annotated[
    list[Literal["authored", "reference", "received"]] | Literal["authored", "reference", "received"] | None,
    BeforeValidator(_as_list),
]
SourceFilter = Annotated[list[str] | str | None, BeforeValidator(_as_list)]


# ---------------------------------------------------------------------------
# result types
# ---------------------------------------------------------------------------
@dataclass
class Hit:
    """One retrieved chunk."""

    chunk_id: int
    document_id: int
    location: str
    title: str | None
    corpus_class: str
    trust_tier: str
    section: str | None
    authors: list[str]
    matched_by: str
    score: float
    text: str


@dataclass
class SearchResult:
    query: str
    mode: str
    model: str
    count: int
    hits: list[Hit] = field(default_factory=list)


@dataclass
class DocumentResult:
    document_id: int
    location: str
    title: str | None
    corpus_class: str
    trust_tier: str
    authors: list[str]
    extractor: str
    byte_size: int | None
    chunk_count: int
    truncated: bool
    content: str


@dataclass
class SourceInfo:
    slug: str
    kind: str
    corpus_class: str
    trust_tier: str
    root: str
    documents: int
    chunks: int


@dataclass
class SourceList:
    count: int
    sources: list[SourceInfo] = field(default_factory=list)


@dataclass
class AuthorInfo:
    name: str
    is_self: bool
    documents: int
    identities: list[str]


@dataclass
class AuthorList:
    count: int
    authors: list[AuthorInfo] = field(default_factory=list)


@dataclass
class ModelInfo:
    slug: str
    dims: int
    stored_dims: int
    storage: str
    index: str
    is_default: bool
    vectors: int
    pending: int


@dataclass
class CorpusStats:
    documents: int
    chunks: int
    authors: int
    placeholders_pending: int
    by_class_and_trust: list[dict]
    models: list[ModelInfo] = field(default_factory=list)


@dataclass
class Citation:
    """One excerpt the answer may cite as ``[n]``."""

    n: int
    document_id: int
    title: str | None
    location: str
    snippet: str
    score: float


@dataclass
class AskResult:
    answer: str
    model: str
    provider: str
    question: str
    citations: list[Citation] = field(default_factory=list)
    prompt_tokens: int | None = None
    completion_tokens: int | None = None


@dataclass
class GenerateResult:
    text: str
    model: str
    provider: str


# ---------------------------------------------------------------------------
# retrieval shared by rag_search and rag_ask
# ---------------------------------------------------------------------------
def _retrieve(
    query: str,
    *,
    limit: int,
    mode: str,
    corpus_class: object = None,
    trust: object = None,
    source: object = None,
    author: str | None = None,
) -> tuple[list[SearchHit], str]:
    """Run the hybrid search; returns the hits and the embedding model's slug."""
    # The BeforeValidator only runs when the call comes through the MCP layer; a
    # direct Python call still needs a bare string turned into a one-item list,
    # or list("document") would filter on the letters d, o, c, ...
    # `_as_list` is typed object -> object because pydantic hands it whatever the
    # caller sent; what comes back out is always a list or None.
    classes = cast("list[str] | None", _as_list(corpus_class))
    tiers = cast("list[str] | None", _as_list(trust))
    slugs = cast("list[str] | None", _as_list(source))
    with session_scope() as session:
        hits = run_search(
            session,
            query,
            limit=limit,
            mode=mode,
            corpus_classes=list(classes) if classes else None,
            trust_tiers=list(tiers) if tiers else None,
            sources=list(slugs) if slugs else None,
            author=author,
        )
        models = list_models(session)
        default = next((m.slug for m in models if m.is_default), "none")
    return hits, default if mode != "fts" else "n/a"


# ---------------------------------------------------------------------------
# tools
# ---------------------------------------------------------------------------
@mcp.tool()
def rag_search(
    query: Annotated[str, Field(description="Natural-language question or keywords to search for.")],
    limit: Annotated[int, Field(ge=1, le=50, description="Maximum hits to return.")] = 10,
    mode: Annotated[
        Literal["hybrid", "vector", "fts"],
        Field(
            description=(
                "hybrid fuses semantic and keyword search (best default); "
                "vector is semantic only; fts is exact-keyword only and needs no "
                "embedding model."
            )
        ),
    ] = "hybrid",
    corpus_class: Annotated[
        ClassFilter,
        Field(
            description=(
                "Restrict by what the resource is. 'document' is prose, 'code' is "
                "source and config, 'communication' is messages and mail. "
                "Accepts one value or a list."
            )
        ),
    ] = None,
    trust: Annotated[
        TrustFilter,
        Field(
            description=(
                "Restrict by provenance. 'authored' is what the corpus owner "
                "wrote, 'reference' is external QA'ed material, 'received' is "
                "what others sent them. Use 'authored' for questions about the "
                "owner's own conclusions. Accepts one value or a list."
            )
        ),
    ] = None,
    source: Annotated[
        SourceFilter,
        Field(description="Restrict to these source slugs. Accepts one value or a list."),
    ] = None,
    author: Annotated[str | None, Field(description="Restrict to documents by this author (substring match).")] = None,
) -> SearchResult:
    """Search the personal corpus with hybrid semantic + keyword retrieval.

    Filter by trust to separate the owner's own writing from reference material,
    and by corpus_class to keep source code out of prose answers.
    """
    hits, embedding_model = _retrieve(
        query, limit=limit, mode=mode, corpus_class=corpus_class, trust=trust, source=source, author=author
    )

    return SearchResult(
        query=query,
        mode=mode,
        model=embedding_model,
        count=len(hits),
        hits=[
            Hit(
                chunk_id=h.chunk_id,
                document_id=h.document_id,
                location=_tidy(h.uri),
                title=h.title,
                corpus_class=h.corpus_class,
                trust_tier=h.trust_tier,
                section=h.heading_path,
                authors=h.authors,
                matched_by=h.matched_by,
                score=round(h.score, 6),
                text=h.text,
            )
            for h in hits
        ],
    )


@mcp.tool()
def rag_get_document(
    document_id: Annotated[int | None, Field(description="Document id, as returned by rag_search.")] = None,
    location: Annotated[
        str | None,
        Field(description="Path of the document; '~' is accepted. Used when no id is given."),
    ] = None,
    max_chars: Annotated[int, Field(ge=500, le=200_000, description="Truncate content beyond this length.")] = 20_000,
) -> DocumentResult:
    """Fetch a document's full extracted text, to read past a search snippet."""
    if document_id is None and not location:
        raise ValueError("pass either document_id or location")

    with session_scope() as session:
        if document_id is not None:
            doc = session.query(Document).filter(Document.id == document_id).one_or_none()
        else:
            expanded = _untidy(location or "")
            doc = session.query(Document).filter(Document.uri == expanded).one_or_none()

        if doc is None:
            raise ValueError(f"no such document: {document_id or location}")

        authors = [
            r[0]
            for r in (
                session.query(Author.display_name)
                .join(DocumentAuthor, DocumentAuthor.author_id == Author.id)
                .filter(DocumentAuthor.document_id == doc.id)
                .order_by(DocumentAuthor.confidence.desc())
                .all()
            )
        ]
        chunk_count = session.query(func.count(Chunk.id)).filter(Chunk.document_id == doc.id).scalar() or 0

    content = doc.content or ""
    truncated = len(content) > max_chars
    return DocumentResult(
        document_id=doc.id,
        location=_tidy(doc.uri),
        title=doc.title,
        corpus_class=str(doc.corpus_class),
        trust_tier=str(doc.trust_tier),
        authors=authors,
        extractor=doc.extractor,
        byte_size=doc.byte_size,
        chunk_count=chunk_count,
        truncated=truncated,
        content=content[:max_chars],
    )


@mcp.tool()
def rag_list_sources() -> SourceList:
    """List indexed sources with their document and chunk counts."""
    with session_scope() as session:
        rows = (
            session.query(
                Source.slug,
                Source.kind,
                Source.default_class.label("cls"),
                Source.default_trust.label("trust"),
                Source.root,
                func.count(func.distinct(Document.id)).label("documents"),
                func.count(Chunk.id).label("chunks"),
            )
            .outerjoin(
                Document,
                (Document.source_id == Source.id) & (Document.state == IngestState.OK),
            )
            .outerjoin(Chunk, Chunk.document_id == Document.id)
            .group_by(
                Source.id,
                Source.slug,
                Source.kind,
                Source.default_class,
                Source.default_trust,
                Source.root,
            )
            .order_by(func.count(func.distinct(Document.id)).desc())
            .all()
        )

    sources = [
        SourceInfo(
            slug=r.slug,
            kind=r.kind,
            corpus_class=str(r.cls),
            trust_tier=str(r.trust),
            root=_tidy(r.root),
            documents=int(r.documents),
            chunks=int(r.chunks),
        )
        for r in rows
    ]
    return SourceList(count=len(sources), sources=sources)


@mcp.tool()
def rag_list_authors(
    limit: Annotated[int, Field(ge=1, le=200)] = 30,
) -> AuthorList:
    """List authors in the corpus, most-documented first."""
    with session_scope() as session:
        identity_expr = AuthorIdentity.kind + ":" + AuthorIdentity.value
        rows = (
            session.query(
                Author.display_name,
                Author.is_self,
                func.count(func.distinct(DocumentAuthor.document_id)).label("documents"),
                func.array_agg(func.distinct(identity_expr)).filter(AuthorIdentity.id.is_not(None)).label("identities"),
            )
            .outerjoin(DocumentAuthor, DocumentAuthor.author_id == Author.id)
            .outerjoin(AuthorIdentity, AuthorIdentity.author_id == Author.id)
            .group_by(Author.id, Author.display_name, Author.is_self)
            .order_by(
                func.count(func.distinct(DocumentAuthor.document_id)).desc(),
                Author.display_name,
            )
            .limit(limit)
            .all()
        )

    authors = [
        AuthorInfo(
            name=r.display_name,
            is_self=bool(r.is_self),
            documents=int(r.documents),
            identities=list(r.identities or []),
        )
        for r in rows
    ]
    return AuthorList(count=len(authors), authors=authors)


@mcp.tool()
def rag_stats() -> CorpusStats:
    """Summarize corpus size, composition, and embedding coverage.

    Useful before searching: it shows which classes and trust tiers actually hold
    content, and whether embeddings are complete enough for semantic search.
    """
    with session_scope() as session:
        documents = int(session.query(func.count(Document.id)).filter(Document.state == IngestState.OK).scalar() or 0)
        chunks = int(session.query(func.count(Chunk.id)).scalar() or 0)
        authors = int(session.query(func.count(Author.id)).scalar() or 0)
        pending = int(
            session.query(func.count(Document.id)).filter(Document.state == IngestState.PLACEHOLDER).scalar() or 0
        )
        overview = corpus_overview(session)

        models: list[ModelInfo] = []
        for m in list_models(session):
            have = count_vectors(session, m)
            models.append(
                ModelInfo(
                    slug=m.slug,
                    dims=m.dims,
                    stored_dims=m.stored_dims,
                    storage=m.storage_kind,
                    index=m.index_kind,
                    is_default=bool(m.is_default),
                    vectors=have,
                    pending=max(0, chunks - have),
                )
            )

    return CorpusStats(
        documents=documents,
        chunks=chunks,
        authors=authors,
        placeholders_pending=pending,
        by_class_and_trust=overview,
        models=models,
    )


# ---------------------------------------------------------------------------
# local generation: rag_ask / rag_generate
# ---------------------------------------------------------------------------
# Both tools run on the local model named by facts.provider / facts.model (the
# app's LlamaXPCService, or a local Ollama server). Retrieved chunks are
# placed in the prompt verbatim; that is local inference, so communications
# may appear there just as they are embedded locally. rag_ask runs every
# excerpt's class through the egress guard first, so a communication never goes
# to an Ollama host that is not loopback.

ASK_SYSTEM_PROMPT = (
    "You answer questions about the user's personal corpus using only the numbered "
    "excerpts provided. Cite the excerpts you rely on inline as [n]. If the excerpts "
    "do not contain the answer, say so plainly instead of guessing."
)
# Each excerpt is trimmed to this many characters before it goes in the prompt.
EXCERPT_CHARS = 1200
# Citations carry a shorter snippet so the result stays readable.
SNIPPET_CHARS = 240


def _trim(text: str, limit: int) -> str:
    text = " ".join(text.split())
    return text if len(text) <= limit else text[: limit - 1].rstrip() + "\u2026"


def build_ask_messages(question: str, hits: list[SearchHit], *, excerpt_chars: int = EXCERPT_CHARS) -> list[dict]:
    """The chat messages ``rag_ask`` sends: system instruction, numbered excerpts, question."""
    if not hits:
        excerpts = "(no excerpts were retrieved)"
    else:
        blocks = []
        for n, hit in enumerate(hits, start=1):
            header = f"[{n}] {hit.title or '(untitled)'} \u2014 {_tidy(hit.uri)}"
            if hit.heading_path:
                header += f" \u00a7 {hit.heading_path}"
            blocks.append(f"{header}\n{_trim(hit.text, excerpt_chars)}")
        excerpts = "\n\n".join(blocks)
    user = f"Excerpts:\n\n{excerpts}\n\nQuestion: {question}"
    return [
        {"role": "system", "content": ASK_SYSTEM_PROMPT},
        {"role": "user", "content": user},
    ]


def _citations(hits: list[SearchHit]) -> list[Citation]:
    return [
        Citation(
            n=n,
            document_id=hit.document_id,
            title=hit.title,
            location=_tidy(hit.uri),
            snippet=_trim(hit.text, SNIPPET_CHARS),
            score=round(hit.score, 6),
        )
        for n, hit in enumerate(hits, start=1)
    ]


@mcp.tool()
def rag_ask(
    question: Annotated[str, Field(description="Natural-language question to answer from the corpus.")],
    limit: Annotated[int, Field(ge=1, le=20, description="Excerpts to retrieve and offer the model.")] = 6,
    mode: Annotated[
        Literal["hybrid", "vector", "fts"],
        Field(description="Retrieval mode, as for rag_search."),
    ] = "hybrid",
    corpus_class: Annotated[
        ClassFilter,
        Field(description="Restrict by what the resource is; see rag_search. Accepts one value or a list."),
    ] = None,
    trust: Annotated[
        TrustFilter,
        Field(description="Restrict by provenance; see rag_search. Accepts one value or a list."),
    ] = None,
    source: Annotated[
        SourceFilter,
        Field(description="Restrict to these source slugs. Accepts one value or a list."),
    ] = None,
    max_tokens: Annotated[int, Field(ge=16, le=4096, description="Cap on the generated answer.")] = 512,
    temperature: Annotated[float, Field(ge=0.0, le=2.0, description="Sampling temperature.")] = 0.2,
) -> AskResult:
    """Answer a question from the corpus with the local model, citing excerpts as [n].

    Retrieval is exactly rag_search; the excerpts then go to the model named by
    facts.model on facts.provider (the app's LlamaXPCService or a local Ollama
    server), so Garage sends nothing off the machine; the answer comes back to
    the calling client like any other tool result. Use rag_search instead when you want
    to read the excerpts yourself.
    """
    hits, _ = _retrieve(question, limit=limit, mode=mode, corpus_class=corpus_class, trust=trust, source=source)
    model = LocalChatModel()
    # The content rule: a communication in the excerpts never goes to a model host off this machine.
    for hit in hits:
        egress.check_destination(model.host, purpose="rag_ask", corpus_class=CorpusClass(hit.corpus_class))
    reply = model.complete(build_ask_messages(question, hits), max_tokens=max_tokens, temperature=temperature)
    return AskResult(
        answer=reply.text,
        model=model.model_ref,
        provider=model.provider,
        question=question,
        citations=_citations(hits),
        prompt_tokens=reply.prompt_tokens,
        completion_tokens=reply.completion_tokens,
    )


@mcp.tool()
def rag_generate(
    prompt: Annotated[str, Field(description="Text to send to the local model as the user turn.")],
    system: Annotated[str | None, Field(description="Optional system instruction.")] = None,
    max_tokens: Annotated[int, Field(ge=1, le=4096, description="Cap on the generated text.")] = 256,
    temperature: Annotated[float, Field(ge=0.0, le=2.0, description="Sampling temperature.")] = 0.7,
) -> GenerateResult:
    """Run a raw prompt through the local model, with no retrieval.

    The same facts.model / facts.provider as rag_ask; useful to check the model
    is loaded and responding, or for demos that do not need the corpus.
    """
    model = LocalChatModel()
    messages: list[dict] = []
    if system:
        messages.append({"role": "system", "content": system})
    messages.append({"role": "user", "content": prompt})
    text = model.chat(messages, max_tokens=max_tokens, temperature=temperature)
    return GenerateResult(text=text, model=model.model_ref, provider=model.provider)


@mcp.tool()
def rag_agent(
    question: Annotated[str, Field(description="Natural-language question to answer from the corpus.")],
    max_steps: Annotated[
        int, Field(ge=1, le=12, description="Tool calls the model may make before it has to answer.")
    ] = _agent.DEFAULT_MAX_STEPS,
    max_tokens: Annotated[int, Field(ge=16, le=4096, description="Cap on each model reply.")] = 768,
    temperature: Annotated[float, Field(ge=0.0, le=2.0, description="Sampling temperature.")] = 0.2,
    search_first: Annotated[
        bool,
        Field(
            description=(
                "Search the corpus for the question before the model's first reply, so a small "
                "model starts from the user's documents instead of answering from its training."
            )
        ),
    ] = True,
) -> AgentResult:
    """Answer a question by letting the local model search and read the corpus itself.

    The model named by facts.model on facts.provider gets this server's read-only
    tools (rag_search, rag_get_document, rag_list_sources, rag_list_authors,
    rag_stats) to call, in a loop, until it answers; the result carries the
    answer, the steps it took and the documents it saw. By default the question is
    searched first and the model starts from those hits. Use rag_ask for one
    retrieval and a cited answer, rag_agent when the question needs more than one
    look. Runs on the local model, so nothing leaves the machine; an off-box
    Ollama or LM Studio host never receives a communication.
    """
    model = LocalChatModel()
    tools = _agent.tools_from_server(mcp)
    return _agent.run_agent(
        question,
        tools,
        model,
        max_steps=max_steps,
        max_tokens=max_tokens,
        temperature=temperature,
        search_first=search_first,
    )


# Names that ``ipaddress`` cannot classify; every 127.x.x.x literal is handled
# by the ``is_loopback`` check below.
LOOPBACK_HOSTS = frozenset({"localhost", "::1", "127.0.0.1"})


def is_loopback(host: str) -> bool:
    """Whether ``host`` can only be reached from this machine."""
    import ipaddress

    if host in LOOPBACK_HOSTS:
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        # A hostname we cannot classify; treat as remote and make the caller
        # opt in explicitly.
        return False


def _log_startup(*, query_database: bool = True) -> None:
    """Log the database the tools read and, if asked, how many sources it holds.

    Never fatal: the database may still be starting (the bundled ``garage-mcp``
    opens Garage.app without waiting for it), and each tool reports its own
    connection error when called.
    """
    settings = get_settings()
    log.info("database connection: %s", redact_url(settings.database_url))
    if not query_database:
        return
    try:
        with session_scope() as session:
            count = session.query(Source).count()
    except Exception as exc:
        log.warning("could not query the database during start-up: %s", exc)
        return
    log.info("%d sources registered", count)


def _host_header(host: str, port: int) -> str:
    """The ``Host`` header value a client uses to reach ``host:port``."""
    authority = f"[{host}]" if ":" in host else host
    return f"{authority}:{port}"


def _http_security(
    bind_host: str,
    bind_port: int,
    allowed_origins: list[str] | None,
    allowed_hosts: list[str] | None = None,
):
    """DNS-rebinding protection shared by every HTTP transport.

    The SDK matches the ``Host`` header exactly (or against a ``name:*``
    pattern), so the allowlist must hold the names clients actually use. On a
    loopback bind those are known. On a remote bind (``0.0.0.0``, a LAN
    address) they are not: the caller either names them through
    ``allowed_hosts`` or, when none are given, the check is switched off with a
    warning -- refusing every request with "Invalid Host header" protects
    nothing and is what an operator who opted into remote access would hit.
    """
    from mcp.server.transport_security import TransportSecuritySettings

    hosts = {
        _host_header(bind_host, bind_port),
        f"localhost:{bind_port}",
        f"127.0.0.1:{bind_port}",
        *(allowed_hosts or []),
    }
    protect = is_loopback(bind_host) or bool(allowed_hosts)
    if not protect:
        log.warning(
            "bound to %s with no allowed hosts: the Host header is not checked, so "
            "DNS-rebinding protection is off; pass --allow-host to restore it",
            bind_host,
        )
    return TransportSecuritySettings(
        enable_dns_rebinding_protection=protect,
        allowed_hosts=sorted(hosts),
        allowed_origins=sorted(set(allowed_origins or [])),
    )


def _warn_if_not_loopback(bind_host: str) -> None:
    if not is_loopback(bind_host):
        # Not fatal here — the CLI already required an explicit opt-in — but it
        # belongs in the log so it is visible in whatever captured stderr.
        log.warning(
            "listening on %s, which is reachable from other machines; this "
            "server has no authentication and exposes the whole corpus",
            bind_host,
        )


def serve(
    transport: str = "stdio",
    *,
    host: str | None = None,
    port: int | None = None,
    path: str | None = None,
    allowed_origins: list[str] | None = None,
    allowed_hosts: list[str] | None = None,
    json_response: bool = False,
    stateless: bool = False,
) -> None:
    """Run the server on ``stdio``, ``streamable-http``, or ``sse``.

    HTTP transports get DNS-rebinding protection configured explicitly. Without
    it a page in your browser could reach a loopback-bound server via a
    rebound hostname, and this server answers questions about your private
    corpus — so the ``Host`` and ``Origin`` allowlists are the only thing
    standing between "local only" and "any website you visit". ``allowed_hosts``
    names the extra ``Host`` values a remote bind should accept.
    """
    settings = get_settings()
    log.info("garage-rag MCP server starting (transport=%s)", transport)
    # On stdio the client waits for `initialize`; a connection attempt to a
    # Postgres that is still starting must not sit in front of it.
    _log_startup(query_database=transport != "stdio")

    if transport == "stdio":
        # stdio is the default and the call blocks.
        mcp.run()
        return

    if transport not in ("streamable-http", "sse"):
        raise ValueError(f"unsupported transport: {transport!r}")

    bind_host = host or settings.mcp_host
    bind_port = port or settings.mcp_port
    http_path = path or settings.mcp_http_path
    security = _http_security(bind_host, bind_port, allowed_origins, allowed_hosts)
    _warn_if_not_loopback(bind_host)

    log.info("listening on http://%s:%d%s", bind_host, bind_port, http_path)

    if transport == "sse":
        mcp.run(
            "sse",
            host=bind_host,
            port=bind_port,
            sse_path=http_path,
            transport_security=security,
        )
        return

    mcp.run(
        "streamable-http",
        host=bind_host,
        port=bind_port,
        streamable_http_path=http_path,
        json_response=json_response,
        stateless_http=stateless,
        transport_security=security,
    )


def main(argv: list[str] | None = None) -> None:
    """Console-script entry point: stdio, which is what MCP clients spawn.

    ``garage-mcp [--config PATH]``. A client spawns it from an arbitrary working
    directory, so a registration passes the config file explicitly.
    """
    import argparse

    from garage_rag.config import ConfigError, load_config, set_settings

    parser = argparse.ArgumentParser(prog="garage-mcp", description="Serve the Garage corpus over MCP on stdio.")
    parser.add_argument("--config", "-c", type=Path, help="Config file. Default: ./garage.json, then ~/.garage.json.")
    options = parser.parse_args(argv)
    try:
        set_settings(load_config(options.config))
    except ConfigError as exc:
        # stdout is the protocol channel; errors go to stderr only.
        parser.exit(2, f"garage-mcp: config error: {exc}\n")
    serve("stdio")


# ---------------------------------------------------------------------------
# embedded (background thread) server, used by the macOS XPC helper
# ---------------------------------------------------------------------------
#
# ``mcp.run("streamable-http")`` builds its own ``uvicorn.Server`` and never
# hands it back, so a caller cannot stop it; the only way to shut it down is to
# end the process. The XPC helper needs start / stop / restart inside one
# long-lived process, therefore the background variant constructs the uvicorn
# server itself and keeps the handle so ``should_exit`` can be raised later.

_active_server = None  # uvicorn.Server | None
_active_server_thread: threading.Thread | None = None
_active_server_error: str | None = None
_server_lock = threading.Lock()

STARTUP_WAIT_SECONDS = 15.0
SHUTDOWN_WAIT_SECONDS = 10.0


def start_background_server(
    host: str = "127.0.0.1",
    port: int = 8787,
    path: str = "/mcp",
    allowed_origins: list[str] | None = None,
    json_response: bool = False,
    stateless: bool = False,
    allowed_hosts: list[str] | None = None,
) -> bool:
    """Start the MCP streamable-HTTP server in a daemon background thread.

    Blocks until the socket is bound (returns ``True``) or start-up failed
    (returns ``False``; see :func:`background_server_error`). A previously
    started server is shut down first so restarting on the same port works.
    """
    global _active_server, _active_server_thread, _active_server_error

    import uvicorn

    with _server_lock:
        if _active_server_thread is not None and _active_server_thread.is_alive():
            _stop_locked()

        _active_server_error = None
        log.info("garage-rag MCP server starting (transport=streamable-http, embedded)")
        _log_startup()

        security = _http_security(host, port, allowed_origins, allowed_hosts)
        _warn_if_not_loopback(host)

        app = mcp.streamable_http_app(
            streamable_http_path=path,
            json_response=json_response,
            stateless_http=stateless,
            transport_security=security,
            host=host,
        )
        config = uvicorn.Config(
            app,
            host=host,
            port=port,
            log_level=mcp.settings.log_level.lower(),
        )
        server = uvicorn.Server(config)

        def _run() -> None:
            global _active_server_error
            try:
                # ``Server.run`` skips signal handling when it is not on the main
                # thread, which is exactly what an embedded server wants.
                server.run()
            except SystemExit as exc:
                # uvicorn calls ``sys.exit(3)`` when the bind or lifespan fails.
                _active_server_error = f"MCP server failed to start (exit {exc.code})"
                log.error("%s", _active_server_error)
            except Exception as exc:
                _active_server_error = f"MCP background server error: {exc}"
                log.error("%s", _active_server_error)

        thread = threading.Thread(target=_run, daemon=True, name="garage-mcp-http-server")
        thread.start()

        deadline = time.monotonic() + STARTUP_WAIT_SECONDS
        while not server.started and thread.is_alive() and time.monotonic() < deadline:
            time.sleep(0.05)

        if not server.started:
            if thread.is_alive():
                # Still binding after the deadline: give up and tear it down.
                server.should_exit = True
                thread.join(timeout=2.0)
                _active_server_error = _active_server_error or (
                    f"MCP server did not start listening on {host}:{port} within {STARTUP_WAIT_SECONDS:.0f}s"
                )
            else:
                _active_server_error = _active_server_error or (
                    f"MCP server exited before binding {host}:{port} (see log)"
                )
            _active_server = None
            _active_server_thread = None
            return False

        _active_server = server
        _active_server_thread = thread
        log.info("listening on http://%s:%d%s", host, port, path)
        return True


def _stop_locked() -> bool:
    """Stop the running server; the caller holds ``_server_lock``."""
    global _active_server, _active_server_thread
    server = _active_server
    thread = _active_server_thread
    _active_server = None
    _active_server_thread = None
    if server is None or thread is None:
        return True

    server.should_exit = True
    thread.join(timeout=SHUTDOWN_WAIT_SECONDS)
    if thread.is_alive():
        # Drain did not finish in time: drop in-flight connections.
        server.force_exit = True
        thread.join(timeout=2.0)
    stopped = not thread.is_alive()
    if stopped:
        log.info("garage-rag MCP server stopped")
    else:
        log.warning("garage-rag MCP server thread did not exit after force_exit")
    return stopped


def stop_background_server() -> bool:
    """Stop the background MCP HTTP server and wait for its thread to exit."""
    with _server_lock:
        return _stop_locked()


def is_background_server_running() -> bool:
    """Whether the background server is bound and its thread is alive."""
    with _server_lock:
        server = _active_server
        thread = _active_server_thread
        return (
            server is not None
            and thread is not None
            and thread.is_alive()
            and bool(server.started)
            and not server.should_exit
        )


def background_server_error() -> str | None:
    """The reason the last :func:`start_background_server` failed, if any."""
    with _server_lock:
        return _active_server_error


# Required: `mcp dev`, `mcp run`, and the tests all *import* this module.
if __name__ == "__main__":
    main()

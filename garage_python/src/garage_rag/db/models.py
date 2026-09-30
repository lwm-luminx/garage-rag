"""SQLAlchemy models mirroring ``data/sql/*.sql``.

The SQL files remain the source of truth for DDL (they hold the CHECK
constraints and the generated tsvector column). These mappings exist for typed
reads and writes, not for schema creation.
"""

from __future__ import annotations

import enum
from datetime import datetime

from sqlalchemy import (
    BigInteger,
    Boolean,
    CheckConstraint,
    DateTime,
    Enum,
    Float,
    ForeignKey,
    Index,
    Integer,
    LargeBinary,
    SmallInteger,
    String,
    Text,
    UniqueConstraint,
    func,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship


class StorageKind(enum.StrEnum):
    VECTOR = "vector"
    HALFVEC = "halfvec"


class IndexKind(enum.StrEnum):
    HNSW = "hnsw"
    HNSW_BQ = "hnsw_bq"
    NONE = "none"


class Base(DeclarativeBase):
    pass


class CorpusClass(enum.StrEnum):
    """What a resource is. The primary partition of the corpus."""

    DOCUMENT = "document"
    CODE = "code"
    COMMUNICATION = "communication"


class TrustTier(enum.StrEnum):
    """How trusted a resource is, and whose it is. Orthogonal to CorpusClass."""

    AUTHORED = "authored"
    REFERENCE = "reference"
    RECEIVED = "received"


class AuthorRole(enum.StrEnum):
    AUTHOR = "author"
    COMMITTER = "committer"
    SENDER = "sender"
    RECIPIENT = "recipient"
    CC = "cc"


class IngestState(enum.StrEnum):
    OK = "ok"
    EXTRACT_FAILED = "extract_failed"
    EMBED_PARTIAL = "embed_partial"
    # Cloud stub with no local content. Absent, not broken.
    PLACEHOLDER = "placeholder"


# values_callable keeps Postgres seeing the lowercase enum labels rather than
# Python's uppercase member names.
_corpus_class = Enum(CorpusClass, name="corpus_class", values_callable=lambda e: [m.value for m in e])
_trust_tier = Enum(TrustTier, name="trust_tier", values_callable=lambda e: [m.value for m in e])
_author_role = Enum(AuthorRole, name="author_role", values_callable=lambda e: [m.value for m in e])
_ingest_state = Enum(IngestState, name="ingest_state", values_callable=lambda e: [m.value for m in e])


class Source(Base):
    __tablename__ = "sources"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    slug: Mapped[str] = mapped_column(Text, unique=True)
    kind: Mapped[str] = mapped_column(Text)
    root: Mapped[str] = mapped_column(Text)
    default_class: Mapped[CorpusClass] = mapped_column(_corpus_class, default=CorpusClass.DOCUMENT)
    default_trust: Mapped[TrustTier] = mapped_column(_trust_tier)
    enabled: Mapped[bool] = mapped_column(Boolean, default=True)
    expected_elements: Mapped[int] = mapped_column(BigInteger, default=0)
    # The last scan (008_source_scan.sql); config stays user-facing settings only.
    scan_item_type: Mapped[str | None] = mapped_column(Text, nullable=True)
    scan_details: Mapped[dict] = mapped_column(JSONB, default=dict)
    scanned_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    config: Mapped[dict] = mapped_column(JSONB, default=dict)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    __table_args__ = (
        CheckConstraint(
            "kind IN ('filesystem', 'git', 'sqlite', 'maildir', 'feed')",
            name="sources_kind_check",
        ),
    )


class Author(Base):
    __tablename__ = "authors"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    display_name: Mapped[str] = mapped_column(Text)
    is_self: Mapped[bool] = mapped_column(Boolean, default=False)
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    identities: Mapped[list[AuthorIdentity]] = relationship(back_populates="author", cascade="all, delete-orphan")


class AuthorIdentity(Base):
    __tablename__ = "author_identities"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    author_id: Mapped[int] = mapped_column(BigInteger, ForeignKey("authors.id", ondelete="CASCADE"))
    kind: Mapped[str] = mapped_column(Text)
    value: Mapped[str] = mapped_column(Text)

    author: Mapped[Author] = relationship(back_populates="identities")

    __table_args__ = (UniqueConstraint("kind", "value", name="author_identities_unique"),)


class Document(Base):
    __tablename__ = "documents"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    source_id: Mapped[int] = mapped_column(BigInteger, ForeignKey("sources.id", ondelete="CASCADE"))
    uri: Mapped[str] = mapped_column(Text)
    corpus_class: Mapped[CorpusClass] = mapped_column(_corpus_class)
    trust_tier: Mapped[TrustTier] = mapped_column(_trust_tier)
    title: Mapped[str | None] = mapped_column(Text, nullable=True)
    mime: Mapped[str | None] = mapped_column(Text, nullable=True)
    lang: Mapped[str | None] = mapped_column(Text, nullable=True)
    byte_size: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    mtime: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    # Raw bytes: enables skipping a document without extracting it.
    source_sha256: Mapped[bytes | None] = mapped_column(LargeBinary, nullable=True)
    # Extracted text: decides whether chunks must be rebuilt.
    content_sha256: Mapped[bytes] = mapped_column(LargeBinary)
    extractor: Mapped[str] = mapped_column(Text)
    extractor_version: Mapped[str] = mapped_column(Text, default="1")
    chunker: Mapped[str | None] = mapped_column(Text, nullable=True)
    content: Mapped[str | None] = mapped_column(Text, nullable=True)
    meta: Mapped[dict] = mapped_column(JSONB, default=dict)
    state: Mapped[IngestState] = mapped_column(_ingest_state, default=IngestState.OK)
    error: Mapped[str | None] = mapped_column(Text, nullable=True)
    ingested_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    chunks: Mapped[list[Chunk]] = relationship(back_populates="document", cascade="all, delete-orphan")
    authors: Mapped[list[DocumentAuthor]] = relationship(back_populates="document", cascade="all, delete-orphan")
    facts: Mapped[list[Fact]] = relationship(back_populates="document", cascade="all, delete-orphan")

    __table_args__ = (UniqueConstraint("source_id", "uri", name="documents_uri_unique"),)


class DocumentAuthor(Base):
    __tablename__ = "document_authors"

    document_id: Mapped[int] = mapped_column(
        BigInteger, ForeignKey("documents.id", ondelete="CASCADE"), primary_key=True
    )
    author_id: Mapped[int] = mapped_column(BigInteger, ForeignKey("authors.id", ondelete="CASCADE"), primary_key=True)
    role: Mapped[AuthorRole] = mapped_column(_author_role, primary_key=True)
    confidence: Mapped[float] = mapped_column(Float, default=1.0)
    # How this attribution was reached: 'git-log', 'pdf-metadata',
    # 'path-rule:Reference', 'imessage-handle'. Makes misattribution diagnosable.
    evidence: Mapped[str | None] = mapped_column(Text, nullable=True)

    document: Mapped[Document] = relationship(back_populates="authors")
    author: Mapped[Author] = relationship()


class Chunk(Base):
    __tablename__ = "chunks"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    document_id: Mapped[int] = mapped_column(BigInteger, ForeignKey("documents.id", ondelete="CASCADE"))
    ord: Mapped[int] = mapped_column(Integer)
    text: Mapped[str] = mapped_column(Text)
    token_count: Mapped[int | None] = mapped_column(Integer, nullable=True)
    char_start: Mapped[int | None] = mapped_column(Integer, nullable=True)
    char_end: Mapped[int | None] = mapped_column(Integer, nullable=True)
    heading_path: Mapped[str | None] = mapped_column(Text, nullable=True)
    chunk_sha256: Mapped[bytes] = mapped_column(LargeBinary)
    chunker: Mapped[str] = mapped_column(Text)
    # Set when this chunk is a fact's text rather than a slice of
    # documents.content, so the fact can be embedded like any other chunk.
    fact_id: Mapped[int | None] = mapped_column(BigInteger, ForeignKey("facts.id", ondelete="CASCADE"), nullable=True)
    # Message chunks only (014_chunk_direction.sql): 'sent' | 'received', and the
    # handle that wrote the message, or 'me'. NULL on every other chunk.
    direction: Mapped[str | None] = mapped_column(Text, nullable=True)
    sender: Mapped[str | None] = mapped_column(Text, nullable=True)
    # `tsv` is a generated column; it is read-only from the ORM's perspective and
    # is intentionally not mapped.

    document: Mapped[Document] = relationship(back_populates="chunks")
    fact: Mapped[Fact | None] = relationship(back_populates="chunk")

    __table_args__ = (
        UniqueConstraint("document_id", "ord", name="chunks_ord_unique"),
        CheckConstraint("direction IN ('sent', 'received')", name="chunks_direction_check"),
        Index("chunks_doc", "document_id"),
    )


class Fact(Base):
    __tablename__ = "facts"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    document_id: Mapped[int] = mapped_column(BigInteger, ForeignKey("documents.id", ondelete="CASCADE"))
    ord: Mapped[int] = mapped_column(Integer)
    fact: Mapped[str] = mapped_column(Text)
    fact_class: Mapped[str] = mapped_column(Text, default="fact")
    attributes: Mapped[dict] = mapped_column(JSONB, default=dict)
    char_start: Mapped[int | None] = mapped_column(Integer, nullable=True)
    char_end: Mapped[int | None] = mapped_column(Integer, nullable=True)
    extractor: Mapped[str] = mapped_column(Text, default="langextract")
    extractor_model: Mapped[str | None] = mapped_column(Text, nullable=True)
    # The facts.prompts entry that produced this fact, and the hash of its
    # description and examples (013_fact_prompts.sql); NULL before 013.
    prompt_name: Mapped[str] = mapped_column(Text, default="default")
    prompt_sha256: Mapped[bytes | None] = mapped_column(LargeBinary, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    # `tsv` is a generated column; read-only from the ORM's perspective and
    # intentionally not mapped.

    document: Mapped[Document] = relationship(back_populates="facts")
    # The chunk carrying this fact's embeddings, if it has been queued for
    # embedding. Deletion is DB-driven (chunks.fact_id ON DELETE CASCADE), not
    # ORM-driven, so the chunk row -- and its vectors in every per-model
    # embedding table -- disappear even on a bulk/raw-SQL fact delete.
    chunk: Mapped[Chunk | None] = relationship(back_populates="fact", uselist=False, passive_deletes=True)

    __table_args__ = (
        UniqueConstraint("document_id", "prompt_name", "ord", name="facts_prompt_ord_unique"),
        Index("facts_document", "document_id"),
    )


class FactRun(Base):
    """The last extraction of one prompt over one document (013_fact_prompts.sql).

    Kept even when the run found nothing, so ``enrich-facts --stale-only`` can
    tell an up-to-date document from one never extracted.
    """

    __tablename__ = "fact_runs"

    document_id: Mapped[int] = mapped_column(
        BigInteger, ForeignKey("documents.id", ondelete="CASCADE"), primary_key=True
    )
    prompt_name: Mapped[str] = mapped_column(Text, primary_key=True)
    prompt_sha256: Mapped[bytes] = mapped_column(LargeBinary)
    content_sha256: Mapped[bytes] = mapped_column(LargeBinary)
    extractor_model: Mapped[str] = mapped_column(Text)
    facts: Mapped[int] = mapped_column(Integer, default=0)
    extracted_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class Conversation(Base):
    __tablename__ = "conversations"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    source_id: Mapped[int] = mapped_column(BigInteger, ForeignKey("sources.id", ondelete="CASCADE"))
    other_author_id: Mapped[int] = mapped_column(BigInteger, ForeignKey("authors.id", ondelete="CASCADE"))
    external_id: Mapped[str] = mapped_column(Text)
    document_id: Mapped[int | None] = mapped_column(
        BigInteger, ForeignKey("documents.id", ondelete="SET NULL"), nullable=True
    )
    first_message_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    last_message_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    message_count: Mapped[int] = mapped_column(Integer, default=0)
    synthesized_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    messages: Mapped[list[Message]] = relationship(back_populates="conversation", cascade="all, delete-orphan")

    __table_args__ = (
        UniqueConstraint("source_id", "external_id", name="conversations_external_id_unique"),
        UniqueConstraint("document_id", name="conversations_document_unique"),
    )


class Message(Base):
    __tablename__ = "messages"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    conversation_id: Mapped[int] = mapped_column(BigInteger, ForeignKey("conversations.id", ondelete="CASCADE"))
    author_id: Mapped[int] = mapped_column(BigInteger, ForeignKey("authors.id", ondelete="CASCADE"))
    external_id: Mapped[str | None] = mapped_column(Text, nullable=True)
    sent_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    body: Mapped[str] = mapped_column(Text)
    meta: Mapped[dict] = mapped_column(JSONB, default=dict)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    conversation: Mapped[Conversation] = relationship(back_populates="messages")

    __table_args__ = (
        UniqueConstraint("conversation_id", "external_id", name="messages_external_id_unique"),
        Index("messages_conversation_sent", "conversation_id", "sent_at"),
    )


class EmbeddingModel(Base):
    __tablename__ = "embedding_models"

    id: Mapped[int] = mapped_column(SmallInteger, primary_key=True)
    slug: Mapped[str] = mapped_column(Text, unique=True)
    provider: Mapped[str] = mapped_column(Text, default="llama_xpc")
    model_ref: Mapped[str] = mapped_column(Text)
    model_id: Mapped[str | None] = mapped_column(Text, nullable=True)
    dims: Mapped[int] = mapped_column(Integer)
    stored_dims: Mapped[int] = mapped_column(Integer)
    storage_kind: Mapped[StorageKind] = mapped_column(String)
    index_kind: Mapped[IndexKind] = mapped_column(String)
    # cosine | l2 | inner_product (009_model_distance.sql): the index's operator
    # class and the search operator both follow it.
    distance: Mapped[str] = mapped_column(Text, default="cosine")
    # text | image (014_model_modality.sql): which chunks backfill gives the model,
    # and whether it embeds their text or the image file behind them.
    modality: Mapped[str] = mapped_column(Text, default="text")
    normalized: Mapped[bool] = mapped_column(Boolean, default=True)
    table_name: Mapped[str] = mapped_column(Text, unique=True)
    is_default: Mapped[bool] = mapped_column(Boolean, default=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class IngestRun(Base):
    __tablename__ = "ingest_runs"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    source_id: Mapped[int] = mapped_column(BigInteger, ForeignKey("sources.id", ondelete="CASCADE"))
    started_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    finished_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    # Reconciliation only trusts a run with completed=True; otherwise an
    # unmounted volume looks like a mass deletion.
    completed: Mapped[bool] = mapped_column(Boolean, default=False)
    seen_count: Mapped[int] = mapped_column(Integer, default=0)
    indexed_count: Mapped[int] = mapped_column(Integer, default=0)
    skipped_count: Mapped[int] = mapped_column(Integer, default=0)
    failed_count: Mapped[int] = mapped_column(Integer, default=0)
    placeholder_count: Mapped[int] = mapped_column(Integer, default=0)
    materialized_count: Mapped[int] = mapped_column(Integer, default=0)
    materialized_bytes: Mapped[int] = mapped_column(BigInteger, default=0)
    error: Mapped[str | None] = mapped_column(Text, nullable=True)


class IngestSeen(Base):
    __tablename__ = "ingest_seen"

    run_id: Mapped[int] = mapped_column(BigInteger, ForeignKey("ingest_runs.id", ondelete="CASCADE"), primary_key=True)
    uri: Mapped[str] = mapped_column(Text, primary_key=True)


class IngestOutcome(Base):
    """A file that produced no document: its stat, hash and extractor revision at the time.

    Lets the next run skip it while nothing changed, instead of OCRing a textless image or
    retrying a failed extraction every time. DDL in ``012_ingest_outcomes.sql``.
    """

    __tablename__ = "ingest_outcomes"

    source_id: Mapped[int] = mapped_column(BigInteger, ForeignKey("sources.id", ondelete="CASCADE"), primary_key=True)
    uri: Mapped[str] = mapped_column(Text, primary_key=True)
    outcome: Mapped[str] = mapped_column(Text)
    byte_size: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    mtime: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    source_sha256: Mapped[bytes | None] = mapped_column(LargeBinary, nullable=True)
    extractor_revision: Mapped[str] = mapped_column(Text, default="")
    error: Mapped[str | None] = mapped_column(Text, nullable=True)
    recorded_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

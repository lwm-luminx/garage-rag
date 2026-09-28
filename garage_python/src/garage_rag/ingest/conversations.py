"""Ingesting a Messages database: one document per conversation, one chunk per message.

A ``sqlite`` source is not walked file by file. Every Messages ``chat.db`` under
its root is read with :mod:`garage_rag.extract.messages`, and each conversation
is stored like any other document through the same
:class:`~garage_rag.ingest.gateway.IngestStorageGateway`, so the in-process
pipeline and the ingest XPC worker behave alike.

The document's text is a header naming the thread and its members, then the
whole thread, one message per paragraph::

    Climbing crew
    Participants: Alex Doe (+15551234567), friend@example.com
    Service: iMessage

    [2026-09-24 18:02 UTC] Me: running late

    [2026-09-24 18:03 UTC] Alex Doe: no worries

A handle shows as a name when ``contact_names`` knows one
(:mod:`garage_rag.extract.contact_names`), and the header keeps the handle beside
it so a search for the number still finds the thread. A thread with no named
members reads, and hashes, exactly as it did before names existed.

Each message is its own chunk, spanning exactly its paragraph, so a search hit
is one message with its sender and time rather than a window that starts
mid-thread. A message longer than the configured chunk size is split into
several chunks, never merged with its neighbours. The header is part of the
content hash, so a renamed group or a new member rebuilds the document. Times
are UTC so the text does not change with the machine's time zone.

Trust is per document, so it cannot say which of a thread's messages the owner
wrote. Each message chunk says so itself: ``chunks.direction`` is ``sent`` (the
owner wrote it) or ``received``, and ``chunks.sender`` is the handle that wrote
it, or ``me`` (``data/sql/014_chunk_direction.sql``). Search filters on it, so the
owner's side of a conversation can be found on its own.

Conversations are always ``communication``, which keeps them on this machine
(see ``docs/privacy.md``). The per-document chunk cap does not apply: it guards
against a runaway file, and cutting a thread short would silently drop its
newest messages. The machine-output gate does not apply either, since every
line of a thread starts with a timestamp by construction.
"""

from __future__ import annotations

import logging
import sqlite3
from collections.abc import Callable
from pathlib import Path

from garage_rag.attribute.resolver import SelfIdentity
from garage_rag.config import get_settings
from garage_rag.db.models import CorpusClass
from garage_rag.extract.base import ContentKind, sha256_text
from garage_rag.extract.contact_names import ContactNames
from garage_rag.extract.messages import (
    EXTRACTOR_NAME,
    EXTRACTOR_VERSION,
    ChatMessage,
    Conversation,
    OrphanStats,
    find_databases,
    messages_database_status,
    read_conversations,
)
from garage_rag.ingest.chunking import TextChunk, chunk_prose
from garage_rag.ingest.gateway import AuthorPayload, ChunkPayload, IngestStorageGateway, SourceContext

log = logging.getLogger(__name__)

CHUNKER = "message"
SELF_LABEL = "Me"


def signature(size: int) -> str:
    """The document's chunker signature; a new chunk size or extractor version rebuilds every thread.

    A rebuild keeps each chunk whose text is unchanged, and its vectors, so a new
    extractor version costs no re-embedding for messages that render the same.
    """
    return f"{ContentKind.CONVERSATION}:{CHUNKER}:{size}:v{EXTRACTOR_VERSION}"


def conversation_uri(db_path: Path, conversation: Conversation) -> str:
    """Stable per thread: the database's path plus the chat's GUID."""
    return f"{db_path}#{conversation.guid}"


def _sender_label(conversation: Conversation, message: ChatMessage) -> str:
    if message.is_from_me:
        return SELF_LABEL
    return conversation.label(message.sender) if message.sender else "Unknown"


def _member(conversation: Conversation, handle: str) -> str:
    name = conversation.names.get(handle)
    return f"{name} ({handle})" if name else handle


def attach_names(conversation: Conversation, contact_names: ContactNames | None) -> Conversation:
    """Give the conversation the names ``contact_names`` knows for its members and senders."""
    if contact_names:
        senders = [message.sender for message in conversation.messages if message.sender]
        conversation.names = contact_names.resolve(dict.fromkeys([*conversation.participants, *senders]))
    return conversation


def _header(conversation: Conversation) -> str:
    """The thread's name and members, so a rename or a new member changes the text (and its hash)."""
    lines = [conversation.title]
    if conversation.participants:
        lines.append("Participants: " + ", ".join(_member(conversation, h) for h in conversation.participants))
    if conversation.service:
        lines.append("Service: " + conversation.service)
    return "\n".join(lines)


def render(conversation: Conversation, *, size: int | None = None) -> tuple[str, list[TextChunk]]:
    """The document text and its chunks, with exact character spans.

    Each message is one chunk. A message longer than ``size`` (the configured
    chunk size) is split at paragraph, line and sentence boundaries into
    several chunks, so no chunk can exceed what the embedders accept; a chunk
    never spans two messages. The header naming the thread is not a chunk.
    """
    text, chunks, _messages = _render(conversation, size=size)
    return text, chunks


def _render(conversation: Conversation, *, size: int | None) -> tuple[str, list[TextChunk], list[ChatMessage]]:
    """:func:`render`, plus the message each chunk came from."""
    size = size or get_settings().chunk_size
    parts = [_header(conversation)]
    offset = len(parts[0])
    chunks: list[TextChunk] = []
    owners: list[ChatMessage] = []
    for message in conversation.messages:
        stamp = message.sent_at.strftime("%Y-%m-%d %H:%M UTC")
        paragraph = f"[{stamp}] {_sender_label(conversation, message)}: {message.text}"
        offset += 2  # the blank line between paragraphs
        pieces = (
            [paragraph] if len(paragraph) <= size else [c.text for c in chunk_prose(paragraph, size=size, overlap=0)]
        )
        cursor = 0
        for piece in pieces:
            start = paragraph.find(piece, cursor)
            if start < 0:  # pragma: no cover - the splitter only drops whitespace
                start = cursor
            cursor = start + len(piece)
            chunks.append(
                TextChunk(
                    ord=len(chunks),
                    text=piece,
                    chunker=CHUNKER,
                    heading_path=conversation.title,
                    char_start=offset + start,
                    char_end=offset + start + len(piece),
                )
            )
            owners.append(message)
        parts.append(paragraph)
        offset += len(paragraph)
    return "\n\n".join(parts), chunks, owners


def _identity_kind(handle: str) -> str:
    return "email" if "@" in handle else "phone"


def conversation_authors(conversation: Conversation, self_identity: SelfIdentity) -> list[AuthorPayload]:
    """Senders are the handles that wrote in the thread; members who only read it are recipients.

    A thread is the owner plus one or more others. The owner is added when their
    name is configured: as a sender when they wrote, else as a recipient.
    """
    senders = {message.sender for message in conversation.messages if message.sender}
    handles = list(dict.fromkeys([*conversation.participants, *sorted(senders)]))
    authors: list[AuthorPayload] = []
    for handle in handles:
        if self_identity.matches(email=handle):
            continue
        authors.append(
            AuthorPayload(
                name=conversation.label(handle),
                role="sender" if handle in senders else "recipient",
                confidence=1.0,
                evidence="imessage-handle",
                identities={_identity_kind(handle): handle},
            )
        )
    if self_identity.name:
        # Every thread has the owner in it; a member is a recipient until they write.
        wrote = any(message.is_from_me for message in conversation.messages)
        authors.append(
            AuthorPayload(
                name=self_identity.name,
                role="sender" if wrote else "recipient",
                confidence=1.0,
                evidence="imessage-is-from-me" if wrote else "imessage-owner",
                is_self=True,
            )
        )
    return authors


def ingest_conversation(
    gateway: IngestStorageGateway,
    source_ctx: SourceContext,
    db_path: Path,
    conversation: Conversation,
    *,
    self_identity: SelfIdentity,
    force: bool = False,
) -> int | None:
    """Store one conversation. Returns the chunks written, or None when it was unchanged."""
    uri = conversation_uri(db_path, conversation)
    size = get_settings().chunk_size
    text, chunks, owners = _render(conversation, size=size)
    content_hash = sha256_text(text).hex()

    existing = gateway.check_stat(source_ctx.slug, uri)
    if (
        existing.exists
        and not force
        and existing.content_sha256 == content_hash
        and existing.chunker == signature(size)
        and existing.state.upper() == "OK"
    ):
        gateway.record_seen(source_ctx.run_id, source_ctx.slug, uri)
        return None

    last = conversation.last_message_at
    meta = {
        "chat_guid": conversation.guid,
        "chat_identifier": conversation.chat_identifier,
        "service": conversation.service,
        "participants": conversation.participants,
        "participant_names": conversation.names,
        "is_group": conversation.is_group,
        "message_count": len(conversation.messages),
        "first_message_at": conversation.messages[0].sent_at.isoformat(),
        "last_message_at": last.isoformat() if last else None,
        "database": str(db_path),
    }
    return gateway.replace_document(
        run_id=source_ctx.run_id,
        source_slug=source_ctx.slug,
        uri=uri,
        title=conversation.title,
        lang=None,
        byte_size=len(text.encode("utf-8")),
        mtime=last.timestamp() if last else 0.0,
        source_sha256=None,
        content_sha256=content_hash,
        extractor=EXTRACTOR_NAME,
        extractor_version=EXTRACTOR_VERSION,
        chunker=signature(size),
        content=text,
        meta=meta,
        corpus_class=CorpusClass.COMMUNICATION.value,
        trust_tier=source_ctx.default_trust.value,
        authors=conversation_authors(conversation, self_identity),
        chunks=[
            ChunkPayload(
                ord=chunk.ord,
                text=chunk.text,
                token_count=chunk.token_estimate,
                char_start=chunk.char_start,
                char_end=chunk.char_end,
                heading_path=chunk.heading_path,
                chunk_sha256=chunk.sha256.hex(),
                chunker=chunk.chunker,
                direction=message.direction,
                sender=message.sender_id,
            )
            for chunk, message in zip(chunks, owners, strict=True)
        ],
    )


def ingest_messages_source(
    gateway: IngestStorageGateway,
    source_ctx: SourceContext,
    counters,
    *,
    self_identity: SelfIdentity,
    force: bool = False,
    limit: int | None = None,
    is_cancelled: Callable[[], bool] | None = None,
    on_item: Callable[[str], None] | None = None,
    contact_names: ContactNames | None = None,
) -> bool:
    """Ingest every conversation in every Messages database under the source's root.

    ``contact_names`` supplies names for the handles; without it threads are
    labelled by phone number and email address, as ``chat.db`` stores them.

    ``counters`` is the pipeline's ``IngestCounters``. Returns True when every
    database was read to the end, which is what lets reconcile retire the
    conversations that are gone; a cancellation, a ``limit`` or a database that
    could not be read returns False so nothing is retired on partial evidence.
    """
    root = Path(source_ctx.root)
    if not root.exists():
        counters.note_error(f"{root}: path does not exist")
        return False

    complete = True
    found = 0
    for db_path in find_databases(root):
        status = messages_database_status(db_path)
        if status is None:
            # Most often Full Disk Access is missing. Its threads must not be retired.
            counters.note_error(f"{db_path.name}: cannot be read (does Garage have Full Disk Access?)")
            log.warning("Could not open %s", db_path)
            complete = False
            continue
        if not status:
            log.info("Skipping %s: not a Messages database", db_path)
            continue
        found += 1
        log.info("Reading conversations from %s", db_path)
        stats = OrphanStats()
        try:
            for conversation in read_conversations(db_path, stats):
                if is_cancelled is not None and is_cancelled():
                    log.info("Ingest cancelled by user for source %s", source_ctx.slug)
                    return False
                counters.seen += 1
                attach_names(conversation, contact_names)
                try:
                    written = ingest_conversation(
                        gateway, source_ctx, db_path, conversation, self_identity=self_identity, force=force
                    )
                except Exception as exc:  # noqa: BLE001 - one thread must not end the run
                    counters.note_error(f"{conversation.title}: {exc}")
                    log.warning("Ingest failed for conversation %s: %s", conversation.guid, exc, exc_info=True)
                    try:
                        gateway.record_seen(source_ctx.run_id, source_ctx.slug, conversation_uri(db_path, conversation))
                    except Exception as seen_exc:  # noqa: BLE001
                        log.warning("Could not record %s as seen: %s", conversation.guid, seen_exc)
                else:
                    if written is None:
                        counters.skipped += 1
                    else:
                        counters.indexed += 1
                        counters.chunks_written += written
                if on_item is not None:
                    on_item(conversation.title)
                if limit is not None and counters.seen >= limit:
                    log.info("Hit candidate limit (%d) for source %r", limit, source_ctx.slug)
                    return False
        except sqlite3.Error as exc:
            counters.note_error(f"{db_path.name}: {exc}")
            log.warning("Could not read %s: %s", db_path, exc)
            complete = False
        else:
            if stats.attached or stats.skipped:
                log.info(
                    "%s: %d message(s) in no thread joined their one-to-one chat; %d skipped "
                    "(%d without a handle, %d whose address has no one-to-one chat)",
                    db_path.name,
                    stats.attached,
                    stats.skipped,
                    stats.no_handle,
                    stats.no_chat,
                )
    if not found and complete:
        # An unlistable folder looks empty; an empty run would retire every thread.
        counters.note_error(f"{root}: no readable Messages database found")
        return False
    return complete


__all__ = [
    "attach_names",
    "conversation_authors",
    "conversation_uri",
    "ingest_conversation",
    "ingest_messages_source",
    "render",
    "signature",
]

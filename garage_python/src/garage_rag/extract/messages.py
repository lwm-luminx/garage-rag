"""Reading Apple Messages' ``chat.db``: one conversation at a time.

A Messages database is not a file to extract but a store of many threads, so it
does not go through :mod:`garage_rag.extract.dispatch`. Each ``chat`` row becomes
one :class:`Conversation`, whose messages the ingest pipeline turns into one
document with one chunk per message (:mod:`garage_rag.ingest.conversations`).

What is read, and what is left out:

* **Text.** ``message.text``, or when that is empty -- as it is for most
  messages since macOS Ventura -- the string inside ``attributedBody``, an
  ``NSAttributedString`` in Apple's typedstream archive format. Only the
  plain string is recovered; formatting and mentions are dropped.
* **Not messages.** Tapbacks and other reactions (``associated_message_type``),
  group events such as renames and joins (``item_type``), and attachment-only
  messages have no text of their own and are skipped. A chat left with no text
  at all yields no conversation.
* **People.** Participants are the chat's handles (phone numbers and email
  addresses) as Messages stores them. Contact names live in the Address Book,
  which this reader does not open.
* **Orphans.** A chat's messages are its ``chat_message_join`` rows plus the
  messages no ``chat_message_join`` row names at all, which older macOS and
  iCloud sync leave behind by the thousand. An orphan with a ``handle_id``
  belongs to the one-to-one chat for that address: a chat that is not a group
  and has exactly one ``chat_handle_join`` handle with the same ``handle.id``
  (handle rows are per address *and* service, so the match is on the address).
  With several such chats, the one joined to the message's own handle row wins,
  then the lowest ROWID. An orphan with no handle, or whose address has no
  one-to-one chat, is skipped and counted (:class:`OrphanStats`).

The database is opened read-only, and never written: Messages holds it open
while it runs.
"""

from __future__ import annotations

import logging
import os
import sqlite3
import unicodedata
from collections.abc import Iterator
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from pathlib import Path

log = logging.getLogger(__name__)

EXTRACTOR_NAME = "messages"
# Bump when what is read or how it is rendered changes, so every conversation is rebuilt
# (it is part of the chunker signature, :func:`garage_rag.ingest.conversations.signature`).
# 2: orphan messages join their one-to-one chat; chunks carry direction and sender.
EXTRACTOR_VERSION = "2"

# chunks.direction (014_chunk_direction.sql), and chunks.sender for the owner's own messages.
SENT = "sent"
RECEIVED = "received"
SELF_SENDER = "me"

# chat.style for a group chat, even one down to a single other member.
_GROUP_STYLE = 43

# chat.db always carries these tables together; no other known database does.
SIGNATURE_TABLES = frozenset({"chat", "message", "handle", "chat_message_join"})

DATABASE_SUFFIXES = (".db", ".sqlite", ".sqlite3")

# Apple's epoch for message.date: 2001-01-01 UTC.
_APPLE_EPOCH = datetime(2001, 1, 1, tzinfo=UTC)
# Since High Sierra message.date is in nanoseconds; before, in seconds. Seconds
# since 2001 stay below this for millennia, nanoseconds pass it within a minute.
_NANOSECOND_THRESHOLD = 10**11

_SQLITE_HEADER = b"SQLite format 3\x00"


@dataclass(frozen=True)
class ChatMessage:
    """One message with text."""

    rowid: int
    guid: str
    sent_at: datetime
    is_from_me: bool
    # The sender's handle (phone number or email); None for the owner's own messages.
    sender: str | None
    text: str

    @property
    def direction(self) -> str:
        """``sent`` when the owner wrote it, else ``received`` (``chunks.direction``)."""
        return SENT if self.is_from_me else RECEIVED

    @property
    def sender_id(self) -> str | None:
        """``chunks.sender``: ``me``, the sender's handle, or None when chat.db does not say."""
        return SELF_SENDER if self.is_from_me else self.sender


@dataclass
class Conversation:
    """One Messages thread and its messages with text, oldest first."""

    guid: str
    chat_identifier: str
    display_name: str
    service: str
    participants: list[str] = field(default_factory=list)
    messages: list[ChatMessage] = field(default_factory=list)

    @property
    def is_group(self) -> bool:
        return len(self.participants) > 1

    @property
    def title(self) -> str:
        if self.display_name:
            return self.display_name
        if self.participants:
            return ", ".join(self.participants)
        return self.chat_identifier or self.guid

    @property
    def last_message_at(self) -> datetime | None:
        return self.messages[-1].sent_at if self.messages else None


@dataclass
class OrphanStats:
    """What became of the messages in no ``chat_message_join`` row, for one database."""

    attached: int = 0
    # No handle_id, so no address to find a chat by.
    no_handle: int = 0
    # An address with no one-to-one chat.
    no_chat: int = 0

    @property
    def skipped(self) -> int:
        return self.no_handle + self.no_chat


def apple_time(value: int | float | None) -> datetime | None:
    """Convert a chat.db timestamp (seconds or nanoseconds since 2001) to UTC."""
    if not value:
        return None
    seconds = value / 1e9 if abs(value) >= _NANOSECOND_THRESHOLD else float(value)
    return _APPLE_EPOCH + timedelta(seconds=seconds)


def decode_attributed_body(blob: bytes | None) -> str | None:
    """The plain string inside an ``attributedBody`` typedstream, or None.

    The archive stores the ``NSString`` class name, a few type bytes ending in
    ``+`` (a C string follows), then the UTF-8 length and bytes. The length is
    one byte, or ``0x81`` then two little-endian bytes, or ``0x82`` then four.
    """
    if not blob:
        return None
    start = blob.find(b"NSString")
    if start < 0:
        return None
    plus = blob.find(b"+", start + len(b"NSString"), start + len(b"NSString") + 8)
    if plus < 0:
        return None
    pos = plus + 1
    if pos >= len(blob):
        return None
    marker = blob[pos]
    if marker == 0x81:
        length = int.from_bytes(blob[pos + 1 : pos + 3], "little")
        pos += 3
    elif marker == 0x82:
        length = int.from_bytes(blob[pos + 1 : pos + 5], "little")
        pos += 5
    else:
        length = marker
        pos += 1
    raw = blob[pos : pos + length]
    if len(raw) != length:
        return None
    return raw.decode("utf-8", errors="replace")


def clean_text(raw: str | None) -> str:
    """NFC, no NULs or object-replacement characters, Unix newlines, trimmed."""
    if not raw:
        return ""
    text = unicodedata.normalize("NFC", raw)
    # U+FFFC stands in for an inline attachment; U+FFFD for bytes that did not decode.
    for ch in ("\x00", "￼", "�"):
        text = text.replace(ch, "")
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    return text.strip()


def find_databases(root: Path) -> list[Path]:
    """SQLite files under ``root`` (or ``root`` itself), skipping WAL sidecars and hidden folders."""
    if root.is_file():
        return [root]
    found: list[Path] = []
    for parent, dirnames, filenames in os.walk(root, followlinks=False):
        dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
        for name in sorted(filenames):
            if name.startswith(".") or name.endswith(("-wal", "-shm", "-journal")):
                continue
            if name.lower().endswith(DATABASE_SUFFIXES):
                found.append(Path(parent) / name)
    return found


def _connect(path: Path) -> sqlite3.Connection:
    """Open read-only. ``mode=ro`` still reads the WAL, so the newest messages are included."""
    try:
        conn = sqlite3.connect(f"{path.resolve().as_uri()}?mode=ro", uri=True, timeout=5.0)
        conn.execute("SELECT 1 FROM sqlite_master LIMIT 1")
        return conn
    except sqlite3.Error:
        # A folder we can read but not write (no -shm can be made): read the main file as is.
        return sqlite3.connect(f"{path.resolve().as_uri()}?immutable=1", uri=True, timeout=5.0)


def _tables(conn: sqlite3.Connection) -> set[str]:
    return {row[0] for row in conn.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}


def _columns(conn: sqlite3.Connection, table: str) -> set[str]:
    return {row[1] for row in conn.execute(f'PRAGMA table_info("{table}")')}


def messages_database_status(path: Path) -> bool | None:
    """True for a Messages ``chat.db`` (by its tables, not its name), False for
    any other file, and None when it could not be read at all.

    Unreadable is not the same as "not Messages": without Full Disk Access
    ``chat.db`` is still listed but cannot be opened, and treating it as some
    other database would let reconcile retire every conversation it holds.
    """
    try:
        with path.open("rb") as handle:
            header = handle.read(len(_SQLITE_HEADER))
    except OSError:
        return None
    if header != _SQLITE_HEADER:
        return False
    try:
        conn = _connect(path)
    except sqlite3.Error:
        return None
    try:
        return _tables(conn) >= SIGNATURE_TABLES
    except sqlite3.Error:
        return None
    finally:
        conn.close()


def is_messages_database(path: Path) -> bool:
    """Whether ``path`` is a readable Messages ``chat.db``."""
    return messages_database_status(path) is True


def _one_to_one_chats(
    conn: sqlite3.Connection, tables: set[str], chat_columns: set[str]
) -> dict[str, list[tuple[int, int]]]:
    """Address -> ``(handle ROWID, chat ROWID)`` for every non-group chat with exactly one handle."""
    if "chat_handle_join" not in tables:
        return {}
    not_group = f" WHERE COALESCE(c.style, 0) <> {_GROUP_STYLE}" if "style" in chat_columns else ""
    solo: dict[str, list[tuple[int, int]]] = {}
    for chat_id, handle_rowid, address in conn.execute(
        "SELECT s.chat_id, s.handle_id, h.id FROM ("
        " SELECT chj.chat_id AS chat_id, min(chj.handle_id) AS handle_id"
        f" FROM chat_handle_join AS chj JOIN chat AS c ON c.ROWID = chj.chat_id{not_group}"
        " GROUP BY chj.chat_id HAVING count(*) = 1"
        ") AS s JOIN handle AS h ON h.ROWID = s.handle_id"
    ):
        if address:
            solo.setdefault(address, []).append((handle_rowid, chat_id))
    return solo


def _assign_orphans(
    rows: list[tuple],
    solo: dict[str, list[tuple[int, int]]],
    handles: dict[int, str],
    stats: OrphanStats,
) -> dict[int, list[tuple]]:
    """Chat ROWID -> the orphan message rows that belong to it (see the module docstring)."""
    by_chat: dict[int, list[tuple]] = {}
    for row in rows:
        handle_rowid = row[4]
        address = handles.get(handle_rowid) if handle_rowid else None
        if not address:
            stats.no_handle += 1
            continue
        candidates = solo.get(address)
        if not candidates:
            stats.no_chat += 1
            continue
        _handle, chat_id = min(candidates, key=lambda c: (c[0] != handle_rowid, c[1]))
        by_chat.setdefault(chat_id, []).append(row)
        stats.attached += 1
    return by_chat


def read_conversations(path: Path, stats: OrphanStats | None = None) -> Iterator[Conversation]:
    """Every chat in the database that has at least one message with text.

    ``stats``, when given, is filled in with what became of the orphan messages
    (before the first conversation is yielded).

    Raises :class:`sqlite3.Error` when the file is not a readable Messages database.
    """
    conn = _connect(path)
    try:
        tables = _tables(conn)
        if not tables >= SIGNATURE_TABLES:
            raise sqlite3.DatabaseError(f"not a Messages database: {path}")
        message_columns = _columns(conn, "message")
        chat_columns = _columns(conn, "chat")

        def col(table_columns: set[str], name: str, default: str = "NULL") -> str:
            return name if name in table_columns else default

        handles = dict(conn.execute("SELECT ROWID, id FROM handle"))

        participants: dict[int, list[str]] = {}
        if "chat_handle_join" in tables:
            for chat_id, handle_id in conn.execute(
                "SELECT chat_id, handle_id FROM chat_handle_join ORDER BY chat_id, handle_id"
            ):
                handle = handles.get(handle_id)
                if handle:
                    participants.setdefault(chat_id, []).append(handle)

        empty = "''"
        chats = conn.execute(
            f"SELECT ROWID, guid, {col(chat_columns, 'chat_identifier', empty)}, "
            f"{col(chat_columns, 'display_name', empty)}, {col(chat_columns, 'service_name', empty)} "
            "FROM chat ORDER BY ROWID"
        ).fetchall()

        # Reactions and group events carry no text of their own.
        filters = []
        if "associated_message_type" in message_columns:
            filters.append("COALESCE(m.associated_message_type, 0) = 0")
        if "item_type" in message_columns:
            filters.append("COALESCE(m.item_type, 0) = 0")
        where = " AND ".join(["cmj.chat_id = ?", *filters])
        select = (
            f"SELECT m.ROWID, m.guid, m.text, {col(message_columns, 'attributedBody', 'NULL')}, "
            f"m.handle_id, m.date, m.is_from_me "
        )
        message_sql = (
            f"{select}FROM chat_message_join AS cmj JOIN message AS m ON m.ROWID = cmj.message_id WHERE {where}"
        )
        orphan_sql = (
            f"{select}FROM message AS m "
            "WHERE NOT EXISTS (SELECT 1 FROM chat_message_join AS j WHERE j.message_id = m.ROWID)"
            + "".join(f" AND {f}" for f in filters)
        )
        orphans = _assign_orphans(
            conn.execute(orphan_sql).fetchall(),
            _one_to_one_chats(conn, tables, chat_columns),
            handles,
            stats if stats is not None else OrphanStats(),
        )

        for chat_rowid, guid, identifier, display_name, service in chats:
            members = list(dict.fromkeys(participants.get(chat_rowid, [])))
            # In a one-to-one chat an unattributed incoming message can only be from the other party.
            fallback_sender = members[0] if len(members) == 1 else None
            if not members and identifier and not identifier.startswith("chat"):
                fallback_sender = identifier
            conversation = Conversation(
                guid=guid or f"chat-{chat_rowid}",
                chat_identifier=identifier or "",
                display_name=clean_text(display_name),
                service=service or "",
                participants=members,
            )
            rows = conn.execute(message_sql, (chat_rowid,)).fetchall() + orphans.get(chat_rowid, [])
            # ORDER BY m.date, m.ROWID, with NULL dates first as SQLite sorts them.
            rows.sort(key=lambda r: (r[5] is not None, r[5] or 0, r[0]))
            for rowid, message_guid, text, attributed, handle_id, date, is_from_me in rows:
                body = clean_text(text) or clean_text(decode_attributed_body(attributed))
                sent_at = apple_time(date)
                if not body or sent_at is None:
                    continue
                from_me = bool(is_from_me)
                sender = None if from_me else handles.get(handle_id) or fallback_sender
                conversation.messages.append(
                    ChatMessage(
                        rowid=rowid,
                        guid=message_guid or f"message-{rowid}",
                        sent_at=sent_at,
                        is_from_me=from_me,
                        sender=sender,
                        text=body,
                    )
                )
            # A one-to-one chat whose handle join is missing still has its other party.
            if not conversation.participants:
                others = [m.sender for m in conversation.messages if m.sender]
                conversation.participants = list(dict.fromkeys(others))
            if conversation.messages:
                yield conversation
    finally:
        conn.close()


__all__ = [
    "EXTRACTOR_NAME",
    "EXTRACTOR_VERSION",
    "RECEIVED",
    "SELF_SENDER",
    "SENT",
    "ChatMessage",
    "Conversation",
    "OrphanStats",
    "apple_time",
    "clean_text",
    "decode_attributed_body",
    "find_databases",
    "is_messages_database",
    "messages_database_status",
    "read_conversations",
]

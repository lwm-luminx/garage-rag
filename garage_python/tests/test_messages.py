"""Messages (chat.db) ingestion: one document per conversation, one chunk per message."""

from __future__ import annotations

import sqlite3
from dataclasses import replace
from datetime import UTC, datetime
from pathlib import Path
from typing import Any
from unittest.mock import patch

import pytest

from garage_rag.attribute.resolver import SelfIdentity
from garage_rag.db.models import CorpusClass, TrustTier
from garage_rag.extract.messages import (
    OrphanStats,
    apple_time,
    decode_attributed_body,
    find_databases,
    is_messages_database,
    read_conversations,
)
from garage_rag.ingest.conversations import conversation_uri, ingest_conversation, render, signature
from garage_rag.ingest.gateway import ExistingDocStat, IngestStorageGateway, SourceContext
from garage_rag.ingest.pipeline import ingest_source

# 2026-09-24 12:00:00 UTC as nanoseconds since 2001-01-01, the way macOS stores message.date.
BASE_NS = int((datetime(2026, 9, 24, 12, tzinfo=UTC) - datetime(2001, 1, 1, tzinfo=UTC)).total_seconds()) * 10**9
MINUTE_NS = 60 * 10**9


def attributed_body(text: str) -> bytes:
    """An NSAttributedString typedstream as Messages writes it, holding ``text``."""
    raw = text.encode("utf-8")
    length = bytes([len(raw)]) if len(raw) < 0x80 else b"\x81" + len(raw).to_bytes(2, "little")
    return (
        b"\x04\x0bstreamtyped\x81\xe8\x03\x84\x01@\x84\x84\x84\x12NSAttributedString\x00"
        b"\x84\x84\x08NSObject\x00\x85\x92\x84\x84\x84\x08NSString\x01\x94\x84\x01+"
        + length
        + raw
        + b"\x86\x84\x02iI\x01\x05\x92\x84\x84\x84\x0cNSDictionary\x00\x94\x84\x01i\x01\x92\x86\x86"
    )


def write_chat_db(path: Path) -> None:
    """A chat.db in Apple's layout, with the cases the reader has to handle."""
    conn = sqlite3.connect(path)
    conn.executescript(
        """
        CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL, country TEXT, service TEXT);
        CREATE TABLE chat (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT UNIQUE NOT NULL, style INTEGER,
            state INTEGER, chat_identifier TEXT, service_name TEXT, display_name TEXT);
        CREATE TABLE message (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT UNIQUE NOT NULL, text TEXT,
            handle_id INTEGER DEFAULT 0, service TEXT, date INTEGER, is_from_me INTEGER DEFAULT 0,
            attributedBody BLOB, associated_message_type INTEGER DEFAULT 0, item_type INTEGER DEFAULT 0);
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER, message_date INTEGER DEFAULT 0,
            PRIMARY KEY (chat_id, message_id));
        CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER, UNIQUE(chat_id, handle_id));
        INSERT INTO handle (ROWID, id, service) VALUES (1, '+15551234567', 'iMessage'),
            (2, 'friend@example.com', 'iMessage'), (3, '+15559876543', 'SMS');
        INSERT INTO chat (ROWID, guid, style, chat_identifier, service_name, display_name) VALUES
            (1, 'iMessage;-;+15551234567', 45, '+15551234567', 'iMessage', ''),
            (2, 'iMessage;+;chat42', 43, 'chat42', 'iMessage', 'Climbing crew'),
            (3, 'SMS;-;+15559876543', 45, '+15559876543', 'SMS', ''),
            (4, 'iMessage;-;friend@example.com', 45, 'friend@example.com', 'iMessage', '');
        INSERT INTO chat_handle_join VALUES (1, 1), (2, 1), (2, 2), (2, 3), (3, 3), (4, 2);
        """
    )
    rows: list[tuple[Any, ...]] = [
        # chat 1: one-to-one; the second message's text lives only in attributedBody.
        (1, 1, "running late", 0, 0, None, 0, 0),
        (1, 2, None, 1, 1, attributed_body("no worries, see you at 7"), 0, 0),
        (1, 3, "Loved “no worries”", 0, 1, None, 2000, 0),  # tapback: skipped
        (1, 4, "￼", 1, 0, None, 0, 0),  # attachment only: skipped
        # chat 2: a group; the two others speak.
        (2, 5, "Saturday at the gym?", 1, 0, None, 0, 0),
        (2, 6, "I'm in", 2, 0, None, 0, 0),
        (2, 7, None, 0, 0, None, 0, 2),  # group renamed: skipped
        # chat 3: nothing with text, so no conversation.
        (3, 8, "", 3, 0, None, 0, 0),
        # chat 4: a long message, long enough for a two-byte length in the typedstream.
        (4, 9, None, 2, 0, attributed_body("x" * 300), 0, 0),
    ]
    for minute, (chat_id, rowid, text, handle_id, from_me, body, assoc, item) in enumerate(rows):
        date = BASE_NS + minute * MINUTE_NS
        conn.execute(
            "INSERT INTO message (ROWID, guid, text, handle_id, date, is_from_me, attributedBody, "
            "associated_message_type, item_type) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (rowid, f"msg-{rowid}", text, 0 if from_me else handle_id, date, from_me, body, assoc, item),
        )
        conn.execute("INSERT INTO chat_message_join VALUES (?, ?, ?)", (chat_id, rowid, date))
    conn.commit()
    conn.close()


def add_orphans(path: Path) -> None:
    """Messages in no chat_message_join row, the way older macOS and iCloud sync leave them.

    Adds a second handle row for +15551234567 (SMS) with its own one-to-one chat, a
    handle with no chat but a group of one, and an orphan of each kind.
    """
    conn = sqlite3.connect(path)
    conn.executescript(
        """
        INSERT INTO handle (ROWID, id, service) VALUES (4, 'stranger@example.com', 'iMessage'),
            (5, '+15551234567', 'SMS');
        INSERT INTO chat (ROWID, guid, style, chat_identifier, service_name, display_name) VALUES
            (5, 'SMS;-;+15551234567', 45, '+15551234567', 'SMS', ''),
            (6, 'iMessage;+;chat77', 43, 'chat77', 'iMessage', 'Just the stranger');
        INSERT INTO chat_handle_join VALUES (5, 5), (6, 4);
        """
    )
    orphans: list[tuple[int, str, int, int, int]] = [
        # (ROWID, text, handle_id, is_from_me, seconds after BASE_NS)
        (30, "orphan from them", 1, 0, 30),  # between chat 1's two messages
        (31, "orphan from me", 1, 1, 150),  # the owner's own: handle_id names the other party
        (32, "orphan by SMS", 5, 0, 200),  # the SMS handle row: its own one-to-one chat wins
        (33, "orphan in a chat that had no text", 3, 0, 210),
        (34, "orphan with no handle", 0, 0, 220),
        (35, "orphan whose only chat is a group", 4, 0, 230),
    ]
    for rowid, text, handle_id, from_me, seconds in orphans:
        conn.execute(
            "INSERT INTO message (ROWID, guid, text, handle_id, date, is_from_me) VALUES (?, ?, ?, ?, ?, ?)",
            (rowid, f"msg-{rowid}", text, handle_id, BASE_NS + seconds * 10**9, from_me),
        )
    conn.commit()
    conn.close()


class FakeGateway(IngestStorageGateway):
    """Keeps documents in a dict, the way the SQL gateway keeps rows."""

    def __init__(self, root: Path, *, kind: str = "sqlite") -> None:
        self.root = root
        self.kind = kind
        self.docs: dict[str, dict[str, Any]] = {}
        self.seen: list[str] = []
        self.finalized: dict[str, Any] = {}

    def list_enabled_sources(self) -> list[str]:
        return ["apple-sms"]

    def begin_session(self, source_slug: str, include_code: bool = False) -> SourceContext:
        return SourceContext(
            source_id=1,
            slug=source_slug,
            root=self.root,
            default_class=CorpusClass.COMMUNICATION,
            default_trust=TrustTier.RECEIVED,
            run_id=9,
            kind=self.kind,
        )

    def persist_scan(self, source_slug, scan_result) -> None:
        self.scan = scan_result

    def check_stat(self, source_slug: str, uri: str) -> ExistingDocStat:
        doc = self.docs.get(uri)
        if doc is None:
            return ExistingDocStat(exists=False)
        return ExistingDocStat(
            exists=True, content_sha256=doc["content_sha256"], chunker=doc["chunker"] or "", state="ok"
        )

    def record_placeholder(self, *args, **kwargs) -> None:
        raise AssertionError("no placeholders in a Messages source")

    def record_extract_failed(self, *args, **kwargs) -> None:
        raise AssertionError("no extraction failures expected")

    def record_rejected(self, *args, **kwargs) -> None:
        raise AssertionError("conversations are never rejected")

    def record_no_text(self, *args, **kwargs) -> None:
        raise AssertionError("conversations without text are never read")

    def record_seen(self, run_id: int, source_slug: str, uri: str) -> None:
        self.seen.append(uri)

    def refresh_metadata(self, *args, **kwargs) -> None:
        raise AssertionError("unchanged conversations are only recorded as seen")

    def replace_document(self, **kwargs) -> int:
        self.docs[kwargs["uri"]] = kwargs
        self.seen.append(kwargs["uri"])
        return len(kwargs["chunks"])

    def finalize_session(self, **kwargs) -> None:
        self.finalized = kwargs


@pytest.fixture
def messages_dir(tmp_path: Path) -> Path:
    folder = tmp_path / "Messages"
    folder.mkdir()
    write_chat_db(folder / "chat.db")
    # Other databases Messages keeps beside chat.db are not conversations.
    other = sqlite3.connect(folder / "nicknames.db")
    other.execute("CREATE TABLE nickname (id INTEGER PRIMARY KEY, name TEXT)")
    other.commit()
    other.close()
    (folder / "chat.db-wal").write_bytes(b"")
    return folder


def test_apple_time_handles_seconds_and_nanoseconds() -> None:
    expected = datetime(2026, 9, 24, 12, tzinfo=UTC)
    assert apple_time(BASE_NS) == expected
    assert apple_time(BASE_NS // 10**9) == expected
    assert apple_time(0) is None


def test_decode_attributed_body() -> None:
    assert decode_attributed_body(attributed_body("hello")) == "hello"
    assert decode_attributed_body(attributed_body("é" * 200)) == "é" * 200
    assert decode_attributed_body(b"not an archive") is None
    assert decode_attributed_body(None) is None


def test_finds_only_the_messages_database(messages_dir: Path) -> None:
    found = find_databases(messages_dir)
    assert [p.name for p in found] == ["chat.db", "nicknames.db"]
    assert is_messages_database(messages_dir / "chat.db")
    assert not is_messages_database(messages_dir / "nicknames.db")


def test_reads_conversations_with_text_only(messages_dir: Path) -> None:
    conversations = {c.guid: c for c in read_conversations(messages_dir / "chat.db")}
    assert set(conversations) == {"iMessage;-;+15551234567", "iMessage;+;chat42", "iMessage;-;friend@example.com"}

    direct = conversations["iMessage;-;+15551234567"]
    assert direct.title == "+15551234567"
    assert not direct.is_group
    assert [(m.is_from_me, m.sender, m.text) for m in direct.messages] == [
        (False, "+15551234567", "running late"),
        (True, None, "no worries, see you at 7"),
    ]

    group = conversations["iMessage;+;chat42"]
    assert group.title == "Climbing crew"
    assert group.is_group
    assert group.participants == ["+15551234567", "friend@example.com", "+15559876543"]
    assert [(m.sender, m.text) for m in group.messages] == [
        ("+15551234567", "Saturday at the gym?"),
        ("friend@example.com", "I'm in"),
    ]

    assert conversations["iMessage;-;friend@example.com"].messages[0].text == "x" * 300


def test_render_gives_one_chunk_per_message_with_exact_spans(messages_dir: Path) -> None:
    direct = next(read_conversations(messages_dir / "chat.db"))
    text, chunks = render(direct)
    assert text == (
        "+15551234567\nParticipants: +15551234567\nService: iMessage\n\n"
        "[2026-09-24 12:00 UTC] +15551234567: running late\n\n[2026-09-24 12:01 UTC] Me: no worries, see you at 7"
    )
    assert [c.ord for c in chunks] == [0, 1]
    for chunk in chunks:
        assert text[chunk.char_start : chunk.char_end] == chunk.text
        assert chunk.heading_path == "+15551234567"


def test_ingest_source_indexes_each_conversation_once(messages_dir: Path) -> None:
    gateway = FakeGateway(messages_dir)
    with patch(
        "garage_rag.ingest.pipeline.SelfIdentity.from_settings",
        return_value=SelfIdentity("Rick", [("email", "rick@example.com")]),
    ):
        counters, _, _ = ingest_source(gateway=gateway, source_slug="apple-sms")

    assert counters.total_items == 4  # the scan counts chats
    assert counters.indexed == 3  # the SMS chat has no text
    assert counters.chunks_written == 5
    assert counters.failed == 0
    assert gateway.finalized["completed"] is True

    db = messages_dir / "chat.db"
    doc = gateway.docs[f"{db}#iMessage;+;chat42"]
    assert doc["title"] == "Climbing crew"
    assert doc["corpus_class"] == "communication"
    assert doc["trust_tier"] == "received"
    assert doc["chunker"] == signature(1000) == "conversation:message:1000:v2"
    assert doc["meta"]["is_group"] is True
    assert [c.text for c in doc["chunks"]] == [
        "[2026-09-24 12:04 UTC] +15551234567: Saturday at the gym?",
        "[2026-09-24 12:05 UTC] friend@example.com: I'm in",
    ]
    assert {(a.name, a.role) for a in doc["authors"]} == {
        ("+15551234567", "sender"),
        ("friend@example.com", "sender"),
        ("+15559876543", "recipient"),  # a member who never wrote
        ("Rick", "recipient"),  # the owner is in every thread, here without writing
    }
    assert {a.name: a.identities for a in doc["authors"]}["friend@example.com"] == {"email": "friend@example.com"}

    direct = gateway.docs[f"{db}#iMessage;-;+15551234567"]
    owner = [a for a in direct["authors"] if a.is_self]
    assert [a.name for a in owner] == ["Rick"]


def test_each_message_chunk_says_which_way_it_went(messages_dir: Path) -> None:
    """Trust is per thread; chunks.direction and chunks.sender say who wrote each message."""
    gateway = FakeGateway(messages_dir)
    ingest_source(gateway=gateway, source_slug="apple-sms")
    db = messages_dir / "chat.db"

    direct = gateway.docs[f"{db}#iMessage;-;+15551234567"]
    assert [(c.direction, c.sender) for c in direct["chunks"]] == [("received", "+15551234567"), ("sent", "me")]
    group = gateway.docs[f"{db}#iMessage;+;chat42"]
    assert [(c.direction, c.sender) for c in group["chunks"]] == [
        ("received", "+15551234567"),
        ("received", "friend@example.com"),
    ]


def test_every_piece_of_a_long_message_carries_its_direction(messages_dir: Path) -> None:
    db = messages_dir / "chat.db"
    long_one = next(c for c in read_conversations(db) if c.guid.endswith("friend@example.com"))
    long_one.messages[0] = replace(long_one.messages[0], text=". ".join(["a sentence of text"] * 30))
    gateway = FakeGateway(messages_dir)
    with patch("garage_rag.ingest.conversations.get_settings") as settings:
        settings.return_value.chunk_size = 120
        ingest_conversation(
            gateway, gateway.begin_session("apple-sms"), db, long_one, self_identity=SelfIdentity("Rick", [])
        )
    chunks = gateway.docs[conversation_uri(db, long_one)]["chunks"]
    assert len(chunks) > 1
    assert {(c.direction, c.sender) for c in chunks} == {("received", "friend@example.com")}


def test_orphan_messages_join_the_one_to_one_chat_for_their_address(messages_dir: Path) -> None:
    add_orphans(messages_dir / "chat.db")
    stats = OrphanStats()
    conversations = {c.guid: c for c in read_conversations(messages_dir / "chat.db", stats)}

    # In date order among the chat's own messages; the owner's orphan keeps is_from_me.
    direct = conversations["iMessage;-;+15551234567"]
    assert [(m.text, m.direction, m.sender_id) for m in direct.messages] == [
        ("running late", "received", "+15551234567"),
        ("orphan from them", "received", "+15551234567"),
        ("no worries, see you at 7", "sent", "me"),
        ("orphan from me", "sent", "me"),
    ]
    # The SMS handle row has its own one-to-one chat, which wins over the iMessage one.
    assert [m.text for m in conversations["SMS;-;+15551234567"].messages] == ["orphan by SMS"]
    # A chat with no text of its own becomes a conversation through its orphan.
    assert [m.text for m in conversations["SMS;-;+15559876543"].messages] == ["orphan in a chat that had no text"]
    # A group is never a one-to-one chat, even with one member; and nothing lands in the real group.
    assert "iMessage;+;chat77" not in conversations
    assert [m.text for m in conversations["iMessage;+;chat42"].messages] == ["Saturday at the gym?", "I'm in"]

    assert (stats.attached, stats.no_handle, stats.no_chat, stats.skipped) == (4, 1, 1, 2)


def test_an_orphan_rebuilds_only_its_thread(messages_dir: Path) -> None:
    gateway = FakeGateway(messages_dir)
    ingest_source(gateway=gateway, source_slug="apple-sms")

    conn = sqlite3.connect(messages_dir / "chat.db")
    conn.execute(
        "INSERT INTO message (ROWID, guid, text, handle_id, date, is_from_me)"
        " VALUES (40, 'msg-40', 'late one', 2, ?, 0)",
        (BASE_NS + 40 * MINUTE_NS,),
    )
    conn.commit()
    conn.close()

    counters, _, _ = ingest_source(gateway=gateway, source_slug="apple-sms")
    assert (counters.indexed, counters.skipped) == (1, 2)
    friend = gateway.docs[f"{messages_dir / 'chat.db'}#iMessage;-;friend@example.com"]
    assert friend["chunks"][-1].text.endswith("friend@example.com: late one")
    assert (friend["chunks"][-1].direction, friend["chunks"][-1].sender) == ("received", "friend@example.com")


def test_unchanged_conversations_are_only_recorded_as_seen(messages_dir: Path) -> None:
    gateway = FakeGateway(messages_dir)
    ingest_source(gateway=gateway, source_slug="apple-sms")
    gateway.seen.clear()

    counters, _, _ = ingest_source(gateway=gateway, source_slug="apple-sms")
    assert counters.indexed == 0
    assert counters.skipped == 3
    assert sorted(gateway.seen) == sorted(gateway.docs)
    assert gateway.finalized["completed"] is True


def test_a_new_message_rebuilds_only_its_conversation(messages_dir: Path) -> None:
    gateway = FakeGateway(messages_dir)
    ingest_source(gateway=gateway, source_slug="apple-sms")

    conn = sqlite3.connect(messages_dir / "chat.db")
    conn.execute(
        "INSERT INTO message (ROWID, guid, text, handle_id, date, is_from_me) VALUES (20, 'msg-20', 'here', 0, ?, 1)",
        (BASE_NS + 30 * MINUTE_NS,),
    )
    conn.execute("INSERT INTO chat_message_join VALUES (1, 20, ?)", (BASE_NS + 30 * MINUTE_NS,))
    conn.commit()
    conn.close()

    counters, _, _ = ingest_source(gateway=gateway, source_slug="apple-sms")
    assert counters.indexed == 1
    assert counters.skipped == 2
    db = messages_dir / "chat.db"
    direct = gateway.docs[conversation_uri(db, next(read_conversations(db)))]
    assert len(direct["chunks"]) == 3


def test_limit_and_cancellation_do_not_count_as_full_coverage(messages_dir: Path) -> None:
    gateway = FakeGateway(messages_dir)
    counters, _, _ = ingest_source(gateway=gateway, source_slug="apple-sms", limit=1)
    assert counters.seen == 1
    assert gateway.finalized["completed"] is False

    gateway = FakeGateway(messages_dir)
    counters, _, _ = ingest_source(gateway=gateway, source_slug="apple-sms", is_cancelled=lambda: True)
    assert counters.seen == 0
    assert gateway.finalized["completed"] is False


def test_the_file_walk_is_not_used_for_messages(messages_dir: Path) -> None:
    """Attachments beside chat.db are not indexed as files of their own."""
    (messages_dir / "Attachments").mkdir()
    (messages_dir / "Attachments" / "note.txt").write_text("an attachment", encoding="utf-8")
    gateway = FakeGateway(messages_dir)
    ingest_source(gateway=gateway, source_slug="apple-sms")
    assert all("#" in uri for uri in gateway.docs)


def test_long_messages_are_split_but_never_merged(messages_dir: Path) -> None:
    long_one = next(c for c in read_conversations(messages_dir / "chat.db") if c.guid.endswith("friend@example.com"))
    long_one.messages[0] = replace(long_one.messages[0], text=". ".join(["a sentence of text"] * 30))
    text, chunks = render(long_one, size=120)
    assert len(chunks) > 1
    assert all(len(c.text) <= 120 for c in chunks)
    for chunk in chunks:
        assert text[chunk.char_start : chunk.char_end] == chunk.text
    assert chunks[0].text.startswith("[2026-09-24 12:08 UTC] friend@example.com: ")


def test_a_renamed_group_is_rebuilt(messages_dir: Path) -> None:
    gateway = FakeGateway(messages_dir)
    ingest_source(gateway=gateway, source_slug="apple-sms")

    conn = sqlite3.connect(messages_dir / "chat.db")
    conn.execute("UPDATE chat SET display_name = 'Crag crew' WHERE ROWID = 2")
    conn.commit()
    conn.close()

    counters, _, _ = ingest_source(gateway=gateway, source_slug="apple-sms")
    assert counters.indexed == 1
    assert gateway.docs[f"{messages_dir / 'chat.db'}#iMessage;+;chat42"]["title"] == "Crag crew"


def test_an_unreadable_database_does_not_count_as_full_coverage(messages_dir: Path) -> None:
    """Without Full Disk Access chat.db is listed but cannot be opened; reconcile must not retire its threads."""
    gateway = FakeGateway(messages_dir)
    with patch("garage_rag.extract.messages.Path.open", side_effect=PermissionError("Operation not permitted")):
        counters, _, _ = ingest_source(gateway=gateway, source_slug="apple-sms")
    assert gateway.finalized["completed"] is False
    assert any("chat.db" in error and "Full Disk Access" in error for error in counters.errors)
    assert not gateway.docs


def test_a_folder_with_no_messages_database_is_not_full_coverage(tmp_path: Path) -> None:
    """An unlistable ~/Library/Messages looks empty, which must not read as "every thread is gone"."""
    gateway = FakeGateway(tmp_path)
    counters, _, _ = ingest_source(gateway=gateway, source_slug="apple-sms")
    assert gateway.finalized["completed"] is False
    assert counters.errors == [f"{tmp_path}: no readable Messages database found"]

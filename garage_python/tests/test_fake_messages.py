"""The fake Messages folder (``fake_messages.py``) and the Messages ingest run against it."""

from __future__ import annotations

import re
import sqlite3
from pathlib import Path
from typing import Any

import pytest

# Faker is in the dev extras only, which the Bazel @pypi hub does not expose; the venv runs this.
pytest.importorskip("faker")

from fake_messages import CHAT_DB_SCHEMA, FakeMessages, build_messages_folder  # noqa: E402

from garage_rag.db.models import CorpusClass, TrustTier
from garage_rag.extract.contact_names import ContactNames
from garage_rag.extract.messages import OrphanStats, is_messages_database, read_conversations
from garage_rag.extract.nicknames import read_shared_names
from garage_rag.ingest.gateway import ExistingDocStat, IngestStorageGateway, SourceContext
from garage_rag.ingest.pipeline import ingest_source

# The fictional exchange (555-0100 to 555-0199) and the reserved example domains.
FICTIONAL_PHONE = re.compile(r"\+1\d{3}55501\d{2}")
FICTIONAL_EMAIL = re.compile(r"[a-z0-9.]+@example\.(com|net|org)")


class RecordingGateway(IngestStorageGateway):
    """Keeps the documents an ingest writes."""

    def __init__(self, root: Path) -> None:
        self.root = root
        self.docs: dict[str, dict[str, Any]] = {}
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
            run_id=1,
            kind="sqlite",
        )

    def persist_scan(self, source_slug, scan_result) -> None:
        pass

    def check_stat(self, source_slug: str, uri: str) -> ExistingDocStat:
        return ExistingDocStat(exists=False)

    def record_placeholder(self, *args, **kwargs) -> None:
        raise AssertionError("no placeholders in a Messages source")

    def record_extract_failed(self, *args, **kwargs) -> None:
        raise AssertionError("no extraction failures expected")

    def record_rejected(self, *args, **kwargs) -> None:
        raise AssertionError("conversations are never rejected")

    def record_no_text(self, *args, **kwargs) -> None:
        raise AssertionError("conversations without text are never read")

    def record_seen(self, run_id: int, source_slug: str, uri: str) -> None:
        pass

    def refresh_metadata(self, *args, **kwargs) -> None:
        raise AssertionError("nothing is unchanged in a first ingest")

    def replace_document(self, *args, **kwargs) -> int:
        self.docs[kwargs["uri"]] = kwargs
        return len(kwargs["chunks"])

    def finalize_session(self, *args, **kwargs) -> None:
        self.finalized = kwargs


@pytest.fixture(scope="module")
def fake(tmp_path_factory: pytest.TempPathFactory) -> FakeMessages:
    return build_messages_folder(tmp_path_factory.mktemp("Messages"), seed=7, people=30, threads=60)


def test_the_database_has_the_messages_schema(fake: FakeMessages) -> None:
    assert is_messages_database(fake.chat_db)
    expected = set(re.findall(r"CREATE TABLE (?:IF NOT EXISTS )?(\w+)", CHAT_DB_SCHEMA.read_text()))
    conn = sqlite3.connect(fake.chat_db)
    tables = {row[0] for row in conn.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
    conn.close()
    assert expected <= tables


def test_the_same_seed_writes_the_same_database(tmp_path: Path) -> None:
    def dump(seed: int, name: str) -> list[tuple]:
        written = build_messages_folder(tmp_path / name, seed=seed)
        conn = sqlite3.connect(written.chat_db)
        sql = "SELECT guid, text, attributedBody, date, is_from_me FROM message ORDER BY ROWID"
        rows = conn.execute(sql).fetchall()
        conn.close()
        return rows

    assert dump(3, "a") == dump(3, "b")
    assert dump(3, "c") != dump(4, "d")


def test_everyone_in_it_is_fictional(fake: FakeMessages) -> None:
    conn = sqlite3.connect(fake.chat_db)
    handles = [row[0] for row in conn.execute("SELECT id FROM handle")]
    conn.close()
    assert handles
    for handle in handles:
        assert FICTIONAL_PHONE.fullmatch(handle) or FICTIONAL_EMAIL.fullmatch(handle), handle
    for handle, _name in fake.contacts:
        assert "@example." in handle or re.fullmatch(r"\(\d{3}\) 555-01\d{2}", handle), handle


def test_the_reader_finds_every_thread_with_text(fake: FakeMessages) -> None:
    stats = OrphanStats()
    conversations = {c.guid: c for c in read_conversations(fake.chat_db, stats)}

    assert {guid: len(c.messages) for guid, c in conversations.items()} == fake.text_messages
    assert not set(fake.silent_chats) & set(conversations)
    assert fake.orphans > 0
    assert stats.attached == fake.orphans
    assert stats.skipped == fake.unplaced_orphans == 2
    # Tapbacks and renames are not messages; every kept message has text.
    for conversation in conversations.values():
        for message in conversation.messages:
            assert message.text
            assert not message.text.startswith("Loved “")
    assert any(c.is_group and c.display_name for c in conversations.values())
    assert any(c.is_group and not c.display_name for c in conversations.values())


def test_handled_shared_names_win_over_pending_ones(fake: FakeMessages) -> None:
    shared = ContactNames(read_shared_names(fake.folder))
    assert fake.shared_names
    for handle, name in fake.shared_names.items():
        assert shared.name_for(handle) == name


def test_ingest_names_threads_from_contacts_then_shared_names(fake: FakeMessages) -> None:
    gateway = RecordingGateway(fake.folder)
    counters, _, _ = ingest_source(gateway=gateway, source_slug="apple-sms", contact_names=ContactNames(fake.contacts))

    assert counters.failed == 0
    assert counters.indexed == len(fake.text_messages)
    assert gateway.finalized["completed"] is True

    in_contacts = {handle for handle, _ in fake.contacts}
    checked = 0
    for person in fake.people:
        known = bool(
            {person.email} & in_contacts
            or (person.phone and any(re.sub(r"\D", "", h).endswith(person.phone[-10:]) for h in in_contacts))
        )
        for handle in person.handles:
            doc = next((d for uri, d in gateway.docs.items() if uri.endswith(f";-;{handle}")), None)
            if doc is None:
                continue
            # Contacts first, then the name they shared, else the handle as chat.db has it.
            expected = person.name if known else fake.shared_names.get(handle, handle)
            assert doc["title"] == expected, handle
            assert "Pending" not in doc["content"]
            checked += 1
    assert checked > 10
    # Somebody's shared name disagrees with Contacts, and Contacts won.
    assert any(name.endswith("🌟") for name in fake.shared_names.values())
    assert not any("🌟" in doc["title"] for doc in gateway.docs.values())


def test_it_holds_every_shape_the_reader_has_to_handle(fake: FakeMessages) -> None:
    conn = sqlite3.connect(fake.chat_db)

    def count(where: str) -> int:
        return conn.execute(f"SELECT COUNT(*) FROM message WHERE {where}").fetchone()[0]

    shapes = {
        "text only": count("text IS NOT NULL AND attributedBody IS NULL AND item_type = 0"),
        "attributedBody only": count("text IS NULL AND attributedBody IS NOT NULL"),
        "long attributedBody": count("length(attributedBody) > 200"),
        "reply": count("thread_originator_guid IS NOT NULL"),
        "edited": count("date_edited IS NOT NULL AND date_retracted IS NULL"),
        "unsent": count("date_retracted IS NOT NULL"),
        "link": count("balloon_bundle_id IS NOT NULL"),
        "tapback": count("associated_message_type BETWEEN 2000 AND 2005"),
        "attachment only": count("cache_has_attachments = 1"),
        "rename": count("item_type = 2"),
        "membership": count("item_type = 1"),
    }
    conn.close()
    assert all(shapes.values()), shapes

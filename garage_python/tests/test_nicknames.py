"""Names iMessage contacts shared, read from Messages' NickNameCache beside chat.db."""

from __future__ import annotations

import plistlib
import sqlite3
from pathlib import Path

from garage_rag.extract.contact_names import ContactNames
from garage_rag.extract.nicknames import read_shared_names


def keyed_archive(fields: dict[str, str]) -> bytes:
    """An NSKeyedArchiver plist whose root is an object holding ``fields``, as Foundation writes one."""
    objects: list = ["$null"]
    root: dict = {"$class": plistlib.UID(0)}
    objects.append(root)
    for key, value in fields.items():
        objects.append(value)
        root[key] = plistlib.UID(len(objects) - 1)
    objects.append({"$classname": "IMNickname", "$classes": ["IMNickname", "NSObject"]})
    root["$class"] = plistlib.UID(len(objects) - 1)
    archive = {
        "$version": 100000,
        "$archiver": "NSKeyedArchiver",
        "$top": {"root": plistlib.UID(1)},
        "$objects": objects,
    }
    return plistlib.dumps(archive, fmt=plistlib.FMT_BINARY)


def write_store(path: Path, rows: list[tuple[str, bytes]]) -> None:
    conn = sqlite3.connect(path)
    conn.execute("CREATE TABLE kvtable (ROWID INTEGER PRIMARY KEY, key TEXT UNIQUE, value BLOB)")
    conn.executemany("INSERT INTO kvtable (key, value) VALUES (?, ?)", rows)
    conn.commit()
    conn.close()


def test_reads_shared_names_and_prefers_accepted_over_pending(tmp_path: Path) -> None:
    cache = tmp_path / "NickNameCache"
    cache.mkdir()
    write_store(
        cache / "pendingNicknamesKeyStore.db",
        [("+15551234567", keyed_archive({"firstName": "Pending", "lastName": "Name"}))],
    )
    write_store(
        cache / "handledNicknamesKeyStore.db",
        [
            ("+15551234567", keyed_archive({"firstName": "Alex", "lastName": "Doe"})),
            ("friend@example.com", plistlib.dumps({"displayName": "Sam"})),
            ("not-a-handle", keyed_archive({"firstName": "Nobody"})),
            ("+15559876543", b"not a plist"),
        ],
    )
    pairs = read_shared_names(tmp_path)
    assert pairs[:2] == [("+15551234567", "Alex Doe"), ("friend@example.com", "Sam")]
    names = ContactNames(pairs)
    assert names.name_for("+15551234567") == "Alex Doe"
    assert names.name_for("+15559876543") is None


def test_no_cache_and_foreign_tables_give_nothing(tmp_path: Path) -> None:
    assert read_shared_names(tmp_path) == []
    cache = tmp_path / "NickNameCache"
    cache.mkdir()
    conn = sqlite3.connect(cache / "other.db")
    conn.execute("CREATE TABLE kv (k TEXT, v TEXT)")
    conn.execute("INSERT INTO kv VALUES ('+15551234567', 'x')")
    conn.commit()
    conn.close()
    (cache / "garbage.db").write_bytes(b"not sqlite")
    assert read_shared_names(tmp_path) == []


def test_contacts_win_and_shared_names_fill_in(tmp_path: Path) -> None:
    contacts = ContactNames([("(555) 123-4567", "Alex from Contacts")])
    combined = contacts.with_fallback([("+15551234567", "Alex shared"), ("friend@example.com", "Sam")])
    assert combined.name_for("+15551234567") == "Alex from Contacts"
    assert combined.name_for("friend@example.com") == "Sam"
    assert contacts.name_for("friend@example.com") is None  # the original is untouched

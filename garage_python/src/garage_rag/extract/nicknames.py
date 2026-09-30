"""Names iMessage contacts shared with the owner ("Share Name and Photo"), from Messages' NickNameCache.

Messages keeps the names people chose to share in ``NickNameCache/`` beside ``chat.db``: small
SQLite key-value stores (``kvtable``: ``key`` a handle, ``value`` an archived nickname). The layout
is Apple's private format, so this reader is deliberately tolerant. It takes any table with a text
key and a blob value, decodes the value as a property list (keyed archive or plain), and takes the
first and last name, or a display name, from whatever dictionary holds them. A file, row or value it
cannot read is skipped; it never fails an ingest. Names for handles that are not a phone number or
email address are ignored.

The folder is inside the Messages folder the user already granted, so reading it needs no other
permission. The names are the owner's contacts' own choices and stay in the communications they label.
"""

from __future__ import annotations

import logging
import plistlib
import sqlite3
from collections.abc import Iterator
from pathlib import Path
from typing import Any

from garage_rag.extract.contact_names import handle_key

log = logging.getLogger(__name__)

FOLDER = "NickNameCache"

# Keys a nickname's name parts have been seen under; compared case-insensitively.
_FIRST = ("firstname", "first", "givenname")
_LAST = ("lastname", "last", "familyname")
_DISPLAY = ("displayname", "fullname", "name")


def _connect(path: Path) -> sqlite3.Connection:
    uri = path.resolve().as_uri()
    try:
        conn = sqlite3.connect(f"{uri}?mode=ro", uri=True, timeout=2.0)
        conn.execute("SELECT 1 FROM sqlite_master LIMIT 1")
        return conn
    except sqlite3.Error:
        return sqlite3.connect(f"{uri}?immutable=1", uri=True, timeout=2.0)


def _key_value_columns(conn: sqlite3.Connection, table: str) -> tuple[str, str] | None:
    columns = [(row[1], (row[2] or "").upper()) for row in conn.execute(f'PRAGMA table_info("{table}")')]
    names = {name.lower(): name for name, _ in columns}
    if "key" in names and "value" in names:
        return names["key"], names["value"]
    text = next((name for name, kind in columns if "TEXT" in kind), None)
    blob = next((name for name, kind in columns if "BLOB" in kind), None)
    return (text, blob) if text and blob else None


def _unarchive(value: Any) -> Any:
    """A keyed archive's root object with its references resolved; anything else as is."""
    if not (isinstance(value, dict) and "$objects" in value and "$top" in value):
        return value
    objects = value["$objects"]

    def resolve(item: Any, depth: int = 0) -> Any:
        if depth > 32:
            return None
        if isinstance(item, plistlib.UID):
            return resolve(objects[item.data], depth + 1) if item.data < len(objects) else None
        if isinstance(item, dict):
            if "NS.keys" in item and "NS.objects" in item:
                keys = [resolve(k, depth + 1) for k in item["NS.keys"]]
                return {k: resolve(v, depth + 1) for k, v in zip(keys, item["NS.objects"], strict=False)}
            return {k: resolve(v, depth + 1) for k, v in item.items() if k != "$class"}
        if isinstance(item, list):
            return [resolve(v, depth + 1) for v in item]
        return None if item == "$null" else item

    top = value["$top"]
    root = top.get("root", next(iter(top.values()), None)) if isinstance(top, dict) else None
    return resolve(root)


def _name_in(value: Any, depth: int = 0) -> str | None:
    """The name held by the first dictionary (depth first) that has name parts."""
    if depth > 8:
        return None
    if isinstance(value, dict):
        fields = {str(k).lower(): v for k, v in value.items() if isinstance(v, str)}
        first = next((fields[k].strip() for k in _FIRST if fields.get(k, "").strip()), "")
        last = next((fields[k].strip() for k in _LAST if fields.get(k, "").strip()), "")
        if first or last:
            return " ".join(part for part in (first, last) if part)
        display = next((fields[k].strip() for k in _DISPLAY if fields.get(k, "").strip()), "")
        if display:
            return display
        children = value.values()
    elif isinstance(value, list):
        children = value
    else:
        return None
    for child in children:
        name = _name_in(child, depth + 1)
        if name:
            return name
    return None


def _decode(blob: Any) -> str | None:
    if not isinstance(blob, bytes | bytearray) or not blob:
        return None
    try:
        value = plistlib.loads(bytes(blob))
    except Exception:  # noqa: BLE001 - Apple's private format: anything unreadable is skipped
        return None
    return _name_in(_unarchive(value))


def _read_file(path: Path) -> Iterator[tuple[str, str]]:
    try:
        conn = _connect(path)
    except sqlite3.Error:
        return
    try:
        tables = [row[0] for row in conn.execute("SELECT name FROM sqlite_master WHERE type = 'table'")]
        for table in tables:
            columns = _key_value_columns(conn, table)
            if columns is None:
                continue
            key_col, value_col = columns
            for key, blob in conn.execute(f'SELECT "{key_col}", "{value_col}" FROM "{table}"'):
                if not isinstance(key, str) or handle_key(key) is None:
                    continue
                name = _decode(blob)
                if name:
                    yield key, name
    except sqlite3.Error as exc:
        log.debug("Skipping nickname store %s: %s", path.name, exc)
    finally:
        conn.close()


def read_shared_names(messages_dir: Path) -> list[tuple[str, str]]:
    """``(handle, name)`` pairs from ``messages_dir/NickNameCache``; empty when there is none.

    Accepted names come before pending ones (a store whose name says ``pending``), so a handle's
    accepted name wins when both are present.
    """
    folder = messages_dir / FOLDER
    if not folder.is_dir():
        return []
    try:
        files = sorted(p for p in folder.iterdir() if p.is_file() and p.suffix.lower() in (".db", ".sqlite"))
    except OSError:
        return []
    files.sort(key=lambda p: "pending" in p.name.lower())
    pairs: list[tuple[str, str]] = []
    for path in files:
        pairs.extend(_read_file(path))
    # A count only: the names are the owner's contacts.
    log.info("Read %d shared name(s) from %s", len(pairs), FOLDER)
    return pairs


__all__ = ["FOLDER", "read_shared_names"]

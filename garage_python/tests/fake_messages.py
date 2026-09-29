"""A fake Apple Messages folder: a ``chat.db`` in Messages' own schema, filled with fictitious people.

Tests use it to run the Messages ingest against something shaped like the real thing, without anyone's
messages. Everything is invented, and a seed gives the same folder (for one Faker version):

* **People** have names from Faker, phone numbers in the North American range reserved for fiction
  (555-0100 to 555-0199) and email addresses on the reserved ``example.com/.net/.org`` domains.
  Most of what they say is Faker's too. Faker is a dev dependency, so the Bazel test skips.
* **Schema** is ``fixtures/messages/chat_db_schema.sql`` (tables and indexes; the real database's
  triggers call functions only Messages registers, so they are left out).
* **Shapes** the reader has to handle: one-to-one chats over iMessage (phone and email), SMS and RCS;
  named and unnamed groups; text only in ``message.text`` (before Ventura), in both columns, or only
  in ``attributedBody`` (since Ventura), some long enough to need a multi-byte length; replies, edits
  and links; tapbacks, unsent messages, attachment-only messages, renames and membership changes,
  none of which is kept; messages no ``chat_message_join`` row names (orphans), some the reader can
  file and some it cannot; one person on two handles (``person_centric_id``).
* **Names**: :attr:`FakeMessages.contacts` is what Contacts would hand the ingest for some people, and
  ``NickNameCache/`` holds names others shared over iMessage, a few of them disagreeing with Contacts.

Run it directly to write a folder for trying the app by hand::

    python garage_python/tests/fake_messages.py /tmp/FakeMessages --seed 7 --people 60 --threads 80
"""

from __future__ import annotations

import argparse
import plistlib
import random
import sqlite3
import uuid
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from pathlib import Path

# gazelle:ignore faker
from faker import Faker  # a dev dependency, which the Bazel @pypi hub does not expose

FIXTURES = Path(__file__).parent / "fixtures" / "messages"
CHAT_DB_SCHEMA = FIXTURES / "chat_db_schema.sql"
NICKNAME_SCHEMA = FIXTURES / "nickname_store_schema.sql"

_APPLE_EPOCH = datetime(2001, 1, 1, tzinfo=UTC)
# Messages' service markers.
IMESSAGE, SMS, RCS = "iMessage", "SMS", "RCS"
# chat.style: 43 for a group, 45 for one-to-one.
GROUP_STYLE, DIRECT_STYLE = 43, 45
# associated_message_type for "loved" .. "questioned"; item_type 1 is a member added or removed,
# 2 a group rename.
TAPBACKS = range(2000, 2006)
ITEM_MEMBERSHIP, ITEM_GROUP_RENAME = 1, 2
OBJECT_REPLACEMENT = "￼"

# Area codes that exist, paired with the fictional 555-01xx exchange.
AREA_CODES = ["206", "312", "415", "503", "617", "702", "808", "919"]
GROUP_KINDS = ["crew", "book club", "Saturday soccer", "trip planning 🏕️", "garden plot", "band practice"]
# Lines Faker would not write: emoji, accents, a link. The rest of the chatter is Faker's.
LINES = [
    "running late, be there in 10",
    "no worries, see you soon",
    "did you see the game last night?",
    "can you grab milk on the way home",
    "happy birthday!! 🎉",
    "what time works for you tomorrow?",
    "sounds good to me",
    "I'll bring the snacks",
    "the ferry leaves at 7:40, don't miss it",
    "just finished the book, the ending was wild",
    "are we still on for dinner Thursday?",
    "sending the photos now",
    "thanks again for yesterday",
    "that's hilarious 😂",
    "on my way",
    "can you call me when you get a sec",
    "the recipe needs two cups of flour, not three",
    "parking is on the north side",
    "I left my umbrella at your place",
    "let's push it to next week",
    "Café au lait at the usual spot? ☕",
    "Tickets are booked for the 14th.",
    "Reminder: the plumber comes between 9 and 11.",
    "Does anyone have a spare tent?",
    "here's the trail map https://example.com/trails/north-loop",
]
# Appended to a line now and then, so some attributedBody strings need a multi-byte length.
LONG_TAIL = (
    " Also, before I forget: the landlord says the hallway gets painted next week, so leave the bikes "
    "on the balcony, and the spare key is back under the blue planter by the door."
)


def apple_ns(when: datetime) -> int:
    """``message.date``: nanoseconds since 2001-01-01 UTC."""
    return int((when - _APPLE_EPOCH).total_seconds()) * 1_000_000_000


def attributed_body(text: str) -> bytes:
    """An ``NSAttributedString`` typedstream holding ``text``, as Messages writes ``attributedBody``."""
    raw = text.encode("utf-8")
    if len(raw) < 0x80:
        length = bytes([len(raw)])
    elif len(raw) < 0x10000:
        length = b"\x81" + len(raw).to_bytes(2, "little")
    else:
        length = b"\x82" + len(raw).to_bytes(4, "little")
    return (
        b"\x04\x0bstreamtyped\x81\xe8\x03\x84\x01@\x84\x84\x84\x12NSAttributedString\x00"
        b"\x84\x84\x08NSObject\x00\x85\x92\x84\x84\x84\x08NSString\x01\x94\x84\x01+"
        + length
        + raw
        + b"\x86\x84\x02iI\x01\x05\x92\x84\x84\x84\x0cNSDictionary\x00\x94\x84\x01i\x01\x92\x86\x86"
    )


def keyed_archive(fields: dict[str, str]) -> bytes:
    """A binary ``NSKeyedArchiver`` plist whose root object holds ``fields`` (a shared nickname)."""
    objects: list = ["$null"]
    root: dict = {}
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


@dataclass
class Person:
    name: str
    phone: str | None
    email: str | None
    person_id: str

    @property
    def handles(self) -> list[str]:
        return [h for h in (self.phone, self.email) if h]


@dataclass
class FakeMessages:
    """What was written, so tests can check the ingest against it."""

    folder: Path
    chat_db: Path
    people: list[Person]
    # (handle, name) pairs as the app would read them from Contacts, Contacts' own spelling.
    contacts: list[tuple[str, str]]
    # handle -> name as shared over iMessage (NickNameCache).
    shared_names: dict[str, str]
    # chat guid -> number of messages with text the reader should keep.
    text_messages: dict[str, int] = field(default_factory=dict)
    # chat guids with no message the reader keeps (it yields no conversation for them).
    silent_chats: list[str] = field(default_factory=list)
    # Orphans the reader files under a one-to-one chat, and those it cannot place.
    orphans: int = 0
    unplaced_orphans: int = 0


def _schema(path: Path) -> str:
    """The schema's tables and indexes, without triggers."""
    lines = [line for line in path.read_text().splitlines() if not line.lstrip().startswith("--")]
    statements = [s.strip() for s in "\n".join(lines).split(";")]
    keep = [
        s
        for s in statements
        if s and not s.lstrip("-\n ").upper().startswith("CREATE TRIGGER") and "CREATE" in s.upper()
    ]
    return ";\n".join(keep) + ";"


class _Writer:
    def __init__(self, conn: sqlite3.Connection, rng: random.Random, start: datetime) -> None:
        self.conn = conn
        self.rng = rng
        self.clock = start
        self.handle_ids: dict[tuple[str, str], int] = {}

    def guid(self) -> str:
        return str(uuid.UUID(int=self.rng.getrandbits(128), version=4)).upper()

    def tick(self) -> int:
        self.clock += timedelta(minutes=self.rng.randint(1, 180))
        return apple_ns(self.clock)

    def handle(self, handle: str, service: str, person: Person) -> int:
        key = (handle, service)
        if key not in self.handle_ids:
            cur = self.conn.execute(
                "INSERT INTO handle (id, country, service, uncanonicalized_id, person_centric_id) "
                "VALUES (?, ?, ?, ?, ?)",
                (handle, "us", service, None if "@" in handle else handle.removeprefix("+1"), person.person_id),
            )
            self.handle_ids[key] = int(cur.lastrowid or 0)
        return self.handle_ids[key]

    def chat(self, *, identifier: str, service: str, group: bool, display_name: str, handles: list[int]) -> int:
        prefix = f"{service};{'+' if group else '-'};{identifier}"
        cur = self.conn.execute(
            "INSERT INTO chat (guid, style, state, chat_identifier, service_name, display_name, account_login) "
            "VALUES (?, ?, 3, ?, ?, ?, 'E:owner@example.com')",
            (prefix, GROUP_STYLE if group else DIRECT_STYLE, identifier, service, display_name),
        )
        chat_id = int(cur.lastrowid or 0)
        self.conn.executemany("INSERT INTO chat_handle_join VALUES (?, ?)", [(chat_id, h) for h in handles])
        self.conn.execute("INSERT INTO chat_service VALUES (?, ?)", (service, chat_id))
        return chat_id

    def message(
        self,
        chat_id: int | None,
        *,
        service: str,
        handle_id: int,
        from_me: bool,
        text: str | None,
        body: bytes | None = None,
        associated: tuple[str, int] | None = None,
        item_type: int = 0,
        group_title: str | None = None,
        columns: dict[str, object] | None = None,
    ) -> tuple[int, str]:
        """Insert one message; ``columns`` sets any other ``message`` columns (replies, edits, unsends)."""
        date = self.tick()
        guid = self.guid()
        cur = self.conn.execute(
            "INSERT INTO message (guid, text, handle_id, service, attributedBody, date, date_delivered, "
            "is_delivered, is_finished, is_from_me, is_read, is_sent, associated_message_guid, "
            "associated_message_type, item_type, group_title, account) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, 1, 1, ?, 1, ?, ?, ?, ?, ?, 'E:owner@example.com')",
            (
                guid,
                text,
                0 if from_me else handle_id,
                service,
                body,
                date,
                date,
                int(from_me),
                int(from_me),
                associated[0] if associated else None,
                associated[1] if associated else 0,
                item_type,
                group_title,
            ),
        )
        rowid = int(cur.lastrowid or 0)
        if columns:
            assignments = ", ".join(f"{name} = ?" for name in columns)
            self.conn.execute(f"UPDATE message SET {assignments} WHERE ROWID = ?", (*columns.values(), rowid))
        if chat_id is not None:
            self.conn.execute("INSERT INTO chat_message_join VALUES (?, ?, ?)", (chat_id, rowid, date))
        return rowid, guid

    def attachment(self, message_id: int) -> None:
        guid = self.guid()
        cur = self.conn.execute(
            "INSERT INTO attachment (guid, filename, uti, mime_type, transfer_name, total_bytes, original_guid) "
            "VALUES (?, ?, 'public.jpeg', 'image/jpeg', 'IMG_0001.jpeg', 184320, ?)",
            (guid, f"~/Library/Messages/Attachments/00/00/{guid}/IMG_0001.jpeg", guid),
        )
        self.conn.execute("INSERT INTO message_attachment_join VALUES (?, ?)", (message_id, cur.lastrowid))
        self.conn.execute("UPDATE message SET cache_has_attachments = 1 WHERE ROWID = ?", (message_id,))


def _people(rng: random.Random, fake: Faker, count: int) -> list[Person]:
    numbers = [f"+1{area}55501{n:02d}" for area in AREA_CODES for n in range(100)]
    rng.shuffle(numbers)
    domains = ["example.com", "example.net", "example.org"]
    people: list[Person] = []
    for i in range(count):
        first, last = fake.unique.first_name(), fake.last_name()
        name = f"{first} {last}"
        kind = rng.random()
        phone = numbers[i] if kind < 0.85 else None
        local = "".join(ch for ch in f"{first}.{last}{i}".lower() if ch.isalnum() or ch == ".")
        email = f"{local}@{rng.choice(domains)}" if kind > 0.6 else None
        people.append(Person(name=name, phone=phone, email=email, person_id=f"person-{i:04d}"))
    return people


def _contacts_spelling(phone: str) -> str:
    """How Contacts tends to store a number: ``(206) 555-0142``."""
    digits = phone.removeprefix("+1")
    return f"({digits[:3]}) {digits[3:6]}-{digits[6:]}"


def build_messages_folder(
    folder: Path,
    *,
    seed: int = 0,
    people: int = 24,
    threads: int = 30,
    messages_per_thread: tuple[int, int] = (3, 14),
    start: datetime = datetime(2025, 1, 6, 9, tzinfo=UTC),
) -> FakeMessages:
    """Write ``folder/chat.db`` and ``folder/NickNameCache/`` and describe what went in."""
    rng = random.Random(seed)
    fake = Faker("en_US")
    fake.seed_instance(seed)

    def chatter() -> str:
        return rng.choice(LINES) if rng.random() < 0.3 else fake.sentence(nb_words=rng.randint(3, 12))

    folder.mkdir(parents=True, exist_ok=True)
    chat_db = folder / "chat.db"
    if chat_db.exists():
        chat_db.unlink()
    conn = sqlite3.connect(chat_db)
    conn.executescript(_schema(CHAT_DB_SCHEMA))
    conn.execute("INSERT INTO _SqliteDatabaseProperties VALUES ('_ClientVersion', '18000')")
    writer = _Writer(conn, rng, start)
    cast = _people(rng, fake, people)
    result = FakeMessages(folder=folder, chat_db=chat_db, people=cast, contacts=[], shared_names={})

    def say(chat_id: int | None, chat_guid: str, service: str, members: list[tuple[Person, int]]) -> None:
        count = rng.randint(*messages_per_thread)
        last_guid: str | None = None
        said: list[str] = []
        for _ in range(count):
            from_me = rng.random() < 0.4
            _speaker, handle_id = rng.choice(members)
            line = chatter()
            if rng.random() < 0.04:
                line += LONG_TAIL
            columns: dict[str, object] = {}
            if said and rng.random() < 0.1 and service == IMESSAGE:  # an inline reply
                columns["thread_originator_guid"] = columns["reply_to_guid"] = said[-1]
                columns["thread_originator_part"] = "0:0:10"
            if "https://" in line:
                columns["balloon_bundle_id"] = "com.apple.messages.URLBalloonProvider"
            if service == IMESSAGE and rng.random() < 0.05:  # edited a minute later
                columns["date_edited"] = apple_ns(writer.clock) + 60 * 10**9
            roll = rng.random()
            if roll < 0.04 and service == IMESSAGE:  # unsent: the text is gone from both columns
                when = apple_ns(writer.clock) + 60 * 10**9
                writer.message(
                    chat_id, service=service, handle_id=handle_id, from_me=True, text=None,
                    columns={"date_retracted": when, "date_edited": when},
                )  # fmt: skip
                continue
            if roll < 0.5:  # text only in attributedBody, as since Ventura
                rowid, last_guid = writer.message(
                    chat_id, service=service, handle_id=handle_id, from_me=from_me, text=None,
                    body=attributed_body(line), columns=columns,
                )  # fmt: skip
            elif roll < 0.7:
                rowid, last_guid = writer.message(
                    chat_id, service=service, handle_id=handle_id, from_me=from_me, text=line,
                    body=attributed_body(line), columns=columns,
                )  # fmt: skip
            elif roll < 0.85:  # text only in message.text, as before Ventura
                rowid, last_guid = writer.message(
                    chat_id, service=service, handle_id=handle_id, from_me=from_me, text=line, columns=columns
                )
            else:  # a photo with no caption: no text of its own
                rowid, _ = writer.message(
                    chat_id, service=service, handle_id=handle_id, from_me=from_me, text=OBJECT_REPLACEMENT
                )
                writer.attachment(rowid)
                continue
            said.append(last_guid)
            result.text_messages[chat_guid] = result.text_messages.get(chat_guid, 0) + 1
            if last_guid and rng.random() < 0.15:  # a tapback on it
                writer.message(
                    chat_id, service=service, handle_id=handle_id, from_me=not from_me,
                    text=f"Loved “{line}”", associated=(f"p:0/{last_guid}", rng.choice(TAPBACKS)),
                )  # fmt: skip

    for n in range(threads):
        kind = rng.random()
        if kind < 0.25:  # a group
            size = rng.randint(2, min(6, len(cast)))
            members = rng.sample(cast, size)
            service = IMESSAGE
            pairs = [(p, writer.handle(p.handles[0], service, p)) for p in members]
            named = rng.random() < 0.6
            display = f"{fake.city()} {rng.choice(GROUP_KINDS)}" if named else ""
            identifier = f"chat{rng.getrandbits(60)}"
            chat_id = writer.chat(
                identifier=identifier, service=service, group=True, display_name=display,
                handles=[h for _, h in pairs],
            )  # fmt: skip
            guid = f"{service};+;{identifier}"
            say(chat_id, guid, service, pairs)
            if size > 2 and rng.random() < 0.5:  # someone added a member: an event, not a message
                writer.message(
                    chat_id, service=service, handle_id=pairs[0][1], from_me=False, text=None,
                    item_type=ITEM_MEMBERSHIP, columns={"group_action_type": 0, "other_handle": pairs[-1][1]},
                )  # fmt: skip
            if named and rng.random() < 0.5:  # renamed once: an event, not a message
                writer.message(
                    chat_id, service=service, handle_id=pairs[0][1], from_me=False, text=None,
                    item_type=ITEM_GROUP_RENAME, group_title=display,
                )  # fmt: skip
        else:  # one-to-one
            person = cast[n % len(cast)]
            handle = rng.choice(person.handles)
            service = IMESSAGE if "@" in handle or kind < 0.75 else (SMS if kind < 0.93 else RCS)
            handle_id = writer.handle(handle, service, person)
            guid = f"{service};-;{handle}"
            if conn.execute("SELECT 1 FROM chat WHERE guid = ?", (guid,)).fetchone():
                continue
            chat_id = writer.chat(identifier=handle, service=service, group=False, display_name="", handles=[handle_id])
            say(chat_id, guid, service, [(person, handle_id)])
            if rng.random() < 0.2:  # older rows no chat_message_join names, left by sync
                for _ in range(rng.randint(1, 3)):
                    writer.message(None, service=service, handle_id=handle_id, from_me=False, text=chatter())
                    result.orphans += 1
                    # The reader files them under this, the one one-to-one chat with their handle.
                    result.text_messages[guid] = result.text_messages.get(guid, 0) + 1

    # Orphans the reader cannot place, and skips: one from an address with no one-to-one chat, one with
    # no handle at all.
    stranger = Person(name="Stranger", phone=None, email="stranger@example.org", person_id="person-stranger")
    writer.message(None, service=IMESSAGE, handle_id=writer.handle(stranger.email or "", IMESSAGE, stranger),
                   from_me=False, text=chatter())  # fmt: skip
    writer.message(None, service=SMS, handle_id=0, from_me=False, text=chatter())
    result.unplaced_orphans = 2

    # A chat whose only message is a photo: the reader yields nothing for it.
    lonely = cast[-1]
    handle_id = writer.handle(lonely.handles[0], SMS, lonely)
    lonely_guid = f"{SMS};-;{lonely.handles[0]}"
    if not conn.execute("SELECT 1 FROM chat WHERE guid = ?", (lonely_guid,)).fetchone():
        chat_id = writer.chat(
            identifier=lonely.handles[0], service=SMS, group=False, display_name="", handles=[handle_id]
        )
        rowid, _ = writer.message(chat_id, service=SMS, handle_id=handle_id, from_me=False, text=OBJECT_REPLACEMENT)
        writer.attachment(rowid)
        result.silent_chats.append(lonely_guid)
    conn.commit()
    conn.close()

    # Contacts knows about two thirds of the cast, in its own spelling; the rest may have shared a name.
    for person in cast:
        roll = rng.random()
        if roll < 0.65:
            if person.phone:
                result.contacts.append((_contacts_spelling(person.phone), person.name))
            if person.email:
                result.contacts.append((person.email, person.name))
            if roll < 0.1:  # also shared a name, a different one: Contacts must win
                result.shared_names[person.handles[0]] = person.name.split(" ")[0] + " 🌟"
        elif roll < 0.85:
            for handle in person.handles:
                result.shared_names[handle] = person.name
    _write_nicknames(folder, result.shared_names, rng)
    return result


def _write_nicknames(folder: Path, shared: dict[str, str], rng: random.Random) -> None:
    cache = folder / "NickNameCache"
    cache.mkdir(exist_ok=True)
    schema = _schema(NICKNAME_SCHEMA)
    handled = sqlite3.connect(cache / "handledNicknamesKeyStore.db")
    handled.executescript(schema)
    pending = sqlite3.connect(cache / "pendingNicknamesKeyStore.db")
    pending.executescript(schema)
    for handle, name in shared.items():
        first, _, last = name.partition(" ")
        handled.execute(
            "INSERT INTO kvtable (key, value) VALUES (?, ?)",
            (handle, keyed_archive({"firstName": first, "lastName": last})),
        )
        if rng.random() < 0.3:  # an update not yet accepted: the handled name must win
            pending.execute(
                "INSERT INTO kvtable (key, value) VALUES (?, ?)",
                (handle, keyed_archive({"firstName": "Pending", "lastName": first})),
            )
    for conn in (handled, pending):
        conn.commit()
        conn.close()


def main() -> None:
    parser = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[0])
    parser.add_argument("folder", type=Path, help="where to write chat.db and NickNameCache/")
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--people", type=int, default=24)
    parser.add_argument("--threads", type=int, default=30)
    args = parser.parse_args()
    fake = build_messages_folder(args.folder, seed=args.seed, people=args.people, threads=args.threads)
    print(
        f"{fake.chat_db}: {len(fake.people)} people, {len(fake.text_messages)} threads with text, "
        f"{sum(fake.text_messages.values())} messages with text, {fake.orphans} orphans, "
        f"{len(fake.contacts)} contact handles, {len(fake.shared_names)} shared names"
    )


if __name__ == "__main__":
    main()

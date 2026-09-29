"""Potential facts read straight from a document's metadata, with no model.

A mail's sender, recipients and subject, and a Messages thread's participants,
are ground truth: nothing has to be inferred to know them. ``garage
enrich-facts`` writes them as potential facts like any prompt's
(``facts.extractor = 'metadata'``, ``prompt_name = 'metadata'``), each with its
value's exact key in ``attributes['key']``:

=============  ==========================================  ==================================
``sender``     a mail's From, a thread's participants       ``author:<id>``, else ``email:<address>``
               who wrote in it
``recipient``  a mail's To and Cc, a thread's other         as above
               participants
``subject``    a mail's Subject                             ``subject:<normalized subject>``
=============  ==========================================  ==================================

A person resolves to their ``authors`` row when an identity matches, so one
person is one key whichever address they wrote from. ``garage cluster-facts``
makes each distinct key an anchored distilled fact whose centroid is fixed
(``data/sql/018_fact_anchors.sql``, :mod:`garage_rag.enrich.clusters`).

Each fact quotes its value as the document states it and, where the text
carries it (a mail's header block), is grounded on that span. Its chunk is
embedded by the ordinary backfill. Nothing here leaves the machine.
"""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass, field
from email.utils import formataddr, getaddresses

from sqlalchemy import func, text
from sqlalchemy.orm import Session

from garage_rag.db.models import Chunk, Document, Fact, FactRun

PROMPT_NAME = "metadata"
EXTRACTOR = "metadata"
# Bumped when what is read, or how it is keyed, changes: every document is read again.
VERSION = "1"
PROMPT_SHA256 = hashlib.sha256(f"metadata:{VERSION}".encode()).digest()
CHUNKER = f"facts:metadata:{VERSION}"

FACT_CLASSES = ("sender", "recipient", "subject")

# "Re:", "Fwd:", "AW:", "[External]" and the like, repeated, at the start of a subject.
_SUBJECT_PREFIX = re.compile(r"^\s*(?:(?:re|fw|fwd|aw|sv|vs|wg|antw)\s*(?:\[\d+\])?\s*:|\[[^\]]*\])\s*", re.IGNORECASE)
_SPACE = re.compile(r"\s+")


@dataclass(frozen=True)
class MetadataFact:
    fact_class: str
    text: str
    key: str
    char_start: int | None = None
    char_end: int | None = None
    attributes: dict[str, str] = field(default_factory=dict)


def normalize_subject(subject: str) -> str:
    """A subject's exact key: reply and forward prefixes stripped, casefolded, spaces collapsed."""
    previous = None
    value = subject
    while previous != value:
        previous = value
        value = _SUBJECT_PREFIX.sub("", value, count=1)
    return _SPACE.sub(" ", value).strip().casefold()


def _span(content: str, value: str, start: int, end: int) -> tuple[int | None, int | None]:
    """Where ``value`` appears in ``content[start:end]``, or no span."""
    if not value:
        return None, None
    at = content.find(value, start, end)
    return (at, at + len(value)) if at >= 0 else (None, None)


def _header_line(content: str, label: str) -> tuple[int, int]:
    """The bounds of the value of a mail's ``label:`` header line, or an empty range."""
    header_end = content.find("\n\n")
    header_end = len(content) if header_end < 0 else header_end
    prefix = f"{label}: "
    if content.startswith(prefix):
        at = 0
    else:
        at = content.find("\n" + prefix, 0, header_end)
        if at < 0:
            return 0, 0
        at += 1
    line_end = content.find("\n", at, header_end)
    return at + len(prefix), header_end if line_end < 0 else line_end


def mail_facts(content: str, meta: dict, author_of: dict[str, int]) -> list[MetadataFact]:
    """A mail's sender, recipients and subject. ``author_of`` maps a lowercased address to its author."""
    facts: list[MetadataFact] = []
    seen: set[tuple[str, str]] = set()
    for fact_class, label, headers in (
        ("sender", "From", [meta.get("email_from")]),
        ("recipient", "To", [meta.get("email_to")]),
        ("recipient", "Cc", [meta.get("email_cc")]),
    ):
        start, end = _header_line(content, label)
        for name, address in getaddresses([h for h in headers if h]):
            address = address.strip()
            if "@" not in address:
                continue
            lowered = address.lower()
            author = author_of.get(lowered)
            key = f"author:{author}" if author is not None else f"email:{lowered}"
            if (fact_class, key) in seen:
                continue
            seen.add((fact_class, key))
            quoted = formataddr((name, address)) if name else address
            span = _span(content, quoted, start, end)
            if span[0] is None:
                quoted = address
                span = _span(content, address, start, end)
            attributes = {"key": key, "address": lowered, "header": label.lower()}
            if name:
                attributes["name"] = name
            facts.append(MetadataFact(fact_class, quoted, key, *span, attributes=attributes))

    # Only a stated subject: without one, the title is the file's name.
    start, end = _header_line(content, "Subject")
    subject = content[start:end].strip()
    key = normalize_subject(subject)
    if key:
        span = _span(content, subject, start, end)
        facts.append(MetadataFact("subject", subject, f"subject:{key}", *span, attributes={"key": f"subject:{key}"}))
    return facts


def conversation_facts(content: str, participants: list[tuple[int, str, str]]) -> list[MetadataFact]:
    """A thread's participants, each ``(author_id, display_name, role)`` with role ``sender`` or ``recipient``."""
    facts: list[MetadataFact] = []
    for author_id, name, role in participants:
        if role not in ("sender", "recipient") or not name:
            continue
        key = f"author:{author_id}"
        span = _span(content, name, 0, len(content))
        facts.append(MetadataFact(role, name, key, *span, attributes={"key": key}))
    return facts


def has_metadata(document: Document) -> bool:
    """Whether ``document`` is a mail or a Messages thread, the documents with metadata facts."""
    meta = document.meta or {}
    return "email_from" in meta or "chat_guid" in meta


def document_facts(session: Session, document: Document) -> list[MetadataFact]:
    """The metadata facts of ``document``: a mail's or a Messages thread's; none for anything else."""
    meta = document.meta or {}
    content = document.content or ""
    if "email_from" in meta:
        addresses = [
            address.lower()
            for _, address in getaddresses([meta.get(k) or "" for k in ("email_from", "email_to", "email_cc")])
            if "@" in address
        ]
        author_of = {
            value: int(author)
            for value, author in session.execute(
                text(
                    "SELECT lower(value), author_id FROM author_identities"
                    " WHERE kind = 'email' AND lower(value) = ANY(CAST(:addresses AS text[]))"
                ),
                {"addresses": addresses},
            ).all()
        }
        return mail_facts(content, meta, author_of)
    if "chat_guid" in meta:
        participants = [
            (int(author), name, role)
            for author, name, role in session.execute(
                text(
                    "SELECT a.id, a.display_name, da.role::text FROM document_authors da"
                    " JOIN authors a ON a.id = da.author_id"
                    " WHERE da.document_id = :id AND da.role IN ('sender', 'recipient') ORDER BY da.role, a.id"
                ),
                {"id": document.id},
            ).all()
        ]
        return conversation_facts(content, participants)
    return []


def is_stale(run: FactRun | None, document: Document) -> bool:
    """Whether ``document``'s metadata facts need writing (again)."""
    if not has_metadata(document):
        return False
    return (
        run is None
        or bytes(run.prompt_sha256) != PROMPT_SHA256
        or bytes(run.content_sha256) != bytes(document.content_sha256 or b"")
    )


def store_metadata_facts(session: Session, document: Document) -> list[Fact]:
    """Replace ``document``'s metadata facts, each with a chunk for the backfill to embed.

    Like a prompt's run: the document's earlier metadata facts are deleted
    (their chunks and vectors cascade), and the run is recorded in
    ``fact_runs`` under the ``metadata`` prompt name.
    """
    session.query(Fact).filter(Fact.document_id == document.id, Fact.prompt_name == PROMPT_NAME).delete()
    if not has_metadata(document):
        return []
    facts = [
        Fact(
            document_id=document.id,
            ord=ord_,
            fact=found.text,
            fact_class=found.fact_class,
            attributes=found.attributes,
            char_start=found.char_start,
            char_end=found.char_end,
            extractor=EXTRACTOR,
            extractor_model=None,
            prompt_name=PROMPT_NAME,
            prompt_sha256=PROMPT_SHA256,
        )
        for ord_, found in enumerate(document_facts(session, document))
    ]
    session.add_all(facts)
    session.merge(
        FactRun(
            document_id=document.id,
            prompt_name=PROMPT_NAME,
            prompt_sha256=PROMPT_SHA256,
            content_sha256=document.content_sha256 or b"",
            extractor_model=EXTRACTOR,
            facts=len(facts),
            extracted_at=func.now(),
        )
    )
    if facts:
        session.flush()
        base_ord = (
            session.query(func.coalesce(func.max(Chunk.ord), -1)).filter(Chunk.document_id == document.id).scalar() + 1
        )
        session.add_all(
            Chunk(
                document_id=document.id,
                ord=base_ord + i,
                text=fact.fact,
                chunk_sha256=hashlib.sha256(fact.fact.encode("utf-8")).digest(),
                chunker=CHUNKER,
                fact_id=fact.id,
            )
            for i, fact in enumerate(facts)
        )
    return facts

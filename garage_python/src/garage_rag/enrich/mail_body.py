"""The text a fact prompt reads: a mail's body without its header lines.

A mail's sender, recipients and subject are ground truth, written as metadata
facts with no model (:mod:`garage_rag.enrich.metadata`). A prompt reading them
again would only restate them as inferred facts, so the model reads the body
alone:

* the header block ``extract/mail.py`` puts first (Subject, From, To, Cc, Date,
  Attachments) is dropped;
* so are the headers of mail quoted or forwarded inside the body: a run of two
  or more ``From:``/``Sent:``/``To:``/``Subject:`` lines (quoted with ``>`` or
  not), the separators above them (``-----Original Message-----``,
  ``---------- Forwarded message ---------``, ``Begin forwarded message:``) and
  a reply's ``On <date>, <someone> wrote:`` line.

The quoted text itself stays: it is what someone wrote. Every other document is
read whole.

What is kept stays in document order, and :meth:`FactSource.to_document` maps
a position in it back into ``documents.content``, so a fact is still grounded
on the document's own text.
"""

from __future__ import annotations

import bisect
import hashlib
import re
from dataclasses import dataclass

from garage_rag.db.models import Document

# Bumped when what is dropped changes: every mail's prompts run again (see ``sha256``).
VERSION = "1"

_TOP_HEADER = re.compile(r"^(?:Subject|From|To|Cc|Date|Attachments): ")
_QUOTE = re.compile(r"^(?:\s*>)*\s*")
_QUOTED_HEADER = re.compile(r"^\*?(?:From|Sent|Date|To|Cc|Bcc|Subject|Reply-To)\*?:\s", re.IGNORECASE)
_SEPARATOR = re.compile(
    r"^-{2,}\s*(?:Original Message|Forwarded message)\s*-{2,}\s*$|^Begin forwarded message:\s*$",
    re.IGNORECASE,
)
_WROTE = re.compile(r"^On\b.{0,200}\bwrote:\s*$", re.IGNORECASE)


def is_mail(document: Document) -> bool:
    """Whether ``document`` is a mail message, whose header lines are metadata."""
    return "email_from" in (document.meta or {})


@dataclass(frozen=True)
class FactSource:
    """The text a prompt reads, with the ``documents.content`` offset of each kept span."""

    text: str
    # (offset in ``text``, offset in the document) at the start of each kept span.
    spans: tuple[tuple[int, int], ...]
    sha256: bytes

    def to_document(self, position: int) -> int:
        """The offset in ``documents.content`` of ``position`` in :attr:`text`."""
        at = bisect.bisect_right([start for start, _ in self.spans], position) - 1
        if at < 0:
            return position
        start, document_start = self.spans[at]
        return document_start + position - start

    def span_to_document(self, start: int | None, end: int | None) -> tuple[int | None, int | None]:
        """A ``[start, end)`` span of :attr:`text` as a span of ``documents.content``."""
        if start is None or end is None:
            return start, end
        document_start = self.to_document(start)
        # The end maps through its last character, so a span ending at a cut stays inside its own text.
        document_end = self.to_document(end - 1) + 1 if end > start else document_start
        return document_start, document_end


def _lines(content: str) -> list[tuple[int, int]]:
    """``(start, end)`` of every line of ``content``, the newline included."""
    bounds: list[tuple[int, int]] = []
    start = 0
    while start < len(content):
        newline = content.find("\n", start)
        end = len(content) if newline < 0 else newline + 1
        bounds.append((start, end))
        start = end
    return bounds


def _body_start(content: str, lines: list[tuple[int, int]]) -> int:
    """The index of the first body line: past the leading header block and its blank line."""
    index = 0
    while index < len(lines) and _TOP_HEADER.match(content[lines[index][0] : lines[index][1]]):
        index += 1
    if index == 0:
        return 0
    while index < len(lines) and not content[lines[index][0] : lines[index][1]].strip():
        index += 1
    return index


def _dropped_lines(content: str, lines: list[tuple[int, int]]) -> set[int]:
    """The indexes of the header lines of a mail: its own and those quoted in its body."""
    body = _body_start(content, lines)
    dropped = set(range(body))
    texts = [_QUOTE.sub("", content[start:end]).rstrip() for start, end in lines]
    index = body
    while index < len(lines):
        text = texts[index]
        if _SEPARATOR.match(text) or _WROTE.match(text):
            dropped.add(index)
        elif index + 1 < len(lines) and text.startswith("On ") and _WROTE.match(f"{text} {texts[index + 1]}"):
            # A client wrapped the attribution line.
            dropped.update((index, index + 1))
            index += 1
        elif _QUOTED_HEADER.match(text):
            run = index
            while run < len(lines) and _QUOTED_HEADER.match(texts[run]):
                run += 1
            if run - index >= 2:
                dropped.update(range(index, run))
                index = run
                continue
        index += 1
    return dropped


def fact_source(document: Document) -> FactSource:
    """What a prompt reads of ``document``: a mail's body without header lines, else the whole text."""
    content = document.content or ""
    if not is_mail(document):
        return FactSource(content, ((0, 0),), bytes(document.content_sha256 or b""))
    lines = _lines(content)
    dropped = _dropped_lines(content, lines)
    parts: list[str] = []
    spans: list[tuple[int, int]] = []
    length = 0
    for index, (start, end) in enumerate(lines):
        if index in dropped:
            continue
        if spans and parts and spans[-1][1] + len(parts[-1]) == start:
            parts[-1] += content[start:end]  # contiguous with the kept span before it
        else:
            spans.append((length, start))
            parts.append(content[start:end])
        length += end - start
    text = "".join(parts)
    return FactSource(text, tuple(spans), hashlib.sha256(f"mail-body:{VERSION}\n{text}".encode()).digest())


__all__ = ["VERSION", "FactSource", "fact_source", "is_mail"]

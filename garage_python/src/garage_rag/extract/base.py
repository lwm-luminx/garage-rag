"""Extraction result types and shared helpers.

An extractor turns a file into plain text plus whatever metadata it learned on
the way (PDF ``/Author``, Markdown frontmatter, EXIF). That metadata feeds
attribution, so extractors record what they find rather than discarding it.
"""

from __future__ import annotations

import hashlib
import unicodedata
from dataclasses import dataclass, field
from enum import StrEnum
from pathlib import Path


class ContentKind(StrEnum):
    """How the text should be chunked, which is not the same as its MIME type."""

    PROSE = "prose"
    MARKDOWN = "markdown"
    CODE = "code"
    TABULAR = "tabular"
    CONVERSATION = "conversation"
    # A picture with no text worth indexing: one chunk, for image embedding models.
    IMAGE = "image"


@dataclass
class ExtractResult:
    """Text plus provenance for one document."""

    text: str
    kind: ContentKind
    extractor: str
    extractor_version: str = "1"
    title: str | None = None
    lang: str | None = None
    # Free-form provenance: pdf_author, page_count, ocr_confidence, language...
    meta: dict = field(default_factory=dict)
    # Populated by extractors that discover authorship (PDF metadata,
    # frontmatter). The resolver treats these as candidate evidence.
    author_hints: list[str] = field(default_factory=list)

    @property
    def is_empty(self) -> bool:
        return not self.text.strip()


class ExtractionError(Exception):
    """Raised when a file cannot be turned into text."""


class UnsupportedFile(ExtractionError):
    """The file type has no registered extractor."""


class NoTextFound(ExtractionError):
    """The file was read without trouble and holds no text: an empty file, one whose text
    is all whitespace, an icon or a photo.

    An outcome, not a failure: the pipeline records the file as rejected rather
    than as an extraction error.
    """


def normalize_text(raw: str) -> str:
    """Canonicalize extracted text.

    NFC because macOS filesystems hand back NFD, which would otherwise make
    identical content hash differently depending on where it came from. Also
    strips NULs, which Postgres ``text`` columns reject outright, and normalizes
    line endings so chunk boundaries do not shift with a file's provenance.
    """
    if not raw:
        return ""
    text = unicodedata.normalize("NFC", raw)
    text = text.replace("\x00", "")
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    # Collapse runs of blank lines; PDF extraction is especially prone to these.
    lines = [line.rstrip() for line in text.split("\n")]
    out: list[str] = []
    blanks = 0
    for line in lines:
        if line:
            blanks = 0
            out.append(line)
        else:
            blanks += 1
            if blanks <= 2:
                out.append("")
    return "\n".join(out).strip()


def sha256_text(text: str) -> bytes:
    return hashlib.sha256(text.encode("utf-8")).digest()


def file_sha256(path: Path, *, chunk_size: int = 1 << 20) -> bytes:
    """Hash a file without loading it entirely into memory."""
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while block := handle.read(chunk_size):
            digest.update(block)
    return digest.digest()


# Software that writes its own name into document author metadata. Without this
# filter, python-pptx's default template attributes every deck to its library
# author, and openpyxl attributes every spreadsheet to "openpyxl".
_TOOL_NAME_TOKENS: tuple[str, ...] = (
    "acrobat",
    "microsoft word",
    "microsoft excel",
    "microsoft powerpoint",
    "latex",
    "pdftex",
    "pdflatex",
    "xetex",
    "ghostscript",
    "quartz",
    "openpyxl",
    "python-pptx",
    "python-docx",
    "steve canny",
    "libreoffice",
    "openoffice",
    "pages",
    "keynote",
    "numbers",
    "wkhtmltopdf",
    "reportlab",
    "tcpdf",
    "fpdf",
    "word for",
    "excel for",
    "adobe",
    "indesign",
    "illustrator",
    "photoshop",
    "canva",
    "google docs",
    "unknown",
    "user",
    "admin",
    "administrator",
    "owner",
)


def looks_like_tool_name(value: str) -> bool:
    """Whether an author-metadata value names software rather than a person.

    Document producers routinely stuff their own name into ``/Author`` or the
    Office core properties. Attributing documents to them would populate the
    author graph with libraries.
    """
    lowered = value.strip().lower()
    if not lowered or len(lowered) < 3:
        return True
    return any(token in lowered for token in _TOOL_NAME_TOKENS)


def clean_author_hints(values: list[str]) -> list[str]:
    """Drop tool names and duplicates from candidate author strings."""
    seen: set[str] = set()
    out: list[str] = []
    for raw in values:
        candidate = raw.strip()
        if not candidate or looks_like_tool_name(candidate):
            continue
        key = candidate.lower()
        if key in seen:
            continue
        seen.add(key)
        out.append(candidate[:200])
    return out


def guess_title(path: Path, text: str, *, kind: ContentKind) -> str | None:
    """Best-effort document title.

    A Markdown H1 or the first substantial line beats the filename, which is
    often a slug or an export timestamp.
    """
    if kind is ContentKind.MARKDOWN:
        for line in text.split("\n", 40)[:40]:
            stripped = line.strip()
            if stripped.startswith("# "):
                return stripped[2:].strip() or None

    for line in text.split("\n", 10)[:10]:
        stripped = line.strip()
        if 3 <= len(stripped) <= 200:
            return stripped

    return path.stem or None

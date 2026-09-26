"""Chunking, specialized per content kind.

The strategies differ because the failure modes differ:

* **Markdown** -- split on headers first so a chunk never straddles two
  sections, then split oversized sections by size. Each chunk keeps its heading
  breadcrumb, which is often the only thing identifying what the text is about.
* **Code** -- language-aware splitting keeps functions and classes intact.
* **Prose / PDF** -- plain recursive splitting on paragraph boundaries.
* **Tabular** -- split on sheet headings, never mid-row.
* **Conversation** -- a Messages thread never reaches here:
  :mod:`garage_rag.ingest.conversations` makes one chunk per message itself.

The splitters themselves live in :mod:`garage_rag.ingest.splitters`, a small
dependency-free port of the langchain-text-splitters behaviour this module was
first written against; ``tests/test_chunking_golden.py`` pins the output to it.
"""

from __future__ import annotations

import hashlib
import logging
from dataclasses import dataclass

from garage_rag.config import get_settings
from garage_rag.extract.base import ContentKind
from garage_rag.ingest.splitters import MarkdownHeaderSplitter, RecursiveSplitter

log = logging.getLogger(__name__)

# Headers to split on, and the metadata key each maps to.
_MD_HEADERS = [("#", "h1"), ("##", "h2"), ("###", "h3")]

# Extension -> separator table (splitters.LANGUAGE_SEPARATORS) for structure-aware
# code splitting. Everything else falls back to recursive character splitting,
# which is still reasonable for code. Perl has no table and is not listed.
_CODE_LANGUAGES: dict[str, str] = {
    ".py": "python",
    ".pyi": "python",
    ".js": "js",
    ".jsx": "js",
    ".mjs": "js",
    ".cjs": "js",
    ".ts": "ts",
    ".tsx": "ts",
    ".c": "c",
    ".h": "c",
    ".cc": "cpp",
    ".cpp": "cpp",
    ".cxx": "cpp",
    ".hpp": "cpp",
    ".hh": "cpp",
    ".go": "go",
    ".rs": "rust",
    ".rb": "ruby",
    ".php": "php",
    ".java": "java",
    ".kt": "kotlin",
    ".scala": "scala",
    ".swift": "swift",
    ".cs": "csharp",
    ".lua": "lua",
    ".hs": "haskell",
    ".ex": "elixir",
    ".exs": "elixir",
    ".html": "html",
    ".htm": "html",
    ".tex": "latex",
    ".sol": "sol",
    ".cob": "cobol",
}


@dataclass
class TextChunk:
    """One embeddable unit."""

    ord: int
    text: str
    chunker: str
    heading_path: str | None = None
    # Span of the chunked text (documents.content), [char_start, char_end). Usually
    # the chunk's exact text; for markdown, whose header splitter drops blank lines,
    # the span from its first to its last line. None if those cannot be found.
    char_start: int | None = None
    char_end: int | None = None

    @property
    def sha256(self) -> bytes:
        return hashlib.sha256(self.text.encode("utf-8")).digest()

    @property
    def token_estimate(self) -> int:
        """Rough token count.

        Deliberately an estimate: loading a real tokenizer per worker process
        costs more than this number is worth, and it is only used for reporting
        and for capping embedding batch payloads.
        """
        return max(1, len(self.text) // 4)


def _recursive_splitter(size: int, overlap: int) -> RecursiveSplitter:
    return RecursiveSplitter(
        chunk_size=size,
        chunk_overlap=overlap,
        # Prefer paragraph, then line, then sentence, then word boundaries.
        separators=["\n\n", "\n", ". ", "! ", "? ", "; ", ", ", " ", ""],
    )


def _heading_path(metadata: dict) -> str | None:
    parts = [metadata[key] for key in ("h1", "h2", "h3") if metadata.get(key)]
    return " > ".join(parts) if parts else None


def chunk_markdown(text: str, *, size: int, overlap: int) -> list[TextChunk]:
    """Header split, then size split, preserving heading breadcrumbs."""
    header_splitter = MarkdownHeaderSplitter(_MD_HEADERS)
    size_splitter = _recursive_splitter(size, overlap)

    try:
        sections = header_splitter.split_text(text)
    except Exception as exc:  # noqa: BLE001 - malformed markdown is still text
        log.debug("markdown header split failed, falling back to recursive: %s", exc)
        return chunk_prose(text, size=size, overlap=overlap)

    chunks: list[TextChunk] = []
    for section in sections:
        heading = _heading_path(section.metadata)
        body = section.content
        pieces = size_splitter.split_text(body) if len(body) > size else [body]
        for piece in pieces:
            if piece.strip():
                chunks.append(
                    TextChunk(
                        ord=len(chunks),
                        text=piece.strip(),
                        chunker=f"markdown-header+recursive/v2:{size}/{overlap}",
                        heading_path=heading,
                    )
                )

    if not chunks:
        return chunk_prose(text, size=size, overlap=overlap)
    return chunks


def chunk_prose(text: str, *, size: int, overlap: int) -> list[TextChunk]:
    splitter = _recursive_splitter(size, overlap)
    return [
        TextChunk(ord=index, text=piece.strip(), chunker=f"recursive:{size}/{overlap}")
        for index, piece in enumerate(splitter.split_text(text))
        if piece.strip()
    ]


def chunk_code(text: str, *, extension: str, size: int, overlap: int) -> list[TextChunk]:
    """Language-aware where a separator table exists, recursive otherwise."""
    language = _CODE_LANGUAGES.get(extension.lower())
    if language is not None:
        splitter = RecursiveSplitter.for_language(language, chunk_size=size, chunk_overlap=overlap)
        label = f"code:{language}:{size}/{overlap}"
    else:
        splitter = _recursive_splitter(size, overlap)
        label = f"recursive:{size}/{overlap}"

    return [
        TextChunk(ord=index, text=piece, chunker=label)
        for index, piece in enumerate(splitter.split_text(text))
        if piece.strip()
    ]


def chunk_tabular(text: str, *, size: int) -> list[TextChunk]:
    """Split spreadsheet text on sheet headings and row boundaries.

    Zero overlap and a newline-first separator list: repeating rows across chunks
    adds noise, and a chunk boundary mid-row produces meaningless fragments.
    """
    splitter = RecursiveSplitter(chunk_size=size, chunk_overlap=0, separators=["\n## ", "\n\n", "\n", " "])
    chunks: list[TextChunk] = []
    for piece in splitter.split_text(text):
        stripped = piece.strip()
        if not stripped:
            continue
        heading = None
        if stripped.startswith("## "):
            heading = stripped.split("\n", 1)[0][3:].strip() or None
        chunks.append(
            TextChunk(
                ord=len(chunks),
                text=stripped,
                chunker=f"tabular:{size}",
                heading_path=heading,
            )
        )
    return chunks


def _span(source: str, text: str, cursor: int) -> tuple[int, int] | None:
    """Where ``text`` sits in ``source`` at or after ``cursor``.

    The exact text first; failing that, from its first line to its last, which
    covers a chunk whose splitter dropped the blank lines in between. Each line is
    looked for after the one before it, so a last line that also appears earlier
    in the chunk (a closing code fence) ends the span where the chunk ends.
    """
    start = source.find(text, cursor)
    if start >= 0:
        return start, start + len(text)
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    if not lines:
        return None
    start = source.find(lines[0], cursor)
    if start < 0:
        return None
    end = start + len(lines[0])
    for line in lines[1:]:
        at = source.find(line, end)
        if at < 0:
            return None
        end = at + len(line)
    return start, end


def _locate(source: str, chunks: list[TextChunk]) -> list[TextChunk]:
    """Set each chunk's offsets to where it sits in ``source``.

    Chunks come out in document order and may overlap, so each search starts one
    character past the previous chunk's start. A chunk that cannot be found keeps
    ``None`` rather than a guessed offset.
    """
    cursor = 0
    for chunk in chunks:
        span = _span(source, chunk.text, cursor)
        if span is None:
            continue
        chunk.char_start, chunk.char_end = span
        cursor = span[0] + 1
    return chunks


def chunk_text(
    text: str,
    kind: ContentKind,
    *,
    extension: str = "",
    size: int | None = None,
    overlap: int | None = None,
) -> list[TextChunk]:
    """Chunk ``text`` according to its :class:`ContentKind`."""
    settings = get_settings()

    if kind is ContentKind.CODE:
        size = size or settings.code_chunk_size
        overlap = overlap if overlap is not None else settings.code_chunk_overlap
        return _locate(text, chunk_code(text, extension=extension, size=size, overlap=overlap))

    size = size or settings.chunk_size
    overlap = overlap if overlap is not None else settings.chunk_overlap

    if kind is ContentKind.MARKDOWN:
        chunks = chunk_markdown(text, size=size, overlap=overlap)
    elif kind is ContentKind.TABULAR:
        chunks = chunk_tabular(text, size=size)
    else:
        # CONVERSATION text arrives pre-windowed; treat the windows as prose.
        chunks = chunk_prose(text, size=size, overlap=overlap)
    return _locate(text, chunks)

"""Dependency-free text splitters.

A minimal reimplementation of the parts of langchain-text-splitters that
:mod:`garage_rag.ingest.chunking` used: the recursive character splitter, its
per-language separator tables, and the markdown header splitter. Their output is
pinned to langchain's by ``tests/test_chunking_golden.py``, so chunks (and their
``chunks.chunker`` ids) are the same as before the swap and a re-ingest rebuilds
nothing.

The algorithms, including their quirks, follow langchain-text-splitters
(MIT License, Copyright (c) LangChain, Inc.). The language tables are regular
expressions, exactly as langchain applies them: ``"$"`` in the LaTeX table is an
end-of-text anchor and ``"\\n| "`` in the Haskell table is an alternation. Fixing
either would change the chunks, and so the chunker ids.
"""

from __future__ import annotations

import logging
import re
from collections.abc import Iterable
from dataclasses import dataclass, field

log = logging.getLogger(__name__)

# Separator tables, keyed by the language name recorded in the chunker id
# (``code:<language>:<size>/<overlap>``). Each entry is a regular expression.
_C_FAMILY = [
    "\nclass ", "\nvoid ", "\nint ", "\nfloat ", "\ndouble ",
    "\nif ", "\nfor ", "\nwhile ", "\nswitch ", "\ncase ",
    "\n\n", "\n", " ", "",
]  # fmt: skip

LANGUAGE_SEPARATORS: dict[str, list[str]] = {
    "python": ["\nclass ", "\ndef ", "\n\tdef ", "\n\n", "\n", " ", ""],
    "js": [
        "\nfunction ", "\nconst ", "\nlet ", "\nvar ", "\nclass ",
        "\nif ", "\nfor ", "\nwhile ", "\nswitch ", "\ncase ", "\ndefault ",
        "\n\n", "\n", " ", "",
    ],
    "ts": [
        "\nenum ", "\ninterface ", "\nnamespace ", "\ntype ", "\nclass ", "\nfunction ",
        "\nconst ", "\nlet ", "\nvar ",
        "\nif ", "\nfor ", "\nwhile ", "\nswitch ", "\ncase ", "\ndefault ",
        "\n\n", "\n", " ", "",
    ],
    "c": _C_FAMILY,
    "cpp": _C_FAMILY,
    "go": [
        "\nfunc ", "\nvar ", "\nconst ", "\ntype ",
        "\nif ", "\nfor ", "\nswitch ", "\ncase ",
        "\n\n", "\n", " ", "",
    ],
    "rust": [
        "\nfn ", "\nconst ", "\nlet ",
        "\nif ", "\nwhile ", "\nfor ", "\nloop ", "\nmatch ", "\nconst ",
        "\n\n", "\n", " ", "",
    ],
    "ruby": [
        "\ndef ", "\nclass ",
        "\nif ", "\nunless ", "\nwhile ", "\nfor ", "\ndo ", "\nbegin ", "\nrescue ",
        "\n\n", "\n", " ", "",
    ],
    "php": [
        "\nfunction ", "\nclass ",
        "\nif ", "\nforeach ", "\nwhile ", "\ndo ", "\nswitch ", "\ncase ",
        "\n\n", "\n", " ", "",
    ],
    "java": [
        "\nclass ", "\npublic ", "\nprotected ", "\nprivate ", "\nstatic ",
        "\nif ", "\nfor ", "\nwhile ", "\nswitch ", "\ncase ",
        "\n\n", "\n", " ", "",
    ],
    "kotlin": [
        "\nclass ", "\npublic ", "\nprotected ", "\nprivate ", "\ninternal ", "\ncompanion ",
        "\nfun ", "\nval ", "\nvar ",
        "\nif ", "\nfor ", "\nwhile ", "\nwhen ", "\ncase ", "\nelse ",
        "\n\n", "\n", " ", "",
    ],
    "scala": [
        "\nclass ", "\nobject ", "\ndef ", "\nval ", "\nvar ",
        "\nif ", "\nfor ", "\nwhile ", "\nmatch ", "\ncase ",
        "\n\n", "\n", " ", "",
    ],
    "swift": [
        "\nfunc ", "\nclass ", "\nstruct ", "\nenum ",
        "\nif ", "\nfor ", "\nwhile ", "\ndo ", "\nswitch ", "\ncase ",
        "\n\n", "\n", " ", "",
    ],
    "csharp": [
        "\ninterface ", "\nenum ", "\nimplements ", "\ndelegate ", "\nevent ",
        "\nclass ", "\nabstract ",
        "\npublic ", "\nprotected ", "\nprivate ", "\nstatic ", "\nreturn ",
        "\nif ", "\ncontinue ", "\nfor ", "\nforeach ", "\nwhile ", "\nswitch ", "\nbreak ", "\ncase ", "\nelse ",
        "\ntry ", "\nthrow ", "\nfinally ", "\ncatch ",
        "\n\n", "\n", " ", "",
    ],
    "lua": ["\nlocal ", "\nfunction ", "\nif ", "\nfor ", "\nwhile ", "\nrepeat ", "\n\n", "\n", " ", ""],
    "haskell": [
        "\nmain :: ", "\nmain = ", "\nlet ", "\nin ", "\ndo ", "\nwhere ", "\n:: ", "\n= ",
        "\ndata ", "\nnewtype ", "\ntype ", "\n:: ",
        "\nmodule ", "\nimport ", "\nqualified ", "\nimport qualified ",
        "\nclass ", "\ninstance ", "\ncase ", "\n| ", "\ndata ", "\n= {", "\n, ",
        "\n\n", "\n", " ", "",
    ],
    "elixir": [
        "\ndef ", "\ndefp ", "\ndefmodule ", "\ndefprotocol ", "\ndefmacro ", "\ndefmacrop ",
        "\nif ", "\nunless ", "\nwhile ", "\ncase ", "\ncond ", "\nwith ", "\nfor ", "\ndo ",
        "\n\n", "\n", " ", "",
    ],
    "html": [
        "<body", "<div", "<p", "<br", "<li",
        "<h1", "<h2", "<h3", "<h4", "<h5", "<h6",
        "<span", "<table", "<tr", "<td", "<th", "<ul", "<ol",
        "<header", "<footer", "<nav", "<head", "<style", "<script", "<meta", "<title",
        "",
    ],
    "latex": [
        "\n\\\\chapter{", "\n\\\\section{", "\n\\\\subsection{", "\n\\\\subsubsection{",
        "\n\\\\begin{enumerate}", "\n\\\\begin{itemize}", "\n\\\\begin{description}", "\n\\\\begin{list}",
        "\n\\\\begin{quote}", "\n\\\\begin{quotation}", "\n\\\\begin{verse}", "\n\\\\begin{verbatim}",
        "\n\\\\begin{align}",
        "$$", "$", " ", "",
    ],
    "sol": [
        "\npragma ", "\nusing ",
        "\ncontract ", "\ninterface ", "\nlibrary ",
        "\nconstructor ", "\ntype ", "\nfunction ", "\nevent ", "\nmodifier ", "\nerror ", "\nstruct ", "\nenum ",
        "\nif ", "\nfor ", "\nwhile ", "\ndo while ", "\nassembly ",
        "\n\n", "\n", " ", "",
    ],
    "cobol": [
        "\nIDENTIFICATION DIVISION.", "\nENVIRONMENT DIVISION.", "\nDATA DIVISION.", "\nPROCEDURE DIVISION.",
        "\nWORKING-STORAGE SECTION.", "\nLINKAGE SECTION.", "\nFILE SECTION.", "\nINPUT-OUTPUT SECTION.",
        "\nOPEN ", "\nCLOSE ", "\nREAD ", "\nWRITE ", "\nIF ", "\nELSE ", "\nMOVE ", "\nPERFORM ",
        "\nUNTIL ", "\nVARYING ", "\nACCEPT ", "\nDISPLAY ", "\nSTOP RUN.",
        "\n", " ", "",
    ],
}  # fmt: skip


def _split_keeping_separator(text: str, pattern: str) -> list[str]:
    """Split on ``pattern``, attaching each separator to the piece after it."""
    if pattern:
        parts = re.split(f"({pattern})", text)
        splits = [parts[i] + parts[i + 1] for i in range(1, len(parts), 2)]
        if len(parts) % 2 == 0:
            splits += parts[-1:]
        splits = [parts[0], *splits]
    else:
        splits = list(text)
    return [s for s in splits if s]


class RecursiveSplitter:
    """Split on the first separator present, recursing into pieces still too long.

    Separators are kept, at the start of the piece that follows them, and pieces
    are merged back up to ``chunk_size`` characters with ``chunk_overlap``
    characters carried from one chunk into the next. Chunks are stripped of
    surrounding whitespace, and whitespace-only chunks are dropped.
    """

    def __init__(
        self, *, chunk_size: int, chunk_overlap: int, separators: list[str], is_separator_regex: bool = False
    ) -> None:
        if chunk_size <= 0:
            raise ValueError(f"chunk_size must be > 0, got {chunk_size}")
        if chunk_overlap < 0:
            raise ValueError(f"chunk_overlap must be >= 0, got {chunk_overlap}")
        if chunk_overlap > chunk_size:
            raise ValueError(f"chunk_overlap ({chunk_overlap}) is larger than chunk_size ({chunk_size})")
        self._chunk_size = chunk_size
        self._chunk_overlap = chunk_overlap
        self._separators = separators
        self._is_separator_regex = is_separator_regex

    @classmethod
    def for_language(cls, language: str, *, chunk_size: int, chunk_overlap: int) -> RecursiveSplitter:
        return cls(
            chunk_size=chunk_size,
            chunk_overlap=chunk_overlap,
            separators=LANGUAGE_SEPARATORS[language],
            is_separator_regex=True,
        )

    def split_text(self, text: str) -> list[str]:
        return self._split(text, self._separators)

    def _pattern(self, separator: str) -> str:
        return separator if self._is_separator_regex else re.escape(separator)

    def _split(self, text: str, separators: list[str]) -> list[str]:
        separator = separators[-1]
        remaining: list[str] = []
        for i, candidate in enumerate(separators):
            if not candidate:
                separator = candidate
                break
            if re.search(self._pattern(candidate), text):
                separator = candidate
                remaining = separators[i + 1 :]
                break

        chunks: list[str] = []
        short: list[str] = []
        for piece in _split_keeping_separator(text, self._pattern(separator)):
            if len(piece) < self._chunk_size:
                short.append(piece)
                continue
            if short:
                chunks.extend(self._merge(short))
                short = []
            if remaining:
                chunks.extend(self._split(piece, remaining))
            else:
                chunks.append(piece)
        if short:
            chunks.extend(self._merge(short))
        return chunks

    def _merge(self, splits: Iterable[str]) -> list[str]:
        """Pack pieces into chunks of at most ``chunk_size``, overlapping by up to ``chunk_overlap``.

        Separators are already attached to the pieces, so they are joined with nothing.
        """
        docs: list[str] = []
        current: list[str] = []
        total = 0
        for piece in splits:
            length = len(piece)
            if total + length > self._chunk_size:
                if total > self._chunk_size:
                    log.debug("created a chunk of %d characters, over the %d limit", total, self._chunk_size)
                if current:
                    doc = "".join(current).strip()
                    if doc:
                        docs.append(doc)
                    while total > self._chunk_overlap or (total + length > self._chunk_size and total > 0):
                        total -= len(current[0])
                        current = current[1:]
            current.append(piece)
            total += length
        doc = "".join(current).strip()
        if doc:
            docs.append(doc)
        return docs


@dataclass
class MarkdownSection:
    """A run of markdown under one heading path."""

    content: str
    metadata: dict[str, str] = field(default_factory=dict)


class MarkdownHeaderSplitter:
    """Split markdown into sections at ATX headings, keeping the heading lines.

    Lines are stripped (and non-printable characters dropped), blank lines are
    dropped, and fenced code blocks are never split on. Lines inside a fence keep
    their indentation, and tabs, since code (Python above all) means something
    different without them. Each section records the text of the headings above
    it under the names in ``headers``.
    """

    def __init__(self, headers: list[tuple[str, str]]) -> None:
        # Longest marker first, so "##" is not mistaken for "#".
        self._headers = sorted(headers, key=lambda header: len(header[0]), reverse=True)

    def split_text(self, text: str) -> list[MarkdownSection]:
        lines: list[MarkdownSection] = []
        content: list[str] = []
        metadata: dict[str, str] = {}
        stack: list[tuple[int, str]] = []
        active: dict[str, str] = {}
        in_code = False
        fence = ""

        for raw in text.split("\n"):
            line = "".join(filter(str.isprintable, raw.strip()))
            if not in_code:
                if line.startswith("```") and line.count("```") == 1:
                    in_code, fence = True, "```"
                elif line.startswith("~~~"):
                    in_code, fence = True, "~~~"
            elif line.startswith(fence):
                in_code, fence = False, ""

            if in_code:
                content.append("".join(c for c in raw.rstrip() if c.isprintable() or c == "\t"))
                continue

            for marker, name in self._headers:
                if line.startswith(marker) and (len(line) == len(marker) or line[len(marker)] == " "):
                    level = marker.count("#")
                    while stack and stack[-1][0] >= level:
                        active.pop(stack.pop()[1], None)
                    stack.append((level, name))
                    active[name] = line[len(marker) :].strip()
                    if content:
                        lines.append(MarkdownSection("\n".join(content), metadata.copy()))
                        content.clear()
                    content.append(line)
                    break
            else:
                if line:
                    content.append(line)
                elif content:
                    lines.append(MarkdownSection("\n".join(content), metadata.copy()))
                    content.clear()

            metadata = active.copy()

        if content:
            lines.append(MarkdownSection("\n".join(content), metadata))
        return self._aggregate(lines)

    @staticmethod
    def _aggregate(lines: list[MarkdownSection]) -> list[MarkdownSection]:
        """Join consecutive runs with the same headings; a bare heading absorbs the deeper run after it."""
        sections: list[MarkdownSection] = []
        for line in lines:
            if sections and sections[-1].metadata == line.metadata:
                sections[-1].content += "  \n" + line.content
            elif (
                sections
                and len(sections[-1].metadata) < len(line.metadata)
                and sections[-1].content.split("\n")[-1][0] == "#"
            ):
                sections[-1].content += "  \n" + line.content
                sections[-1].metadata = line.metadata
            else:
                sections.append(line)
        return sections

"""Chunking behaviour per content kind."""

from __future__ import annotations

import pytest

from garage_rag.extract.base import ContentKind, normalize_text
from garage_rag.extract.text import split_frontmatter
from garage_rag.ingest.chunking import (
    TextChunk,
    chunk_code,
    chunk_markdown,
    chunk_prose,
    chunk_tabular,
    chunk_text,
)

MARKDOWN = """# Boot Security

Intro paragraph about the boot chain.

## SEP

The Secure Enclave Processor validates its own firmware.

### FIPS Mode

FIPS mode changes the key derivation path.

## EEPROM

Some notes about EEPROM contents.
"""


class TestMarkdown:
    def test_heading_path_is_recorded(self) -> None:
        chunks = chunk_markdown(MARKDOWN, size=1000, overlap=100)
        paths = [c.heading_path for c in chunks]
        assert any(p and "SEP" in p for p in paths)
        # Nested headings produce a breadcrumb, not just the leaf.
        assert any(p and "FIPS Mode" in p and "SEP" in p for p in paths)

    def test_chunks_do_not_straddle_sections(self) -> None:
        chunks = chunk_markdown(MARKDOWN, size=1000, overlap=100)
        # EEPROM content must not land in a chunk labelled as SEP.
        for chunk in chunks:
            if chunk.heading_path and "EEPROM" in chunk.heading_path:
                assert "Secure Enclave" not in chunk.text

    def test_oversized_section_is_split_by_size(self) -> None:
        big = "# Title\n\n" + ("word " * 2000)
        chunks = chunk_markdown(big, size=500, overlap=50)
        assert len(chunks) > 1
        assert all(len(c.text) <= 700 for c in chunks)

    def test_malformed_markdown_still_produces_chunks(self) -> None:
        """A header split failure must not cost us the document."""
        chunks = chunk_markdown("#" * 5000, size=200, overlap=20)
        assert chunks

    def test_chunker_label_records_strategy(self) -> None:
        chunks = chunk_markdown(MARKDOWN, size=1000, overlap=100)
        assert chunks[0].chunker.startswith("markdown-header+recursive")

    def test_fenced_code_keeps_its_indentation(self) -> None:
        text = "# Loop\n\nRuns forever.\n\n```python\nwhile True:\n    if done():\n\tbreak\n```\n"
        [chunk] = chunk_markdown(text, size=1000, overlap=100)
        assert "while True:\n    if done():\n\tbreak\n```" in chunk.text
        # Prose around the fence is still stripped.
        assert chunk.text.startswith("# Loop  \nRuns forever.")

    def test_span_ends_at_the_closing_fence(self) -> None:
        """A chunk's last line that also appears earlier in it (a fence) ends the span at the chunk's end."""
        text = "# Log\n\nFormat:\n\n```\nDATE OPERATION target\n```\n"
        [chunk] = chunk_text(text, ContentKind.MARKDOWN, size=1000, overlap=100)
        assert (chunk.char_start, chunk.char_end) == (0, len(text.rstrip()))


class TestProse:
    def test_splits_on_paragraphs(self) -> None:
        text = "\n\n".join(f"Paragraph number {i} with some content." for i in range(50))
        chunks = chunk_prose(text, size=200, overlap=20)
        assert len(chunks) > 1
        assert all(c.text.strip() for c in chunks)

    def test_short_text_is_one_chunk(self) -> None:
        chunks = chunk_prose("A single short sentence.", size=1000, overlap=100)
        assert len(chunks) == 1

    def test_ordinals_are_sequential(self) -> None:
        text = "\n\n".join(f"Para {i}." for i in range(30))
        chunks = chunk_prose(text, size=100, overlap=10)
        assert [c.ord for c in chunks] == list(range(len(chunks)))


class TestCode:
    PY = '''
def alpha(x):
    """First."""
    return x + 1


def beta(y):
    """Second."""
    return y * 2


class Gamma:
    def method(self):
        return None
'''

    def test_python_uses_language_aware_splitter(self) -> None:
        chunks = chunk_code(self.PY, extension=".py", size=100, overlap=0)
        assert chunks
        assert "python" in chunks[0].chunker

    def test_unknown_extension_falls_back_to_recursive(self) -> None:
        chunks = chunk_code("some text here", extension=".xyz", size=100, overlap=0)
        assert chunks
        assert chunks[0].chunker.startswith("recursive")

    def test_indentation_is_preserved(self) -> None:
        """Code chunking must not strip leading whitespace."""
        chunks = chunk_code(self.PY, extension=".py", size=500, overlap=0)
        assert any(line.startswith("    ") for c in chunks for line in c.text.split("\n"))


class TestTabular:
    def test_splits_on_sheet_headings(self) -> None:
        text = "## Sheet1\na | b | c\n1 | 2 | 3\n\n## Sheet2\nx | y\n9 | 8\n"
        chunks = chunk_tabular(text, size=200)
        headings = [c.heading_path for c in chunks]
        assert any(h == "Sheet1" for h in headings)

    def test_no_overlap_between_chunks(self) -> None:
        """Repeating rows across chunks adds retrieval noise."""
        text = "## S\n" + "\n".join(f"row {i} | value {i}" for i in range(400))
        chunks = chunk_tabular(text, size=200)
        assert len(chunks) > 1
        first_lines = set(chunks[0].text.split("\n"))
        second_lines = set(chunks[1].text.split("\n"))
        assert not (first_lines & second_lines) - {"## S"}


class TestDispatch:
    def test_kind_selects_strategy(self) -> None:
        md = chunk_text(MARKDOWN, ContentKind.MARKDOWN)
        assert md[0].chunker.startswith("markdown-header")

        code = chunk_text("def f():\n    pass\n", ContentKind.CODE, extension=".py")
        assert "code:" in code[0].chunker or code[0].chunker.startswith("recursive")

        prose = chunk_text("Plain sentence.", ContentKind.PROSE)
        assert prose[0].chunker.startswith("recursive")

    def test_conversation_is_treated_as_prose(self) -> None:
        """Conversations arrive pre-windowed from the messages extractor."""
        chunks = chunk_text("Me: hi\nThem: hello\n", ContentKind.CONVERSATION)
        assert chunks
        assert chunks[0].chunker.startswith("recursive")

    def test_empty_text_yields_no_chunks(self) -> None:
        assert chunk_text("   \n\n  ", ContentKind.PROSE) == []


class TestChunkMetadata:
    def test_sha256_is_content_addressed(self) -> None:
        a = TextChunk(ord=0, text="identical", chunker="x")
        b = TextChunk(ord=5, text="identical", chunker="y")
        # Hash depends on text alone, so re-chunking stable text is detectable.
        assert a.sha256 == b.sha256

    def test_sha256_changes_with_text(self) -> None:
        a = TextChunk(ord=0, text="one", chunker="x")
        b = TextChunk(ord=0, text="two", chunker="x")
        assert a.sha256 != b.sha256

    def test_token_estimate_is_positive(self) -> None:
        assert TextChunk(ord=0, text="a", chunker="x").token_estimate >= 1


class TestNormalizeText:
    def test_nfc_normalization(self) -> None:
        """macOS hands back NFD; without normalizing, identical content would
        hash differently depending on its origin."""
        nfd = "école"
        nfc = "école"
        assert normalize_text(nfd) == normalize_text(nfc)

    def test_strips_nul_bytes(self) -> None:
        """Postgres text columns reject NUL outright."""
        assert "\x00" not in normalize_text("a\x00b")

    def test_normalizes_line_endings(self) -> None:
        assert normalize_text("a\r\nb\rc") == "a\nb\nc"

    def test_collapses_excess_blank_lines(self) -> None:
        """PDF extraction is especially prone to long blank runs."""
        assert normalize_text("a\n\n\n\n\n\nb") == "a\n\n\nb"

    def test_empty_input(self) -> None:
        assert normalize_text("") == ""


@pytest.mark.parametrize(
    ("raw", "has_front"),
    [
        ("---\ntitle: X\nauthor: Me\n---\nBody", True),
        ("No frontmatter here", False),
        # Genuinely unparseable YAML (ScannerError); the body must survive.
        ("---\na: b: c: d\n---\nBody", False),
        ("---\n[unclosed\n---\nBody", False),
        # Valid YAML that is not a mapping is not usable frontmatter.
        ("---\nnot a dict\n---\nBody", False),
    ],
)
def test_frontmatter_parsing(raw: str, has_front: bool) -> None:
    front, body = split_frontmatter(raw)
    assert bool(front) is has_front
    # The body must survive regardless of frontmatter validity.
    assert "Body" in body or not has_front


class TestOffsets:
    """chunk_text records where each chunk sits in the text it was cut from."""

    @staticmethod
    def _assert_slices(source: str, chunks: list[TextChunk]) -> None:
        for chunk in chunks:
            if chunk.char_start is not None:
                assert chunk.char_end is not None
                assert source[chunk.char_start : chunk.char_end] == chunk.text

    def test_prose_chunks_are_located_even_when_they_overlap(self) -> None:
        source = " ".join(f"Sentence number {i} about the boot chain." for i in range(80))
        chunks = chunk_text(source, ContentKind.PROSE, size=200, overlap=50)
        assert len(chunks) > 3
        assert all(c.char_start is not None for c in chunks)
        assert chunks[0].char_start == 0
        starts = [c.char_start for c in chunks]
        assert starts == sorted(starts)
        self._assert_slices(source, chunks)

    def test_code_chunks_are_located(self) -> None:
        source = "\n\n".join(f"def f{i}(x):\n    return x + {i}\n" for i in range(40))
        chunks = chunk_text(source, ContentKind.CODE, extension=".py", size=120, overlap=0)
        assert all(c.char_start is not None for c in chunks)
        self._assert_slices(source, chunks)

    def test_markdown_spans_cover_each_chunk(self) -> None:
        """The header splitter drops blank lines, so a markdown chunk is rarely a
        verbatim slice; its span runs from its first line to its last."""
        chunks = chunk_text(MARKDOWN, ContentKind.MARKDOWN, size=80, overlap=0)
        assert all(c.char_start is not None for c in chunks)
        for chunk in chunks:
            span = MARKDOWN[chunk.char_start : chunk.char_end]
            lines = [line.strip() for line in chunk.text.splitlines() if line.strip()]
            assert span.startswith(lines[0])
            assert span.endswith(lines[-1])
            position = 0
            for line in lines:
                position = span.index(line, position)

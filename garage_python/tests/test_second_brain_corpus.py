"""A real-world Markdown corpus (``tests/corpora/second-brain-os``) goes through the real pipeline.

The UI tests' fixture corpus is six invented files, small enough to know every answer by heart.
This one is a copy of `undefined-ui/second-brain-os <https://github.com/undefined-ui/second-brain-os>`_
(MIT; see ``tests/corpora/README.md``): 250 Markdown files written by people for people, with
front matter, fenced code, tables, deep heading trees, template placeholders and many files that
share a name. It walks, extracts, gates, attributes and chunks every file against a gateway that
records what would be stored, then checks that every file is indexed and that what was recorded
matches ``golden/second_brain_os.json``: each document's title, extractor, classes and content
hash, and each chunk's heading path, offsets and hash. An extractor or chunker change that moves
any of it fails here, on Linux. A deliberate change regenerates the golden::

    python tests/test_second_brain_corpus.py --regenerate
"""

from __future__ import annotations

import hashlib
import json
import shutil
import sys
from pathlib import Path
from typing import Any

import pytest

from garage_rag.config import repo_root
from garage_rag.db.models import CorpusClass, TrustTier
from garage_rag.ingest.gateway import ExistingDocStat, IngestStorageGateway, SourceContext
from garage_rag.ingest.pipeline import ingest_source
from garage_rag.ingest.scanner import ScanResult

CORPUS = repo_root() / "garage_python" / "tests" / "corpora" / "second-brain-os"
GOLDEN = Path(__file__).parent / "golden" / "second_brain_os.json"

# replace_document's parameters after uri and title, in order, for calls that pass them positionally.
_DOCUMENT_FIELDS = (
    "lang",
    "byte_size",
    "mtime",
    "source_sha256",
    "content_sha256",
    "extractor",
    "extractor_version",
    "chunker",
    "content",
    "meta",
    "corpus_class",
    "trust_tier",
    "authors",
    "chunks",
)


class RecordingGateway(IngestStorageGateway):
    """Stores nothing; keeps each document and every other outcome by its path under the root."""

    def __init__(self, root: Path) -> None:
        self.root = root
        self.documents: dict[str, dict[str, Any]] = {}
        self.outcomes: dict[str, str] = {}

    def _note(self, uri: str, outcome: str) -> str:
        key = Path(uri).relative_to(self.root).as_posix()
        self.outcomes[key] = outcome
        return key

    def list_enabled_sources(self) -> list[str]:
        return ["second-brain-os"]

    def begin_session(self, source_slug: str, include_code: bool = False) -> SourceContext:
        return SourceContext(
            source_id=1,
            slug=source_slug,
            root=self.root,
            default_class=CorpusClass.DOCUMENT,
            default_trust=TrustTier.AUTHORED,
            run_id=1,
        )

    def persist_scan(self, source_slug: str, scan_result: ScanResult) -> None:
        pass

    def check_stat(self, source_slug: str, uri: str) -> ExistingDocStat:
        return ExistingDocStat(exists=False)

    def record_placeholder(self, run_id, source_slug, uri, mtime, title, error="") -> None:
        self._note(uri, "placeholder")

    def record_extract_failed(self, run_id, source_slug, uri, error, **kwargs) -> None:
        self._note(uri, f"failed: {error}")

    def record_no_text(self, run_id, source_slug, uri, **kwargs) -> None:
        self._note(uri, "no text")

    def record_rejected(self, run_id, source_slug, uri) -> None:
        self._note(uri, "rejected")

    def record_seen(self, run_id, source_slug, uri) -> None:
        pass

    def refresh_metadata(self, *args, **kwargs) -> None:
        pass

    def replace_document(self, run_id, source_slug, uri, title, *args, **kwargs) -> int:
        record = dict(zip(_DOCUMENT_FIELDS, args, strict=False)) | kwargs | {"title": title}
        self.documents[self._note(uri, "indexed")] = record
        return len(record["chunks"])

    def finalize_session(self, *args, **kwargs) -> None:
        pass


def _ingest(tmp_path: Path) -> RecordingGateway:
    # A copy, never the committed folder: attribution reads the repository's git history otherwise.
    root = tmp_path / "second-brain-os"
    shutil.copytree(CORPUS, root)
    gateway = RecordingGateway(root)
    counters, _, _ = ingest_source(gateway=gateway, source_slug="second-brain-os", include_code=True)
    assert counters.failed == 0, counters.errors
    return gateway


def _summary(document: dict[str, Any]) -> dict[str, Any]:
    """What the golden pins for one document: enough to see any change, without its text."""
    return {
        "title": document["title"],
        "extractor": document["extractor"],
        "corpus_class": document["corpus_class"],
        "trust_tier": document["trust_tier"],
        "content_sha256": document["content_sha256"],
        "chunks": [
            [
                chunk.heading_path,
                chunk.char_start,
                chunk.char_end,
                hashlib.sha256(chunk.text.encode("utf-8")).hexdigest()[:16],
            ]
            for chunk in document["chunks"]
        ],
    }


def _markdown_files() -> list[str]:
    return sorted(p.relative_to(CORPUS).as_posix() for p in CORPUS.rglob("*.md"))


@pytest.fixture(scope="module")
def ingested(tmp_path_factory: pytest.TempPathFactory) -> RecordingGateway:
    return _ingest(tmp_path_factory.mktemp("second-brain-os"))


@pytest.fixture(scope="module")
def golden() -> dict[str, dict[str, Any]]:
    return json.loads(GOLDEN.read_text(encoding="utf-8"))


def test_the_corpus_holds_the_upstream_markdown_and_its_license() -> None:
    files = sorted(p.relative_to(CORPUS).as_posix() for p in CORPUS.rglob("*") if p.is_file())
    assert files == sorted([*_markdown_files(), "LICENSE"])
    assert len(_markdown_files()) == 250
    assert (CORPUS / "LICENSE").read_text(encoding="utf-8").startswith("MIT License")


def test_every_markdown_file_is_indexed(ingested: RecordingGateway) -> None:
    """Nothing is rejected by the quality gate, fails to extract or comes out empty; LICENSE has no extractor."""
    assert ingested.outcomes == dict.fromkeys(_markdown_files(), "indexed")
    for name, document in ingested.documents.items():
        assert document["chunks"], f"{name} has no chunks"


def test_every_chunk_lies_in_its_span(ingested: RecordingGateway) -> None:
    """Each chunk's offsets cover its text, whitespace aside (the Markdown splitter drops blank lines)."""
    for name, document in ingested.documents.items():
        for chunk in document["chunks"]:
            assert chunk.char_start is not None, (name, chunk.ord)
            span = document["content"][chunk.char_start : chunk.char_end]
            assert " ".join(chunk.text.split()) in " ".join(span.split()), (name, chunk.ord)


def test_golden_covers_every_file(golden: dict[str, dict[str, Any]]) -> None:
    assert sorted(golden) == _markdown_files()


@pytest.mark.parametrize("name", _markdown_files())
def test_matches_golden(ingested: RecordingGateway, golden: dict[str, dict[str, Any]], name: str) -> None:
    assert _summary(ingested.documents[name]) == golden[name]


if __name__ == "__main__" and "--regenerate" in sys.argv:
    import tempfile

    with tempfile.TemporaryDirectory() as tmp:
        recorded = {name: _summary(doc) for name, doc in _ingest(Path(tmp)).documents.items()}
    # One document per line keeps diffs readable.
    lines = [f"{json.dumps(name)}: {json.dumps(recorded[name], ensure_ascii=False)}" for name in sorted(recorded)]
    GOLDEN.write_text("{\n" + ",\n".join(lines) + "\n}\n", encoding="utf-8")
    print(f"wrote {len(recorded)} documents to {GOLDEN}")

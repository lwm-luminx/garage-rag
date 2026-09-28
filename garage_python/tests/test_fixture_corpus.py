"""The UI tests' fixture corpus (``macapp/Tests/Fixtures/corpus``) goes through the real pipeline.

The macOS UI tests copy that folder into a throwaway data folder and ingest it through the app,
then assert on what the Documents, Search and Facts pages show. Those tests only run on a Mac, so
this one walks, extracts, gates, attributes and chunks the same files here, against a gateway that
records what would be stored, and checks what ``macapp/Tests/Fixtures/README.md`` promises: every
file becomes one document with the title, class and token listed there.
"""

from __future__ import annotations

import json
import re
import shutil
from collections import Counter
from pathlib import Path
from typing import Any
from unittest.mock import MagicMock

import pytest

from garage_rag.config import repo_root
from garage_rag.db.models import CorpusClass, TrustTier
from garage_rag.enrich import langextract as lx
from garage_rag.enrich.facts import default_prompt, langextract_examples
from garage_rag.enrich.local_provider import LocalLanguageModel
from garage_rag.inference import ChatResult
from garage_rag.ingest.gateway import ExistingDocStat, IngestStorageGateway, SourceContext
from garage_rag.ingest.pipeline import ingest_source
from garage_rag.ingest.scanner import ScanResult

CORPUS = repo_root() / "macapp" / "Tests" / "Fixtures" / "corpus"

# file -> (title, corpus class, trust tier, the file's unique token). Keep in step with the README.
# Metadata naming an author other than the owner makes a file `reference`; a mail from someone
# else is `received`.
EXPECTED = {
    "quillon-bridge.md": ("The Quillon Bridge", "document", "authored", "zorvexine"),
    "marrowgate-lighthouse.txt": ("Marrowgate Lighthouse", "document", "authored", "plimbrate"),
    "tide_tables.rs": ("tide_tables.rs", "code", "authored", "tessaroon"),
    "lantern-festival.eml": ("The Brindlecombe lantern festival", "communication", "received", "wendleflock"),
    "ashvale-orchard.pdf": ("The Ashvale Orchard Survey", "document", "reference", "orbanquet"),
    "tavish-glassworks.docx": ("A History of Tavish Glassworks", "document", "reference", "glimmerhaft"),
}
CODE_FILES = {"tide_tables.rs"}

# The sentence each file is known for, which search and fact tests look for.
KNOWN_FACTS = {
    "quillon-bridge.md": "The Quillon Bridge opened in 1893",
    "marrowgate-lighthouse.txt": "Idra Voss kept the Marrowgate lighthouse for forty-one years",
    "tide_tables.rs": "High water at Port Ellery comes 52 minutes later each day",
    "lantern-festival.eml": "held on the third Saturday of October",
    "ashvale-orchard.pdf": "The Ashvale orchard grows 212 varieties of pear",
    "tavish-glassworks.docx": "Tavish Glassworks was founded by Mirela Tavish in 1911",
}


class RecordingGateway(IngestStorageGateway):
    """Stores nothing; keeps each ``replace_document`` call, and every other outcome, by file name."""

    def __init__(self, root: Path) -> None:
        self.root = root
        self.documents: dict[str, dict[str, Any]] = {}
        self.outcomes: dict[str, str] = {}

    def list_enabled_sources(self) -> list[str]:
        return ["fixture"]

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

    def _note(self, uri: str, outcome: str) -> None:
        self.outcomes[Path(uri).name] = outcome

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
        names = [
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
        ]
        record = dict(zip(names, args, strict=False)) | kwargs | {"title": title}
        self.documents[Path(uri).name] = record
        self._note(uri, "indexed")
        return len(record["chunks"])

    def finalize_session(self, *args, **kwargs) -> None:
        pass


def _ingest(tmp_path: Path, *, include_code: bool) -> RecordingGateway:
    # A copy, never the committed folder: attribution reads the repository's git history otherwise.
    root = tmp_path / "corpus"
    shutil.copytree(CORPUS, root)
    gateway = RecordingGateway(root)
    counters, _, _ = ingest_source(gateway=gateway, source_slug="fixture", include_code=include_code)
    assert counters.failed == 0, counters.errors
    return gateway


def test_the_corpus_holds_exactly_the_documented_files() -> None:
    assert sorted(p.name for p in CORPUS.iterdir()) == sorted(EXPECTED)


@pytest.fixture(scope="module")
def ingested(tmp_path_factory: pytest.TempPathFactory) -> RecordingGateway:
    return _ingest(tmp_path_factory.mktemp("with-code"), include_code=True)


@pytest.mark.parametrize("name", sorted(EXPECTED))
def test_every_file_becomes_one_document(ingested: RecordingGateway, name: str) -> None:
    assert ingested.outcomes.get(name) == "indexed", ingested.outcomes
    document = ingested.documents[name]
    title, corpus_class, trust_tier, token = EXPECTED[name]
    assert document["title"] == title
    assert document["corpus_class"] == corpus_class
    assert document["trust_tier"] == trust_tier
    assert document["chunks"], "no chunks"
    text = " ".join(chunk.text for chunk in document["chunks"])
    assert token in text
    assert KNOWN_FACTS[name] in " ".join(text.split())
    # Each token belongs to one file only.
    for other, (*_, other_token) in EXPECTED.items():
        if other != name:
            assert other_token not in text


def test_chunk_counts(ingested: RecordingGateway) -> None:
    """The UI tests count chunks: the Markdown note splits at its second heading, the rest are one chunk."""
    expected = dict.fromkeys(EXPECTED, 1) | {"quillon-bridge.md": 2}
    assert {name: len(doc["chunks"]) for name, doc in ingested.documents.items()} == expected


def test_a_source_without_code_skips_the_code_file(tmp_path: Path) -> None:
    """The app's Sources form adds a source with code off, so the UI tests see five documents."""
    gateway = _ingest(tmp_path, include_code=False)
    assert sorted(gateway.documents) == sorted(set(EXPECTED) - CODE_FILES)


# ---- the model UI tests' deterministic engine ------------------------------------------------
#
# macapp/Tests/GarageAppModelUITests distil this corpus through MockLlamaXPCService, whose
# DeterministicLlamaEngine (macapp/Tests/LlamaTestSupport) answers a LangExtract prompt with one
# extraction per sentence of the prompt's last question. The functions below mirror that answer,
# so the prompt shape it relies on and the counts FixtureCorpus.swift promises the UI tests are
# checked against the vendored LangExtract here, on Linux.

# FixtureCorpus.swift: distilledFacts (their sum), distilledEvents, distilledFromMail, zorvexineFact.
DISTILLED = {"fact": 9, "event": 11}
DISTILLED_FROM_MAIL = 3
QUILLON_BRIDGE_FACTS = 5
ZORVEXINE_FACT = "Townspeople call the middle arch the zorvexine arch, after the swallows that nest under it."


def _deterministic_question(prompt: str) -> str | None:
    """DeterministicLlamaEngine.langExtractQuestion: the text after the last ``Q: `` line."""
    body = prompt.rstrip()
    if not body.endswith("\nA:"):
        return None
    body = body[: -len("\nA:")]
    at = body.rfind("\nQ: ")
    if at >= 0:
        return body[at + len("\nQ: ") :]
    return body[len("Q: ") :] if body.startswith("Q: ") else None


def _deterministic_answer(prompt: str) -> str:
    """DeterministicLlamaEngine.extractionAnswer: sentences of five words or more, ``event`` with a
    ``year`` when one holds a four-digit number, ``fact`` otherwise, in a fenced JSON object."""
    text = _deterministic_question(prompt)
    assert text is not None, f"not a LangExtract prompt: {prompt[-200:]!r}"
    extractions = []
    for line in text.split("\n"):
        for match in re.finditer(r"[^.!?]*[.!?]", line):
            sentence = match.group(0).strip()
            if len(sentence.split(" ")) < 5:
                continue
            year = next((run for run in re.split(r"[^0-9]+", sentence) if len(run) == 4), None)
            extractions.append({"event": sentence, "event_attributes": {"year": year}} if year else {"fact": sentence})
    return "```json\n" + json.dumps({"extractions": extractions}, indent=2) + "\n```"


def _distil(content: str) -> list[lx.data.Extraction]:
    client = MagicMock()
    client.chat.side_effect = lambda messages, *args, **kwargs: ChatResult(
        text=_deterministic_answer(messages[-1]["content"])
    )
    prompt = default_prompt()
    result = lx.extract(
        text_or_documents=content,
        prompt_description=prompt.description,
        examples=langextract_examples(prompt),
        model=LocalLanguageModel("uitest-deterministic", client),
    )
    return result.extractions


@pytest.fixture(scope="module")
def distilled(tmp_path_factory: pytest.TempPathFactory) -> dict[str, list[lx.data.Extraction]]:
    gateway = _ingest(tmp_path_factory.mktemp("distilled"), include_code=False)
    return {name: _distil(document["content"]) for name, document in gateway.documents.items()}


def test_the_deterministic_engine_grounds_every_fact(distilled: dict[str, list[lx.data.Extraction]]) -> None:
    """Every extraction is found in its document, so the Facts page shows each one's excerpt."""
    for name, extractions in distilled.items():
        assert extractions, f"{name} distilled no facts"
        for extraction in extractions:
            assert extraction.char_interval is not None, (name, extraction.extraction_text)


def test_the_deterministic_engine_distils_the_counts_the_ui_tests_expect(
    distilled: dict[str, list[lx.data.Extraction]],
) -> None:
    kinds = Counter(e.extraction_class for extractions in distilled.values() for e in extractions)
    assert dict(kinds) == DISTILLED
    assert len(distilled["lantern-festival.eml"]) == DISTILLED_FROM_MAIL
    assert len(distilled["quillon-bridge.md"]) == QUILLON_BRIDGE_FACTS
    carrying_token = [
        e.extraction_text for extractions in distilled.values() for e in extractions if "zorvexine" in e.extraction_text
    ]
    assert carrying_token == [ZORVEXINE_FACT]
    for extractions in distilled.values():
        for extraction in extractions:
            if extraction.extraction_class == "event":
                assert extraction.attributes and extraction.attributes["year"] in extraction.extraction_text

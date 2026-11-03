"""``read_for_host``: what each reader outcome becomes for the Rust ingest loop's host."""

from __future__ import annotations

import errno
import json
from datetime import UTC, datetime

import pytest

from garage_rag.extract.base import ContentKind, ExtractionError, ExtractResult, NoTextFound
from garage_rag.extract.placeholder import PlaceholderFile
from garage_rag.ingest import materialize
from garage_rag.ingest.host_read import read_for_host, read_for_host_json


def _reader(outcome):
    def read(path):
        if isinstance(outcome, BaseException):
            raise outcome
        return outcome

    return read


def test_a_document_carries_every_field(tmp_path):
    result = ExtractResult(
        text="Hello.",
        kind=ContentKind.MARKDOWN,
        extractor="text",
        extractor_version="4",
        title="Hi",
        lang="en",
        meta={"pages": 2, "nested": {"a": [1, "b"]}},
        author_hints=["Ada"],
    )
    assert read_for_host(tmp_path / "a.md", reader=_reader(result)) == {
        "document": {
            "text": "Hello.",
            "kind": "markdown",
            "extractor": "text",
            "extractor_version": "4",
            "title": "Hi",
            "lang": "en",
            "meta": {"pages": 2, "nested": {"a": [1, "b"]}},
            "author_hints": ["Ada"],
        }
    }


def _dataless_failure() -> ExtractionError:
    try:
        try:
            raise OSError(next(iter(materialize.DATALESS_REFUSED_ERRNOS)), "refused")
        except OSError as cause:
            raise ExtractionError("could not read") from cause
    except ExtractionError as error:
        return error


@pytest.mark.parametrize(
    ("outcome", "expected"),
    [
        (NoTextFound("empty"), {"no_text": "empty"}),
        (PlaceholderFile("/x/a.md"), {"placeholder": True}),
        (ExtractionError("broken"), {"failed": "broken"}),
        (OSError(errno.EACCES, "denied"), {"failed": "[Errno 13] denied"}),
        (ValueError("a bug"), {"raised": "a bug"}),
    ],
    ids=["no text", "placeholder", "failed", "os error", "raised"],
)
def test_each_failure_maps_as_ingest_one_treats_it(tmp_path, outcome, expected):
    assert read_for_host(tmp_path / "a.md", reader=_reader(outcome)) == expected


def test_a_refused_dataless_read_is_a_placeholder(tmp_path):
    assert read_for_host(tmp_path / "a.md", reader=_reader(_dataless_failure())) == {"placeholder": True}


def test_meta_json_cannot_hold_is_raised(tmp_path):
    result = ExtractResult(text="x", kind=ContentKind.PROSE, extractor="t", meta={"when": datetime.now(UTC)})
    assert "raised" in read_for_host(tmp_path / "a.txt", reader=_reader(result))


def test_the_real_readers_answer_as_json(tmp_path):
    path = tmp_path / "note.md"
    path.write_text("# Title\n\nSome prose about things.\n")
    reply = json.loads(read_for_host_json(str(path)))
    assert reply["document"]["kind"] == "markdown"
    assert "Some prose" in reply["document"]["text"]
    empty = tmp_path / "empty.txt"
    empty.write_text("   \n")
    assert "no_text" in json.loads(read_for_host_json(str(empty)))

from __future__ import annotations

import hashlib
from pathlib import Path
from unittest.mock import MagicMock

from garage_rag.config.fact_prompts import effective_prompts
from garage_rag.db.models import Document, Fact, FactRun
from garage_rag.enrich import langextract as lx
from garage_rag.enrich.facts import extract_and_store_facts, is_stale
from garage_rag.enrich.mail_body import fact_source
from garage_rag.extract.mail import extract_email

_MAIL = """\
From: Jane Doe <jane@example.com>
To: Bob Roe <bob@example.com>
Subject: Budget for Q3
Date: Tue, 1 Sep 2026 10:00:00 -0700

Bob, the Q3 budget is 40,000 dollars.

On Mon, Aug 31, 2026 at 9:00 AM Bob Roe <bob@example.com> wrote:
> What is the Q3 budget?

---------- Forwarded message ---------
From: Carol Poe <carol@example.com>
Date: Fri, Aug 28, 2026
Subject: Offsite
To: Jane Doe <jane@example.com>

The offsite is in Austin.
"""


def _mail_document(tmp_path: Path) -> Document:
    path = tmp_path / "budget.eml"
    path.write_text(_MAIL)
    result = extract_email(path)
    content = result.text
    return Document(
        id=7,
        content=content,
        content_sha256=hashlib.sha256(content.encode()).digest(),
        meta=result.meta,
    )


def test_a_mail_is_read_without_its_header_lines(tmp_path: Path) -> None:
    document = _mail_document(tmp_path)

    text = fact_source(document).text

    assert "Bob, the Q3 budget is 40,000 dollars." in text
    assert "> What is the Q3 budget?" in text
    assert "The offsite is in Austin." in text
    for header in ("From:", "To:", "Subject:", "Date:", "wrote:", "Forwarded message", "jane@example.com"):
        assert header not in text, header


def test_a_span_of_the_body_maps_back_onto_the_document(tmp_path: Path) -> None:
    document = _mail_document(tmp_path)
    source = fact_source(document)

    for sentence in ("Bob, the Q3 budget is 40,000 dollars.", "The offsite is in Austin."):
        start = source.text.index(sentence)
        document_start, document_end = source.span_to_document(start, start + len(sentence))
        assert document.content[document_start:document_end] == sentence


def test_other_documents_are_read_whole() -> None:
    content = "From: a design note\nTo: nobody\n\nIt is prose."
    document = Document(id=1, content=content, content_sha256=b"c", meta={"title": "note"})

    source = fact_source(document)

    assert source.text == content
    assert source.sha256 == b"c"
    assert source.span_to_document(5, 9) == (5, 9)


def test_a_single_from_line_in_a_body_is_kept() -> None:
    content = "Subject: Hi\nFrom: a@example.com\n\nFrom: the lab, results came back.\nAll good."
    document = Document(id=1, content=content, meta={"email_from": "a@example.com"})

    assert fact_source(document).text == "From: the lab, results came back.\nAll good."


def test_the_model_reads_the_body_and_facts_are_grounded_on_the_document(tmp_path: Path, monkeypatch) -> None:
    document = _mail_document(tmp_path)
    sent: list[str] = []

    def fake_extract_facts(text, **kwargs):
        sent.append(text)
        start = text.index("The offsite is in Austin.")
        return [
            lx.data.Extraction(
                extraction_class="fact",
                extraction_text="The offsite is in Austin.",
                char_interval=lx.data.CharInterval(start_pos=start, end_pos=start + 25),
            )
        ]

    monkeypatch.setattr("garage_rag.enrich.facts.extract_facts", fake_extract_facts)
    session = MagicMock()
    added: list = []
    session.add_all.side_effect = lambda items: added.extend(items)

    (fact,) = extract_and_store_facts(session, document, queue_for_embedding=False)

    (text,) = sent
    assert "jane@example.com" not in text and "Subject:" not in text
    assert isinstance(fact, Fact)
    assert document.content[fact.char_start : fact.char_end] == "The offsite is in Austin."
    (run,) = [call.args[0] for call in session.merge.call_args_list]
    assert isinstance(run, FactRun)
    assert run.content_sha256 == fact_source(document).sha256


def test_a_mail_read_with_its_headers_is_stale(tmp_path: Path) -> None:
    document = _mail_document(tmp_path)
    prompt = effective_prompts([])[0]
    before = FactRun(prompt_sha256=prompt.sha256, content_sha256=document.content_sha256, extractor_model="m")
    after = FactRun(prompt_sha256=prompt.sha256, content_sha256=fact_source(document).sha256, extractor_model="m")

    assert is_stale(before, document, prompt, "m")
    assert not is_stale(after, document, prompt, "m")


def test_a_mail_with_only_headers_sends_nothing(monkeypatch) -> None:
    document = Document(id=1, content="Subject: Lunch\nFrom: a@example.com", meta={"email_from": "a@example.com"})
    monkeypatch.setattr("garage_rag.enrich.facts.extract_facts", lambda text, **kwargs: _never_called())

    assert extract_and_store_facts(MagicMock(), document) == []


def _never_called():
    raise AssertionError("the model was asked about a mail with no body")

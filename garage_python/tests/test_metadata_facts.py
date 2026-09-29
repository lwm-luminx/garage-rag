"""Metadata facts: a mail's and a thread's ground truth, read with no model (garage_rag.enrich.metadata)."""

from __future__ import annotations

from types import SimpleNamespace

import pytest

from garage_rag.enrich.metadata import (
    FACT_CLASSES,
    conversation_facts,
    has_metadata,
    is_stale,
    mail_facts,
    normalize_subject,
)

CONTENT = (
    "Subject: Re: FW: Roof  quote\n"
    "From: Ada Lovelace <ada@example.com>\n"
    "To: bob@example.com, Carol <carol@example.com>\n"
    "Cc: Ada Lovelace <ada@example.com>\n"
    "Date: Tue, 29 Sep 2026 10:00:00 +0000\n"
    "\n"
    "Bob, the quote from bob@example.com's roofer is attached."
)
META = {
    "email_from": "Ada Lovelace <ada@example.com>",
    "email_to": "bob@example.com, Carol <carol@example.com>",
    "email_cc": "Ada Lovelace <ada@example.com>",
}


@pytest.mark.parametrize(
    ("subject", "key"),
    [
        ("Roof quote", "roof quote"),
        ("Re: Roof quote", "roof quote"),
        ("RE: Fwd: re:  Roof   Quote ", "roof quote"),
        ("[External] AW: Roof quote", "roof quote"),
        ("Re[2]: Roof quote", "roof quote"),
        ("Regarding the roof", "regarding the roof"),
        ("Re:", ""),
    ],
)
def test_normalize_subject(subject: str, key: str) -> None:
    assert normalize_subject(subject) == key


def test_a_mails_sender_recipients_and_subject_are_grounded_in_its_header() -> None:
    facts = mail_facts(CONTENT, META, {"ada@example.com": 7})
    assert [(f.fact_class, f.text, f.key) for f in facts] == [
        ("sender", "Ada Lovelace <ada@example.com>", "author:7"),
        ("recipient", "bob@example.com", "email:bob@example.com"),
        ("recipient", "Carol <carol@example.com>", "email:carol@example.com"),
        # Ada is also on Cc: one recipient fact for her, beside the sender fact.
        ("recipient", "Ada Lovelace <ada@example.com>", "author:7"),
        ("subject", "Re: FW: Roof  quote", "subject:roof quote"),
    ]
    for fact in facts:
        assert CONTENT[fact.char_start : fact.char_end] == fact.text
        assert fact.attributes["key"] == fact.key
        assert fact.fact_class in FACT_CLASSES
    # Grounded in the header, not in the body where the address appears again.
    bob = facts[1]
    assert bob.char_start < CONTENT.index("\n\n")
    assert facts[3].char_start > CONTENT.index("Cc: ")


def test_a_mail_without_a_subject_line_has_no_subject_fact() -> None:
    content = "From: ada@example.com\n\nNo subject here."
    facts = mail_facts(content, {"email_from": "ada@example.com"}, {})
    assert [(f.fact_class, f.key) for f in facts] == [("sender", "email:ada@example.com")]


def test_an_address_the_header_block_does_not_carry_is_kept_ungrounded() -> None:
    facts = mail_facts("Subject: Hi\n\nbody", {"email_from": "Ada <ada@example.com>"}, {})
    sender = facts[0]
    assert (sender.text, sender.char_start, sender.char_end) == ("ada@example.com", None, None)


def test_a_threads_participants_are_keyed_on_their_authors() -> None:
    content = "[2026-09-24 12:00 UTC] Ada: on my way\n[2026-09-24 12:01 UTC] Me: see you"
    facts = conversation_facts(content, [(3, "Ada", "sender"), (4, "Bob", "recipient"), (5, "Eve", "cc")])
    assert [(f.fact_class, f.text, f.key, f.char_start) for f in facts] == [
        ("sender", "Ada", "author:3", content.index("Ada")),
        ("recipient", "Bob", "author:4", None),
    ]


def test_only_mail_and_threads_have_metadata_facts() -> None:
    mail = SimpleNamespace(meta={"email_from": "a@b.c"}, content_sha256=b"x")
    thread = SimpleNamespace(meta={"chat_guid": "g"}, content_sha256=b"x")
    note = SimpleNamespace(meta={}, content_sha256=b"x")
    assert has_metadata(mail) and has_metadata(thread) and not has_metadata(note)
    assert is_stale(None, mail)
    assert not is_stale(None, note)

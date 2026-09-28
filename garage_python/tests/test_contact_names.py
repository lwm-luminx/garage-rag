"""Names for Messages handles: matching Contacts-style numbers to chat.db handles, and using them."""

from __future__ import annotations

from datetime import UTC, datetime

from garage_rag.attribute.resolver import SelfIdentity
from garage_rag.extract.contact_names import ContactNames, handle_key
from garage_rag.extract.messages import ChatMessage, Conversation
from garage_rag.ingest.conversations import attach_names, conversation_authors, render

AT = datetime(2026, 9, 24, 12, tzinfo=UTC)


def _group() -> Conversation:
    return Conversation(
        guid="iMessage;+;chat42",
        chat_identifier="chat42",
        display_name="",
        service="iMessage",
        participants=["+15551234567", "Friend@Example.com", "+15559876543"],
        messages=[
            ChatMessage(1, "m1", AT, False, "+15551234567", "Saturday?"),
            ChatMessage(2, "m2", AT, True, None, "I'm in"),
        ],
    )


def test_handle_key() -> None:
    assert handle_key("(555) 123-4567") == "5551234567"
    assert handle_key("+1 555 123 4567") == "15551234567"
    assert handle_key(" Friend@Example.com ") == "friend@example.com"
    assert handle_key("12345") is None  # a short code is not a person
    assert handle_key("") is None


def test_numbers_match_with_or_without_the_country_code() -> None:
    names = ContactNames([("(555) 123-4567", "Alex Doe"), ("friend@example.com", "Sam  Lee")])
    assert names.name_for("+15551234567") == "Alex Doe"
    assert names.name_for("5551234567") == "Alex Doe"
    assert names.name_for("FRIEND@example.com") == "Sam Lee"
    assert names.name_for("+15559876543") is None


def test_an_ambiguous_number_gets_no_name() -> None:
    names = ContactNames([("+1 555 123 4567", "Alex"), ("+44 555 123 4567", "Alexandra")])
    assert names.name_for("+15551234567") == "Alex"  # the full number still matches
    assert names.name_for("5551234567") is None  # but the national part names two people


def test_names_label_the_thread_its_members_and_senders() -> None:
    conversation = attach_names(_group(), ContactNames([("5551234567", "Alex Doe"), ("friend@example.com", "Sam")]))
    assert conversation.title == "Alex Doe, Sam, +15559876543"
    text, chunks = render(conversation)
    assert text.splitlines()[1] == "Participants: Alex Doe (+15551234567), Sam (Friend@Example.com), +15559876543"
    assert chunks[0].text == "[2026-09-24 12:00 UTC] Alex Doe: Saturday?"
    authors = conversation_authors(conversation, SelfIdentity(None, []))
    assert {(a.name, tuple(a.identities.values())) for a in authors} == {
        ("Alex Doe", ("+15551234567",)),
        ("Sam", ("Friend@Example.com",)),
        ("+15559876543", ("+15559876543",)),
    }


def test_a_named_group_keeps_its_own_name() -> None:
    conversation = _group()
    conversation.display_name = "Climbing crew"
    attach_names(conversation, ContactNames([("5551234567", "Alex Doe")]))
    assert conversation.title == "Climbing crew"


def test_without_names_the_text_is_unchanged() -> None:
    before, _ = render(_group())
    after, _ = render(attach_names(_group(), ContactNames()))
    assert before == after
    assert attach_names(_group(), None).names == {}

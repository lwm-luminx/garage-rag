"""Naming authors who arrive known only by a handle, for every kind of document.

An author payload whose name is one of its own identities (``alex@example.com``
from a bare ``From:`` header, ``+15551234567`` from Messages) takes the name
:class:`~garage_rag.extract.contact_names.ContactNames` knows for any of its
identities. An author that arrives with a real name keeps it, and so does the
owner. Stored rows follow on their own: ``get_or_create_author`` renames, or
merges, an author still named after its handle when a named payload arrives.
"""

from __future__ import annotations

from dataclasses import replace

from garage_rag.extract.contact_names import ContactNames
from garage_rag.ingest.gateway import AuthorPayload


def name_authors(authors: list[AuthorPayload], contact_names: ContactNames | None) -> list[AuthorPayload]:
    """``authors`` with handle-named entries given their contact names, where known."""
    if not contact_names:
        return authors
    named: list[AuthorPayload] = []
    for author in authors:
        handles = list(author.identities.values())
        if not author.is_self and author.name in handles:
            name = next((n for n in map(contact_names.name_for, handles) if n), None)
            if name:
                author = replace(author, name=name)
        named.append(author)
    return named


__all__ = ["name_authors"]

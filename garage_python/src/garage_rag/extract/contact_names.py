"""Names for Messages handles: turning ``+15551234567`` into the person it belongs to.

``chat.db`` knows people only by handle, a phone number or an email address, as
the carrier or Apple ID delivered it. A name comes from elsewhere (the owner's
contacts, or a name an iMessage contact shared), and the two rarely spell a
number the same way: Contacts holds ``(555) 123-4567`` where Messages holds
``+15551234567``. :class:`ContactNames` matches them.

* **Email** matches case-insensitively.
* **Phone** matches on its digits. When the full digits differ (one side has a
  country code, the other does not), the last ten digits match instead, but only
  when exactly one name claims them, so two people never share a label.

Names are applied to communications only, which never leave the machine.
"""

from __future__ import annotations

from collections.abc import Iterable, Mapping

# A national number without its country code: ten digits in the NANP, and the
# length below which a suffix match stops being specific to one number.
_NATIONAL_DIGITS = 10
_MIN_PHONE_DIGITS = 7


def _digits(handle: str) -> str:
    return "".join(ch for ch in handle if ch.isdigit())


def handle_key(handle: str) -> str | None:
    """The comparable form of a handle: an email lowercased, a phone number's digits, or None."""
    handle = handle.strip()
    if not handle:
        return None
    if "@" in handle:
        return handle.lower()
    digits = _digits(handle)
    return digits if len(digits) >= _MIN_PHONE_DIGITS else None


class ContactNames:
    """A handle-to-name lookup built from ``(handle, name)`` pairs."""

    def __init__(self, entries: Iterable[tuple[str, str]] = ()) -> None:
        self._entries: list[tuple[str, str]] = []
        # Consulted only for a handle these names do not resolve (see with_fallback).
        self._fallback: ContactNames | None = None
        self._exact: dict[str, str] = {}
        self._national: dict[str, set[str]] = {}
        for handle, name in entries:
            self.add(handle, name)

    @classmethod
    def from_mapping(cls, mapping: Mapping[str, str]) -> ContactNames:
        return cls(mapping.items())

    def add(self, handle: str, name: str) -> None:
        """Record a name; the first name given for a handle wins."""
        name = " ".join(name.split())
        key = handle_key(handle)
        if not key or not name:
            return
        self._entries.append((handle, name))
        self._exact.setdefault(key, name)
        if "@" not in key and len(key) >= _NATIONAL_DIGITS:
            self._national.setdefault(key[-_NATIONAL_DIGITS:], set()).add(name)

    def with_fallback(self, entries: Iterable[tuple[str, str]]) -> ContactNames:
        """A copy that also knows ``entries``, consulted only for handles these names do not resolve.

        The tiers stay apart, so a fallback name never outranks one of these, even when it spells the
        number more like the handle does (``+15551234567`` against a contact's ``(555) 123-4567``).
        """
        combined = ContactNames(self._entries)
        combined._fallback = self._fallback.with_fallback(entries) if self._fallback else ContactNames(entries)
        return combined

    def __len__(self) -> int:
        return len(self._exact) + (len(self._fallback) if self._fallback else 0)

    def __bool__(self) -> bool:
        return bool(self._exact) or bool(self._fallback)

    def name_for(self, handle: str) -> str | None:
        """The name for ``handle``, or None when no contact, or more than one, claims it."""
        name = self._own_name_for(handle)
        if name is None and self._fallback is not None:
            return self._fallback.name_for(handle)
        return name

    def _own_name_for(self, handle: str) -> str | None:
        key = handle_key(handle)
        if not key:
            return None
        if key in self._exact:
            return self._exact[key]
        if "@" in key or len(key) < _NATIONAL_DIGITS:
            return None
        names = self._national.get(key[-_NATIONAL_DIGITS:], set())
        return next(iter(names)) if len(names) == 1 else None

    def resolve(self, handles: Iterable[str]) -> dict[str, str]:
        """The names for those of ``handles`` that have one."""
        resolved: dict[str, str] = {}
        for handle in handles:
            name = self.name_for(handle)
            if name:
                resolved[handle] = name
        return resolved


__all__ = ["ContactNames", "handle_key"]

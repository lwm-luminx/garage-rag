"""Detection of cloud placeholder (non-materialized) files.

Cloud storage clients on macOS -- Dropbox, iCloud Drive, OneDrive -- leave
stubs on disk for files that live only in the cloud. They appear in directory
listings with plausible names and modification times, which makes them
indistinguishable from real files to a naive walker. Clients built on the File
Provider framework (iCloud Drive; Dropbox since macOS 12.5, under
``~/Library/CloudStorage``) leave *dataless* files that report their real size;
the older Dropbox client left zero-byte files with an extended attribute.

This matters more than it sounds. *Reading* such a stub asks the provider to
materialize it, so a bulk ingest over a large online-only folder silently turns
into a multi-hundred-gigabyte download. Detecting them up front lets the walker
skip and *report* them instead of quietly triggering that.

Three independent signals, because providers differ and none is sufficient alone:

1. A provider-specific extended attribute. The pre-File-Provider Dropbox
   client sets ``com.dropbox.placeholder``; iCloud uses ``com.apple.ubiquity.*``.
   This is the only signal that catches that older Dropbox client, which does
   *not* set the dataless flag.
2. The macOS ``SF_DATALESS`` file flag, set by the File Provider framework.
   Catches iCloud and File Provider Dropbox stubs, which report a nonzero
   logical size.
3. iCloud's ``.name.icloud`` sidecar naming convention.

A zero-byte file with none of these is a genuinely empty file, which is a
different and harmless condition.

Note on the xattr call: ``os.listxattr`` exists only on Linux, so on macOS the
libc ``listxattr(2)`` is called through ctypes.
"""

from __future__ import annotations

import ctypes
import ctypes.util
import logging
import os
import sys
from pathlib import Path

log = logging.getLogger(__name__)

# macOS: file is a dataless placeholder managed by a File Provider extension.
# Defined in sys/stat.h; Python's stat module does not export it.
SF_DATALESS = 0x40000000

# listxattr(2) option: do not follow symlinks.
_XATTR_NOFOLLOW = 0x0001

_PLACEHOLDER_XATTRS: frozenset[str] = frozenset(
    {
        "com.dropbox.placeholder",
        "com.apple.fileprovider.dataless",
        "com.apple.ubiquity.unsyncedItem",
    }
)

_PLACEHOLDER_XATTR_PREFIXES: tuple[str, ...] = (
    "com.apple.ubiquity.",
    "com.apple.fileprovider.",
)


class PlaceholderFile(Exception):
    """The file is a cloud stub, not materialized locally.

    Deliberately distinct from a generic extraction failure: the remedy is to
    download the file, not to fix a parser.
    """

    def __init__(self, path: Path, provider: str = "cloud") -> None:
        self.path = path
        self.provider = provider
        super().__init__(
            f"{path} is a non-materialized {provider} placeholder (no local content); download it to index its contents"
        )


def _load_listxattr():
    """Bind libc ``listxattr``, or return None where it is unavailable."""
    if not sys.platform.startswith("darwin"):
        return None
    try:
        libc_path = ctypes.util.find_library("c")
        libc = ctypes.CDLL(libc_path, use_errno=True)
        func = libc.listxattr
    except (OSError, AttributeError):  # pragma: no cover - platform dependent
        return None
    # ssize_t listxattr(const char *path, char *namebuf, size_t size, int options)
    func.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_int]
    func.restype = ctypes.c_ssize_t
    return func


_listxattr = _load_listxattr()


def list_xattrs(path: Path) -> tuple[str, ...]:
    """Extended attribute names on ``path``. Empty tuple on any failure."""
    # Linux and any future platform where Python exposes this natively.
    native = getattr(os, "listxattr", None)
    if native is not None:
        try:
            return tuple(native(path, follow_symlinks=False))
        except OSError:
            return ()

    if _listxattr is None:
        return ()

    encoded = os.fsencode(str(path))
    size = _listxattr(encoded, None, 0, _XATTR_NOFOLLOW)
    if size <= 0:
        return ()
    buffer = ctypes.create_string_buffer(size)
    written = _listxattr(encoded, buffer, size, _XATTR_NOFOLLOW)
    if written <= 0:
        return ()
    # The result is a packed sequence of NUL-terminated names.
    return tuple(name.decode("utf-8", errors="replace") for name in buffer.raw[:written].split(b"\x00") if name)


def provider_from_xattrs(attrs: tuple[str, ...]) -> str | None:
    """Name the sync provider implied by a set of extended attributes."""
    for attr in attrs:
        if attr == "com.dropbox.placeholder":
            return "Dropbox"
        if attr.startswith("com.apple.ubiquity."):
            return "iCloud Drive"
        if attr.startswith("com.apple.fileprovider."):
            return "File Provider"
    return None


def _has_placeholder_xattr(attrs: tuple[str, ...]) -> bool:
    return any(attr in _PLACEHOLDER_XATTRS for attr in attrs) or any(
        attr.startswith(prefix) for attr in attrs for prefix in _PLACEHOLDER_XATTR_PREFIXES
    )


def check_materialized(path: Path, *, size: int | None = None, st: os.stat_result | None = None) -> None:
    """Raise :class:`PlaceholderFile` if ``path`` is an unmaterialized stub.

    Pass ``st`` (or ``size``) to reuse a ``stat`` the caller already performed;
    the walker stats every file anyway, and this runs across ~200k of them.
    """
    # iCloud's sidecar convention: the real name hides behind ".name.icloud".
    if path.name.startswith(".") and path.name.endswith(".icloud"):
        raise PlaceholderFile(path, "iCloud Drive")

    if st is None and size is None:
        try:
            st = path.stat()
        except OSError:
            return

    # SF_DATALESS can be set on files reporting a nonzero logical size, so this
    # check cannot be gated behind size == 0.
    if st is not None and bool(getattr(st, "st_flags", 0) & SF_DATALESS):
        raise PlaceholderFile(path, provider_from_xattrs(list_xattrs(path)) or "File Provider")

    effective_size = st.st_size if st is not None else size
    if effective_size is None or effective_size > 0:
        return

    # Zero bytes: the xattr decides stub versus genuinely empty.
    attrs = list_xattrs(path)
    if _has_placeholder_xattr(attrs):
        raise PlaceholderFile(path, provider_from_xattrs(attrs) or "cloud")


def is_placeholder(path: Path, *, size: int | None = None, st: os.stat_result | None = None) -> bool:
    """Non-raising form of :func:`check_materialized`."""
    try:
        check_materialized(path, size=size, st=st)
    except PlaceholderFile:
        return True
    return False

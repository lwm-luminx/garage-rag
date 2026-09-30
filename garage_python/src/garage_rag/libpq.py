"""Point psycopg at Garage's own libpq: the one built from ``//ext/postgres``.

psycopg's pure Python implementation locates libpq via ``ctypes.util.find_library``
and falls back to ``pg_config --libdir``. Inside a hardened-runtime process that
resolves to a Homebrew/system copy signed by a different Team ID, which dyld
rejects ("mapping process and mapped file (non-platform) have different Team IDs").

In the app, the framework links libpq, so it is already loaded when Python starts
(:func:`garage_rag.native.loaded_library`); this module makes psycopg use that copy.
It must run before ``psycopg`` is imported (``garage_rag/__init__.py`` calls it).

Windows has no system libpq, and a binary wheel's bundled copy would be a second Postgres version
beside the server's. ``GARAGE_LIBPQ`` names the ``libpq.dll`` built from ``//ext/postgres`` (the
Windows build's ``pgsql\bin``, or the folder holding it), and psycopg loads that one. Without it,
psycopg searches ``PATH`` as usual.
"""

from __future__ import annotations

import ctypes.util
import os
import sys
from collections.abc import Callable
from pathlib import Path

from garage_rag.native import loaded_library

# psycopg asks for "libpq.dll" on Windows, "libpq.dylib" on macOS and "pq" elsewhere.
_LIBPQ_NAMES = frozenset({"pq", "libpq", "libpq.dll", "libpq.dylib", "libpq.5.dylib", "libpq.5"})

LIBPQ_ENV = "GARAGE_LIBPQ"


class LibpqNotFound(RuntimeError):
    """``GARAGE_LIBPQ`` names no ``libpq.dll``."""


def configured_library() -> str | None:
    """The ``libpq.dll`` ``GARAGE_LIBPQ`` names on Windows (the file, or the folder holding it).

    None when the variable is unset, and off Windows, where libpq comes from the system or the app.
    Raises :class:`LibpqNotFound` when it is set but names no ``libpq.dll``, rather than letting
    psycopg fall back to whatever ``PATH`` holds.
    """
    if sys.platform != "win32":
        return None
    value = os.environ.get(LIBPQ_ENV, "").strip()
    if not value:
        return None
    path = Path(value)
    if path.is_dir():
        path = path / "libpq.dll"
    if not path.is_file():
        raise LibpqNotFound(f"{LIBPQ_ENV} names {value}, which holds no libpq.dll")
    return str(path.resolve())


def configure() -> str | None:
    """Install a ``ctypes.util.find_library`` shim that resolves libpq to Garage's copy.

    That is the copy already loaded in the app, or on Windows the one ``GARAGE_LIBPQ`` names.
    Idempotent; returns the path that psycopg will use (or ``None`` when there is neither, as in
    a plain venv, where psycopg's own search applies).
    """
    path = loaded_library("pq") or configured_library()
    if not path:
        return None
    if getattr(ctypes.util, "_garage_libpq_path", None) == path:
        return path

    original: Callable[[str], str | None] = getattr(
        ctypes.util, "_garage_original_find_library", ctypes.util.find_library
    )

    def find_library(name: str) -> str | None:
        if name in _LIBPQ_NAMES:
            return path
        return original(name)

    # Monkey-patching ctypes.util is the whole point of this module, so each of
    # these three writes is deliberate: two private stash slots this module
    # invents (read back by the getattr calls above) and the shim itself.
    ctypes.util._garage_original_find_library = original  # ty: ignore[unresolved-attribute]
    ctypes.util._garage_libpq_path = path  # ty: ignore[unresolved-attribute]
    ctypes.util.find_library = find_library  # ty: ignore[invalid-assignment]
    return path

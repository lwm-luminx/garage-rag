"""garage_rag.native: finding a library among the images loaded into the process."""

from __future__ import annotations

import ctypes
import sys

import pytest

from garage_rag import libpq
from garage_rag.native import loaded_library

darwin_only = pytest.mark.skipif(sys.platform != "darwin", reason="dyld image list is macOS only")


@darwin_only
def test_finds_a_loaded_library_by_name():
    ctypes.CDLL("/usr/lib/libz.1.dylib")
    path = loaded_library("z")
    assert path is not None
    assert path.endswith("/libz.1.dylib")


def test_a_library_that_is_not_loaded_is_none():
    assert loaded_library("garage-no-such-library") is None


@pytest.mark.skipif(sys.platform == "darwin", reason="elsewhere there is no dyld image list")
def test_nothing_is_found_off_macos():
    assert loaded_library("c") is None


def test_psycopg_is_pointed_at_the_loaded_libpq(monkeypatch):
    monkeypatch.setattr(libpq, "loaded_library", lambda name: "/frameworks/libpq.dylib" if name == "pq" else None)
    monkeypatch.setattr(libpq.ctypes.util, "find_library", lambda name: f"/usr/lib/lib{name}.dylib")
    for slot in ("_garage_libpq_path", "_garage_original_find_library"):
        monkeypatch.delattr(libpq.ctypes.util, slot, raising=False)

    assert libpq.configure() == "/frameworks/libpq.dylib"
    assert libpq.ctypes.util.find_library("pq") == "/frameworks/libpq.dylib"
    assert libpq.ctypes.util.find_library("z") == "/usr/lib/libz.dylib"


def test_without_a_loaded_libpq_psycopg_searches_as_usual(monkeypatch):
    monkeypatch.setattr(libpq, "loaded_library", lambda name: None)
    monkeypatch.delenv(libpq.LIBPQ_ENV, raising=False)
    assert libpq.configure() is None


def _forget_shim(monkeypatch):
    for slot in ("_garage_libpq_path", "_garage_original_find_library"):
        monkeypatch.delattr(libpq.ctypes.util, slot, raising=False)


def test_on_windows_garage_libpq_names_the_ext_postgres_build(monkeypatch, tmp_path):
    dll = tmp_path / "pgsql" / "bin" / "libpq.dll"
    dll.parent.mkdir(parents=True)
    dll.write_bytes(b"")
    monkeypatch.setattr(libpq.sys, "platform", "win32")
    monkeypatch.setattr(libpq, "loaded_library", lambda name: None)
    monkeypatch.setattr(libpq.ctypes.util, "find_library", lambda name: None)
    _forget_shim(monkeypatch)

    # The folder or the file itself.
    monkeypatch.setenv(libpq.LIBPQ_ENV, str(dll.parent))
    assert libpq.configured_library() == str(dll.resolve())
    monkeypatch.setenv(libpq.LIBPQ_ENV, str(dll))
    assert libpq.configure() == str(dll.resolve())
    # psycopg's own lookup on Windows.
    assert libpq.ctypes.util.find_library("libpq.dll") == str(dll.resolve())


def test_garage_libpq_naming_nothing_is_an_error_not_a_fallback(monkeypatch, tmp_path):
    monkeypatch.setattr(libpq.sys, "platform", "win32")
    monkeypatch.setenv(libpq.LIBPQ_ENV, str(tmp_path))
    with pytest.raises(libpq.LibpqNotFound, match="holds no libpq.dll"):
        libpq.configured_library()


def test_garage_libpq_is_ignored_off_windows(monkeypatch, tmp_path):
    monkeypatch.setattr(libpq.sys, "platform", "darwin")
    monkeypatch.setenv(libpq.LIBPQ_ENV, str(tmp_path))
    assert libpq.configured_library() is None

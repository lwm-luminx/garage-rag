"""psycopg's C implementation, as the app builds it in (//ext/psycopg_c)."""

from __future__ import annotations

import re
import tomllib
from pathlib import Path

import pytest

from garage_rag import libpq

TESTS = Path(__file__).resolve().parent
LOCKFILE = TESTS.parent / "uv.lock"
MODULE_FILE = TESTS.parent.parent / "ext" / "psycopg_c" / "psycopg_c.MODULE.bazel"


def _locked_psycopg() -> str:
    lock = tomllib.loads(LOCKFILE.read_text(encoding="utf-8"))
    return next(package["version"] for package in lock["package"] if package["name"] == "psycopg")


def test_the_built_in_psycopg_c_is_psycopgs_own_release():
    # psycopg calls into psycopg_c with its own release's signatures (3.3.6 passes wait_c a
    # `timeout` 3.3.4 does not take), so the sdist //ext/psycopg_c builds must be the psycopg in uv.lock.
    module = MODULE_FILE.read_text(encoding="utf-8")
    pinned = re.search(r'strip_prefix = "psycopg_c-([^"]+)"', module)
    assert pinned is not None
    assert pinned.group(1) == _locked_psycopg()
    assert module.count(f"psycopg_c-{pinned.group(1)}.tar.gz") == 1


def test_with_psycopg_c_built_in_nothing_is_configured(monkeypatch):
    monkeypatch.setattr(
        libpq.sys, "builtin_module_names", (*libpq.sys.builtin_module_names, "psycopg_c.pq", "psycopg_c._psycopg")
    )
    monkeypatch.setattr(libpq, "loaded_library", lambda name: pytest.fail("looked for a loaded libpq"))
    assert libpq.builtin_psycopg_c()
    assert libpq.configure() is None


def test_the_interpreters_here_have_no_built_in_psycopg_c():
    assert not libpq.builtin_psycopg_c()

# Python 3.14 evaluation (standard build)

Date: 2026-09-27. Branch: claude/project-thread-mxczt0 (PR #137 against v1.5-beta).

## Result

Garage runs on CPython 3.14.7 with no code changes. The move is pins only.

## What was checked (Linux, python-build-standalone 3.14.7)

- pytest: 1494 passed, 52 skipped (Postgres and libtesseract tests, same as on 3.13).
- `python -X dev -W error` run: one pre-existing ResourceWarning (an unclosed sqlite3 connection in
  test_scanner) that fails identically on 3.13; not a 3.14 issue.
- ruff check / format clean, also with target-version py314.
- uv.lock: requires-python is already `>=3.13,<3.15` and every compiled dep has cp314 or abi3
  macOS wheels at the locked version. No repin needed.
- Embedding shim (GaragePythonEmbed.c): PyConfig, PyStatus, PyGILState, PyRun_SimpleString,
  Py_FinalizeEx only. All unchanged in 3.14.
- PythonKit 0.5.1: searches Python.framework/Versions/3.<n> from 3.30 down, so 3.14 is found.
- rules_python 2.3.3 knows 3.14 (3.14.4). rules_py 2.0.0-alpha.6 resolves 3.14 from PBS release 20260303.

## What the PR changes

ext/python (3.14.7 tarball), MODULE.bazel, .bazelrc, ext/python/BUILD.bazel and
macapp/externals/BUILD.bazel paths (Versions/3.14, python3.14, config-3.14-darwin),
bazel/codesign.bzl install names, CI venvs, Windows host python, session hook, docs,
tools/third_party_notices.py + regenerated notices (adds pyzstd notice).

## Left for a Mac

- The framework build (macOS workflow runs on the PR).
- `bazel mod deps --lockfile_mode=update` and commit MODULE.bazel.lock.
- Optional: narrow pyproject to `>=3.14,<3.15` and run tools/repin.
- 3.14 adds compression.zstd; the macOS SDK has no libzstd so `_zstd` is skipped. Add `//ext/zstd`
  only if something needs it (nothing in Garage does).
- Optional: CPython's `--with-app-store-compliance` configure flag (3.13+) patches out code Apple
  has rejected in the past; worth a look for the store build.

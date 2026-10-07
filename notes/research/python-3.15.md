# Python 3.15 (pre-release) evaluation

Date: 2026-09-27. Base: `v1.5-beta` at 7243401, which already carries PR #137 (CPython 3.14.7).
Interpreter: CPython **3.15.0rc2** (python-build-standalone release 20260924, via uv 0.12.19), Linux x86_64.
Companions: `python314/findings.md` (the 3.14 move) and `free-threaded-python/findings.md`.

## Short answer

Garage's own code runs on 3.15.0rc2 unchanged: the pytest suite passes (1494 passed, 52 skipped, the
same skips as 3.13/3.14), ruff is clean with `--target-version py315`, the Swift syntax checker runs,
and the embedding shim compiles with `-Wall -Werror` against the 3.15 headers. What holds it back is
the dependency set, not Garage:

1. **pydantic**: the current stable release (2.13.5) pins `pydantic-core==2.46.5`, which has **no
   cp315 wheel**. The first pydantic-core with cp315 wheels (2.48.0) is only required by the
   **2.14 betas** (2.14.0b2 -> core 2.49.0). Without 2.14 final, 3.15 means either a beta pydantic or
   building pydantic-core from source (Rust) in the Bazel sdist path. mcp 2.1.0 works with 2.14.0b2.
2. **grpcio / grpcio-tools** 1.83.1 (locked) have no cp315 wheel; **1.84.0** does.
3. **pydantic-core 2.46.4, SQLAlchemy 2.0.x** have no cp315 wheels at any 2.0.x version. SQLAlchemy
   ships a `py3-none-any` wheel, so 2.0.52 still installs (pure Python, no Cython speedups) and the suite
   passes on it; **SQLAlchemy 2.1.1** has cp315 wheels and the suite also passes on it. 2.1 is a feature
   release, so moving to it is its own change.
4. **PyYAML 6.0.3** has no cp315 wheel; the sdist builds. Garage only calls `yaml.safe_load` /
   `safe_dump` (the pure-Python loader), so the C extension doesn't matter.
5. Dev only: **tree-sitter 0.26.0** builds from sdist fine; tree-sitter-swift is abi3 and loads.

Already fine at the locked versions: cffi 2.1.1, charset-normalizer 3.5.1, lxml 6.1.2, Pillow 12.3.0,
regex 2026.9.10, rpds-py 2026.6.3 (all cp315 macOS arm64 wheels); cryptography 43.0.3 and protobuf
7.36 (abi3, protobuf uses `upb`); pypdfium2 and ruff (platform wheels).

Recommendation: **not for 1.5, and not before 3.15.0 final plus pydantic 2.14 final.** Once those
exist the move is the same shape as #137 (pins and per-version paths) plus four lock bumps
(pydantic 2.14, grpcio/grpcio-tools 1.84, and either SQLAlchemy 2.1 or accepting pure-Python 2.0).
Target it for the release after 1.5, not the beta.

## Embedding (macOS app)

- `GaragePythonEmbed.c` uses PyPreConfig/PyConfig isolated init, `Py_InitializeFromConfig`,
  `PyGILState_*`, `PyEval_SaveThread`, `PyRun_SimpleString`, `Py_FinalizeEx`. It compiles with
  `-Wall -Werror` (deprecations included) against the 3.15.0rc2 headers.
- PythonKit 0.5.1 (dlsym): every C-API symbol it uses that I checked is still exported by
  `libpython3.15` (Py_IncRef/Py_DecRef, PyObject_*, PyDict_*, PyList_*, PyTuple_*, PyLong_*,
  PyFloat_*, PyUnicode_AsUTF8, PyErr_Fetch, PyCFunction_NewEx, PyInstanceMethod_New,
  `_Py_NoneStruct`/`_Py_TrueStruct`/`_Py_FalseStruct`, the type objects). The list is from memory of
  PythonKit's symbol table: GitHub was not reachable from this session to re-read its source, so a Mac
  build is the real check. Its framework search runs from 3.30 down, so `Versions/3.15` is found.
- 3.15 makes UTF-8 mode the default (PEP 686). The shim already sets `preconfig.utf8_mode = 1`,
  so nothing changes for the app; the venv/CLI gets the same behaviour for free.

## Build system (not verified here; needs a Mac)

- `ext/python`: 3.15.0 source tarball; the same per-version path edits #137 made for 3.14
  (`Versions/3.15`, `python3.15`, `config-3.15-darwin`, codesign install names, notices, CI venvs).
- rules_py 2.0.0-alpha.6 resolves interpreters from python-build-standalone 20260303, which predates
  3.15 rc builds; 3.15 needs a newer PBS release (20260924 has 3.15.0rc2) or a newer rules_py.
  rules_python 2.3.3 likely doesn't know 3.15 either. python.org, GitHub and the Bazel registry were
  blocked from this session, so neither was checked.
- pyproject `requires-python` must become `<3.16`; with `tools/repin`, the lock adds cp315 wheels but
  keeps pydantic 2.13 (no cp315 core), so the bumps above have to be explicit.

## What 3.15 offers Garage

| Feature | Measured / checked | Worth it? |
|---|---|---|
| **Explicit lazy imports (PEP 810)** | `garage --help` 572 -> 280 ms and `garage config get` 489 -> 228 ms on 3.15 by adding a `__lazy_modules__` list (sqlalchemy, rich, `garage_rag.db.*`, mcp install, search) to `cli.py`; suite still passes. `__lazy_modules__` is ignored before 3.15, so it is safe to add on 3.14 but buys nothing until then. | Yes, once on 3.15: the launchers and stdio `garage-mcp` start-up are what users feel. |
| Global lazy mode (`-X lazy_imports=all`) | Breaks third-party code: pytest's assertion rewriter (import cycle), pydantic schema generation (`<lazy_import ...>` types), a type registry ("Type object is already registered"), importlib.metadata. | No. Opt in per module only. |
| Egress guard vs `lazy import` | `lazy import httpx` parses to `ast.Import(is_lazy=1)`; `test_egress_block._imported_modules` still reports it. | The choke-point scan already covers the new syntax. |
| Interpreter speed | `chunk_markdown` over 6764 text files, best of 5: 3.13.12 5.22 s, 3.14.7 4.58 s, 3.15.0rc2 4.47 s, 3.15 with `PYTHON_JIT=1` 4.24 s. Module import times within noise of 3.14. | Small: ~2% over 3.14, ~5% more with the JIT. Not a reason to move on its own. |
| Sampling profiler (PEP 799, `profiling.sampling`) | Not run. Attaching to a live XPC service needs task_for_pid, which the hardened runtime denies; `python -m profiling.sampling run` on the venv CLI works for ingest profiling. | Handy for dev, no ship impact. |
| Free-threaded 3.15t | grpcio still has no `t` wheel (1.84.0 included); lxml, pydantic-core 2.49, SQLAlchemy 2.1, Pillow, cffi, regex, rpds-py have cp315t. | Same blocker as 3.14t (grpcio). |

## Nothing landed

No PR: every change that helps (lock bumps, the `__lazy_modules__` list) either depends on
pre-release packages or does nothing until Garage ships 3.15. The `__lazy_modules__` diff for `cli.py`
is the first thing to do after the move; `mcp_server/server.py` (1.2 s import, mostly mcp/pydantic)
is the next candidate.

## Re-check list for 3.15.0 final

1. pydantic 2.14.0 final with a cp315 pydantic-core.
2. Bump grpcio/grpcio-tools to >=1.84 (fine on 3.14 too; could go in any time).
3. Decide SQLAlchemy 2.1 vs pure-Python 2.0 wheel.
4. rules_py / rules_python releases that know 3.15; PBS release with 3.15.0.
5. A Mac framework build and the M4 `aspect test //...` run, as for #137.

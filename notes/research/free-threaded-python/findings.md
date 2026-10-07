# Free-threaded (GIL-free) Python for Garage

Evaluated 2026-09-27 against `v1.5-beta` (50ef577). Companion to the separate Python 3.14 evaluation
thread; this note covers only the free-threaded build (`--disable-gil`, ABI tag `t`).

## Short answer

Garage's own code runs on free-threaded Python today: the whole pytest suite passes on CPython
3.14.7t (1494 passed, 52 skipped), both with the interpreter's default behaviour and with
`PYTHON_GIL=0` forcing the GIL off. Two dependencies stand in the way of shipping it:

1. **grpcio** publishes no free-threaded wheels for any version (checked 1.83.1 and 1.84.0 on PyPI)
   and its Cython extension `grpc._cython.cygrpc` **re-enables the GIL at import**. Every Garage
   process that serves or calls `GarageService` imports it, so in practice the app would run with the
   GIL on anyway unless forced off "at your own risk".
2. **lxml** (6.1.2 and 6.1.3, pulled in by python-docx and python-pptx) ships cp314t wheels but has
   not declared free-threading support, so `lxml.etree` also re-enables the GIL.

Everything else imports clean (no GIL re-enable): cffi, cryptography 50, Pillow, pydantic-core,
PyYAML (with the C loader), regex, rpds-py, psycopg (pure Python over libpq), pypdfium2, SQLAlchemy.

Recommendation: **not for 1.5.** Revisit when grpcio ships `cp314t` wheels (or Garage's gRPC use moves
to something else) and lxml declares support. The build-system work below is modest and could be
prepared on a branch in the meantime; the win is real but only materialises once ingest runs
extraction in parallel, which it does not today.

## What the free-threaded build means for the dependency set

The ecosystem has moved on from 3.13t: the current release of every native dependency publishes
`cp314t` wheels but **no `cp313t` wheels** (pydantic-core, Pillow, SQLAlchemy, regex, rpds-py all had
cp313t wheels in earlier releases and dropped them). Free-threaded Garage therefore means Python
3.14t, which ties this to the 3.14 evaluation.

The limited API / stable ABI is not available on free-threaded builds (`Python.h` errors out with
"The limited API is not currently supported in the free-threaded build" on 3.14.7). Every `abi3`
wheel Garage uses today is affected:

| Package | Lock today | Free-threaded state |
|---|---|---|
| grpcio 1.83.1 | cp313 wheel | **No `t` wheel for any version.** Builds from source (about 20 min on 4 cores) and then re-enables the GIL. |
| grpcio-tools | cp313 wheel (dev only) | Same; built from source for this test. |
| protobuf 7.36.x | cp310-abi3 wheel (upb) | abi3 cannot load, so protobuf silently falls back to its **pure-Python implementation** (`api_implementation.Type() == "python"`), several times slower on the wire. |
| cryptography 43.0.3 (pinned `<44`) | cp37-abi3 wheel | Source build fails (limited API). cryptography 50.0.1 has a `cp314t` macOS arm64 wheel; the `<44` pin, which has no recorded reason, has to go. |
| lxml 6.1.x | cp313 universal2 | `cp314t` wheel exists, re-enables the GIL on import. |
| tree-sitter-swift 0.7.3 (dev) | cp38-abi3 | Does not build on a free-threaded interpreter. Dev-only (`tools/swiftcheck`), so the dev extras would need a marker or a second interpreter. |
| charset-normalizer | cp37-abi3 + pure-Python | Falls back to pure Python; harmless. |
| pypdfium2, ruff | `py3-none-<platform>` | ctypes / standalone binary; unaffected. |
| psycopg, psycopg-pool | pure Python | Unaffected (already the non-`c` flavour). |
| pydantic-core, Pillow, PyYAML, regex, rpds-py, cffi, SQLAlchemy | cp313 wheels | `cp314t` macOS arm64 wheels on PyPI; `uv.lock` already lists them for several. |

## What the embedding side looks like

- `GaragePythonEmbed.c` uses only the PyConfig API plus `PyGILState_Ensure/Release` and
  `PyEval_SaveThread`. All of these exist and behave on a free-threaded build: `PyGILState_Ensure`
  still attaches the calling thread and is still required before touching objects. The
  `withGIL` rule in `GaragePythonRuntime` (create, use and release `PythonObject`s inside one scope)
  stays exactly as it is; nothing in the shim needs to change.
- **PythonKit 0.5.1** loads every C-API symbol with `dlsym` and manages references through the
  `Py_IncRef`/`Py_DecRef` functions, never through `ob_refcnt` or the object header, so the
  changed `PyObject` layout of the free-threaded build does not reach it. Checked against the
  upstream source of `Python.swift` and `PythonLibrary.swift` at v0.5.1.
- **CPython's framework build supports `--disable-gil`** (configure appends `t` to `ABIFLAGS`;
  mimalloc, which it requires, is on by default on macOS). The only build-system consequence is the
  ABI suffix appearing in paths and names, all of which are hard-coded today:
  - `ext/python/BUILD.bazel`: add `--disable-gil` to `configure_options`; the `python_headers`
    include path becomes `include/python3.14t`.
  - `macapp/externals/BUILD.bazel`: the stdlib copy globs `lib/python3.13/**` and
    `config-3.13-darwin` become `lib/python3.14t/**` and `config-3.14t-darwin`.
  - `bazel/codesign.bzl`: the `@rpath/Python.framework/Versions/3.13/Python` install names.
  - `tools/third_party_notices.py` and the CI workflows pin the interpreter version string.
  - `ext/python`'s `PythonAppsDir`/framework name can stay `Python.framework`; python.org's installer
    renames the free-threaded framework to `PythonT.framework` only so both can coexist.
- **Bazel toolchains.** `rules_python` 2.3.3 has a `py_freethreaded` config setting and
  free-threaded python-build-standalone archives; `aspect_rules_py` 2.0.0-alpha.6's
  `python_interpreters` extension has a `freethreaded` mode selected at build time. The `@pypi` hub
  is resolved from `uv.lock`, which already records `cp314t` wheels where they exist; packages
  without one (grpcio) would fall to `rules_py`'s sdist build inside Bazel.

## Test results (Linux x86_64, 4 cores, CPython 3.14.7 free-threading build)

Environment: `uv venv --python 3.14t`, `uv pip install -e . pytest-asyncio ruff grpcio-tools
--override cryptography>=50`, with `tree-sitter`/`tree-sitter-swift` left out. grpcio 1.84.0 and
grpcio-tools built from source.

| Run | Result |
|---|---|
| `pytest tests` (default: grpc re-enables the GIL when imported) | 1494 passed, 52 skipped, 54.9 s |
| `PYTHON_GIL=0 pytest tests` (GIL forced off, grpc and lxml included) | 1494 passed, 52 skipped, 55.0 s |

The skips are the usual ones (no Postgres server, no live model server, no Tesseract). Note the
forced-off run is one pass of a suite that mostly runs single-threaded; it is not evidence that
grpcio's extension is thread-safe without the GIL.

### Where parallelism would pay

Ingest is a sequential loop (`ingest_source` walks and calls `ingest_one` per candidate;
`ingest/pipeline.py`). Extraction (pypdf, pdfminer/pdfplumber, python-docx, openpyxl) and chunking
are pure-Python CPU work, so a free-threaded build helps only once that loop hands documents to a
thread pool. A small benchmark of `chunk_markdown` over the fixture corpus (1506 documents, 4
threads) shows the shape of the gain:

| Interpreter | 1 thread | 4 threads |
|---|---|---|
| 3.13 (stock, system) | 0.67 s | 0.61 s |
| 3.14.7t, `PYTHON_GIL=1` | 1.01 s | 1.31 s |
| 3.14.7t, `PYTHON_GIL=0` | 0.80 s | 0.23 s |

So about 3.5x on four cores when the GIL is off, and roughly a 20% single-thread cost against stock
3.13 (3.14t restored the specialising interpreter, which 3.13t had disabled). On an Apple Silicon
Mac with 8 to 12 performance cores the multiplier would be higher, but the same result is available
today by ingesting in several processes, which the Beta item to run workers as inherit children
(backlog A2) already points at.

Things that would need a look before real parallel ingest, GIL or not: `ingest/__init__.py`'s
process-wide progress and log callbacks (already behind an `RLock`), the module-level tesseract and
image locks (already present), and one SQLAlchemy `Session` per document (already the case; the
engine pool is thread-safe).

## Suggested path

1. Nothing for 1.5. Keep the GIL build; the app's parallelism story is per-process (XPC services)
   and stays that way.
2. Beta or later: lift the `cryptography<44` pin independently of this (it blocks 3.14t and has no
   recorded reason; 50.x is current).
3. Track two upstreams: grpcio free-threaded wheels (grpc/grpc issue tracker, "free-threading") and
   lxml's `Py_mod_gil` declaration. When both land, the build changes above are a day's work plus a
   Mac build, and a `PYTHON_GIL`-style switch is not needed because the interpreter is chosen at
   build time.
4. If Garage wants parallel extraction before then, a `ThreadPoolExecutor` around `ingest_one` gives
   nothing on the GIL build; a small process pool for extraction does, and carries over unchanged
   to a free-threaded build.

## Update 2026-09-27, Mac results

The full app was built and tested on 3.14.7t on the M4: see `m4-results.md` beside this file and
draft PR #151. Two corrections to the table above from that run: SQLAlchemy's `cyextension` also
re-enables the GIL (2.0.x in the lock; the Linux venv had 2.1.1, which has no compiled extension),
and protobuf's abi3 extension does not merely fail to load on macOS, it segfaults, so `google/_upb`
has to be excluded from site-python. The embedding shim's isolated PyConfig ignores `PYTHON_GIL`;
forcing the GIL off there would need `config.enable_gil`.

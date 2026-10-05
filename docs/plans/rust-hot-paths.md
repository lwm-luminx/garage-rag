---
layout: default
title: Rust Hot Paths — Native Kernels for Ingest
description: Moving the ingest pipeline's measured CPU hot spots (the quality gate, the text splitters and the walker's per-file pass) into one Rust library loaded through ctypes, with the Python code kept as the reference implementation and the golden tests as the conformance suite.
date: 2026-10-04
status: Proposed
status_kind: proposed
---

# Rust hot paths: native kernels for ingest

Garage's ingest is Python end to end: walk, extract, gate, chunk, attribute, store. Profiling it
shows that three small, self-contained pieces of that path take most of the CPU the pipeline spends
per document, and that each of them is a pure function of bytes with no I/O, no database and no
network. They are the shape of code that Rust does well and Python does badly: character-by-character
scans and regex passes over text, and glob matching over every filename a walk sees.

This plan moves those three pieces into one Rust library, `libgarage_native`, called from Python
through ctypes the way `libtesseract` and `libpq` already are. The Python implementations stay as the
reference and as the fallback: a venv without the library, a PyPI install, or `GARAGE_NATIVE=0` runs
the pure-Python path, and a conformance test holds the two to identical output. The chunk goldens that
already pin the splitters' output byte for byte are the acceptance test, so the stored chunker ids,
and with them every vector in the corpus, survive the port.

The plan deliberately stops where the measurements stop. After these ports the ingest is bound by the
gRPC round trip and the Postgres transaction each document already pays, and by the PDF extractors,
none of which a Rust kernel changes. Section 2 lists what is not in scope and why.

## 1. Where the time goes

### 1.1 Method

Two measurements, both on 2026-10-04 against `main` at `db351e8`, CPython 3.14.7, a Linux x86-64
container. Absolute numbers will differ on an Apple silicon Mac; the shares and ratios are what this
plan rests on, and milestone 0 re-takes them on a Mac before any Rust is written.

1. **A whole ingest under cProfile.** `ingest_source()` over `tests/corpora/second-brain-os` (250
   Markdown files, 1.3 MB) with the `RecordingGateway` from `tests/test_second_brain_corpus.py`, so
   storage costs nothing and what remains is the pipeline's own CPU.
2. **Each candidate in isolation.** `time.perf_counter`, best of three, on synthetic inputs sized like
   real files: generated prose, Markdown with headings and fenced code, Python classes, a single-line
   minified JavaScript bundle, timestamped log lines, and a synthetic tree of 30k files.

Milestone 0 commits the harness as `tools/bench/` so these tables can be regenerated with one command.

### 1.2 Share of ingest CPU on the corpus

| Stage | Share of the run | Notes |
| --- | ---: | --- |
| `extract/quality.py::assess` | 25.6% | `_alpha_ratio` alone is 19.5%: a Python generator over every character of a 64 KB sample |
| `ingest/chunking.py::chunk_text` | 17.4% | `MarkdownHeaderSplitter.split_text` is 12.7%: `"".join(filter(str.isprintable, ...))` per line |
| `attribute/resolver.py::resolve` | 16.9% | `pathrules.classify_path` 8.7%, `git.find_repo_root` 7.8% (a `stat` per ancestor, per file) |
| `extract/dispatch.py::extract` | 16.8% | reading, YAML front matter (8%), `normalize_text` |
| scan plus walk | 14.4% | the tree is walked twice, once to count and once to ingest |

Per document that is about 2.6 ms of Python. For comparison, a real ingest also pays one gRPC
`CheckDocumentStat` round trip and one Postgres transaction per document, so the Python share is
roughly half of the per-document cost today and the I/O half is untouched by this plan.

### 1.3 The candidates in isolation

| Function | Input | Time | Throughput |
| --- | --- | ---: | ---: |
| `quality.assess` | 100 KB prose (64 KB sample) | 6.0 ms | 11 MB/s |
| `quality.assess` | 64 KB of log lines | 9.1 ms | 7 MB/s |
| `chunk_text` MARKDOWN | 100 KB | 7.7 ms | 13 MB/s |
| `MarkdownHeaderSplitter.split_text` | 100 KB | 4.4 ms | 23 MB/s |
| `chunk_text` PROSE | 100 KB | 1.0 ms | 97 MB/s |
| `chunk_text` CODE (`.py`) | 100 KB | 0.9 ms | 113 MB/s |
| `chunk_text` CODE (`.js`, one line) | 50 KB | 60 ms | 0.8 MB/s |
| `RecursiveSplitter` on one unbroken token | 160 KB | 194 ms | 0.8 MB/s |
| `normalize_text` (for scale) | 100 KB | 0.27 ms | 367 MB/s |
| `sha256` (C, for scale) | 100 KB | 0.24 ms | 424 MB/s |

The last code row is the splitter's fallback to the empty-string separator (`splitters.py`,
`_split_keeping_separator`): a line with no space becomes one piece per character, and `_merge` then
pops them one at a time with `current = current[1:]`. It is linear, but a hundred times slower than
the normal path, and code trees are full of such files: bundled JavaScript, SVG path data, lock files,
base64 blobs in source.

### 1.4 The walk

A walk over a synthetic tree of 30k files (24k of them indexable), under cProfile:

| | Time | Share |
| --- | ---: | ---: |
| `walker.walk` in total | 3.28 s | 100% |
| `_matches_any` (the diagnostic patterns) | 2.13 s | 65% |
| of which `fnmatch.fnmatch` | 1.51 s | 46% |
| `posix.stat` | 0.21 s | 6% |
| `os.walk` itself | 0.07 s | 2% |
| `os.walk` plus a `stat` per file, no predicates | 0.19 s | the syscall floor |

Each filename is matched against the twenty `DIAGNOSTIC_FILE_PATTERNS` with `fnmatch`, which
lower-cases and compiles on every call; each directory name against `DIAGNOSTIC_DIR_PATTERNS` and
`DEPENDENCY_PATH_FRAGMENTS` through `pathlib`. Per file that is 13 µs for `is_diagnostic_file` and
16 µs for `is_dependency_dir`, against 7 µs for the `stat`. The scanner (`ingest/scanner.py`) runs
the same predicates over the same tree before the ingest does, so a 192k-file source pays this twice.

### 1.5 What is not hot

Measured and found fine, so left alone: `normalize_text` (367 MB/s), the SHA-256 hashing (C),
`git log` parsing (430k lines/s, once per repository), Messages `attributedBody` decoding (about
1 µs per message), Reciprocal Rank Fusion (it runs in SQL), protobuf (the upb backend).

Two things that are hot but belong to other plans: PDF extraction runs at 175 pages/s under pypdf and
5 pages/s where it escalates to pdfplumber, and the backfill renders each vector to text with
`str(float)` per dimension (0.5 to 1.7 ms per chunk). The first is a library choice, the second a
binary adaptation in psycopg; neither is a kernel to port.

## 2. Scope

**In scope**, in the order the measurements rank them:

1. **The quality gate**, `extract/quality.py::assess`. A pure function of a string.
2. **The splitters and chunking**, `ingest/splitters.py` (`RecursiveSplitter`,
   `MarkdownHeaderSplitter`, the per-language separator tables) and `ingest/chunking.py` (`_locate`,
   the char offsets). Pure functions of a string and a few integers.
3. **The walker's per-file pass**, `ingest/walker.py`: directory pruning, the filename predicates, the
   `stat`, the cloud-placeholder check (`extract/placeholder.py`), and the `WalkStats` counters, as
   one native pass that returns candidate records. Shared with `scanner.scan_filesystem`.
4. **Optional, last:** the LangExtract alignment in `enrich/langextract/resolver.py`
   (`_best_lcs_spans`, a pure-Python triple loop costing 3 to 40 ms per fuzzily aligned fact) and
   `tokenizer.py::RegexTokenizer.tokenize` (0.9 MB/s). Textbook kernels, but the facts pass is bound
   by local LLM inference at seconds per chunk, so they are a few percent of its wall time. Measured
   first, ported only if a real facts run shows otherwise.

**Out of scope**, with the reason:

- Anything that opens a connection. `net/egress.py` stays the one choke point, in Python, where the
  AST scan in `tests/test_egress_block.py` can see it. The Rust crate opens no sockets and depends on
  no crate that does; section 5 says how that is enforced.
- Attribution's `find_repo_root` and `classify_path`. Hot, but the fix is a per-directory cache in
  Python, not a port; it goes into milestone 0.
- PDF and Office extraction, vector serialization, `git log` parsing, Messages, search, the MCP server,
  the gRPC service.

## 3. Design

### 3.1 One library with a C ABI, called through ctypes

The alternative is a PyO3 extension module. It loses on four counts here:

- **The app's conventions.** `PythonXPCService.framework` already carries `libtesseract` and `libpq`
  in its `Frameworks` folder, linked with load commands so dyld maps them at launch, before the App
  Sandbox applies, and `garage_rag.native.loaded_library()` finds the loaded copy for ctypes. A
  `cdylib` slots into that; an extension module would need its own loading story in a sandboxed
  service.
- **The build.** The module already declares `rules_rs` 0.0.61 and a Rust 1.92 toolchain, unused.
  `rules_rs` is a facade over `rules_rust`, so `rust_shared_library` and `crate.from_cargo` are
  available; nothing in Bazel builds a PyO3 module against the hermetic `python-build-standalone`
  interpreter without more work.
- **Free-threaded Python.** The `python-freethreaded` CI job runs the suite on 3.14t. A library with
  no Python API has nothing to make thread-safe on the Python side, and ctypes releases the GIL for
  the call, so chunking threads actually run in parallel there.
- **Swift later.** A C ABI is callable from `GarageIngestXPCService` directly, should the walk ever
  move out of Python.

Crate: `native/garage_native/` (`Cargo.toml`, `Cargo.lock`, `src/`), built by `//native:garage_native`
as `rust_shared_library`, producing `libgarage_native.dylib` / `.so` / `.dll`. Edition 2024, as the
toolchain declares.

### 3.2 Loading and the fallback

`garage_rag/native/__init__.py` grows `accelerator() -> ctypes.CDLL | None`, cached:

1. `GARAGE_NATIVE=0` in the environment: `None`, always. Tests and bug reports use it to force Python.
2. `loaded_library("garage_native")`: the copy dyld already mapped (the app, its XPC services, the
   launchers).
3. `GARAGE_NATIVE_LIBRARY=<path>`: an explicit path, for CI and development.
4. Otherwise `None`.

Before it is used, the library's `garage_native_abi_version()` must equal the constant in the Python
module; a mismatch logs once and returns `None`. A stale dylib must never produce different chunks than
the Python it ships with.

Each ported function keeps its Python signature and body, and gains a first line:

```python
if (lib := accelerator()) is not None:
    return _native_assess(lib, text, sample_bytes=sample_bytes)
```

The Python body below it is the specification. A behavior change lands there first, with its golden
update, and the Rust side follows. The library can be removed from a build and nothing breaks but the
speed.

### 3.3 Data across the boundary

Text goes in as UTF-8 bytes with a length. A Python `str` holding lone surrogates cannot be encoded;
that document takes the Python path (the extractors never produce one, but the fallback costs nothing).

- **`assess`** returns a struct of counts and ratios: lines, distinct line shapes, timestamped,
  dump-shaped, hex runs, base64 runs, alphabetic characters, sample length. Python keeps the
  thresholds, the "decisive" rule and the reason strings, so tuning stays in one file and the Rust
  surface is the arithmetic only.
- **Chunking** returns a packed buffer: a count, then per chunk its text length, heading length,
  `char_start` and `char_end`, followed by one UTF-8 buffer holding every text and heading. Offsets
  are code-point offsets, computed in Rust in the same pass, because `chunks.char_start` is a Python
  string index and the stored goldens are in those units. Python builds the `TextChunk` objects, a few
  hundred per document, and frees the buffer with `garage_native_free`.
- **The walker** is an iterator: `garage_native_walk_open(root, options) -> handle`,
  `garage_native_walk_next(handle, records, capacity) -> n` filling fixed-size records (path offset
  and length into a per-call string buffer, size, mtime in nanoseconds, flags for placeholder and
  oversize), and `garage_native_walk_close(handle, &stats)` returning the `WalkStats` counters. The
  policy stays in Python and goes in through `options`: `DEFAULT_EXCLUDE_DIRS`, the two pattern
  tables, `DEPENDENCY_PATH_FRAGMENTS`, `exclude_prefixes`, `include_code`, `max_file_bytes`, the
  extension sets `is_indexable` and `is_code_path` consult. Pruning happens during descent, as today.
  A walk error increments `unreadable` and continues, as `on_error` does today.

### 3.4 Semantics that must survive exactly

This is where a port goes wrong, so each item gets a test in milestone 0 before any Rust exists.

- **The separator tables are regular expressions, quirks included.** `"$"` in the LaTeX table is an
  end-of-text anchor and `"\n| "` in the Haskell table is an alternation; fixing either changes the
  chunks and so the chunker ids (`splitters.py` says so). Rust's `regex` is stricter than Python's `re`
  about an unescaped `{`, which the LaTeX table has, so the tables are translated once, at crate build
  time, with a test that every entry compiles and splits a sample the same way. The golden test covers
  a handful of languages today; milestone 0 extends it to every key of `LANGUAGE_SEPARATORS`.
- **`re.split` with a capturing group**, and the way `_split_keeping_separator` reattaches separators
  to the piece after them.
- **Python's Unicode predicates.** `str.isprintable` (everything but categories Cc, Cf, Cs, Co, Cn,
  Zl, Zp and Zs, with U+0020 printable), `str.isspace`, `str.isalpha` and `str.strip()`'s notion of
  whitespace, all against the Unicode version CPython 3.14 ships (16.0). Generated tables, not the
  `regex` crate's classes, so a Unicode bump is a visible change.
- **Regex classes in the quality gate.** `\d`, `\w`, `\b` and `\s` are Unicode-aware in both Python
  and Rust, but not identically at the edges; the conformance corpus includes non-ASCII digits,
  combining marks and CJK so a difference shows up as a failed test, not a changed verdict in the field.
- **Code-point offsets**, as above, and `_locate`'s search order: each chunk is looked for from one past
  the previous chunk's start, exact text first, then first line to last line.
- **`_merge`'s oversize debug log** is dropped; nothing reads it.
- **The walker's order.** `os.walk` yields directories top-down in `scandir` order and the pipeline's
  `limit` depends on the order candidates arrive. The Rust walk keeps directory-listing order and
  depth-first descent; the conformance test compares the yielded sequence, not just the set.

### 3.5 Build, packaging and CI

- **`MODULE.bazel`.** Add the `rules_rust` facade extension and `register_toolchains` for
  `@default_rust_toolchains` (declared today, never registered), and `crate.from_cargo` over
  `native/garage_native/Cargo.lock` with triples for `aarch64-apple-darwin`,
  `x86_64-unknown-linux-gnu`, `aarch64-unknown-linux-gnu` and `x86_64-pc-windows-msvc`.
- **The Mac app.** `//native:garage_native` joins `libtesseract` in the framework's `Frameworks`
  folder with a load command, so every Python process in the bundle has it at launch and the
  `codesign_test` targets seal it with the rest. The Status page's helper self-tests gain a
  "Native Kernels" row (loaded, ABI version), skipped in a venv.
- **Notices.** The crates' licenses (`regex`, `regex-syntax`, `memchr`, `aho-corasick`, `globset`,
  `walkdir`, `rustix`, all MIT or Apache-2.0) are added to `NATIVE_COMPONENTS` in
  `tools/third_party_notices.py` and `THIRD_PARTY_NOTICES.txt` is regenerated;
  `//data/notices:third_party_notices_test` enforces it.
- **Linux CI.** The `python` job builds the `.so` with `cargo build --release` (no Bazel on that
  runner) and runs the suite twice, once with `GARAGE_NATIVE_LIBRARY` set and once with
  `GARAGE_NATIVE=0`. `python-freethreaded` does the same. The macOS Bazel job builds and tests it
  through `//...`.
- **PyPI.** The wheel stays pure Python: an install from PyPI runs the fallback. Shipping platform
  wheels with the library through `hatch_build.py` is a later decision (section 6).
- **Windows.** The MSVC triple is in the crate lock from the start, but `windows.yaml` does not build
  the library in the first milestones; the fallback covers it.

## 4. Milestones

### M0: baseline and conformance harness, no Rust

- Commit the profiling and benchmark scripts as `tools/bench/ingest_bench.py` (isolated timings) and
  `tools/bench/ingest_profile.py` (cProfile of a full ingest), with a `--corpus` option for a real
  folder. Re-take the tables in section 1 on an Apple silicon Mac and record them here.
- Extend the goldens: a single-line JavaScript file, a 20k-line log, UTF-16 with BOM, NFD text, CRLF,
  an unbroken 20 KB token, and one sample per key of `LANGUAGE_SEPARATORS`.
- Add `tests/test_native_conformance.py`: every ported function run through both implementations
  over the goldens, the corpus and a seeded random generator, asserting equality. It passes trivially
  now (one implementation) and is the gate for M2 to M4.
- Python fixes that are independent of Rust and shrink the walker case: one compiled regex for each
  pattern table (`fnmatch.translate` joined with `|`), a per-directory cache for `find_repo_root`,
  and `_alpha_ratio` as a regex count. Expected from the measurements: the 30k-file walk from 3.3 s to
  about 0.6 s, `assess` about twice as fast. Measure again and record it; if the walk lands within 2×
  of the syscall floor, M4 shrinks to the placeholder check and the `stat` or is dropped.

### M1: the crate, loading and packaging

- `native/garage_native/` exporting `garage_native_abi_version()` and `garage_native_free()`;
  `//native:garage_native`; the `MODULE.bazel` wiring; the framework load command and codesign; the
  notices; the Linux CI build; `garage_rag.native.accelerator()` and the self-test row.
- Done when `aspect build //:macapp` carries the library, `aspect test //...` passes on macOS, the
  Linux `python` job runs the suite both ways, and the Status page shows the row.

### M2: the quality gate

- `garage_native_assess`. Python keeps thresholds and reasons (3.3).
- Done when the conformance test passes with the native path forced and `assess` on the 64 KB sample
  is at least 20× faster than the Python baseline from M0.

### M3: the splitters and chunking

- `RecursiveSplitter`, `MarkdownHeaderSplitter`, the language tables, `_locate`, behind `chunk_text`.
- Done when `test_chunking_golden.py` and `test_second_brain_corpus.py` pass with the native path
  forced, no chunker id changes, 100 KB of Markdown chunks in under 0.5 ms and the 400 KB single-line
  bundle in under 20 ms.

### M4: the walk

- The native pass of 3.3 behind `walker.walk` and `scanner.scan_filesystem`.
- Done when the yielded sequence and every `WalkStats` counter match the Python walk on a fixture
  tree with excluded directories, dependency paths, a bare git directory, hidden files, oversized
  files and, on macOS, dataless placeholders; and the walk runs within 1.5× of the `os.walk`-plus-`stat`
  floor.

### M5, optional: LangExtract alignment

- Run `tools/bench/ingest_profile.py --facts` over a real `enrich-facts` run first. Port
  `_best_lcs_spans` and `RegexTokenizer.tokenize` only if alignment is above about 5% of that run's
  wall time. The vendored LangExtract code keeps its upstream layout; the native call goes in behind
  `_lcs_fuzzy_align_extraction`.

## 5. Risks

- **Semantic drift** is the risk that matters: a chunk boundary that moves re-embeds the corpus. Held
  by the goldens, the dual-run conformance test, the ABI handshake, and the rule that Python is the
  specification and stays in the tree.
- **Privacy.** The crate must never be a second way out. It takes no network crates; a test reads
  `Cargo.lock` against an allowlist, the way `test_egress_block.py` lists `CALLERS`, and the crate's
  only file I/O is the walker's `stat` and `listxattr`. It never opens a file's contents.
- **Build complexity.** `rules_rs` on the Apple toolchain, the framework load command and codesign
  are proven in M1 with an empty library, before any kernel depends on them.
- **Sandbox loading.** A sandboxed XPC service cannot `dlopen` a path it was not linked against;
  the framework load command and `loaded_library` are the existing answer, and M1 verifies it in the
  App Store configuration.
- **Two implementations of three modules.** The maintenance cost is real and is the price of the
  fallback. The conformance test makes a divergence a failing build rather than a slow discovery.
- **Unicode tables** drift from CPython's with a Python upgrade. The tables are generated with a
  pinned Unicode version and a test compares them to the running interpreter's `unicodedata`.

## 6. Decisions to confirm

1. C ABI through ctypes rather than PyO3 (3.1). Recommended: C ABI.
2. Crate name and place: `native/garage_native`, `libgarage_native`.
3. Whether M0's Python fixes land first. Recommended: yes; they are cheap, they stand on their own, and
   they decide how much of M4 is worth building.
4. Whether PyPI ever ships the library, or stays pure Python with the fallback.
5. Whether M5 happens at all, or the facts pass is left to the LLM's clock.

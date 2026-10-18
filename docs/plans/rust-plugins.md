---
layout: default
title: Rust Components and Reader Plugins
description: Moving the ingester's components from Python to Rust one at a time, starting with the text reader, behind a new gRPC contract between the ingester and its reader plugins that Swift, .NET and Python all speak.
date: 2026-10-17
status: Active (first component, the text reader)
status_kind: active
---

# Rust components and reader plugins

Python is reaching its limits in the ingester: the GIL serializes extraction across a source, the
interpreter's startup and memory are paid in every XPC service that embeds it, and each native
library Python reaches (libtesseract, libgit2, libpq) needs its own binding. The plan is to move the
ingester's components to Rust one at a time, keeping Python as the reference implementation until
each one is replaced, and to keep supporting reader *plugins*: programs that read one document type
(an Office reader, a mail reader) through a published contract, so a reader can be written in any
language and run outside the ingester's process.

This supersedes the transport in [Rust hot paths]({{ '/plans/rust-hot-paths.html' | relative_url }}),
which proposed one library loaded through ctypes. The kernels it names (the quality gate, the
splitters, the walker's per-file pass) are still the next candidates; they now arrive as Rust crates
with a C ABI linked at build time, and as plugins where the contract fits.

## The contract

`proto/garage_plugin.proto` (`garage.plugin.v1`) is the contract between the ingester and its
readers: `ExtractorPlugin` with `Describe` (what the plugin reads: extractors, extensions, file
names, content kind) and `Extract` (one file's name and bytes in; a document, "no text" or a failure
out).

- A plugin is handed a file name and its bytes, never a path. It needs no access to the user's
  folders, which is what lets the app run one in a sandbox of its own.
- Failures a plugin can explain (unsupported, malformed) are answered in the response, so every
  transport reports them the same way; a transport error means the call itself failed.
- `ContractVersion` is reported by the plugin and checked by the host, which refuses a contract it
  does not know.

The same messages cross two transports:

| Transport | For | Where |
| --- | --- | --- |
| gRPC on a Unix-domain socket (a named pipe on Windows, not yet built) | a plugin in its own process, any language | `rust/garage-plugin` (`server`), `garage_rag/extract/plugins.py` |
| a C ABI over the serialized messages | a first-party reader linked into the ingester | `rust/garage-plugin` (`ffi`), `rust/garage-text-ffi/include/garage_text.h` |

There is no TCP transport: a plugin listens on a socket the host names (mode 0600, in a 0700
directory), consistent with "no new network listeners".

## The first component: the text reader

The text reader (`garage_rag/extract/text.py`: Markdown with YAML front matter, plain text, source
code, plus `normalize_text` and `guess_title`) is the first component moved. It is the most used
reader, a pure function of bytes, and its output decides `content_sha256`, so it is a demanding
first test of parity: any difference re-chunks a document.

- `rust/garage-text` is the reader. Front matter follows PyYAML's YAML 1.1 `SafeLoader` resolution
  (booleans like `yes`/`on`, octal and sexagesimal integers, timestamps, merged duplicate keys,
  anchors, the `!` tag), implemented over yaml-rust2's events, and the text helpers reproduce
  Python's `str.isspace`, `str.strip`, `pathlib` suffix rules, float `repr` and the cp1252 fallback.
- `rust/garage-text-plugin` serves it over gRPC; `rust/garage-text-ffi` exports it over the C ABI as
  a static library (the Mac app) and a shared one (.NET, Python's tests).
- `garage_python/tests/test_text_plugin.py` holds the Rust reader to the Python one over both
  transports: hand-written edge cases, a seeded fuzz and the second-brain-os corpus. Offline fuzzing
  found no difference over 80,000 generated front-matter files.

Known differences, all on input Python handles worse or not at all:

- An invalid date (`2024-02-30`) raises in PyYAML and fails Python's extraction; Rust keeps it as a
  string.
- Front matter with merge keys (`<<`) or tags other than the standard ones is dropped by Rust, kept
  by PyYAML.
- PyYAML refuses a duplicate anchor name; Rust accepts it.
- `NaN` and infinite floats have no JSON form, so Rust leaves them out of `meta_json`.
- About 4 in 60,000 malformed YAML inputs parse on one side and not the other.

Throughput on the second-brain-os corpus (250 Markdown files) is about 1.6 times Python's when
called through ctypes, protobuf encoding included. Speed is not the main gain: the reader runs
without the GIL, so the ingester can read files in parallel once it owns the loop.

## Bindings

- **Python**: `extraction.plugins` lists plugins, each a `unix:` socket or a program path the host
  starts with `--socket <path> --exit-with-stdin`. `plugins.PluginRegistry` asks each for `Describe`,
  and `dispatch` routes a file to the plugin that claims its extension or name ahead of the built-in
  readers. A plugin's extractor name and version become the document's, so changing a plugin
  re-extracts what it reads.
- **Swift**: `macapp/Sources/GaragePlugins` (`NativeTextReader`) links the static library through a
  Clang module and speaks the contract's Swift messages (`//proto:garage_plugin_proto_swift`).
- **.NET**: `winapp/src/Garage.Plugins` (`NativeTextReader`) calls the C ABI through `LibraryImport`,
  with the gRPC client generated from the same proto.

## Build

`rust/` is a Cargo workspace (`rust/Cargo.toml`, toolchain pinned in `rust-toolchain.toml`).
Bazel builds it through rules_rs: `crate.from_cargo` resolves `rust/Cargo.lock` into `@crates`, and
each crate's `BUILD.bazel` mirrors its `Cargo.toml`. The gRPC code is generated by `rust/protogen`
and checked in, so neither build needs `protoc`; CI fails when it is stale. The `rust` CI job runs
rustfmt, clippy, the tests, and the .NET binding's tests against the built library; the `python` job
builds the reader so `test_text_plugin.py` runs.

## Next steps

1. **Use it in the app.** Today the app's ingest still reads text in Python. Either the ingest XPC
   service calls `NativeTextReader` and hands Python the result, or PythonXPCService links the static
   library and Python calls it in-process. The second keeps one pipeline and needs no ctypes if it
   is a built-in module, as `_garage_git` is.
2. **Windows named pipes** for out-of-process plugins, and the program path convention for them.
3. **`extractor_revision` in the server process.** The gRPC server answers stat checks with the
   extractor's revision, so with plugins configured the server process starts them too. It should
   learn revisions from the ingester instead.
4. **The next components**, in the order Rust hot paths measured: the quality gate, the splitters,
   the walker's per-file pass. Then the Office and PDF readers, as plugins.
5. **Third-party notices** for the crates the app links, once the app links them.

## Python-free XPC services

The goal past the readers is XPC services that are Python-free binaries, one service at a time. Each
step leaves the app working, with the Python reference still there for the services not yet moved.

1. **The services that already run no Python** (model downloads, llama.cpp, image embeddings) still
   linked Python.framework and PythonXPCService.framework, because the service base class lived
   there. `GarageXPCKit` is that base without Python: logging, crash handling, self tests, the
   managed-service host and the peer requirement. `GaragePythonXPCServiceBase` in PythonXPCService adds
   the interpreter for the services that embed it. ModelDownloadXPCService is the first service built on
   the kit alone; LlamaXPCService and GarageImageEmbedXPCService follow once the client modules they
   share with the app (`LlamaClient`, `LlamaEngine`, `ImageEmbedClient`) import the kit instead.
2. **Embeddings.** The backfill worker in GarageEmbedXPCService, in Rust, over the same gRPC facade.
3. **Ingest.** The walker, readers, chunking, attribution, the quality gate and the splitters, in Rust,
   with readers behind the plugin contract above.
4. **The MCP server and the GarageXPCService backend**, last, since they serve the corpus itself.

## Privacy

A plugin sees one file's bytes and returns text. It receives no path, database URL or network
address, and the host refuses plugin entries that are not Unix sockets or programs. The contract
gives a plugin nothing to send a document to; a plugin that opens its own connections is outside
what `net/egress.py` can see, which is why plugins are configured by the user, one by one, and
the app's own readers are linked rather than loaded.

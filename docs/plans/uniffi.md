---
layout: default
title: Swift and Rust Interop
description: How the XPC services call their Rust workers and how Rust calls Swift-only APIs. UniFFI for the hosts' wide, callback-heavy APIs; a cbindgen-generated C ABI for the reader plugins; swift-rs for Rust calling Swift. A pilot on the embed worker.
date: 2026-11-03
status: Active (pilot on the embed worker)
status_kind: active
---

# Swift and Rust interop

The XPC services are moving their work into Rust ([Rust components and reader plugins]({{ '/plans/rust-plugins.html' | relative_url }})).
Each crate so far crosses into Swift through a C ABI with JSON requests and replies. The ABI is
static and loads nothing at run time, but its headers and its JSON shapes are kept by hand on
both sides.

Rick chose the three tools below on 2026-11-03: "lets start with cbindgen and swift-rs", followed
by a UniFFI pilot for the XPC hosts.

| Direction and use | Tool | Why |
| --- | --- | --- |
| A reader plugin's C ABI (`garage_text.h`): protobuf bytes in and out, for Swift, .NET and Python's ctypes alike | **cbindgen** | The contract is the proto. The header only carries bytes, so generating it from the Rust is all it needs. |
| An XPC service calling its Rust worker (embed, ingest, MCP): wide APIs, many host callbacks | **UniFFI** | Typed records, enums and errors in place of hand-kept JSON. The host's callbacks become a Swift protocol. Python bindings come with it, and C# through a community generator. |
| Rust calling a Swift-only Apple API (Vision's `RecognizeDocumentsRequest`) | **swift-rs** | An `@_cdecl` Swift function, declared in Rust with `swift!`, which balances the retain counts of what crosses. |

## cbindgen

- `cargo run -p headergen` writes each FFI crate's `include/*.h` from its Rust, and CI runs it with
  `--check`.
- Each crate's `cbindgen.toml` holds the header's prologue, guard and renames.
- The doc comments on the Rust items become the header's comments. That includes the JSON shapes,
  which used to live only in the header.
- `usize` is written as `size_t`, so Swift keeps seeing `Int`.
- So far `garage-text-ffi` and `garage-embed-ffi` are covered. `garage-ingest-ffi` joins once the
  ingest port's open work lands.

## UniFFI: the embed worker pilot

`rust/garage-embed-uniffi` exposes the same three calls as `garage_embed.h` (`backfill`, `models`,
`embed_texts`) with:

- records for the request, the settings, the connection, HTTP requests and replies, and backfill
  statuses;
- an `EmbedError` enum in place of status codes;
- the host as `EmbedHost`, a trait exported `with_foreign`. Swift implements it as a protocol, in
  place of `GarageEmbedHost`'s C function pointers and `release`.

It sits beside the C ABI, which `GarageEmbedWorker` still uses, so nothing changes until the Swift
host switches.

- **Bindings.** `rust/uniffi-bindgen` is UniFFI's generator pinned to the workspace's version. It is
  built without the `cargo-metadata` feature, so it reads only the library and runs in Bazel's
  sandbox. `//rust/garage-embed-uniffi:swift_bindings` generates the Swift, the header and the module
  map, and `:GarageEmbedUniFFI` is the Swift module a host imports.
- **Tests.**
  - The Rust unit tests call the API through a Rust host.
  - `tests/python_roundtrip.py` runs in CI's rust job against the built library. It uses the
    generated Python bindings, with a Python host answering the worker's HTTP requests, and checks
    vectors, the typed request and both kinds of error across the boundary.
- **Not yet.**
  - The Mac build of `:GarageEmbedUniFFI`.
  - Moving `GarageEmbedWorker` to it.
  - Whether UniFFI's per-call serialization matters for batches of vectors. It shouldn't: a batch is
    64 vectors, and the HTTP reply dominates.

If the pilot holds, the ingest and MCP hosts follow, one crate at a time, each keeping its C ABI until
its host has moved.

## swift-rs

`garage-ocr`'s `vision-documents` feature is the first use: Rust calls Vision's Swift-only
`RecognizeDocumentsRequest` through `garage_ocr_recognize_document` (see [OCR for the Rust
ingester]({{ '/plans/ocr.html' | relative_url }})).

- swift-rs's own Swift half is vendored in `ext/swift_rs`, at the crate's version, for Bazel.
- Cargo builds it through SwiftPM and swift-rs's `SwiftLinker`.

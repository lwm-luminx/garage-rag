---
layout: default
title: The Backend in Rust, and the End of Python in the App
description: What Python is still in Garage after the Rust XPC services, module by module; how GarageService (the gRPC backend) moves to a Rust crate on tokio-postgres; and the order in which the launchers, the Windows services, Python.framework and garage_python then leave.
date: 2026-11-04
status: Active (inventory done; stage 1, the storage facade and corpus reads, in progress)
status_kind: active
---

# The backend in Rust, and the end of Python in the app

> **Decided (Rick, 2026-11-04):** port the backend service to Rust, and once it is complete strip out
> all Python. This plan is the inventory he asked for and the order of the work.

Five of the Mac app's seven XPC services are Rust without Python: model downloads, LlamaXPCService,
image embedding, the embed worker ([`garage-embed`](https://github.com/rickmark/garage-rag/tree/main/rust/garage-embed)),
and the MCP server (`garage-mcp`, #299). The ingest service reads every file in Rust (#307) and drops
its Python fallback in #309. What is left is **GarageXPCService**, which hosts `garage_rag.service.server`:
the gRPC `GarageService` every other piece stores through and reads from. Behind that one process sits
most of the Python package, because the backend is where the database, the configuration, the search
query and every operation live.

## 1. What is still Python

Line counts are of `garage_python/src/garage_rag` on `next` at #307, without generated protobuf.

### 1.1 Behind GarageXPCService (the backend)

| Module | Lines | What it is | Rust today | Goes to |
| --- | ---: | --- | --- | --- |
| `service/server.py`, `auth.py` | 2,021 | The 48 RPCs, the token interceptor, the Unix-socket binding, streaming with cancellation | `garage-facade` has the generated messages and the *client*; `protogen` can emit the server | `garage-service` (stage 1–3) |
| `ingest/gateway.py` (`SqlAlchemyIngestStorageGateway`) | ~600 | The server side of the storage facade: ingest runs, outcomes, `replace_document` keeping unchanged chunks | the client side is `garage-ingest/facade.rs` | stage 1 |
| `db/` (`engine`, `models`, `migrate`, `registry`, `emb_tables`, `catalog`) | 1,379 | Connections, the schema mirror, applying `data/sql`, the storage plan per width, the per-model tables, `models.json` | nothing | stage 1 |
| `search/hybrid.py` | 427 | RRF over pgvector and FTS, the halfvec and binary-quantized paths, the filters | nothing (the Rust MCP server calls `CorpusSearch`) | stage 1 |
| `mcp_server/server.py` (the tools' bodies) | ~700 | `rag_search`, `rag_get_document`, `rag_list_sources`, `rag_list_authors`, `rag_stats`, which `Corpus*` run | `garage-mcp` has the protocol and calls these over gRPC | stage 1 |
| `embed/ollama.py` (`pending_chunks_sql`, `store_vectors`, `backfill_distilled`), `emb_tables.py` | ~400 | Which chunks a model lacks, writing vectors to the right table, the distilled-fact centroids | `garage-embed` is the worker that calls these | stage 1 |
| `ops/sources.py`, `ingest/scanner.py` (persist), `ingest/reconcile.py`, `ingest/__init__.py` (sync) | ~1,100 | add/remove source, scan, sync with `garage.json`, import, reconcile | `garage-ingest` has the scanner and the source rules | stage 2 |
| `ops/models.py`, `embed/*`, `inference/*` | ~1,900 | register/default/drop, `EmbedText`, `verify_model_dims`, the one HTTP client | `garage-embed/provider.rs` is the client | stage 2 |
| `config/__init__.py`, `config/fact_prompts.py` | 1,550 | `SECTIONS`, loading and saving `garage.json`, `Get`/`SetSetting`, the JSON Schema | `garage-embed/settings.rs` reads five keys through `GetSetting` | stage 2 (`garage-config`) |
| `mcp_server/install.py`, `ops/mcp.py` | 675 | `McpInstall`/`Uninstall`/`Status`: editing each assistant's config file | nothing | stage 2 |
| `net/egress.py` | 238 | The destination allowlist and the content rule | `garage-embed/egress.rs` (the same rules) | stage 2 (shared) |
| `db/graph.py`, `ops/graph.py` | 796 | The AGE projection and the three graph RPCs | nothing | stage 2 |
| `xpc/host.py`, `xpc/llama_xpc.py` | ~340 | `EnsureLlamaModel`, loading a `llama_xpc` model through the app | the hosts' `ensure_llama_model` callback | stage 2 |
| `enrich/facts.py`, `local_provider.py`, `generation.py`, `metadata.py`, `ops/facts.py` | ~1,500 | `EnrichFacts`, `ListFacts`, `GetFactStats`, `ListFactPrompts`, the metadata anchors | the langextract-rs thread's crate (3.3k lines, no I/O) replaces the vendored `enrich/langextract` (4.5k) | stage 3 |
| `enrich/clusters.py` | 1,665 | `ClusterFacts`: the two-level dedup over fact vectors | nothing | stage 3 |

### 1.2 Outside the backend

| What | Python it runs | Replaced by | Stage |
| --- | --- | --- | --- |
| `garage` launcher (`GarageLauncher` → `garage_rag.cli`, 2,025 lines) | the whole CLI, mostly thin presenters over `ops/` | a Rust `garage` binary: the same commands as gRPC calls to the app's socket, and its own server for a venv-less install | 4 |
| `garage-mcp` launcher (`garage_rag.mcp_server.server` on stdio) | the Python MCP server | `garage-mcp`'s stdio front end (`stdio.rs`, built for #299, not yet a binary) | 4 |
| The Python extractors (`extract/`, 3,348 lines) including the Tesseract image reader (`image.py`, `tesseract.py`, `imageio.py`) | only the Python ingest loop (CLI, Windows, the smoke test) since #307/#309 | the Rust readers (`garage-readers`, `garage-ocr`) | 5 |
| Extraction plugins (`extract/plugins.py`, `extraction.plugins`) | the Python loop starts a plugin program and routes files to it over the contract | the same contract, spoken by the Rust ingester (`garage-plugin` has the server and the in-process ABI; the client over a Unix socket is missing) | 2 |
| The Windows app (`winapp/`, `Garage.Services.exe --service core|ingest`) | embeds CPython and runs the backend and the Python ingest loop | the Rust service and ingest binaries, started the same way | 4 |
| `PythonXPCService` (the CPython embed, `GaragePythonRuntime`, the site-packages build, `Python.framework`) | everything above | nothing; the Swift types it also carries (`GarageSockets`, `GarageAppGroup`, the endpoints) move to `GarageXPCKit` | 5 |

The ingest loop itself (`ingest/pipeline.py`, walker, chunking, attribution, conversations, 4.8k lines)
is already ported in `garage-ingest`; the Python copy stays only as long as the CLI and Windows run it,
and leaves in stage 5 with the rest.

## 2. The Rust backend

One new crate, **`rust/garage-service`**, with the same contract (`proto/garage.proto`), the same SQL
and the same error mapping, so the Swift app, the Windows app, the Rust workers and the MCP server
notice nothing but the process behind the socket.

- **Server.** tonic (already the workers' client stack), with the server code generated by `protogen`
  beside the client in `garage-facade`. The same socket rules as Python's: a Unix socket in `s/`
  (0700, a stale socket recovered under a lock) or a loopback port; `x-garage-token` on every call
  but `EnsureLlamaModel` when `GARAGE_GRPC_TOKEN` is set; the config-changing methods refused on
  TCP without a token (`service/auth.py`'s list). Long jobs (`Scan`, `Backfill`, `EnrichFacts`,
  `ClusterFacts`) are server streams that stop at the next progress step when the call is dropped.
  Requests up to 256 MiB.
- **Database.** `tokio-postgres` with `deadpool-postgres` for the pool and the `pgvector` crate for
  the vector types. Pure Rust, no libpq binding, so the crate links statically into the XPC service
  and the Windows binary alike; the connection is the app's Unix socket (`?host=<dir>&port=14824`) or
  loopback, with the password from the URL as today, so it needs no TLS. The SQL moves as written:
  `data/sql` stays the schema's source of truth (`InitDb` applies it, in order, idempotently), the
  hybrid search query, the pending-chunk anti-join and `replace_document`'s keep-or-replace logic
  are transcribed from the Python, and the parity tests below hold them to it.
- **Host.** Like `garage-mcp`, the crate opens no HTTP connection of its own. What it needs from
  the process is a `Host` trait: `http` (a request it has already approved, to a model server),
  `ensure_llama_model`, `embed_images` and `embed_image_texts` for the image service, and the
  folder access the app grants for `AddSource`/`Scan`. In GarageXPCService that is Swift, through
  a C ABI with JSON calls (`garage-service-ffi`, the pattern of `garage_mcp.h`), to be replaced by
  UniFFI once the embed pilot lands ([Swift and Rust interop]({{ '/plans/uniffi.html' | relative_url }})).
  Outside the app (the `garage` binary, Windows, CI), a plain host carries requests with a small
  HTTP client that honours the same egress rules.
- **Egress.** `garage-embed/egress.rs` becomes the shared check (`garage-egress`), and the Python
  AST scan in `tests/test_egress_block.py` gets a Rust equivalent: a test that no crate but the
  hosts' depends on an HTTP client, and that every request leaves through `Host::http` after
  `check_destination`. Communications still never go to a destination that is not loopback.
- **Reuse.** `Backfill` runs `garage-embed`'s worker in-process against a `Facade` implementation
  over the local database instead of over gRPC; `Scan` and `SyncSources` run `garage-ingest`'s
  scanner and source rules; `EnrichFacts` drives the langextract-rs crate through the host's model
  calls; `Corpus*` keep answering with the JSON the Python tools produced (`garage-mcp/pyjson.rs`
  already renders Python's shapes), so the MCP clients see the same results.
- **Configuration.** `garage-config` holds `SECTIONS` as data (section, key, type, default,
  documentation), reads and writes the nested `garage.json`, rejects unknown keys and warns about
  retired ones, and generates `docs/.data/garage.schema.json`, so the schema test keeps enforcing
  that every setting is documented.

### Parity tests

Python's tests are the specification. `garage_python/tests/test_postgres.py` (the migrations
re-applied, the per-model DDL for each metric, the search query on every storage path, the egress
filter on pending chunks) is ported to a Rust integration test against `GARAGE_TEST_DATABASE_URL`,
skipped when it is unset as today, and CI's `rust` job gets the `pgvector/pgvector` service the
`python` job has. While both backends exist, a parity test runs the same requests against each
and compares the replies, so the Rust server is held to the Python one message by message before
the host switches.

## 3. The order

Each stage is a pull request to `next`, stacked on the previous one while it is open.

1. **Storage facade and corpus reads** (this plan's first PR): `garage-service` with the database
   layer, `InitDb`, the ingest facade (`BeginIngestSession` … `FinalizeIngestSession`), the embed
   facade (`GetEmbeddingBatches`, `UpdateEmbeddings`, `BackfillDistilled`), `Ping`/`GetStatus`/
   `GetVersion`, `Search`, `ListDocuments`, `GetDocument`, `ListSources`, `ListModels`, `GetStats`,
   `GetSetting` (read-only, from `garage.json`), the five `Corpus*` reads, the token and socket
   rules, and the Postgres tests. Nothing in the app changes yet.
2. **Operations**: sources, models, `EmbedText`, `Backfill`, `EnsureLlamaModel`, `SetSetting` and
   the full `garage-config`, the MCP registrations, the graph RPCs, and the plugin client in the
   Rust ingester (the last leftover of #307).
3. **Facts**: `EnrichFacts` on langextract-rs (the crate the LangExtract thread is finishing),
   `ListFacts`, `GetFactStats`, `ListFactPrompts`, the metadata anchors, `ClusterFacts`.
4. **The host switch**: GarageXPCService links `garage-service-ffi` and drops PythonKit; the
   parity test retires with the Python server; the `garage` and `garage-mcp` launchers become Rust
   binaries (the helper bundles, entitlements and the `/bin/sh` forwarders stay); `Garage.Services.exe`
   starts the Rust binaries on Windows.
5. **Strip**: Python.framework and the site-packages leave the bundle and the Bazel rules
   (`bazel/python_site_packages.bzl`, `framework_linking.bzl`'s Python parts); `PythonXPCService`
   keeps only its Swift types and is renamed; `garage_python/`, `uv.lock`, the `@pypi` hub, the
   Python CI jobs and `tools/third_party_notices.py`'s Python side go; `CLAUDE.md`, the README, the
   site and `docs/architecture.md` describe the Rust pipeline. The PyPI package is retired with a
   last release pointing at the binaries.

## 4. Open questions

- **"All Python" and the CLI.** The plan reads it as the whole repository: the `garage` CLI and the
  PyPI package become the Rust binary too. If the Python CLI should survive as a client for
  scripting, stage 4 keeps `garage_python` as a thin gRPC client package instead.
- **Windows.** The Windows app embeds CPython the way the Mac app did. Stage 4 moves it to the
  Rust binaries; until then it keeps working on the Python backend.
- **Apache AGE.** The graph RPCs are the only place openCypher is sent. They port as they are; a
  server without AGE answers `available = false` as today.

---
layout: default
title: The garage_rag Python Package over Rust
description: How the garage_rag package on PyPI keeps its name and the 1.5.0 API while the code underneath becomes Garage's Rust. The 1.5.0 surface module by module, what each name maps to in the Rust crates, the console scripts that ship first, the version, and the Python layer that will carry the library API.
date: 2026-11-05
status: Active (phase 1, the console scripts and the version, in review; phase 2, the import API, waits on the decisions below)
status_kind: active
---

# The garage_rag Python package over Rust

> **Decided (Rick, 2026-11-05):** the PyPI package `garage_rag` keeps its name. Its next release is the
> Rust-backed package built from `rust/garage-rag` (maturin, UniFFI), and it reaches parity with the last
> pure-Python release, 1.5.0, by wrapping the Rust code. **A layer of Python provides the API mapping:**
> the 1.5.0 module paths, names, signatures, defaults and result types live in hand-written Python
> modules in the package, which translate to and from a small, generic set of Rust calls underneath.

## Where this starts

The pure-Python package left the repository with the Python removal
([The backend in Rust]({{ '/plans/python-removal.html' | relative_url }})); each Rust crate names the
Python module it ports. 1.5.0 is the last pure-Python release on PyPI: 97 modules, `Requires-Python
>=3.13,<3.15`, 19 runtime dependencies (psycopg, SQLAlchemy, mcp, grpcio, pdfplumber, ...), and two
console scripts:

| Script | 1.5.0 entry point |
| --- | --- |
| `garage` | `garage_rag.cli:main_cli` |
| `garage-mcp` | `garage_rag.mcp_server.server:main` |

The UniFFI pilot ([Swift and Rust interop]({{ '/plans/uniffi.html' | relative_url }})) then put a
`garage_rag` package in `rust/garage-rag`, versioned 0.1.0 from the Cargo workspace, exposing only
`garage_rag.garage_embed`. Published as is, it would have gone below 1.5.0 and dropped both commands.

## The 1.5.0 surface

The inventory is every top-level function and class without a leading underscore in the 1.5.0 wheel
(read with `ast`, nothing imported): **523 names in 97 modules**. The 1.5.0 README documented only the two
console scripts; the library was never documented as an API, so "public" below is a judgement: what the
CLI, the gRPC servicer and the MCP server called across module lines, which is what an integrator would
have imported.

The table counts each subpackage's names and says where they went. *Clean* means a Rust function or RPC
does the same work with the same inputs, so a Python wrapper only translates names and types. *Partial*
means the work exists in Rust but in another shape (bytes and a file name in place of a path, a `Host` in
place of an HTTP client, a session gone), so the wrapper adapts more than names. *None* has no
counterpart by construction.

| 1.5.0 module | Names | Rust | Mapping |
| --- | ---: | --- | --- |
| `cli` (Typer commands, `main_cli`, `get_version`) | 39 | `garage-cli` (every command, same options, wording and exit codes) | clean, through argv (phase 1) |
| `ops.sources`, `ops.models`, `ops.settings`, `ops.facts`, `ops.backfill`, `ops.mcp` | 37 | GarageService RPCs: `AddSource`, `RemoveSource`, `Scan`, `SyncSources`, `ImportSourcesToConfig`, `RegisterModel`, `SetDefaultModel`, `DropModel`, `GetSetting`, `SetSetting`, `Backfill`, `EnrichFacts`, `ListFactPrompts`, `ListFacts`, `GetFactStats`, `McpInstall`, `McpUninstall`, `McpStatus` (`sources.rs`, `models.rs`, `facts.rs`, `prompts.rs`, `backfill.rs`, `enrich.rs`, `mcp_install.rs`) | clean |
| `search.hybrid` (`search`, `corpus_overview`, `snippet`, `tsquery_expr`, `SearchHit`) | 5 | `search.rs`; `Search`, `GetStats`, `CorpusSearch`, `CorpusStats` | clean (the `session` argument goes) |
| `mcp_server.server` (8 tools, 11 result models, `serve`, `main`, the background HTTP server, `build_ask_messages`, `is_loopback`) | 28 | `garage-mcp` (`Toolbox`, `http.rs`, `stdio.rs`, `build_ask_messages`), `garage-mcp-ffi` (`garage_mcp_http_start/stop/is_running`), `Corpus*` RPCs | clean |
| `mcp_server.install` (`client_targets`, `plan_targets`, `install`, `uninstall`, `installed_in`, `server_command`, `server_entry`, ...) | 14 | `garage-service`'s `mcp_install.rs` | clean (needs exports) |
| `mcp_server.agent` | 14 | `garage-mcp`'s `agent.rs` (behind `rag_agent`) | partial: `run_agent` maps, the rest were its helpers |
| `config` (`load_config`, `save_config`, `Settings`, `setting_names`, `resolve_setting`, `coerce_setting`, `update_config`, `json_schema`, `find_config_file`, ...), `config.fact_prompts` | 35 | `config.rs` (`SECTIONS`), `schema.rs`, `prompts.rs`; `GetSetting`/`SetSetting` | clean (`Settings` becomes a read-only view of the flat settings) |
| `service.client.GarageClient`, `service.server` (`create_grpc_server`, `serve_grpc`), `service.auth` | 9 | `garage-facade` (the blocking client), `garage-service-ffi` (`start`/`stop`), `auth.rs` | clean |
| `db.migrate`, `db.registry`, `db.catalog` | 23 | `migrate.rs`, `registry.rs`, `catalog.rs`; `InitDb` | clean |
| `db.emb_tables` (`register_model(session, ...)`, `list_models`, `drop_model`, ...) | 9 | `models.rs` over the model RPCs | clean (the `session` argument goes) |
| `db.models` enums (`CorpusClass`, `TrustTier`, `AuthorRole`, `IngestState`, `StorageKind`, `IndexKind`) | 6 | the SQL enums and `registry.rs` | clean (Python `StrEnum`s) |
| `db.models` ORM classes (`Source`, `Document`, `Chunk`, `Fact`, ...), `db.engine` (`session_scope`, `get_engine`) | 20 | none: the Rust reads Postgres with tokio-postgres and SQL | none |
| `embed.*` (`Embedder`, `OllamaEmbedder`, `get_embedder`, `backfill_model`, `embed_via_grpc`, ...) | 13 | `garage-embed`, already bound as `garage_rag.garage_embed` (`embed_texts`, `backfill`, `models`) | partial: the embedders become thin classes over `embed_texts` and a host |
| `enrich.facts`, `enrich.generation`, `enrich.local_provider` | 16 | `enrich.rs` (`FactExtractor`, langextract-rs), `garage-mcp`'s `chat.rs` | partial |
| `enrich.langextract.*` (the vendored LangExtract) | 67 | the `langextract-rs` crate, not Garage's API | none |
| `extract.*` readers (`dispatch.extract`, `extractor_for`, `is_indexable`, `extractor_revision`, `text`, `mail`, `office`, `pdf`, `image`, `quality.assess`, `messages`, `nicknames`, `contact_names`, `base`) | 43 | `garage-readers`, `garage-text`, `garage-ocr`, `garage-ingest`'s `quality.rs`, `contact_names.rs`, `messages-markdown` | partial: the Rust readers take a file name and bytes, never a path |
| `extract.placeholder` | 5 | `garage-ingest`'s `placeholder.rs`, `materialize.rs` | partial |
| `extract.tesseract`, `extract.imageio` | 6 | `garage-ocr` (engine trait, no PIL images) | none |
| `ingest.walker`, `chunking`, `splitters`, `classify`, `scanner`, `materialize`, `reconcile`, `pipeline`, `conversations`, `author_names` | 53 | `garage-ingest` (`walk.rs`, `chunking.rs`, `splitters.rs`, `scanner.rs`, `materialize.rs`, `pipeline.rs`, `source.rs`, `conversations.rs`), `sources.rs` (`Reconcile`) | partial |
| `ingest.__init__` (`ingest_xpc`, `set_c_progress_callback`, `OSLogHandler`, ...), `ingest.gateway` (`IngestStorageGateway` and its two implementations) | 17 | `garage_ingest_run` and `GrpcStorage` replace them; they were the XPC host's hooks | none |
| `attribute.git`, `attribute.pathrules`, `attribute.resolver` (`resolve`, `classify_path`, `SelfIdentity`, ...) | 17 | `garage-git`, `garage-ingest`'s `attribution.rs`, `history.rs`, `parseaddr.rs` | partial |
| `attribute.resolver` (`get_or_create_author(session, ...)`, `ensure_self_author`) | 2 | done inside `PersistDocument` | none |
| `net.egress` (`check_destination`, `allows_communications`, `approved_destinations`, `EgressBlocked`) | 4 | `garage-embed`'s `egress.rs` | partial |
| `net.egress` (`http_client`, `url_opener`, `UrlOpener`), `inference.*` (`InferenceClient`, `Backend`, the error classes, `transport`, `bridge`) | 28 | none by design: the Rust never opens a connection itself; its host carries each request after `egress` approves it | none |
| `xpc.*`, `native`, `libpq`, `proto.*` (the generated gRPC stubs) | 13 | the Mac app's XPC services; the proto is `proto/garage.proto` | none |

**Totals: 205 clean, 165 partial, 153 none.** The clean ones are the operations layer, search, the MCP
tools and server, configuration, the gRPC client and the schema: the code the 1.5.0 CLI, servicer and MCP
server shared, which the Rust ports one to one. The partial ones are the pipeline's internals, reachable
in Rust as library functions but not as RPCs. Nothing in *none* can be matched without bringing back what
the removal took out (SQLAlchemy, the vendored LangExtract, an HTTP client in the package), and the
privacy guarantee rules out the last: content leaves only through a host after `egress` approves it.

## Phase 1: the console scripts and the version (this change)

- **`rust/garage-cli-uniffi`**, a UniFFI namespace `garage_cli` with three calls: `run_garage(args) ->
  exit code`, `run_garage_mcp(args) -> exit code` and `version()`. Each runs `garage_cli::run` /
  `run_mcp`, with GarageService in the calling process, as the binaries and the Mac app's launchers do.
  `rust/garage-rag` links it beside `garage-embed-uniffi`. It is built without garage-cli's new
  `tesseract` feature, so the library links no libtesseract: on the Mac pictures are read by Vision, and
  elsewhere a picture reads as no text, as in the Windows app.
- **The package is hand-written Python** (`rust/garage-rag/python/garage_rag`, maturin's `python-source`).
  The generated bindings and the library land in `garage_rag._native`; the hand-written modules import
  them:
  - `garage_rag.cli` (`main_cli`, `main(argv)`, `get_version`) and `garage_rag.mcp_server.server`
    (`main(argv)`), the 1.5.0 entry points, which `[project.scripts]` names again;
  - `garage_rag.garage_embed` and the re-export of its names from `garage_rag`, the 0.1 package's surface;
  - `garage_rag._runtime`, which points `GARAGE_SQL_DIR` and `GARAGE_MODEL_MANIFEST` at the schema and
    model catalog the wheel carries (`garage_rag/_data`, laid in by `rust/garage-rag/build.rs` from
    `data/`), and `GARAGE_MCP_EXECUTABLE` at the install's own `garage-mcp`, each only when unset, and
    lets Ctrl-C end a command as it ends a native one.
- **The database** comes from `GARAGE_DATABASE_URL` or the config file (`./garage.json`, `~/.garage.json`
  or `--config`), as for the Rust CLI. `garage init-db` against any Postgres with pgvector works from a
  pip install.
- **`garage --version`** is new (the Rust CLI had only `garage version`; `garage-mcp --version` existed).
- **The wheel links libgit2 statically**, built from `ext/libgit2`'s pin with `//ext/libgit2`'s options
  (`tools/wheels/build_libgit2.sh`; vcpkg's on Windows, as `windows.yaml` does), and SQLite comes from
  rusqlite's bundled copy, so a wheel loads only the system's libraries. The release profile no longer
  strips (`strip = "none"`): macOS 27's dyld refuses a library rust-objcopy stripped.

### The version

The package continues from 1.5.0 and takes the app's release version, which has one source in the tree:
GarageService's `VERSION` (`rust/garage-service/src/service.rs`). `garage --version` and `GetVersion`
report it, and the Windows installers read it (`Get-GarageVersion` in `winapp/packaging/common.ps1`).

- `rust/garage-rag` has its own `version` instead of the workspace's 0.1.0, and a test in the crate holds
  it equal to `VERSION`; `release.yaml`'s `check` job fails the release when they differ. The workspace
  version keeps versioning the crates, which `release.yaml`'s `crates` job publishes on their own terms.
- `release.yaml` and `ruby/build.sh` read the version from `rust/garage-rag/Cargo.toml`, so PyPI's
  `skip-existing` and the gem push's own check still skip a version already published.
- Both move to **1.5.1** now. 1.5.0 is taken on PyPI by the pure-Python wheel
  (`garage_rag-1.5.0-py3-none-any.whl`); a platform wheel of 1.5.0 has another file name, so
  `skip-existing` would not skip it, and it would be added to the old release, where pip would prefer it.
  Every version this package publishes must be above 1.5.0.
- The Mac app's `CFBundleShortVersionString` stays `1.5` (`macapp/Sources/GarageApp/BUILD.bazel`); it is
  not read from `VERSION`.

## Phase 2: the import API (decisions first)

The design the decision above sets: the Rust exports stay few and generic, and every 1.5.0 name is a
Python function or class in the module 1.5.0 had it in.

**The Rust underneath.** One more UniFFI object beside `garage_cli`, say `Garage`, opened with an optional
config path. It starts GarageService in the process on a private socket, exactly as the CLI's
`backend::Backend` does, and offers:

- `call(method, request) -> response` and `stream(method, request, sink)` for every RPC of
  `proto/garage.proto` (the `sink` a callback interface for `Scan`, `Backfill`, `EnrichFacts`,
  `ClusterFacts`), over `garage-facade`;
- `tool(name, arguments) -> result` for the MCP tools, over `garage-mcp`'s `Toolbox`, which already
  speaks JSON and applies the access hooks;
- a handful of typed pure functions the pipeline's partial names need (`extract(name, bytes)`,
  `chunk_text`, `assess`, `walk`, `plan_storage`, `check_destination`), added as phase 2 reaches them.

**The Python on top.** For each clean name, a function with 1.5.0's signature and defaults that builds the
request, calls the door, and returns 1.5.0's result type (`AddSourceResult`, `SearchHit`, `FactPage`, the
MCP tools' records) as a dataclass. Errors are mapped from the service's gRPC codes onto the 1.5.0
exception classes (`ConfigError`, `SourceArgumentError`, `EmbeddingError`, `EgressBlocked`, ...). A
`session` argument is accepted and ignored where 1.5.0 took one, so `search(session, "q")` keeps working.

**Decisions needed before phase 2:**

1. **Scope.** Wrap the 205 clean names and stop, or also the 165 partial ones? The recommendation is the
   clean ones first (`ops`, `search`, `mcp_server`, `config`, `service.client`, `db.migrate`/`registry`/
   `catalog`, the enums), then the readers and chunking, which are the partial names most worth having.
2. **The door's format.** JSON (serde derives added to `protogen`'s generated types, no Python dependency)
   or protobuf bytes (the package then depends on `protobuf` and ships generated `garage_pb2`). JSON is the
   recommendation, and is what the `Corpus*` calls and the MCP tools already return.
3. **Result types.** Plain dataclasses (no dependency) or pydantic models as in 1.5.0 (`Settings`, the MCP
   records), which would bring pydantic back as a dependency. Dataclasses are the recommendation;
   `Settings` would be a read-only view.
4. **Which service a call reaches.** Always an in-process GarageService (needs Postgres reachable from the
   Python process), or the app's own when `GARAGE_GRPC_SOCKET` names it, as the Mac launchers arrange?
5. **The names with no counterpart** (`session_scope`, the ORM classes, `langextract`, the inference
   clients): leave them out, or keep the modules importable with each name raising an error that says
   what replaced it.
6. **The version line.** 1.5.1 is the smallest version above the pure-Python 1.5.0. If the next app
   release on `next` is to be 1.6, `VERSION` and `rust/garage-rag` move to 1.6.0 together instead.
7. **Platforms.** Windows wheels and gems depend on the vcpkg step mirrored from `windows.yaml`, which
   cannot be exercised before a release tag; keep them, or publish macOS and Linux only until a dry run
   has passed. And Tesseract stays off in the wheels (pictures read as no text on Linux and Windows) unless
   it is linked statically from `//ext/tesseract`'s build.

## Publishing

`release.yaml` publishes from a `v*` tag on `main`. The PyPI project `garage_rag` trusts
`publish-python.yaml` on `main`, the 1.5.0 workflow; before the first release from `release.yaml`, add it
(environment `pypi`) as a trusted publisher of the existing project.

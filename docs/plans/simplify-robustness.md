---
layout: default
title: Simplification and robustness plan
description: Engineering plan to make the gRPC server the one facade, give extraction a media-type contract, and tighten the schema.
---

# Simplification and robustness plan

Findings from reading `main` at `db351e8` on 2026-10-04, with line numbers from that commit. Three
themes, each one a chain of PR-sized steps that leaves the app working after every step:

| Theme | One line |
|---|---|
| **One facade** | Every reader and every writer of the corpus goes through `GarageService`; the app stops parsing `psql` output and the ingest worker stops silently falling back to direct Postgres. |
| **Extraction contract** | Extractors are registered by media type (`image/*` → Tesseract), not by a hand-kept list of suffixes, with one result shape, one error hierarchy and one name per extractor. |
| **Schema** | Drop what nothing writes, remember every ingest outcome in one place, bound the bookkeeping tables, apply migrations once, and tune the local-first Postgres for what it actually does. |

Two defects found on the way are being fixed separately on `main` (see §5): `extractor_revision()`
raises `KeyError` for `.eml`/`.emlx`, and a `PlaceholderFile` raised inside `extract()` is counted as
an ingest error instead of a placeholder.

---

## 0. Where we start

What exists and shapes the design. Each item is one thing the plan changes.

**The facade has leaks.**

- The Swift app reads models, sources and corpus stats by running `psql -tAF\t` and splitting the
  output (`macapp/Sources/GarageApp/Services/PostgresService.swift:213-241, 744, 778, 1014`), beside
  the `ListModels`, `ListSources` and `GetStats` RPCs that return the same data. It also applies
  `data/sql` itself (`:897-938`), beside the `InitDb` RPC.
- The ingest worker's storage gateway is chosen by environment sniffing
  (`ingest/gateway.py:1008-1050`): gRPC when `GARAGE_GRPC_SOCKET` or `GARAGE_GRPC_PORT` is in
  `os.environ`, else direct Postgres. The app never passes a socket in `IngestOptions`
  (`AppState.swift:1130-1136`), so the choice rests on `configureHelpers` having run, and
  `mergeConfiguration` mirrors options into `os.environ` only when Python is already ready
  (`GarageXPCServiceBase.swift:286`), with no replay. A `configureHelpers` that arrives early leaves
  ingest writing to Postgres directly, with nothing logged.
- The database URL reaches the ingest helper by three routes: `updateConfiguration`,
  `setDatabaseURL`, and `IngestOptions.databaseUrl` inside the options JSON (`IngestService.swift:412-420`).
- Nine handlers in `service/server.py` hold their own SQLAlchemy queries (`Search`, `ListDocuments`,
  `GetDocument`, `ListSources`, `ListModels`, `GetStats`, `PersistScan`, `GetEmbeddingBatches`,
  `UpdateEmbeddings`); the rest are thin over `ops/`. `cli.py:541` and `mcp_server/server.py:390`
  carry their own copies of some of those reads.
- `PersistDocument` multiplexes seven gateway methods behind a string `action` (`server.py:1285-1368`),
  and progress streams are told apart by string phases that Swift compares in a dozen places
  (`GarageGRPCService+Operations.swift:70, 142, 171`; `AppState.swift:993, 1172, 1200-1203`;
  `IngestModels.swift:88-96`).
- Connection state is a cached enum the app re-syncs only from the Status page's refresh button
  (`GarageGRPCService.swift:358-366`). If the helper hosting the server dies, `status` stays
  `.running`, `call()` never restarts it, and a ping failure closes the shared channel under other
  in-flight RPCs (`:352`). The embed worker has two code paths, in-process `backfill_model` and
  `GetEmbeddingBatches`/`UpdateEmbeddings`, which disagree on batch size, the width check, and
  `ON CONFLICT` (`embed/ollama.py:175` vs `server.py:1462`); Swift calls only `embedTexts`, so the
  second path is dead from the app.
- The gRPC server runs ten worker threads over a pool of five connections plus five overflow
  (`server.py:1516`, `db/engine.py:41-43`). `Backfill`, `EnrichFacts` and `Scan` each hold a worker
  for their whole run, and `GetStatus` reports `needs_migration` on any connection error, since
  `pending_migrations` returns every file on an exception (`db/migrate.py:217`).

**Extraction is keyed on suffix tables that drift.**

- `extract/dispatch.py` holds eleven suffix sets and a parallel `_EXTRACTOR_MODULES` table that must
  list every extractor by hand; it missed `_email` (the `KeyError`). `ingest/chunking.py:37`
  keeps its own suffix map that includes `.sol` and `.cob`, which `CODE_EXTENSIONS` lacks, so those
  branches are unreachable. `ingest/classify.py:32`, `ingest/scanner.py:375, 448, 533`,
  `extract/messages.py:67`, `extract/nicknames.py:150` and `extract/image.py:41` each hold more.
- Extractors name themselves one way and the revision table another: `documents.extractor` holds
  `tesseract`, `pypdf`, `pypdf+pdfplumber`, `python-docx`, `openpyxl`, while `extractor_revision`
  reports `image:2`, `pdf:1`, `docx:1`. Nothing joins the two.
- `documents.mime` exists in the schema and the model and is written as `None` on every row
  (`ingest/gateway.py:564`).
- The error contract is four exceptions in two hierarchies: `NoTextFound`, `UnsupportedFile` and
  `ExtractionError` under one root, `PlaceholderFile` under `Exception`; the pipeline's extract step
  has four `except` clauses (`ingest/pipeline.py:256-302`) and still misses one.
- A scanned PDF is flagged `meta.likely_scanned` (`extract/pdf.py:175-183`) and nothing acts on it;
  there is no way for the PDF extractor to hand a page to the image extractor. Office extractors
  skip embedded images for the same reason.
- The Messages path (`ingest/conversations.py`) bypasses classify, attribute, the quality gate and
  the chunk cap: a second pipeline for one source kind.

**The schema carries dead weight and forgets things.**

- `conversations` and `messages` (`005_conversations.sql`) are never read or written; the only
  reference is a row count in `schema_summary`. Their design (one other participant, a synthesized
  document) does not match how threads are stored.
- `ingest_state` has four values; only `ok` and `extract_failed` are written. `author_identities.kind`
  allows `imessage_handle` and `handle`, which nothing writes.
- A document whose re-extraction fails flips to `extract_failed` and keeps its chunks
  (`gateway.py:382`), but search filters `d.state = 'ok'` (`search/hybrid.py:120`), so a transient
  parser error makes a previously good document vanish from results until the next successful run.
- A file the quality gate rejects is deleted and its outcome forgotten (`gateway.py:400-421`), so it
  is re-read, re-extracted and re-rejected on every run. `ingest_outcomes` remembers only
  `no_text` and `failed`.
- `ingest_seen` gets one row per (run, uri) and is never pruned; neither is `ingest_runs`.
- `apply_migrations` runs every SQL file on every call and consults `schema_migrations` only to
  report what is pending; the Swift copy skips applied versions. A migration that is edited after
  it was applied is silently applied twice or never, depending on who runs it.
- Index overlap: `chunks_doc (document_id)` is covered by `chunks_ord_unique (document_id, ord)`;
  `documents_class (corpus_class)` by `documents_class_trust (corpus_class, trust_tier)`;
  `chunks_sha (chunk_sha256)` serves no query (chunk reuse compares hashes in Python,
  `gateway.py:619-633`).
- `chunks.tsv` is `to_tsvector('english', text)` for every chunk, code included, while
  `documents.lang` is stored and unused.
- Every document commit runs with default `synchronous_commit = on` against a cluster that only
  this app uses, and no session sets `statement_timeout` or `lock_timeout`.

---

## 1. One facade: `GarageService`

Goal: the only process that opens a Postgres connection is the one hosting `GarageService` (plus the
CLI and tests, which are the same code in-process). Everything else, the app, the ingest helper, the
embed helper, the MCP helper, speaks protobuf to it. Then the server can own the connection pool,
the session settings, the migrations and the invariants, and nothing can bypass them.

### 1.1 The app reads only through the RPCs

- Replace `PostgresService.listRegisteredModels`, `listRegisteredSources` and `fetchCorpusStats`
  with `ListModels`, `ListSources` and `GetStats` (the Swift client already has them in
  `GarageGRPCService+Operations.swift`). Keep `psql` for what only it can do: `pg_isready`-style
  reachability, backup and restore, and the launcher's "is the cluster up" check.
- Replace `PostgresService.applyMigrations` with `InitDb`. Postgres must be up before the server
  starts, and the server needs the schema before it answers; the order is already cluster → helper
  → server → `InitDb` on the Python side, so the Swift copy is a second implementation with a
  different skip rule, not a bootstrap necessity. `GetStatus.db_status = needs_migration` is the
  signal the app acts on.
- Delete the `psql` output parsing and `RegisteredModel`/`RegisteredSource`/`CorpusStats` decoding
  once nothing uses them. Test: a unit test over `PostgresService` asserting it no longer has any
  `SELECT` text.

### 1.2 The ingest worker persists only through the facade

- Make the gateway choice explicit. `ingest_xpc` takes a `storage` argument that is one of
  `grpc(socket | host:port, token)` or `direct(database_url)`; the helper passes the gRPC one and
  the CLI passes `direct`. Remove the `os.environ` sniffing from `get_storage_gateway`
  (`gateway.py:1008-1050`); a worker with no explicit storage fails at `BeginIngestSession`, loudly,
  instead of opening Postgres.
- One route for configuration. `IngestOptions` carries the gRPC address and token (it already
  carries the token); drop `setDatabaseURL` and `IngestOptions.databaseUrl`, and stop putting the
  database URL in the ingest and embed helpers' `updateConfiguration` at all, since they no longer
  connect. The "Database Connection" self test in those two helpers becomes a "gRPC Connection"
  test that makes a real `Ping` with the token.
- Replay configuration. `mergeConfiguration` stores the options and `pythonDidBecomeReady` applies
  whatever arrived before Python was up (`GarageXPCServiceBase.swift:280-292`). This is a bug fix on
  its own and can land first.
- Fold the per-worker embed path into the one that exists. Swift calls only `embedTexts`; backfill
  runs inside the server. Either delete `embed_via_grpc`, `GetEmbeddingBatches` and
  `UpdateEmbeddings` (reserve the field numbers), or make `backfill_model` the one implementation
  and have the RPC path call it with a gateway, as ingest does. Deleting is the simpler choice and
  the plan assumes it; `test_embed_xpc.py` goes with it.

### 1.3 Server internals: handlers translate, modules decide

- Move the nine inline queries into `ops/` (`ops/corpus.py`: `search`, `list_documents`,
  `get_document`, `list_sources`, `list_models`, `stats`; `ops/sources.py`: `persist_scan`). Each
  returns a dataclass; the handler, the CLI and the MCP tools all call the same function.
  `cli.py:541` and `mcp_server/server.py:390` stop carrying their own copies. This is the rule the
  module docstring already states (`server.py:1-9`); it is just not true yet.
- One translation layer, `service/convert.py`, with `to_proto(dataclass)` / `from_proto(message)`
  pairs and a round-trip test per message (`test_grpc_serialization.py` already does this for some).
  Empty-string-means-None lives there, once, instead of in each handler
  (`server.py:1322-1368` does it for `replace` and not for the other actions).
- Replace `PersistDocumentRequest.action` with a `oneof outcome { Placeholder; ExtractFailed;
  NoText; Rejected; Seen; RefreshMetadata; Replace }`. Each arm carries only its fields, so the
  server cannot receive a `title` on a `seen` or discard a `mtime` on a `placeholder` (which it does
  today, `server.py:1286`). Proto3 `oneof` is wire-compatible to add beside the string field; the
  string field is reserved after the app ships with the new one.
- Typed progress. Give `ScanStatus`, `BackfillStatus`, `EnrichFactsStatus` and the ingest progress
  JSON a `Phase` enum (`STARTED`, `PROGRESS`, `DOCUMENT`, `FINISHED`, `SKIPPED`, `CANCELLED`,
  `FAILED`) and move the ingest progress message into `garage.proto` so Swift decodes it with the
  generated code rather than a hand-mirrored struct (`IngestModels.swift:52-85`). Swift then switches
  on the enum in one place per stream instead of comparing strings in six.
- Drop `formatted_output` from responses. It is presentation, every client formats differently, and
  it is the only reason some handlers import `snippet` and f-string summaries. The CLI builds its
  text from the dataclass.
- Shared enums. Declare `CorpusClass`, `TrustTier`, `SourceKind` and `AuthorRole` as proto enums
  and use them in every message that carries one. `db/models.py` keeps the Python enums but a test
  asserts they match the proto; Swift drops `CorpusTaxonomy.swift:7-8`, `SourcesView.swift:38-40`
  and `FactPrompts.swift:109`.

### 1.4 Connection lifecycle the app can trust

- One `call()` path. `search`, `listDocuments` and `getDocument` get their own copies of the
  auto-start and a different error mapping (`GarageGRPCService.swift:379-381, 432-434, 462-464`).
  Route them through `call()` so cancellation and errors mean the same thing everywhere.
- Status from facts, not memory. Replace the cached `status` enum with a watchdog: a `Ping` every
  few seconds while any view that needs the backend is open, plus the helper's XPC
  `isServerRunning`. A failed ping marks the server down and triggers one restart attempt with
  backoff; `call()` waits on readiness rather than on the enum. `start()` returning at once while
  `.starting` (`:186`) becomes "await the in-flight start".
- Never close the shared channel under in-flight calls. A failed ping marks the channel suspect and
  the next `call()` rebuilds it after the current calls finish; `cleanupChannel` from `deinit` on
  the main actor goes.
- Size the server for its streams. `max_workers` grows to the number of long streams the app can run
  at once plus a reserve for unary reads (the app runs backfill and enrich-facts on dedicated
  runners, so at least two long streams), and the engine pool matches. `GetStatus` distinguishes
  "cannot connect" from "needs migration" (`pending_migrations` raises, the handler reports
  `db_status = unreachable`), so the app shows the right remedy.
- Session settings in one place. `session_scope` takes a `role` (`read`, `ingest`, `maintenance`)
  that sets `statement_timeout` for reads, `synchronous_commit = off` for ingest commits (one
  document per transaction on a local cluster; durability across a crash is a re-ingest of the last
  document, which the stat skip already handles), and `lock_timeout` for DDL. See §3.6.

### 1.5 Helper configuration is one struct

- One `HelperConfiguration` value (gRPC address, token, models directory, manifest, MCP executable)
  built in one place (`GarageGRPCService.helperConfiguration()` already exists, `:134-147`), sent to
  every helper by `configureHelpers`, replayed on helper restart and on Python readiness. The
  database URL is in it only for the helper that hosts the server and the MCP helper.
- The in-process (sandboxed) host shares one Python with the ingest delegate; the server's
  `os.chdir` and ingest's `reset_settings`/`reset_engine` affect each other
  (`GarageXPCServiceDelegate.swift:56-58`, `GarageIngestXPCServiceDelegate.swift:274-283`). With §1.2
  ingest no longer touches the engine, and the server stops calling `chdir` (it takes the working
  directory as a setting instead), which removes the shared state.

**Order:** replay fix (1.2 bullet 3) → explicit gateway (1.2) → app reads over RPC (1.1) → ops
extraction and convert layer (1.3) → oneof and enums (1.3) → lifecycle (1.4) → helper config (1.5).
Each is one PR; 1.1 and 1.2 are independent of each other.

---

## 2. Extraction contract: media types in, one result shape out

Goal: adding a format means registering one extractor under the media types it handles; the
walker, the revision table, `documents.mime`, the chunker's language choice and the scanner all read
the same registry. `image/*` goes to Tesseract because the registry says so, not because eleven
suffixes are listed in the right set.

### 2.1 Identify the file once

`extract/media.py`:

```python
@dataclass(frozen=True)
class MediaType:
    type: str           # "image/png", "application/pdf", "text/x-python", "message/rfc822"
    source: str         # "suffix" | "name" | "magic" | "uttype"

def identify(path: Path, *, size: int) -> MediaType | None
```

- Suffix and known-name lookup first (free, no I/O), from one table that maps suffix → media type.
  On macOS, `UTType(filenameExtension:)`/`UTType(contentsOf:)` is reachable from Python through the
  same ctypes pattern as `extract/imageio.py`; off macOS the table and `mimetypes` stand in. A
  magic-byte check only for the ambiguous cases (a `.msg` is OLE, a `.doc` may be RTF, an `.xml` may
  be an Atom feed), with the first 4 KiB read once.
- `is_indexable(path)` becomes `identify(path) is not None and registry.handles(media_type)`. The
  walker keeps its "no I/O before pruning" property because identification by suffix needs none.
- `documents.mime` gets the identified type. That column finally means something: it drives the
  Documents page's icon, `rag_get_document`'s hint to the client, and per-type stats.

### 2.2 One registry, one protocol

```python
class Extractor(Protocol):
    name: str                       # the one name: "image", "pdf", "docx", "email", "code", ...
    version: str                    # bumps retry remembered outcomes
    media_types: tuple[str, ...]    # "image/*", "application/pdf", "text/markdown", ...
    def extract(self, path: Path, media: MediaType, ctx: ExtractContext) -> ExtractResult: ...

REGISTRY: list[Extractor]          # first match on media type wins; "text/*" is the fallback

def extractor_for(media: MediaType) -> Extractor
def extractor_revision(media: MediaType) -> str   # f"{e.name}:{e.version}", derived, cannot be missing
```

- `ExtractResult.extractor` is `Extractor.name`; the engine that did the work (`pypdf`,
  `pypdf+pdfplumber`, `tesseract`) moves to `meta.engine`. `documents.extractor` then joins
  `extractor_revision`, and `_indexed_by_a_retired_extractor` (`pipeline.py:154`) becomes a
  comparison of `documents.extractor || ':' || extractor_version` against the registry instead of a
  per-suffix special case.
- `ExtractContext` carries settings (`max_file_bytes`, `ocr_min_chars`) and a `delegate(media_type,
  path_or_bytes)` callback, so an extractor can hand a sub-document to another: the PDF extractor
  rasterizes a page it found empty and delegates it as `image/png`; the DOCX extractor delegates
  embedded images. The `likely_scanned` flag becomes a behavior. Delegation is bounded by the same
  budget settings (pages per PDF, images per document) so a photo album in a `.pptx` does not become
  an OCR run.
- One error hierarchy under `ExtractionOutcome`: `NoText`, `Unsupported`, `Placeholder`, `Failed`.
  The pipeline's extract step becomes one `except ExtractionOutcome as outcome` that maps to the
  gateway's oneof arm (§1.3). `PlaceholderFile` moves under it (the "deliberately distinct" note in
  `placeholder.py:66-70` is about the remedy, which the subclass still expresses).
- Lazy imports stay: each registry entry names a module and the attribute to load, as
  `_EXTRACTOR_MODULES` does today, so a walk over a code tree still never imports `pdfplumber`.

### 2.3 Every other suffix table reads the registry

- `ingest/chunking.py:37` (`_CODE_LANGUAGES`) becomes a map from media type (`text/x-python`) to
  splitter language, and its two unreachable entries either get media types or go.
- `ingest/classify.py:32` (`_DOC_EXTENSIONS_IN_CODE_TREES`) asks "is this media type prose" of the
  registry entry (`ContentKind` lives on the extractor, so the question is answerable without
  extracting).
- `ingest/scanner.py` counts by the same `identify`, so a scan's `expected_elements` and an
  ingest's `seen` agree by construction (today maildir counts `.msg`/`.mbox` the walker never
  indexes, `:448`).
- `extract/messages.py:67`, `nicknames.py:150` and `scanner.py:375` share one `SQLITE_SUFFIXES`.
- Swift has no suffix tables to delete; it never decides what is indexable.

### 2.4 Sources produce documents through one pipeline

The Messages path is a second pipeline because its input is not a file. Make the unit of work a
`DocumentCandidate` (uri, media type, a way to get bytes or text, stat) produced by a `Producer`
per source kind: the walker yields file candidates; the `sqlite` producer yields one candidate per
thread with `media_type = "application/x-garage-thread"` and the rendered text already in hand.
`ingest_one` then runs the same steps for both: stat skip, extract (a no-op extractor for
pre-rendered text), quality gate, chunk, classify, attribute, persist. The thread-specific parts
(one chunk per message, `direction`/`sender`) become the `CONVERSATION` chunker, which is where they
belong. Then communications get the chunk cap and attribution evidence like everything else, and
`_ingest_source`'s `if kind == "sqlite"` branch (`pipeline.py:546-566`) goes.

**Order:** `identify` + `documents.mime` (2.1) → registry and derived revision (2.2, replaces the
hand-kept table and lands the one-name rule; a migration rewrites `documents.extractor` from the
old engine names) → error hierarchy (2.2) → the other tables (2.3) → delegation for scanned PDFs
(2.2, with a budget setting and the schema regen) → producers (2.4). The two bug fixes in §5 land
first and the registry step deletes the table they patch.

---

## 3. Schema: resilient, bounded, tuned

Goal: the schema says what the code does, every ingest outcome has one home, bookkeeping cannot grow
without bound, migrations apply once, and the server is configured for a single-user local corpus.
Migrations keep the repo's rules: idempotent, re-applicable, `data/sql` is truth and
`db/models.py` mirrors it, and `docs/schema.md` is updated with each.

### 3.1 Drop what nothing writes (`015_drop_unused.sql`)

- `DROP TABLE conversations, messages` and their models. If the v1.5 memory/triples work needs a
  message-level store it will be designed for how threads are actually stored.
- `ingest_state`: remove `embed_partial` and `placeholder`. Postgres cannot drop enum values, so
  recreate the type: add `ingest_state_v2 ('ok', 'extract_failed')`, alter the column with a
  `USING`, drop the old type, rename. Or, with §3.3, drop `documents.state` entirely.
- `author_identities_kind_check`: keep only the kinds code writes, plus whatever `self_identities`
  config may list (a test enumerates both).
- Drop `chunks_doc`, `documents_class` and `chunks_sha` (covered or unused, §0).
- `documents.mime` stays and is populated (§2.1).

### 3.2 Migrations apply once (`db/migrate.py`)

- `apply_migrations` skips files whose stem is in `schema_migrations`, as the Swift copy already
  does; idempotency remains the safety net, not the mechanism.
- Add `checksum` to `schema_migrations`. An applied file whose checksum changed is an error that
  names the file: edit a migration, add a new one. A test hashes `data/sql` and fails when a
  committed migration's checksum moves after it is tagged (keep a `data/sql/CHECKSUMS` file the test
  regenerates on demand).
- Each file runs in its own transaction (`BEGIN … COMMIT` around the file, with
  `lock_timeout` set so a migration that needs an exclusive lock fails fast against a running
  backfill instead of queuing behind it and blocking every reader). The extension file stays outside
  SQLAlchemy as today.
- Replace the f-string `INSERT` (`migrate.py:160-162`) with a parameter. `pending_migrations`
  raises on a connection error instead of returning every file (§1.4 uses the distinction).
- With §1.1 the Python applier is the only one; the Swift copy is deleted.

### 3.3 One home for ingest outcomes (`016_ingest_outcomes.sql`)

Today a file's last outcome lives in two places with different rules: `documents.state`/`error`
for a document that exists, `ingest_outcomes` for one that does not, and nowhere for `rejected`.

- `ingest_outcomes` becomes the record of the last attempt for every (source, uri), whatever the
  result: `outcome IN ('indexed', 'unchanged', 'no_text', 'rejected', 'failed', 'placeholder',
  'unsupported')`, with `byte_size`, `mtime`, `source_sha256`, `extractor_revision`, `error`,
  `run_id`, `recorded_at`. `rejected` is remembered, so the quality gate runs once per file version
  instead of once per run.
- `documents.state` and `documents.error` go. A document row exists only for indexed content, and
  search's `d.state = 'ok'` filter goes with it. A failed re-extraction records `failed` in
  `ingest_outcomes` and leaves the document and its chunks searchable; the Documents page shows the
  outcome beside the document by joining on (source_id, uri). A document whose file is gone is still
  reconcile's job, not an outcome.
- `check_stat` reads one row from each table and `_is_settled` becomes "the outcome row's stat
  matches and its revision is current". The pipeline's step 1 and step 3 skip rules collapse to one.

### 3.4 Bound the bookkeeping (`017_last_seen.sql`)

- Replace `ingest_seen` with `ingest_outcomes.run_id`: "seen in run R" is "outcome row's run_id =
  R", which §3.3 writes anyway. Reconcile deletes documents whose outcome row's `run_id` is older
  than the source's last completed run, under the same completed-run guard as today
  (`ingest/reconcile.py`). One fewer table, no per-run row fan-out, and the walk's
  `record_seen` becomes an `UPDATE … SET run_id` on a row that exists.
- Keep the last N `ingest_runs` per source (N = 20, a setting) and delete older ones in
  `finalize_session`. `fact_runs` is per (document, prompt) and already bounded.
- `scan_details` stays on `sources`; it is one row per source.

### 3.5 Search-side columns

- `chunks.tsv` uses the `simple` configuration for `code` chunks and `english` for the rest:
  `to_tsvector(CASE WHEN chunker LIKE 'code%' THEN 'simple' ELSE 'english' END::regconfig, text)`
  is immutable enough for a generated column when written with the literal regconfig casts. Stemming
  identifiers (`parser` → `pars`) hurts code recall and helps nothing. `documents.lang` is either
  used to pick the configuration or dropped; the plan drops it until an extractor sets it.
- `facts.tsv` serves only `ListFacts`; keep it, it is small.
- The `hnsw_bq` first stage (`hybrid.py:229-259`) and `index_kind = 'none'` are reachable only for
  models wider than 4000 dims without MRL; `models.json` has none. Leave the code, add a
  `test_postgres.py` case so it stays working, since it is the only path that is never exercised by
  the app.

### 3.6 Postgres session and cluster settings

Set by the server (§1.4) per session role, and by the app in `postgresql.conf` for the bundled
cluster:

| Setting | Where | Why |
|---|---|---|
| `synchronous_commit = off` | ingest and backfill sessions | one commit per document or batch; losing the last one on a crash is a re-ingest the stat skip handles |
| `statement_timeout = 30s` | read sessions (search, lists) | a runaway query cannot wedge the UI; the app's 30 s client deadline becomes a server-side fact |
| `lock_timeout = 5s` | migrations, `DROP TABLE emb_*` | fail fast behind a backfill instead of queuing and blocking every reader |
| `hnsw.ef_search` | search sessions (exists) | unchanged |
| `maintenance_work_mem = 512MB` | backfill session before `CREATE INDEX` | HNSW builds are memory-bound; the index on a new model table is built after the first backfill, not before (`create_embedding_table` builds it empty today, so every insert is an index insert) |
| `jit = off` | cluster | short OLTP queries lose to JIT warm-up |
| `shared_buffers`, `effective_cache_size` | cluster, from physical RAM | the bundled cluster ships Postgres defaults sized for a shared host |

The index-after-backfill change is the one with a visible payoff: build the per-model table without
its HNSW index, backfill, then `CREATE INDEX` once (`emb_tables.create_embedding_table`,
`registry.index_ddl`). `embedding_models` gets `index_built boolean` so search falls back to exact
KNN (`SET LOCAL enable_indexscan`, or no `ORDER BY` operator hint needed; pgvector does exact scans
without an index) until it is built, and `GetStats` reports it.

### 3.7 Constraints that catch bugs

- `chunks`: `CHECK (char_end IS NULL OR char_end >= char_start)`, `CHECK ((direction IS NULL) =
  (sender IS NULL))`.
- `facts`: same offsets check; `CHECK (char_start IS NOT NULL)` once the extractor drops ungrounded
  facts, as the comment in `006_facts.sql` says it does.
- `documents`: `CHECK (content IS NOT NULL)` once §3.3 makes a document row mean indexed content;
  `CHECK (extractor <> '')`.
- `ingest_outcomes`: `CHECK (outcome <> 'failed' OR error IS NOT NULL)`.
- `embedding_models`: `CHECK (index_kind <> 'hnsw_bq' OR storage_kind = 'vector')`.

**Order:** migrations-apply-once (3.2, no schema change, unblocks safe edits) → drop unused (3.1)
→ outcomes (3.3, with the gateway oneof from §1.3 so the wire change and the table change are one
PR) → last-seen (3.4) → tsv config and `lang` (3.5) → session roles and index-after-backfill (3.6)
→ constraints (3.7, last, once the code guarantees them).

---

## 4. Cross-cutting: one source for each truth

| Truth | Today | After |
|---|---|---|
| Corpus class, trust tier, source kind, author role | SQL enums, Python enums, three Swift string lists | proto enums (§1.3); SQL and Python checked by test; Swift uses the generated enums |
| Progress phases | strings compared in six Swift sites and three Python ops | proto `Phase` enum (§1.3) |
| What is indexable and how | eleven suffix sets plus six satellites | `extract/media.py` + the registry (§2) |
| Extractor name | `documents.extractor` vs `_EXTRACTOR_MODULES` | `Extractor.name` (§2.2) |
| Model catalog | `models.json`, `GarageConfigLoader` with three decode shapes and name heuristics | `models.json` read by Python; Swift gets `ListModels` plus a `ListCatalog` RPC that returns the catalog with `is_embedding`, `dims`, `provider` resolved (closes the catalog item of #27) |
| Config defaults | `config/__init__.py` and `GarageConfigLoader.swift:439-487` | Swift reads settings through `GetSetting`; the defaults exist once, in Python |
| Schema version | Python applies everything each time; Swift skips applied | Python applies once with checksums (§3.2); Swift calls `InitDb` |
| Database URL for helpers | three routes to ingest | one `HelperConfiguration` (§1.5), and only two helpers get the URL at all |

---

## 5. Already underway

Two defects confirmed while reading, fixed on `main` in their own session and PR, independent of
this plan:

- `extract/dispatch.py:267` `_EXTRACTOR_MODULES` has no `_email` entry; `extractor_revision()`
  raises `KeyError` for `.eml`/`.emlx`, so a mail file that fails extraction or has no text crashes
  the per-file handler instead of being remembered. Fix: add the entry and a test that every
  extractor `extractor_for` can return is in the table. §2.2 later derives the revision from the
  registry, which makes the table and the test unnecessary.
- `PlaceholderFile` is a plain `Exception` and `extract()` raises it from `check_materialized`;
  `ingest_one`'s extract step does not catch it, so the file is counted as an error and recorded as
  `seen` instead of as a placeholder. Fix: catch it in step 3 as step 2 does, with a pipeline test.
  §2.2's error hierarchy makes it one `except`.

---

## 6. Sequencing

Each row is one PR, with the tests that guard it. Rows in the same group are independent of each
other.

| # | Change | Guard |
|---|---|---|
| 1 | §5 defects | new unit tests |
| 2 | Replay helper configuration when Python becomes ready (§1.2) | `GarageXPCServiceBase` unit test with a stubbed runtime |
| 3 | Migrations apply once, with checksums and per-file transactions (§3.2) | `test_migrate.py`, `test_postgres.py` |
| 4 | Explicit storage choice for the ingest worker, delete the env sniffing (§1.2) | `test_ingest_gateway.py`, `test_ingest_xpc.py` |
| 5 | App reads models, sources, stats and runs `InitDb` over gRPC; delete the `psql` reads and the Swift migrator (§1.1) | Swift unit tests; `test_grpc_operations.py` |
| 6 | Move inline handler queries into `ops/`; `service/convert.py` with round-trip tests (§1.3) | `test_grpc_documents.py`, `test_grpc_serialization.py`, `test_cli_commands.py` |
| 7 | `identify()` + `documents.mime` populated (§2.1) | `test_fixture_corpus.py` asserts a mime per document |
| 8 | Extractor registry, derived revision, one name, migration rewriting old names (§2.2) | `test_image_extract.py`, `test_mail_extract.py`, `test_postgres.py` for the rename |
| 9 | One error hierarchy; one `except` in the pipeline (§2.2) | pipeline tests over a mocked gateway |
| 10 | Drop unused tables, enum values, indexes (§3.1) | `test_postgres.py` migration re-apply |
| 11 | `PersistDocument` oneof + `ingest_outcomes` as the one outcome record, `documents.state` dropped (§1.3, §3.3) | `test_ingest_gateway.py`, `test_postgres.py`, `test_grpc_serialization.py` |
| 12 | `ingest_seen` → `run_id` on outcomes; prune `ingest_runs` (§3.4) | reconcile tests, `test_postgres.py` |
| 13 | Proto enums and `Phase`; ingest progress in proto; Swift switches on them (§1.3) | enum-parity test; Swift presentation tests |
| 14 | Connection watchdog, one `call()` path, server sized for streams, `unreachable` vs `needs_migration` (§1.4) | `test_grpc_server.py`; Swift unit tests for the watchdog state machine |
| 15 | Session roles and settings; index after first backfill (§3.6) | `test_postgres.py` builds a model table, backfills, builds the index, searches |
| 16 | Remaining suffix tables read the registry; scanner and walker agree (§2.3) | `test_scanner.py` counts == walker counts over the fixture corpus |
| 17 | Delegation: scanned PDF pages and embedded images to `image/*` (§2.2) | fixture PDF with one scanned page; budget setting documented and in the schema |
| 18 | `tsv` configuration per chunk kind; drop `documents.lang` (§3.5) | `test_postgres.py` keyword search over an identifier |
| 19 | Producers: Messages through the one pipeline (§2.4) | `test_messages.py`, `test_fake_messages.py` |
| 20 | Constraints (§3.7); `ListCatalog` and Swift config through `GetSetting` (§4) | `test_postgres.py`; Swift tests |
| 21 | `HelperConfiguration` as one struct; server stops `chdir` (§1.5) | Swift tests; `test_grpc_server.py` |

Groups: {1, 2, 3} → {4, 5, 6, 7} → {8, 9, 10} → {11, 12, 13} → {14, 15, 16} → {17, 18, 19} →
{20, 21}. Nothing here changes the egress guard; every step that touches `embed/`, `enrich/` or
`net/` keeps `test_egress_block.py` and `test_embed_egress.py` green, and the deletion of the
worker embed path (§1.2) removes one caller from `CALLERS` rather than adding one.

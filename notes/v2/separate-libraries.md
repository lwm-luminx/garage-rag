# More than one corpus in Garage v2: design exploration

> 2026-09-29: the several-Macs goal is covered by `design.md` and `../postgres-sync/peer-sync-design.md`. Multiple corpora are still wanted: Rick decided how the MCP server picks one (see MCP below).

Status: exploration, no code. Written 2026-09-29 against `main` at 04d210d.

## The short answer

Support several **corpora** in one Garage, each a **separate Postgres database inside the one
bundled cluster** (`CREATE DATABASE garage_<slug>`), with its own sources, models, facts, graph,
backups and privacy policy. Keep one Postgres server, one gRPC backend and one set of XPC services;
route every call to a corpus by name. Leave "a second Postgres instance" and "a remote Postgres"
for later, because both cost a lot and one of them (remote) breaks the privacy guarantee as written.

The Python side needs one real refactor first (settings and the engine are process-wide
singletons), and the cluster's connection budget has to grow. Everything else is plumbing.

## What people would use it for

"More than one DB / instance / corpus" covers four different wishes. They pull the design in
different directions, so it matters which ones v2 serves.

| Wish | Example | What it needs |
|---|---|---|
| **Separation** | Work vs. personal; a client's documents kept apart from mine | Strong isolation, per-corpus MCP access, per-corpus reset and backup |
| **Different rules** | Personal corpus stays strictly local; a work-docs corpus may embed on the office LM Studio box | Per-corpus egress policy and model choice |
| **Portability** | Hand a colleague a corpus of product docs; move a corpus to another Mac | Self-contained dump of one corpus, including its model registry |
| **Scale / placement** | A huge code corpus on an external SSD, or on a NAS Postgres | Tablespaces or another server |

The first three are well served by database-per-corpus. The fourth is the only one that needs
another instance, and it is the rarest for a personal tool.

## Options considered

### A. Collections inside one database (a `corpus_id` column)

Add a corpus tag to `sources` (and denormalize to `documents`/`chunks`), filter every query.

- Cheapest: no new databases, one engine, cross-corpus search is just "no filter".
- Weakest isolation: one missing `WHERE` leaks a work document into a personal answer. Every
  query in `search/hybrid.py`, `mcp_server`, facts, stats, the gRPC listing calls and every future
  one has to remember the filter. Per-model `emb_*` tables and HNSW indexes are shared, so
  filtered KNN gets worse (pgvector filters after the index scan; a small corpus inside a big one
  returns too few hits unless `hnsw.iterative_scan` is tuned).
- Reset and backup of one corpus become DELETE-by-tag and a filtered dump, both slow and fragile.

Good for "saved scopes" (see below), not for the separation people are asking for.

### B. One database per corpus in the bundled cluster (recommended)

`garage_personal`, `garage_work`, … in the existing `pgdata`, each migrated with the same
`data/sql`.

- Isolation is Postgres's own: a connection is bound to one database, so a query cannot reach
  another corpus by mistake. MCP access control becomes "which database may this registration
  open", which is easy to reason about and test.
- Per-corpus everything falls out for free: `embedding_models` and `emb_*` tables (a code corpus
  can use a code model, a mail corpus a small fast one), `facts`/`fact_runs`, the AGE graph
  (graphs live per database), `ingest_outcomes`, stats.
- Backup and restore are `pg_dump -d garage_work`, which is also the portability story.
- **Reset of one corpus is `dropdb --force` + `createdb` + migrate, with no app relaunch.** Today's
  Reset Database deletes `pgdata` and relaunches (`resetDatabaseAndRelaunch`, the
  `--after-database-reset` handshake, #203's sandbox fix). Per-corpus reset is simpler and safer
  than what ships now; "Reset everything" can keep the current path.
- One postmaster, one set of shared buffers, one socket, no new entitlements, no new listeners.
- Cost: cross-corpus search is a fan-out in Python (below), and each database is its own
  connection pool.

### C. One schema per corpus in one database

`search_path`-switched schemas. Cross-corpus SQL is possible, but migrations must run per schema,
`emb_*` names and the `embedding_models_table_name_shape` check need schema qualification, AGE and
pgvector live in `public`/`ag_catalog` and are shared, and a `search_path` slip is the same leak as
option A. It has B's work without B's isolation. Not recommended.

### D. One Postgres cluster per corpus

A postmaster per corpus, each with its own `pgdata`, socket and password.

- Real benefits only for: different Postgres majors per corpus (no), a corpus whose whole data
  directory lives on another volume, and separate crash domains.
- Costs: memory and a process per corpus; `PostgresService` becomes a collection; the flock
  interlock, the SIGINT shutdown, the socket path budget (104 bytes of `sun_path`), keychain items
  and the Reset handshake all multiply. The App Store app runs Postgres as a child of a sandboxed
  process, so a data directory on another volume needs a security-scoped grant the postmaster
  inherits; that is unproven.

Placement on another volume is better done later as a **tablespace** inside option B
(`CREATE DATABASE … TABLESPACE`), after testing that a sandboxed postmaster can use a granted
external folder. If it can't, it is a Developer ID-only feature.

### E. A remote or external Postgres (NAS, Homebrew, a team server)

Attach a corpus that lives on another server.

- **Breaks the privacy guarantee as written.** psycopg is listed as local infrastructure in
  `INBOUND_OR_LOCAL`; a remote database URL sends every chunk, communications included, off the
  Mac. It would have to go through the egress guard like an HTTP destination: an explicit
  allowlisted host, the content rule applied (a corpus whose server is not loopback may not hold
  `communication` sources), and TLS required. `test_egress_block.py` would need a new layer.
- Needs pgvector ≥ 0.7 and (optionally) AGE on that server, and migrations we don't control the
  timing of. The app has `network.client` already, so the sandbox is not the obstacle.
- Worth doing only as "attach read-only" for a shared team corpus, and only after B exists.

## The recommended design (B) in more detail

### Vocabulary

"Corpus" in the code and docs; in the UI probably **Library** ("Work library", "Personal
library"). One corpus is the default and is what everything uses when nothing says otherwise, so a
single-corpus user sees no change.

### Storage

- Database name `garage_<slug>`; the existing `garage-rag` database becomes the default corpus
  with slug `default` (renamed in place or kept under its old name with a mapping; keeping the
  name avoids touching an upgraded user's data).
- The corpora are tracked in a **catalog database** (Rick, 2026-09-29), described below.
- **Connection budget.** `initdb` sets `max_connections=5` (`PostgresService.swift:419`), and
  SQLAlchemy pools are per engine, per process (`db/engine.py`: pool 5 + overflow 5). Connections
  are per database, so N corpora across the backend, ingest, embed and MCP processes plus each
  stdio `garage-mcp` will not fit in 5. v2 needs a higher `max_connections` (set at start, not only
  at initdb, so existing clusters get it too), lazily created engines, and small pools (or
  `NullPool` for short-lived stdio MCP processes). Worth checking separately whether today's single
  database is already near that ceiling.

### The catalog database

**Decided (Rick, 2026-09-29): a master database tracks the corpora.** It is `garage_catalog`, in
the same cluster, created at first launch before any corpus. It holds no document content, only
what spans corpora:

| Table | Holds |
|---|---|
| `corpora` | slug, display name, database name, `is_default`, created, state (`ready`, `migrating`, `resetting`, `deleting`), schema level applied, egress policy (`local-only` or may use the configured off-box hosts) |
| `corpus_settings` | per-corpus settings (sources, chunking, quality, facts model and prompts, default embedding model) as typed JSON validated by the same `SECTIONS` machinery |
| `app_settings` | Mac-wide settings (`embedding.*_host`, `llama_host`, `identity`, `inference`, the placeholder disk cap, MCP HTTP) |
| `mcp_registrations` | which assistant config entry points at which corpus, over stdio or HTTP, so the MCP page and Update know without re-parsing every config file |
| `jobs` | maintenance and Update Everything runs across corpora: corpus, step, started, finished, result |
| `nodes`, `corpus_peers` (v2 sync) | this Mac's node id and certificate; each paired Mac's **public key / certificate**, stored in the row (Rick, 2026-09-29), which is what permits mTLS for sync: a peer connection is accepted only when its client certificate matches a stored one, and outgoing connections pin the peer's. This Mac's private key stays in the Keychain, never in the catalog. `corpus_peers` records which corpora are shared with which peer; the peer protocol reads its per-corpus digests' scope from here. Unpairing deletes the row, which revokes that Mac at once |

How it is used:

- **Resolving a corpus.** `garage-mcp --corpus work`, `/mcp/work`, `x-garage-corpus: work` and
  the CLI's `--corpus` all resolve through `corpora`. An unknown slug, or one not `ready`, is an
  error, never a fallback to the default. Each process keeps one small pool on the catalog and
  opens a corpus's engine lazily on first use.
- **Lifecycle.** Create corpus: insert a row in `migrating`, `createdb`, apply `data/sql`, mark it
  `ready`. Delete: mark it `deleting`, `dropdb --force`, delete the row. Reset: mark it
  `resetting`, then drop, recreate and migrate. The state column makes an interrupted step
  resumable at the next launch, and keeps MCP and ingest off a corpus mid-change.
- **Migrations.** The catalog has its own schema (`data/sql/catalog/`), applied first. It then
  records each corpus's schema level, so the Database page can show "work: 2 updates to apply"
  without connecting to every corpus.
- **Config file.** `garage.json` stops being the source of truth. It becomes an import and export
  format: `garage config export` writes the catalog's settings in today's nested shape, and a
  `garage.json` found at launch is imported once. That covers the upgrade: an existing file's
  `sources` become the default corpus's settings. `garage config get/set` read and write the
  catalog. The JSON Schema stays generated from `SECTIONS`.
- **Upgrade.** On first launch of a catalog-aware build: create `garage_catalog` and register the
  existing `garage-rag` database as the default corpus under its current name. No data moves.
- **Backups.** A corpus backup is `pg_dump` of its database plus a small manifest of its catalog
  row and settings, so restoring it on another Mac recreates the corpus. "Back up everything" adds
  the catalog.
- **Reset has two forms (Rick, 2026-09-29).** **Reset this corpus** drops and recreates one
  corpus's database and migrates it, with no relaunch; its catalog row and settings (sources,
  models) are kept, so the next Update Everything re-indexes it. **Reset everything** is today's
  Reset Database: it stops every service, deletes `pgdata` (the catalog with it) and relaunches,
  and the new instance recreates the catalog and the default corpus and imports `garage.json` if
  one exists. The Database page's Start Over row offers both, and the reset sheet names which
  corpus or says "every corpus".
- **Connection budget.** The catalog adds one always-open pool per process, which makes raising
  `max_connections` (below) a prerequisite.

Why a database rather than a config file: the corpus list, the lifecycle states and the job history
are written by several processes (app, backend, CLI, MCP). The config file is read once per
process and written without locking, and it can't express "this corpus is mid-reset". The catalog
also gives the v2 peer protocol a transactional place for pairing and sharing state.

### Python

This is the real work.

- `get_settings()` and `get_engine()` are process-wide singletons (`config/__init__.py:977`,
  `db/engine.py:26`), and most modules call them directly. Introduce a `Corpus` context (settings +
  engine + slug, resolved through the catalog) carried in a `contextvars.ContextVar`, set at each entry point (CLI `--corpus`,
  each gRPC call, each MCP request), with `get_settings()`/`get_session()` reading it. This keeps
  the diff to the entry points instead of threading a parameter through every function, and it
  works with threads and asyncio. Free-threaded CPython doesn't change that.
- **gRPC:** a `corpus` metadata key (`x-garage-corpus`, beside `x-garage-token`), read by the
  same interceptor style as `service/auth.py`. Metadata instead of a field in 37 request messages
  means `GrpcIngestStorageGateway` and the embed worker just carry one more header. Corpus
  lifecycle gets its own RPCs: `ListCorpora`, `CreateCorpus`, `DeleteCorpus` (config-changing, so
  in `CONFIG_CHANGING_METHODS`), `ResetCorpus`.
- **Migrations:** `InitDb` and the Database page's schema check run per corpus; the app applies
  pending migrations to every corpus at start-up.
- **Egress:** `check_destination` gains the corpus's policy as an input, so "this corpus is
  local-only" is enforced where the rest of the policy is, and tested per layer like the others.

### Cross-corpus search

Needed for the menu-bar Ask and for an assistant allowed more than one corpus.

Run the existing hybrid search in each allowed database in parallel and fuse the per-corpus
result lists with RRF again. RRF is rank-based, so it fuses fine even when corpora use different
embedding models with incomparable scores. Hits carry their corpus slug. Cost is one query per
corpus; fine for the handful of corpora a person has.

### MCP

**Decided (Rick, 2026-09-29): the corpus is chosen by a command-line parameter for stdio and by
the URL path for HTTP.** An MCP connection serves exactly one corpus; tools take no `corpus`
argument, so an assistant can't reach a corpus its registration didn't name.

- **stdio:** `garage-mcp --corpus work`. The app writes the flag into each registration, and the
  entry in the assistant's config is named after the corpus (`garage-rag-work`), so one assistant
  can hold several clearly labelled entries. No flag means the default corpus, so today's
  registrations keep working.
- **HTTP:** `http://127.0.0.1:8787/mcp/work`. Bare `/mcp` is the default corpus. An unknown slug
  is a 404, never a fallback to the default. The server opens a corpus's engine on first request
  to its path.
- The launcher passes the flag through to Python unchanged; the bundled launchers still export
  only the database credential, and the corpus maps to its database inside Python.
- The MCP page's Connected Assistants rows show which corpus each entry reaches, and Connect
  asks which corpus when more than one exists.
- Cross-corpus search over MCP is not offered; an assistant that needs two corpora gets two
  entries.

### Swift app

- `GaragePostgresEndpoint.databaseName` (a constant today) becomes per corpus; `PostgresService`
  learns `createDatabase`/`dropDatabase`/`backup(corpus:)`.
- A library picker in the window toolbar scopes Sources, Models, Documents, Facts, Search and the
  Database page's Contents/Backups rows; Status shows every library. Update Everything and scheduled
  maintenance run over every library, one after the other.
- Ingest, embed and MCP XPC services receive the corpus with each job, not at bootstrap.
- First-run: unchanged (it makes the default library). "New Library…" reuses the same template
  source and model steps.

### Sandbox and App Store

Option B adds no entitlements and no listeners. Folder grants stay per source, so a source's
grant belongs to the corpus that owns it; the same folder in two corpora is allowed but warned
about (it would be read and embedded twice). Tablespaces on external volumes and remote servers
(options D/E) are where sandboxing bites, which is part of why they are deferred.

## Also worth doing, cheaply: saved scopes

Many "separate corpus" wishes are really "search only these sources". A **scope** (a named set
of sources and classes, stored per corpus) filtered at query time gives that without a new
database, and an MCP registration could be bound to a scope. Scopes filter, so they are
convenience, not isolation; the UI should say so. This is option A done honestly, and it can ship
before or alongside B.

## Suggested phases

1. **Groundwork, invisible (1.5.x / `next`)**: the `Corpus` context replacing the singletons, the
   database name read from config, `max_connections` raised at start, `--corpus` on the CLI.
   No UI. This is where the risk is, so it goes first, behind the existing single corpus.
2. **Multiple local libraries (v2)**: config split, corpus RPCs and metadata, per-corpus
   migrations, backup and reset, the toolbar picker, MCP registrations per library.
3. **Cross-library search**: fan-out plus RRF for Ask and multi-library registrations; saved
   scopes.
4. **Portability**: export a library as one file (dump plus a manifest of its models and sources),
   import it as a new library.
5. **Later, if wanted**: tablespaces on external volumes (after a sandbox test), read-only
   attachment of a remote corpus through the egress guard.

## Decided so far (Rick, 2026-09-29)

- Separate corpora on one Mac are wanted alongside multi-Mac sync; a database per corpus (B).
- MCP picks the corpus by `--corpus` for stdio and by URL path for HTTP; one corpus per connection.
- A catalog database tracks the corpora.
- Reset is per corpus or everything.

## Still open

1. Should an off-box (remote) Postgres ever be allowed? If yes, only for corpora with no
   communication sources, through the egress guard.
2. UI word: "Library", "Corpus", or "Workspace"?

## Open questions to test before building

- Does the connection budget already pinch with one database? (`max_connections=5`.)
- Can a sandboxed app's child postmaster use a tablespace in a security-scoped external folder?
- How long does migrating N databases at start-up take on Phobos-class hardware (8 GB)?
- AGE: confirm `create_graph` and `shared_preload_libraries=age` behave per database as expected
  (they should; graphs are per database).

# Multi-master sync with Postgres: state of the art, framed for Garage

Written 2026-09-29. Question: what is the current state of the art for multi-master (active-active)
Postgres, and what would it mean for syncing one Garage corpus across a user's Macs?

> **Superseded for design purposes by `peer-sync-design.md`** (same folder). Rick wants Postgres
> hidden, with peers syncing over Garage's own gRPC, Bonjour discovery and gossip. This file remains
> the survey of Postgres-level options.

## Revised 2026-09-29 for the actual goal

Rick's goal: **each Mac indexes its own files, and every Mac can answer from the whole union as
well as the Mac that indexed them.** That changes the answer. The other Macs cannot re-derive
another Mac's documents (the files aren't there), so derived rows do have to travel. But it also
removes the hard part of multi-master: **every row has exactly one writer, the Mac that indexed
it.** That is not multi-master; it is N single-writer streams, which core Postgres already does
well.

### Recommended shape: one database per Mac, replicated read-only to the others

- Each Mac writes only to its own corpus database, e.g. `garage_mbp`, `garage_mini`. This is
  option B of `multi-corpus/design.md` with "corpus = machine" (and still compatible with
  work/personal corpora: the database is per machine *and* corpus).
- Every other Mac holds a **read-only replica** of that database, fed by **native logical
  replication** (`CREATE PUBLICATION … FOR ALL TABLES` on the owner, `CREATE SUBSCRIPTION` on each
  peer). Single writer per database means no write conflicts, so none of the section-1 conflict
  machinery, Spock or PGD is needed, and `bigserial` ids stay as they are: they never collide
  because two Macs never write the same database.
- Search on any Mac runs the existing hybrid search in its own database and in each replica, then
  fuses with RRF, exactly the cross-corpus fan-out already designed in `multi-corpus/design.md`
  ("Cross-corpus search"). HNSW and FTS indexes are built locally on each replica (logical
  replication ships rows, not indexes), so query quality and speed are the same on every Mac.
- Hits from another Mac carry that Mac's name and path; opening the file works only where it
  exists, but the excerpt, facts and graph answer everywhere, which is what "answer equally well"
  needs.

### What has to be solved for it to answer *equally* well

1. **Same embedding models.** A query vector only matches vectors from the same model. The
   model registry must be the same on every Mac (synced as intent, section 3), and each
   replica's `emb_*` tables must exist before its subscription starts, since core logical
   replication does not replicate DDL. The app would apply `data/sql` plus each registered model's
   DDL to the replica database, then `ALTER SUBSCRIPTION … REFRESH PUBLICATION`. A model added
   later is the same sequence.
2. **Query-time model availability.** Each Mac needs the model loaded to embed the query (already
   true for the local corpus). Distillation (facts) happens only on the owner.
3. **AGE.** The graph lives in AGE's tables and sequences inside the database; since the replica is
   read-only and single-writer, `graphid` collisions don't arise. What needs a test is whether AGE's
   label catalog (`ag_catalog.ag_graph`/`ag_label`) replicates cleanly or must be created on the
   replica first like the `emb_*` DDL. Unverified; flag for a spike.
4. **Duplicates across Macs.** iCloud Messages, Mail and shared iCloud Drive folders mean several
   Macs index the same content. Fusion should dedupe on `content_sha256` (documents) or message
   guid (Messages), otherwise the same hit appears N times and crowds out others. Better: sources
   that exist on every Mac (Messages, iCloud Drive) are indexed by one Mac only, chosen in the
   synced intent layer.
5. **Offline laptops.** A subscription catches up from the publisher's replication slot when the
   peer reconnects; while a peer is away, the owner retains WAL for it. Cap it with
   `max_slot_wal_keep_size` / PG 18 `idle_replication_slot_timeout`; an invalidated slot means a
   fresh `copy_data` resync of that one database, which is acceptable for a cache-like replica.
   Answers from a Mac's replica are as fresh as its last sync; the UI should say "MacBook, synced
   2 h ago".

### Transport (unchanged in principle, sharper in consequence)

Logical replication needs a libpq connection from subscriber to publisher, so this design needs
**Postgres reachable between the user's Macs**, which today it deliberately isn't (0700 Unix socket
only). Options, best first:

| Transport | Notes |
|---|---|
| **Paired-Mac tunnel run by the app** | The app on each Mac exposes the local Postgres socket only through an authenticated, TLS (or Noise) channel between Macs paired once by the user (Network.framework + Bonjour on the LAN; optionally over the user's own Tailscale). Postgres itself still listens only on its Unix socket; the replication role can read only publications. The tunnel is the one new listener and goes into `egress.py`/`INBOUND_OR_LOCAL` as a named, tested destination class ("paired Mac"). |
| **Store-and-forward change files** | When Macs are rarely online together: the owner writes logical change batches (via `pg_logical_slot_get_binary_changes` / `pgoutput`, or simpler, per-document export keyed by `content_sha256`) into a user-chosen synced folder, client-side encrypted; peers apply them. More code, but works through iCloud Drive/Dropbox with no listener at all. |
| Direct libpq over TCP with `sslmode=verify-full` | Simplest to prototype, but opens Postgres on the network; not for shipping. |

**Communications:** replicating a Mac's corpus sends its mail and Messages chunks to the other
Macs. That is the user's own Macs, but it is still "leaving the Mac", so it must be an explicit
per-corpus choice, and the egress content rule needs a new, tested "paired Mac" exception rather
than silently widening "loopback". Publications can exclude `communication` rows with row filters
(`WHERE corpus_class <> 'communication'` on `documents`; chunks/facts/`emb_*` need the class
denormalized or a per-corpus split, since row filters can't join).

### Alternative: federated query instead of replication

Each Mac serves search over the paired channel and the asking Mac fans out live. No replicas, no
DDL sync, always fresh, communications only leave as excerpts for a query. Downside: a Mac that is
asleep or away contributes nothing, so answers are *not* equally good everywhere. Good as a first
step (it reuses gRPC `Search`), and the natural complement: federate when the peer is online,
fall back to the replica when it isn't.

### Bottom line

For "index several Macs, answer equally well from any of them": **database per Mac + native
one-way logical replication to every peer + RRF fan-out**. It uses core Postgres 18/19 only, with
no multi-master product, because nothing is ever written in two places. The real work is the
paired-Mac transport, the DDL/model sync ahead of subscriptions, cross-Mac dedup, and the
communications policy. The rest of this document (written before the goal was clear) still
applies to the small shared intent layer, and explains why true multi-master is unnecessary.

## The short answer (original, before the goal was clarified)

- **Postgres multi-master is real but server-shaped.** The mature options (EDB PGD, pgEdge Spock,
  AWS pgactive) all run asynchronous row-level logical replication between always-reachable nodes,
  resolve conflicts mostly by last-write-wins on commit timestamps, and assume an operator.
  Core Postgres has the building blocks (origin filtering since 16, conflict counters in 18,
  `update_deleted` detection and sequence sync in 19) but still does **no automatic resolution**
  beyond skipping or erroring.
- **For Garage it is the wrong layer.** Almost everything in a corpus is *derived* from files on the
  Mac (documents, chunks, vectors, facts, graph), keyed by `bigserial` ids and local paths.
  Replicating those rows between Macs imports every problem of multi-master (id collisions,
  DDL for `emb_*` tables, HNSW rebuilds, AGE graph ids) for data each Mac could re-derive or
  fetch by content hash.
- **Recommendation:** sync at the application level, not the WAL. Sync the small, user-authored
  state (sources, models, settings, fact prompts) as a change log, and treat expensive derived
  data (embeddings, facts) as a **content-addressed cache** keyed by `content_sha256` + model +
  chunker, which merges without conflicts. Transport is the privacy question, not the database
  one; see "Transport" below.

## 1. What exists today

### Core PostgreSQL (what ships in our bundled 18/19)

| Version | What it added for multi-writer setups |
|---|---|
| 16 | `CREATE SUBSCRIPTION … WITH (origin = none)`: a subscriber asks only for changes that originated locally, which is what stops A→B→A loops and makes two-way native replication possible at all. [Crunchy Data][crunchy-aa16], [Fujitsu][fujitsu-origin] |
| 17 | `pg_createsubscriber`, failover slots (single-writer HA; listed for completeness). |
| 18 | Conflict *detection and counting*: `confl_insert_exists`, `confl_update_origin_differs`, `confl_update_exists`, `confl_update_missing`, `confl_delete_origin_differs`, `confl_delete_missing`, `confl_multiple_unique_conflicts` in `pg_stat_subscription_stats`, plus log lines. [PG 18 docs][pg18-conflicts], [AWS on PG 18][aws-pg18] |
| 19 (beta) | `retain_dead_tuples` / `max_retention_duration` on subscriptions so `update_deleted` (update vs. concurrent delete) can be detected; sequence values can be replicated. [PG 19 release notes][pg19-notes], [PG 19 conflicts][pg19-conflicts] |

What core still does **not** do: resolve conflicts. An `insert_exists` stops the apply worker until
someone intervenes; `update_origin_differs` is applied (effectively last-arriving-wins) and only
logged. A resolution framework (last_update_wins / apply_remote / keep_local per conflict type) has
been proposed on -hackers for several cycles and tracked on the wiki, but is not committed.
[Wiki: Conflict Detection and Resolution][wiki-cdr]. DDL is not replicated either.

So "native bidirectional replication" in 2026 means: two nodes, disjoint write sets or
application-level conflict avoidance, and a human on call for the rest.

### Extensions and products (the actual multi-master options)

| Option | License | Model | Notes |
|---|---|---|---|
| **EDB Postgres Distributed (PGD 6)**, the descendant of 2ndQuadrant BDR | Commercial | Mesh, row-by-row async; optional commit scopes (group commit, CAMO) | Most complete: conflict triggers, column-level resolution, and six built-in **CRDT column types** (counters etc.) that merge instead of picking a winner. [PGD docs][pgd], [PGD CRDTs][pgd-crdt], [PGD conflicts][pgd-conflicts] |
| **pgEdge Spock** | PostgreSQL License since Sept 2025 (was source-available) | Async multi-master logical replication, PG 15–18 | Last-write-wins on commit timestamps, auto DDL replication, "delta apply" columns for counters; companion `snowflake` extension for globally unique ids. [Spock repo][spock], [pgEdge license change][pgedge-oss], [The New Stack][tns-pgedge] |
| **AWS pgactive** | Apache 2.0, open-sourced June 2025 | Async active-active, derived from the open BDR 1/2 code | Last-update-wins / first-update-wins / custom; built for cross-region RDS. [AWS announcement][pgactive-news], [RDS conflict docs][pgactive-conflicts] |
| pglogical 2 | PostgreSQL License | Largely superseded by core logical replication; basic LWW | Mostly maintenance mode; Spock is its active fork. |

Honest framing from the practitioner side: most teams that ask for active-active actually need HA
or read scaling, and the conflict budget is the real cost. [Percona, 2025][percona-aa]

### The local-first / sync-engine world (the other state of the art)

This is where "one person, several devices, sometimes offline" is actually being solved, and it
mostly does *not* replicate Postgres to Postgres:

- **ElectricSQL** (v1 late 2025; joining Databricks, Aug 2026): read-path only, streams "shapes"
  of Postgres to clients; writes go through your own API. [Electric writes guide][electric-writes], [comparison][kanopy-sync]
- **PowerSync**: Postgres server ↔ SQLite on devices, with a client upload queue for writes.
  [PowerSync vs Electric][powersync-vs]
- **CRDT databases**: cr-sqlite (SQLite extension, causal-length sets, true multi-writer merge)
  [cr-sqlite][crsqlite]; Supabase `pg_crdt` (Yjs/Automerge types in Postgres) is explicitly a
  proof of concept, with notes on WAL and dead-tuple cost. [pg_crdt][pgcrdt]
- **Apple's CKSyncEngine** (macOS 14+): the platform's own sync loop over a CloudKit private
  database; the app supplies records and resolves conflicts, CloudKit handles push, retries and
  scheduling. [CKSyncEngine docs][cksync], [WWDC23][wwdc-cksync], [Apple sample][cksync-sample]

The common thread: every one of these has a hub (a server or iCloud) and syncs **application
records**, not physical rows. None of them expects peers to replicate a WAL to each other.

## 2. Why row-level multi-master fits Garage badly

Checked against `data/sql/` on `main`:

1. **Ids collide.** `documents`, `chunks`, `facts`, `authors`, etc. use `bigserial`, and
   `embedding_models` uses `smallserial` (`003_core.sql`, `004_registry.sql`, `006_facts.sql`).
   Two Macs ingesting independently both mint `chunks.id = 1`. Every multi-master product's
   first instruction is to fix this (UUIDs, `snowflake`, node-offset sequences). PG 19 sequence
   sync does not help: it copies a sequence's value, it does not make two writers' ids disjoint.
2. **Rows describe this Mac.** A document's identity is a `source` + URI on a local volume.
   `~/Documents` on the MacBook and on the Mac mini are different files that may or may not be the
   same bytes. Syncing rows would say "this chunk exists" on a Mac that cannot open its file.
3. **Derived data is re-derivable.** Chunks, vectors and facts are functions of
   (`content_sha256`, extractor/chunker version, model). Replicating them row by row means
   replicating the output of a deterministic pipeline, with conflicts on what should be pure
   cache hits.
4. **DDL per model.** Each registered model creates an `emb_<slug>` table with its own HNSW index.
   Core logical replication does not replicate DDL; Spock and PGD do, but schema changes in a
   mesh are the most fragile part of either.
5. **AGE.** Graph vertices/edges carry `graphid`s drawn from per-label sequences. Two writers
   mint the same ids exactly as in (1), and nothing in AGE is multi-master-aware. [Apache AGE][age]
6. **Transport and listeners.** Every Postgres replication option needs one node to open a libpq
   connection to another: a network listener on each Mac (today Postgres listens only on a 0700
   Unix socket), NAT traversal between a user's Macs, and TLS/auth. That contradicts the project's
   "XPC with code-signing checks, no new network listeners" decision and the egress guard, where
   psycopg is allowlisted *as local infrastructure* (`INBOUND_OR_LOCAL`).
7. **Communications rule.** `corpus_class = 'communication'` must never leave the Mac for a
   destination that is not loopback. Row replication would carry mail and Messages chunks to the
   other Mac unless every publication filters them out (row filters exist since PG 15, but one
   missed table leaks).
8. **Operations.** Replication slots retain WAL while a peer is asleep or offline; a laptop closed
   for a week can fill the disk of the Mac that stayed on (PG 18's
   `idle_replication_slot_timeout` caps it by invalidating the slot, which then needs a resync).
   This is the "operator on call" assumption again.

None of this is impossible, but the result would be a distributed database a single user has to
run, to sync data that is mostly a cache.

## 3. What to sync instead: split the corpus by who authored it

| Layer | Examples | Size | Sync approach |
|---|---|---|---|
| **User intent** | sources (as intents, not paths), model registry, settings, fact prompts, MCP registrations, later: pins, tags, saved scopes | KB | Change log of records with stable UUIDs, last-writer-wins per field (or a small CRDT). This is exactly CKSyncEngine's shape. |
| **Expensive derived data** | embeddings (`emb_*`), distilled facts, maybe OCR text | MB–GB | **Content-addressed cache**: key = `content_sha256` + chunker/extractor version + model id (+ prompt sha for facts). Two Macs that ingest the same bytes can share vectors and facts without conflicts, because equal keys mean equal values. Merge is a union. |
| **Cheap derived data** | documents, chunks, FTS, attribution, graph | — | Re-derive locally from files; never sync rows. Local ids stay `bigserial`. |
| **The files themselves** | the user's folders | — | Already synced by iCloud Drive / Dropbox / git for most sources; Garage should not become a file sync tool. |

This design gets most of the value (a new Mac doesn't redo hours of embedding and LLM distillation)
with none of the multi-master machinery, and it composes with the multi-corpus plan: a corpus
(database per corpus, option B in `multi-corpus/design.md`) is the natural unit to opt into sync,
and `pg_dump -d garage_<slug>` stays the one-shot "move this corpus" path.

## 4. Transport options (this is the privacy decision)

| Transport | Fits "nothing leaves the Mac without the user choosing"? | Notes |
|---|---|---|
| **Direct Mac-to-Mac on the LAN** (Network.framework / Bonjour, TLS with keys paired once) | Yes: the user pairs Macs explicitly; can carry communications if the user allows it | New listener, only while pairing/syncing; must go through the egress guard as a named destination class. Only syncs when both are awake on the same network. |
| **iCloud private database via CKSyncEngine** | Only as an explicit per-corpus opt-in; never for communications | Content leaves the Mac for Apple's servers; end-to-end encrypted only with Advanced Data Protection, which Garage can't require or detect reliably, so encrypt payloads client-side with a key in the iCloud Keychain. Works while Macs are never online together. |
| **User-chosen folder** (iCloud Drive, Dropbox, NAS) holding encrypted change-log segments | Same as iCloud: opt-in, client-side encrypted | Simplest to build and inspect; conflict handling is ours; no push notifications. |
| Postgres logical replication between Macs (Spock / pgactive / native) | Only with a new libpq listener and egress-guard changes | See section 2; not recommended. |

A reasonable default: intent layer over CKSyncEngine (tiny, useful even to users who never sync a
corpus); cache layer over LAN pairing first, with an encrypted iCloud option for non-communication
corpora later.

## 5. If Rick does want Postgres-level multi-master anyway

Least-bad path, in order:
1. Move every primary key that crosses Macs to UUIDv7 (`uuidv7()` is built into PG 18) and give
   `embedding_models` a stable key (its slug).
2. Use **Spock** (PostgreSQL License, supports PG 18, DDL replication, LWW) rather than native
   bidirectional subscriptions; it would have to be vendored in `ext/` like pgvector and AGE and
   rebuilt for the PG 19 line.
3. Replicate only intent tables and the embedding/fact caches; exclude `communication` rows with
   publication row filters and test that exclusion in `test_egress_block.py`.
4. Keep AGE out of replication and rebuild the graph locally.

That is essentially section 3 implemented with heavier tools, which is why the recommendation is
to skip straight to section 3.

## Sources

[crunchy-aa16]: https://www.crunchydata.com/blog/active-active-postgres-16
[fujitsu-origin]: https://www.postgresql.fastware.com/blog/bi-directional-replication-using-origin-filtering-in-postgresql
[pg18-conflicts]: https://www.postgresql.org/docs/current/logical-replication-conflicts.html
[aws-pg18]: https://aws.amazon.com/blogs/database/logical-replication-improvements-in-amazon-rds-for-postgresql-18/
[pg19-notes]: https://www.postgresql.org/docs/19/release-19.html
[pg19-conflicts]: https://www.postgresql.org/docs/19/logical-replication-conflicts.html
[wiki-cdr]: https://wiki.postgresql.org/wiki/Conflict_Detection_and_Resolution
[pgd]: https://www.enterprisedb.com/docs/pgd/latest/
[pgd-crdt]: https://www.enterprisedb.com/docs/pgd/latest/conflict-management/crdt/
[pgd-conflicts]: https://www.enterprisedb.com/docs/pgd/latest/conflict-management/
[spock]: https://github.com/pgEdge/spock
[pgedge-oss]: https://www.pgedge.com/blog/pgedge-goes-open-source
[tns-pgedge]: https://thenewstack.io/why-pgedge-ripped-the-band-aid-off-to-go-totally-open-source/
[pgactive-news]: https://aws-news.com/article/2025-06-09-announcing-open-sourcing-pgactive-active-active-replication-extension-for-postgresql
[pgactive-conflicts]: https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Appendix.PostgreSQL.CommonDBATasks.pgactive.handle-conflicts.html
[percona-aa]: https://percona.community/blog/2025/06/18/postgresql-active-active-replication-do-you-really-need-it/
[electric-writes]: https://electric-sql.com/docs/guides/writes
[kanopy-sync]: https://kanopylabs.com/blog/electric-sql-vs-powersync-vs-livestore-local-first
[powersync-vs]: https://powersync.com/blog/electricsql-vs-powersync
[crsqlite]: https://github.com/vlcn-io/cr-sqlite
[pgcrdt]: https://github.com/supabase/pg_crdt
[cksync]: https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5
[wwdc-cksync]: https://developer.apple.com/videos/play/wwdc2023/10188/
[cksync-sample]: https://github.com/apple/sample-cloudkit-sync-engine
[age]: https://github.com/apache/age

- Crunchy Data, "Active Active in Postgres 16": https://www.crunchydata.com/blog/active-active-postgres-16
- Fujitsu, "Bi-directional replication using origin filtering": https://www.postgresql.fastware.com/blog/bi-directional-replication-using-origin-filtering-in-postgresql
- PostgreSQL 18 docs, Logical replication conflicts: https://www.postgresql.org/docs/current/logical-replication-conflicts.html
- AWS, Logical replication improvements in RDS for PostgreSQL 18: https://aws.amazon.com/blogs/database/logical-replication-improvements-in-amazon-rds-for-postgresql-18/
- PostgreSQL 19 release notes: https://www.postgresql.org/docs/19/release-19.html
- PostgreSQL 19 docs, Conflicts: https://www.postgresql.org/docs/19/logical-replication-conflicts.html
- PostgreSQL wiki, Conflict Detection and Resolution: https://wiki.postgresql.org/wiki/Conflict_Detection_and_Resolution
- EDB PGD docs (overview, CRDTs, conflict management): https://www.enterprisedb.com/docs/pgd/latest/
- pgEdge Spock: https://github.com/pgEdge/spock ; license change: https://www.pgedge.com/blog/pgedge-goes-open-source ; The New Stack: https://thenewstack.io/why-pgedge-ripped-the-band-aid-off-to-go-totally-open-source/
- AWS pgactive open-source announcement: https://aws-news.com/article/2025-06-09-announcing-open-sourcing-pgactive-active-active-replication-extension-for-postgresql ; conflict handling: https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Appendix.PostgreSQL.CommonDBATasks.pgactive.handle-conflicts.html
- Percona, "PostgreSQL active-active replication, do you really need it?": https://percona.community/blog/2025/06/18/postgresql-active-active-replication-do-you-really-need-it/
- Electric writes guide: https://electric-sql.com/docs/guides/writes ; PowerSync vs Electric: https://powersync.com/blog/electricsql-vs-powersync ; Kanopy comparison: https://kanopylabs.com/blog/electric-sql-vs-powersync-vs-livestore-local-first
- cr-sqlite: https://github.com/vlcn-io/cr-sqlite ; pg_crdt: https://github.com/supabase/pg_crdt
- Apple CKSyncEngine: https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5 ; WWDC23 "Sync to iCloud with CKSyncEngine": https://developer.apple.com/videos/play/wwdc2023/10188/ ; sample: https://github.com/apple/sample-cloudkit-sync-engine
- Apache AGE: https://github.com/apache/age

Caveats: postgresql.org pages were read through search excerpts (the site was not directly
fetchable from this session); the PG 19 items are from the beta release notes and could change
before 19.0. The resolution-framework status is from the wiki page, not a fresh read of -hackers.

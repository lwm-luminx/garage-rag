# Garage peer sync: several Macs, one answer

Status: design exploration, no code. Written 2026-09-29 against `main`. It builds on
`briefing.md` (same folder) and `multi-corpus/design.md`.

**Goal (Rick):** each Mac indexes its own files, and any Mac can answer from all of them as well as
the Mac that indexed them. Postgres stays hidden: peers talk Garage's own gRPC, found through
Bonjour, with gossip-style propagation. Postgres never listens beyond its 0700 Unix socket.

**Scope (Rick, 2026-09-29): a v2 feature.** It is **opt-in** and off by default, in line with "no new
network listeners by default, remote serving opt-in only". While it is off, nothing listens or
advertises. The overall v2 design lives in `multi-corpus/design.md`. This file covers only the peer
sync protocol.

**Content hashes carry the design (Rick):** documents carry `content_sha256`, so a receiver can
ingest reliably and derive everything else itself. What peers exchange is therefore
**content-addressed**:
- The canonical payload is the owner's extracted text, its metadata and attribution, plus
  `content_sha256` and the extractor `VERSION`. That is everything a Mac needs to rebuild chunks,
  vectors, facts and the graph with its own pipeline.
- **Full derived values ship with every document (Rick, 2026-09-29: don't waste computation).**
  A bundle always carries the chunks, the vectors for every model the owner has, and the facts for
  every prompt the owner ran, each keyed by `(content_sha256, chunker VERSION, model slug +
  model file hash | prompt name + prompt_sha256)`. The receiver stores every part whose key matches
  a model or prompt it has, and derives locally only what no peer has computed: a model or prompt
  the owner lacks, or a chunker version mismatch. Where the keys match, the shipped values are
  exactly what the receiver would compute, so nothing is computed twice anywhere in the mesh.
- Vectors for a model the receiver has not registered are kept, not dropped, when the user has
  that model registered on any Mac. They become usable as soon as the model is registered locally,
  without re-embedding.
- Identical content from two owners (for example the same PDF on two Macs) is derived once. The
  same hashing enforces idempotency: a bundle applied twice is a no-op, which makes gossip's
  duplicate deliveries harmless.

## The short answer

- **Nothing is ever written in two places.** Every document has exactly one **owner**, the Mac that
  indexed it. The others hold a **replica** of it. That removes write conflicts entirely, so no
  multi-master database, CRDTs or last-write-wins are needed for corpus data.
- **The unit of sync is a document bundle**, not a row: the document, its chunks, its vectors per
  model, its facts and its attribution. That is almost exactly today's `PersistDocument` plus
  `UpdateEmbeddings` over the ingest facade, so the receiving side persists through the same
  `SqlAlchemyIngestStorageGateway` the pipeline already uses.
- **Propagation is anti-entropy gossip in the Scuttlebutt style.** Each owner stamps its changes with
  its own increasing sequence number. Peers exchange a digest of "highest sequence I have from each
  owner" and send what the other is missing, including changes they relay for a third Mac. A
  laptop and a desktop never have to be online together. The same shape is used by Syncthing's
  Block Exchange Protocol (index updates by per-device sequence), Cassandra/Dynamo anti-entropy and
  HashiCorp memberlist.
- **Discovery and trust:** Bonjour (`_garage-sync._tcp`) on the LAN, with mutual TLS between Macs
  paired once. The device identity is the certificate's key, which is how Syncthing does it.
  Optionally the user's own Tailscale for off-LAN, never a Garage relay server.
- **Search** fans out over the local database, which now holds every owner's documents, so a
  single hybrid query is enough. Indexes are built locally, so every Mac answers equally well once
  it has caught up.

## 1. Data model changes

| Change | Why |
|---|---|
| In the **catalog database** `garage_catalog` (Rick, 2026-09-29; `multi-corpus/separate-libraries.md`, "The catalog database"): `nodes` (`node_id uuid`, stable per install and derived from the device certificate; name; last seen; the peer's public certificate stored in the row itself, which is what mTLS pins against; only this Mac's private key lives in the Keychain; unpairing deletes the row and revokes the peer) and `corpus_peers` (which corpus is shared with which peer) | Identity of owners and paired Macs spans corpora. The peer service reads each corpus's sharing scope from here |
| In each **corpus database**: `origin_high_water(origin_node, seq)`, maintained from `sync_log` | The per-corpus gossip digest |
| `documents.origin_node uuid NOT NULL DEFAULT <self>`, `documents.origin_uid uuid` (stable id the owner assigns), unique `(origin_node, origin_uid)` | Local `bigserial` ids stay local and never cross the wire; bundles are addressed by `(origin_node, origin_uid)` |
| `sync_log(origin_node, seq, origin_uid, op, content_sha256)` | Each owner appends one entry per document upsert/delete, in the ingest transaction. Replicas copy entries they apply, which lets them relay. Compaction keeps the latest entry per document |
| `sources.origin_node` | Sources belong to the Mac whose folders they are. A replica shows them read-only ("on Mac mini") |
| Tombstones: `op = 'delete'` entries kept until every known peer's digest has passed them | Deletions propagate; a Mac that returns after months still learns them. Beyond a horizon, a stale peer gets a full resync of that owner |

Chunks, facts, `emb_*` rows, authors and fact links hang off `documents` as today, so they follow
the document with no id changes. `ON DELETE CASCADE` already makes a replicated delete remove
vectors in every model table.

## 2. The protocol (a new gRPC service, not `GarageService`)

`GarageService` is the local app-to-backend facade and trusts its token/socket. Peers get a
separate, smaller `GaragePeerService`, served only on the pairing channel:

```proto
service GaragePeerService {
  rpc Hello (HelloRequest) returns (HelloResponse);           // node ids, names, versions, schema + model catalog hashes
  rpc Digest (DigestRequest) returns (DigestResponse);        // map<origin_node, max_seq> I hold
  rpc Pull (PullRequest) returns (stream DocumentBundle);     // "send me origin X after seq N", paged, resumable
  rpc Intent (IntentRequest) returns (stream IntentRecord);   // shared settings/model registry changes (below)
  // Digest also lists trust records by id: vouches and vouch revocations, each signed by the
  // voucher's machine key, gossiped transitively. Fetched with:
  rpc TrustRecords (TrustRecordsRequest) returns (stream SignedTrustRecord);
  rpc Search (PeerSearchRequest) returns (SearchResponse);    // optional live federation (section 5)
}

message DocumentBundle {
  bytes  origin_node = 1;  bytes origin_uid = 2;  uint64 seq = 3;
  string op = 4;                         // upsert | delete
  PersistDocumentRequest document = 5;   // reuse: text, chunks, attribution, corpus_class
  repeated ModelVectors vectors = 6;     // per model slug: chunk ord -> vector
  repeated Fact facts = 7;
}
```

A session between two Macs is pull only, in both directions: each side asks for what its digest
lacks. That keeps flow control with the receiver, which matters for a laptop on battery.
Scuttlebutt's paper covers why ordering by per-origin sequence plus digests converges and how to
bound work per round.

Gossip on a handful of Macs does not need random fan-out or SWIM failure detection. "Sync with every
reachable paired peer when something changes, and every N minutes" is enough. The gossip property
that matters here is **transitive relay**: B passes A's changes to C.

## 3. Answering equally well

1. **Same models everywhere.** A query vector only matches vectors from the same model. The
   embedding model registry and the default model are **intent**, synced over `Intent` and
   applied by the same `RegisterModel` path, so every Mac has the same `emb_*` tables before bundles
   arrive. Bundles carry the vectors for every model the owner has, and the receiver stores them
   when the model slug, model file hash, chunker version and chunk hash all match. Only a model no
   peer has run yet is backfilled locally (backfill already embeds whatever has no vector), and
   that backfill's vectors then flow back out in the next bundle revision, so each chunk is embedded
   once per model across all Macs.
2. **Facts and graph.** Facts ship in the bundle, since distillation is the expensive step. The AGE
   graph is rebuilt locally from facts, so graph ids never cross the wire.
3. **One index, one query.** Because replicas land in the same tables, the existing
   `search/hybrid.py` query covers every Mac's documents with no fan-out and no RRF-of-RRF.
   Results gain an "on MacBook" badge. Opening the file is offered only where it exists.
4. **Duplicates.** iCloud Messages, Mail and shared iCloud Drive folders get indexed on several
   Macs. The intent layer should name **one owner per shared source** (for example "Messages is
   indexed by the Mac mini"). Search also collapses hits with the same `content_sha256` as a backstop.
5. **Freshness is visible.** Each owner's replica shows "synced 2 h ago". A Mac that is behind
   answers from what it has.

## 4. Shared intent (the only part with real conflicts)

Settings that should be the same on every Mac, such as models, fact prompts, identity
(`identity.self_name`) and per-source owner assignments, sync as small records with a hybrid
logical clock and last-writer-wins per key. The volume is tiny, and a conflict here is two edits to
one setting, which LWW handles acceptably. Per-Mac settings (paths, local model hosts, MCP
registrations) are never synced. This belongs in `config/SECTIONS` as a per-key `synced` flag.

## 5. Optional: live federation

`GaragePeerService.Search` lets an asking Mac include peers that are online and ahead of its
replica. The results are fused with RRF, which is rank-based so it copes with differing scores. It
is useful while a new Mac is still catching up. It is not required once replication works.

## 6. Security and privacy

- **Pairing:** defined in `multi-corpus/design.md`, "Pairing and trust" (the per-Mac key, code/QR
  PAKE, the opt-in iCloud Keychain "automatic for my Macs" mode, and the Off / Ask / Automatic
  policy in the catalog). This protocol relies only on its outcome: the peer's certificate in its
  catalog `nodes` row plus this Mac's countersigned trust record. A peer is accepted only if its certificate matches the stored one AND the countersignature verifies against this Mac's own key (mutual TLS, pinned; no CA), so a catalog write alone cannot add trust. Trust follows **vouches** (Rick; see "Pairing and trust"): a vouch means everyone who trusts the vouching Mac ought to trust the new peer. Receivers accept it automatically and record their own countersignature (anchor "vouched by B"), so the handshake rule above never changes. Chains follow, and trust is recomputed as whatever is reachable from direct anchors (code, iCloud Keychain) through the vouches received. A signed vouch revocation, or unpairing the voucher, triggers the recompute and drops the countersignatures that are no longer reachable. The protocol carries vouches and revocations as signed records listed in the digest and gossiped like any other record. Pairing
  grants trust only; what is exchanged is scoped by `corpus_peers`. Bonjour only advertises the service, and an
  unpaired Mac on the LAN learns nothing but that Garage is present.
- **Listener:** the peer service runs on its own port, only while sync is enabled. It is the app's
  second TCP listener after optional MCP HTTP. It must sit behind the pinned-TLS check before any
  handler runs. It never exposes `GarageService` or Postgres.
- **Egress guard:** a paired Mac becomes a new, named destination class in `net/egress.py`. It is
  not "loopback", and it is not a free-form host. `test_egress_block.py` gains a layer asserting
  that only paired certificates are reachable and that sync code builds its channel through the guard.
- **Communications:** these leave the Mac under this design, even though they go only to the
  user's own Macs. That needs an explicit per-source choice ("share Messages with my other Macs"),
  off by default, enforced when bundles are built: a `communication` document is never put in a
  bundle unless its source opted in. The content rule gets a tested "paired Mac, opted in"
  exception rather than a widened loopback rule.
- **Sandbox:** the App Store build needs `com.apple.security.network.server` and `.client` for
  the peer listener and connections. The Bonjour service type goes in `NSBonjourServices`, and there
  is a local network privacy prompt (`NSLocalNetworkUsageDescription`). These add App Review
  surface, so the review notes need a line on them.
- **Transport stack:** gRPC-Swift 2 on Network.framework (NWListener/NWBrowser) in the app. The Python
  backend stays unaware of the network: the Swift peer service calls the local backend over the
  existing socket, `PersistDocument`/`UpdateEmbeddings` for incoming bundles and a new
  `ExportBundles(after_seq)` for outgoing ones. That keeps Python's egress guarantee simple, because
  Python still talks only to local sockets.

## 6a. Corpus-side requirements (from the multi-corpus thread, 2026-09-29)

- **Local-only operations.** Reconcile, SyncSources, RemoveSource, Scan and Reset act only on rows
  where `origin_node = self`. Replicas change only through bundles. Removing a peer ("forget this
  Mac") is a separate operation that drops that origin's documents.
- **Source identity.** Source slugs are unique per `(origin_node, slug)`, not globally. Every API
  that takes a slug (gRPC, CLI, MCP filters) either defaults to the local origin or takes an
  origin as well.
- **Bundle format version and skew.** `Hello` exchanges the bundle format version, the schema
  version and the extractor/chunker `VERSION`s. A receiver accepts formats it knows, and a newer
  sender downgrades to the receiver's format or holds back. A receiver never applies what it cannot
  read, and it resumes from its digest once it is upgraded.
- **Visible embedding gaps.** For each owner and model, show how many chunks have no vector yet
  ("MacBook: 1,204 chunks waiting for bge-m3"), so "answers equally well" can be checked.
- **Connection budget.** The bundled cluster runs `max_connections=5`
  (`PostgresService.swift:419`, checked). Bundle import must share the ingest facade's pool and not
  open connections of its own, or the budget has to grow.
- **Storage growth and a thin mode.** A full replica of every Mac multiplies disk use, since
  vectors dominate. Offer a thin mode per peer: sync only the digest and use live federation
  (section 5), or sync text and facts without vectors.
- **Opening hits from another Mac.** Show the owner and path. Offer "Reveal" only when the same
  `content_sha256` exists locally (for example in a shared iCloud folder). Otherwise show the text
  excerpt, with an option to fetch the full extracted text from the owner.

## 6b. Distributed derivation: volunteer computing across the user's Macs (Rick, 2026-09-29)

Documents that are still waiting for derived data are shipped so that other Macs can compute it,
in the style of SETI@home / Folding@home (BOINC). Ingest (walk, extract, hash) stays with the owner,
because only the owner can read the files. Everything after extraction is a pure function of
`content_sha256` plus a model or prompt, so any Mac can do it.

**Work units.** A unit is `(content_sha256, chunker VERSION, task)`, where the task is one of:
- `embed(model slug, model file hash)`, over a batch of chunks, typically one document's chunks or
  N chunks;
- `distill(prompt name, prompt_sha256, facts model + file hash)`, per document;
- later, `ocr(page)` for image-only PDFs. That would need the image bytes, not just text, so it
  comes later.

The unit carries the extracted text and chunk boundaries, which is everything the task needs. The
result is a derived-value part keyed exactly as in the bundle, so a finished unit just becomes part
of the next bundle revision. No new result format is needed.

**Scheduling: pull, leases, idle only.**
- The owner (or any Mac holding the document) advertises pending units in its digest:
  `pending: {task key -> count}`.
- A volunteer Mac pulls units with `LeaseWork(capabilities, max_units)`. Capabilities cover the
  models and prompts it has, its free memory and whether the facts model is loaded. The volunteer
  gets a lease with a deadline. On expiry, or if the volunteer disappears, the unit returns to the
  pool, so no failure detector is needed. BOINC uses the same lease-and-deadline model.
- A Mac volunteers only when user policy allows it. The defaults: on AC power, user idle, thermal
  state nominal, not in Low Power Mode. It uses ProcessInfo's `thermalState` and
  `isLowPowerModeEnabled` and the IOKit idle time. A Mac mini volunteers freely; a MacBook on
  battery never does. Local ingest always takes priority over volunteer work.
- Placement prefers the Mac that already has the model loaded. Loading a 4 to 8 GB facts model is
  the real cost, so batches are grouped by model and each volunteer drains one model's queue before
  switching. Phobos-sized 8 GB Macs should advertise small models only.
- A unit that is already done anywhere is never issued again: its derived part appears in someone's
  digest, and the `content_sha256` key dedups across owners.

**Result verification.** These are the user's own Macs, so the question is correctness, not
cheating (BOINC's redundancy and quorum exist for untrusted volunteers, and Garage doesn't need
them). But results are not bit-exact across hardware: `known-answers.yaml` already measures Metal
against the CPU reference at about 0.988 cosine, and llama.cpp distillation is not deterministic
either. So:
- Tag every result with the producing node, backend (Metal or CPU) and engine version.
- Treat any matching-key result as valid. The first result wins, and a later duplicate from another
  Mac is discarded, not averaged.
- Occasionally cross-check: the owner recomputes a small random sample and compares with the
  repo's `MIN_COSINE` threshold (0.98). A Mac that fails is marked unhealthy, and its units are
  reissued. This catches a broken model file or engine, which is the realistic failure.

**Privacy.** A work unit is document content leaving the owner, so it follows the same rules as
bundles:
- Units are issued only to paired Macs.
- Units for `communication` documents go only to Macs whose source opted in to sharing
  communications.
- A volunteer keeps no copy of a unit's text beyond the lease, unless it also replicates that
  owner, in which case it already has the bundle.

**Protocol additions** to `GaragePeerService`:

```proto
rpc LeaseWork (LeaseWorkRequest) returns (LeaseWorkResponse);          // capabilities -> units + lease ids/deadlines
rpc SubmitWork (stream WorkResult) returns (SubmitWorkResponse);      // derived parts keyed like bundles
rpc RenewLease (RenewLeaseRequest) returns (RenewLeaseResponse);      // long distillation runs
```

**UI.** The Status page gets a "Helping other Macs" row, for example "Mac mini: embedding 1,204
chunks for MacBook". There is a per-Mac toggle and policy ("only when plugged in and idle"). The
visible embedding gaps in 6a show the queue shrinking.

## 7. Build order

1. Schema: `nodes`, `origin_node`/`origin_uid`, `sync_log`, maintained by ingest. Nothing syncs
   yet. A test covers that re-ingest appends one log entry and that deletes leave a tombstone.
2. `ExportBundles` / import through `PersistDocument` between two databases on one Mac, as a
   `test_postgres.py` case. This proves bundles round-trip and search sees them.
3. Pairing and pinned TLS between two Macs, with `Hello`/`Digest`/`Pull`, LAN only.
4. Intent sync (models, prompts, source owners), then dedup and the "on MacBook" UI.
5. Communications opt-in, the egress guard layer and App Review notes.
6. Distributed derivation (6b): pending units in the digest, `LeaseWork`/`SubmitWork`, idle policy,
   sampled cross-checks.
7. Optional: federation, and Tailscale.

## Sources

- Anderson, "BOINC: A Platform for Volunteer Computing", 2019 (work units, leases/deadlines, redundancy): https://arxiv.org/abs/1903.01699
- BOINC project: https://boinc.berkeley.edu/

- Syncthing Block Exchange Protocol v1 (device IDs from certificates, index updates by sequence): https://docs.syncthing.net/specs/bep-v1.html
- van Renesse et al., "Efficient Reconciliation and Flow Control for Anti-Entropy Protocols" (Scuttlebutt), 2008: https://www.cs.cornell.edu/home/rvr/papers/flowgossip.pdf
- Demers et al., "Epidemic Algorithms for Replicated Database Maintenance", 1987: https://dl.acm.org/doi/10.1145/41840.41841
- DeCandia et al., "Dynamo" (Merkle-tree anti-entropy), 2007: https://www.allthingsdistributed.com/files/amazon-dynamo-sosp2007.pdf
- Das, Gupta, Motivala, "SWIM" membership protocol: https://www.cs.cornell.edu/projects/Quicksilver/public_pdfs/SWIM.pdf
- HashiCorp memberlist (SWIM + gossip in practice): https://github.com/hashicorp/memberlist
- gRPC Swift: https://github.com/grpc/grpc-swift
- Apple Network framework (NWListener, NWBrowser, Bonjour): https://developer.apple.com/documentation/network
- Postgres-level options and why they are not needed: `briefing.md` in this folder

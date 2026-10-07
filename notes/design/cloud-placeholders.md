# Cloud placeholders: tracking, hashing, evicting, and provider APIs

Planning thread, 2026-09-27. **Target: the `next` branch** (the next feature release, v1.5.5),
created 2026-09-27 16:18 from `v1.5-beta` at 4b885a9 (after #143); Rick judged this plan too large
for the beta. Every PR below targets `next`, stacked as the table says. `v1.5-beta` keeps only
fixes; `next` takes `v1.5-beta` merges as the beta moves. The code survey below is of that commit. Builds on the Dropbox
research (`dropbox-online-only/findings.md`), PR #134 (CloudStorage folder fallback) and PR #139
(dataless-file guard), both merged into `v1.5-beta`. Nothing here is implemented yet.

Rick's six asks, in his order, with what exists today, the design, and what each needs.
Legend: **Cloud** a cloud session can do it and CI proves it. **Mac** needs a real placeholder on
a Mac (the M3). **Rick** a decision, a developer-app registration or a signing step.

## Where the code stands

- Detection is right: `extract/placeholder.py` catches the old Dropbox xattr, `SF_DATALESS`
  (File Provider Dropbox, iCloud, OneDrive) and the `.icloud` sidecar; the walker stats every
  file and sets `Candidate.placeholder`.
- Download is metered and guarded: `ingest/materialize.py` has the budget, the daemon-thread
  timeout and, since #139, `setiopolicy_np` OFF on the pipeline thread and ON only on the
  materialize thread, so nothing else can start a download.
- The size and mtime skip already exists for indexed files: `pipeline._stat_matches` compares
  `documents.byte_size` and `mtime`, and a placeholder that was indexed before eviction is skipped
  on mtime alone when it reports no size (step 1 of the idempotency contract).
- **Nothing remembers a placeholder.** Migration 011 retired the `placeholder` document state
  (a stub with no content made a blank document). `record_placeholder` now only writes
  `ingest_seen`, so after a run the only trace is `ingest_runs.placeholder_count`. The Status
  page shows that count and nothing more. That is the gap ask 1 fills, and asks 3 to 5 need it.
- Hashes: `source_sha256` is a plain SHA-256 over the whole file, computed in `file_sha256` after
  materialization. There is no Dropbox-style block hash and no per-provider hash column.
- Providers: `DropboxFolder.swift` locates the Dropbox folder. There is no OneDrive preset or
  folder locator, and `placeholder.py` names OneDrive only in its docstring.

## 1. Track which files were placeholders

**Goal.** Every stub the walker sees is on record, with its provider, its remote size and mtime,
whether Garage downloaded it, and whether Garage has since indexed it. The Documents and Status
pages can then show "in the cloud, not indexed" per source, ask 3 can find what to evict, and
asks 5 and 6 have somewhere to write the provider's own hash.

**Design.** A new table beside `ingest_outcomes`, not a document state (011 was right that a stub
is not a document):

```sql
-- data/sql/014_cloud_items.sql
CREATE TABLE IF NOT EXISTS cloud_items (
    source_id        bigint      NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
    uri              text        NOT NULL,
    provider         text        NOT NULL,          -- 'dropbox' | 'icloud' | 'onedrive' | 'file_provider'
    status           text        NOT NULL,          -- 'dataless' | 'materialized' | 'evicted'
    byte_size        bigint,                        -- the logical size the stub reports
    mtime            timestamptz,
    materialized_by  text,                          -- 'garage' | 'user' | NULL
    materialized_at  timestamptz,
    evicted_at       timestamptz,
    provider_hash    bytea,                         -- Dropbox content_hash / OneDrive quickXorHash, when known
    provider_rev     text,                          -- Dropbox rev / OneDrive eTag, when known
    recorded_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (source_id, uri),
    CONSTRAINT cloud_items_status_check CHECK (status IN ('dataless', 'materialized', 'evicted'))
);
```

- `record_placeholder` (all three gateways: SQLAlchemy, gRPC client, gRPC server) upserts a
  `dataless` row with the stub's size and mtime. `materialize()` success flips it to
  `materialized` with `materialized_by = 'garage'`. A file the walker finds local whose row says
  `dataless` was fetched by the user (or by Dropbox's own sync): `materialized_by = 'user'`. A
  file that comes back dataless after being `materialized` goes back to `dataless` (the provider
  evicted it; Garage keeps the document, as today).
- The provider comes from `provider_from_xattrs` plus the folder: a dataless file under
  `~/Library/CloudStorage/Dropbox*` is Dropbox, `OneDrive*` is OneDrive, `~/Library/Mobile
  Documents` is iCloud. Add `provider_for(path)` to `placeholder.py`; today an SF_DATALESS file
  with no telling xattr is reported as "File Provider".
- Reconcile: a row whose uri is absent from the latest completed run is deleted with the document.
- Surface it: `ingest_runs` keeps its counters; the gRPC `Stats`/`ListDocuments` grow a
  per-source "in cloud" count, and the Sources page row reads "1,204 files in the cloud, 310
  downloaded and indexed". No new page.
- Config: none new.

**Needs.** Cloud (schema, gateways, proto, tests on mocks and `test_postgres.py`), then a Mac to
confirm the provider names on real stubs. One PR, against `next`. Everything below depends on it.

## 2. The Dropbox content hash and an overall content-hashing scheme

**Goal.** Garage can compare what it holds with what the provider says is in the cloud without
downloading anything, and its own idempotency hash stops being coupled to one algorithm.

**Dropbox's algorithm** (documented at dropbox.com/developers/reference/content-hash): split the
file into 4 MiB blocks, SHA-256 each block, concatenate the 32-byte digests in order, SHA-256 the
concatenation; hex of that is `content_hash`. It streams, so it costs one pass, the same as
`file_sha256` today.

**OneDrive** (Microsoft Graph `driveItem.file.hashes`): `quickXorHash` on every item (personal
and business), `sha1Hash` and `crc32Hash` on personal only, `sha256Hash` on personal only and
not always present. QuickXorHash is a documented 160-bit shift-and-xor over the bytes plus the
length; ~40 lines of Python, also one streaming pass.

**Scheme.**
- `extract/hashes.py`: one streaming reader that feeds every registered digest at once
  (`sha256`, `dropbox`, `quickxor`), so a file is read once whatever set is wanted.
  `file_sha256` becomes a thin call into it. Pure Python, testable against the published test
  vectors (Dropbox publishes the hash of its milky-way test image; Microsoft publishes none, so
  the test uses a known-good value from the rclone implementation, which is widely cross-checked).
- `source_sha256` stays SHA-256 over raw bytes: it is the idempotency key for every source, cloud
  or not, and changing it would re-extract every corpus. The provider hash goes in
  `cloud_items.provider_hash`, computed in the same pass when the file is in a cloud folder.
- A `hash_algorithm` column is not needed: the provider fixes the algorithm, and `provider`
  is already on the row.
- CLI: `garage hash PATH [--algorithm dropbox|quickxor|sha256]` for checking by hand.

**Needs.** Cloud only. One PR stacked on ask 1. Small.

## 3. Revert to placeholders once hashed and indexed

**Goal.** After Garage downloads a stub, hashes it, extracts and chunks it, the bytes can go back
to the cloud, so indexing an online-only folder does not fill the disk. Only files Garage itself
materialized are evicted; a file the user downloaded is theirs.

**Mechanism.** `FileManager.evictUbiquitousItem(at:)` is what Finder's "Remove Download" calls.
It is documented for iCloud, routed through fileproviderd, and reported to work for replicated
third-party providers on macOS 12.3+. Unverified for Dropbox and OneDrive: **the M3 check comes
first** (B3 in the backlog). The Python side cannot call it (Foundation, not libc), so:

- The ingest worker returns the list of uris it materialized in the run report (it already
  returns `materialized_count`; add the uris, from the new table).
- `IngestService` (Swift) evicts each one after the run, inside the security-scoped access it
  already holds, and calls a new `MarkEvicted` RPC (or `RecordCloudItems`) so the row reads
  `evicted`. A failed eviction leaves the row `materialized`; the next run tries again.
- The document keeps its chunks and embeddings; step 1 of the pipeline already skips an evicted
  file whose mtime matches, and with ask 1 the row's stored size makes the File Provider case
  exact as well (both size and mtime compare, not mtime alone).
- Setting: per source, `sources[].evict_after_index` (bool, default false, in `SECTIONS` and the
  schema; decided by Rick 2026-09-27), shown as "Return downloaded files to the cloud after
  indexing" on the source, Dropbox and OneDrive presets only. Docs: `docs/privacy.md` gets a line (the bytes were on disk while Garage
  read them, and go when it is done).
- Fallback if eviction does not work for Dropbox: none from our side (there is no API), so the
  setting stays hidden for providers where the M3 check fails, and the plan notes it.

**Overall disk cap (Rick, 2026-09-27 16:16).** Besides the per-run budget (`placeholders.max_bytes`,
which bounds one run's downloads), one global setting bounds how much disk Garage's downloads
may occupy at any time: `placeholders.disk_cap_bytes` (default 20 GiB, 0 = no cap), "Keep at
most N GB of downloaded cloud files on disk" on the Sources page next to the presets.
- What counts: the sum of `byte_size` over `cloud_items` rows in status `materialized` with
  `materialized_by = 'garage'`, across every source. Files the user downloaded never count and
  are never evicted.
- Before each download, `materialize()` checks `bytes_on_disk + size <= cap`. When it would not
  fit: sources with `evict_after_index` on give up their oldest indexed, Garage-materialized
  files first (a `ReclaimCloudSpace` call the ingest worker makes to the app, which evicts and
  marks the rows), then the download proceeds; when nothing can be reclaimed, the file is
  deferred as the budget defers today, and the run report says "N files deferred: disk cap".
- With `evict_after_index` on for a source, its files are evicted at the end of the run anyway;
  the cap matters within a run (a slice larger than the cap) and for sources where eviction is
  off, which then simply stop downloading at the cap.
- The Status page shows the figure: "3.2 GB of 20 GB used by downloaded cloud files".

**Needs.** Mac first (a 20-line Swift test program on the M3 against one dataless Dropbox file and
one OneDrive file: download by read, evict, stat shows SF_DATALESS again), then Cloud for the
Python and Swift, then Mac to confirm end to end. Stacked on ask 1.

## 4. Size and time markers in the scan

**Goal.** The scan and the ingest use what the stub's stat already says, so an unchanged cloud
file is never opened, and a changed one is recognised before download.

**What already holds.** Under File Provider a stub reports its real size and the server's
`client_modified` as mtime, and `_stat_matches` compares both against the document row. That is
the heuristic Rick describes, for files Garage has indexed.

**What to add.**
- With ask 1, compare against `cloud_items` too: a stub whose size and mtime match its row is
  "seen, unchanged, still in the cloud" and costs one stat, no xattr call and no DB write beyond
  `ingest_seen`. A stub whose size or mtime moved is a candidate for the next budget slice, and
  its row is updated so the Sources page count of "changed in the cloud" is honest.
- The scan (`scanner.scan_filesystem`) counts dataless files separately (`scan_details` already
  holds a per-kind breakdown), so before any ingest the Sources page says "12,400 files, 9,100 of
  them in the cloud (48 GB)". The size sum is free: the stub reports it.
- Budget ordering: spend the budget on the smallest changed files first (or newest first, a
  setting), instead of directory order, so a run converges on the most documents per byte.
- `URLResourceKey.generationIdentifierKey` is meant to change with content and may track remote
  updates; it is a Foundation key, so a Mac check tells whether it beats mtime. Not needed for
  the first cut.
- Old-client Dropbox stubs (zero bytes with the xattr) stay on mtime only, as today.

**Needs.** Cloud, stacked on ask 1. Small. The mtime granularity check (Dropbox sets mtime to
the second) is already handled by the 1 s tolerance in `_stat_matches`.

## 5. Dropbox API to compare on-disk contents

**Goal.** Ask Dropbox, not the disk, what is in the folder: `content_hash`, `rev`, `size` and
`server_modified` for every file with no download, and a `list_folder/continue` cursor that
returns only what changed since the last run. Garage can then (a) confirm an indexed file's
bytes still match the cloud, (b) find changed files without walking, and (c) know the hash of a
stub it has never downloaded.

**Framing (Rick, 2026-09-27 16:15).** Dropbox already has every path, name, size and hash in this
list: the File Provider extension on the Mac gets them from the same API to draw the folder. The
metadata call sends Dropbox nothing it does not already hold, and content never travels. Garage
uses it for one purpose: to track what changed in the cloud without downloading anything, so the
corpus stays current without taking more disk space. It is optional: off by default, on per
source after the user connects the account, and every other feature in this plan works without
it. The setting, the source page, `docs/privacy.md` and the App Review notes say exactly that.

**What it costs** (from the earlier findings, still true):
- A Dropbox developer app (Rick registers it; "scoped access", permission `files.metadata.read`
  only for this ask; `files.content.read` only if streaming reads are ever wanted). Production
  access is capped at 50 users until Dropbox approves the app, which is fine for a beta.
- OAuth 2 PKCE in the app (`ASWebAuthenticationSession`), refresh token stored as a
  generic-password item in the App Group keychain beside the Postgres password. Python gets a
  short-lived access token from the app per run, never the refresh token.
- Egress: `api.dropboxapi.com` becomes an allowed origin in `egress.check_destination` only while
  `sources[].cloud_tracking` is on for a source, with `purpose="cloud_metadata"`, and `CALLERS`
  in `test_egress_block.py` learns the one new caller (`net/cloud/dropbox.py`). The guard's
  client for this purpose is metadata-only by construction: it is built without a content route
  (`files/download` is not on its allowlist, and a test proves the client refuses it), so the
  privacy property "content never leaves the machine" stays enforced by code, not by policy.
  `docs/privacy.md` gets a "Cloud change tracking (optional)" section with the framing above,
  and the content rule keeps `corpus_class = 'communication'` paths out of the calls too.
- Path mapping: the local folder root maps to the account root for a personal account; team
  spaces need the `Dropbox-API-Path-Root` header. `info.json` (already read by
  `DropboxFolder.swift`) says which the folder is.

**Design.**
- `net/dropbox.py`: `list_folder` (recursive, with cursor persistence in `sources.scan_details`),
  `get_metadata`. httpx via `egress.http_client`. No SDK.
- The comparison step, `garage cloud compare SLUG` and a `CompareCloud` RPC: for each entry,
  upsert `cloud_items.provider_hash`/`provider_rev`; for each indexed document, compute the
  Dropbox hash of the local bytes only when the row has none (ask 2 stores it at index time
  going forward) and report matches, mismatches (the cloud moved on; the local copy is stale or
  the file is dataless and the stub's mtime lied) and cloud-only files.
- Ingest then uses the cursor: when a source has a Dropbox cursor, the run walks the delta, not
  the tree. The full walk stays as the fallback and the periodic reconcile.
- UI: a "Connect Dropbox" button on the Dropbox source, showing the account and a "Compare" action
  with the three counts.

**Needs.** Rick gave the go on 2026-09-27 with the framing above. Still from Rick: the Dropbox
developer app (scoped, `files.metadata.read`). Then Cloud for the client, comparison and egress
test, Mac for the OAuth flow. Stacked on asks 1 and 2. The biggest item.

## 6. The same for OneDrive

**On disk.** OneDrive on macOS has been a File Provider extension since 2022: the folder is
`~/Library/CloudStorage/OneDrive-Personal` or `OneDrive-<TenantName>` (one per account),
`~/OneDrive` is a link on migrated Macs, and online-only files are dataless with the real size,
exactly as Dropbox. So detection already works, and the gaps are:
- `OneDriveFolder.swift` beside `DropboxFolder.swift`: enumerate `~/Library/CloudStorage/OneDrive-*`
  and offer one preset per account ("OneDrive (Personal)", "OneDrive (Contoso)"). No `info.json`
  equivalent; the folder names are the account labels.
- `provider_for(path)` in ask 1 names it `onedrive`.
- Materialize, guard, evict (ask 3) and stat heuristics (ask 4) are provider-neutral and need
  only the M3 check on a OneDrive stub.

**API.** Microsoft Graph: `GET /me/drive/root/delta` gives every item with `file.hashes`
(`quickXorHash` always; `sha1Hash`/`sha256Hash` personal only), `eTag`, `size`,
`lastModifiedDateTime`, and a `@odata.deltaLink` that plays the role of Dropbox's cursor. Needs an
Entra app registration (Rick), MSAL-style OAuth PKCE (same `ASWebAuthenticationSession` code as
ask 5, different endpoints), scope `Files.Read`, and `graph.microsoft.com` plus
`login.microsoftonline.com` as allowed origins under the same gate. Path mapping is simpler than
Dropbox: item paths are relative to the drive root, which is the CloudStorage folder.

**Design.** Make ask 5's client a `CloudProvider` protocol (`list_changes(cursor)`,
`metadata(path)`, `hash_algorithm`) with `dropbox.py` and `onedrive.py` implementations, and one
comparison step over it. Ask 2's `quickxor` digest is the local side.

**Needs.** Cloud for the folder locator and preset (small, can go now, stacked on nothing), Mac
for a OneDrive stub check, Rick for the Entra registration before the API half.

## Order and PRs

| # | PR | Base | Needs first |
|---|---|---|---|
| 1 | `cloud_items` table, gateways, provider naming, Sources page count | next | nothing; start now |
| 2 | `extract/hashes.py` (sha256, dropbox, quickxor), stored at index time, `garage hash` | PR 1 | nothing |
| 6a | OneDrive folder locator and presets | next | nothing |
| 4 | stat heuristic against `cloud_items`, scan counts cloud files and bytes, budget ordering | PR 1 | nothing |
| 3 | evict after index per source, overall disk cap (Swift + `MarkEvicted`/`ReclaimCloudSpace` + settings) | PR 1 | **M3 check** that `evictUbiquitousItem` works on Dropbox and OneDrive stubs |
| 5 | Dropbox metadata client, compare, cursor ingest, connect UI | PRs 1, 2 | **Rick**: Dropbox developer app (go given 2026-09-27) |
| 6b | OneDrive client over the same protocol | PR 5 | **Rick**: Entra app registration |

PRs 1, 2, 6a and 4 are cloud work with no blocker. PR 3 waits on one M3 experiment (half an hour
with a dataless file). PRs 5 and 6b wait on Rick for the developer app registrations; the privacy call is made (opt-in, metadata only).

## Open questions for Rick

1. Answered 2026-09-27 16:15: go. The provider APIs expose the same data the File Provider
   extension already fetches; Garage uses them only to track changes without taking more disk
   space, and the feature is optional. Section 5 carries that framing.
2. Answered 2026-09-27 16:16: per source, plus an overall disk cap on materialized files (section 3).
3. Budget ordering (ask 4): smallest first, newest first, or directory order as today?

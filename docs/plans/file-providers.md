# File providers: Dropbox and Google Drive by API, with versions and change feeds

Plan written against `main` on 2026-10-04 (after #240). Nothing here is in the code yet.

## Why

Today a cloud folder reaches Garage only through its sync client's mirror on disk. The Dropbox
preset is `kind: filesystem` on `~/Dropbox` or `~/Library/CloudStorage/Dropbox`
(`macapp/Sources/GarageApp/Services/DropboxFolder.swift`); Google Drive is whatever Drive for
desktop mirrors. That mirror is the only view the pipeline has, and it limits us four ways:

| Limit | Where it bites |
|---|---|
| **Change detection is the stat.** `ingest_one` skips on `mtime`+`byte_size`, then on `source_sha256` after reading the file (`ingest/pipeline.py`). A full walk of the tree is needed to learn that anything changed. | A 200k-file Dropbox is re-walked every maintenance run to find a dozen edits. |
| **Deletion needs a complete walk.** `reconcile` trusts only an `ingest_runs.completed` run and refuses above 25% (`ingest/reconcile.py`). | A run cut short by the materialization budget or a cancel never reconciles. |
| **Online-only files cost a download of the whole file through the kernel.** `materialize.py` meters it, and the dataless I/O policy keeps other reads from starting one, but the provider decides what is local. | A Dropbox "online-only" tree converges over many runs; Drive for desktop streams everything through its own cache. |
| **No history.** A document is its current bytes; a rename is a delete plus an add (`documents.uri` is the path); who edited a shared file is unknown. | Attribution of shared folders falls to the source default. Nothing can answer "what did this say before". |

Both providers expose exactly what the mirror hides: stable item ids, a cursor-based change feed,
a server-side content hash, and a revision list with who changed what and when. This plan adds
connections to those APIs behind one **file provider contract**, keeps the local filesystem as
the first implementation of that same contract, and leaves room for OneDrive, a FSEvents-driven
local feed, and others.

Out of scope here: writing to a provider (the connectors are read-only), Dropbox team spaces and
Drive shared drives beyond listing them (noted where they matter), and iCloud Drive (no public
API; it stays on the disk provider).

---

## 1. The contract

The contract is a *tree of items with identity, revisions and a change feed*. It is written once
as a Python ABC in `garage_rag/providers/base.py` and mirrored one-to-one as a gRPC service in
`proto/garage_provider.proto`, so an implementation can live in-process or in another process
(§4). The pipeline programs against the ABC only.

### 1.1 Types

```python
class Capability(Flag):
    CHANGE_FEED   = auto()   # changes_since(cursor) works
    REVISIONS     = auto()   # list_revisions / open works for past revisions
    STABLE_IDS    = auto()   # item_id survives rename and move
    CONTENT_HASH  = auto()   # Fingerprint on every file item, without opening it
    EXPORT        = auto()   # some items have no bytes until exported (Google Docs, Paper)
    LONGPOLL      = auto()   # wait_for_changes(cursor, timeout) works

@dataclass(frozen=True)
class Fingerprint:
    kind: str     # "sha256" | "dropbox_content_hash" | "md5" | "gdrive_version"
    value: str

@dataclass(frozen=True)
class Item:
    item_id: str                  # provider's stable id; for the disk provider the path itself
    path: PurePosixPath           # display path relative to the source root, with an extension
    is_folder: bool
    size: int | None              # None when unknown (an unexported Google Doc)
    modified_at: datetime | None
    revision: str | None          # provider's head revision id ("rev" / headRevisionId)
    fingerprint: Fingerprint | None
    mime: str | None              # the provider's mime, e.g. application/vnd.google-apps.document
    placeholder: bool = False     # disk provider only: dataless / online-only stub
    modified_by: Identity | None = None   # who made the head revision, when the provider says

@dataclass(frozen=True)
class Revision:
    revision: str
    modified_at: datetime
    modified_by: Identity | None
    size: int | None
    fingerprint: Fingerprint | None

class ChangeKind(Enum): ADDED = ...; MODIFIED = ...; DELETED = ...; MOVED = ...

@dataclass(frozen=True)
class Change:
    kind: ChangeKind
    item: Item | None             # None for DELETED when the provider gives only the id
    item_id: str
    previous_path: PurePosixPath | None   # MOVED

@dataclass(frozen=True)
class ChangePage:
    changes: list[Change]
    cursor: str                   # to persist *after* every change in the page is applied
    has_more: bool
    reset: bool = False           # provider says the cursor is invalid: do a full list
```

### 1.2 Operations

```python
class FileProvider(ABC):
    kind: ClassVar[str]                      # "filesystem" | "dropbox" | "gdrive" | ...
    def capabilities(self) -> Capability: ...
    def probe(self) -> None: ...             # raises SourceUnavailable with the remedy (today's root_problem)

    # enumeration
    def list_all(self) -> Iterator[Item]: ...                       # full crawl, folders included
    def changes_since(self, cursor: str | None) -> Iterator[ChangePage]: ...   # None: start a cursor at "now"
    def wait_for_changes(self, cursor: str, timeout: float) -> bool: ...        # LONGPOLL only

    # content
    def open(self, item: Item, *, revision: str | None = None, budget: TransferBudget) -> LocalFile: ...
    # LocalFile is a context manager yielding a Path: the item's own path for the disk provider, a
    # spooled download (or export) under <data dir>/spool/ otherwise, removed on exit.

    # history
    def list_revisions(self, item: Item, *, limit: int) -> list[Revision]: ...
```

Rules every implementation must keep, enforced by a conformance test (§6):

1. **Enumeration never opens content.** `list_all` and `changes_since` are metadata only. The
   walker's "stat, don't open" discipline becomes the contract's.
2. **Cursors are at-least-once.** A page replayed after a crash must produce the same end state;
   the pipeline persists the cursor only after the page's changes are committed.
3. **`open` goes through the budget.** `TransferBudget` is today's `MaterializationBudget`
   (files, bytes, timeout per run) renamed and given to every provider, so a first crawl of a
   large Drive converges over runs exactly as placeholder materialization does.
4. **Read-only.** No operation takes corpus content as an argument. What leaves the machine is a
   credential, a cursor, item ids and paths. The egress test checks this (§5).
5. **Degrade by capability.** Without `CHANGE_FEED` the pipeline falls back to `list_all` every
   run (today's behaviour). Without `CONTENT_HASH` it compares `modified_at`/`size`, then
   `source_sha256` after download. Without `STABLE_IDS` a move is a delete plus an add.

### 1.3 How the pipeline uses it

`ingest_one` keeps its five steps; what changes is where "unchanged" comes from:

| Step | Today (`pipeline.py`) | With a provider |
|---|---|---|
| 1 skip without opening | `mtime`+`byte_size` match an OK row | `revision` matches `provider_items.revision`, or `fingerprint` matches; else `modified_at`/`size` |
| materialize | `ensure_local` on a placeholder | `provider.open(item, budget=…)` for every non-local item; the disk provider still routes placeholders through the dataless-policy thread |
| 2 skip on bytes | `source_sha256` | unchanged, computed on the spooled file |
| 3–5 | extract, hash text, chunk, replace | unchanged |

Three new pieces around it:

- **`provider_items`** (§2) maps `(source_id, item_id)` to the document, current path, revision
  and fingerprint. A `MOVED` change rewrites `documents.uri` and the path in place, so chunks
  and vectors survive a rename. A `DELETED` change tombstones the item and deletes the document
  (through the same guard as reconcile: a page that would delete more than 25% of a source is
  refused and reported, since an account unlink or a folder moved out of scope looks like one).
- **An incremental run** (`changes_since`) records only the items it touched in `ingest_seen`
  and never sets `ingest_runs.completed`, so `reconcile` keeps its meaning (a full crawl). The
  run row gains `mode = 'full' | 'incremental'` and the cursor range it applied.
- **Scheduling.** `scan` for a provider source that has a cursor is `changes_since` with no
  content: it reports the count of pending changes, which the Sources page shows as "12 changes
  since Tuesday" instead of a recount of the tree. Without a cursor it is `list_all`.

Google Docs, Sheets and Slides (and Dropbox Paper) have no bytes until exported. The provider
reports `EXPORT`, gives the item a synthesized extension (`.md` for Docs via Drive's
`text/markdown` export, `.csv` per sheet or `.xlsx` for Sheets, `.pptx` for Slides, `.md` for
Paper) so `extract/dispatch.py` and `classify` work unchanged, and `open` performs the export.
`documents.mime` keeps the provider's mime; `meta.export_format` records what was fetched. They
have no size or checksum, so step 1 runs on `revision` alone (`headRevisionId` changes on every
edit) and `source_sha256` is over the export.

### 1.4 Versions

"Handle versions" means three different things, taken in this order:

1. **Detect change by revision id, not bytes** (§1.3). This is where most of the value is and it
   costs one metadata call per change.
2. **A revision ledger.** `document_revisions` (§2) keeps every revision the provider lists for an
   indexed item: id, time, who, size, fingerprint, and whether its text is indexed. Fetched when
   an item is first indexed and extended on each `MODIFIED` change (`list_revisions` with the
   stored head as a floor). It gives:
   - an **attribution signal**. `attribute/` gains `provider_history.py` between git and embedded
     metadata: the modifying identities over the ledger, with the owner's account as self. Same
     shape as `git.py` (evidence string, confidence from share of revisions).
   - the Documents view a history list, and MCP a `rag_document_history` tool (metadata only).
   - Dropbox keeps 30 days of revisions on Basic/Plus and 180 days to a year on Professional and
     Business; Drive keeps revisions until it prunes them (and keeps every Docs revision). The
     ledger is what survives when the provider forgets.
3. **Indexing superseded text**, behind `sources[].history: none | ledger | index` (default
   `ledger`) with `history_limit` (default 5 revisions, 0 = all the provider has). An indexed
   past revision is a document of its own with `uri = <item uri>@<revision>`,
   `documents.superseded_by` pointing at the current one, chunks embedded like any other. Search
   excludes superseded documents unless the request asks (`include_history`), and
   `document_revisions.indexed` tells the ledger which ones are there. It multiplies embedding
   cost by up to `history_limit`, which is why it is off until a user turns it on per source.
   Replacing the head keeps the old head's text only when `history = index`; `ledger` drops it as
   today.

The disk provider has no revisions. A `git` source does: its commits are revisions of each path,
and `git log --follow` gives the ledger for free. That is a later milestone (§7) but the contract
fits it without change, which is the test of the contract.

---

## 2. Schema (`data/sql/015_file_providers.sql`)

Idempotent, like the rest of `data/sql`. Starts at 015 since 014 is taken.

```sql
ALTER TABLE sources DROP CONSTRAINT IF EXISTS sources_kind_check;
ALTER TABLE sources ADD CONSTRAINT sources_kind_check
    CHECK (kind IN ('filesystem','git','sqlite','maildir','feed','dropbox','gdrive'));
-- The provider account a remote source reads through, and its change-feed position.
ALTER TABLE sources ADD COLUMN IF NOT EXISTS account_id    bigint REFERENCES provider_accounts(id) ON DELETE RESTRICT;
ALTER TABLE sources ADD COLUMN IF NOT EXISTS sync_cursor   text;
ALTER TABLE sources ADD COLUMN IF NOT EXISTS cursor_at     timestamptz;

-- One row per connected account. Never holds a token: `credential_ref` names the Keychain item
-- (macOS) or the 0600 file (elsewhere) that does. Removing an account with sources is refused.
CREATE TABLE IF NOT EXISTS provider_accounts (
    id              bigserial PRIMARY KEY,
    provider        text NOT NULL,              -- 'dropbox' | 'gdrive'
    account_uid     text NOT NULL,              -- provider's account id
    display_name    text,
    email           text,
    credential_ref  text NOT NULL,
    scopes          text[] NOT NULL DEFAULT '{}',
    connected_at    timestamptz NOT NULL DEFAULT now(),
    last_ok_at      timestamptz,
    last_error      text,
    UNIQUE (provider, account_uid)
);

-- Every item a provider source knows, folders included (Drive needs the folder graph to decide
-- whether a changed file is still under the source root). `document_id` is null for folders,
-- for files that made no document, and for tombstones.
CREATE TABLE IF NOT EXISTS provider_items (
    source_id     bigint NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
    item_id       text   NOT NULL,
    document_id   bigint REFERENCES documents(id) ON DELETE SET NULL,
    parent_id     text,
    path          text   NOT NULL,              -- root-relative display path
    is_folder     boolean NOT NULL DEFAULT false,
    revision      text,
    fingerprint_kind text,
    fingerprint   text,
    size          bigint,
    modified_at   timestamptz,
    mime          text,
    deleted_at    timestamptz,                  -- tombstone; the row goes on the next full crawl
    seen_at       timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (source_id, item_id)
);
CREATE INDEX IF NOT EXISTS provider_items_document ON provider_items (document_id);
CREATE INDEX IF NOT EXISTS provider_items_parent   ON provider_items (source_id, parent_id);

-- The revision ledger (§1.4). `indexed` marks a revision whose text is a document of its own.
CREATE TABLE IF NOT EXISTS document_revisions (
    document_id   bigint NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    revision      text   NOT NULL,
    modified_at   timestamptz,
    modified_by   text,                         -- display name or email the provider gave
    modified_by_author_id bigint REFERENCES authors(id) ON DELETE SET NULL,
    size          bigint,
    fingerprint_kind text,
    fingerprint   text,
    indexed       boolean NOT NULL DEFAULT false,
    PRIMARY KEY (document_id, revision)
);

ALTER TABLE documents ADD COLUMN IF NOT EXISTS superseded_by bigint REFERENCES documents(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS documents_current ON documents (source_id) WHERE superseded_by IS NULL;

ALTER TABLE ingest_runs ADD COLUMN IF NOT EXISTS mode         text NOT NULL DEFAULT 'full';
ALTER TABLE ingest_runs ADD COLUMN IF NOT EXISTS cursor_from  text;
ALTER TABLE ingest_runs ADD COLUMN IF NOT EXISTS cursor_to    text;
```

`documents.uri` for a provider source is id-based and stable: `dropbox://<account_uid>/<item_id>`
and `gdrive://<account_uid>/<item_id>`. Paths are not unique in Drive (two files of the same
name in one folder are legal) and change on rename in both; the display path lives in
`provider_items.path` and `meta.path`, which the Documents view and `pathrules` read. The disk
provider keeps `uri = <absolute path>`, so nothing existing is rewritten.

`author_identities.kind` gains `'dropbox_account'` and `'google_account'` so the ledger's
`modified_by` resolves to authors the way git emails do. `db/models.py` mirrors all of this;
`docs/schema.md` gets a section.

---

## 3. The two providers

Both are hand-written over REST with the egress guard's `httpx` client. The official SDKs are
out: `dropbox` depends on `requests`, and `google-api-python-client` brings `httplib2`,
`google-auth` and `requests`, all of which `test_egress_block.py` forbids outside `net/egress.py`.
The read-only subsets we need are small (eight Dropbox endpoints, six Drive ones), and owning the
client is what lets the egress rules apply to it.

### 3.1 Dropbox (`providers/dropbox.py`)

- **Auth.** OAuth 2 with PKCE (`token_access_type=offline`), no client secret, so the app key
  can ship in the binary. Scopes `files.metadata.read`, `files.content.read`,
  `account_info.read`. Refresh tokens do not expire or rotate; access tokens last 4 hours and the
  provider refreshes them itself. A Dropbox app serves 50 users before it needs "Production"
  approval, which is a form, not a security audit.
- **Enumeration.** `files/list_folder` (`recursive=true`, `include_deleted=false`,
  `include_non_downloadable_files=true` for Paper) and `list_folder/continue` on the cursor the
  first call returns, 2,000 entries a page. The same cursor is the change feed:
  `list_folder/continue` after a full crawl yields only what changed, with `deleted` entries
  (by path, so `provider_items.path` resolves the id). A `reset` error means a full crawl.
  `list_folder/get_latest_cursor` starts a cursor at "now" for a source whose first crawl ran
  through the disk mirror.
- **Identity and hashes.** `id:…` is stable across move and rename; `rev` changes per edit;
  `content_hash` is the Dropbox block hash (SHA-256 of the concatenated SHA-256s of 4 MiB
  blocks), which we implement in `providers/dropbox_hash.py` (30 lines) to verify downloads and
  to compare a mirrored file against the API without downloading it.
- **Content.** `files/download` on `content.dropboxapi.com` (`Dropbox-API-Arg` header), streamed
  to the spool; `files/export` for Paper and other non-downloadable types.
- **Revisions.** `files/list_revisions` (`mode: id`, up to 100); for files in shared folders each
  entry's `sharing_info.modified_by` (an account id, resolved by `users/get_account_batch` once per
  unknown id) feeds the ledger. Files in a private folder have only the owner as editor.
- **Longpoll.** `list_folder/longpoll` on `notify.dropboxapi.com`, 30–480 s, no auth. Used only
  by the app's maintenance loop when the user opts into "watch for changes" (§7).
- **Limits.** 429 with `Retry-After` and `too_many_write_operations`-style `error_summary`
  strings; the transport honours `Retry-After` and backs off. Team spaces need the
  `Dropbox-API-Path-Root` header; the first version lists the member folder only and says so.
- **Mirror handoff.** A `filesystem` source rooted on the Dropbox mirror can be *upgraded* to a
  `dropbox` source: the migration matches each document's mirror-relative path to a
  `files/list_folder` entry's `path_display`, confirms it by `client_modified` against the stored
  `mtime` (and by block hash where the mirrored file is materialized), sets `provider_items`,
  rewrites `uri`, and keeps every chunk and vector. Unmatched documents are left for the first
  API crawl to replace. Default-excluded prefixes (`pathrules.EXCLUDED_PREFIXES`) apply to the API
  path the same way.

### 3.2 Google Drive (`providers/gdrive.py`)

- **Auth.** OAuth 2 with PKCE for a "Desktop app" client, loopback redirect. Scope
  `drive.readonly` (metadata, content, revisions and export). Two facts shape the plan:
  - `drive.readonly` is a **restricted scope**. Publishing an OAuth client that requests it needs
    Google's app verification and, past 100 users, an annual CASA security assessment. An
    unverified client in "Testing" caps at 100 test users and its refresh tokens expire after
    seven days, which is unusable for a maintenance loop.
  - `drive.file` (non-sensitive, per-file through the Picker) cannot crawl a folder.
  
  So the first version takes a **user-supplied OAuth client** (`providers.gdrive.client_id`,
  `client_secret` in the credential store; Google requires the secret even for desktop clients,
  and treats it as non-confidential for them), created by the user in their own Cloud project
  with the consent screen set to *External, In production* and themselves as the only user.
  That path has no verification step, shows the "unverified app" interstitial once, and the
  refresh token does not expire. The Sources page walks through it. Shipping a Garage-owned
  client is a product decision for later; the code is the same.
- **Enumeration.** Initial crawl: `files.list` with `q = '<folder> in parents and trashed = false'`,
  `fields = files(id,name,mimeType,parents,size,md5Checksum,sha256Checksum,headRevisionId,
  modifiedTime,version,lastModifyingUser(displayName,emailAddress,me),shortcutDetails)`, 1,000 a
  page, breadth-first over folders; shortcuts are followed once by target id and never recursed.
  Change feed: `changes.getStartPageToken` at the end of the crawl, then `changes.list`
  (`includeRemoved=true`, `restrictToMyDrive=false`, `includeItemsFromAllDrives` only when a
  shared drive is configured, `spaces=drive`) and `newStartPageToken`. The feed is **drive-wide,
  not folder-scoped**: every change is checked against the folder graph in `provider_items`
  (walk `parents` up to the source root; a parent not yet known is fetched with `files.get`),
  which is why folders are items. A file whose parents no longer reach the root is a `DELETED`
  for this source; one that newly does is `ADDED`; a changed `name` or `parents` with the same id
  is `MOVED`. A 404/410 on the page token means a full crawl.
- **Identity and hashes.** Ids are stable across move and rename. Binary files carry
  `md5Checksum` and (since 2023) `sha256Checksum`; the latter is the fingerprint, and it equals
  our `source_sha256`, so an unchanged file is known without a download. Google-native files have
  neither: `headRevisionId` is the fingerprint.
- **Content.** `files.get?alt=media` streamed to the spool, with `Range` resume on a stalled
  download; `files.export` for native types (`text/markdown` for Docs, `text/csv` per sheet or
  `application/vnd.openxmlformats-officedocument.spreadsheetml.sheet` for Sheets,
  `application/vnd.openxmlformats-officedocument.presentationml.presentation` for Slides, both of
  which `extract/office.py` already reads). Export is capped at 10 MB by Google; a larger Doc is
  recorded in `ingest_outcomes` as `failed` with that reason.
- **Revisions.** `revisions.list` with `fields = revisions(id,modifiedTime,lastModifyingUser,
  size,md5Checksum)`; `revisions.get?alt=media` for a past binary revision, and
  `revisions.get` export links for native ones (history indexing of Docs uses the `exportLinks`
  of each revision).
- **Limits.** 403 `userRateLimitExceeded` / 429 with exponential backoff; the default quotas
  (thousands of queries a minute) are far above a maintenance run. `files.list` has no
  recursive mode, so the first crawl is one call per folder; a 50k-file Drive with 3k folders is
  about 3k calls, a few minutes.
- **Push.** `changes.watch` needs a public HTTPS endpoint, so there is no longpoll; the loop polls
  `changes.list` (cheap: an empty page costs one call).

### 3.3 Shared behaviour (`providers/transport.py`, `providers/oauth.py`, `providers/credentials.py`)

- **Transport** wraps `egress.http_client(purpose="provider:<kind>", base_url=…)` per origin (the
  guard pins each client to one origin, so a provider with three hosts holds three clients),
  JSON helpers, streaming download to the spool with the budget's timeout, `Retry-After` and
  backoff, and the "2xx with an `error` body" rule from `inference/transport.py`.
- **OAuth** runs the PKCE flow with a loopback redirect listener (inbound, 127.0.0.1, random
  port, single request, 120 s) and the system browser. On macOS the app uses
  `ASWebAuthenticationSession` in Swift instead (§7) and hands the resulting tokens to Python.
- **Credentials.** A `CredentialStore` protocol with three implementations: `keychain` (the app:
  Swift reads the item and passes it in `IngestOptions`, as `lmstudio_api_token` is today, so
  Python never touches the Keychain), `file` (`<data dir>/credentials/<ref>.json`, 0600, for the
  venv, Linux and Windows), `env` (`GARAGE_PROVIDER_CREDENTIAL_<REF>` for CI). Tokens are
  memory-only in Python, never logged, never in `garage.json`. A rotated refresh token (Google
  may rotate) is reported back on the progress channel so the app can store it.

---

## 4. Where the providers run: Python in-process versus a gRPC provider service

The contract can be satisfied two ways. Both were weighed against the code as it is.

### Option A: Python modules in the ingest process

Providers are `FileProvider` subclasses in `garage_rag/providers/`, chosen by `sources.kind`,
running wherever the pipeline runs: the ingest XPC service (in the app's own process in the
App Store build, out of process in Developer ID), the `garage` launcher, a venv, Linux, Windows.

| For | Against |
|---|---|
| The pipeline, walker, materialize budget and extractors are Python and take a `Path`; a spooled download is the smallest change. | Every ingest process holds the provider tokens for the run (in memory; the LM Studio token already travels this way). |
| One language, one test suite, mocks over `httpx.MockTransport` through the guard. | A long first crawl keeps a token alive in a process that also parses untrusted PDFs. (It parses them today with the database URL in hand, so this is not a new class of exposure.) |
| Outbound traffic stays under the AST-scanned choke point in `net/egress.py`; the privacy tests extend to the providers with two lines in `CALLERS`. | |
| CLI, venv, Linux and Windows get the providers with no daemon to run. | |
| No new entitlement: the sandboxed app, the ingest service and GarageXPCService all carry `com.apple.security.network.client` already. | |

### Option B: a separate gRPC provider service

A `FileProvider` gRPC service (`proto/garage_provider.proto`, the §1 operations as RPCs with
`Open` server-streaming bytes or returning a spool path in the group container) hosted by a new
`GarageProviderXPCService` on macOS, or a `garage-providers` process elsewhere. The pipeline
talks to it through `GrpcFileProvider`, a client that implements the same ABC.

| For | Against |
|---|---|
| Credentials and the network live in one process; the pipeline sees items and bytes, never a token. Matches the repo's one-concern-per-XPC-service pattern. | A second process to start, supervise and hand sockets to, plus a `*Client` module, in every deployment, or an in-process fallback for the venv, Linux and Windows, which is Option A again. |
| A provider can be written in Swift when the platform API is Swift-only: Apple's File Provider framework for iCloud, `NSFileProviderManager` signals for the local feed. | Content crosses a process boundary: either streamed over gRPC (the facade already allows 256 MiB messages, but a 2 GB video wants streaming) or spooled to the group container and passed by path. |
| Third-party providers without touching `garage_rag`. | The Python egress test cannot see a Swift provider; its "one choke point" becomes "one choke point per language", and the Swift side needs its own host-pinning test. |
| | Latency per `check`/`open` is a gRPC round trip; fine for ingest, which is I/O bound anyway. |

### Decision: A first, built so B is a client of the same contract

Ship Dropbox and Google Drive as Python providers (Option A). Define the gRPC service alongside
the ABC from the start, generate the stubs, and keep `GrpcFileProvider` as a thin client that
passes the §6 conformance suite against an in-process Python server of the proto. That is the
`IngestStorageGateway` pattern already in the repo: one ABC, `SqlAlchemy…` and `Grpc…`
implementations, the pipeline indifferent. Option B's host (`GarageProviderXPCService`) is then a
milestone that can be taken when a provider needs Swift (iCloud, FSEvents) or when credential
isolation is wanted, without changing the pipeline or the Python providers, which would simply
move behind the server.

What makes A acceptable now is that it does not widen the trust model: the sandboxed app already
runs ingest in-process with network access, and the ingest service already receives a
third-party token (LM Studio) for the run. What makes B worth defining now rather than later is
that the contract gets exercised by two implementations from day one, which is what keeps it a
contract.

---

## 5. Privacy

The guarantee today is "content goes only to loopback or the configured model servers, and
communications never leave the machine". Providers add outbound traffic of a new kind, so it is
written down as a rule and tested, not slipped under the old one.

- **Fixed origins, not a setting.** `egress.PROVIDER_ORIGINS` is a frozen table:
  `dropbox` → `api.dropboxapi.com`, `content.dropboxapi.com`, `notify.dropboxapi.com`;
  `gdrive` → `www.googleapis.com`, `oauth2.googleapis.com`, `accounts.google.com` (the
  authorization page only, opened in the browser, never by the client). `check_destination`
  approves them for `purpose="provider:<kind>"` and for no other purpose, so an embedding client
  can never be pointed at `googleapis.com`. There is still no free-form hosts setting.
- **Read-only, by construction.** The provider transport has no method that takes a body built
  from anything but typed arguments (ids, paths, cursors, revision ids, OAuth parameters). The
  AST test gains a rule: modules under `providers/` may import nothing from `extract/`, `ingest/`
  (beyond the budget type), `search/`, `enrich/` or `db/models` document types, so corpus content
  cannot reach a request. `CALLERS` gains `providers/transport.py: egress.http_client` and
  `providers/oauth.py: egress.http_client`.
- **Content rule unchanged.** A provider source's documents are `document` or `code` by default;
  a user can mark one `communication` and the existing rule (never off-box for embedding or
  facts) applies as it does to mail. Nothing in this plan sends content to a provider.
- **What a provider learns.** That Garage read these paths at these times, through this OAuth
  client. Google's consent screen shows the scope and the client; Dropbox's shows the app. Both
  are documented in `docs/privacy.md` under a new "Layer 6: provider connectors are read-only
  and pinned", and the "Cloud placeholders and network traffic" section says the API path is an
  alternative to the mirror, not an addition to it.
- **Credentials.** Never in `garage.json`, never in the database (`credential_ref` only), never
  in logs (the transport redacts `Authorization` and `refresh_token` in every debug line), in
  the App Group Keychain on macOS (same access group as the Postgres password, so the launchers
  read them without a prompt).

---

## 6. Testing

- **Conformance suite** (`tests/providers/conformance.py`), parametrized over every
  `FileProvider`: enumeration never calls `open` (a spy on the transport); a replayed page is
  idempotent; `MOVED` keeps the document id; a `DELETED` page over the threshold is refused; the
  budget stops `open`; capabilities declared match behaviour exercised. It runs against:
  - the disk provider over a tmp tree (today's walker tests, re-pointed);
  - Dropbox and Drive over recorded fixtures (`tests/fixtures/providers/*.json`) served by an
    `httpx.MockTransport` that the guard's `http_client` accepts through a test-only hook, as the
    inference tests do; the fixtures are scrubbed captures from a throwaway account on each
    service;
  - `GrpcFileProvider` in front of a Python server of the proto wrapping each of the above.
- **Pipeline golden test**: the disk provider through the new `Item`/`open` path produces the
  same `documents` and `chunks` rows as `main` on the existing ingest fixtures, so the refactor is
  behaviour-free (same spirit as `test_chunking_golden.py`).
- **Egress**: the new `test_egress_block.py` rules in §5, plus a test that
  `check_destination("https://www.googleapis.com", purpose="embedding")` raises.
- **Postgres** (`test_postgres.py`): 015 applied and re-applied; the `superseded_by` and
  `provider_items` cascades; the current-documents partial index used by search.
- **Dropbox block hash**: known-answer test against the values Dropbox publishes.
- **Swift**: unit tests for the Sources page presentation of remote kinds and the connect flow's
  state machine (`SourcesPresentation` pattern); a UI test under `GarageApp_uitest` with a mock
  provider server is a stretch goal.
- **Live smoke** (manual, documented in `docs/contributing.md`): `garage provider connect dropbox`,
  `garage add-source … --kind dropbox`, `garage ingest`, edit a file in the web UI, `garage ingest`
  again and see one `MODIFIED` applied.

---

## 7. Milestones

Each lands on its own, behind the previous one. Sizes are relative.

| # | Milestone | Contents | Size |
|---|---|---|---|
| 0 | **Contract and disk provider** | `providers/base.py`, `providers/local.py` (walker + scanner + materialize behind the ABC), `TransferBudget`, `Item` replacing `Candidate` in `pipeline.py`, golden test, `proto/garage_provider.proto` + `GrpcFileProvider` + conformance suite. No user-visible change. | M |
| 1 | **Schema and incremental runs** | `015_file_providers.sql`, `db/models.py`, `provider_items` upkeep in the gateway (both implementations) and the facade RPCs (`UpsertProviderItems`, `ApplyChanges`, `GetCursor`/`SetCursor`, `RecordRevisions`), `ingest_runs.mode`, the deletion guard on change pages, `docs/schema.md`. | M |
| 2 | **Dropbox** | `providers/dropbox.py`, block hash, transport, OAuth PKCE + `CredentialStore` (`file`, `env`), `garage provider connect|list|disconnect`, `add-source --kind dropbox`, egress table and tests, mirror-to-API upgrade, `docs/privacy.md` layer 6. | L |
| 3 | **Google Drive** | `providers/gdrive.py`, folder graph, exports, BYO OAuth client with the guided setup, fixtures, docs page for creating the Cloud project. | L |
| 4 | **macOS app** | Sources page: "Connect Dropbox / Google Drive" with `ASWebAuthenticationSession`, Keychain store (`GaragePostgresEndpoint` pattern, App Group access group), folder picker over the provider's `list_all` of folders, tokens passed in `IngestOptions` and rotated ones stored from progress; `RegisteredSource` stops assuming `root` is a path (`testVolumeAccess`, `expandedRootURL`, `SourcesPresentation` icons); `runPipeline` unchanged (scan of a cursor source is the change count); optional "watch for changes" using Dropbox longpoll between maintenance runs. | L |
| 5 | **Revision ledger and attribution** | `document_revisions` fill, `attribute/provider_history.py`, Documents view history list, `rag_document_history` MCP tool. | M |
| 6 | **History indexing** | `sources[].history = index`, `superseded_by`, search filter, backfill unchanged. | M |
| 7 | **Later, on the same contract** | `git` revisions from `git log --follow`; a FSEvents change feed for the disk provider (`CHANGE_FEED` without a network); OneDrive (`/delta`, same shape as Drive's feed); `GarageProviderXPCService` when iCloud or credential isolation calls for it. | — |

Milestones 0 and 1 are the ones to review hardest: they touch `pipeline.py`, the gateway and the
proto, and everything after them is additive.

---

## 8. Configuration

`SECTIONS` gains `providers`, and `SourceSpec` three fields. Regenerate the schema
(`garage config schema --publish`) and document every field.

```jsonc
{
  "providers": {
    "dropbox": { "app_key": "…" },                       // default baked in; override for a custom app
    "gdrive":  { "client_id": "…" },                      // user-supplied (§3.2); the secret goes to the credential store
    "spool_dir": "",                                      // default <data dir>/spool
    "history_default": "ledger"                           // none | ledger | index
  },
  "sources": [
    { "slug": "dropbox", "kind": "dropbox", "account": "dbid:AAB…", "root": "/Documents",
      "history": "ledger", "history_limit": 5 },
    { "slug": "drive", "kind": "gdrive", "account": "103…", "root": "1AbC…",   // folder id, or "root"
      "class": "document", "trust": "reference" }
  ]
}
```

`root` stays the field name so `sync` and the app's config loader keep working; for a provider
kind it is a provider path or id, and `account` names the `provider_accounts.account_uid`. The
transfer budget settings (`materialize.*`) are renamed `transfer.*` with the old names in
`RETIRED_KEYS` as aliases that still load.

---

## 9. Open questions

1. **Ship a Garage OAuth client for Drive, or BYO only?** BYO avoids verification and the CASA
   assessment but is a ten-step setup for the user. Decide after milestone 3 has been used.
2. **Spool location in the sandbox.** `<data dir>/spool` is in the App Group container, which the
   in-process ingest can write; a spooled file is deleted after extraction, but a crash leaves
   plaintext on disk until the next run's sweep. Encrypting the spool is possible but the
   extractors need a path. Accept the sweep, or extract from memory for small files.
3. **Deletion threshold for change pages.** 25% of a source per page matches reconcile; a user
   who really deleted a folder must run `garage reconcile --force` as today. Is a per-run total
   better than per-page?
4. **Should the disk provider learn the API?** For a Dropbox mirror, `content_hash` from the
   API answers "did this placeholder change" without materializing it. Cheap once milestone 2
   exists; it makes the mirror source a hybrid, which complicates the model. Leaning no: upgrade
   the source instead.
5. **Communications on providers.** Mail exported to Drive is plausible; the class rule holds,
   but the connector still *downloads* it over the network from Google, which it already holds.
   Worth a sentence in `docs/privacy.md`, not a rule.

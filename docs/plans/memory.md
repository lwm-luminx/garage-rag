# Memory: text an agent stores, embedded and searched like everything else

Design for the first write path into the corpus. An MCP client stores a piece of text; Garage keeps
it, embeds it, returns it from `rag_search` beside file and message hits, and lets the client edit,
delete and list what it stored. Memory files that assistants already keep on disk (`CLAUDE.md`,
`AGENTS.md`, Cursor rules, ...) are ingested as memories too, from memory sources rooted on a
folder. This is the narrow slice of §3 "Generic memory" in [v1.5.md](v1.5.md): the storage model is
the one that plan settled on, and nothing here closes off its later layers (evidence, importance,
forgetting, dreaming). Those stay out of this design.

Written against `main` on 2026-10-04; the schema runs to `014_chunk_direction.sql`.

## Goals

- **Store** any number of memories: free text over MCP, with an optional title and tags.
- **N memory sources.** `memory` is a source kind. A memory source rooted on `memory://` is a
  store that only the write tools fill; one rooted on a folder ingests the memory files it finds
  there. Database setup creates one store, `default`, and new memories go there unless the caller
  names another.
- **Embed** every memory under every registered model so hybrid search finds it; a memory stored
  this second is findable this second, not after the next maintenance run.
- **Search**: no new search path. `rag_search` returns memories with its other hits, and
  `source="default"` (or any memory source's slug) restricts a search to them.
- **Edit** and **delete** a memory by id. An edit keeps the id; a delete removes the text, its chunks
  and every vector of it.
- **List** memories, newest first, with paging, a tag filter and a source filter.
- Keep every privacy layer intact. Nothing new leaves the machine; a memory classified as a
  communication is held back from an off-box provider exactly as a message is.

Not in scope: evidence links, importance, recall ranking, forgetting, consolidation, `rag_store`
for long verbatim documents, and memories written by anything but an MCP client, the CLI, the app
or a memory file. Each is designed in v1.5.md §3 and fits on top of this without a schema change to
what is here.

## The model: a memory is a document in a memory source

A memory is a `documents` row in a source of `kind = 'memory'`, with its text in `documents.content`
and its chunks in `chunks`. That buys, with no new code:

- embeddings: the backfill anti-join (`embed/ollama.py:pending_chunks_sql`) embeds any chunk under
  every model, and `GetEmbeddingBatches` does the same for the app's embed worker;
- search: both engines in `search/hybrid.py` join `chunks → documents → sources`, so a memory is a
  hit with a `document_id`, `chunk_id`, class, trust and authors, and every existing filter applies;
- deletion: `ON DELETE CASCADE` from `documents` through `chunks` into every `emb_*` table, plus
  `facts` and `document_authors`;
- idempotent edits: `replace_document` upserts on `(source_id, uri)` and keeps every chunk whose
  text is unchanged, so an edit re-embeds only what changed;
- reading: `rag_get_document(document_id)` and the app's Documents page work on it unchanged.

Beside the document, a thin `memories` row carries what is memory-specific and queryable: the id
the MCP tools hand out, tags, who wrote it, and when it changed. The text is **not** duplicated
there; `documents.content` is the one copy, so the two cannot drift. Which memory source a memory
belongs to is the document's `source_id`; the `memories` row does not repeat it.

### Memory sources: stores and folders

`sources.kind` gets a sixth value, `memory`. Two shapes, told apart by `root`:

| Shape | `root` | Filled by | Ingest |
|---|---|---|---|
| **store** | the literal `memory://` | `rag_remember`, `garage memory add`, the app | never walked, scanned or reconciled |
| **folder** | a directory, like any filesystem source | the memory files under it | walked like a filesystem source, keeping only memory files |

The migration creates one store, slug `default`, and it is where every memory lands when the
caller names no source. More stores are allowed (`garage add-source --kind memory notes memory://`),
for a client that wants its own, or to keep work and personal memories apart. Folder sources are
declared like any other source, in `garage.json` or with `add-source`:

```json
{ "slug": "claude-memory", "kind": "memory", "root": "~/.claude", "trust": "authored" }
```

Everything that enumerates sources learns the kind:

| Where | Today | Change |
|---|---|---|
| `_ingest_source` in `ingest/pipeline.py` and `IngestStorageGateway.list_enabled_sources` | every enabled source is scanned, then walked (or `ingest_messages_source` for `sqlite`) | a store is skipped (`ingest default` by name is a `ValueError`); a folder goes through `ingest_memory_folder` (below) |
| `scan_source` in `ingest/scanner.py` | counts files under `root` | a store counts nothing and `expected_elements` stays 0; a folder counts the memory files it would ingest |
| `ops.sources.sync_sources` | reports every database-only source as `undeclared` | a store is not undeclared; a folder is declared like any source |
| `ops.sources.add_source` | `root` must exist | `kind="memory"` accepts the literal `memory://` as a root; a folder root must exist as before |
| `ops.sources.remove_source` | deletes the source and cascades its documents | `default` is refused with `PermissionError` (gRPC `PERMISSION_DENIED`): the way to empty it is to forget each memory. Any other memory source is removable, memories and all |
| `reconcile_source` | refuses without a completed run | a store never has one: refuse with a clear message. A folder reconciles as any source |
| `SourceSpec.kind` in `config/__init__.py` | `filesystem \| git \| sqlite \| maildir \| feed` | `memory` added; `root` may be `memory://`. `default` itself is never in the file (it comes from the migration), but declaring it there with the same root is harmless and merely re-syncs it |
| `data/models/`-style presets, `SourcePresets.swift` | folder presets | a "Claude memory" preset for `~/.claude` and an "Agent instructions" one for `~/.codex`, `~/.cursor` |

The Sources page and `rag_list_sources` show memory sources as any other, with document and chunk
counts: how many memories each holds. Every memory write resolves its source by slug and checks
`kind = 'memory'` and `root = 'memory://'`, so an older database with a filesystem source that
happens to be named `default` gets a clear error, and a write aimed at a folder source is refused
(its files are the truth; see below).

### Schema: `015_memory.sql`

```sql
-- Memory sources (kind 'memory'): a store, rooted on the literal 'memory://', that the write
-- tools fill, or a folder of memory files (CLAUDE.md, AGENTS.md, ...). A memory is a documents
-- row in one of them; this table carries what is memory-specific and queryable. The text lives
-- on the document. Database setup creates the 'default' store, where new memories land unless
-- the caller names another.
-- Idempotent: safe to re-run.

ALTER TABLE sources DROP CONSTRAINT IF EXISTS sources_kind_check;
ALTER TABLE sources ADD CONSTRAINT sources_kind_check
    CHECK (kind IN ('filesystem', 'git', 'sqlite', 'maildir', 'feed', 'memory'));

INSERT INTO sources (slug, kind, root, default_class, default_trust)
    VALUES ('default', 'memory', 'memory://', 'document', 'authored')
    ON CONFLICT (slug) DO NOTHING;

CREATE TABLE IF NOT EXISTS memories (
    id          bigserial   PRIMARY KEY,
    document_id bigint      NOT NULL UNIQUE REFERENCES documents(id) ON DELETE CASCADE,
    origin      text        NOT NULL DEFAULT '',   -- MCP client name, 'cli', 'app', or 'file'
    tags        text[]      NOT NULL DEFAULT '{}',
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS memories_tags    ON memories USING gin (tags);
CREATE INDEX IF NOT EXISTS memories_updated ON memories (updated_at DESC);
```

`db/models.py` mirrors it: a `Memory` model, `'memory'` added to the duplicated
`sources_kind_check`, and a `Document.memory` one-to-one relationship. The DROP/ADD of the CHECK is
the idempotent form for a changed constraint; a `DO $$ ... duplicate_object` guard would leave the
old five-value constraint in place. The `INSERT ... ON CONFLICT (slug) DO NOTHING` is what creates
`default` on database setup and on every later re-apply (the app re-applies the migrations at each
start, so an upgraded install gets it too); a Reset Database recreates it with the schema.

What the document row holds for a stored memory:

| Column | Value |
|---|---|
| `uri` | `memory://<uuid4>`, minted at creation and never changed. Unique within the source, stable across edits, and `_tidy` in the MCP server leaves it alone (it only rewrites a home-folder prefix) |
| `title` | the optional title |
| `content` | the text, byte for byte as given, so an edit round-trips |
| `corpus_class` | `document` (default) or `communication`; see privacy |
| `trust_tier` | `authored` by default (the owner said or decided this), `reference` on request |
| `extractor` / `extractor_version` | `memory` / `1` |
| `chunker` | `memory:v1:<first chunk's chunker>`, the signature `pipeline._chunker_signature` would give |
| `source_sha256` | `NULL`, as for a Messages thread: there are no raw bytes |
| `content_sha256` | sha256 of the text; same-text re-stores into the same source dedupe on it |
| `byte_size` / `mtime` | UTF-8 length; `mtime` is the memory's `updated_at`, so Documents sorts it sensibly |
| `meta` | `{"origin": ..., "tags": [...]}` as a copy for the Documents detail view; `memories` is the queryable truth |
| authors | the owner (`ensure_self_author`) with role `author` for `authored`; none for `reference` |

Chunking: `chunk_text(text, ContentKind.MARKDOWN)` with the configured prose sizes, so a note with
headings splits at them and a long one at paragraphs. The title goes into each chunk's
`heading_path` (shown as `section` on a hit), not into the chunk text, so `content` stays verbatim.
Most memories are one chunk. Stored text is bounded at `MEMORY_MAX_CHARS = 16_000` (a `ValueError`
beyond it): a memory is a thing to remember, and `rag_store` in v1.5 §3 is the door for long
verbatim documents. A memory file is not bounded this way; it gets the ordinary
`max_chunks_per_document` cap like any file.

### Memory files: folder sources

Assistants already keep memory on disk, in files with well-known names. A memory source rooted on
a folder ingests those files, and only those, as memories:

| File | Kept by | Tag |
|---|---|---|
| `CLAUDE.md`, `CLAUDE.local.md`, `.claude/**/*.md` (`memory/`, `rules/`, `agents/`, `skills/`) | Claude Code | `claude` |
| `AGENTS.md` | Codex and others | `agents` |
| `GEMINI.md` | Gemini CLI | `gemini` |
| `.cursorrules`, `.cursor/rules/*.mdc` | Cursor | `cursor` |
| `.windsurfrules`, `.windsurf/rules/*.md` | Windsurf | `windsurf` |
| `.github/copilot-instructions.md`, `.github/instructions/*.instructions.md` | Copilot | `copilot` |
| `MEMORY.md`, `NOTES.md`, `memory/*.md` | people | `notes` |

The table lives in `ingest/memory_files.py`, data-driven like `attribute/pathrules.py`, and a
source may narrow or extend it with `config.patterns` (globs relative to the root). The matching
walk is `iter_memory_files(root, patterns)`: `os.walk` with the walker's dependency and
`.git` pruning reused, but **hidden directories kept**, because `.claude/`, `.cursor/` and
`.github/` are where these files live and the ordinary walker prunes them. Cloud placeholders go
through `materialize` as for any file.

Each file becomes a document through the ordinary pipeline step for a candidate (`extract`
Markdown, quality gate, `replace_document`), so stat skips, hashes, chunk reuse and
`ingest_outcomes` all apply, and `ingest_memory_folder` then upserts the `memories` row:
`origin = 'file'`, `tags` = the matched rule's tag plus the source's `config.tags`, and the
document's `title` = the file's first `#` heading, else its path relative to the root. The uri is
the file's path, as for any file, so `rag_get_document(location=...)` reads it and Reconcile removes
the memory when the file goes.

A file-backed memory is **read-only to the write tools**. `rag_update_memory` and `rag_forget`
on one raise `ValueError("this memory is the file ~/.claude/CLAUDE.md; edit the file and re-ingest
the source")`, and `MemoryInfo.editable` is false, so a client knows before it tries. The file is
the truth; the database mirrors it. Writing an assistant's edit back into `CLAUDE.md` is listed
under decisions.

## Write path (`ops/memory.py`)

One module, five functions, in the ops shape the CLI and the gRPC servicer both present:

```python
DEFAULT_MEMORY_SOURCE = "default"

@dataclass
class MemoryRecord:
    memory_id: int
    document_id: int
    source: str              # the memory source's slug
    uri: str                 # memory://<uuid> for a stored memory, the path for a file
    editable: bool           # False for a file-backed memory
    title: str | None
    text: str
    tags: list[str]
    origin: str
    corpus_class: str
    trust_tier: str
    created_at: datetime
    updated_at: datetime
    chunks: int
    embedded: list[str]      # model slugs embedded in this call
    pending: list[str]       # model slugs left for backfill, with why in `notes`
    notes: list[str]

def remember(text, *, source=DEFAULT_MEMORY_SOURCE, title=None, tags=(), corpus_class="document",
             trust="authored", origin="") -> MemoryRecord
def update_memory(memory_id, *, text=None, title=None, tags=None) -> MemoryRecord
def forget(memory_id) -> ForgetResult            # memory_id, document_id, chunks_deleted
def list_memories(*, source=None, limit=20, offset=0, tag=None, query=None) -> MemoryPage   # total, memories
def get_memory(memory_id) -> MemoryRecord
```

`remember` and `update_memory` share one store step:

1. Resolve the source by slug and check it is a store (`kind = 'memory'`, `root = 'memory://'`);
   a missing slug is a `LookupError`, a folder source or another kind a `ValueError`.
2. Chunk the text and persist through `SqlAlchemyIngestStorageGateway.replace_document` with
   `run_id=0` (no ingest run, so no `ingest_seen` row), the uri above, and the columns in the table.
   This is the same code path a file and a Messages thread go through, so the memory is a document
   in every respect the rest of the code checks (`state = 'ok'`, hashes, chunk reuse).
3. Upsert the `memories` row (`tags`, `origin`, `updated_at = now()`).
4. Embed what is new (below) in the same process, then commit.

Dedup: `remember` with text whose `content_sha256` already exists in the same store returns that
memory with `created=False` (and applies a new title or tags to it) rather than storing a twin.
The same text in two stores is two memories, which is what two stores are for.

`forget` deletes the document row; the cascade takes the memory row, chunks, vectors, facts and
authorship. The op returns the chunk count it removed so the CLI and the app can say so. On a
file-backed memory it refuses, as above.

`list_memories` spans every memory source unless `source` names one, orders by `updated_at DESC`,
filters `tag = ANY(tags)` and `query` as an `ILIKE` on title and text (a lexical convenience;
semantic recall is `rag_search(source=...)`).

### Embedding at write time

The backfill is the safety net, not the plan: it runs on the app's maintenance schedule, and an
agent that stores a memory expects to find it in its next search. So the store step embeds the new
chunks under every registered model, in process, through the existing embedder:

- `backfill_model(session, model, document_id=...)` gains an optional document filter, threaded
  into `pending_chunks_sql` as `AND c.document_id = :document_id`. Everything else is unchanged:
  the egress check, the provider-is-local withhold for communications, the width check,
  `ON CONFLICT DO NOTHING`. One code path embeds, whichever caller drives it.
- Failure is reported, not raised: a model whose server is down leaves the chunk pending and the
  result says so (`pending=["bge_m3"]`, `notes=["bge_m3: Ollama unreachable"]`). FTS finds the
  memory meanwhile, since `chunks.tsv` is generated on insert, and the next backfill finishes the
  job. The write never fails because of an embedder.
- Inside the app, the MCP server runs in `mcp-server-xpc`, which already does `llama_xpc`
  inference for `rag_ask` over `LlamaInferenceBridge`; embedding goes the same way. The launchers'
  `garage-mcp` reaches `LlamaXPCService` over its socket like `backfill` does.
- A per-call bound: `settings.embed_batch_size` is plenty for one memory's chunks, and
  `MEMORY_MAX_CHARS` keeps the batch small.
- Memory files are embedded by the ordinary backfill after their ingest, like any file.

## MCP surface (`mcp_server/server.py`)

Four tools, the project's first writes. Each returns a dataclass like the read tools.

```python
rag_remember(
    text: str,                              # ≤ 16 000 chars
    title: str | None = None,
    tags: list[str] = [],
    source: str | None = None,              # a memory store's slug; None is 'default'
    corpus_class: Literal["document", "communication"] = "document",
    trust: Literal["authored", "reference"] = "authored",
) -> MemoryResult

rag_update_memory(memory_id: int, text: str | None = None, title: str | None = None,
                  tags: list[str] | None = None) -> MemoryResult   # None leaves a field alone; [] clears tags

rag_forget(memory_id: int) -> ForgetResult                          # memory_id, document_id, deleted: bool

rag_list_memories(source: str | None = None, limit: int = 20 (1–100), offset: int = 0,
                  tag: str | None = None, query: str | None = None) -> MemoryList   # count, total, memories
```

- `MemoryResult` is `MemoryRecord` field for field, plus `created: bool` (false when deduplicated)
  and `embedded_models` / `pending_models` so the client knows whether a vector search will hit it
  yet. `MemoryInfo` in the list carries the full text of a stored memory and the first
  `max_chars` (default 2 000) of a file-backed one, with `truncated`; memories are bounded and the
  default page is 20, so there is no separate get tool: `rag_get_document(document_id)` reads the
  whole of a long file.
- `origin` is the MCP client's name from the session's `clientInfo` when the SDK exposes it, else
  `"mcp"`.
- `rag_list_sources` already lists memory sources with their kind; its docstring says that
  `kind = "memory"` sources hold memories and which one is `default`.
- `rag_search` changes in two small ways. `Hit` gains `memory_id: int | None` (a `LEFT JOIN
  memories m ON m.document_id = d.id` in the final select of `search()`, carried on `SearchHit`),
  so a client can update or forget what it just found. The docstring says that `source` with a
  memory source's slug keeps to memories, and that memories otherwise rank with everything else.
- `rag_agent` keeps its read-only allowlist (`AGENT_TOOL_NAMES`); the model never writes.
- The tool docstrings tell an assistant what a memory is for: durable facts about the owner,
  decisions, preferences and context worth keeping across sessions, one idea per memory, to
  search before storing so it updates rather than duplicates, and that a memory with
  `editable: false` is a file it should edit on disk instead.

### Write gate

The HTTP transport is the one surface another local account could reach (`127.0.0.1:8787`, the
app's only TCP listener), and it has no authentication. Writes are therefore gated by transport:

- a new setting, `mcp.writes`: `"stdio"` (default) | `"always"` | `"never"`;
- the four write tools are registered by `register_write_tools(mcp)` from `serve()` and
  `start_background_server()` when the gate allows, instead of at import. A client of a server
  that does not allow writes never sees the tools, which is clearer than a tool that refuses;
- `garage config set mcp.writes always` turns them on for the HTTP server; the app's MCP page gets
  the same switch beside its HTTP toggle, with the wording that it lets any local process store
  and delete memories.

The setting goes through `SECTIONS`, `docs/.data/garage.schema.json` is regenerated, and the
documentation test covers it.

### Privacy

No layer moves. `ops/memory.py` and `ingest/memory_files.py` import no network library; the AST
scan in `test_egress_block.py` passes without a new entry. Embedding goes through
`backfill_model → get_embedder → inference`, the guarded path, so:

- a memory stored as `communication` is withheld from an `ollama_host` / `lmstudio_host` that is
  not loopback, counted as pending, and embedded only by local models (`test_embed_egress.py`
  gains a memory case);
- `rag_ask` already runs every hit's class through `check_destination`, memories included;
- `rag_agent`'s `restrict_for_host` keeps a communication memory from an off-box model as it does a
  message.

`docs/privacy.md` gets a paragraph under "What connected agents receive": an assistant allowed to
write can also read back and delete what it wrote; what it stores is content the owner's assistant
decided to keep, and it goes to that assistant's provider with the conversation like any excerpt.
A memory folder is content from disk like any other source, and `CLAUDE.md` files often describe
private projects, so the guide says what indexing `~/.claude` means.

## gRPC and the app

RPCs in the proto's style, in a "Memories" banner, none of them config-changing (they change corpus
data, like `PersistDocument`, not egress):

```proto
rpc AddMemory    (AddMemoryRequest)    returns (AddMemoryResponse);     // text, title, tags, source, corpus_class, trust, origin
rpc UpdateMemory (UpdateMemoryRequest) returns (UpdateMemoryResponse);  // memory_id, optional text/title, tags + clear_tags
rpc DeleteMemory (DeleteMemoryRequest) returns (DeleteMemoryResponse);  // memory_id → document_id, chunks_deleted
rpc ListMemories (ListMemoriesRequest) returns (ListMemoriesResponse);  // source, tag, query, limit, offset → repeated MemoryInfo, total_count
rpc GetMemory    (GetMemoryRequest)    returns (GetMemoryResponse);
```

`MemoryInfo` mirrors `MemoryRecord`; `SearchHit` gains `int64 memory_id`. Handlers are thin over
`ops.memory` under `@_grpc_errors` (`LookupError` → `NOT_FOUND`, `ValueError` → `INVALID_ARGUMENT`,
`PermissionError` → `PERMISSION_DENIED`). `AddSource` already carries `kind`, so a memory store or
folder needs no new RPC. `GarageClient` gets one method per RPC; the checked-in `garage_pb2*.py`
are regenerated.

In the app: a **Memories** page under Data, after Search (`AppSection.memories`, symbol
`brain.head.profile`; `AppSectionTests` counts ten), with a source picker (all, or one memory
source), the list (title, first line, tags, source, updated; a document icon on file-backed ones),
a search field over `ListMemories.query`, an Add/Edit sheet (title, text, tags, store) and Delete
with confirmation; Edit and Delete are disabled on a file-backed memory with a "Reveal in Finder"
in their place. `GarageGRPCService+Memories.swift` and `AppState` wrappers follow `listDocuments`.
The Sources page's Add sheet offers the memory folder presets. The MCP page's "Try it" list and
`MCPServerPresentation` name the new tools and the writes switch.

## CLI

A `memory` sub-app, like `facts`:

```
garage memory add [--source SLUG] [--title T] [--tag TAG]... [--class document|communication] [--trust authored|reference] [TEXT | -]
garage memory list [--source SLUG] [--tag TAG] [--query Q] [--limit N] [--offset N] [--json]
garage memory show ID
garage memory edit ID [--text TEXT | --text-file PATH] [--title T] [--tag TAG]... [--clear-tags]
garage memory rm ID [--yes]
garage add-source --kind memory SLUG memory://      # another store
garage add-source --kind memory claude-memory ~/.claude
```

`add` reads stdin on `-`; `origin` is `cli`. Each prints the record, and `add`/`edit` say which
models embedded it and which are pending.

## Everything a memory touches elsewhere

- **Facts.** `enrich-facts` sees memories as documents and distils them like any other; with
  `--stale-only` an unchanged memory is not re-run. A stored memory is usually already atomic, so
  the pass is cheap and its facts are often the memory itself; a `CLAUDE.md` yields real facts.
  Left on (see decisions).
- **Documents page / `ListDocuments`.** A memory lists under its memory source with its title; the
  detail view shows `meta.tags` and `meta.origin`. No change needed.
- **Stats.** `rag_stats` and the Status page count memories as documents and chunks, which is
  honest; `rag_list_sources` shows the count per memory source.
- **Reset Database.** Memories in a store live in `pgdata` like everything else and are gone with a
  reset; the migration recreates `default` empty, and folder sources re-sync from `garage.json` and
  re-ingest. The reset sheet's wording should say that stored memories have no file to come back from.
- **Deletion safety** (`docs/architecture.md`). `forget` is the first single-document delete; it
  deletes by `memories.id` and only a memory whose source is a store, so a wrong id can never
  remove a file's document.

## Tests

- `test_memory.py` (mocks, like the other ops tests): `remember` persists through the gateway with
  the expected columns, uri shape and chunker signature, into `default` when no source is named
  and into the named store otherwise; a folder source or a non-memory source as the target is a
  `ValueError`; dedup on same text within a store, not across stores; `update_memory` keeps uri and
  document id and only changes what was passed; `forget` of an unknown id is a `LookupError`;
  `update_memory`/`forget` on a file-backed memory is a `ValueError`; text over the bound is a
  `ValueError`; a store with the embedder down returns `pending` and does not raise; `origin`
  recorded; `list_memories` spans sources and filters by one.
- `test_memory_files.py`: the name table matches each listed file and not `README.md`;
  `iter_memory_files` keeps `.claude/` and `.cursor/` but prunes `node_modules` and `.git`;
  `config.patterns` narrows and extends; the title comes from the first heading; the `memories`
  row carries `origin='file'` and the rule's tag.
- `test_postgres.py` (real server): migration 015 applies twice; the `default` source exists
  after it; a remembered memory is a hit for `search(..., sources=["default"])` and for a plain
  query; an edit that changes one of two chunks keeps the other chunk's vector; `forget` leaves no
  row in `chunks` or the model table.
- `test_embed_egress.py`: a communication memory is withheld from an off-box provider at write
  time and embedded by a local one.
- `test_mcp_server.py`: the four tools are present with `mcp.writes = always` and absent with
  `never`; stdio registers them by default and HTTP does not; `rag_search` hits carry
  `memory_id`; `rag_agent`'s tool list is unchanged. `test_mcp_stdio.py` asserts the tools over
  the wire.
- `test_sources_ops.py`: a store is skipped by ingest and scan and is not `undeclared`; `default`
  cannot be removed, another store can; `add_source(kind="memory", root="memory://")` needs no
  existing path; a folder memory source scans and ingests only memory files.
- `test_grpc_operations.py` / `test_grpc_server.py`: the five RPCs over `ops.memory`, none in
  `CONFIG_CHANGING_METHODS`.
- `test_cli_commands.py`: the `memory` sub-app. `test_config.py`: `mcp.writes` validates and is
  documented; `kind: memory` with a folder or `memory://` root loads.
- Swift: `AppSectionTests` for the new section; a `MemoriesPresentation` test for the wording;
  `SourcePresets` for the memory folder presets.

## Docs to update

`docs/schema.md` (`sources.kind`, the two shapes of a memory source, a `memories` section, the
memory row shape under `documents`), `docs/architecture.md` (the ingest dispatch for memory
sources; §9 Serve: the tools are no longer all reads; Deletion safety; the gRPC list),
`docs/privacy.md` (above), `docs/support/guide.md` and `faq.md` (how to let an assistant remember
things, indexing `~/.claude`, and the HTTP switch), `docs/.data/garage.schema.json` (regenerated), a
new `docs/memory.md` for users, and `CLAUDE.md` (memory sources, the `default` store, the write
gate, `ops/memory.py`, `ingest/memory_files.py`).

## Order of work

1. Python, stores only: migration (with `default`), models, `ops/memory.py`, the source skips,
   `backfill_model(document_id=)`, MCP tools and gate, `memory_id` on hits, CLI, tests, docs.
   Usable from a venv and from the bundled `garage-mcp` launcher with no app change, since the app
   applies migrations at start.
2. Memory folders: `ingest/memory_files.py`, the pipeline dispatch, scan, `config.patterns`, the
   presets, tests.
3. gRPC RPCs, `GarageClient`, regenerated stubs.
4. The Memories page, the source presets in the Sources sheet, and the MCP page switch.

## Decisions to confirm

1. **Default trust `authored`.** An assistant storing what the owner said or decided is recording
   the owner's words, and `trust=authored` is how clients ask for "the owner's own conclusions".
   v1.5 §3 proposed `reference` for agent-written memories, with a UI confirm flipping them. The
   recommendation is `authored` by default with `reference` on request; the plan's finer origins
   can still land later.
2. **Write gate default `stdio`.** Writes on for the per-client stdio server (the assistant the
   owner registered), off for the shared HTTP server until switched on. Alternative: off
   everywhere until the user opts in.
3. **File-backed memories are read-only over MCP.** The file is the truth and the database mirrors
   it. Alternative: write-through, where `rag_update_memory` rewrites `CLAUDE.md` on disk and
   re-ingests it. That makes an MCP client an editor of files other tools read at startup, which
   the write gate alone does not make safe; if wanted, it should be a per-source opt-in
   (`config.writable: true`).
4. **Memory files inside other sources.** A `CLAUDE.md` in a `git` or `filesystem` source is
   indexed today as a document (or skipped as code, depending on `include_code`). Recommendation:
   leave them as they are; a memory folder source is the way to make them memories. Alternative:
   every file matching the memory-file table, in any source, also gets a `memories` row, so
   `rag_list_memories` shows every project's instructions without another source.
5. **Facts on memories: on.** Memories are distilled like any document. Alternative: skip memory
   sources in `enrich-facts`, since a stored memory is already a fact-sized statement.
6. **One `memories` table, text on the document.** Alternative: no table, with tags and origin in
   `documents.meta` and the document id as the memory id. Fewer rows, but tag filters on jsonb and
   nowhere typed for the columns v1.5 adds next.
7. **`MEMORY_MAX_CHARS = 16_000`** for stored memories. A constant, not a setting. Longer verbatim
   text is `rag_store`'s job when it lands; files are not bounded by it.

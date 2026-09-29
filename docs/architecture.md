---
layout: default
title: Architecture Guide
description: How Garage's local RAG pipeline works, from walking folders and extracting PDF, Office, mail and Messages text to chunking, embedding with pgvector and hybrid search.
---

# Architecture

```
sources ──▶ walker ──▶ [materialize] ──▶ extract ──▶ quality gate
                                                          │
                            attribution ◀─────────────────┤
                                  │                       ▼
                                  └──────▶ documents ── chunks ◀── facts
                                                          │
                                              ┌───────────┴───────────┐
                                              ▼                       ▼
                                        emb_bge_m3            emb_nomic_embed_text
                                              └───────────┬───────────┘
                                                          ▼
                                              hybrid search (RRF)
                                                          │
                                                    MCP server
```

## Stages

### 1. Walk (`ingest/walker.py`)

Stats each candidate once and yields a small record. Nothing is opened, because
opening is where the cost is — parsing, and for cloud placeholders, downloading.
Pruning happens during descent, so excluded subtrees are never entered:

- `DEFAULT_EXCLUDE_DIRS` — VCS, build output, dependency directories, test fixtures
- `DIAGNOSTIC_DIR_PATTERNS` — `sysdiagnose_*`, `*.logarchive`, `ioreg`, `logs`
- `DEPENDENCY_PATH_FRAGMENTS` — `go/pkg/mod`, `.cargo/registry`, and friends
- `include_code=False` (default) — source and config files are skipped

### 2. Materialize (`ingest/materialize.py`)

Cloud placeholders are stubs (zero bytes from the old Dropbox client, dataless
files with their real size from File Provider clients such as iCloud Drive and
today's Dropbox); *reading* one asks the provider to download it. Materialization
is therefore metered by a `MaterializationBudget` capping files and bytes per
run. Hitting the cap is not a failure — because ingest is idempotent, repeated
bounded runs converge on the full corpus.

On macOS the budget is also enforced by the kernel: `ingest_source` turns the
`IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES` I/O policy off for its thread, so a
read of a dataless file anywhere else in the pipeline (an extractor, a hash)
fails with `EDEADLK` instead of downloading, and the pipeline records that file
as a placeholder. Only the materialize thread turns the policy back on, for the
one budgeted read.

A placeholder that was indexed before the sync client evicted it is skipped
without a download while its `mtime` (and its size, when the stub reports one)
still matches the document row. One that stays a placeholder gets no document:
the run counts it in `ingest_runs.placeholder_count` and records it as seen, and
an older row for it keeps its chunks.

Two more skips come before extraction. A file whose stat changed but whose raw
bytes did not (`source_sha256`) has its stat refreshed and is not re-extracted.
A file with no text (empty, all whitespace, an icon or a photo) gets no document
either: it is counted as rejected and any older row for it is dropped. It and a
file whose extraction failed are remembered in `ingest_outcomes` with their stat
and hash, so they are not read again until they change or their extractor's
version does.

### 3. Extract (`extract/`)

Dispatch is by extension, with lazy imports so a walk over 100k files does not
pay for `pdfplumber` and `openpyxl` in every worker.

| Kind | Extractor | Notes |
|---|---|---|
| Markdown | `text.py` | YAML frontmatter split off; malformed frontmatter never costs the body |
| PDF | `pdf.py` | `pypdf` first, escalating to `pdfplumber` **per page** when a page yields little text or holds tables |
| Office | `office.py` | `python-docx` / `python-pptx` / `openpyxl`; headings preserved as Markdown |
| Images | `image.py` | Tesseract, on this machine; no cloud fallback. HEIC/HEIF is decoded by macOS ImageIO (`imageio.py`), not a bundled codec |
| Mail | `mail.py` | `.eml` and Apple Mail's `.emlx`: a header block (subject, from, to, cc, date) and the body, plain part preferred, HTML stripped otherwise; attachments listed by name, never extracted. Filed as `communication` |
| Code | `text.py` | Verbatim — indentation is meaningful |

A Messages `chat.db` (a `sqlite` source) is not walked file by file:
`ingest/conversations.py` reads every chat and stores each thread as one
`communication` document, keyed on `<chat.db path>#<chat GUID>`, with one chunk
per message, so a thread that gains a message re-embeds one chunk. Each message
chunk records its `direction` (`sent` by the owner or `received`) and `sender`,
which search can filter on. Messages that no `chat_message_join` row names
(older macOS and iCloud sync leave many) join the one-to-one chat for their
sender's address; one with no handle, or whose address has only group chats,
is skipped and counted in the log (`extract/messages.py`).

### 4. Quality gate (`extract/quality.py`)

A personal corpus is full of text no human wrote. One macOS `sysdiagnose` bundle
here produced ~200k chunks — 76% of the index. Path rules catch most of it; this
module is the content-based backstop, using structural signals (line-shape
repetition, timestamp prefixes, hex/base64 density, alphabetic ratio).

Any single signal has false positives — a bibliography repeats, a cryptography
paper contains hex — so rejection needs either corroboration or one decisive
signal. Validated at zero false positives across 21 real prose documents.

`max_chunks_per_document` is the final backstop: no single document may dominate
the index.

### 5. Attribute (`attribute/`)

Signals in precedence order, each recording its evidence:

1. **Git history** (`git.py`) — authoritative, and the only signal that separates
   your own repository from a clone of someone else's.
2. **Embedded metadata** — PDF `/Author`, Office core properties. Filtered
   through `looks_like_tool_name`, because `python-pptx` writes its own author
   into every deck and `openpyxl` names itself.
3. **Path convention** (`pathrules.py`) — always available, so it is the
   fallback rather than the lead.
4. **Source default.**

A mail message skips the metadata rule: its sender decides, `authored` when it is
the owner and `received` otherwise. See [`attribution.md`](attribution.md).

> **Why one `git log` per repository:** `git log --follow` per file would mean
> 18k git invocations. One `--name-only` pass per repo builds a path→authors map
> in memory: 60 repos, 29 seconds total, versus an afternoon.

### 6. Store

See [`schema.md`](schema.md). Chunks are model-agnostic; each embedding model
owns a table keyed on `chunk_id` with `ON DELETE CASCADE`.

### 7. Distill facts (`enrich/facts.py`)

An optional pass over stored documents, run as `garage enrich-facts` or the
`EnrichFacts` streaming RPC (the app's Glean Facts action, and the last step of
Update Everything on the Sources page, which passes `stale_only`), not part of ingest
itself. [LangExtract](https://github.com/google/langextract) is pointed at the
local model named by `facts.model` on `facts.provider` (default: the app's
`gemma2-2b` alias on `llama_xpc`; `ollama` with e.g. `gemma2:2b` and `lmstudio`
with e.g. `google/gemma-3-4b` are the others, and `--model`/`--provider`
override both). What it asks for comes from the prompts in `facts.prompts`
(`config/fact_prompts.py`), each a name, a description (the instructions),
few-shot examples in LangExtract's shape (text plus the expected extractions,
each with a class, the quoted text and optional attributes), an optional scope
(`corpus_classes`, `sources`) and an `enabled` flag. The built-in `default`
prompt is deliberately generic — it has no notion of what kind of document it is
given — and asks for every standalone claim in the document's own wording.

Configured prompts are **merged by name** with the built-ins: an entry named
`default` overrides it field by field (so `{"name": "default", "enabled": false}`
turns it off, and a description or examples left out keep the built-in's), and
any other entry is added after it, so adding a prompt never silently drops the
default. `enrich-facts` runs every enabled prompt that applies to a document, or
only those named with `--prompt` (repeatable; the `EnrichFacts` RPC's `prompts`),
which also runs a disabled one. `garage facts prompts list` and
`garage facts prompts show NAME` print the effective prompts, and the app's
Models page lists and edits them (the `ListFactPrompts` RPC reads them;
`SetSetting facts.prompts` writes the list back).

Stored facts are browsed with `garage facts list` / `garage facts stats`, over the
same `ops.facts` functions as the `ListFacts` / `GetFactStats` RPCs behind the
app's Facts page: filtered by text (full-text or substring), source, document,
extraction class and corpus class, each fact with the document text around its
grounding span (`--evidence` prints the span), and counted per source and class.

**Recipe: entities as facts.** Nothing constrains `fact_class` to `'fact'`, so an
`entities` prompt asking for people, places, organizations, projects and events
runs today with no code change — just a `facts.prompts` entry. Each mention
becomes an ordinary, span-grounded fact (with an `attributes.name`/`kind`
LangExtract attaches) and gets embedded like any other fact; nothing resolves
repeated mentions into one entity or turns a relationship into an edge yet — see
[`v1.5.md`](plans/v1.5.md) for where that's headed. Add to `~/.garage.json`:

```json
{
  "facts": {
    "prompts": [
      {
        "name": "entities",
        "description": "Extract every named person, place, organization and event mentioned in this text. Quote each mention exactly as it appears; do not paraphrase. For each, give attributes: name (the full canonical name if the text states it, else the mention), and kind. For a person also give role if the text states one; for an event also give date if the text states one. Do not infer anything not stated.",
        "examples": [
          {
            "text": "On 12 May 2019 Jane Doe of Acme Corp presented the Q2 roadmap at the Austin Convention Center.",
            "extractions": [
              {"class": "event", "text": "presented the Q2 roadmap", "attributes": {"name": "Q2 roadmap presentation", "date": "2019-05-12"}},
              {"class": "person", "text": "Jane Doe", "attributes": {"name": "Jane Doe", "role": "presenter"}},
              {"class": "organization", "text": "Acme Corp", "attributes": {"name": "Acme Corp"}},
              {"class": "place", "text": "Austin Convention Center", "attributes": {"name": "Austin Convention Center", "kind": "venue"}}
            ]
          }
        ]
      }
    ]
  }
}
```

Run `garage enrich-facts --prompt entities` and inspect the `facts` rows it
produces (`fact_class` will be `person`/`place`/`organization`/`event`) before
building schema on top of what a given local model actually extracts.

Only the local part of LangExtract is used, vendored as
`enrich/langextract` (prompting, chunking, parsing and alignment). Upstream's
provider registry, which routes `gemini*`/`gpt-*` model ids to Google and
OpenAI, is not vendored, and a cloud model id is refused with an error. The
model is always `facts_language_model(...)`, a `LocalLanguageModel`
(`enrich/local_provider.py`) that posts each prompt to the server's
`/v1/chat/completions` through the [inference client](#local-inference-client).
Like the rest of local inference, content never leaves the machine. Ollama
keeps the JSON mode and temperature (0.1) that LangExtract's own Ollama provider
sent (GPT-OSS models get a JSON-only system instruction instead); LM Studio and
`llama_xpc` are prompt-only, since LM Studio refuses `json_object`.

Each fact lands in `facts` grounded to the exact span of `documents.content`
it came from; a fact the extractor cannot locate is dropped rather than stored.
Each fact records its prompt (`prompt_name`) and a hash of that prompt's
description and examples (`prompt_sha256`); re-extracting a document with a
prompt replaces that prompt's facts only. `fact_runs` records what each prompt
last ran with (prompt hash, the document's `content_sha256`, model), and
`enrich-facts --stale-only` skips a prompt whose run is still current.

Every fact also gets a `chunks` row of its own (`chunks.fact_id`,
`chunker = 'facts:langextract:<model>'`). That is the entire embedding story: a
chunk is a chunk regardless of where its text came from, so the ordinary
backfill anti-join picks fact chunks up and every registered model ends up with
a vector for them, with no fact-specific embedding path. Deleting a fact
cascades into its chunk and, from there, into every `emb_*` table.

### 8. Search (`search/hybrid.py`)

Reciprocal Rank Fusion over vector KNN and Postgres FTS, `k = 60`, 200
candidates per engine. RRF needs only each side's *ranking*, which matters
because cosine distance and `ts_rank_cd` are not comparably scaled.

The keyword half ORs its terms rather than ANDing them. `websearch_to_tsquery`
would require every word of "secure enclave firmware validation" in one chunk and
return nothing; RRF is what decides ordering, so the keyword side should favour
recall.

### 9. Serve (`mcp_server/server.py`)

MCP 2.0 over stdio (`garage-mcp`, the entry point clients spawn, separate from
the `garage` CLI) or HTTP (`garage mcp-serve`, or the macOS app's MCP helper).
Every tool returns a dataclass, because under MCP 2.0
dataclass returns map field-for-field while scalars and lists get wrapped in
`{"result": ...}`. `rag_search`, `rag_get_document`, `rag_list_sources`,
`rag_list_authors` and `rag_stats` read the corpus; `rag_ask`, `rag_agent` and
`rag_generate` also generate text, entirely on a local model.

`rag_ask` runs the same retrieval as `rag_search`, numbers the excerpts (each
trimmed to ~1,200 characters), and asks the model to answer from them citing
`[n]`; the result carries the answer plus one `Citation` per excerpt so a client
can resolve `[n]` back to a document. `rag_generate` is the same model with a raw
prompt and no retrieval. The model is `LocalChatModel` (`enrich/generation.py`),
built from `inference.provider` / `inference.model` (or `facts.provider` /
`facts.model` while `inference.model` is empty), which posts to `/v1/chat/completions`
through the [inference client](#local-inference-client): `llama_xpc` to the
app's `LlamaXPCService` on `llama_host` (the `model` field of each request
selects among the models the engine holds), `ollama` to the Ollama server on
`ollama_host`, `lmstudio` to the LM Studio server on `lmstudio_host`, all
through the egress guard. None is a cloud API; retrieved communications may
appear in the prompt but never leave the machine: `rag_ask` runs each excerpt's
class through the guard, which refuses a communication for a host that is not
loopback (see `docs/privacy.md`).

`rag_agent` (`mcp_server/agent.py`) lets the model drive instead: it gets the
five read-only tools above, each as a one-line signature in the system prompt
(arguments, their allowed values, the description's first sentence; small models
follow that better than a JSON schema), with a short guide from kinds of question to
tools and filters and the owner's name from `identity.self_name`, and calls them by replying with one JSON object
(`{"tool": "rag_search", "arguments": {...}}`); each result comes back as the next
user turn, and a reply that is not a tool call is the answer. Calls travel in the
conversation rather than as the OpenAI `tools` field because the app's llama engine
renders the chat template from role/content pairs alone, and the one format then
works on Ollama and LM Studio too. Arguments are validated against the tool's own
schema, as `tools/call` validates them, and an error goes back to the model to
correct. The result carries the answer, the steps (`AgentStep`) and one
`AgentCitation` per document the model saw. The menu bar's "Ask Garage" runs it.
By default (`search_first`) the question goes to `rag_search` before the model's
first reply, and the model starts from those hits, shown as a call it already made:
small models such as gemma2-2b otherwise read "when did I last talk to BMW?" as a
question about their training and answer that they have no access to personal
information. The system prompt also tells the model the corpus is the user's own.
Its content rule: when the model host is not loopback, `rag_search` is restricted
to documents and code and `rag_get_document` refuses a communication. `garage ask` is the
CLI front door to both tools, with `--json` for the app.

## Idempotency

Two hashes, deliberately not redundant:

| Hash | Over | Enables |
|---|---|---|
| `source_sha256` | raw bytes | skip an unchanged file **without opening it** — and so without materializing a placeholder |
| `content_sha256` | extracted text | rebuild chunks when an extractor improves, even though the file never changed |

One transaction per document, so a crash leaves earlier documents committed.

Replacing a document does not throw its chunks away. Each existing chunk whose
`ord`, text hash, text and chunker match the new set is kept (its offsets and
heading are updated in place), the rest are deleted and only new ones inserted.
A kept chunk keeps its row id, and so its vectors in every `emb_*` table: an edit
near the end of a file, or a Messages thread that gained a message, re-embeds
only what changed. Fact chunks are always dropped with the old content.

Each document also records a chunker signature (`chunks.chunker`, e.g.
`recursive:1000/100` or `code:python:1500/150`); a different signature means the
chunks are rebuilt on the next ingest even when neither hash changed. The
splitters behind it (`ingest/splitters.py`) are a small dependency-free port of
the langchain-text-splitters behaviour the chunker was first written against.
`tests/test_chunking_golden.py` pins their output to what langchain produced,
chunk for chunk and offset for offset, so the signatures did not change with the
swap and an existing index is not rebuilt. A deliberate change to the splitting
must change the signature too, so that stored chunks are rebuilt rather than
silently mixed.

## Deletion safety

The risk is not deleting, it is *deciding* something is missing — an unmounted
volume looks identical to a mass deletion. `ingest_runs.completed` marks only
walks that ran to exhaustion (a `--limit` or a cancellation that stopped the
walk early leaves it false), `ingest_seen` records every URI the walk yielded —
indexed, stat-skipped, failed or placeholder alike — and a run that would delete
more than 25% of a source refuses without `--force`.

## Concurrency

Ingest is a single process that handles one file at a time: walk, materialize,
extract, chunk and store run sequentially, one transaction per document. The
only worker thread is the one that guards a placeholder download with a
timeout. Parallelism across sources comes from running separate ingest
invocations, not from a pool inside the pipeline.

Embedding is a single batching producer at 64 chunks per request: Ollama
serializes model execution, so client fan-out buys contention, not throughput.
The `llama_xpc` provider (embeddings and, with `--provider llama_xpc`, facts)
talks to the app's `LlamaXPCService` through a llama-server-compatible API:
over NSXPC from the app's own XPC services (`garage_rag.inference.bridge`),
otherwise over HTTP on its socket in the App Group container
(`GARAGE_LLAMA_SOCKET`, which the app's processes export), with `llama_host`
naming the origin. Models are loaded over NSXPC only, never over HTTP. When a request finds its model not resident (503 `no model loaded`, 404
`model X is not loaded`), `LlamaXPCClient` asks `garage_rag.xpc.host` to load
it and retries once:

- inside the app's XPC services that embed Python (`GarageXPCService` for
  search, backfill and enrich-facts, `GarageMCPServerService` for `rag_search`
  and `rag_ask`, the embed worker) the Swift host installed a loader at start-up
  (`LlamaModelLoaderBridge`, a C function Python calls through ctypes, which
  releases the GIL); it resolves the slug to the downloaded GGUF and the Models
  page's load settings (`LlamaModelResolver`) and calls `ensureModel` on
  `LlamaXPCService` over NSXPC, through the endpoint of its anonymous listener,
  which the app hands each of these services at launch and after any of them
  restarts (a sibling XPC service cannot look `LlamaXPCService` up by name);
- elsewhere (the `garage`/`garage-mcp` launchers, or a venv while the app runs)
  it asks the app's `EnsureLlamaModel` RPC, which uses `GarageXPCService`'s
  loader;
- with neither, the error says to open Garage or load the model on its Models
  page, and a model that is not downloaded is named with where to download it.

`ensureModel` checks and loads under the engine lock, so callers in different
processes never load the same model twice, and a load waits for any running
inference (they share the engine lock). Python never unloads. The app decides
residency (`AppState+LlamaModels.swift`): it loads the default `llama_xpc`
embedding model once Postgres is up, and again when the default changes, so a
search finds it resident; it loads the facts model before a distillation run
and unloads it when the run ends, unless it is also the search model. Anything
loaded on demand stays until the Models page's Unload, which the Providers box
offers for every model Llama XPC holds.

## gRPC bridge (`service/server.py`)

`GarageService` (`proto/garage.proto`) listens on loopback port 50051, hosted in
the app's `GarageXPCService` helper, or run by hand with `garage serve`. Each handler is a thin
presenter over the same function the CLI command calls (`ops/`), and a
`_grpc_errors` decorator maps `LookupError`, `ValueError`, `FileExistsError` and
`PermissionError` onto gRPC status codes. The RPCs fall in three groups:

- **Corpus reads** for the app's views: `Search`, `ListDocuments`,
  `GetDocument`, `ListFacts`, `GetFactStats`, `ListSources`, `ListModels`, `GetStats`,
  `GetStatus`, `GetVersion`, `Ping`.
- **Operations**: `AddSource`, `RemoveSource`, `Scan` (streaming),
  `SyncSources`, `ImportSourcesToConfig`, `Reconcile`, `RegisterModel`,
  `SetDefaultModel`, `DropModel`, `Backfill` and `EnrichFacts` (both streaming;
  cancelling the call stops the work at its next progress step),
  `ListFactPrompts`, `InitDb`, `GetSetting` / `SetSetting`, `McpInstall` /
  `McpUninstall` / `McpStatus`, and `EnsureLlamaModel` for processes that cannot
  reach `LlamaXPCService` over NSXPC themselves.
- **The database facade** the ingest and embed XPC workers persist through
  (`GrpcIngestStorageGateway`): `BeginIngestSession`, `PersistScan`,
  `CheckDocumentStat` (the stat and hashes the skip decisions need),
  `PersistDocument`, `FinalizeIngestSession`, `GetEmbeddingBatches` and
  `UpdateEmbeddings`. The server side is the same
  `SqlAlchemyIngestStorageGateway` the in-process pipeline uses.

The server accepts requests up to 256 MiB, since `PersistDocument` carries a
document's whole text and chunks and a long Messages thread outgrows gRPC's
4 MiB default.

When `GARAGE_GRPC_TOKEN` is set, the server rejects with `UNAUTHENTICATED` any
call whose `x-garage-token` metadata is not that token (`service/auth.py`,
compared in constant time). The app makes a random 32-byte token each launch,
hands it to `GarageXPCService` and the ingest worker through their XPC
configuration (never `garage.json`, never a log), and sends it on every call;
`GarageClient` sends it whenever the variable is set. `EnsureLlamaModel` is the
one exception, since a stdio `garage-mcp` an MCP client spawned has no token.
Without the variable (`garage serve` by hand, the tests) the server takes any
call that only reads or persists corpus data. The methods that write
configuration (`auth.CONFIG_CHANGING_METHODS`: sources, models, `SetSetting`,
`McpInstall`, `McpUninstall`, and `InitDb`, whose `schema_dir` names SQL the
server runs) are stricter, because `SetSetting embedding.ollama_host` widens
the egress allowlist and a caller's schema directory runs against the corpus: with no token they are
answered only by a server bound to the owner-only Unix socket, whose folder mode
admits this account alone, and a server on a loopback TCP port refuses them with
`PERMISSION_DENIED` (`_config_change` in `service/server.py`; the decision is made
from the server's binding, not from `ServicerContext.peer()`, which macOS gRPC does
not report as `unix:` the way Linux does). This keeps other local processes from driving
configuration until the app reaches the server over XPC, with code-signing
checks and no socket.

## Local inference client

`garage_rag/inference/` is the one HTTP client for the three local inference
servers — LM Studio, Ollama and the app's `LlamaXPCService` — used by the
embedders (`embed/ollama.py`, `embed/lmstudio.py`, `embed/llama_xpc.py`),
`LocalChatModel` and the LangExtract provider. There is no `ollama` or `openai`
package behind it; it is httpx and a few hundred lines.

- **`Backend`** — `kind` (`lmstudio` | `ollama` | `llama_xpc`), `base_url` (the
  server root: a trailing `/v1`, as `lmstudio_host` carries, is dropped and
  added back per route), optional bearer `token` (LM Studio's, from
  `GARAGE_LMSTUDIO_API_TOKEN` or `embedding.lmstudio_api_token_file`), timeouts.
  `Backend.from_settings(kind)` builds it from the configuration.
- **`InferenceClient`** — `embed(texts, model)`, `chat(messages, model,
  max_tokens=, temperature=, response_format=)` and `list_models()` /
  `has_model()` on every backend, all on the OpenAI-compatible `/v1` routes
  except Ollama embeddings (below). For LM Studio, model management on its
  native REST API: `lmstudio_models()` (`GET /api/v1/models`: type, loaded
  instances, max context), `load_model()` (reads the applied `load_config`
  back, since `context_length` can be ignored), `unload_model()` and
  `download_model()` (starts a download and returns the job; polling is not
  implemented until the status route is confirmed). `LlamaXPCClient`
  (`xpc/llama_xpc.py`) is a subclass adding llama-server's own routes (health,
  props, tokenizer, raw completion, rerank).
- **Errors** are all `InferenceError`, with a `status_code`: unreachable (503),
  non-2xx (`InferenceHTTPError`, with the server's message and error `type`;
  `InferenceAuthError` for 401/403), **a 2xx whose body is `{"error": …}`**
  (`InferenceErrorBody` — LM Studio answers unknown routes with HTTP 200 and
  an error body), a reply that is not the promised JSON (502), an operation
  the backend does not have (501) and a refused destination (400).
- **What it never does:** send `dimensions` (LM Studio ignores it; Garage
  truncates vectors itself), or add a `response_format` of its own (LM Studio
  rejects `json_object` with HTTP 400; `json_schema_format()` builds the
  `json_schema` form every backend accepts).
- **Ollama embeddings stay on `/api/embed`**, the route the `ollama` package
  used, so stored vectors are reproduced exactly. `Backend.ollama_embed_route =
  "openai"` switches to `/v1/embeddings` once `tests/test_inference_live.py`
  has shown the two agree on a real embedding model.
- **Transport.** `inference/transport.py` imports no HTTP library:
  `open_transport()` takes its client from the egress guard,
  `egress.http_client`. That approves loopback or the origin configured for the
  backend (`llama_xpc` is loopback only), refuses a communication for a host
  that is not loopback when the client is built with `corpus_class`, ignores
  proxy variables, never follows a redirect and refuses any other origin. A
  refusal is `InferenceRefused`, which is also an `EgressBlocked`.

---
layout: default
title: Database Schema Reference
description: PostgreSQL schema layout, cascade rules, and HNSW vector indexing.
---

# Schema reference

DDL lives in `data/sql/00*.sql` at the repository root, which is the source of truth (it holds the CHECK
constraints and the generated `tsvector`). `db/models.py` mirrors it for typed
reads and writes, not for schema creation.

Migrations are idempotent — `IF NOT EXISTS` plus `duplicate_object` guards for
enum types — so applying them repeatedly *is* the migration story. Sufficient for
a single-user local corpus, and it avoids a migration framework.

The files run in order, `001_extensions.sql` through `013_fact_prompts.sql`.
`001` creates `vector` and `pg_trgm`, and Apache AGE (`age`, graph queries in
openCypher) only where the server has it installed: the app's bundled Postgres
always does, Homebrew's and the CI image usually do not, and nothing in the
schema depends on it yet.

## The two axes

The design decision worth understanding: **what a thing is** and **how trusted it
is** are independent.

`corpus_class` — the primary partition:

| Value | Meaning |
|---|---|
| `document` | prose: notes, papers, reports, presentations |
| `code` | source and structured config |
| `communication` | messages and mail; Garage never sends it off the machine |

`trust_tier` — provenance:

| Value | Meaning |
|---|---|
| `authored` | the owner wrote it |
| `reference` | external, already QA'ed: papers, vendored code, product docs |
| `received` | someone else sent it |

The pairing is what makes the corpus queryable:

| (class, trust) | Example |
|---|---|
| `(code, reference)` | a vendored dependency |
| `(code, authored)` | your own repository |
| `(document, reference)` | a downloaded paper |
| `(document, authored)` | your research notes |
| `(communication, received)` | an inbound message |

A single `trust_tier` with a `communication` value would have conflated these —
"is this a private conversation" is a property of *what the content is*, not of
how much you trust it. The embedding guard that keeps communications off any
provider not on this machine is keyed on `corpus_class` for that reason.

## Tables

### `sources`

Registered roots. `kind` ∈ `filesystem | git | sqlite | maildir | feed` — `feed`
is the extension point for social media connectors.

`expected_elements` is the item count of the last scan, which the app's
progress bars measure ingest against. The rest of that scan lives beside it
(`008_source_scan.sql`): `scan_item_type` (files, messages, …), `scan_details`
(the scanner's per-kind breakdown) and `scanned_at`. `config` holds only the
source's own settings, such as `include_code`, as written by `sync` from
garage.json.

### `authors` / `author_identities`

An author owns many identities (`git_email`, `email`, `phone`,
`imessage_handle`, `handle`). Resolution is lookup-by-identity, create-on-miss,
so the same person arriving first via a git email and later via a PDF byline
collapses onto one row.

A partial unique index enforces at most one `is_self` author.

### `documents`

One row per logical document, unique on `(source_id, uri)`.

| Column | Purpose |
|---|---|
| `source_sha256` | raw bytes — a changed stat over unchanged bytes skips re-extraction |
| `content_sha256` | extracted text — decides whether to re-chunk |
| `extractor` + `extractor_version` | provenance; a version bump forces a rebuild |
| `chunker` | chunking signature; a config change forces a rebuild |
| `content` | full extracted text, for `rag_get_document` |
| `meta` | extractor and attribution provenance |
| `state` | `ok \| extract_failed \| embed_partial \| placeholder` |

`placeholder` is no longer written: a file whose bytes are not on this machine
gets no document, and each run counts such files in `ingest_runs.placeholder_count`
instead. `011_drop_placeholder_documents.sql` removes the empty rows older builds
wrote and returns indexed rows they had marked `placeholder` to `ok`.

### `document_authors`

M:N with `role` (`author`, `committer`, `sender`, `recipient`, `cc`),
`confidence`, and `evidence` — `git-log:self-commits:4/4`,
`path-rule:Reference`, `document-metadata`. Evidence makes a misattribution
diagnosable instead of mysterious.

### `chunks`

The unit of embedding, and deliberately model-agnostic — every model references
these same rows, which is what makes re-indexing a backfill rather than a
re-ingest.

```sql
tsv tsvector GENERATED ALWAYS AS (to_tsvector('english', text)) STORED
```

Postgres maintains the keyword index itself; no application bookkeeping.

`char_start` / `char_end` are the chunk's span of `documents.content`: its
exact text, or for markdown (whose header splitter drops blank lines) the span
from its first line to its last. They are NULL when the chunk cannot be found
in the content, and on chunks built before offsets were recorded; those gain
them the next time the document is re-chunked.

Re-chunking a document keeps every row whose `ord`, `chunk_sha256`, text and
`chunker` are unchanged, updating only its offsets and heading, and replaces the
rest. A kept row keeps its `id`, so its vectors in the `emb_*` tables survive and
backfill embeds only the chunks that actually changed. Fact chunks are always
replaced.

`chunks.fact_id` (`007_chunk_fact_link.sql`) is a nullable
`REFERENCES facts(id) ON DELETE CASCADE` column with a partial unique index
(`WHERE fact_id IS NOT NULL`), so a fact has at most one chunk. It marks a
chunk as distilled from a fact rather than cut from `documents.content`; such
chunks carry `chunker = 'facts:langextract:<model>'`. Nothing else about the
row is special — the backfill's anti-join finds it like any other chunk, which
is what gets facts embedded under every model without a fact-specific path.
Deleting a fact cascades into its chunk and, through `chunk_id`, into every
`emb_*` table.

### `facts`

Atomic, self-contained claims distilled out of a document's text by
`enrich/facts.py` (`006_facts.sql`, `013_fact_prompts.sql`). Same shape as
chunks: ordered rows scoped to a `document_id` (`ON DELETE CASCADE`), and within
it to the prompt that produced them (unique on `(document_id, prompt_name, ord)`).
Running one prompt over a document again replaces that prompt's facts and
leaves every other prompt's alone.

| Column | Purpose |
|---|---|
| `fact` | the claim, in the document's own wording |
| `fact_class` | the extractor's label (its prompt's `extraction_class`, default `'fact'`); unconstrained so the prompt can be specialized per corpus |
| `attributes` | `jsonb` extractor attributes, default `'{}'` |
| `char_start` / `char_end` | span of `documents.content` the fact was grounded to; an ungrounded fact is dropped by the extractor rather than stored |
| `extractor` / `extractor_model` | provenance, default `'langextract'` and the model id |
| `prompt_name` | the `facts.prompts` entry that produced the fact; `'default'` (the built-in prompt) for facts from before 013 |
| `prompt_sha256` | SHA-256 of that prompt's description and examples when it ran; NULL before 013 |
| `tsv` | generated `to_tsvector('english', fact)`, GIN-indexed — the keyword half of hybrid search over facts |

### `fact_runs`

The last extraction of each prompt over each document (`013_fact_prompts.sql`),
keyed on `(document_id, prompt_name)` with `document_id` `ON DELETE CASCADE`:
the prompt's hash (`prompt_sha256`), the document's `content_sha256` and the
`extractor_model` it ran with, how many `facts` it found, and `extracted_at`. A
run that found nothing still leaves a row. `garage enrich-facts --stale-only`
compares all three inputs with the current ones and skips a prompt whose run is
up to date, so changing a prompt's text, a document's content or the model
re-extracts exactly what it affects.

### `conversations` / `messages`

Structured storage for communication sources (`sms`/`imessage` chat.db, `mail`)
prior to synthesis into a document.

A `conversations` row is one thread between the corpus owner and a single
other participant (`other_author_id`), scoped to the `source_id` it came
from and keyed on the source's native thread identifier (`external_id`) so
re-ingest finds the same conversation rather than duplicating it.

`messages` rows accumulate under a conversation as they are ingested, each
attributed to its sender via `author_id` (the owner or the conversation's
`other_author_id`) and deduplicated on `(conversation_id, external_id)`.

A synthesis step concatenates a conversation's messages in `sent_at` order
into one synthetic `documents` row — `conversations.document_id` — which is
then chunked and embedded exactly like any other document, using the same
`comms_window_minutes` / `comms_window_messages` grouping as the chunker.
Deleting that document (e.g. to force a rebuild) clears `document_id` back
to null rather than deleting the raw messages, so re-synthesis has the full
history to work from.

These tables are not written yet. Messages ingest (`ingest/conversations.py`)
reads `chat.db` directly on every run and stores each thread as one `documents`
row with one chunk per message, keyed on `<chat.db path>#<chat GUID>`.

### `embedding_models` and the `emb_*` tables

One table per model, because `vector(1024)` and `vector(2560)` cannot share a
column, and per-model nullable columns would make HNSW indexes and backfills
painful.

```sql
CREATE TABLE emb_<slug> (
  chunk_id  bigint PRIMARY KEY REFERENCES chunks(id) ON DELETE CASCADE,
  embedding <type>(<dims>) NOT NULL,
  embedded_at timestamptz NOT NULL DEFAULT now()
);
```

`chunk_id` as both primary key and cascading foreign key is the load-bearing
detail: deleting a chunk removes its vectors from *every* model table at once,
so stale vectors cannot outlive the text they came from.

#### Storage selection

pgvector 0.8 HNSW ceilings are hard limits — `vector` ≤ 2000 dims, `halfvec`
≤ 4000:

| Model width | Storage | Index |
|---|---|---|
| ≤ 2000 | `vector(d)` | HNSW on the model's distance |
| 2001–4000 | `halfvec(d)` | HNSW on the model's distance |
| > 4000, Matryoshka | `halfvec(4000)` truncated + renormalized | HNSW on the model's distance |
| > 4000, not Matryoshka | `vector(d)` | HNSW on `binary_quantize(...)::bit(d)`, re-ranked on the exact distance |

#### Distance

`embedding_models.distance` (`009_model_distance.sql`) is the similarity the
model was trained for: `cosine`, `l2` or `inner_product`. It is declared per
model in `docs/.data/models.json` (or `register-model --distance` for a model
the catalog does not list) and fixes two things that must agree: the HNSW
operator class (`vector_cosine_ops`, `halfvec_l2_ops`, `vector_ip_ops`, …) and
the operator search orders by (`<=>`, `<->`, `<#>`). An index built for one
metric is not used by a query on another, so the metric is chosen once, at
registration. Models registered before the column existed were indexed for
cosine, which is its default.

`models.json` is the one model catalog: the app reads it for presets and
downloads, and `garage_rag.db.catalog` reads the same file for widths,
`supports_mrl`, `distance` and per-provider names (`provider_refs`, e.g. an
Ollama tag), found through `GARAGE_MODEL_MANIFEST` or in the repository
(`docs/.data/models.json`). The site serves that file as
`https://garagerag.app/.data/models.json`; the app fetches it at launch, keeps the
copy in its data folder when it decodes as a catalog with presets, and points
`GARAGE_MODEL_MANIFEST` at that copy, else at the one in its bundle. A catalog
change therefore reaches installed apps without a release. It has two lists:
`text_embedding`, and `inference_models` for the generative models, each tagged
`inference` (chat, `rag_ask`), `distillation` (`enrich-facts`) or both; the app still
reads the list's older name, `fact_distil`, as distillation models. Every entry names its
`maker` (e.g. `IBM`), `country_of_origin` (an ISO 3166-1 alpha-2 code, e.g. `DE`) and
`origin_zone` (`US`, `EU`, `CN`, `UK`, `CH` or `OTHER`, e.g. `EU` for `DE`), which the app
shows as a badge and a test holds to the country; `tool_calling: true` marks a
model trained to call tools, which can drive Garage's MCP tools. Reference embeddings of
fixed inputs are kept apart from it, keyed by slug, in
`docs/.data/model_test_vectors.json`, so the catalog the app fetches stays small.

Truncation is only sound for MRL-trained models, so `supports_mrl` is declared
per model rather than assumed. A CHECK constraint refuses to register an
`hnsw`-indexed model above its type's ceiling, so the mistake cannot reach a
failing `CREATE INDEX` thousands of documents into an ingest.

Truncated vectors are renormalized: a prefix of a unit vector is not itself unit
length, and pgvector's cosine operator does not normalize for you.

### `ingest_runs` / `ingest_seen`

Coverage bookkeeping that makes deletion safe. `completed` is true only for a
walk that ran to exhaustion (not one cut short by `--limit` or cancellation).
`ingest_seen` holds one row per observed URI per run, including files that were
stat-skipped without being opened; nothing prunes old runs yet, so it grows
with every ingest.

### `ingest_outcomes`

One row per file that made no document because it holds no text (`no_text`: an
empty file, an icon, a photo) or its extraction failed (`failed`, with
`error`). It keeps the file's `byte_size`, `mtime` and `source_sha256`, and
`extractor_revision`, the extractor and its `VERSION` at the time (`image:1`).
While the stat or the raw hash still matches, the next run skips the file
instead of reading it again. A row whose revision differs from the current
extractor's is ignored, so bumping an extractor's `VERSION` retries every file it
gave up on. Indexing the file deletes its row. DDL in `012_ingest_outcomes.sql`.

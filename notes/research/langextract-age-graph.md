# LangExtract → entities, vectors and edges in Apache AGE

Research for Rick's ask (2026-09-27): how to turn LangExtract output into graph nodes with
embeddings and typed edges in Apache AGE, and what new prompts (People, Places, Events, …) that
needs. Any code targets `v1.5-beta`. Repo state read from `main` at 2026-09-27.

## 1. What already exists

**LangExtract in Garage produces spans, not triples.** `enrich/facts.py` runs the vendored local
half of LangExtract and keeps only grounded extractions. Each one is an `Extraction` with
`extraction_class`, `extraction_text` (quoted verbatim from the document), `attributes`
(`dict[str, str | list[str]]`), a `char_interval` and a `group_index`. Every one becomes a
`facts` row: `fact_class`, `attributes` (jsonb), `char_start`/`char_end`, `prompt_name`,
`prompt_sha256`. Nothing constrains `fact_class` to `'fact'`; the schema comment in
`006_facts.sql` says so on purpose, and `test_postgres.py` already exercises a prompt named
`people`.

**Every fact is already a vector.** A fact gets its own `chunks` row (`chunks.fact_id`,
`chunker = 'facts:langextract:<model>'`), so the ordinary backfill embeds it under every
registered model with no fact-specific path. Deleting a fact cascades to its chunk and all
`emb_<slug>` rows.

**Prompts are already plural and named.** `facts.prompts` (`config/fact_prompts.py`) merges by
name onto the built-in `default`, each with `corpus_classes` and `sources` scope. `enrich-facts`
runs every enabled prompt, replaces only that prompt's facts, and `fact_runs` gives
`--stale-only`. The Models page's fact-prompt UI (`FactPromptsSection.swift`) edits them.

**People already have a table.** `authors` / `author_identities` (`email`, `git_email`,
`git_name`, `phone`, `imessage_handle`, `handle`) and `document_authors` (role, confidence,
evidence) are a resolved-identity store fed by attribution and the conversation ingesters. A
graph "Person" must join this, not duplicate it.

**AGE is installed but unused.** `//ext/age` pins AGE 1.8.0-rc0 for PG18 and PG19;
`001_extensions.sql` creates it where the server has it; the app starts Postgres with
`shared_preload_libraries=age` and `search_path="$user", public, ag_catalog`
(`PostgresService.swift:497-504`); `TestAge` in `test_postgres.py` proves `create_graph`,
`CREATE` and `MATCH` round-trip. Homebrew and the CI image lack it, so everything graph-side
must degrade to "no graph" cleanly, as 001 does.

Consequence: the pipeline from prompt to embedded row exists end to end. What is missing is
(a) prompts that ask for entities and relations instead of free-standing facts, (b) a place
to resolve many mentions into one entity, and (c) the projection of entities and relations into
AGE plus tools that read it back.

## 2. Phase 0: try it today, no code

The current alpha can run an entity prompt as a configuration change. `fact_class` stores the
class, `attributes` stores whatever the model attaches, and the Facts page lists the results.
Example `facts.prompts` entry (`~/.garage.json`), in the shape `FactPrompt` validates:

```json
{
  "name": "entities",
  "description": "Extract every named person, place, organization and event mentioned in this text. Quote each mention exactly as it appears; do not paraphrase. For each, give attributes: name (the full canonical name if the text states it, else the mention), and kind. For a person also give role if the text states one; for an event also give date if the text states one. Do not infer anything not stated.",
  "examples": [
    {
      "text": "On 12 May 2019 Jane Doe of Acme Corp presented the Q2 roadmap at the Austin Convention Center.",
      "extractions": [
        {"class": "event",        "text": "presented the Q2 roadmap", "attributes": {"name": "Q2 roadmap presentation", "date": "2019-05-12"}},
        {"class": "person",       "text": "Jane Doe",                 "attributes": {"name": "Jane Doe", "role": "presenter"}},
        {"class": "organization", "text": "Acme Corp",                "attributes": {"name": "Acme Corp"}},
        {"class": "place",        "text": "Austin Convention Center", "attributes": {"name": "Austin Convention Center", "kind": "venue"}}
      ]
    }
  ]
}
```

That gives typed, span-grounded, embedded mention rows immediately. What it does not give is
resolution (three "Jane" mentions are three rows) or edges. It is the right way to check what
`gemma2-2b` and the other local models actually produce before building schema on it. My
expectation from LangExtract's behaviour on small models: single-class entity spans are
reliable; attributes are mostly right for `name` and `kind`, and unreliable for anything that
needs inference (`role`, dates written relative to the document).

## 3. Prompts

LangExtract works best with few classes per prompt and one job per prompt. Proposed built-ins,
each a `FactPrompt` so users can override or disable them exactly like `default`:

| Prompt | Classes | Attributes | Scope |
|---|---|---|---|
| `entities` | `person`, `place`, `organization`, `event`, `project` | `name`, `kind`, `role` (person), `date` (event) | all |
| `relations` | `relation` | `subject`, `predicate`, `object`, optional `date` | all |
| `default` | `fact` | none | all (unchanged) |

Notes on shape:

- **One entity mention per extraction, quoted verbatim.** The span is what grounds it and what
  the existing ungrounded-drop filter keys on. The canonical `name` attribute is *not* grounded;
  keep it only when it fuzzy-matches the span or another mention in the same document, else fall
  back to the span text.
- **Relations as one extraction whose text is the sentence that states them.** The subject and
  object go in attributes. This keeps the evidence span (the sentence) grounded and lets the
  relation be embedded as a chunk like any fact; the triple is resolved against the entity table
  afterwards. LangExtract's own relationship pattern is a shared attribute value across
  extractions (upstream's `medication_group` example) and its `group_index` groups the
  extractions the model emitted together; both are usable, but a single `relation` extraction
  with `subject`/`object` attributes is simpler for a 2B model and simpler to store.
- **Predicate vocabulary.** Ask the model to pick from a short list (`works_at`, `member_of`,
  `located_in`, `attended`, `organized`, `knows`, `related_to`, `part_of`, `created`, `owns`)
  and record the free-text predicate too. AGE stores edges one table per label, so a small
  fixed vocabulary is what makes edge labels indexable; `related_to {predicate: '…'}` catches
  the rest.
- **Communications.** Participants come from `messages.author_id` and
  `conversations.other_author_id`, not from the model. On `corpus_class = 'communication'` the
  `entities` prompt is for third parties and places mentioned in the text; the sender and
  recipient edges come from the tables and are free.
- **Code.** Scope `entities`/`relations` to `document` and `communication` by default; on code
  the yield is package names and author handles, already covered by attribution.
- **Cost.** Each prompt is one more model pass per document per chunk window. Two new prompts
  triple distillation time. `--stale-only` already limits re-runs; a per-prompt `enabled`
  default of true for `entities` and false for `relations` is the safe first cut.

## 4. Storage: relational source of truth, AGE as projection

AGE has no foreign keys into ordinary tables, so a cascade from `documents` can never reach a
vertex. The reliable pattern is: plain tables own the data (with cascades), and the graph is a
projection written in the same transaction and rebuilt per document, the way facts and chunks
are replaced wholesale today.

Proposed `014_entities.sql` (all `IF NOT EXISTS`, re-appliable):

```sql
CREATE TABLE IF NOT EXISTS entities (
    id          bigserial PRIMARY KEY,
    label       text NOT NULL,                 -- person | place | organization | event | project
    key         text NOT NULL,                 -- normalized canonical name, unique per label
    name        text NOT NULL,                 -- display form
    aliases     text[] NOT NULL DEFAULT '{}',
    attributes  jsonb NOT NULL DEFAULT '{}',
    author_id   bigint REFERENCES authors(id) ON DELETE SET NULL,   -- when a person resolves to a known author
    mention_count int NOT NULL DEFAULT 0,
    created_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT entities_label_key_unique UNIQUE (label, key)
);
CREATE INDEX IF NOT EXISTS entities_name_trgm ON entities USING gin (name gin_trgm_ops);

-- One row per grounded mention; the fact row is the evidence and cascades from the document.
CREATE TABLE IF NOT EXISTS entity_mentions (
    fact_id     bigint PRIMARY KEY REFERENCES facts(id) ON DELETE CASCADE,
    entity_id   bigint NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
    document_id bigint NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    role        text
);
CREATE INDEX IF NOT EXISTS entity_mentions_entity ON entity_mentions (entity_id);
CREATE INDEX IF NOT EXISTS entity_mentions_document ON entity_mentions (document_id);

CREATE TABLE IF NOT EXISTS entity_relations (
    id          bigserial PRIMARY KEY,
    subject_id  bigint NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
    object_id   bigint NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
    label       text NOT NULL,                 -- the fixed vocabulary
    predicate   text,                          -- the model's words
    fact_id     bigint NOT NULL REFERENCES facts(id) ON DELETE CASCADE,   -- evidence sentence
    document_id bigint NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    attributes  jsonb NOT NULL DEFAULT '{}'
);

-- An entity is embedded the way a fact is: it gets a chunk.
ALTER TABLE chunks ADD COLUMN IF NOT EXISTS entity_id bigint REFERENCES entities(id) ON DELETE CASCADE;
CREATE UNIQUE INDEX IF NOT EXISTS chunks_entity_unique ON chunks (entity_id) WHERE entity_id IS NOT NULL;
```

Cascade story: document deleted → facts → mentions and relations; entity with no mentions left
is garbage-collected by the enrich pass (or kept when `author_id` is set). Re-running the
`entities` prompt on a document deletes that prompt's facts, which drops the mentions, then
re-inserts, exactly the pattern in `extract_and_store_facts`.

### Vectors

`chunks.entity_id` mirrors `chunks.fact_id`: the entity's chunk text is `name` plus its aliases
and a one-line description assembled from attributes ("Jane Doe, person, presenter at Acme
Corp"). The backfill anti-join picks it up under every model with zero new embedding code.
An entity chunk belongs to no single document, and today's schema forbids that
(`chunks.document_id NOT NULL`); options are to relax the column to nullable for entity chunks, or to attach the chunk
to the document of the first mention. Relaxing it is cleaner; `hybrid.py` joins
`documents` through `chunks.document_id`, so the search query needs a `LEFT JOIN` for entity
rows or a separate entity search. Relation sentences are already embedded because they are
facts.

Vectors do not go into AGE. `agtype` is JSON-like; there is no pgvector type inside it and no
HNSW over vertex properties. Every vertex carries the relational id as a property and the
KNN happens in `emb_<slug>` as now.

### The graph in AGE

One graph, `garage`, created in `014` inside the same `IF EXISTS (… 'age')` guard as `001`.
Vertex labels `Person`, `Place`, `Organization`, `Event`, `Project`, `Document`, `Author`.
Each vertex holds only ids and a display name; everything else stays relational:

```
(:Person {entity_id, name, author_id?})
(:Document {document_id, title, corpus_class})
(:Author {author_id, display_name, is_self})
```

Edges:

| Edge | From → To | Properties | Source |
|---|---|---|---|
| `MENTIONED_IN` | entity → Document | `fact_id`, `char_start`, `char_end`, `role` | `entity_mentions` |
| `WROTE` / `RECEIVED` | Author → Document | `confidence`, `evidence` | `document_authors` |
| `IS` | Person → Author | | `entities.author_id` |
| `WORKS_AT`, `LOCATED_IN`, `ATTENDED`, … | entity → entity | `fact_id`, `document_id`, `predicate`, `date` | `entity_relations` |
| `RELATED_TO` | entity → entity | as above plus free `predicate` | fallback label |

Writes use `MERGE` on the id property so re-projection is idempotent:

```sql
SELECT * FROM cypher('garage', $$
  MERGE (p:Person {entity_id: 42}) SET p.name = 'Jane Doe'
  MERGE (d:Document {document_id: 1234})
  MERGE (p)-[m:MENTIONED_IN {fact_id: 9876}]->(d) SET m.char_start = 10, m.char_end = 18
$$) AS (r agtype);
```

Per-document re-projection: `MATCH (d:Document {document_id: $id})<-[m:MENTIONED_IN]-() DELETE m`
then recreate from the tables; relation edges the same by `document_id` property.

Reading back with a join to relational tables, e.g. neighbours of a search hit:

```sql
SELECT (e)::text FROM cypher('garage', $$
  MATCH (d:Document {document_id: 1234})<-[:MENTIONED_IN]-(x)-[r]-(y)
  WHERE NOT y:Document
  RETURN {entity_id: y.entity_id, label: labels(y)[0], via: type(r)} AS e
  LIMIT 50
$$) AS (e agtype);
```

Practical AGE points. The first is proven by the existing test; the rest come from AGE's 1.x
documentation and were not run here, so PR B should confirm each against the bundled build:

- Outside the app, a session must `LOAD 'age'` and put `ag_catalog` on `search_path`
  (`test_postgres.py:750-753`). Add both to the engine's connect hook, guarded by
  `pg_extension` having `age`, so venv runs against Homebrew keep working without a graph.
- `cypher()` in `FROM` needs a column definition list, and returns `agtype` that must be cast
  (`::text`, then JSON-decode, or `agtype_access_operator` for a field). Ints are bigint.
- Parameters: the Cypher body is a dollar-quoted literal, so values cannot be bound into it
  with psycopg placeholders. AGE's third argument is an `agtype` map referenced as `$name` in
  the body, but its docs say it works only through a `PREPARE`d statement, so the projection
  code should prepare once per label and execute with a JSON string cast to `agtype`. Never
  interpolate document text or names into the body; only ids go there, and only after an
  `int()` check.
- Each label is a table in schema `garage` (`garage."Person"`, `garage."MENTIONED_IN"`).
  Expression indexes work: `CREATE INDEX ON garage."Person" (agtype_access_operator(properties, '"entity_id"'::agtype))`.
  Without them `MERGE` on a property is a sequential scan per call; add them in 014.
- Statement-level, so it runs inside the same SQLAlchemy transaction as the fact insert.
- `pg_dump`/restore of a database with AGE needs care: the graph lives in its own schema plus
  rows in `ag_catalog.ag_graph`/`ag_label`, and AGE's own docs give a specific restore order.
  The app's Back Up / Restore (`pg_dump` in `PostgresService`) must be checked against a
  restored graph before this ships; a broken restore that loses only the projection is
  acceptable if the enrich pass can rebuild it from the tables, which this design allows
  (`garage graph rebuild`).
- Cypher `MERGE`, `labels()`, `type()`, list/map literals, `OPTIONAL MATCH`, `UNWIND` and
  variable-length paths (`-[*1..2]-`) are supported in 1.8; there is no full-text or vector
  operator, which is fine here.

## 5. Entity resolution

Order, cheapest first, in the enrich pass after facts are stored:

1. **Key normalization**: casefold, strip honorifics and punctuation, collapse whitespace;
   `(label, key)` is the unique key. "Jane Doe" / "jane doe" / "Dr. Jane Doe" collapse.
2. **Alias inside the document**: LangExtract's `name` attribute against other spans of the
   same class in the same document ("Jane" after "Jane Doe" → alias).
3. **Trigram**: `pg_trgm` is already installed; `similarity(name, $1) > 0.6` within the same
   label proposes merges of near names (typos, initials).
4. **Vector**: once an entity chunk is embedded, KNN over entity chunks under the default
   model with a tight threshold proposes merges across surface forms ("ACC" vs "Austin
   Convention Center") when the description text overlaps. Proposals only; automatic merge
   only for 1 and 2.
5. **Authors**: a `person` whose key matches an `author_identities` value of kind `git_name`
   or an `authors.display_name` gets `author_id`; `is_self` gives the owner's own node, which
   is what makes "what did I say about X" a traversal.

Merging keeps the survivor's id, moves mentions and relations, appends aliases, and drops the
other entity (its chunk and vectors cascade). A manual merge/split later belongs on a Facts or
People page; the tables support it without the graph knowing (re-project the affected
documents).

## 6. Reading it: search, MCP, the app

- **Graph expansion of hybrid search.** `rag_search(..., expand: "neighbors")`: take the RRF
  top-k documents, `MATCH` entities mentioned in them and their one-hop neighbours, and append
  the neighbours' best facts as extra citations. This is the GraphRAG payoff at a size a local
  model can use; two hops explode on a personal corpus and should stay opt-in.
- **New MCP tools**, each returning a dataclass like the others: `rag_entities(query, label?)`
  (trigram plus KNN over entity chunks), `rag_entity(entity_id)` (mentions, relations,
  documents, author link), `rag_graph(entity_id, hops=1, labels?)` (a bounded traversal;
  never raw Cypher from the client). The upcoming `rag_agent` (#155) gets these for free.
- **Content rule.** Entity names and relation sentences distilled from communications are
  communication content. `entity_mentions` carries `document_id`, so a query for an off-box
  chat model filters mentions and relations whose document is a communication the way
  `backfill` withholds chunks; an entity mentioned only in communications is itself withheld.
  Add a case to `test_egress_block.py`/`test_embed_egress.py` for it.
- **App**: the Facts page gains a class filter and an Entities tab; the Status page's Library
  bar counts distillation per prompt already. Graph visualisation is not needed for the value
  above and should wait.

## 7. Risks and unknowns

- **Small-model quality.** `gemma2-2b` is the default. Entities will be fine; relations from
  a 2B model will be noisy, and noisy edges are worse than none. Gate `relations` behind an
  explicit enable and measure precision on a fixture before making it default.
- **Time.** Distillation is already the slowest stage. Two more prompts on a 30k-document
  corpus is days on an M-series laptop; run `entities` on new documents in the normal pass and
  offer a one-time backfill.
- **AGE maturity.** 1.8.0-rc0 on PG18/PG19 is a release-candidate line. The projection design
  keeps the graph disposable so an AGE bug loses nothing that a rebuild cannot restore.
- **Backup/restore** with AGE, as above, needs a real test on the M3 before beta.
- **Schema drift with `documents.content_sha256`.** `fact_runs` already invalidates by content
  hash; mentions and relations hang off facts, so they inherit it. Nothing new to track.

## 8. Suggested order for v1.5-beta

1. **Phase 0** (now, config only): ship the `entities` prompt JSON above in the docs as a
   recipe and try it on the M3 against a real folder; look at the `facts` rows it produces.
2. **PR A, tables and resolution**: `014_entities.sql`, `enrich/entities.py` (resolve mentions
   and relations from the two prompts' facts into the tables, entity chunks), `entities` and
   `relations` built-in prompts, tests on mocks plus the SQL in `test_postgres.py`.
   Useful without AGE at all.
3. **PR B, AGE projection**: graph creation in 014, `graph/projection.py` (per-document
   re-projection, `garage graph rebuild`), connect-hook `LOAD 'age'`, `TestAge` extended to
   the real labels, backup/restore check on the M3.
4. **PR C, reading**: `rag_entities`, `rag_entity`, `rag_graph`, `expand` on `rag_search`,
   the egress test cases, Facts page filter and Entities tab.

A and B touch `data/sql`, `enrich/`, `db/`; C touches `mcp_server/`, `search/`, the app. If
#155's `rag_agent` lands first, C bases on it.

## 9. Redundant facts (Rick's follow-up, 2026-09-27)

**Where duplicates come from today.** There is no fact de-duplication anywhere in the pipeline.
The vendored LangExtract cuts a document into 1000-character windows with no overlap and runs
one pass (`extraction.py`: `max_char_buffer=1000`, `extraction_passes=1`); its only merge
logic, `_merge_non_overlapping_extractions`, handles multi-pass overlap by character position
and never runs. So duplicates are not a windowing artefact. They come from:

1. The document saying the same thing twice: abstract and body, summary and detail, repeated
   headers, and above all **quoted replies in mail and repeated statements in a flattened
   conversation**. `extract/mail.py` strips markup but not quoted earlier messages, so a
   ten-message thread states the first message ten times.
2. The model emitting a compound claim and its parts ("founded in 1998 by Jane Doe" plus
   "founded in 1998" plus "founded by Jane Doe"), which small models do despite the prompt.
3. Cross-prompt overlap (`default` fact and `relations` sentence on the same span). That is by
   design and should stay: different classes, same evidence.
4. The same fact across documents (drafts, versions, forwards). A corpus-level problem; the
   same machinery applies later but it is out of scope for per-document work.

**Assessment of the embed-cluster-reduce idea.** Right shape, with three corrections.

- *Embeddings alone will merge contradictions.* Sentence embeddings place "the meeting is on
  Tuesday" next to "the meeting is not on Tuesday", and "42 employees" next to "45 employees".
  A fact store that silently collapses those is worse than one with duplicates. Every merge
  needs a guard the embedding cannot give: identical sets of numbers and dates, no negation
  asymmetry, and, once the `entities` prompt runs, the same entity mentions. For clusters that
  pass the guard and are still doubtful, one yes/no call to the local chat model ("do these
  state the same claim?") is cheap, because clusters are few and small.
- *Reduce by selection, not generation.* A model-written merged sentence is no longer a
  quotation, and the whole facts design rests on every fact being a verbatim, grounded span
  (ungrounded extractions are dropped, not stored). Keep the most complete member as the
  survivor's text (longest grounded span; earliest on ties) and attach every member's span. If
  a canonical paraphrase is wanted for display, store it in a separate, clearly non-verbatim
  column (`statement`), never in `fact`.
- *Cluster with average linkage, not single linkage.* Single linkage chains A≈B, B≈C into one
  cluster where A and C differ. Per document the count is tens to low hundreds, so a full
  pairwise cosine matrix and agglomerative average-linkage merging with a threshold is enough;
  no HDBSCAN or index needed.

**Proposed pass, in the enrich step after extraction and before entity resolution:**

1. Exact and normalized-text dedup (casefold, whitespace, trailing punctuation). Free; do it
   in the same PR as the entity tables regardless of the rest.
2. Embed the document's new facts with the default registered embedding model at distill
   time (tens of short strings, one batched call). Doing it here rather than after the
   backfill means the survivor is what the backfill embeds and what the entity graph counts.
3. Pairwise cosine, average-linkage clusters above a threshold. The threshold is
   model-specific (paraphrase on short sentences sits high, roughly 0.9 and up on the
   bge/nomic family, but it has to be measured): calibrate on a fixture per default model and
   record the model slug and threshold in `fact_runs` so `--stale-only` re-runs when either
   changes.
4. Guard each cluster (numbers, dates, negation, entity set); optional local-model confirm.
5. Survivor by selection; members become spans of the survivor and their own rows are not
   stored, so nothing downstream changes except that a fact can now have several spans.

**Schema.** Add `fact_spans (fact_id FK cascade, char_start, char_end, prompt_name,
extraction_index)`, one row per grounded occurrence, and keep `facts.char_start`/`char_end`
as the primary span so the Facts page highlight and `list_facts`' excerpt keep working. The
excerpt view lists the other spans as "also stated at …". A `facts.statement` column only if
generated paraphrases are wanted.

**Cheaper first fix for the biggest source.** Strip quoted reply blocks (`> ` prefixes, "On
… wrote:" and Outlook-style separators) in `extract/mail.py` before distillation, and give
conversation documents the message structure they already have in `messages` (distill per
message run, not per flattened window). That removes most mail duplicates with no clustering
and improves the chunks too. Do it in the same phase.

**Where it fits.** Phase A (tables and resolution), before entity resolution, since merged
facts mean merged mentions and correct `mention_count`. It needs no AGE.

---
layout: default
title: Search result access rules
description: ALLOW and DENY rules, matched by regular expression, keyword or similarity to a phrase (and later by a local model's judgement), that decide which search results each target sees, whether that is the app, an MCP assistant, or a client reaching the Mac through Garage Door.
date: 2026-11-02
status: Proposed (design only, no code yet)
status_kind: proposed
---

# Search result access rules

Today every reader of the corpus sees all of it. The app's Search page, each assistant registered
on the MCP page, and a client coming in through Garage Door all get the same results for the same
query. The only control is the egress rule, which keeps communications away from a model host that
is not on this Mac (`docs/privacy.md`). That rule decides where content may be *processed*. It does
not decide who may *read* it.

This plan adds access rules. A rule says ALLOW or DENY, says what it matches (a regular
expression, a keyword, or similarity to a phrase, and later a local model's judgement), and names
the targets it applies to. For each target, the rules decide which documents its searches,
document reads, fact listings and answers may draw on.

Written against `next` at `71af3bd` on 2026-11-02. The schema runs to `018_fact_anchors.sql`.
Enterprise parts are kept apart in [Enterprise](#enterprise-what-stays-out-of-garage-rag), and the
choices that need Rick are in [Decisions to confirm](#decisions-to-confirm).

## Goals

- **Targets.** Each reader of the corpus has a name: the app, each MCP registration, each Garage
  Door, and each client or OAuth grant on a door. Rules are written against targets and groups of
  them (`mcp:*`, `door:*`, `*`).
- **Rules.** ALLOW or DENY, with a matcher. The first matchers are `regex`, `term` and `similar`.
  Structural matchers that cost nothing (source, corpus class, trust tier, author, path glob) come
  with them, because they are what most rules will actually be.
- **One evaluation, every read path.** Search, `rag_get_document`, the listings, facts, the graph,
  `rag_ask` and `rag_agent` all go through the same check. A test fails when a read path is added
  without it, as `test_egress_block.py` does for outbound clients.
- **Results stay full.** Filtering happens before ranking and fusion, so a search that hides
  results still returns `limit` hits when the corpus has them.
- **Fail closed.** A document the rules have not yet been evaluated against is treated as matched
  by every DENY that is still pending for it, and not matched by any pending ALLOW.
- **Room for model-judged rules.** The matcher interface takes an LLM-evaluated rule without a
  schema change (see [Later: model-judged rules](#later-model-judged-rules)).
- **Nothing new leaves the machine.** Rules, their phrases and their matches stay in the local
  database and `garage.json`.

Not in scope: rules about queries, so that "deny any search about X" is not this plan; per-user rights
in a shared corpus (Enterprise's `readers`, below); and redacting part of a document.

## What a rule decides: a document, not a chunk

A rule matches content, and what it hides is the **whole document**. If a DENY matches one chunk
of a file, the file is hidden from that target: every chunk, every fact distilled from it, its
title in listings, and its full text through `rag_get_document`. An ALLOW that matches one chunk
admits the document.

Hiding only the matched chunk would leak the rest. The neighbouring chunks usually carry the same
subject, `rag_get_document` would return the full text anyway, and facts distilled from the file
restate it. This is the rule the Hub plan settled in Enterprise ("a chunk is as sensitive as its
file", decision 2), applied to targets instead of people, so the two editions agree.

Redaction, where a document is shown with the matched passages cut, is a possible later feature on
top of this and is not designed here.

## Targets

A target is a reader of the corpus. Its identity has to come from somewhere the reader cannot
simply type, and how strong that is depends on the path:

| Target | Name | Where the identity comes from | Default |
|---|---|---|---|
| The app's own pages (Search, Documents, Facts, Graph) | `app` | The gRPC token the app sets per launch (`GARAGE_GRPC_TOKEN`); only the app has it | ALLOW |
| An MCP assistant over stdio | `mcp:<registration>` (e.g. `mcp:claude-desktop`) | `--target <registration>` in the args that `McpInstall` writes into the assistant's config | ALLOW |
| An MCP assistant over the app's HTTP endpoint | `mcp:<registration>` | A bearer token per registration, written into its config by `McpInstall`; only its SHA-256 is stored | ALLOW |
| `garage-mcp` started with no target (hand-edited config, older registration) | `mcp:unregistered` | The absence of a target | ALLOW, but one switch flips it to DENY |
| A Garage Door | `door:<door id>` | The registration the Door connector uses on the Mac, as for an HTTP assistant | Decision 3 |
| A client or OAuth grant on a door | `door:<door id>/<grant id>` | An identity header the gateway sets after it checks the client's token (Enterprise change, below) | Inherits its door |

Upgrading changes nothing: with no rules, every target sees what it sees today.

**What this protects against, and what it does not.** Rules keep an assistant to what the person
meant it to see, and keep a remote client to what its door was opened for. They are not a sandbox
against software running as the same user on the Mac. Such software can start `garage-mcp --target
app` itself, or edit an assistant's config. The HTTP and Door paths are stronger, because they need
a token only the app hands out. `docs/privacy.md` will say this plainly, and the app will never
describe rules as a security boundary against local software.

**Within a door.** The node decides what a door may see, since the connector's registration is the
door's. Which *client* on that door is calling is something only the gateway knows, because it
checked the client's token and the token never reaches the Mac. So per-client rules trust the
gateway to name the client honestly. A gateway that lied could only move a request between
clients of the same door, never past the door's own rules, and the door's rules are enforced on the
Mac. That fits the Door rule that what a client may do is decided on the node.

**Groups.** A rule's `targets` is a list of names and patterns: `app`, `mcp:*`, `door:*`,
`door:abc123/*`, `*`. The patterns are fixed prefixes with one trailing `*`, not regular expressions.

## Rules

```jsonc
// garage.json
"access": {
  "defaults": { "app": "allow", "mcp:*": "allow", "mcp:unregistered": "allow", "door:*": "allow" },
  "rules": [
    { "name": "no-medical", "effect": "deny", "targets": ["mcp:*", "door:*"],
      "match": { "similar": "my medical records and diagnoses", "threshold": 0.62 } },
    { "name": "no-keys", "effect": "deny", "targets": ["*"],
      "match": { "regex": "-----BEGIN [A-Z ]*PRIVATE KEY-----", "field": "text" } },
    { "name": "work-only", "effect": "allow", "targets": ["door:abc123"],
      "match": { "source": ["work-docs", "work-code"] } },
    { "name": "project-falcon", "effect": "deny", "targets": ["mcp:chatgpt"],
      "match": { "term": "falcon acquisition" } }
  ]
}
```

A rule has a stable `name` (its identity across edits), an `effect`, its `targets`, one `match`, and
an optional `enabled`. Its **version** is a hash of everything that changes what it matches,
including the embedding model a `similar` rule is evaluated under. Editing a rule's matcher gives it
a new version, and its old matches stop counting at once.

### Matchers

| Matcher | Matches a document when | Evaluated | Cost |
|---|---|---|---|
| `source`, `corpus_class`, `trust_tier`, `author`, `path` (glob) | Its metadata says so | In the query predicate, directly on `documents` | Nothing |
| `regex` | Any chunk's text, or the title or path (`field`), matches the expression, case-insensitive by default | At ingest, in SQL (`~*`), under a statement timeout | One scan per new rule |
| `term` | Any chunk matches the keyword query, with stemming, through the existing `tsv` column and its GIN index | At ingest, in SQL | Index lookup |
| `similar` | Any chunk's vector, under the default model, is within the threshold's cosine similarity of the phrase's vector | After embedding, in the backfill pass | One KNN per rule per new chunk batch |
| `judge` (later) | A local model, given the rule's question and the document, answers yes | After embedding, as a distillation-style pass | One model call per document per rule |

`regex` runs in Postgres, not in Python, so it does not care which language the ingester is in after
the Rust migration. Postgres's regular-expression engine is a hybrid DFA and NFA, which avoids most
catastrophic backtracking, and the evaluation runs with a `statement_timeout`. A rule that times out
stays pending, so it fails closed, and the app says so on the rule.

**Similarity needs calibration, so the editor shows it.** A cosine threshold means different things
under different models. The rule editor embeds the phrase as it is typed and shows the nearest
documents with their scores, the number the threshold would match, and the ones just past it. A
`similar` DENY is a broad net and is meant to be tuned against that preview. A phrase is embedded
under the default model only. A rule records the model it was evaluated under, and changing the
default model makes every `similar` rule pending until the backfill evaluates it again.

Facts (`chunks.fact_id`) are chunks of their document, so a match on a fact's text counts for the
document, and hiding the document hides its facts.

### How rules combine

For a target `t` and a document `d`:

1. If any enabled DENY rule for `t` matches `d`, or is still pending for `d`, the document is hidden.
2. Otherwise, if any enabled ALLOW rule for `t` matches `d`, it is visible.
3. Otherwise the target's default applies.

So a DENY always wins over an ALLOW, whatever the order. ALLOW rules matter only for a target
whose default is DENY: "this door sees my work sources and nothing else" is a DENY default with one
ALLOW. This is decision 1. The alternative, an ordered list where the first match wins (as in a
firewall), is easier to explain for small lists and harder to get right for long ones. It also lets a
fuzzy `similar` ALLOW placed early undo a precise DENY placed late.

A target's rules are its own, plus every rule whose pattern names it. Nothing inherits otherwise,
except that `door:<id>/<grant>` sees at most what `door:<id>` sees: the grant's rules are evaluated
after the door's, never instead of them.

### Built-in rules

Two rules ship disabled and are offered by the app:

- `communications`: DENY `corpus_class = communication`. The Door's open question, whether to
  withhold messages and mail from remote clients by default, becomes whether this rule is ticked for
  `door:*` when a door is created (decision 3).
- `secrets`: DENY a `regex` set for private keys, common API token shapes and `.env`-style
  assignments, for `*` except `app`.

## Where it is enforced

### Evaluation is materialized, the decision is made at query time

Evaluating regular expressions and similarity across the corpus on every query would be too slow, and
filtering after retrieval would leave searches short of results. So matching happens ahead of time,
and the *decision* is made in the query:

- **Matches** are stored sparsely, one row per (rule, version, document) that matched. They are a
  function of the document's content and the rule's version, so they never go stale. Changed
  content or a changed rule gives a new key.
- **Rules, targets and defaults** are read for each request, so disabling a rule, deleting it, or
  changing a default takes effect on the next query with nothing to rebuild.
- **A new DENY** takes effect at once too. Until its evaluation has covered a document, the rule is
  pending for that document, and a pending DENY hides it. A new DENY over a large corpus therefore
  hides everything from its targets for the minutes its first pass takes, and the rule's row in the
  app shows the progress.

This is the "live, fail closed" property the Hub plan asks of source permissions (decision 6),
applied to content rules. Nothing that decides visibility is cached past the request. Only the
matches are stored, and they are facts about content, not decisions.

### Schema (`019_access_rules.sql`, the next free number)

```sql
CREATE TABLE access_rules (
  id          bigserial PRIMARY KEY,
  name        text NOT NULL UNIQUE,
  effect      text NOT NULL CHECK (effect IN ('allow', 'deny')),
  targets     text[] NOT NULL,                   -- names and prefix patterns
  matcher     text NOT NULL,                     -- source | ... | regex | term | similar | judge
  spec        jsonb NOT NULL,                    -- the match object from garage.json
  version     text NOT NULL,                     -- hash of spec (+ model slug for similar)
  enabled     boolean NOT NULL DEFAULT true,
  -- evaluation progress: documents with id <= evaluated_through have been checked at `version`
  evaluated_through bigint NOT NULL DEFAULT 0,
  state       text NOT NULL DEFAULT 'pending'    -- pending | ready | failed
);

CREATE TABLE access_matches (                     -- sparse: only matches
  rule_id     bigint NOT NULL REFERENCES access_rules ON DELETE CASCADE,
  version     text   NOT NULL,
  document_id bigint NOT NULL REFERENCES documents ON DELETE CASCADE,
  PRIMARY KEY (rule_id, document_id, version)
);

CREATE TABLE access_pending (                     -- documents whose content changed after the rule passed them
  rule_id     bigint NOT NULL REFERENCES access_rules ON DELETE CASCADE,
  document_id bigint NOT NULL REFERENCES documents ON DELETE CASCADE,
  PRIMARY KEY (rule_id, document_id)
);

CREATE TABLE access_targets (                      -- registrations, for the token paths and the UI
  name          text PRIMARY KEY,                  -- 'mcp:claude-desktop', 'door:abc123'
  kind          text NOT NULL,                     -- app | mcp | door | door_client
  token_sha256  bytea,                             -- HTTP and Door registrations only
  default_effect text                              -- NULL: the defaults table in garage.json
);
```

A document is pending for a rule when its id is above `evaluated_through` or it has an
`access_pending` row. `replace_document` evaluates the metadata, `regex` and `term` rules inline,
in the document's own transaction, and adds `access_pending` rows for the `similar` (and later
`judge`) rules, which the backfill clears once the document's chunks have vectors. A new document
is therefore visible to a target with `similar` DENY rules only after it has been embedded. That is
the fail-closed choice, and the delay is the one search already has, since an unembedded chunk is
found only by keyword.

Like the rest of `data/sql`, the migration is idempotent and re-applied, not tracked.

### The predicate

`acl.Viewer` resolves the target's rules for the request into two arrays of rule ids and the
default, and `search/hybrid.py:_filter_clause` adds one more condition. It sits in both engines'
CTEs, so the filter comes before fusion, as the existing filters do:

```sql
AND NOT EXISTS (                                   -- matched or pending DENY
      SELECT 1 FROM access_matches m
      WHERE m.document_id = d.id AND m.rule_id = ANY(:deny_ids)
        AND m.version = (SELECT version FROM access_rules WHERE id = m.rule_id)
    UNION ALL
      SELECT 1 FROM access_pending p
      WHERE p.document_id = d.id AND p.rule_id = ANY(:deny_ids)
    UNION ALL
      SELECT 1 FROM access_rules r
      WHERE r.id = ANY(:deny_ids) AND d.id > r.evaluated_through)
AND (:default_allow OR EXISTS (...matched, not pending, ALLOW...))
AND <metadata DENY/ALLOW rules inlined as plain conditions>
```

With `hnsw.iterative_scan` on (Enterprise needs it upstream anyway, `architecture.md` section 0),
the vector engine keeps walking the index until the filtered candidates fill its depth. With no
rules for the target, the predicate is omitted and the query is the one that runs today.

### Every read path

`garage_rag/acl/` is the one place that knows the rules, as `net/egress.py` is the one place that
opens a connection. Each read path takes an `acl.Viewer` and passes it down:

| Path | What changes |
|---|---|
| `search/hybrid.py:search` (CLI, gRPC `Search`, `rag_search`) | The predicate above |
| `rag_get_document`, gRPC `GetDocument` | A hidden document answers exactly as a missing one does ("no such document"), by id or by path, so its existence does not leak |
| `ListDocuments`, `ListFacts`, `GetFactStats` | The predicate on the document join |
| `rag_list_sources`, `rag_list_authors`, `rag_stats`, `GetStats` | Counted over visible documents. A source with none visible is not listed |
| `rag_ask`, `rag_agent` | Retrieval and every tool call the model makes run as the calling target; the model sees nothing the caller could not |
| Graph (`GetGraphLabels`, `FindGraphVertices`, `GetGraphNeighborhood`) | A vertex or edge is shown when at least one supporting fact's document is visible, and only the visible support is listed |
| Memories (the memory plan) | Memories are documents and need nothing new. A memory also records the target that wrote it, so a later rule can match `written_by` |

`tests/test_access_paths.py` holds the table above as data. It walks every `@mcp.tool()` and every
`GarageService` read handler, and fails on one that is not listed with its enforcement.
`test_postgres.py` covers the predicate against real Postgres: pending DENY hides, ALLOW under a
DENY default admits, a version change drops old matches, and `hnsw` and `hnsw_bq` both still fill
`limit`.

**Row-level security, later.** The predicate is enforced in the query, by code the path test
checks. A second layer would set the target on the transaction (`set_config('garage.target', ...)`)
and put the same condition in RLS policies on `documents`, `chunks` and `facts`, with `FORCE ROW
LEVEL SECURITY`. That is the mechanism `architecture.md` uses for `garage.principals`, so the
editions would share one policy shape. It is a milestone of its own (A5), because RLS has to leave
the ingest and embed paths untouched and needs its own Postgres tests.

### What a target is told

Nothing. A hidden result is absent, not counted, for every target but the app. A count tells an
assistant that something about its query exists, and it can probe with narrower queries. The app's
Search page has a **Preview as** menu (any target), which shows exactly what that target would get,
with "N results hidden by: no-medical, communications" under the list. This is the personal
edition's counterpart of Enterprise's View as User. Decision 4.

Each rule keeps a hit counter and the time it last hid something, so the Access page can show that
a rule is doing anything. No query text, title or content is logged.

## The rest of the app

- **Access page** (Configuration group, after MCP Server): the targets (the app, each MCP
  registration, each door and its clients) with their defaults, and the rules, each with its
  targets, a live match count, its evaluation progress and its hit counter. The rule editor has the
  preview described above. Wording goes in an `AccessPresentation` value with unit tests, as the
  other pages do.
- **MCP page**: each registration shows its target name and a link to its rules. Registering an
  assistant writes `--target` (stdio) or its token (HTTP). Update rewrites an older registration
  that has neither.
- **Door**: when a door is paired, the app creates `door:<id>` and offers the built-in
  `communications` rule ticked or not, per decision 3.
- **Config**: an `access` section in `config/__init__.py`'s `SECTIONS`, synced into
  `access_rules` at start-up and by the `SetSetting` path, as sources are synced. The schema in
  `docs/.data/garage.schema.json` is regenerated. Since `SetSetting` on `access.*` changes what
  leaves the Mac, it joins `auth.CONFIG_CHANGING_METHODS`.
- **CLI**: `garage access list|add|remove|test`, where `test --as door:abc123 "query"` runs a search
  as that target. `garage-mcp --target NAME`.
- **gRPC**: `ListAccessRules`, `PreviewAccessRule` (streaming the nearest matches while typing), and
  `target` on `SearchRequest` and the other read requests for Preview as. Only the app's token may
  name a target other than `app`.

## Later: model-judged rules

A `judge` rule asks a local model a question about a document, for example "Is this about my
health?" or "Would I be uncomfortable if my employer read this?". It fits the design above without
schema changes:

- It is a matcher with `needs = text + model`, evaluated in a pass like `enrich-facts`, over
  documents that are pending for it, with the result stored in `access_matches` like any other.
- It runs on the facts provider (`llama_xpc` by default). It goes through `egress`, and a
  communication goes only to loopback, as with every other model call. A `judge` rule may be
  restricted to loopback entirely. That is likely the right default, since the rule exists because
  the content is sensitive.
- Its version includes the model id and the prompt, so a model change re-evaluates it.
- It is never evaluated at query time. Pending fails closed, as for `similar`.
- The prompt asks for a yes or no with the passage that decided it, so the Access page can show why
  a document was hidden. A cheap prefilter (a `similar` threshold set low) limits which documents
  reach the model.

Its cost is one model call per document per rule. On a large corpus that is hours, and the app will
say so before a `judge` rule is enabled.

## Enterprise: what stays out of garage-rag

This design is the personal edition's, and every part of it belongs in garage-rag. The following
belong to Enterprise and are only noted here:

- **Per-person rights.** Enterprise's `readers` and `sensitivity` on each row, under Postgres RLS
  (`architecture.md` section 3). Access rules narrow what a *target* gets *within* what the person
  may read. They never widen it. In Enterprise the effective set is readers ∩ live source check ∩
  target rules.
- **Org-managed rules.** Rules pushed by the organization, locked against editing, as signed policy
  or managed configuration (Hub plan H4). Upstream needs only a `locked` flag on a rule and a hook
  for where locked rules come from.
- **Door's client identity.** The gateway setting a client identity header after its token check,
  added to `door/lib/garage_door/protocol.rb`'s allowlist and stripped from anything the client
  sends, plus the account pages for naming grants. That change is in garage-enterprise `door/`. The
  node side, reading the header only on a door's registration, is here.
- **Audit retention.** Garage keeps hit counters. Enterprise's audit row per request and SIEM export
  stay there.

### The Hub plan and `architecture.md`

The Hub plan (`garage-enterprise docs/plans/hub.md`, Proposed) conflicts with `architecture.md` on
four points. This design takes a side on none of them, but it touches two:

- **"A chunk is as sensitive as its file"** (Hub decision 2): adopted here, as the reason a rule
  hides whole documents. In the Hub plan the decision is about which *machines* may process a
  document, against `architecture.md`'s plaintext leases to cleared workers. That conflict is
  untouched, and it is still Rick's.
- **Live checks at query time** (Hub decision 6) against `architecture.md`'s principal set cached
  for the token's lifetime and ACL captured at ingest: access rules are decided at query time with
  no cached decision, so they meet the Hub's bar either way. Which bar Enterprise holds *person*
  rights to is still open, and it should be settled in `architecture.md` section 11 before the
  Kotlin tier's query path is written.

## Order of work

| Milestone | Contents |
|---|---|
| **A1** | Schema, the `access` config section, `acl.Viewer`, the metadata matchers plus `regex` and `term`, the predicate on every read path with the path test, `--target` for stdio and `garage access` |
| **A2** | `similar`, with evaluation in backfill, the HTTP registration tokens, and the Access page with its preview and Preview as on Search |
| **A3** | Door targets on the node, and on the Enterprise side the gateway's identity header and grant names |
| **A4** | The built-in rules, and the Door default |
| **A5** | Row-level security as a second layer |
| **A6** | `judge` |

## Decisions to confirm

1. **How rules combine.** Recommended: DENY always wins, ALLOW matters only under a DENY default.
   The alternative is an ordered list where the first match wins.
2. **What a rule hides.** Recommended: the whole document, matching the Hub plan's decision 2. The
   alternative is the matched chunk only, with redaction.
3. **Door's default.** Recommended: a new door starts with the `communications` rule ticked (DENY
   messages and mail), and everything else allowed. This also answers the Door design's open
   question.
4. **What a target is told.** Recommended: nothing; the app's Preview as shows what was hidden. The
   alternative is a `withheld` count in results.
5. **Where rules live.** Recommended: `garage.json`'s `access` section, synced to the database as
   sources are. The alternative is the database only, since a rule's phrase can itself be
   sensitive.

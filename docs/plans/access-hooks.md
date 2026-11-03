---
layout: default
title: Access hooks
description: The seams an extension needs to decide which search results each caller sees, whether the caller is the app, an MCP assistant or a remote client. Garage itself ships no policy, and with no extension installed nothing changes.
date: 2026-11-02
status: Proposed (design only, no code yet)
status_kind: proposed
---

# Access hooks

Every reader of the corpus sees all of it today. The app's Search page, each assistant registered
on the MCP page, and a remote client reaching `garage-mcp` all get the same results for the same
query. The only control is the egress rule, which keeps communications away from a model host that
is not on this Mac (`docs/privacy.md`). That rule decides where content may be *processed*. It does
not decide who may *read* it.

This plan adds **hooks, not a policy.** Garage learns to name the caller of every read, carries that
name to every read path, and asks a registered **access policy** what that caller may see. Garage
ships no policy. With none installed, every hook is a no-op, no SQL changes, and results are
exactly what they are today. An extension supplies the policy, including its rules, their
evaluation, its storage, its settings and its pages in the app.

Written against `next` at `71af3bd` on 2026-11-02. The schema runs to `018_fact_anchors.sql`.

## Goals

- **Name the caller** of every read: the app, and each MCP registration, proved by a token the
  registration carries, plus whatever a transport passes along about a remote client.
- **One extension point** for the policy, loaded the same way as the other seams an extension
  needs (config sections, SQL, gRPC services, egress destinations).
- **Every read path asks.** Search, document reads, listings, facts, the graph, `rag_ask` and
  `rag_agent` go through the hook. A test fails when a read path is added without it, as
  `test_egress_block.py` does for outbound clients.
- **Filtering before ranking.** The policy contributes a condition to the search's filter clause,
  so a filtered search still fills `limit`, rather than dropping hits after fusion.
- **Lifecycle events** that let a policy keep its own derived state current, such as a document
  replaced, chunks embedded, a document deleted, or a model changed.
- **Zero cost when unused.** With no policy registered, there is no extra predicate and no
  per-request work beyond building the caller object.

Not in scope: rules, matchers, rule storage, a rules UI, and any decision about what a caller may
see. Those belong to the extension. Nothing here makes a policy a security boundary against
software running as the same user (see [Callers](#callers)).

## The extension loader

There is no extension mechanism today. This plan adds a small one, which the access hooks use
first:

```toml
# an extension's pyproject.toml
[project.entry-points."garage_rag.extensions"]
enterprise = "garage_enterprise.extension:register"
```

`garage_rag/extensions.py` loads every `garage_rag.extensions` entry point once at start-up, in
name order. It calls each with a `Registry`, where the extension declares what it provides:

| Registry call | Used by |
|---|---|
| `register_access_policy(policy)` | This plan. At most one policy; a second registration is a start-up error, not a silent override |
| `register_config_section(section)` | `config/SECTIONS`, so the extension's settings are known keys and appear in the generated schema |
| `register_schema_dir(path)` | `db/migrate.py` applies it after `data/sql`, idempotently, as the rest is applied |
| `register_grpc_servicer(add_fn)` | `create_grpc_server` adds the extension's service beside `GarageService`, on the same socket and behind the same token |
| `register_egress_destinations(provider)` | `net/egress.py`. Already listed as an upstream seam in the Enterprise architecture, and not otherwise part of this plan |

Extensions load in-process, with the privileges of the process that loads them, so the loader adds
no attack surface beyond installing a package into Garage's Python. In the app, that Python is
the one bundled in `PythonXPCService.framework`, so only a build that bundles an extension has one.
`GARAGE_EXTENSIONS=0` turns the loader off for tests and support.

`test_egress_block.py` keeps holding: an extension that imports a network client fails the AST scan
like any other module in the site-packages the app bundles, unless it is listed.

## Callers

`garage_rag/access/caller.py` defines the value every read carries:

```python
@dataclass(frozen=True)
class Caller:
    kind: Literal["app", "cli", "mcp"]
    registration: Registration | None  # MCP: the registration its token proved, or None
    transport: Literal["grpc", "stdio", "http", "local"]
    attributes: Mapping[str, str]      # transport facts a policy may use; see below
```

Where each one comes from:

| Caller | `kind` / `registration` | Source |
|---|---|---|
| The app's pages (gRPC from the app) | `app` | The per-launch gRPC token (`GARAGE_GRPC_TOKEN`), which only the app has |
| `garage` on a terminal | `cli` | The process itself |
| An MCP assistant over stdio | `mcp` / its registration | The registration token in `GARAGE_MCP_TOKEN`, from the `env` block `McpInstall` writes into the assistant's config |
| An MCP assistant over HTTP | `mcp` / its registration | The same kind of token, as `Authorization: Bearer` on each request |
| `garage-mcp` with no token, or one that matches nothing | `mcp` / `None` | Hand-edited configs, older registrations, a revoked token |

### Registrations carry a token

The registration's token, not its name, decides who the caller is, and so which ACL a policy applies.

- **Minting.** `McpInstall` (the MCP page, the setup assistant, `garage mcp install`) mints a random
  token for each registration (`gmr_` and 32 random bytes, base64url). It writes the token into that
  assistant's config and stores only its SHA-256 in a new table, `mcp_registrations` (`id`, `name`,
  `client`, `transport`, `token_sha256`, `created_at`, `last_seen_at`; `019_mcp_registrations.sql`).
  The token is never logged, and never shown again after it is written.
- **Where it goes.** Over stdio it goes in the server entry's `env` block, not in `args`, so it does
  not show in `ps`. Over HTTP it goes in the entry's headers as a bearer token. One registration
  has one token, whichever transport it uses.
- **Checking.** `garage-mcp` hashes the token it was given, at start for stdio and on every request
  for HTTP, and looks it up. A match gives `Caller.registration`, and stamps `last_seen_at`. The
  comparison is constant-time.
- **Revoking.** Uninstall deletes the row, so a copied token stops working at once. The MCP page
  gets "Reset token", which mints a new one and rewrites the config. Update gives an older
  registration that has none a token.
- **With no policy installed,** a missing or unknown token is served exactly as today, so nothing
  breaks. With a policy installed, the policy decides what `registration = None` sees, and it
  should see little.
- **Other clients of the HTTP endpoint,** such as a tunnelling connector, get a registration of their
  own, minted the same way. Garage Door's connector is one.

`attributes` is where a transport passes facts without Garage interpreting them. The HTTP server
passes the request headers named by `policy.caller_headers()` and no others. That is how a
tunnelling connector on the Mac can tell a policy which remote client is calling. Garage does not
know or care what a door is. The policy honours such attributes only from registrations it trusts
to set them.

**What a token is worth.** It proves which registration a caller holds, not which program is
running. Software running as the same user can read an assistant's config file and present that
assistant's token. It can then get what that assistant gets, but it cannot pick another
registration's rights, and it can never become `app`. The alternative was a name passed as an
argument, which any process could set to anything. The token sits in a file the user's
assistant already trusts with its own secrets. A keychain cannot hold it instead, because the
assistant starts `garage-mcp` from its config with no way to unlock anything. `docs/privacy.md`
will say this plainly.

**Preview as.** gRPC read requests gain an optional `caller` field (a registration id, or `app`).
The server honours it only from the app's token, so the app can show what another caller would
get. From anyone else the field is refused with `PERMISSION_DENIED`.

## The access policy interface

```python
class AccessPolicy(Protocol):
    # Callers (registrations are authenticated by Garage before the policy sees them)
    def caller_headers(self) -> Collection[str]: ...

    # Reads
    def search_filter(self, session: Session, caller: Caller) -> SqlFilter | None: ...
    def visible_document_ids(self, session: Session, caller: Caller, ids: Sequence[int]) -> set[int]: ...

    # Lifecycle (in the same transaction as the change, unless noted)
    def on_document_replaced(self, session: Session, document_id: int) -> None: ...
    def on_document_deleted(self, session: Session, document_id: int) -> None: ...
    def on_chunks_embedded(self, session: Session, model_slug: str, chunk_ids: Sequence[int]) -> None: ...
    def on_models_changed(self, session: Session) -> None: ...       # after commit
```

`SqlFilter` is a SQL fragment over the aliases the search already uses (`d` for documents, `c` for
chunks, `s` for sources) plus its bind parameters, in their own namespace (`acl_*`), so they cannot
collide with the search's. `None` means no condition, and a policy returns it for a caller it does
not restrict, so that caller's query is today's query.

**Fail closed.** If a policy raises, the read fails with an error. It never falls back to returning
everything, and the error tells the caller nothing about the corpus.

`garage_rag/access/__init__.py` holds the registered policy and a `NullPolicy`, which allows
everything and is used when none is registered. Read paths call module functions
(`access.search_filter(session, caller)`, `access.visible(...)`), never the policy object directly,
so the null case stays one branch in one place.

## Where the hooks go

| Path | Hook |
|---|---|
| `search/hybrid.py:search` (CLI, gRPC `Search`, `rag_search`) | Takes `caller`. `_filter_clause` appends `search_filter`'s fragment inside both engines' CTEs, so it applies before fusion. `apply_search_tuning` sets `hnsw.iterative_scan = relaxed_order` when a filter is present, so the vector side keeps walking until the filtered candidates fill its depth |
| `rag_get_document`, gRPC `GetDocument` | `visible_document_ids` on the one id. A hidden document answers exactly as a missing one does ("no such document"), by id or by path |
| `ListDocuments`, `ListFacts`, `GetFactStats` | `search_filter` on the document join |
| `rag_list_sources`, `rag_list_authors`, `rag_stats`, `GetStats` | Counted with `search_filter` applied |
| `rag_ask`, `rag_agent` | Retrieval and every tool call the model makes carry the calling `Caller`; the model can draw only on what that caller may see |
| Graph (`GetGraphLabels`, `FindGraphVertices`, `GetGraphNeighborhood`) | `visible_document_ids` on each vertex's supporting documents; a vertex is shown with its visible support only |
| `ingest/gateway.py:replace_document`, document deletion | `on_document_replaced` / `on_document_deleted`, inside the document's transaction |
| `embed/ollama.py:store_vectors` (and the facade's `UpdateEmbeddings`) | `on_chunks_embedded`, inside the batch's transaction |
| Model register, drop, set default | `on_models_changed` |

`tests/test_access_paths.py` holds this table as data. It walks every `@mcp.tool()` and every
`GarageService` handler and fails on a read path that is not listed with its hook, and on a lifecycle
path that does not fire its event. A test policy that hides one document then runs every read path
and checks that the document appears nowhere: not in results, counts, facts, graph or answers.
`test_postgres.py` checks that a policy's fragment sits inside both CTEs on the `vector`, `halfvec`
and `hnsw_bq` paths, and that a filtered search still returns `limit` hits.

## In the app

The app gets two seams, both empty in this repository:

- **An extension section in the sidebar.** `AppSection` gains no new cases here. A Bazel label flag,
  `//macapp:extension_sections`, defaults to an empty library. A build that sets it links a module
  contributing extra `AppSection`-like entries and their views, under the existing groups. The
  unit test that holds the sidebar order runs over the built-in cases only.
- **Preview as** on the Search page appears only when the backend reports a policy
  (`GetStatus.access_policy`, the policy's name), and lists the callers the policy offers.

The MCP page mints a token for every registration, as described in
[Registrations carry a token](#registrations-carry-a-token), and shows "Reset token" beside each.
This happens whether or not a policy is installed, so a policy installed later can tell assistants
apart without re-registering them.

## Order of work

| Step | Contents |
|---|---|
| **H1** | `extensions.py` with the registry, `Caller`, `NullPolicy`, registration tokens (`mcp_registrations`, minting in `McpInstall`, checking in `garage-mcp`) and the `Caller` plumbing through MCP and gRPC |
| **H2** | `search_filter` and `visible_document_ids` on every read path, the path test and the hide-one-document test, plus the Postgres checks |
| **H3** | Lifecycle events, `register_schema_dir`, `register_config_section`, `register_grpc_servicer` |
| **H4** | The app's seams: the sidebar label flag, Preview as, and Reset token on the MCP page |

## Decisions to confirm

1. **Entry points** as the loading mechanism, rather than a list of module names in `garage.json`.
   Entry points mean only what is installed into Garage's Python can load, never something a config
   file names.
2. **One policy at most**, rather than several combined. Combining policies (all must allow) is
   easy to add later. Defining how two policies' SQL fragments and lifecycle state interact is not
   worth doing before there is a second policy.
3. **A token for every registration**, even with no policy installed. A missing or unknown token is
   still served as today until a policy says otherwise.

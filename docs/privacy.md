---
layout: default
title: Privacy and macOS Permissions
description: How Garage keeps your data on your computer, with one egress choke point, a destination allowlist, messages that never leave the machine, and the macOS permissions it asks for.
---

# Privacy and macOS permissions

## The guarantee

Garage sends content only to approved destinations: this machine, and the Ollama
or LM Studio server you configure. Communications never leave this machine.
There is no cloud AI client in the codebase.

Garage never uploads your files or its index. What leaves your computer depends on
which AI you connect:

- **A cloud assistant over MCP** (Claude, ChatGPT and the like), the usual
  setup. The assistant's app queries Garage's MCP server on this computer and
  receives only the relevant parts of the corpus: the excerpts its searches
  return and the documents it opens, never the whole index. Garage uploads
  nothing, but the assistant sends those parts to its provider's servers with
  your conversation, Messages and Mail excerpts included if you indexed them; see
  [What connected agents receive](#what-connected-agents-receive).
- **Fully private, on your computer.** With the built-in llama.cpp engine on a
  macOS, or LM Studio or Ollama on this computer, and an agent that runs its model locally,
  nothing leaves the machine.
- **Your own server on your network.** With `embedding.ollama_host` or
  `embedding.lmstudio_host` set to another machine, documents and code go to
  that server, and only that server, for embeddings, facts and answers.
  Communications never do (layer 4).

This is enforced structurally, in layers that are each tested on their own
(`rust/garage-embed`'s `egress` tests and the service's). Removing any one of them
fails the test suite.

### Layer 1 — one choke point

No crate of the pipeline opens an outbound connection itself. The embed worker
(`rust/garage-embed`) builds every model-server request (LM Studio, Ollama and
the app's `LlamaXPCService`: embeddings, fact extraction, answers, LM Studio model
management) and hands it to its host (`Host::http`) only after its `egress`
module has checked the destination; the fact distiller, the query embedder, the
MCP server's `rag_ask` and the `mcp-test` probe all go through that worker. The
hosts are the Mac app's XPC services (a `URLSession` with no proxy that returns
redirects instead of following them), the Windows app's `Garage.Services.exe`
(an `HttpClient`, likewise) and the `garage` command's own plain-HTTP host.

Image embedding models open no connection at all: the host of each helper
reaches the app's `GarageImageEmbedXPCService` over NSXPC, through the listener
endpoint the app hands the helper, and the pictures are embedded on this
machine's Neural Engine or GPU.

The pipeline's other connections are inbound or local: the gRPC server, the MCP
server's HTTP listener, and the backend's connection to Postgres over its socket.
The gRPC *client* of the app's facade (`garage-facade`) checks its address with the
guard (loopback only), unless it is given the app's socket.

### Layer 2 — no cloud AI SDK

No crate depends on a cloud AI SDK (`anthropic`, `openai`, `google.genai`,
`google.cloud`, `cohere`, `mistralai`, `boto3`, upstream `langextract` and the
like), and `rust/Cargo.lock` contains none. Neither an `openai` nor an `ollama`
crate is a dependency: LM Studio's and Ollama's HTTP APIs are a few JSON
routes, made by `garage-embed`'s providers and sent by the host.

There used to be an optional Claude vision fallback for OCR. It has been removed:
OCR is Tesseract only, on this machine, and the `cloud` settings section and the
per-source `allow_cloud_enrichment` flag are retired (an older config that still
has them loads with a warning).

### Layer 3 — the destination allowlist

`egress.check_destination` runs before any client is built. It approves:

- **loopback** — `localhost` or a literal loopback address (`127.0.0.0/8`,
  `::1`): the app's own `LlamaXPCService` on `embedding.llama_host` (default
  `http://127.0.0.1:8790`, and required to be loopback; in the app it is reached
  on its socket or over NSXPC instead, see "Garage's own endpoints" below), and
  Ollama or LM Studio running on this computer;
- **the configured model servers** — exactly the origins (scheme, host and port)
  of `embedding.ollama_host` and `embedding.lmstudio_host`, which may be another
  machine.

Anything else raises `EgressBlocked`. There is no setting that adds other hosts.
A host *name* other than `localhost` is never treated as loopback, even if it
resolves to loopback today, because a DNS answer can change; it is approved only
when it is the configured server.

The clients the guard builds ignore the environment's proxy variables and never
follow a redirect, and each one refuses a request addressed to any origin but the
one it was built for, so neither `http_proxy` nor a server's `Location` header
can send content elsewhere.

### Layer 4 — communications stay on this machine

Content classified `corpus_class = 'communication'` never goes to a destination
that is not loopback, even an approved one. The guard checks this before
anything else when the caller says what it is sending:

- **Facts** (`garage enrich-facts`) pass each document's class, so a message is
  never posted to an off-box Ollama or LM Studio; the refusal comes before the document's
  stored facts are touched.
- **Answers** (`rag_ask`) run every retrieved excerpt's class through the guard
  before building a prompt for an off-box Ollama or LM Studio, so a communication in the
  results aborts the call. `rag_agent`, where the model searches for itself, restricts
  its searches to documents and code and refuses to read a communication when the
  model host is not loopback, so the model never sees one.
- **Embeddings** — backfill, in-process or through the embed worker, asks
  `egress.allows_communications` and leaves chunks of communication documents
  out for a provider that is not on this machine. They stay unembedded for that
  model, and the backfill summary counts them as withheld
  (`test_embed_egress.py`).

### Layer 5 — local fact extraction

Only the local part of LangExtract is shipped: the Rust port `langextract-rs`
(which makes no requests and opens no files; the model it is given is its only way
out). Upstream chooses its backend by regex on the model name and would send a
`gemini-*` or `gpt-*` model id to Google or OpenAI; that routing and those
backends are not shipped, and the fact distiller refuses a cloud model id with a
clear error. Every extraction runs on Garage's own
provider, through the same loopback-only client.

### What these layers do not cover — MCP clients

The MCP server hands search results and document excerpts, communications
included, to whichever client is connected to it, and that client may send them
to its own model provider; see [What connected agents receive](#what-connected-agents-receive).
`rag_search` results carry each hit's `corpus_class` so a client can tell
communications apart, and a message's `direction` and `sender` (a phone number
or address, or `me`). Those two are communication metadata: they live on the
chunk in the local database, and like the message itself reach only an MCP
client that retrieves it.

### Outside the guard — the app's own downloads

GarageApp's Swift code makes three kinds of request that carry no corpus content
and so do not go through `net/egress.py`: it fetches
`https://garagerag.app/.data/models.json` at every launch (`ModelCatalog.refresh`),
downloads a model from Hugging Face when you pick one, and, in the Developer ID
build only, checks `https://garagerag.app/appcast.xml` for updates once you allow
Sparkle to. The [privacy policy](support/privacy-policy.html) lists them for users.

## macOS permissions (TCC)

Messages and Mail are protected by Transparency, Consent, and Control. Without
Full Disk Access:

```
$ sqlite3 ~/Library/Messages/chat.db .tables
Error: unable to open database: authorization denied

$ ls ~/Library/Mail
ls: Operation not permitted
```

The file *metadata* is visible, so a naive walker sees plausible files and fails
confusingly on every one. The pipeline detects this and reports it as a
permissions problem rather than a parse failure.

To grant: **System Settings → Privacy & Security → Full Disk Access**, and add
Garage (for the app's ingest) or your terminal (for `garage` run from it). Then
re-run — idempotency means nothing already indexed is re-done.

If you would rather not grant blanket access, copy `chat.db` (plus `-wal` and
`-shm`) to a working directory via Finder and register that copy as the source.
Narrower grant, more friction per refresh.

### Contacts

Messages and Mail know people by phone number or email address. To show names
instead, the app asks once for access to Contacts (`NSContactsUsageDescription`,
and the `com.apple.security.personal-information.addressbook` entitlement in both
builds) before its first ingest. The app, not the ingest service, reads the names
(`ContactNamesService`) and hands them to each ingest. They label the Messages
threads, sender lines and authors they match, stay in the corpus on this computer, and
never go to a model server beyond what communications already allow (layer 4).
Declining leaves every handle as it is. `defaults write me.rickmark.garage-rag
garage.contactNames.disabled -bool YES` turns the lookup off without revoking
the permission.

Names that iMessage contacts shared with you ("Share Name and Photo") fill in
for handles Contacts does not know. Garage reads them from
`~/Library/Messages/NickNameCache`, inside the Messages folder you already
granted, so they need no other permission.

## Cloud placeholders and network traffic

`~/Dropbox` here is ~99% online-only stubs. **Reading a stub asks Dropbox to
download it** — a naive walk would have quietly pulled ~230 GB.

`placeholders.materialize` controls this, and even when enabled, downloads are
capped per run by `placeholders.limit` and `placeholders.max_bytes`. Every run reports what it fetched and what it
deferred; nothing is silently truncated. A stub that is not downloaded gets no
document (the run counts it as a placeholder), and a file indexed before the sync
client evicted it is skipped without a download while its stat still matches.

## Dropbox sources

A Dropbox source (kind `dropbox`) reads the account through Dropbox's HTTP API instead of the
synced folder: Garage lists the folder, and downloads only a file that is new or whose size or
modification time changed. Content only comes in. The requests go to
`https://api.dropboxapi.com/2/` and `https://content.dropboxapi.com/2/` and nowhere else
(`garage-ingest`'s `dropbox::check_destination`, checked again by the host), and carry the source's
paths and listing cursors, never a document's text. A download is checked against Dropbox's content
hash and kept in memory only; nothing is written to disk but the index.

Garage holds no Dropbox account itself. The process that runs ingest hands over a short-lived
access token when asked: in the App Store build the node signs in to Dropbox itself, with Garage Door
only relaying Dropbox's answer sealed to that node, and keeps and refreshes the token on the node. Door
holds no token and never sees a file. A build with no token provider (this repository's own
builds, the CLI and the Windows app, so far) reports a Dropbox source as unavailable.

## OneDrive sources

A OneDrive source (kind `onedrive`, personal OneDrive or OneDrive for Business) reads the drive
through Microsoft Graph the same way: Garage lists the folder child by child, skipping the folders
the walker would skip without listing them, and downloads only a file that is new or changed. The
signed requests go to `https://graph.microsoft.com/v1.0/me/drive/` (and `/v1.0/drives/` for Graph's
next-page links) and nowhere else (`garage-ingest`'s `onedrive::check_destination`, checked again by
the host). Graph answers a download with a redirect to a pre-authenticated URL on Microsoft's content
hosts (`*.sharepoint.com`, `*.1drv.com`, `*.livefilestore.com`, `*.microsoftpersonalcontent.com`);
the host never follows it, and Garage fetches that URL itself, after the same check, without the
access token. A download is checked against OneDrive's QuickXorHash and kept in memory only. The
token comes from the process that runs ingest, as for Dropbox: in the App Store build the node links
its Microsoft account through Garage Door, which only relays Microsoft's answer sealed to that node.

## Outlook sources

An Outlook source (kind `outlook`, an Outlook.com or Microsoft 365 mailbox) reads mail through
Microsoft Graph with the same Microsoft account. Garage lists the folder the source names and every
folder below it (the whole mailbox but Deleted Items, Junk Email, Drafts and the Outbox for `/`), and
downloads only a message that is new or changed, as its MIME, into memory. The signed requests go to
`https://graph.microsoft.com/v1.0/me/mailFolders` and `/v1.0/me/messages/` and nowhere else
(`garage-ingest`'s `outlook::check_destination`, checked again by the host); every one is a `GET`, so
Garage never sends, moves or deletes mail. Each message is read by the mail reader and filed as a
`communication`, so, like an `.eml` on disk, it never goes to a model server that is not on this
computer.

## Garage's own endpoints

The app's pieces talk to each other on this computer: the backend to Postgres,
the app and its workers to the `GarageService` gRPC facade, and the `llama_xpc`
provider to `LlamaXPCService`. A loopback TCP port is reachable by every process
of every account on the computer, so none of these listen on one:

- **Unix-domain sockets in an owner-only folder.** Postgres, gRPC and the
  llama-server API listen in `s/` at the root of the App Group container
  (`~/Library/Group Containers/DWVXMLB45Y.group.me.rickmark.garage-rag/s`, mode
  0700): `.s.PGSQL.14824`, `grpc` and `llama`. Only this account's processes
  can open them, and in the App Sandbox only processes entitled to the group
  (the app, its XPC services and the `garage` / `garage-mcp` launchers). Postgres
  still asks for its password (SCRAM), which lives in the group's Keychain.
  A socket path must fit in 104 bytes; for a user name long enough to overflow
  that, the affected endpoint falls back to its loopback port as before
  (`GarageSockets`).
- **Configuration changes need a vouched-for caller.** The gRPC methods that
  write `garage.json` or an MCP client's config (`SetSetting`, the source and
  model methods, `McpInstall`/`McpUninstall`), and `InitDb`, which runs the SQL
  of a caller-named `schema_dir`, run only for a caller presenting
  the app's per-launch token or arriving over that owner-only socket. A server
  on a loopback TCP port with no token refuses them, so no other account on
  the computer can point `embedding.ollama_host` off-box and widen the allowlist.
- **XPC peers must share the team.** Each XPC service puts a code-signing
  requirement on its connections (`anchor apple generic and certificate
  leaf[subject.OU]` = the team in its own signature), so only the app, its
  other services and the launchers can call it. Ad-hoc and locally signed
  builds have no team, and skip the check.
- **Inference over NSXPC inside the app.** The XPC services send `llama_xpc`
  requests straight over their NSXPC connection to `LlamaXPCService` (the embed
  worker's Swift host); the llama-server socket is for the launchers and a
  `garage` run from a terminal.

`GARAGE_LLAMA_HTTP_PORT` puts `LlamaXPCService` back on a loopback port, for
debugging with tools that cannot use a socket.

## Serving over HTTP

The MCP server has **no authentication**. Over stdio that is fine: the client
spawns it as a child process and nothing else can reach it. Over HTTP it is the
whole security model, so three defences apply.

**Loopback by default.** `mcp.host` is `127.0.0.1`. Binding anything else requires
`--allow-remote`, and the refusal explains why rather than just erroring:

```
$ garage mcp-serve --http --host 0.0.0.0
refusing to bind 0.0.0.0: this server has no authentication and exposes your
entire corpus, including anything indexed from private communications.
```

**DNS-rebinding protection, on by default.** Without it, a page you visit could
resolve its own hostname to `127.0.0.1` and POST to your loopback server from
your browser — reading your corpus without ever touching the network perimeter.
The `Host` allowlist blocks it:

```
$ curl -H 'Host: evil.example.com' http://127.0.0.1:8787/mcp   # 421
$ curl -H 'Host: 127.0.0.1:8787'   http://127.0.0.1:8787/mcp   # 200
```

Browser clients additionally need their origin allowed explicitly, with
`--allow-origin https://example.com`.

The check stays on for loopback. Under `--allow-remote` the server cannot know which
host names reach it, so the check is off unless you list them with `--allow-host`.

**No transport-level encryption.** Plain HTTP. Fine over loopback; if you expose
it, terminate TLS and authenticate at a reverse proxy. Do not put this on a
network you do not control.

## What connected agents receive

The MCP server answers whichever client you connect: Claude Desktop, Claude
Code, Cursor, or anything else you register. An agent receives the excerpts its
searches return (`rag_search`, `rag_get_document`, and the answers from `rag_ask` /
`rag_agent` / `rag_generate`), only those, not the whole index. Most agents run their model in
the cloud, so they send those excerpts, with your conversation, to their model
provider. That includes excerpts from Messages and Mail if you have indexed
them: the MCP tools serve communications like any other content, and the egress
guard above governs what Garage itself sends, not what a client does next.

Each client entry Garage writes carries a registration token (`GARAGE_MCP_TOKEN`
in a stdio entry, a bearer header in an HTTP one), and only its SHA-256 is kept in
the database. A build with an access policy uses it to tell assistants apart. The
token proves which registration a reader holds, not which program is running:
software that runs as you can read an assistant's config file and present that
assistant's token, and so read what that assistant may read, but never what the
app may, and uninstalling the entry revokes the token at once.

What happens to an excerpt after an agent receives it is governed by that
agent's terms and privacy policy, not Garage's. If an indexed source should not
reach a cloud model, do not connect a cloud-hosted agent, or leave that source
out of the index.

## What is stored, and where

Everything stays in your local Postgres database (`garage-rag` in the app's
bundled cluster, in its data folder): extracted text in
`documents.content`, chunk text in `chunks.text`, vectors in `emb_*`. No content
leaves the machine except to the model servers you configure (communications
never do), or through an MCP client or `--allow-remote`, described above.

The database is unencrypted at rest, as Postgres normally is. If you index
private communications, the database file is as sensitive as the messages
themselves — consider FileVault (on by default on recent macOS) and treat
`pg_dump` output accordingly.

The Mac app also puts each document's title and path, and each distilled fact's
statement, into the Mac's own Spotlight index (Core Spotlight, in the app's
container on this Mac), so a Spotlight search finds them. No document text goes
there, and communications (mail, Messages) are never added. The Database page's
Spotlight switch turns it off and takes every Garage item out of Spotlight;
"Reset Database" empties it too.

On the Mac, a document type Garage has no reader for (`.rtf`, `.doc`, `.odt`,
...) is read by the system's own Spotlight importer for it, loaded into the
ingest's process from `/System/Library/Spotlight` (`extraction.spotlight`). The
importer reads the file on this machine and sends nothing anywhere; only Apple's
importers are loaded, never a third party's.

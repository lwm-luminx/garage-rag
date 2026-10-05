---
layout: default
title: Troubleshooting & Diagnostics
description: Resolutions for common issues, error codes, PostgreSQL startup failures, and permission problems in Garage.
redirect_from:
  - /troubleshooting.html
---

# Troubleshooting & Diagnostics

This guide provides step-by-step diagnostic procedures and solutions for common issues encountered when using Garage.

---

## Quick Diagnostic Matrix

| Symptom / Error | Probable Cause | Quick Fix |
|---|---|---|
| `authorization denied` or `Operation not permitted` | Missing macOS Full Disk Access for Messages or Mail | [Grant Full Disk Access](#tcc-permissions) |
| `FATAL: lock file "postmaster.pid" already exists` | Orphaned lock file after system crash | [Clear PID Lock File](#postgres-pid-lock) |
| `FATAL: postmaster became multithreaded during startup` | Locale initialization spawning threads | [Set `LC_ALL=C`](#postgres-multithreaded) |
| `connection refused` on `localhost:14824` | PostgreSQL service not running or port occupied | [Restart Postgres Service](#postgres-port-issues) |
| `cannot reach … at http://127.0.0.1:8790` | Garage (and its built-in model engine) not running | [Start the model server](#provider-connection-refused) |
| `HTTP 421 Misdirected Request` on MCP server | DNS rebinding protection triggered | [Check Host Header](#mcp-dns-rebinding) |
| `Vector dimension mismatch` on backfill | Registered model dimension differs from provider | [Verify Model Dimensions](#vector-dimensions) |
| Large unexpected network downloads | Cloud stubs (Dropbox/iCloud) being read | [Configure Placeholder Limits](#cloud-placeholders) |

---

<h2 id="postgres-issues">1. PostgreSQL Service Issues</h2>

<h3 id="postgres-port-issues">Port 14824 Unavailable</h3>

**Symptom**: GarageApp indicates database error or CLI fails with:
`psycopg.OperationalError: connection failed: … port 14824 failed: Connection refused`

**Solution**:
1. Check if another instance or zombie process is using port 14824:
   ```bash
   lsof -i :14824
   ```
2. If a stale postgres process exists, stop it:
   ```bash
   kill -TERM <PID>
   ```
3. In `GarageApp`, open the **Database** page and click **Start** (or **Restart**). Postgres's own output is at the bottom of that page.

<h3 id="postgres-pid-lock">Orphaned <code>postmaster.pid</code> File</h3>

**Symptom**: PostgreSQL log reports `lock file "postmaster.pid" already exists` and server does not start after a macOS crash or forced shutdown.

**Solution**:
Verify no postgres processes are active, then remove the stale lock file:
```bash
rm -f ~/Library/Group\ Containers/DWVXMLB45Y.group.me.rickmark.garage-rag/Library/Application\ Support/GarageApp/pgdata/postmaster.pid
```

<h3 id="postgres-multithreaded">Multithreaded Startup Error</h3>

**Symptom**: Log contains `FATAL: postmaster became multithreaded during startup`.

**Cause**: Custom macOS locale settings can spawn auxiliary threads during runtime initialization before postgres fork safety validation.

**Solution**: Ensure `LC_ALL=C` is exported in the environment before launching postgres (handled automatically by `GarageApp`).

<h3 id="starting-over">Starting over with an empty database</h3>

**Database → Reset Database…** deletes everything Garage built from your files and nothing else:
- **Deleted:** the search index (documents, chunks and embeddings), facts, the conversation memory
  imported from Messages and Mail, and the source, model, author and ingest records.
- **Kept:** your original files, downloaded model files, logs, `garage.json` and the Keychain password.

Garage stops its services, deletes the database folder and relaunches into the setup assistant. Its
first page creates the new database and registers the sources in `garage.json` again; the next pages
let you add sources, choose embedding models and connect your agents. **Skip setup** finishes the
reset without the assistant and leaves you on the Status page to set things up yourself. Either way,
run ingest afterwards to rebuild the index.

To keep a way back, press **Back Up First…** in the confirmation sheet before resetting. It saves the
same dump as **Back Up…**, and **Restore…** on the Database page loads it into the new database.

---

<h2 id="tcc-permissions">2. macOS Permissions (TCC) & Protected Files</h2>

<h3 id="authorization-denied"><code>authorization denied</code> on <code>chat.db</code> or <code>~/Library/Mail</code></h3>

**Symptom**: Ingestion log reports permission failure reading SMS / iMessage or Apple Mail databases.

```
sqlite3: unable to open database ~/Library/Messages/chat.db: authorization denied
```

**Solution**:
1. Open **System Settings → Privacy & Security → Full Disk Access**.
2. Click the lock/add icon and ensure both **Garage** and your terminal emulator (e.g. **Terminal**, **iTerm2**, or **Ghostty**) are added with toggle enabled.
3. If permissions were changed while the app was running, quit and re-launch Garage.

**App Store version**: it runs in the macOS sandbox and can read only the folders you choose. It asks with the standard Open dialog when you add a source, or when it needs your home folder (**Select Home Folder…** at the top of the Sources page; **Select Startup Disk…** beside it covers other disks). For Messages and Mail, choose the folder and also grant Full Disk Access as above.

---

<h2 id="embedding-issues">3. Embedding Models & Providers</h2>

<h3 id="provider-connection-refused">Model Server Connection Refused</h3>

**Symptom**: `garage backfill`, `garage enrich-facts` or a search fails with `cannot reach <server> at <URL>`.

**Solution**:
- **Built-in engine** (`llama_xpc`, port `8790`): it runs inside Garage, so open Garage. If the error names a model that is not loaded, load it on the **Models** page; one that is not downloaded is named with where to download it.
- **Ollama**: Verify Ollama is running (`ollama list`). Start Ollama via `ollama serve` or open the Ollama desktop app.
- **LM Studio**: Open LM Studio, select the **Developer** tab, and click **Start Server** on port `1234`.

<h3 id="vector-dimensions">Vector Dimension Mismatch</h3>

**Symptom**: PostgreSQL error `different vector dimensions` during backfill.

**Cause**: Each embedding table `emb_<slug>` is strictly typed to its model's vector dimensions (e.g., 1024 for `bge-m3`, 768 for `nomic-embed-text`).

**Solution**:
Inspect your registered model settings:
```bash
garage list-models
```
If registered incorrectly, drop the model (this discards its vectors) and re-register it with the right width, then backfill:
```bash
garage drop-model <model-name> --yes
garage register-model <model-name> --provider ollama --dims <correct-dims>
garage backfill --model <model-name>
```

---

<h2 id="mcp-issues">4. Model Context Protocol (MCP)</h2>

<h3 id="mcp-dns-rebinding">HTTP 421 Misdirected Request</h3>

**Symptom**: Browser or custom client receives `421 Misdirected Request` when connecting to `http://127.0.0.1:8787/mcp`.

**Cause**: On a loopback bind the MCP HTTP server checks the `Host` header (DNS rebinding protection). Requests must send `127.0.0.1:8787` or `localhost:8787`.

**Solution**:
Ensure your client sends `Host: 127.0.0.1:8787`. If accessing from a web application, specify `--allow-origin <origin>`. When serving remotely (`--allow-remote`), pass each name clients will use with `--allow-host <host:port>` (or `<host>:*`); with no `--allow-host` the `Host` check is switched off and a warning is logged.

<h3 id="claude-desktop-not-detecting">Claude Desktop Not Detecting Tools</h3>

**Symptom**: Claude Desktop starts, but the `rag_search` or `rag_get_document` tools are missing.

**Solution**:
1. Check `~/Library/Application Support/Claude/claude_desktop_config.json`.
2. Confirm the `garage-rag` entry exists: the command `/Applications/Garage.app/Contents/MacOS/garage-mcp` (the default, which starts Garage when needed) or, if you turned on the HTTP server, the URL `http://127.0.0.1:8787/mcp`, which needs Garage running. The **MCP Server** page shows each assistant as Connected, or offers **Update** when its entry points at an old address.
3. Re-install using:
   ```bash
   garage mcp-install --target claude-desktop
   ```
4. Completely quit Claude Desktop (Cmd+Q) and reopen it.

---

<h2 id="cloud-placeholders">5. Cloud Placeholders & Online Files</h2>

<h3 id="dropbox-icloud-mass-downloads">Unintended Downloads of Online-Only Files</h3>

**Symptom**: Ingestion takes a long time and starts downloading large quantities of cloud files from Dropbox or iCloud Drive.

**Solution**:
Garage meters cloud stub materialization. In `~/.garage.json`, adjust placeholder materialization settings:
```json
{
  "placeholders": {
    "materialize": false,
    "limit": 50,
    "max_bytes": 104857600
  }
}
```
Setting `"materialize": false` means online-only placeholders are never downloaded: they are counted as placeholders and get no document until their contents are on your computer. A file that was indexed before the sync client made it online-only keeps its index entry and is skipped without a download while it stays unchanged. With materialization on, `limit` (files) and `max_bytes` cap what one run downloads; `0` means unlimited. In the app these settings live in `garage.json` in its data folder.

---

<h2 id="inspecting-logs">6. Inspecting Diagnostic Logs</h2>

When diagnosing issues, the **Logs** page shows every log live: Unified Log, Postgres, App, Ingest, Embed, MCP Server, Index Manager, Built-in Engine and Downloader. Postgres's output is also at the bottom of the **Database** page.

The helper services also write log files, in `~/Library/Logs/Garage/` for the direct-download (Developer ID) build. The App Store build is sandboxed, so each helper writes to `Data/Library/Logs/Garage/` inside its own container, `~/Library/Containers/me.rickmark.garage-rag.<helper>/` (for example `me.rickmark.garage-rag.ingest-xpc` for `ingest-xpc.log`, and `me.rickmark.garage-rag.xpc` for `garage-xpc.log`):

- **Ingestion**: `ingest-xpc.log`
- **Embedding**: `embed-xpc.log`
- **MCP Server**: `mcp-server-xpc.log`
- **Index Manager** (search, embedding, facts): `garage-xpc.log`
- **Built-in model engine**: `llama-xpc.log`
- **Model downloads**: `model-download-xpc.log`
- **Image embeddings** (Core ML image models): `image-embed-xpc.log`

A helper that crashed leaves `<service>-crash.log` beside them.

<div class="callout callout-info">
  <div class="callout-title">Need to Submit Logs for Support?</div>
  <p>The quickest route is <strong>Report a Bug</strong> in GarageApp's <strong>Logs</strong> view (also under <strong>Help &rarr; Report a Bug&hellip;</strong>). It attaches the recent log lines along with version and service state, redacts your home directory, user name, e-mail addresses and secrets, and shows you the finished report before anything leaves your Mac.</p>
  <p>If you would rather paste log snippets by hand, read our <a href="{{ '/support/contact.html' | relative_url }}">Contact &amp; Log Sanitization Guide</a> first to ensure your personal notes or confidential documents are removed.</p>
</div>

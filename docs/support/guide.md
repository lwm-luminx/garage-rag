---
layout: default
title: Support & User Guide
description: Complete user and support guide for Garage macOS App, CLI, ingestion pipelines, and MCP integration.
redirect_from:
  - /support.html
---

# Garage Support & User Guide

Welcome to the comprehensive support guide for **Garage**. This guide covers system requirements, installation, source management, model configuration, MCP server integrations, and database operations. It describes Garage 1.5.

---

## Table of Contents
1. [System Requirements](#system-requirements)
2. [Getting Started](#getting-started)
   - [Native macOS Application (GarageApp)](#native-macos-application)
   - [The App's Pages](#app-pages)
   - [Command Line Interface (CLI)](#command-line-interface)
3. [Managing Sources & Ingestion](#managing-sources--ingestion)
   - [Corpus Classes & Trust Tiers](#corpus-classes--trust-tiers)
   - [Adding Folders, Repositories, and Mail/Messages](#adding-sources)
   - [Keeping the Index Up to Date](#keeping-up-to-date)
4. [Embedding Models & Providers](#models-and-embeddings)
   - [The Built-in Engine](#built-in-engine)
   - [Ollama Configuration](#ollama-configuration)
   - [LM Studio Configuration & Keychain Tokens](#lm-studio-configuration)
   - [Fact Distillation](#fact-distillation)
5. [Model Context Protocol (MCP) Integration](#mcp-integration)
   - [Claude Desktop Integration](#claude-desktop-integration)
   - [Claude Code Integration](#claude-code-integration)
   - [HTTP MCP Endpoint](#http-mcp-endpoint)
6. [macOS Permissions & TCC](#macos-permissions)
7. [Database Backup, Restore & Reset](#database-management)

---

<h2 id="system-requirements">1. System Requirements</h2>

- **Operating System**: macOS 14.0 (Sonoma) or later
- **Architecture**: Apple Silicon (M1 and later) only
- **Memory**: 8 GB RAM minimum (16 GB+ recommended when running local embedding models)
- **Disk Space**: ~500 MB for Garage application and embedded PostgreSQL, plus the models you download; database size depends on ingested document corpus
- **Embedding Backend**: none to install. Garage runs embedding and distillation models itself with its built-in llama.cpp engine; [Ollama](https://ollama.com/) or [LM Studio](https://lmstudio.ai/) can be used instead

---

<h2 id="getting-started">2. Getting Started</h2>

<h3 id="native-macos-application">Native macOS Application (<code>GarageApp</code>)</h3>

Get Garage from the [Mac App Store](https://apps.apple.com/app/id6811306880), or download the signed and notarized installer from the [download page]({{ '/#download' | relative_url }}). Both versions share one library (the same data folder), so switching between them needs no re-indexing. The installer version updates itself through **Check for Updates…** after asking you once; the App Store version gets its updates from the App Store instead.

`GarageApp` provides a menu bar utility and management window that bundles an embedded, relocatable instance of PostgreSQL 18 with `pgvector`:

1. **Launch GarageApp**: The app initializes its private database in `~/Library/Group Containers/DWVXMLB45Y.group.me.rickmark.garage-rag/Library/Application Support/GarageApp/pgdata` on port `14824`. A strong SCRAM superuser password is automatically generated and securely stored in your **macOS Keychain**.
2. **Setup Assistant**: On first launch the window opens on a four-page assistant: it waits for the database and services, lets you pick sources (Documents, Desktop, Downloads, iCloud Drive, Dropbox, `~/Developer`, Messages, Mail, or any folder), an embedding model and an optional fact-distillation model, and connects the AI assistants it finds (Claude Desktop, Claude Code, Cursor, …). Every page can be skipped, and **Garage → Setup Assistant…** runs it again.
3. **Menu Bar**: The Garage icon in the menu bar opens a popover with a search field, one row for the services ("All systems go" when everything is up), and what the pipeline is doing, with **Ingest Now** or **Stop**. Its header opens the main window (⌘O) or quits Garage (⌘Q).

<h3 id="app-pages">The App's Pages</h3>

The sidebar starts with **Status**, followed by three groups:

- **Status** — the page to check first.
  - **Health** reads "All systems go", or lists each problem (the database stopped or needing a schema update, the MCP server down, missing disk access, a source that can't be read, no sources or embedding model yet) with the button that fixes it and a link to its page.
  - **Library** shows how much of your library is read, indexed and gleaned for facts, with **Update Everything** or **Stop**; while it updates it shows the current stage and the Scan › Read › Index › Glean trail. Below it are the source, document, chunk, indexed and fact figures.
  - **Index Manager** shows the background service that runs search and indexing jobs, and what it is doing. **Helper Services** lists every helper process (Built-in Engine runs the models Garage hosts itself) with **Test**, **Restart** and a chevron for its status report, self tests and crash report. **Service Output**, folded at the bottom, holds their log.
- **Configuration**
  - **Sources** — one row per source with its state ("24 items to go", "Up to date", "Needs permission to read this folder") and **Scan & Ingest**, which turns into **Cancel** while the source is queued or running. Anything that cannot be read is listed at the top with the button that fixes it. New sources come from location cards, **Add Folder…** or **Custom Source…**.
  - **Models** — three tabs. **Overall** says whether search is ready and which distillation model is set. **Embedding** lists your embedding models and the presets you can add. **Distillation** picks the fact model and edits the fact prompts. The Providers box's **Built-in engine** row lists the models the built-in engine has loaded, each with **Unload**.
  - **MCP Server** — whether the local server is up, the assistants connected to it (**Connect**, **Update**, **Disconnect**), and **Try It** to call the tools the way an assistant does.
- **Data** — **Documents**, **Facts** and **Search** browse and query what has been indexed.
- **Advanced**
  - **Database** — Postgres status (Start, Restart, Stop), the connection URL, schema updates, corpus counts and size on disk, backups and reset.
  - **Logs** — live logs, one tab each: Unified Log, Postgres, App, Ingest, Embed, MCP Server, Index Manager, Built-in Engine and Downloader, with **Report a Bug**.

<h3 id="command-line-interface">Command Line Interface (<code>garage</code>)</h3>

For automated pipelines or terminal workflows, the `garage` CLI communicates with the database. The app includes it at `/Applications/Garage.app/Contents/MacOS/garage` (with `garage-mcp` beside it); when a command needs the database and Garage is not running, it opens the app in the background and uses its database, with no password to configure. The same commands ship in the `garage_rag` Python package for use against any PostgreSQL with pgvector.

```bash
# Put the launchers on your PATH (optional). The copies find Garage wherever it is installed.
sudo mkdir -p /usr/local/bin
sudo cp /Applications/Garage.app/Contents/Resources/launchers/garage \
        /Applications/Garage.app/Contents/Resources/launchers/garage-mcp /usr/local/bin/

# Write a configuration file with every setting at its default (./garage.json; --user for ~/.garage.json)
garage config init

# Apply the schema and pgvector extension (the app does this itself)
garage init-db

# Check status and document count
garage stats
```

`garage` reads `./garage.json`, then `~/.garage.json`, or the file named with `--config`. The app keeps its own settings in `garage.json` in its data folder, next to `pgdata`.

---

<h2 id="managing-sources--ingestion">3. Managing Sources & Ingestion</h2>

Garage indexes your local files, codebases, notes, and messages into a unified vector corpus.

### Corpus Classes & Trust Tiers

Every source is categorized to protect privacy and enable precise retrieval filtering:

- **Corpus Classes**:
  - `document`: Prose documents, research papers, reports, notes (`.md`, `.pdf`, `.docx`, `.pptx`, `.xlsx`, OCR images).
  - `code`: Source code repositories and structured configuration files (`.json`, `.yaml`, `.toml`, `.py`, `.swift`, `.ts`, etc.).
  - `communication`: Personal conversations (Apple Messages, Apple Mail and `.eml` files). **Enforced strictly with zero cloud egress**.
- **Trust Tiers**:
  - `authored`: Content written by you (verified via Git commit authorship or your identity profiles).
  - `reference`: External material you collected (papers, vendored packages, documentation).
  - `received`: Inbound communications sent by other parties.

<h3 id="adding-sources">Adding Sources</h3>

In the app, open **Sources** and click a location card, **Add Folder…**, or **Custom Source…** for another kind of source or its own class and trust. From the terminal:

```bash
# Add a personal notes directory as authored content
garage add-source notes ~/Documents/Notes --class document --trust authored

# Add a Git repository (authorship is detected per-commit automatically)
garage add-source my-repo ~/Projects/my-repo --kind git --class code

# Add Apple Messages and Apple Mail (require Full Disk Access)
garage add-source apple-sms ~/Library/Messages --kind sqlite --class communication --trust received
garage add-source apple-mail ~/Library/Mail --kind maildir --class communication --trust received

# Run ingestion to parse files into text chunks
garage ingest
```

Ingest is safe to re-run. Unchanged files are skipped without being read, a file with no text (empty, or an image with no words in it) is remembered and not read again until it changes, and when a document does change only its changed chunks are embedded again.

<h3 id="keeping-up-to-date">Keeping the Index Up to Date</h3>

- **Update Everything** on the Sources page scans and ingests every source, embeds the new chunks with every model, then gleans facts from documents that have not been distilled yet. **Stop** ends it at the current step.
- **Automatic Updates** on the same page scans, ingests and embeds on a schedule, and optionally once when Garage starts.
- From the terminal: `garage scan`, `garage ingest`, `garage backfill`, then `garage enrich-facts --stale-only`.

---

<h2 id="models-and-embeddings">4. Embedding Models & Providers</h2>

Garage supports multiple embedding models simultaneously without re-parsing raw files.

<h3 id="built-in-engine">The Built-in Engine</h3>

Garage runs GGUF models itself with llama.cpp (provider `llama_xpc`, Metal-accelerated, on `127.0.0.1` only). Pick a preset in the setup assistant or on **Models → Embedding** and Garage downloads it from Hugging Face. The default embedding model is loaded when Garage starts, so searches are answered at once; the distillation model is loaded only while facts are being gleaned. The built-in engine is available while Garage is running.

### Ollama Configuration

1. Install and start [Ollama](https://ollama.com/):
   ```bash
   ollama pull bge-m3
   ```
2. Register and set `bge-m3` as the default model:
   ```bash
   garage register-model bge-m3 --provider ollama --dims 1024
   garage set-default-model bge-m3
   ```
3. Generate vector embeddings for all indexed chunks:
   ```bash
   garage backfill
   ```

### LM Studio Configuration

1. In LM Studio, load an embedding model (e.g., `nomic-ai/nomic-embed-text-v1.5-GGUF`) and start the local server on `http://127.0.0.1:1234`.
2. In `GarageApp`, the **Models** page's Providers box can store your LM Studio API token in the macOS Keychain.
3. Via CLI:
   ```bash
   garage register-model nomic-embed-text --provider lmstudio --dims 768
   garage backfill
   ```

<h3 id="fact-distillation">Fact Distillation</h3>

Garage can distill each document into short, self-contained facts, each tied to the passage it came from and searchable like any other text. Pick a model on **Models → Distillation** and click **Glean Facts**, or run `garage enrich-facts`. What the model is asked for comes from the fact prompts (`facts.prompts` in `garage.json`, editable on the same tab); the built-in `default` prompt asks for every standalone claim. Distillation runs on a local model only, and messages are never sent to a model server on another machine.

---

<h2 id="mcp-integration">5. Model Context Protocol (MCP) Integration</h2>

Garage implements the **Model Context Protocol (MCP) 2.0**, allowing AI assistants to query your local knowledge base with `rag_search`, `rag_get_document`, `rag_list_sources`, `rag_list_authors`, `rag_stats`, `rag_ask` and `rag_generate`.

The easiest way to connect an assistant is the **MCP Server** page: each assistant Garage finds has a **Connect** button.

### Claude Desktop Integration

Install the Garage MCP tool directly into your Claude Desktop configuration:

```bash
garage mcp-install --target claude-desktop
```

This adds a `garage-rag` entry to `~/Library/Application Support/Claude/claude_desktop_config.json` pointing at Garage's HTTP server (`http://127.0.0.1:8787/mcp`), keeping every other entry. With `--stdio` it registers the bundled `garage-mcp` command instead, which Claude Desktop starts itself; either way the config carries no database password. Restart Claude Desktop to start searching your notes and code directly from Claude!

### Claude Code Integration

Register Garage with Claude Code:

```bash
garage mcp-install --target claude-code-user
```

### HTTP MCP Endpoint

`GarageApp` automatically hosts a loopback HTTP MCP server at:
`http://127.0.0.1:8787/mcp`

<div class="callout callout-info">
  <div class="callout-title">🔒 Security Notice</div>
  <p>By default the HTTP MCP server binds only to <code>127.0.0.1</code> and refuses remote clients, with DNS-rebinding protection and Host validation. Serving other computers takes an explicit opt-in for power users, <code>--allow-remote</code>; then add <code>--allow-host</code> for each name clients use, since with no <code>--allow-host</code> the Host check is off.</p>
</div>

---

<h2 id="macos-permissions">6. macOS Permissions & TCC</h2>

When indexing Apple Messages (`~/Library/Messages`) or Apple Mail (`~/Library/Mail`), macOS Transparency, Consent, and Control (TCC) requires explicit permission.

### Granting Full Disk Access

1. Open **System Settings** on your Mac.
2. Navigate to **Privacy & Security → Full Disk Access**.
3. Click the **+** button and add **Garage** (or your **Terminal** app if running via CLI).
4. Toggle the switch to **On**.
5. Restart Garage or run `garage ingest` again.

The Sources page lists a source it cannot read at the top, with a button to grant access.

### App Store version

The App Store version runs in the macOS sandbox and can read only the folders you choose. It asks with the standard Open dialog when you add a source, or when it needs the disk (**Select Disk…** at the top of the Sources page, **Select Startup Disk…** in the setup assistant). For Messages and Mail, choose the folder and also turn on Full Disk Access as above.

---

<h2 id="database-management">7. Database Backup, Restore & Reset</h2>

### Backup & Restore
- **In GarageApp**: Open the **Database** page and click **Back Up…** to save a PostgreSQL custom-format snapshot (`.dump`). **Restore…** replaces the database with a backup, after asking.
- **Via CLI**: copy the connection URL from the **Database** page (the copy button includes the password) and use the `pg_dump` bundled with the app:
  ```bash
  /Applications/Garage.app/Contents/Resources/postgres/bin/pg_dump -Fc -d "<connection URL>" -f ~/Desktop/garage_backup.dump
  ```

### Reset
**Database → Reset Database…** deletes the database and relaunches Garage into the setup assistant, which creates a new, empty one. Your original files, downloaded models, logs and `garage.json` are kept. See [Starting over with an empty database]({{ '/support/troubleshooting.html' | relative_url }}#starting-over) for details.

---

<div class="callout callout-success">
  <div class="callout-title">Need additional assistance?</div>
  <p>If you encounter unexpected errors or need further diagnosis, check out the <a href="{{ '/support/troubleshooting.html' | relative_url }}">Troubleshooting Guide</a> or <a href="{{ '/support/contact.html' | relative_url }}">open an issue on GitHub</a>.</p>
</div>

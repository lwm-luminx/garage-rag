---
layout: default
title: Run Garage on Linux
description: How to run Garage on Linux from the command line, with PostgreSQL and pgvector, Ollama or LM Studio for embeddings, and the garage-mcp server for your AI assistant.
---

<div class="hero">
  <h1>Run Garage on Linux</h1>
  <p>Garage has no desktop app for Linux, but the whole pipeline runs there. You get the <code>garage</code> command for indexing and search and the <code>garage-mcp</code> server for your AI assistant, over a PostgreSQL database you run yourself.</p>
</div>

## What you get, and what you don't

The Linux version is the same `garage_rag` Python package the Mac app runs inside. CI tests it on Linux on every push, against a real PostgreSQL with pgvector.

- **Included:** indexing folders and git repositories; Markdown, PDF, Office documents, code and `.eml` mail; image OCR with Tesseract; authorship attribution; hybrid search; fact distillation; and the MCP server over stdio or HTTP.
- **Not on Linux:** the menu-bar app and its first-run assistant, the bundled database, and the built-in llama.cpp engine. Apple Messages, Apple Mail and HEIC images need a Mac too. Use [Ollama](https://ollama.com/) or [LM Studio](https://lmstudio.ai/) for embeddings and answers.

## Before you start

- Python 3.13 or 3.14 and [uv](https://docs.astral.sh/uv/), which can fetch Python for you (or `pipx`).
- PostgreSQL with [pgvector](https://github.com/pgvector/pgvector) 0.7 or later. CI tests PostgreSQL 18, the version the Mac app bundles.
- Ollama or LM Studio, on this computer or on another machine you run.
- For OCR, optional: `libtesseract` with English language data (`tesseract-ocr` and `tesseract-ocr-eng` on Debian and Ubuntu).

## 1. Set up the database

On Debian or Ubuntu, with the PostgreSQL project's [apt repository](https://wiki.postgresql.org/wiki/Apt) set up:

```bash
sudo apt install postgresql-18 postgresql-18-pgvector tesseract-ocr tesseract-ocr-eng
sudo -u postgres createuser "$USER"
sudo -u postgres createdb --owner "$USER" garage
sudo -u postgres psql -d garage -c 'CREATE EXTENSION IF NOT EXISTS vector'
```

pgvector is not a trusted extension, so `postgres` creates it once. Your own role, which owns the database, can then apply the rest of the schema without superuser rights. If you would rather use Docker, the `pgvector/pgvector:pg18` image is what CI runs.

## 2. Install Garage

Garage is on [PyPI](https://pypi.org/project/garage-rag/) as `garage-rag`. Install it as a tool, which puts the `garage` and `garage-mcp` commands on your `PATH` in an environment of their own:

```bash
uv tool install --python 3.14 garage-rag
garage version
```

Without uv, `pipx install garage-rag` does the same. To update later, run `uv tool upgrade garage-rag`. To run the latest code from `main` instead of a release, use `uv tool install --python 3.14 "garage-rag @ git+https://github.com/rickmark/garage-rag#subdirectory=garage_python"`.

## 3. Configure and initialize

```bash
garage config init --user                                 # writes ~/.garage.json
garage config set database.url postgresql:///garage       # the local socket, as your user
garage config set facts.provider ollama                   # no built-in engine on Linux
garage init-db
```

If Ollama or LM Studio runs on another machine, set `embedding.ollama_host` or `embedding.lmstudio_host` to its address. Garage sends documents and code only to that server. Communications such as mail never leave this computer; see [privacy]({{ '/privacy.html' | relative_url }}).

## 4. Add a model and your files

```bash
ollama pull bge-m3
garage register-model bge-m3 --provider ollama --dims 1024 --default

garage add-source notes ~/Documents/Notes --class document --trust authored
garage ingest
garage backfill
garage search "what did I decide about the deployment"
```

## 5. Connect your AI assistant

```bash
garage mcp-install --target claude-code-user   # or cursor, vscode, zed, windsurf, project
garage mcp-test
```

The assistant starts `garage-mcp` itself over stdio. To serve several clients from one process, run `garage mcp-serve` and register it with `--http`.

<div class="callout callout-info">
  <div class="callout-title">🧭 Going further</div>
  <p>The <a href="{{ '/support/guide.html#command-line-interface' | relative_url }}">user guide</a> covers every command and setting, and the <a href="{{ '/architecture.html' | relative_url }}">architecture guide</a> explains the pipeline. Something not working on your distribution? <a href="https://github.com/rickmark/garage-rag/issues" target="_blank" rel="noopener">Open an issue</a>, or see <a href="{{ '/contributing.html' | relative_url }}">how to contribute</a> a fix.</p>
</div>

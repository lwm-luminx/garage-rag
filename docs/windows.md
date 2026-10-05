---
layout: default
title: Garage for Windows (alpha)
description: Garage is coming to Windows. What the Windows alpha includes, what it doesn't yet, how to install it and how to report what you find.
windows_page: true
---

{% assign windows_open = false %}{% if site.windows_alpha_url and site.windows_alpha_url != "" %}{% assign windows_open = true %}{% endif %}

<div class="hero">
  <h1>Garage for Windows <small>alpha</small></h1>
  <p>Garage is coming to Windows. The alpha brings the private database, the indexer and the MCP server to your computer, so your AI assistant can search your own files there too.</p>
  {% if windows_open %}
  <div class="hero-actions">
    <a id="windows-alpha-download" href="{{ site.windows_alpha_url }}" class="btn btn-primary btn-large" target="_blank" rel="noopener">Download the Windows alpha ↗</a>
    <a href="https://github.com/rickmark/garage-rag/releases" class="btn btn-secondary btn-large" target="_blank" rel="noopener">All releases ↗</a>
  </div>
  <p class="download-meta">64-bit Windows (x64) · alpha: unfinished, free</p>
  {% endif %}
</div>

{% unless windows_open %}
<div class="callout callout-warning">
  <div class="callout-title">⏳ The alpha hasn't been posted yet</div>
  <p>The download link appears on this page when the first Windows build is ready. To hear about it, watch the <a href="https://github.com/rickmark/garage-rag" target="_blank" rel="noopener">repository on GitHub</a> (<strong>Watch → Custom → Releases</strong>). In the meantime, Garage runs on <a href="{{ '/#download' | relative_url }}">macOS</a> and from the command line on <a href="{{ '/linux.html' | relative_url }}">Linux</a>.</p>
</div>
{% endunless %}

## Where the Windows version stands

PostgreSQL with pgvector, Python and the Garage pipeline already build from source on Windows, and every push to `main` runs the database tests against that Windows build. That's the core the alpha ships: the same indexer, hybrid search and MCP server as the macOS app.

The alpha is for people who are comfortable with rough edges:

- **Expect a command line first.** The macOS app's menu-bar window, first-run assistant and one-click assistant connections are macOS-only for now. You drive the alpha with `garage` and `garage-mcp`, as on [Linux]({{ '/linux.html' | relative_url }}).
- **Bring your own model server.** The macOS app's built-in llama.cpp engine isn't in the alpha. Run [Ollama](https://ollama.com/) or [LM Studio](https://lmstudio.ai/) for embeddings and answers, on this computer or on another machine you run.
- **macOS-only sources stay macOS-only.** Apple Messages, Apple Mail and HEIC photos need macOS. Folders, git repositories, Markdown, PDF, Office documents, code and `.eml` mail work everywhere.
- **Things may change between builds**, including where data is kept. Back up anything you can't re-index.

## Before you start

- 64-bit Windows (x64).
- Ollama or LM Studio, with an embedding model such as `bge-m3`.
- An MCP client: Claude Desktop, Claude Code, Cursor, VS Code, Windsurf, Zed or LM Studio.

## Install and set up

1. **Download the alpha** {% if windows_open %}from [its release]({{ site.windows_alpha_url }}){:target="_blank" rel="noopener"}{% else %}from this page once it's posted{% endif %}, and follow the install steps in the release notes. Builds are early, so the steps can change from one to the next.
2. **Initialize Garage**, register a model and add a folder:
   ```powershell
   garage config init --user
   garage config set facts.provider ollama
   garage init-db
   garage register-model bge-m3 --provider ollama --dims 1024 --default
   garage add-source notes "$HOME\Documents\Notes" --class document --trust authored
   garage ingest
   garage backfill
   ```
3. **Connect your assistant** with `garage mcp-install --target claude-desktop` (or `cursor`, `vscode`, `claude-code-user`, ...), then ask it about your files.

The [user guide]({{ '/support/guide.html#command-line-interface' | relative_url }}) explains each command and setting.

## Tell us what you find

Alpha testers shape the Windows version. When something breaks or feels wrong, [open an issue on GitHub](https://github.com/rickmark/garage-rag/issues/new) with your Windows version, the Garage build, what you did and what happened, plus any error output. The [contact page]({{ '/support/contact.html' | relative_url }}) has a checklist. Fixes are welcome too: see [how to contribute]({{ '/contributing.html' | relative_url }}).

<div class="callout callout-info">
  <div class="callout-title">🛡️ Same privacy, every platform</div>
  <p>On Windows as on macOS, Garage uploads nothing. Content goes only to the model server you configure, and communications such as mail never leave this computer. The same code enforces it on every platform; see <a href="{{ '/privacy.html' | relative_url }}">how it works</a>.</p>
</div>

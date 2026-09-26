---
layout: default
title: Garage
description: Garage indexes your documents, code and messages on your Mac and serves them to your AI assistant over MCP. Local-first, private by construction. Download for macOS.
---

<div class="hero hero-landing">
  <img src="{{ '/assets/logo.png' | relative_url }}" alt="Garage Logo" class="hero-logo">
  <h1>Your files, your Mac, your AI.</h1>
  <p>Garage indexes your documents, code repositories, notes and messages on your Mac and hands them to your AI assistant over the Model Context Protocol. Nothing is uploaded, nothing is sent anywhere you did not point it at.</p>
  <div class="hero-actions">
    <a id="download-primary" href="https://github.com/rickmark/garage-rag/releases/latest" class="btn btn-primary btn-large"><svg class="btn-icon" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M12 3v12m0 0-5-5m5 5 5-5M5 20h14" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/></svg><span class="btn-label">Download for Mac</span></a>
    <a href="{{ '/support/' | relative_url }}" class="btn btn-secondary btn-large">Support Center</a>
  </div>
  <p class="download-meta" id="download-meta">Apple Silicon · macOS 14 Sonoma or later · notarized installer</p>
</div>

## What Garage does

<div class="grid">
  <div class="card">
    <span class="card-icon">🗂️</span>
    <h3>Indexes what you already have</h3>
    <p>Folders, git repositories, Markdown, PDF, Office documents, scanned images and Apple Messages and Mail, parsed into searchable chunks in a private PostgreSQL database.</p>
  </div>

  <div class="card">
    <span class="card-icon">🔎</span>
    <h3>Hybrid search</h3>
    <p>Vector similarity and full-text search fused with Reciprocal Rank Fusion, so a question finds the meaning and a keyword finds the exact line.</p>
  </div>

  <div class="card">
    <span class="card-icon">✍️</span>
    <h3>Knows who wrote it</h3>
    <p>Git history, document metadata and path rules classify every document as authored by you, reference material or received from someone else, with the evidence recorded.</p>
  </div>

  <div class="card">
    <span class="card-icon">🔌</span>
    <h3>Works with your AI assistant</h3>
    <p>An MCP 2.0 server lets Claude Desktop, Claude Code, Cursor and other MCP clients search your corpus, read documents and ask grounded questions.</p>
  </div>

  <div class="card">
    <span class="card-icon">🧠</span>
    <h3>Local models, your choice</h3>
    <p>Embeddings and fact distillation run on the built-in llama.cpp engine, or on the Ollama or LM Studio server you already have. Switch models without re-ingesting.</p>
  </div>

  <div class="card">
    <span class="card-icon">🛡️</span>
    <h3>Private by construction</h3>
    <p>No cloud AI client in the app. One tested egress choke point with a destination allowlist, and your messages never leave the machine. <a href="{{ '/support/privacy-policy.html' | relative_url }}">Read the privacy policy →</a></p>
  </div>
</div>

## How it works

```
sources ──▶ walker ──▶ [materialize] ──▶ extract ──▶ quality gate
                                                          │
                            attribution ◀─────────────────┤
                                  │                       ▼
                                  └──────▶ documents ── chunks
                                                          │
                                              ┌───────────┴───────────┐
                                              ▼                       ▼
                                         emb_<model_1>           emb_<model_2>
                                              └───────────┬───────────┘
                                                          ▼
                                              hybrid search (RRF)
                                                          │
                                                    MCP server
```

Garage walks the sources you register, extracts text, decides who wrote each document and how much to trust it, and splits it into chunks. Each chunk is embedded under every model you register, one table per model, so adding a model is a backfill rather than a re-ingest. Search fuses the vector and keyword rankings and serves the result to your assistant over MCP. Everything lives in a PostgreSQL 18 + pgvector cluster the app bundles and runs for you.

<h2 id="download">Download</h2>

<div class="download-panel">
  <div class="download-panel-main">
    <h3 id="download-title">Garage for Mac</h3>
    <p id="download-detail">Apple Silicon (M1 and later), macOS 14 Sonoma or later. A signed and notarized <code>.pkg</code> installer.</p>
    <div class="hero-actions download-actions">
      <a id="download-pkg" href="https://github.com/rickmark/garage-rag/releases/latest" class="btn btn-primary"><svg class="btn-icon" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M12 3v12m0 0-5-5m5 5 5-5M5 20h14" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/></svg><span class="btn-label">Download installer</span></a>
      <a id="download-release" href="https://github.com/rickmark/garage-rag/releases/latest" class="btn btn-secondary" target="_blank" rel="noopener">All downloads on GitHub ↗</a>
    </div>
  </div>
  <div class="download-panel-aside">
    <h4>After installing</h4>
    <ol>
      <li>Open <strong>Garage</strong> from Applications. It appears in the menu bar and starts its private database.</li>
      <li>The first-run assistant picks your folders, an embedding model and the AI clients to connect.</li>
      <li>Ask Claude, or any MCP client, a question about your own files.</li>
    </ol>
    <p><small>Garage checks for updates through Sparkle, only after asking you once. Garage runs on Apple Silicon only. The <code>.zip</code> archive is on the <a id="download-release-aside" href="https://github.com/rickmark/garage-rag/releases/latest" target="_blank" rel="noopener">GitHub release page</a>.</small></p>
  </div>
</div>

<div id="download-alpha" class="callout callout-warning" hidden>
  <div class="callout-title">🧪 <span id="download-alpha-title">Try the next version</span></div>
  <p>A test build of the next Garage is out: signed and notarized, but not finished. Back up <code>~/Library/Application Support/GarageApp</code> before installing it. It updates itself to the final release when that ships.</p>
  <div class="hero-actions download-actions">
    <a id="download-alpha-pkg" href="https://github.com/rickmark/garage-rag/releases" class="btn btn-secondary">Download the test build</a>
    <a id="download-alpha-notes" href="https://github.com/rickmark/garage-rag/releases" class="btn btn-secondary" target="_blank" rel="noopener">What's new ↗</a>
  </div>
</div>

## Also a command line and a Python package

The app installs a `garage` command for terminal workflows and a `garage-mcp` stdio server for MCP clients. The same pipeline ships as the `garage_rag` Python package, so the indexer, extractors and search run anywhere PostgreSQL with pgvector does. Sources, build instructions and the developer documentation are on <a href="https://github.com/rickmark/garage-rag" target="_blank" rel="noopener">GitHub</a>: the <a href="{{ '/architecture.html' | relative_url }}">architecture guide</a>, <a href="{{ '/attribution.html' | relative_url }}">attribution engine</a>, <a href="{{ '/privacy.html' | relative_url }}">privacy internals</a> and <a href="{{ '/schema.html' | relative_url }}">database schema</a>.

<div class="callout callout-info">
  <div class="callout-title">💬 Need help?</div>
  <p>The <a href="{{ '/support/' | relative_url }}">Support Center</a> has the <a href="{{ '/support/guide.html' | relative_url }}">user guide</a>, <a href="{{ '/support/troubleshooting.html' | relative_url }}">troubleshooting</a>, the <a href="{{ '/support/faq.html' | relative_url }}">FAQ</a> and <a href="{{ '/support/contact.html' | relative_url }}">how to report a bug</a>.</p>
</div>

<script src="{{ '/assets/download.js' | relative_url }}" defer></script>

---
layout: default
title: Garage — Private local RAG and MCP server for your Mac
description: Garage is a free, open-source local RAG app for macOS. It indexes your documents, code and messages on your Mac and serves them to Claude and other AI assistants over MCP.
structured_data:
  "@context": https://schema.org
  "@type": SoftwareApplication
  name: Garage
  description: A local-first personal RAG app for macOS. It indexes your documents, code, notes and messages on your Mac and serves them to your AI assistant over the Model Context Protocol (MCP).
  applicationCategory: ProductivityApplication
  operatingSystem: macOS 14 or later (Apple silicon)
  url: https://garagerag.app/
  downloadUrl: https://github.com/rickmark/garage-rag/releases/latest
  image: https://garagerag.app/assets/social-card.png
  screenshot: https://garagerag.app/assets/screenshots/mcp-server-light-1x.png
  license: https://github.com/rickmark/garage-rag
  isAccessibleForFree: true
  offers:
    "@type": Offer
    price: "0"
    priceCurrency: USD
  author:
    "@type": Person
    name: Rick Mark-Penwell
    url: https://garagerag.app/about.html
---

<div class="hero hero-landing">
  <img src="{{ '/assets/logo.png' | relative_url }}" alt="Garage Logo" class="hero-logo">
  <h1>Your files, your Mac, your AI.</h1>
  <p>Garage indexes your documents, code, notes and messages on your Mac and serves them to your AI assistant over the Model Context Protocol. Garage uploads nothing: your assistant gets only the excerpts it searches for, never the whole collection.</p>
  <div class="hero-actions">
    <a id="download-primary" href="https://github.com/rickmark/garage-rag/releases/latest" class="btn btn-primary btn-large"><svg class="btn-icon" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M12 3v12m0 0-5-5m5 5 5-5M5 20h14" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/></svg><span class="btn-label">Download for Mac</span></a>
    <a href="{{ '/support/' | relative_url }}" class="btn btn-secondary btn-large">Support Center</a>
  </div>
  <p class="download-meta" id="download-meta">Apple Silicon · macOS 14 Sonoma or later · notarized installer</p>
  {% unless site.app_store_live %}{% if site.testflight_url and site.testflight_url != "" %}<p class="download-meta">Want the Mac App Store version? It's in beta: <a href="{{ '/testflight.html' | relative_url }}">join the TestFlight</a>.</p>{% endif %}{% endunless %}
  <div id="download-alpha" class="hero-strip hero-alpha" hidden>
    <div class="hero-strip-text">
      <strong>🧪 <span id="download-alpha-title">Try the next version</span> <small id="download-alpha-meta"></small></strong>
      <span>Signed and notarized, but not finished. Back up <code>~/Library/Application Support/GarageApp</code> first.</span>
    </div>
    <div class="hero-strip-actions">
      <a id="download-alpha-pkg" href="https://github.com/rickmark/garage-rag/releases" class="btn btn-secondary">Download</a>
      {% if site.testflight_url and site.testflight_url != "" %}<a id="download-alpha-testflight" href="{{ '/testflight.html' | relative_url }}" class="btn btn-secondary">TestFlight</a>{% endif %}
      <a id="download-alpha-notes" href="https://github.com/rickmark/garage-rag/releases" class="btn btn-secondary" target="_blank" rel="noopener">What's New ↗</a>
    </div>
  </div>
</div>

<figure class="screenshot-figure screenshot-hero">
  {% include screenshot.html name="mcp-server" alt="Garage for Mac's MCP Server page: Claude Desktop, Claude Code and LM Studio connected, and a question about a sample library answered with its sources" class="screenshot-window" loading="eager" %}
  <figcaption>Garage for Mac, answering a question about a sample library through its MCP server.</figcaption>
</figure>

<div class="hero-strip hero-hire">
  <div class="hero-strip-text">
    <strong>👋 Made by Rick Mark-Penwell, and he's available to hire</strong>
    <span>Security and AI engineer, formerly of Meta, Coinbase, Dropbox and Microsoft, and one of the researchers behind the Apple T2 work. Open to AI security, privacy engineering and security research roles.</span>
  </div>
  <div class="hero-strip-actions">
    <a href="{{ '/about.html' | relative_url }}" class="btn btn-primary">About Rick</a>
    <a href="https://linkedin.com/in/penwellr" class="btn btn-secondary" target="_blank" rel="noopener">Get in touch on LinkedIn ↗</a>
  </div>
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
    <p>No cloud AI client in the app. One tested egress choke point with a destination allowlist, and Garage itself never sends your messages off your Mac. <a href="{{ '/support/privacy-policy.html' | relative_url }}">Read the privacy policy →</a></p>
  </div>
</div>

## A look inside

<div class="screenshot-tour">
  <figure class="screenshot-figure">
    <h3>Search that finds the meaning and the exact line</h3>
    <p>Every result shows how it matched, whether it is yours or someone else's, and the full text beside it.</p>
    {% include screenshot.html name="search" alt="Search results for 'who kept the lighthouse during the storm', ranked by hybrid search, with the top document's text beside them" class="screenshot-detail" %}
  </figure>

  <figure class="screenshot-figure">
    <h3>Answers grounded in your own files</h3>
    <p>Try a question in the app before your assistant does: a local model answers from what search returns, and cites it.</p>
    {% include screenshot.html name="try-it" alt="Try It on the MCP Server page: the question 'Who kept the Marrowgate lighthouse, and for how long?' answered by a local model, with its source" class="screenshot-detail" %}
  </figure>

  <figure class="screenshot-figure">
    <h3>Connects to the assistants you already use</h3>
    <p>Garage finds the MCP clients on your Mac and connects each one with a click.</p>
    {% include screenshot.html name="assistants" alt="Connected Assistants: Claude Desktop, Claude Code and LM Studio connected, Cursor installed and ready to connect" class="screenshot-detail" %}
  </figure>

  <figure class="screenshot-figure">
    <h3>Always knows where your library stands</h3>
    <p>Documents, chunks, embeddings and distilled facts, counted on the Status page.</p>
    {% include screenshot.html name="library" alt="The Status page's library card: up to date, five documents in one source, indexed with one model, facts gleaned" class="screenshot-detail" %}
  </figure>
</div>

## Where your data goes

Garage never uploads your files or its index. What leaves your Mac depends on which AI you connect, and Garage's [privacy guarantee]({{ '/privacy.html' | relative_url }}) is enforced by tests, not by promise.

<div class="grid">
  <div class="card">
    <span class="card-icon">☁️</span>
    <h3>Claude, ChatGPT and other cloud assistants</h3>
    <p>Most people connect a cloud assistant. Its app on your Mac queries Garage over MCP and gets only the relevant parts of your collection: the excerpts its searches return and the documents it opens, never the whole index. Garage uploads nothing, but the assistant does send those parts to its provider's servers with your conversation, under the provider's terms, so leave out any source you don't want to go there.</p>
  </div>

  <div class="card">
    <span class="card-icon">💻</span>
    <h3>Fully private, on your Mac</h3>
    <p>Use the built-in llama.cpp engine, or LM Studio or Ollama on this Mac, for embeddings and answers, and connect an agent that runs its model locally, such as LM Studio's chat. Nothing leaves the machine: not your files, not the index, not the questions you ask.</p>
  </div>

  <div class="card">
    <span class="card-icon">🏠</span>
    <h3>Private AI on your own network</h3>
    <p>Point Garage at an LM Studio or Ollama server on another machine you run, and documents and code go to that one server for embedding, and nowhere else. Messages and Mail never do: they stay on this Mac even then.</p>
  </div>
</div>

## How it works

<figure class="diagram">
  <picture>
    <source media="(max-width: 640px) and (prefers-color-scheme: dark)" srcset="{{ '/assets/diagrams/how-it-works-narrow-dark.svg' | relative_url }}">
    <source media="(max-width: 640px)" srcset="{{ '/assets/diagrams/how-it-works-narrow-light.svg' | relative_url }}">
    <source media="(prefers-color-scheme: dark)" srcset="{{ '/assets/diagrams/how-it-works-dark.svg' | relative_url }}">
    <img src="{{ '/assets/diagrams/how-it-works-light.svg' | relative_url }}" width="1040" height="470" loading="lazy" alt="Your folders, git repositories, documents, Messages and Mail, and cloud folders feed Garage on your Mac. Garage reads each file, attributes it, splits it into passages and embeds them with on-device models into a private PostgreSQL and pgvector library. Hybrid search over that library is served over MCP: your AI assistant asks a question and gets back only the excerpts it searched for. Garage uploads nothing.">
  </picture>
</figure>

Garage walks the sources you register, extracts text, decides who wrote each document and how much to trust it, and splits it into chunks. Each chunk is embedded under every model you register, one table per model, so adding a model is a backfill rather than a re-ingest. Search fuses the vector and keyword rankings and serves the result to your assistant over MCP. Everything lives in a PostgreSQL 18 + pgvector cluster the app bundles and runs for you.

<h2 id="download">Download</h2>

<div class="download-panel">
  <div class="download-panel-main">
    <h3 id="download-title">Garage for Mac</h3>
    <p id="download-detail">Apple Silicon (M1 and later), macOS 14 Sonoma or later. A signed and notarized <code>.pkg</code> installer.</p>
    <div class="hero-actions download-actions">
      <a id="download-pkg" href="https://github.com/rickmark/garage-rag/releases/latest" class="btn btn-primary"><svg class="btn-icon" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M12 3v12m0 0-5-5m5 5 5-5M5 20h14" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/></svg><span class="btn-label">Download installer</span></a>
      <a id="download-release" href="https://github.com/rickmark/garage-rag/releases/latest" class="btn btn-secondary" target="_blank" rel="noopener">All downloads on GitHub ↗</a>
      {% if site.app_store_live %}<a id="download-app-store" href="https://apps.apple.com/app/id6811306880" class="btn btn-secondary" target="_blank" rel="noopener">Mac App Store ↗</a>{% elsif site.testflight_url and site.testflight_url != "" %}<a id="download-testflight" href="{{ '/testflight.html' | relative_url }}" class="btn btn-secondary">App Store beta on TestFlight</a>{% endif %}
    </div>
    {% if site.app_store_live %}<p><small>Garage is also on the <a href="https://apps.apple.com/app/id6811306880" target="_blank" rel="noopener">Mac App Store</a>. Both versions share one library on your Mac, so you can switch between them without re-indexing. The App Store version gets its updates from the App Store instead of the in-app updater.</small></p>{% else %}<p><small>The Mac App Store version is in beta on <a href="{{ '/testflight.html' | relative_url }}">TestFlight</a>. Both versions share one library on your Mac, so you can switch between them without re-indexing. The App Store version gets its updates from the App Store instead of the in-app updater.</small></p>{% endif %}
  </div>
  <div class="download-panel-aside">
    <h4>After installing</h4>
    <ol>
      <li>Open <strong>Garage</strong> from Applications. It appears in the menu bar and starts its private database.</li>
      <li>The first-run assistant picks your folders, an embedding model and the AI clients to connect.</li>
      <li>Ask Claude, or any MCP client, a question about your own files.</li>
    </ol>
    <p><small>The installer version checks for updates through Sparkle, only after asking you once; the App Store version updates through the App Store. Garage runs on Apple Silicon only. The <code>.zip</code> archive is on the <a id="download-release-aside" href="https://github.com/rickmark/garage-rag/releases/latest" target="_blank" rel="noopener">GitHub release page</a>.</small></p>
  </div>
</div>

## Also a command line and a Python package

The app includes a `garage` command for terminal workflows and a `garage-mcp` stdio server for MCP clients (in `Garage.app/Contents/MacOS`). The same pipeline ships as the `garage_rag` Python package, so the indexer, extractors and search run anywhere PostgreSQL with pgvector does. Sources, build instructions and the developer documentation are on <a href="https://github.com/rickmark/garage-rag" target="_blank" rel="noopener">GitHub</a>: the <a href="{{ '/architecture.html' | relative_url }}">architecture guide</a>, <a href="{{ '/attribution.html' | relative_url }}">attribution engine</a>, <a href="{{ '/privacy.html' | relative_url }}">privacy internals</a> and <a href="{{ '/schema.html' | relative_url }}">database schema</a>.

<div class="callout callout-info">
  <div class="callout-title">💬 Need help?</div>
  <p>The <a href="{{ '/support/' | relative_url }}">Support Center</a> has the <a href="{{ '/support/guide.html' | relative_url }}">user guide</a>, <a href="{{ '/support/troubleshooting.html' | relative_url }}">troubleshooting</a>, the <a href="{{ '/support/faq.html' | relative_url }}">FAQ</a> and <a href="{{ '/support/contact.html' | relative_url }}">how to report a bug</a>.</p>
</div>

<script src="{{ '/assets/download.js' | relative_url }}" defer></script>

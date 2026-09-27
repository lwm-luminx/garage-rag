---
layout: default
title: Frequently Asked Questions (FAQ)
description: Frequently asked questions about Garage local RAG, privacy guarantees, performance, and integrations.
redirect_from:
  - /faq.html
---

# Frequently Asked Questions (FAQ)

<div class="search-container" style="margin-bottom: 2rem;">
  <span class="search-icon">🔍</span>
  <input type="text" id="support-search" class="search-input" placeholder="Search questions (e.g. privacy, models, Claude, formats)...">
</div>

## General & Overview

<details open>
  <summary>What is Garage?</summary>
  <div class="faq-content">
    <p><strong>Garage</strong> is a local-first personal Retrieval-Augmented Generation (RAG) and knowledge indexing engine for macOS. It indexes your documents, notes, codebases, and communications locally using PostgreSQL and <code>pgvector</code>, providing hybrid semantic/keyword search via the Model Context Protocol (MCP 2.0) to local and desktop AI assistants like Claude Desktop and Claude Code.</p>
  </div>
</details>

<details>
  <summary>Is Garage completely open-source and free to use?</summary>
  <div class="faq-content">
    <p>Yes. Garage is licensed under the permissive MIT License. You have complete freedom to inspect the source code, run it locally, and adapt it to your workflow.</p>
  </div>
</details>

<details>
  <summary>How is Garage different from cloud RAG solutions?</summary>
  <div class="faq-content">
    <p>Unlike cloud solutions, Garage stores 100% of your documents, extracted chunks, and vector embeddings in a private local PostgreSQL instance on your machine. Your private communications and personal notes are never transmitted to third-party servers.</p>
  </div>
</details>

---

## Privacy & Security

<details>
  <summary>Does my data ever leave my Mac?</summary>
  <div class="faq-content">
    <p><strong>Not unless you point it at another machine.</strong> Garage sends nothing to the cloud, and the guarantee is enforced by tests rather than by convention:</p>
    <ul>
      <li><strong>No cloud AI client:</strong> An automated scan of every source file fails the build if any module imports a cloud AI SDK, and the dependency lockfile must contain none.</li>
      <li><strong>One egress choke point, one allowlist:</strong> Every outbound connection is built by a single tested module, and goes only to this Mac or to the Ollama / LM Studio server you configure. Anything else is refused.</li>
      <li><strong>Local OCR:</strong> Text in images is recognized with Tesseract on your Mac. There is no cloud fallback.</li>
      <li><strong>Communications stay local:</strong> Content classified as <code>communication</code> (e.g., Messages, Mail) is never sent to a server that is not on this Mac, even one you configured.</li>
    </ul>
    <p>If you connect an MCP client such as Claude Desktop, what Garage returns to it is handled by that client under its own terms.</p>
  </div>
</details>

<details>
  <summary>Can websites or malicious browser tabs access my MCP server?</summary>
  <div class="faq-content">
    <p>No. By default the local HTTP MCP server binds only to <code>127.0.0.1:8787</code>, refuses remote clients, and includes DNS rebinding protection and Host validation. (Serving other computers is an explicit opt-in for power users, <code>--allow-remote</code>; with it, and with no <code>--allow-host</code>, the Host check is off. See <a href="{{ '/support/troubleshooting.html#mcp-dns-rebinding' | relative_url }}">Troubleshooting</a>.) Any request originating from an unauthorized Host or browser cross-origin without explicit permission is rejected with <code>HTTP 421 Misdirected Request</code>.</p>
  </div>
</details>

<details>
  <summary>How are database passwords stored?</summary>
  <div class="faq-content">
    <p><code>GarageApp</code> automatically generates a cryptographically random SCRAM superuser password on initial launch and stores it in the secure <strong>macOS Keychain</strong> under the service name <code>com.rickmark.garage.postgres</code>. Signed builds keep it in the App Group keychain, which only Garage and its bundled <code>garage</code> / <code>garage-mcp</code> commands can read, without a Keychain prompt. The Database page's copy button puts the full connection URL, password included, on the clipboard when you need it.</p>
  </div>
</details>

---

## Supported Formats & Ingestion

<details>
  <summary>What file formats does Garage support?</summary>
  <div class="faq-content">
    <p>Garage includes streaming, memory-efficient extractors for:</p>
    <ul>
      <li><strong>Markdown & Plain Text:</strong> <code>.md</code>, <code>.txt</code>, <code>.rst</code>, <code>.org</code>, <code>.adoc</code> (with YAML frontmatter stripping).</li>
      <li><strong>PDF Documents:</strong> Fast extraction via <code>pypdf</code>, with automatic page-level escalation to <code>pdfplumber</code> for embedded data tables.</li>
      <li><strong>Office Documents:</strong> Word (<code>.docx</code>), PowerPoint (<code>.pptx</code>), and Excel (<code>.xlsx</code>).</li>
      <li><strong>Source Code & Config:</strong> <code>.py</code>, <code>.swift</code>, <code>.ts</code>, <code>.rs</code>, <code>.go</code>, <code>.json</code>, <code>.yaml</code>, <code>.toml</code>, etc.</li>
      <li><strong>Images & Scans:</strong> Local OCR via Tesseract (PNG, JPEG, TIFF, HEIC and more). An image with no text in it is skipped and remembered, not indexed.</li>
      <li><strong>Communications:</strong> Apple Messages (<code>chat.db</code>, one document per conversation) and Apple Mail (<code>.emlx</code>) or <code>.eml</code> messages.</li>
    </ul>
  </div>
</details>

<details>
  <summary>How does Authorship Attribution work?</summary>
  <div class="faq-content">
    <p>Garage automatically tags content with provenance (<code>authored</code>, <code>reference</code>, or <code>received</code>):</p>
    <ul>
      <li><strong>Git Repositories:</strong> Commits are inspected so that files you modified are attributed to you (<code>authored</code>), while upstream or vendored libraries are categorized as <code>reference</code>.</li>
      <li><strong>Document Metadata:</strong> PDF / Office author tags are extracted and cleaned against tool signatures.</li>
      <li><strong>Path Heuristics:</strong> Paths such as <code>Papers/</code>, <code>Manuals/</code>, or <code>node_modules/</code> are automatically mapped to reference material.</li>
    </ul>
  </div>
</details>

---

## Models & Search

<details>
  <summary>Can I use multiple embedding models at once?</summary>
  <div class="faq-content">
    <p>Yes. Garage decouples text chunks from embedding tables (<code>emb_&lt;model_slug&gt;</code>). You can register multiple models (e.g., <code>bge-m3</code>, <code>nomic-embed-text</code>) and run vector searches across any of them without re-extracting your original files.</p>
  </div>
</details>

<details>
  <summary>What is Hybrid Search (RRF)?</summary>
  <div class="faq-content">
    <p><strong>Reciprocal Rank Fusion (RRF)</strong> combines PostgreSQL full-text search (BM25-style keyword matching) with dense pgvector cosine similarity. This ensures that exact keyword matches (like specific function names or error codes) and semantic conceptual queries are merged into an optimal ranked result list.</p>
  </div>
</details>

---

## Model Context Protocol (MCP) & AI Clients

<details>
  <summary>Which MCP tools are available to Claude Desktop?</summary>
  <div class="faq-content">
    <p>Garage provides the following MCP tools to LLMs:</p>
    <ul>
      <li><code>rag_search</code>: Hybrid semantic and keyword search across your documents and code.</li>
      <li><code>rag_get_document</code>: Retrieve the full extracted text and metadata of a specific indexed file.</li>
      <li><code>rag_stats</code>: Overview of indexed document counts, chunk counts, and registered embedding models.</li>
      <li><code>rag_list_sources</code>: List all configured knowledge sources and their sync status.</li>
      <li><code>rag_list_authors</code>: List the people the corpus attributes documents to.</li>
      <li><code>rag_ask</code>: Answer a question from retrieved excerpts with a local model (<code>facts.provider</code> / <code>facts.model</code>), citing them as <code>[n]</code>. Garage sends nothing off the machine; the answer goes back to the agent that asked.</li>
      <li><code>rag_agent</code>: Let the same local model search and read the corpus itself with the tools above, in a loop, and answer; the result lists the steps it took and the documents it saw. This is what "Ask Garage" in the menu bar runs.</li>
      <li><code>rag_generate</code>: Send a raw prompt to the same local model, with no retrieval.</li>
    </ul>
  </div>
</details>

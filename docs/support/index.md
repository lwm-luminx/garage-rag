---
layout: default
title: Support Center
description: Official support pages, troubleshooting guides, FAQ, and privacy documentation for Garage.
---

<div class="hero">
  <img src="{{ '/assets/logo.png' | relative_url }}" alt="Garage Logo" style="width: 72px; height: 72px; margin-bottom: 1rem; border-radius: 16px; box-shadow: 0 4px 12px rgba(0,0,0,0.15);">
  <h1>Garage Support Center</h1>
  <p>Setup instructions, troubleshooting guides, and answers to frequently asked questions for Garage — your local-first personal knowledge retrieval engine. Looking for the app itself? <a href="{{ '/#download' | relative_url }}">Download Garage</a>.</p>
  <div class="hero-actions">
    <a href="{{ '/support/guide.html' | relative_url }}" class="btn btn-primary">📖 Support Guide</a>
    <a href="{{ '/support/troubleshooting.html' | relative_url }}" class="btn btn-secondary">🛠️ Troubleshooting</a>
    <a href="{{ '/support/faq.html' | relative_url }}" class="btn btn-secondary">❓ FAQ</a>
  </div>
  <div class="search-container">
    <span class="search-icon">🔍</span>
    <input type="text" id="support-search" class="search-input" placeholder="Search support topics, error messages, or questions...">
  </div>
</div>

## Explore Support Topics

<div class="grid">
  <div class="card">
    <span class="card-icon">🚀</span>
    <h3>Getting Started & Setup</h3>
    <p>Step-by-step setup for both the native macOS menu bar app and the Python CLI, including source registration and indexing.</p>
    <a href="{{ '/support/guide.html' | relative_url }}#getting-started" class="card-link">View Setup Guide →</a>
  </div>

  <div class="card">
    <span class="card-icon">🔐</span>
    <h3>macOS Permissions & TCC</h3>
    <p>How to grant Full Disk Access for indexing Apple Messages (chat.db), Mail, and protected system directories without errors.</p>
    <a href="{{ '/support/guide.html' | relative_url }}#macos-permissions" class="card-link">Configure Permissions →</a>
  </div>

  <div class="card">
    <span class="card-icon">🧠</span>
    <h3>Embedding Models & Providers</h3>
    <p>Configure local embedding models with Ollama, LM Studio, or local Llama runners. Backfill vectors and switch models seamlessly.</p>
    <a href="{{ '/support/guide.html' | relative_url }}#models-and-embeddings" class="card-link">Manage Models →</a>
  </div>

  <div class="card">
    <span class="card-icon">🔌</span>
    <h3>Model Context Protocol (MCP)</h3>
    <p>Connect your personal knowledge index to LLM clients including Claude Desktop, Claude Code, and Cursor via MCP 2.0.</p>
    <a href="{{ '/support/guide.html' | relative_url }}#mcp-integration" class="card-link">Setup MCP Integration →</a>
  </div>

  <div class="card">
    <span class="card-icon">🛠️</span>
    <h3>Troubleshooting & Diagnostics</h3>
    <p>Resolutions for common issues: PostgreSQL startup errors, port conflicts, DNS rebinding blocks, and placeholder downloads.</p>
    <a href="{{ '/support/troubleshooting.html' | relative_url }}" class="card-link">Troubleshoot Issues →</a>
  </div>

  <div class="card">
    <span class="card-icon">❓</span>
    <h3>Frequently Asked Questions</h3>
    <p>Answers to common questions regarding local storage footprint, supported formats, search algorithms (RRF), and privacy guarantees.</p>
    <a href="{{ '/support/faq.html' | relative_url }}" class="card-link">Read FAQ →</a>
  </div>

  <div class="card">
    <span class="card-icon">🛡️</span>
    <h3>Privacy & Egress Guarantees</h3>
    <p>No cloud AI client, one egress choke point with a destination allowlist, and messages that Garage itself never sends off your Mac.</p>
    <a href="{{ '/support/privacy-policy.html' | relative_url }}" class="card-link">Read Privacy Policy →</a>
  </div>

  <div class="card">
    <span class="card-icon">📬</span>
    <h3>Contact & Bug Reports</h3>
    <p>How to safely submit diagnostic logs, report bugs, request features, or contact the maintainers on GitHub.</p>
    <a href="{{ '/support/contact.html' | relative_url }}" class="card-link">Get Support →</a>
  </div>
</div>

---

## Quick Diagnostic Checklist

If you are experiencing unexpected behavior, check these fundamental items first:

1. **Check Database Status**: Ensure PostgreSQL is running. In the macOS App, check the menu bar indicator. In CLI, verify with `garage stats`.
2. **Verify Full Disk Access**: If indexing `~/Library/Messages` or `~/Library/Mail`, make sure **Full Disk Access** is granted to `GarageApp` or your Terminal application under **System Settings → Privacy & Security**.
3. **Verify Embedding Provider**: Ensure Ollama or LM Studio is running locally on your machine before running `garage backfill` or `garage ingest`.
4. **Inspect Application Logs**: In the macOS App, navigate to the **Logs** tab to view live streaming logs from PostgreSQL, Ingestion, and the MCP HTTP server.

<div class="callout callout-info">
  <div class="callout-title">💡 Need In-Depth Technical Architecture?</div>
  <p>For internal pipeline details, schema definitions, and authorship heuristics, check the developer specifications: <a href="{{ '/architecture.html' | relative_url }}">Architecture Guide</a>, <a href="{{ '/attribution.html' | relative_url }}">Attribution Engine</a>, and <a href="{{ '/schema.html' | relative_url }}">Database Schema Reference</a>.</p>
</div>

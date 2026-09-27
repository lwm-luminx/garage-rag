---
layout: default
title: Contact & Support
description: Contact the maintainers, submit bug reports, request features, and get support for Garage.
redirect_from:
  - /contact.html
---

# Contact & Support

We welcome questions, bug reports, feature suggestions, and security vulnerability disclosures from the community.

---

## Getting Support & Submitting Inquiries

### 1. Bug Reports & Issues
If you encounter a bug, crash, or unexpected behavior in `GarageApp` or the `garage` CLI:

**From inside GarageApp (recommended)**: choose **Help → Report a Bug…** (⇧⌘B), click the ladybug tab on
the right edge of the main window, pick **Report a Bug…** from the menu bar, or click **Report a Bug** in the **Logs** view to start with the log stream you are
already looking at. Describe what happened and Garage assembles the rest — version, macOS build,
database and helper service state, corpus counts, registered models, and optionally the most recent log
lines.

The report is built entirely on your Mac and shown to you in full before anything happens to it. Your
home directory, user name, e-mail addresses, and any secrets are replaced with placeholders
automatically, and indexed documents, messages, and search results are never included. From there you
can copy it, save it as Markdown, or open a pre-filled GitHub issue in your browser — where you get one
more chance to read it before posting.

**By hand**: [open a GitHub Issue](https://github.com/rickmark/garage-rag/issues) and include:
  - macOS version and hardware architecture (e.g., macOS 15.0 Sequoia, Apple Silicon M3)
  - Garage version / commit hash
  - Relevant sanitized log snippets (see below)
  - Exact steps to reproduce the issue

### 2. Feature Requests & Discussions
Have an idea for a new extractor, embedding provider, or MCP tool?
- Join the discussion and submit proposals under [GitHub Issues / Feature Requests](https://github.com/rickmark/garage-rag/issues).

### 3. Security Vulnerability Disclosures
If you discover a potential security issue or data leakage vulnerability:
- Please do **not** open a public issue.
- Email the maintainer directly at: [security@rickmark.com](mailto:security@rickmark.com)
- All valid security reports receive prompt attention and coordinated disclosure.

---

## How to Safely Share Diagnostic Logs

Before sharing logs on public issue trackers, protect your privacy by following these sanitization steps:

### Locating Your Logs
Logs are stored locally on your machine at:
- **PostgreSQL Service**: `~/Library/Group Containers/DWVXMLB45Y.group.me.rickmark.garage-rag/Library/Application Support/GarageApp/logs/postgres.log`
- **Ingestion & CLI Pipeline**: `~/Library/Group Containers/DWVXMLB45Y.group.me.rickmark.garage-rag/Library/Application Support/GarageApp/logs/ingest.log`
- **MCP HTTP Server**: `~/Library/Group Containers/DWVXMLB45Y.group.me.rickmark.garage-rag/Library/Application Support/GarageApp/logs/mcp.log`

If you file through **Help → Report a Bug…**, the steps below are already applied to anything the
reporter attaches — they matter when you paste log snippets by hand.

### Sanitization Guidelines
1. **Redact Usernames and Paths**: Replace your home directory name (e.g., `/Users/yourname/`) with `/Users/username/`.
2. **Redact Sensitive File Names**: Check if log traces contain confidential project titles or private message sender handles.
3. **Never Share Database Dumps**: Do not attach raw `.dump` or `pgdata` files to public tickets, as they contain your indexed content and vector chunks.

---

<div class="callout callout-success">
  <div class="callout-title">Community & Open Source</div>
  <p>Garage is maintained as an open-source project by <a href="{{ '/about.html' | relative_url }}">Rick Mark-Penwell</a>. Contributions and pull requests are warmly welcomed!</p>
</div>

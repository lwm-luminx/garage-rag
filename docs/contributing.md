---
layout: default
title: Contribute to Garage
description: How to contribute to Garage, the open-source local RAG app and MCP server. Find the code on GitHub, report bugs, test on Windows and Linux, set up a development environment and send a pull request.
---

<div class="hero">
  <h1>Contribute to Garage</h1>
  <p>Garage is free and open source under the MIT license. The macOS app, the Python pipeline, the Windows build and this website all live in one repository on GitHub, and contributions of every size are welcome.</p>
  <div class="hero-actions">
    <a href="https://github.com/rickmark/garage-rag" class="btn btn-primary btn-large" target="_blank" rel="noopener">rickmark/garage-rag on GitHub ↗</a>
    <a href="https://github.com/rickmark/garage-rag/issues" class="btn btn-secondary btn-large" target="_blank" rel="noopener">Issues ↗</a>
  </div>
</div>

## Ways to help

<div class="grid">
  <div class="card">
    <span class="card-icon">🐛</span>
    <h3>Report what you find</h3>
    <p>A clear bug report is a contribution. In the macOS app, <strong>Report a Bug</strong> (in Logs, or the Help menu) assembles the details for you. Elsewhere, the <a href="{{ '/support/contact.html' | relative_url }}">contact page</a> lists what to include.</p>
  </div>

  <div class="card">
    <span class="card-icon">🪟</span>
    <h3>Test on Windows and Linux</h3>
    <p>Garage is cross-platform, and growing. Try the <a href="{{ '/windows.html' | relative_url }}">Windows alpha</a> or the <a href="{{ '/linux.html' | relative_url }}">Linux command line</a> and tell us what breaks: your distribution, your file types, your MCP client.</p>
  </div>

  <div class="card">
    <span class="card-icon">📝</span>
    <h3>Improve the docs</h3>
    <p>This site is in <code>docs/</code> in the repository, plain Markdown built by Jekyll. Fixing a confusing step or a typo is a fine first pull request.</p>
  </div>

  <div class="card">
    <span class="card-icon">🧩</span>
    <h3>Write code</h3>
    <p>New extractors, attribution rules, MCP tools, model support, performance and Windows work. Issues are a good place to start: say what you plan before a big change, so it fits. The <a href="{{ '/plans/' | relative_url }}">engineering plans</a> show what is already proposed or under way.</p>
  </div>
</div>

## Find your way around

| Folder | What's in it |
| --- | --- |
| [`garage_python/`](https://github.com/rickmark/garage-rag/tree/main/garage_python) | The `garage_rag` Python package: ingestion, extractors, attribution, embeddings, hybrid search, the MCP server and the `garage` CLI. Runs on macOS, Linux and Windows. |
| [`macapp/`](https://github.com/rickmark/garage-rag/tree/main/macapp) | The Swift/SwiftUI macOS app, its XPC services and the `garage` / `garage-mcp` launchers. |
| [`data/sql/`](https://github.com/rickmark/garage-rag/tree/main/data/sql) | The database schema, the source of truth. Migrations are idempotent and re-applied, not tracked. |
| [`proto/`](https://github.com/rickmark/garage-rag/tree/main/proto) | The gRPC contract between the macOS app and the Python service. |
| [`ext/`](https://github.com/rickmark/garage-rag/tree/main/ext) | From-source builds of PostgreSQL, pgvector, Python, llama.cpp, Tesseract and the rest. |
| [`docs/`](https://github.com/rickmark/garage-rag/tree/main/docs) | This website. |
| [`docs/plans/`](https://github.com/rickmark/garage-rag/tree/main/docs/plans) | Engineering plans and design notes, published as the [plans page]({{ '/plans/' | relative_url }}). |

The [architecture guide]({{ '/architecture.html' | relative_url }}) walks through the pipeline, and the repository's [`CLAUDE.md`](https://github.com/rickmark/garage-rag/blob/main/CLAUDE.md) is the detailed map for anyone, human or coding agent, working in the code.

## Set up for Python work

Most changes touch only the Python package, and that needs no Bazel, Xcode or macOS:

```bash
git clone https://github.com/rickmark/garage-rag.git
cd garage-rag/garage_python
uv sync                                         # macOS
# uv venv --python 3.14 .venv && uv pip install -e '.[dev]'   # Linux and Windows
.venv/bin/pytest                                # the unit tests mock the database
```

The tests that need real SQL (`tests/test_postgres.py`) run when `GARAGE_TEST_DATABASE_URL` names a PostgreSQL server with pgvector and a superuser role, such as Homebrew's `postgresql@18` or the `pgvector/pgvector:pg18` Docker image. Each run creates and drops its own throwaway database. Don't point it at the macOS app's own database, which holds your real corpus.

Before you push, run the formatter and linters:

```bash
.venv/bin/ruff format && .venv/bin/ruff check
```

## Build everything

The whole repository, the macOS app included, builds with Bazel through the [Aspect CLI](https://docs.aspect.build/cli/):

```bash
aspect build //...          # everything
aspect build //:macapp      # the macOS app, with its own PostgreSQL, Python and llama.cpp
aspect test //...           # every test
aspect gazelle              # regenerate BUILD files after adding Python sources
```

The macOS app needs macOS with Xcode. Windows builds PostgreSQL and Python with each project's own MSVC build, in [`.github/workflows/windows.yaml`](https://github.com/rickmark/garage-rag/blob/main/.github/workflows/windows.yaml), which is the place to start for Windows work.

## Ground rules

- **Privacy is load-bearing.** Only `net/egress.py` opens outbound connections. No cloud AI SDKs. Communications such as Messages and Mail never go to a server that is not on this computer. The tests in `test_egress_block.py` check each rule on its own, and a change that weakens one won't be merged. See [privacy internals]({{ '/privacy.html' | relative_url }}).
- **Keep licenses permissive.** For example, PDF extraction uses `pypdf` and `pdfplumber` because PyMuPDF is AGPL. After changing dependencies, regenerate the third-party notices (`python3 tools/third_party_notices.py`).
- **Tests come with the change.** Deprecation warnings fail the suite, so fix them rather than silencing them.
- **Settings are documented.** A new or renamed config setting needs its description, and the JSON Schema regenerated (`garage config schema --publish`).

## Send a pull request

1. Fork the repository and make a branch.
2. Make your change, with tests, and run them.
3. Open a pull request against `main` that says what changed and why. CI runs the Python suite on Linux (with PostgreSQL), format and lint checks, a Swift syntax check and, for build changes, the full macOS and Windows builds.
4. Be ready for a round of review. Small, focused pull requests get merged fastest.

By contributing, you agree that your contribution is licensed under the project's [MIT license](https://github.com/rickmark/garage-rag/blob/main/LICENSE).

<div class="callout callout-info">
  <div class="callout-title">💬 Questions?</div>
  <p>Not sure where to start, or whether an idea fits? <a href="https://github.com/rickmark/garage-rag/issues/new" target="_blank" rel="noopener">Open an issue</a> and ask. Garage is maintained by <a href="{{ '/about.html' | relative_url }}">Rick Mark-Penwell</a>, and you can support the work on <a href="https://www.patreon.com/rickmark" target="_blank" rel="noopener">Patreon</a>.</p>
</div>

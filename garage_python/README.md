# garage_rag

The Python half of [Garage](https://github.com/rickmark/garage-rag#readme): a local-first personal RAG pipeline over
PostgreSQL + pgvector. It walks personal documents, code repositories and communications,
extracts and chunks their text, attributes authorship, embeds every chunk under each
registered model, distills documents into span-grounded facts, and serves the corpus over
MCP 2.0 and gRPC. Garage never sends communications off the machine (MCP clients you connect still receive what they retrieve); see [`docs/privacy.md`](https://github.com/rickmark/garage-rag/blob/main/docs/privacy.md).

## Entry points

| Command | Module | Role |
|---|---|---|
| `garage` | `garage_rag.cli:main_cli` | ingest, backfill, enrich-facts, search, config, model registry, `serve` (gRPC bridge for the macOS app) |
| `garage-mcp` | `garage_rag.mcp_server.server:main` | MCP 2.0 server over stdio, the command MCP clients spawn (`garage mcp-install --stdio` wires it into Claude Desktop/Code); `garage mcp-serve` runs the HTTP server |

Both are console scripts of the `garage_rag` package. The macOS app does not
ship them as standalone binaries: it bundles the package as
`site-python` inside `Frameworks/PythonXPCService.framework` (`//garage_python:site-packages`) and runs it through
Swift launchers that embed the bundled interpreter, packaged as helper bundles
(`Contents/Helpers/garage.app` and `garage-mcp.app`, `//macapp/Sources/GarageCLI:garage_app` and
`//macapp/Sources/GarageMCPCLI:garage_mcp_app`) and reached through the stable paths
`Contents/MacOS/garage` and `garage-mcp`. Those launchers find or start the app's database and
export `GARAGE_DATABASE_URL`; the console scripts from a venv do not.

## Layout

```
src/garage_rag/
  ingest/     walker, materialization budget, chunking, scanner, pipeline, Messages threads,
              the storage gateway (in-process SQLAlchemy, or gRPC for the XPC workers)
  extract/    per-format extractors (text, PDF, Office, images via in-process Tesseract, mail) + quality gate
  attribute/  git / metadata / path-rule / message-sender authorship signals
  embed/      embedding backends (Ollama, LM Studio, llama XPC) and backfill
  enrich/     fact distillation (vendored local LangExtract subset) and local generation
  inference/  the one HTTP client for LM Studio, Ollama and the app's LlamaXPCService
  net/        egress.py, the only module that opens outbound connections
  search/     hybrid RRF search
  mcp_server/ MCP tools and client registration (mcp-install)
  service/    gRPC GarageService (proto/garage.proto) and its client
  ops/        the operations the CLI and the gRPC handlers both present
  xpc/        hooks for the app's XPC hosts (llama_xpc client, model loader)
  native/     finds libpq / libtesseract already loaded into the process
  db/         SQLAlchemy models mirroring data/sql/00*.sql, migrations, model registry
  config/     garage.json settings and the generated JSON Schema
tests/        pytest suite, one Bazel py_test target per file
```

## Building and testing

Everything is driven by the Aspect CLI from the repository root:

```bash
aspect build //garage_python:site-packages
aspect test //garage_python/tests:suite
aspect test //garage_python/tests:test_facts --bazel-flag=--test_arg=-k --bazel-flag=--test_arg=some_case
```

`tests/BUILD.bazel` has one `py_test` per file (via `//tools/pytest:defs.bzl`, which drives
pytest); `aspect gazelle` writes the target for a new test file, and the `suite` list is kept by
hand. Third-party
dependencies live in `pyproject.toml` and are locked with `uv` (`../tools/repin`), exposed to
Bazel as `@pypi//<package>`.

For quick iteration outside Bazel, use the `uv`-managed virtualenv:

```bash
cd garage_python
uv sync --extra dev
uv run pytest -q
```

The lockfile resolves for macOS only; on Linux use
`uv venv --python 3.14 .venv && uv pip install -e '.[dev]'`, then `.venv/bin/pytest -q`.
`tests/test_postgres.py` runs against a real server when `GARAGE_TEST_DATABASE_URL` is set (see
"Testing against Postgres" in `../CLAUDE.md`).

## Documentation

`../docs/` — [architecture](https://github.com/rickmark/garage-rag/blob/main/docs/architecture.md), [schema](https://github.com/rickmark/garage-rag/blob/main/docs/schema.md),
[attribution](https://github.com/rickmark/garage-rag/blob/main/docs/attribution.md), [privacy](https://github.com/rickmark/garage-rag/blob/main/docs/privacy.md), plus support and
troubleshooting guides. The generated config schema is committed at
`../docs/.data/garage.schema.json` and served as `https://garagerag.app/.data/garage.schema.json`.

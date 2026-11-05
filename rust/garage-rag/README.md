# garage_rag

[Garage](https://garagerag.app) is a local-first personal RAG pipeline over PostgreSQL and pgvector: it
indexes your documents, code and communications with authorship attribution, embeds them with local
models, searches them with hybrid full-text and vector retrieval, and serves the corpus to AI assistants
over MCP.

Since 1.5.1 this package is Garage's Rust, in one library per platform; 1.5.0 was the last pure-Python
release. It installs the same two commands:

| Command | Entry point | What it does |
| --- | --- | --- |
| `garage` | `garage_rag.cli:main_cli` | sources, scan, ingest, backfill, enrich-facts, search, ask, the model registry, config, `mcp-install`, `mcp-serve`, `serve` |
| `garage-mcp` | `garage_rag.mcp_server.server:main` | the MCP server over stdio, the command MCP clients start (`garage mcp-install` registers it) |

```bash
pip install garage_rag
export GARAGE_DATABASE_URL=postgresql://localhost:5432/garage   # or database.url in garage.json
garage init-db
garage --help
```

## What it needs

- **PostgreSQL with pgvector** (0.7 or later), reached through `GARAGE_DATABASE_URL` or the config file
  (`./garage.json`, then `~/.garage.json`, or `--config PATH`; `garage config init` writes one). Each
  command runs Garage's backend in its own process; no app or server needs to be running.
- **A local model server** for embeddings and the ask and fact commands: Ollama, LM Studio, or the
  Garage app's own. Garage uploads nothing: content goes only to the model servers you configure, and
  communications only to one on this machine.

The wheel carries the schema and the model catalog, and points `GARAGE_SQL_DIR`,
`GARAGE_MODEL_MANIFEST` and `GARAGE_MCP_EXECUTABLE` at them when they are unset. On Linux and Windows a
picture reads as no text (no OCR engine is linked); on macOS it is read with Vision.

## From Python

`garage_rag.garage_embed` is the embed worker through UniFFI (`embed_texts`, `backfill`, `models`, and
the `EmbedHost` protocol a host implements); its names are also importable from `garage_rag`. The rest of
the 1.5.0 library API is being brought back over the Rust
([the plan](https://garagerag.app/plans/python-package-parity.html)).

## Building

```bash
tools/wheels/build_libgit2.sh /tmp/libgit2 && export GARAGE_LIBGIT2_DIR=/tmp/libgit2
cd rust/garage-rag && maturin build --release
```

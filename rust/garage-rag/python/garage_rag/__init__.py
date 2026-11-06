"""Garage (https://garagerag.app): a local-first personal RAG pipeline over PostgreSQL + pgvector.

Since 1.5.1 the package is Garage's Rust, linked into one library: the hand-written modules here
keep the names of the pure-Python 1.5.0 package and call the UniFFI bindings maturin generates in
``garage_rag._native`` (docs/plans/python-package-parity.md).

- ``garage`` and ``garage-mcp``, the console scripts (``garage_rag.cli:main_cli``,
  ``garage_rag.mcp_server.server:main``), run the Rust command line in this process.
- ``garage_rag.garage_embed``: the embed worker, with the ``EmbedHost`` protocol; its names are
  re-exported here, as the bindings-only 0.1 package did.
"""

from ._native import garage_cli as _garage_cli
from .garage_embed import *  # noqa: F403 (the 0.1 package's surface, kept)

__version__: str = _garage_cli.version()

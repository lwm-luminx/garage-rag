"""garage-rag: a local-first personal RAG pipeline.

Indexes personal documents into Postgres + pgvector, preserving authorship,
reference, and communication distinctions, and exposes the corpus to Claude
through an MCP server.
"""

__version__ = "1.5.0"

# Must run before psycopg is imported anywhere in the package: makes psycopg's
# ctypes based libpq lookup use the signed copy the app's framework has loaded
# instead of a Homebrew/system library that dyld rejects.
from . import libpq as _libpq  # noqa: E402

_libpq.configure()

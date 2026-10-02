"""garage-rag: a local-first personal RAG pipeline.

Indexes personal documents into Postgres + pgvector, preserving authorship,
reference, and communication distinctions, and exposes the corpus to Claude
through an MCP server.
"""

__version__ = "1.5.0"

# Must run before psycopg is imported anywhere in the package: outside the app,
# whose interpreter has psycopg's C implementation built in, it makes psycopg's
# ctypes based libpq lookup use a signed copy already loaded (the Bazel tests'),
# or on Windows the GARAGE_LIBPQ build, instead of a library dyld rejects.
from . import libpq as _libpq  # noqa: E402

_libpq.configure()

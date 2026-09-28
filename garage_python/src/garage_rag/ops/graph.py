"""The AGE projection of the corpus (``garage graph rebuild``); see :mod:`garage_rag.db.graph`."""

from __future__ import annotations

from garage_rag.db.engine import session_scope
from garage_rag.db.graph import GraphSummary
from garage_rag.db.graph import rebuild_graph as _rebuild


def rebuild_graph() -> GraphSummary:
    """Re-project documents, chunks, authors and facts into the ``garage`` graph, where AGE exists."""
    with session_scope() as session:
        return _rebuild(session)

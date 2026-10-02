"""The AGE projection of the corpus (``garage graph``); see :mod:`garage_rag.db.graph`."""

from __future__ import annotations

from garage_rag.db.engine import session_scope
from garage_rag.db.graph import GraphLabels, GraphSummary, GraphVertex, Neighborhood, QueryResult
from garage_rag.db.graph import document_links as _document_links
from garage_rag.db.graph import find_vertices as _find_vertices
from garage_rag.db.graph import graph_labels as _graph_labels
from garage_rag.db.graph import neighborhood as _neighborhood
from garage_rag.db.graph import rebuild_graph as _rebuild
from garage_rag.db.graph import run_query as _run_query


def rebuild_graph() -> GraphSummary:
    """Re-project documents, messages, authors, links and facts into the ``garage`` graph, where AGE exists."""
    with session_scope() as session:
        return _rebuild(session)


def graph_labels() -> GraphLabels:
    """The graph's labels with counts, for the Graph page's filters."""
    with session_scope() as session:
        return _graph_labels(session)


def find_vertices(query: str, *, label: str = "", limit: int = 50) -> list[GraphVertex]:
    """Vertices titled like ``query``, or with that relational id."""
    with session_scope() as session:
        return _find_vertices(session, query, label=label, limit=limit)


def neighborhood(
    *,
    vertex_id: int | None = None,
    label: str = "",
    key: int | None = None,
    depth: int = 1,
    vertex_labels: list[str] | None = None,
    edge_labels: list[str] | None = None,
    limit: int = 200,
) -> Neighborhood:
    """A vertex and everything within ``depth`` hops, under the label filters."""
    with session_scope() as session:
        return _neighborhood(
            session,
            vertex_id=vertex_id,
            label=label,
            key=key,
            depth=depth,
            vertex_labels=vertex_labels,
            edge_labels=edge_labels,
            limit=limit,
        )


def document_links(document_id: int, *, limit: int = 2000) -> Neighborhood:
    """Everything in the graph linked to one document: its messages, authors, links and facts."""
    with session_scope() as session:
        return _document_links(session, document_id, limit=limit)


def run_query(query: str, *, limit: int = 500) -> QueryResult:
    """One read-only openCypher query on the graph, at most ``limit`` rows."""
    with session_scope() as session:
        return _run_query(session, query, limit=limit)

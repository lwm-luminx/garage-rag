"""The corpus as an Apache AGE graph, projected from the relational tables.

The tables stay the source of truth; the graph ``garage`` is a projection of
them for openCypher queries, rebuilt whole by :func:`rebuild_graph` (``garage
graph rebuild``, and after every ``garage cluster-facts``). It exists only
where the server has AGE (the app's bundled Postgres; ``001_extensions.sql``
creates the extension where it is installed). Elsewhere :func:`age_available`
is false and nothing is projected.

Vertices carry the relational id and a few display properties; text, spans and
vectors stay in the tables (and vectors in the ``emb_``/``potential_fact_emb_``/``fact_emb_`` tables):

=================  ===============================================================
``Document``       ``document_id``, ``title``, ``uri``, ``corpus_class``, ``trust_tier``
``Chunk``          ``chunk_id``, ``document_id``, ``ord`` (content chunks, not facts')
``Author``         ``author_id``, ``display_name``, ``is_self``
``PotentialFact``  ``fact_id``, ``document_id``, ``fact_class``, ``prompt_name``, ``fact``
``Fact``           ``distilled_fact_id``, ``fact_class``, ``statement``, ``statement_generated``,
                   ``nodes``, ``spread``, ``drift`` (how varied its group is; see enrich/clusters.py)
=================  ===============================================================

Edges:

=============  ==============================  ==============================================================
``HAS_CHUNK``  Document -> Chunk               ``ord``
``WROTE``      Author -> Document              ``role`` (author, committer, sender), ``confidence``
``RECEIVED``   Author -> Document              ``role`` (recipient, cc), ``confidence``
``STATES``     Document -> PotentialFact       ``char_start``, ``char_end``
``RESTATES``   PotentialFact -> PotentialFact  ``similarity``: a restatement to its document's representative
``SUPPORTS``   PotentialFact -> Fact           ``similarity`` (NULL for a fact alone); representatives only
=============  ==============================  ==============================================================

The rebuild writes the label tables directly (``INSERT INTO garage."Document"``)
rather than through ``cypher()``: one statement per label instead of one
``MERGE`` per row, and no value is ever interpolated into a Cypher body.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field

from sqlalchemy import text
from sqlalchemy.orm import Session

log = logging.getLogger(__name__)

GRAPH = "garage"

# label -> (id property, SELECT of (relational id, jsonb properties))
VERTICES: dict[str, tuple[str, str]] = {
    "Document": (
        "document_id",
        """
        SELECT d.id, jsonb_build_object('document_id', d.id, 'title', d.title, 'uri', d.uri,
                                        'corpus_class', d.corpus_class::text, 'trust_tier', d.trust_tier::text)
        FROM documents d
        """,
    ),
    "Chunk": (
        "chunk_id",
        """
        SELECT c.id, jsonb_build_object('chunk_id', c.id, 'document_id', c.document_id, 'ord', c.ord)
        FROM chunks c WHERE c.fact_id IS NULL
        """,
    ),
    "Author": (
        "author_id",
        """
        SELECT a.id, jsonb_build_object('author_id', a.id, 'display_name', a.display_name, 'is_self', a.is_self)
        FROM authors a
        """,
    ),
    "PotentialFact": (
        "fact_id",
        """
        SELECT f.id, jsonb_build_object('fact_id', f.id, 'document_id', f.document_id, 'fact_class', f.fact_class,
                                        'prompt_name', f.prompt_name, 'fact', f.fact)
        FROM facts f
        """,
    ),
    "Fact": (
        "distilled_fact_id",
        """
        SELECT df.id, jsonb_strip_nulls(jsonb_build_object(
                   'distilled_fact_id', df.id, 'fact_class', df.fact_class, 'statement', df.statement,
                   'statement_generated', df.statement_generated, 'nodes', df.nodes, 'spread', df.spread,
                   'drift', df.drift))
        FROM distilled_facts df
        """,
    ),
}

# label -> (from label, to label, SELECT of (from id, to id, jsonb properties))
EDGES: dict[str, tuple[str, str, str]] = {
    "HAS_CHUNK": (
        "Document",
        "Chunk",
        "SELECT c.document_id, c.id, jsonb_build_object('ord', c.ord) FROM chunks c WHERE c.fact_id IS NULL",
    ),
    "WROTE": (
        "Author",
        "Document",
        """
        SELECT da.author_id, da.document_id, jsonb_build_object('role', da.role::text, 'confidence', da.confidence)
        FROM document_authors da WHERE da.role IN ('author', 'committer', 'sender')
        """,
    ),
    "RECEIVED": (
        "Author",
        "Document",
        """
        SELECT da.author_id, da.document_id, jsonb_build_object('role', da.role::text, 'confidence', da.confidence)
        FROM document_authors da WHERE da.role IN ('recipient', 'cc')
        """,
    ),
    "STATES": (
        "Document",
        "PotentialFact",
        """
        SELECT f.document_id, f.id, jsonb_strip_nulls(jsonb_build_object('char_start', f.char_start,
                                                                         'char_end', f.char_end))
        FROM facts f
        """,
    ),
    "RESTATES": (
        "PotentialFact",
        "PotentialFact",
        """
        SELECT f.id, f.restates_fact_id, jsonb_strip_nulls(jsonb_build_object('similarity', f.restates_similarity))
        FROM facts f WHERE f.restates_fact_id IS NOT NULL
        """,
    ),
    "SUPPORTS": (
        "PotentialFact",
        "Fact",
        """
        SELECT f.id, f.distilled_fact_id, jsonb_strip_nulls(jsonb_build_object('similarity', f.distilled_similarity))
        FROM facts f WHERE f.distilled_fact_id IS NOT NULL AND f.restates_fact_id IS NULL
        """,
    ),
}


@dataclass
class GraphSummary:
    """What a rebuild projected; ``available`` is false where the server has no AGE."""

    available: bool
    vertices: dict[str, int] = field(default_factory=dict)
    edges: dict[str, int] = field(default_factory=dict)

    @property
    def message(self) -> str:
        if not self.available:
            return "no graph: this server has no Apache AGE"
        counts = [f"{n:,} {label}" for label, n in [*self.vertices.items(), *self.edges.items()]]
        return f"graph {GRAPH!r}: " + ", ".join(counts)


def age_available(session: Session) -> bool:
    """Whether the database has the AGE extension."""
    return bool(session.execute(text("SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'age')")).scalar())


def use_age(session: Session) -> None:
    """Load AGE into this session and put ``ag_catalog`` on its search path, for this transaction.

    The app preloads AGE and sets the search path when it starts Postgres; any
    other server needs both per session.
    """
    conn = session.connection()
    conn.exec_driver_sql("LOAD 'age'")
    conn.exec_driver_sql("""SET LOCAL search_path = "$user", public, ag_catalog""")


def rebuild_graph(session: Session) -> GraphSummary:
    """Drop and re-project the ``garage`` graph from the tables. Commits.

    A no-op returning ``available=False`` when the server has no AGE.
    """
    if not age_available(session):
        return GraphSummary(available=False)
    use_age(session)
    exists = session.execute(text("SELECT EXISTS (SELECT 1 FROM ag_catalog.ag_graph WHERE name = :g)"), {"g": GRAPH})
    if exists.scalar():
        session.execute(text("SELECT ag_catalog.drop_graph(:g, true)"), {"g": GRAPH})
    session.execute(text("SELECT ag_catalog.create_graph(:g)"), {"g": GRAPH})

    summary = GraphSummary(available=True)
    conn = session.connection()
    for label, (key, select) in VERTICES.items():
        session.execute(text("SELECT ag_catalog.create_vlabel(:g, :label)"), {"g": GRAPH, "label": label})
        inserted = conn.execute(
            text(
                f'INSERT INTO {GRAPH}."{label}" (properties) SELECT CAST(p::text AS ag_catalog.agtype) '
                f"FROM ({select}) AS v(rid, p)"
            )
        )
        summary.vertices[label] = inserted.rowcount
        # The relational id -> vertex id map the edges join through, and an index
        # so a Cypher MATCH on the id property is not a scan.
        session.execute(
            text(
                f'CREATE INDEX ON {GRAPH}."{label}" '
                f"(ag_catalog.agtype_access_operator(properties, '\"{key}\"'::ag_catalog.agtype))"
            )
        )
        session.execute(
            text(
                f"CREATE TEMP TABLE graph_ids_{label.lower()} ON COMMIT DROP AS "
                f"SELECT CAST(CAST(ag_catalog.agtype_access_operator(properties, '\"{key}\"'::ag_catalog.agtype) "
                f'AS text) AS bigint) AS rid, id AS gid FROM {GRAPH}."{label}"'
            )
        )
        session.execute(text(f"CREATE UNIQUE INDEX ON graph_ids_{label.lower()} (rid)"))

    for label, (source, target, select) in EDGES.items():
        session.execute(text("SELECT ag_catalog.create_elabel(:g, :label)"), {"g": GRAPH, "label": label})
        inserted = conn.execute(
            text(
                f'INSERT INTO {GRAPH}."{label}" (start_id, end_id, properties) '
                f"SELECT s.gid, t.gid, CAST(e.p::text AS ag_catalog.agtype) FROM ({select}) AS e(src, dst, p) "
                f"JOIN graph_ids_{source.lower()} s ON s.rid = e.src "
                f"JOIN graph_ids_{target.lower()} t ON t.rid = e.dst"
            )
        )
        summary.edges[label] = inserted.rowcount
    session.commit()
    log.info("%s", summary.message)
    return summary

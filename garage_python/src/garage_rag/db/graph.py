"""The corpus as an Apache AGE graph, projected from the relational tables.

The tables stay the source of truth; the graph ``garage`` is a projection of
them for openCypher queries, rebuilt whole by :func:`rebuild_graph` (``garage
graph rebuild``, and after every ``garage cluster-facts``). It exists only
where the server has AGE (the app's bundled Postgres; ``001_extensions.sql``
creates the extension where it is installed). Elsewhere :func:`age_available`
is false and nothing is projected.

Vertices carry the relational id and a few display properties; text, spans and
vectors stay in the tables (and vectors in the ``emb_``/``fact_emb_`` tables):

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

import json
import logging
import re
from dataclasses import dataclass, field
from typing import Any

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


# ---------------------------------------------------------------------------
# Reading the graph: what the app's Graph page shows
# ---------------------------------------------------------------------------

# The property a vertex is titled by, where one property reads as its name.
TITLE_PROPERTIES: dict[str, str] = {
    "Document": "title",
    "Author": "display_name",
    "PotentialFact": "fact",
    "Fact": "statement",
}

# The property holding the relational id, from VERTICES; an unknown label has none.
KEY_PROPERTIES: dict[str, str] = {label: key for label, (key, _) in VERTICES.items()}

_LABEL_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


@dataclass(frozen=True)
class GraphVertex:
    """One vertex: its graph id, label, relational id (``key``; 0 for a label without one) and properties."""

    id: int
    label: str
    key: int
    title: str
    properties: dict[str, Any]


@dataclass(frozen=True)
class GraphEdge:
    """One edge between two graph ids."""

    id: int
    label: str
    source_id: int
    target_id: int
    properties: dict[str, Any]


@dataclass
class GraphLabels:
    """The labels the graph has, with a count of each; ``available`` is false without AGE or a graph."""

    available: bool
    vertices: dict[str, int] = field(default_factory=dict)
    edges: dict[str, int] = field(default_factory=dict)


@dataclass
class Neighborhood:
    """A vertex and everything within ``depth`` hops of it, under the label filters.

    ``truncated`` says the vertex limit cut the walk short; ``vertices`` includes
    the center.
    """

    available: bool
    center: GraphVertex | None = None
    vertices: list[GraphVertex] = field(default_factory=list)
    edges: list[GraphEdge] = field(default_factory=list)
    truncated: bool = False


def graph_exists(session: Session) -> bool:
    """Whether the server has AGE and the ``garage`` graph has been projected."""
    if not age_available(session):
        return False
    return bool(
        session.execute(
            text("SELECT EXISTS (SELECT 1 FROM ag_catalog.ag_graph WHERE name = :g)"), {"g": GRAPH}
        ).scalar()
    )


def _label_names(session: Session, kind: str) -> list[str]:
    """The graph's labels of one kind (``v`` or ``e``), without AGE's own ``_ag_label_*`` parents."""
    rows = session.execute(
        text(
            "SELECT l.name FROM ag_catalog.ag_label l JOIN ag_catalog.ag_graph g ON g.graphid = l.graph "
            "WHERE g.name = :g AND l.kind = :kind AND l.name NOT LIKE '\\_ag\\_%' ORDER BY l.name"
        ),
        {"g": GRAPH, "kind": kind},
    )
    return [str(r[0]) for r in rows if _LABEL_NAME.match(str(r[0]))]


def label_from_relation(relation: str) -> str:
    """The label of a label table from its ``regclass`` text: ``garage."Document"`` -> ``Document``."""
    name = relation.rsplit(".", 1)[-1]
    return name.strip('"').replace('""', '"')


def parse_properties(raw: str | None) -> dict[str, Any]:
    """An agtype map's text as a dict; agtype prints maps as JSON, bar the odd ``::numeric`` suffix."""
    if not raw:
        return {}
    try:
        value = json.loads(raw)
    except ValueError:
        try:
            value = json.loads(re.sub(r"::(numeric|vertex|edge|path)\b", "", raw))
        except ValueError:
            return {"raw": raw}
    return value if isinstance(value, dict) else {"value": value}


def vertex_title(label: str, properties: dict[str, Any]) -> str:
    """What a vertex is called on screen: its title property, else something from the rest."""
    prop = TITLE_PROPERTIES.get(label)
    if prop:
        value = properties.get(prop)
        if isinstance(value, str) and value.strip():
            return value.strip()
    if label == "Document":
        uri = properties.get("uri")
        if isinstance(uri, str) and uri:
            return uri.rstrip("/").rsplit("/", 1)[-1] or uri
    if label == "Chunk" and "ord" in properties:
        return f"Chunk {properties['ord']}"
    for value in properties.values():
        if isinstance(value, str) and value.strip():
            return value.strip()
    key = KEY_PROPERTIES.get(label)
    if key and key in properties:
        return f"{label} {properties[key]}"
    return label


def _vertex(gid: str, relation: str, raw: str | None) -> GraphVertex:
    label = label_from_relation(relation)
    properties = parse_properties(raw)
    key = properties.get(KEY_PROPERTIES.get(label, ""), 0)
    return GraphVertex(
        id=int(gid),
        label=label,
        key=int(key) if isinstance(key, int) and not isinstance(key, bool) else 0,
        title=vertex_title(label, properties),
        properties=properties,
    )


_VERTEX_COLUMNS = "CAST(v.id AS text), CAST(v.tableoid::regclass AS text), ag_catalog.agtype_out(v.properties)::text"
_EDGE_COLUMNS = (
    "CAST(e.id AS text), CAST(e.tableoid::regclass AS text), CAST(e.start_id AS text), CAST(e.end_id AS text), "
    "ag_catalog.agtype_out(e.properties)::text"
)


def _label_oids(alias: str, labels: list[str] | None) -> str:
    """A clause keeping the rows of the given label tables, on a query of their inherited parent table."""
    if labels is None:
        return ""
    return (
        f" AND {alias}.tableoid IN (SELECT c.oid FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace "
        "WHERE n.nspname = :graph AND c.relname = ANY(CAST(:labels AS text[])))"
    )


def _vertices_by_id(session: Session, ids: list[int], labels: list[str] | None) -> list[GraphVertex]:
    if not ids:
        return []
    rows = session.execute(
        text(
            f'SELECT {_VERTEX_COLUMNS} FROM {GRAPH}."_ag_label_vertex" v '
            f"WHERE v.id = ANY(CAST(CAST(:ids AS text[]) AS ag_catalog.graphid[])){_label_oids('v', labels)} "
            "ORDER BY v.id"
        ),
        {"ids": [str(i) for i in ids], "graph": GRAPH, "labels": labels},
    )
    return [_vertex(*r) for r in rows]


def graph_labels(session: Session) -> GraphLabels:
    """Every label the projected graph has, with how many vertices or edges carry it."""
    if not graph_exists(session):
        return GraphLabels(available=False)
    use_age(session)
    labels = GraphLabels(available=True)
    for name in _label_names(session, "v"):
        labels.vertices[name] = int(session.execute(text(f'SELECT count(*) FROM {GRAPH}."{name}"')).scalar_one())
    for name in _label_names(session, "e"):
        labels.edges[name] = int(session.execute(text(f'SELECT count(*) FROM {GRAPH}."{name}"')).scalar_one())
    return labels


def find_vertex(session: Session, label: str, key: int) -> GraphVertex | None:
    """The vertex of ``label`` whose relational id is ``key`` (a document id for ``Document``, ...)."""
    if label not in _label_names(session, "v"):
        raise LookupError(f"the graph has no {label!r} vertices")
    prop = KEY_PROPERTIES.get(label)
    if prop is None:
        raise ValueError(f"{label!r} vertices have no relational id; look one up by graph id")
    rows = session.execute(
        text(
            f'SELECT {_VERTEX_COLUMNS} FROM {GRAPH}."{label}" v '
            f"WHERE ag_catalog.agtype_access_operator(v.properties, '\"{prop}\"'::ag_catalog.agtype) "
            "= CAST(CAST(:key AS text) AS ag_catalog.agtype) LIMIT 1"
        ),
        {"key": int(key)},
    )
    row = rows.first()
    return _vertex(*row) if row else None


def find_vertices(session: Session, query: str, *, label: str = "", limit: int = 50) -> list[GraphVertex]:
    """Vertices whose title contains ``query`` (case-insensitively), or whose relational id is it.

    ``label`` narrows to one label; an empty ``query`` lists the first vertices
    of each searchable label. Chunks have no title and are found through their
    documents.
    """
    if not graph_exists(session):
        return []
    use_age(session)
    labels = _label_names(session, "v")
    if label:
        if label not in labels:
            raise LookupError(f"the graph has no {label!r} vertices")
        labels = [label]
    query = query.strip()
    key = int(query) if query.isdigit() else None
    found: list[GraphVertex] = []
    for name in labels:
        prop = TITLE_PROPERTIES.get(name)
        clauses: list[str] = []
        if prop and query:
            clauses.append(
                f"CAST(ag_catalog.agtype_access_operator(v.properties, '\"{prop}\"'::ag_catalog.agtype) AS text) "
                "ILIKE :pattern"
            )
        key_prop = KEY_PROPERTIES.get(name)
        if key is not None and key_prop:
            clauses.append(
                f"ag_catalog.agtype_access_operator(v.properties, '\"{key_prop}\"'::ag_catalog.agtype) "
                "= CAST(CAST(:key AS text) AS ag_catalog.agtype)"
            )
        if query and not clauses:
            continue
        where = f"WHERE {' OR '.join(clauses)}" if clauses else ""
        rows = session.execute(
            text(f'SELECT {_VERTEX_COLUMNS} FROM {GRAPH}."{name}" v {where} ORDER BY v.id LIMIT :limit'),
            {"pattern": f"%{_like_escape(query)}%", "key": key, "limit": max(1, limit - len(found))},
        )
        found.extend(_vertex(*r) for r in rows)
        if len(found) >= limit:
            break
    return found[:limit]


def _like_escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


def neighborhood(
    session: Session,
    *,
    vertex_id: int | None = None,
    label: str = "",
    key: int | None = None,
    depth: int = 1,
    vertex_labels: list[str] | None = None,
    edge_labels: list[str] | None = None,
    limit: int = 200,
) -> Neighborhood:
    """Walk ``depth`` hops out from a vertex, named by graph id or by label and relational id.

    ``vertex_labels`` and ``edge_labels`` keep only those labels (``None`` keeps
    all); an excluded vertex is neither shown nor walked through. The walk stops
    at ``limit`` vertices, breadth first, and says so with ``truncated``.
    Raises ``LookupError`` when the vertex is not in the graph.
    """
    if not graph_exists(session):
        return Neighborhood(available=False)
    use_age(session)
    if vertex_id:
        found = _vertices_by_id(session, [vertex_id], None)
        center = found[0] if found else None
    elif label and key is not None:
        center = find_vertex(session, label, key)
    else:
        raise ValueError("name the vertex by graph id, or by label and relational id")
    if center is None:
        raise LookupError("that vertex is not in the graph; rebuild it with `garage graph rebuild`")

    depth = max(0, min(depth, 6))
    limit = max(1, limit)
    vertices: dict[int, GraphVertex] = {center.id: center}
    edges: dict[int, GraphEdge] = {}
    frontier = [center.id]
    truncated = False
    allowed = set(vertex_labels) if vertex_labels is not None else None
    for _ in range(depth):
        if not frontier or len(vertices) >= limit:
            break
        rows = session.execute(
            text(
                f'SELECT {_EDGE_COLUMNS} FROM {GRAPH}."_ag_label_edge" e '
                "WHERE (e.start_id = ANY(CAST(CAST(:ids AS text[]) AS ag_catalog.graphid[])) "
                "OR e.end_id = ANY(CAST(CAST(:ids AS text[]) AS ag_catalog.graphid[])))"
                f"{_label_oids('e', edge_labels)} ORDER BY e.id"
            ),
            {"ids": [str(i) for i in frontier], "graph": GRAPH, "labels": edge_labels},
        ).all()
        hop_edges = [
            GraphEdge(int(eid), label_from_relation(rel), int(src), int(dst), parse_properties(props))
            for eid, rel, src, dst, props in rows
        ]
        new_ids = sorted(({e.source_id for e in hop_edges} | {e.target_id for e in hop_edges}) - vertices.keys())
        room = limit - len(vertices)
        if len(new_ids) > room:
            truncated = True
        new_vertices = _vertices_by_id(session, new_ids, vertex_labels)
        if allowed is not None:
            new_vertices = [v for v in new_vertices if v.label in allowed]
        if len(new_vertices) > room:
            new_vertices = new_vertices[:room]
        for v in new_vertices:
            vertices[v.id] = v
        for e in hop_edges:
            if e.source_id in vertices and e.target_id in vertices:
                edges[e.id] = e
        frontier = [v.id for v in new_vertices]
    return Neighborhood(
        available=True,
        center=center,
        vertices=list(vertices.values()),
        edges=list(edges.values()),
        truncated=truncated,
    )

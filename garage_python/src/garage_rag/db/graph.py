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
                   ``nodes``, ``spread``, ``drift`` (how varied its group is; see enrich/clusters.py),
                   ``anchor_key`` (a metadata value's key, for an anchored fact)
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

Configured labels (``facts.prompts[].graph``; :func:`garage_rag.config.fact_prompts.graph_schema`):

* a vertex entry projects the distilled facts of its class as vertices of its
  label instead of ``Fact`` (``distilled_fact_id``, ``fact_class``, ``title``,
  ``statement``, ``nodes``, ``anchor_key``), and their potential facts'
  ``SUPPORTS`` edges point there;
* an edge entry projects each potential fact of its class as an edge from the
  distilled fact its ``source`` attribute names to the one its ``target``
  attribute names (``fact_id``, ``document_id``, ``predicate``, ``fact``),
  labelled by ``label_attribute`` from ``labels``, else ``label``. A name is
  resolved in the fact's own document first (a fact of that class quoting it,
  or whose title attribute is it), then by a distilled fact stating it; an
  edge whose end does not resolve is left out.

The rebuild writes the label tables directly (``INSERT INTO garage."Document"``)
rather than through ``cypher()``: one statement per label instead of one
``MERGE`` per row, and no value is ever interpolated into a Cypher body.
"""

from __future__ import annotations

import json
import logging
import re
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any

from sqlalchemy import text
from sqlalchemy.orm import Session

from garage_rag.config.fact_prompts import GraphSchema

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
                   'drift', df.drift, 'anchor_key', df.anchor_key))
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


@dataclass(frozen=True)
class VertexSet:
    label: str
    key: str
    select: str
    params: dict = field(default_factory=dict)


@dataclass(frozen=True)
class EdgeSet:
    label: str
    source: str
    target: str
    select: str
    params: dict = field(default_factory=dict)


def _configured_schema() -> GraphSchema:
    from garage_rag.config import get_settings
    from garage_rag.config.fact_prompts import effective_prompts, graph_schema

    return graph_schema(effective_prompts(get_settings().fact_prompts))


def _resolve_end(attribute: str, fact_class: str, title: str) -> str:
    """SQL for the distilled fact of ``fact_class`` a relation fact ``r``'s attribute names."""
    name = f"r.attributes->>CAST(:{attribute} AS text)"
    return f"""coalesce(
        (SELECT m.distilled_fact_id FROM facts m
         WHERE m.document_id = r.document_id AND m.fact_class = :{fact_class} AND m.distilled_fact_id IS NOT NULL
           AND (lower(m.fact) = lower({name}) OR lower(m.attributes->>CAST(:{title} AS text)) = lower({name}))
         ORDER BY m.id LIMIT 1),
        (SELECT d.id FROM distilled_facts d
         WHERE d.fact_class = :{fact_class} AND lower(d.statement) = lower({name})
         ORDER BY d.id LIMIT 1))"""


def projection(schema: GraphSchema) -> tuple[list[VertexSet], list[EdgeSet]]:
    """The vertex and edge sets a rebuild writes: the built-in ones, then the configured ones."""
    mapped = sorted(schema.vertices)
    vertices = [VertexSet(label, key, select) for label, (key, select) in VERTICES.items()]
    edges = [EdgeSet(label, source, target, select) for label, (source, target, select) in EDGES.items()]
    if mapped:
        # A configured class's distilled facts are vertices of its label, not Fact.
        not_mapped = "JOIN distilled_facts dm ON dm.id = {id} WHERE NOT (dm.fact_class = ANY(CAST(:mapped AS text[])))"
        vertices = [
            VertexSet(
                v.label,
                v.key,
                f"SELECT x.* FROM ({v.select}) x(rid, p) {not_mapped.format(id='x.rid')}",
                {"mapped": mapped},
            )
            if v.label == "Fact"
            else v
            for v in vertices
        ]
        edges = [
            EdgeSet(
                e.label,
                e.source,
                e.target,
                f"SELECT x.* FROM ({e.select}) x(src, dst, p) {not_mapped.format(id='x.dst')}",
                {"mapped": mapped},
            )
            if e.label == "SUPPORTS"
            else e
            for e in edges
        ]
    for fact_class, vertex in schema.vertices.items():
        params = {"cls": fact_class, "title": vertex.title}
        vertices.append(
            VertexSet(
                vertex.label,
                "distilled_fact_id",
                """
                SELECT df.id, jsonb_strip_nulls(jsonb_build_object(
                           'distilled_fact_id', df.id, 'fact_class', df.fact_class,
                           'title', coalesce(nullif(rep.attributes->>CAST(:title AS text), ''), df.statement),
                           'statement', df.statement, 'nodes', df.nodes, 'anchor_key', df.anchor_key))
                FROM distilled_facts df LEFT JOIN facts rep ON rep.id = df.representative_fact_id
                WHERE df.fact_class = :cls
                """,
                params,
            )
        )
        edges.append(
            EdgeSet(
                "SUPPORTS",
                "PotentialFact",
                vertex.label,
                """
                SELECT f.id, f.distilled_fact_id,
                       jsonb_strip_nulls(jsonb_build_object('similarity', f.distilled_similarity))
                FROM facts f JOIN distilled_facts df ON df.id = f.distilled_fact_id
                WHERE f.restates_fact_id IS NULL AND df.fact_class = :cls
                """,
                {"cls": fact_class},
            )
        )
    for edge in schema.edges:
        source_title = schema.vertices[edge.source_class].title if edge.source_class in schema.vertices else None
        target_title = schema.vertices[edge.target_class].title if edge.target_class in schema.vertices else None
        picked = (
            "upper(regexp_replace(trim(r.attributes->>CAST(:label_attribute AS text)), '[^A-Za-z0-9]+', '_', 'g'))"
            if edge.label_attribute
            else "NULL"
        )
        for label in dict.fromkeys([*edge.labels, edge.label]):
            edges.append(
                EdgeSet(
                    label,
                    schema.label_for(edge.source_class),
                    schema.label_for(edge.target_class),
                    f"""
                    SELECT {_resolve_end("source", "source_class", "source_title")},
                           {_resolve_end("target", "target_class", "target_title")},
                           jsonb_strip_nulls(jsonb_build_object(
                               'fact_id', r.id, 'document_id', r.document_id, 'fact', r.fact,
                               'predicate', r.attributes->>CAST(:label_attribute AS text)))
                    FROM facts r
                    WHERE r.fact_class = :cls AND r.restates_fact_id IS NULL
                      AND (CASE WHEN {picked} = ANY(CAST(:labels AS text[])) THEN {picked} ELSE :fallback END)
                          = :label
                    """,
                    {
                        "cls": edge.extraction_class,
                        "source": edge.source,
                        "source_class": edge.source_class,
                        "source_title": source_title,
                        "target": edge.target,
                        "target_class": edge.target_class,
                        "target_title": target_title,
                        "label_attribute": edge.label_attribute,
                        "labels": list(edge.labels),
                        "fallback": edge.label,
                        "label": label,
                    },
                )
            )
    return vertices, edges


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


def rebuild_graph(session: Session, schema: GraphSchema | None = None) -> GraphSummary:
    """Drop and re-project the ``garage`` graph from the tables. Commits.

    ``schema`` is the configured labels (default: ``facts.prompts``' graph
    blocks). A no-op returning ``available=False`` when the server has no AGE.
    """
    if not age_available(session):
        return GraphSummary(available=False)
    vertex_sets, edge_sets = projection(schema if schema is not None else _configured_schema())
    use_age(session)
    exists = session.execute(text("SELECT EXISTS (SELECT 1 FROM ag_catalog.ag_graph WHERE name = :g)"), {"g": GRAPH})
    if exists.scalar():
        session.execute(text("SELECT ag_catalog.drop_graph(:g, true)"), {"g": GRAPH})
    session.execute(text("SELECT ag_catalog.create_graph(:g)"), {"g": GRAPH})

    summary = GraphSummary(available=True)
    conn = session.connection()
    for vertex_set in vertex_sets:
        label, key, select = vertex_set.label, vertex_set.key, vertex_set.select
        session.execute(text("SELECT ag_catalog.create_vlabel(:g, :label)"), {"g": GRAPH, "label": label})
        inserted = conn.execute(
            text(
                f'INSERT INTO {GRAPH}."{label}" (properties) SELECT CAST(p::text AS ag_catalog.agtype) '
                f"FROM ({select}) AS v(rid, p)"
            ),
            vertex_set.params,
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

    for edge_set in edge_sets:
        label, source, target, select = edge_set.label, edge_set.source, edge_set.target, edge_set.select
        if label not in summary.edges:
            session.execute(text("SELECT ag_catalog.create_elabel(:g, :label)"), {"g": GRAPH, "label": label})
            summary.edges[label] = 0
        inserted = conn.execute(
            text(
                f'INSERT INTO {GRAPH}."{label}" (start_id, end_id, properties) '
                f"SELECT s.gid, t.gid, CAST(e.p::text AS ag_catalog.agtype) FROM ({select}) AS e(src, dst, p) "
                f"JOIN graph_ids_{source.lower()} s ON s.rid = e.src "
                f"JOIN graph_ids_{target.lower()} t ON t.rid = e.dst"
            ),
            edge_set.params,
        )
        summary.edges[label] += inserted.rowcount
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

# The property holding the relational id, from VERTICES.
KEY_PROPERTIES: dict[str, str] = {label: key for label, (key, _) in VERTICES.items()}


def title_property(label: str) -> str | None:
    """The property ``label``'s vertices are titled by: a built-in's, else a configured label's ``title``."""
    return TITLE_PROPERTIES.get(label) if label in VERTICES else "title"


def key_property(label: str) -> str | None:
    """The property holding ``label``'s relational id; a configured label's is its distilled fact's."""
    return KEY_PROPERTIES.get(label) if label in VERTICES else "distilled_fact_id"


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
    prop = title_property(label)
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
    key = key_property(label)
    if key and key in properties:
        return f"{label} {properties[key]}"
    return label


def _vertex(gid: str, relation: str, raw: str | None) -> GraphVertex:
    label = label_from_relation(relation)
    properties = parse_properties(raw)
    key = properties.get(key_property(label) or "", 0)
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
    prop = key_property(label)
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
    documents. The owner's own Author vertex (``is_self``) comes before other
    authors, so the Graph page can open on it.
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
        prop = title_property(name)
        clauses: list[str] = []
        if prop and query:
            clauses.append(
                f"CAST(ag_catalog.agtype_access_operator(v.properties, '\"{prop}\"'::ag_catalog.agtype) AS text) "
                "ILIKE :pattern"
            )
        key_prop = key_property(name)
        if key is not None and key_prop:
            clauses.append(
                f"ag_catalog.agtype_access_operator(v.properties, '\"{key_prop}\"'::ag_catalog.agtype) "
                "= CAST(CAST(:key AS text) AS ag_catalog.agtype)"
            )
        if query and not clauses:
            continue
        where = f"WHERE {' OR '.join(clauses)}" if clauses else ""
        order = (
            "CAST(ag_catalog.agtype_access_operator(v.properties, '\"is_self\"'::ag_catalog.agtype) AS text)"
            " = 'true' DESC, v.id"
            if name == "Author"
            else "v.id"
        )
        rows = session.execute(
            text(f'SELECT {_VERTEX_COLUMNS} FROM {GRAPH}."{name}" v {where} ORDER BY {order} LIMIT :limit'),
            {"pattern": f"%{_like_escape(query)}%", "key": key, "limit": max(1, limit - len(found))},
        )
        found.extend(_vertex(*r) for r in rows)
        if len(found) >= limit:
            break
    return found[:limit]


def _like_escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


# How many new neighbours one vertex contributes to a neighbourhood walk.
EDGES_PER_VERTEX = 20

# Edge labels by how much they say about a claim, most first; a configured relation label, not
# listed, ranks between RESTATES and STATES.
_EDGE_ORDER = ("SUPPORTS", "RESTATES", None, "STATES", "WROTE", "RECEIVED", "HAS_CHUNK")
_ROLE_ORDER = ("author", "sender", "committer", "recipient", "cc")


def _number(value: Any) -> float | None:
    return float(value) if isinstance(value, int | float) and not isinstance(value, bool) else None


def edge_rank(edge: GraphEdge) -> tuple:
    """Sort key for one vertex's edges, most germane first.

    By label (``_EDGE_ORDER``), then within a label: the closest statements
    (``similarity``), the surest attribution (``confidence``, then role), a
    document's facts in reading order (``char_start``) and chunks by ``ord``;
    the newest edge breaks ties.
    """
    label = edge.label if edge.label in _EDGE_ORDER else None
    p = edge.properties
    similarity = _number(p.get("similarity"))
    confidence = _number(p.get("confidence"))
    role = p.get("role")
    position = _number(p.get("char_start"))
    if position is None:
        position = _number(p.get("ord"))
    return (
        _EDGE_ORDER.index(label),
        -similarity if similarity is not None else float("inf"),
        -confidence if confidence is not None else float("inf"),
        _ROLE_ORDER.index(role) if role in _ROLE_ORDER else len(_ROLE_ORDER),
        position if position is not None else float("inf"),
        -edge.id,
    )


def _other_end(edge: GraphEdge, vertex_id: int) -> int:
    return edge.target_id if edge.source_id == vertex_id else edge.source_id


# Reciprocal Rank Fusion's k, as search uses (search/hybrid.py RRF_K).
RRF_K = 60

# Each neighbour's vector distance to the walk's center, by graph id; a neighbour with no vector
# to compare is left out.
Closeness = Callable[[Session, GraphVertex, list[GraphVertex]], dict[int, float]]


def _vector_source(vertex: GraphVertex, chunks: str, potential_facts: str, facts: str) -> str | None:
    """A SELECT of (relational id, embedding) holding ``vertex``'s kind, or None for a kind with no vector.

    A document's vector is the mean of its content chunks'; an author has none.
    """
    if vertex.label == "PotentialFact":
        return f"SELECT fact_id, embedding FROM {potential_facts}"
    if vertex.label == "Chunk":
        return f"SELECT chunk_id, embedding FROM {chunks}"
    if vertex.label == "Document":
        return (
            f"SELECT c.document_id, avg(e.embedding) FROM {chunks} e JOIN chunks c ON c.id = e.chunk_id "
            "WHERE c.fact_id IS NULL GROUP BY c.document_id"
        )
    if "distilled_fact_id" in vertex.properties:  # Fact, or a configured class's claim vertex
        return f"SELECT distilled_fact_id, embedding FROM {facts}"
    return None


def vector_closeness(session: Session, center: GraphVertex, neighbours: list[GraphVertex]) -> dict[int, float]:
    """Each neighbour's vector distance to the center's, under the default model (smaller is closer).

    Empty when the center has no vector, there is no default model, or the comparison fails.
    """
    from garage_rag.db.emb_tables import assert_safe_table, fact_table_name, get_model, potential_fact_table_name
    from garage_rag.db.registry import distance_operator

    try:
        with session.begin_nested():
            model = get_model(session)
            chunks = assert_safe_table(model.table_name)
            tables = (chunks, potential_fact_table_name(chunks), fact_table_name(chunks))
            center_source = _vector_source(center, *tables)
            if center_source is None or not center.key:
                return {}
            op = "<=>" if model.index_kind == "hnsw_bq" else distance_operator(model.distance)
            by_source: dict[str, list[GraphVertex]] = {}
            for vertex in neighbours:
                source = _vector_source(vertex, *tables)
                if source and vertex.key:
                    by_source.setdefault(source, []).append(vertex)
            found: dict[int, float] = {}
            for source, group in by_source.items():
                ids = {v.key: v.id for v in group}
                rows = session.execute(
                    text(
                        f"SELECT s.k, s.v {op} (SELECT r.v FROM ({center_source}) r(k, v) WHERE r.k = :center) "
                        f"FROM ({source}) s(k, v) WHERE s.k = ANY(CAST(:keys AS bigint[]))"
                    ),
                    {"keys": list(ids), "center": center.key},
                ).all()
                found.update({ids[int(key)]: float(distance) for key, distance in rows if distance is not None})
            return found
    except Exception as exc:  # no model yet, a table made before 017, ...: rank without vectors
        log.debug("graph: no vector closeness (%s)", exc)
        return {}


def _germane_order(
    outward: list[GraphEdge], vertex_id: int, links: dict[int, int], closeness: dict[int, float]
) -> list[int]:
    """``vertex_id``'s neighbours, most related to the walk's center first.

    The center is the context: Reciprocal Rank Fusion of how close a neighbour's
    vector is to the center's (``closeness``), how many vertices already in the
    picture it links to (``links``: what it has in common with the center's
    surroundings) and the strength of the edge that reaches it (``edge_rank``). A
    neighbour missing from a ranking (an author has no vector) gets no term from it.
    """
    by_edge = list(dict.fromkeys(_other_end(e, vertex_id) for e in sorted(outward, key=edge_rank)))
    scores = dict.fromkeys(by_edge, 0.0)
    rankings = [
        [vid for _, vid in sorted((d, vid) for vid, d in closeness.items() if vid in scores)],
        [vid for n, vid in sorted((-links.get(vid, 0), vid) for vid in by_edge) if n < -1],
        by_edge,
    ]
    for ranking in rankings:
        for rank, vid in enumerate(ranking, start=1):
            scores[vid] += 1.0 / (RRF_K + rank)
    position = {vid: i for i, vid in enumerate(by_edge)}
    return sorted(by_edge, key=lambda vid: (-scores[vid], position[vid]))


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
    edges_per_vertex: int = EDGES_PER_VERTEX,
    closeness: Closeness | None = None,
) -> Neighborhood:
    """Walk ``depth`` hops out from a vertex, named by graph id or by label and relational id.

    ``vertex_labels`` and ``edge_labels`` keep only those labels (``None`` keeps
    all); an excluded vertex is neither shown nor walked through. The center is
    the context: each vertex reaches at most ``edges_per_vertex`` new
    neighbours, and when it has more they are ranked by how related they are to
    the center (``_germane_order``, with ``closeness`` defaulting to
    ``vector_closeness``), at every hop. An edge to a vertex already in the
    picture is always kept, so the way back to the center never goes. The walk
    stops at ``limit`` vertices, breadth first. Either cut sets ``truncated``.
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
        raise LookupError("that vertex is not in the graph yet; Distill Facts or `garage graph rebuild` projects it")

    depth = max(0, min(depth, 6))
    limit = max(1, limit)
    edges_per_vertex = max(1, edges_per_vertex)
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
        candidate_ids = sorted(({e.source_id for e in hop_edges} | {e.target_id for e in hop_edges}) - vertices.keys())
        candidates = {v.id: v for v in _vertices_by_id(session, candidate_ids, vertex_labels)}
        if allowed is not None:
            candidates = {i: v for i, v in candidates.items() if v.label in allowed}
        # Each vertex of the frontier reaches at most edges_per_vertex new neighbours, its most
        # germane edges first, so a hub (an author of thousands of documents) cannot fill the picture.
        picked: list[int] = []
        seen: set[int] = set()
        # How many vertices already in the picture each candidate links to: one is the edge that
        # reaches it; more is something it shares with the center's surroundings.
        linked: dict[int, set[int]] = {}
        for e in hop_edges:
            for near, far in ((e.source_id, e.target_id), (e.target_id, e.source_id)):
                if near in vertices and far in candidates:
                    linked.setdefault(far, set()).add(near)
        links = {vid: len(near) for vid, near in linked.items()}
        close: dict[int, float] | None = None
        for vid in frontier:
            outward = [
                e
                for e in hop_edges
                if vid in (e.source_id, e.target_id)
                and _other_end(e, vid) in candidates
                and _other_end(e, vid) not in seen
            ]
            fresh = list(dict.fromkeys(_other_end(e, vid) for e in sorted(outward, key=edge_rank)))
            if len(fresh) > edges_per_vertex:
                truncated = True
                if close is None:
                    close = (closeness or vector_closeness)(session, center, list(candidates.values()))
                fresh = _germane_order(outward, vid, links, close)[:edges_per_vertex]
            seen.update(fresh)
            picked.extend(fresh)
        room = limit - len(vertices)
        if len(picked) > room:
            truncated = True
            picked = picked[:room]
        new_vertices = [candidates[i] for i in picked]
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

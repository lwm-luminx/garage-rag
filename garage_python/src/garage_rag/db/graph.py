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

import logging
from dataclasses import dataclass, field

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

"""The corpus as an Apache AGE graph, projected from the relational tables.

The tables stay the source of truth; the graph ``garage`` is a projection of
them for openCypher queries, rebuilt whole by :func:`rebuild_graph` (``garage
graph rebuild``, and after every ``garage cluster-facts``). It exists only
where the server has AGE (the app's bundled Postgres; ``001_extensions.sql``
creates the extension where it is installed). Elsewhere :func:`age_available`
is false and nothing is projected.

Chunks are not in the graph: they are how text is cut up for embedding, an
implementation detail. What the graph shows is what a person would name: a
document, a message in a Messages thread, who wrote it, the links in it and the
facts it states. A fact hangs directly off the document, or off the message its
statement's span falls in.

Vertices carry the relational id and a few display properties; text, spans and
vectors stay in the tables (and vectors in the ``emb_``/``fact_emb_`` tables).
Every vertex says what it is in ``origin``: ``read`` from a source (``READ_LABELS``) or
``derived`` from what was read (facts, and configured classes). ``at`` is when the element
happened, ISO 8601 in UTC: a document's own time (:mod:`garage_rag.db.recency`), a message's
stamp, and for a distilled fact its most recent restatement's (the message or document stating
it), which ``latest_fact_id`` and ``latest_document_id`` name, so every fact traces back to a
dated document:

=================  ===============================================================
``Document``       ``document_id``, ``title``, ``uri``, ``corpus_class``, ``trust_tier``, ``at``
``Message``        ``message_id`` (its first chunk's id), ``document_id``, ``ord`` (its place in the
                   thread), ``direction``, ``sender``, ``at``, ``text`` (the first 280 characters)
``Author``         ``author_id``, ``display_name``, ``is_self``
``Link``           ``link_id`` (a hash of the href), ``href``, ``text`` (its commonest anchor text, else the href)
``Fact``           ``distilled_fact_id``, ``fact_class``, ``statement``, ``statement_generated``,
                   ``nodes``, ``spread``, ``drift`` (how varied its group is; see enrich/clusters.py),
                   ``anchor_key`` (a metadata value's key, for an anchored fact),
                   ``latest_fact_id``, ``latest_document_id``, ``at``
=================  ===============================================================

The facts a document states (``facts`` rows, the potential facts) are not
vertices: the graph shows only distilled facts, so a claim a document restates,
or that several documents state, is one vertex. A fact not yet distilled is not
in the graph until ``garage cluster-facts`` links it to one.

A Messages thread is one document with one chunk per message, and a message
longer than the chunk size several (ingest/conversations.py); the chunks of one
message are grouped back into one ``Message`` by the time-and-sender stamp only
a message's first chunk starts with (``MESSAGE_START_PATTERN``).

Edges:

===============  ==============================  ============================================================
``HAS_MESSAGE``  Document -> Message             ``ord``
``WROTE``        Author -> Document              ``role`` (author, committer, sender), ``confidence``
``RECEIVED``     Author -> Document              ``role`` (recipient, cc), ``confidence``
``SENT``         Author -> Message               ``direction``: the handle (or the owner, for ``me``) that wrote it
``STATES``       Document -> Fact                ``char_start``, ``char_end`` (its first statement there),
                                                 ``similarity`` (its closest statement's), ``statements``
                                                 (how many); statements outside every message
``STATES``       Message -> Fact                 the same, for statements whose span starts in that message
``LINKS_TO``     Document/Message -> Link        ``text``: the anchor text there, when it has one
``REFERS_TO``    Link -> Document                the link's href is that document's path
===============  ==============================  ============================================================

Links are found in the text: Markdown ``[text](href)``, HTML ``<a href>`` and
bare ``http(s)://`` URLs, in a document's content or, for a thread, in each
message (``LINK_PATTERNS``).

Configured labels (``facts.prompts[].graph``; :func:`garage_rag.config.fact_prompts.graph_schema`):

* a vertex entry projects the distilled facts of its class as vertices of its
  label instead of ``Fact`` (``distilled_fact_id``, ``fact_class``, ``title``,
  ``statement``, ``nodes``, ``anchor_key``, ``latest_fact_id``, ``at``), and
  the ``STATES`` edges of their documents and messages point there;
* an edge entry projects each extracted fact of its class as an edge from the
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
from garage_rag.db.recency import document_time_sql, iso_utc_sql
from garage_rag.extract.messages import MESSAGE_START_PATTERN

log = logging.getLogger(__name__)

GRAPH = "garage"

# The patterns links are found by, bound as parameters (a regex's ``(?:`` would read as a bind
# parameter in the SQL text). Postgres AREs: ``md_link`` captures (text, href), ``html_link``
# (href, text), ``bare_link`` the URL, whose trailing punctuation is trimmed.
LINK_PATTERNS: dict[str, str] = {
    "md_link": r"\[([^]\n]{1,255})\]\(((?:https?|mailto|file):[^)[:space:]]+)\)",
    "html_link": r"""<a\s[^>]*href\s*=\s*["']([^"'>]+)["'][^>]*>([^<]{0,255})</a>""",
    "bare_link": r"""https?://[^][:space:]<>"'(){}[]+""",
}

# Every built-in set's parameters: the message stamp and the link patterns.
PARAMS: dict[str, str] = {
    "message_start": MESSAGE_START_PATTERN,
    # The same stamp, capturing its date and time.
    "message_stamp": MESSAGE_START_PATTERN.replace("^\\[", "^\\[(", 1).replace(" UTC\\]", ") UTC\\]", 1),
    **LINK_PATTERNS,
}

# Each message chunk with the message it belongs to: ``n`` counts the message starts up to it, and
# the message's id is the id of its first chunk.
CHUNK_MESSAGES = """
    SELECT s.chunk_id, s.document_id, s.ord, s.text, s.char_start, s.char_end, s.direction, s.sender, s.n,
           min(s.chunk_id) OVER (PARTITION BY s.document_id, s.n) AS message_id
    FROM (SELECT c.id AS chunk_id, c.document_id, c.ord, c.text, c.char_start, c.char_end, c.direction, c.sender,
                 count(*) FILTER (WHERE c.text ~ CAST(:message_start AS text))
                     OVER (PARTITION BY c.document_id ORDER BY c.ord) AS n
          FROM chunks c WHERE c.direction IS NOT NULL AND c.fact_id IS NULL) s
"""

# One row per message: its text whole, its span of the document, and its stamp's time.
MESSAGES = f"""
    SELECT m.message_id, m.document_id, min(m.n) AS n, string_agg(m.text, ' ' ORDER BY m.ord) AS text,
           min(m.char_start) AS char_start, max(m.char_end) AS char_end,
           min(m.direction) AS direction, min(m.sender) AS sender,
           min(substring(m.text FROM CAST(:message_stamp AS text))) AS stamp
    FROM ({CHUNK_MESSAGES}) m GROUP BY m.message_id, m.document_id
"""

# The message each fact's span starts in, for the facts of a thread.
FACT_MESSAGES = f"""
    SELECT f.id AS fact_id, msg.message_id, msg.stamp
    FROM facts f JOIN ({MESSAGES}) msg ON msg.document_id = f.document_id
     AND f.char_start >= msg.char_start AND f.char_start < msg.char_end
"""

# The text links are looked for in: a thread's messages, and every other document's content.
_LINK_SOURCES = f"""
    SELECT 'Document' AS src_label, d.id AS src_id, d.content AS body FROM documents d
    WHERE d.content IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM chunks c WHERE c.document_id = d.id AND c.direction IS NOT NULL)
    UNION ALL
    SELECT 'Message', msg.message_id, msg.text FROM ({MESSAGES}) msg
"""

# One row per (document or message, href), with the anchor text there when it has one.
LINKS = f"""
    SELECT s.src_label, s.src_id, l.href, max(nullif(trim(l.text), '')) AS text
    FROM ({_LINK_SOURCES}) s CROSS JOIN LATERAL (
        SELECT x[2] AS href, x[1] AS text FROM regexp_matches(s.body, CAST(:md_link AS text), 'g') x
        UNION ALL
        SELECT x[1], x[2] FROM regexp_matches(s.body, CAST(:html_link AS text), 'gi') x
        UNION ALL
        SELECT regexp_replace(x[1], '[.,;!?]+$', ''), NULL FROM regexp_matches(s.body, CAST(:bare_link AS text), 'g') x
    ) l
    WHERE l.href <> ''
    GROUP BY s.src_label, s.src_id, l.href
"""

_LINK_ID = "hashtextextended(k.href, 0)"
_DOCUMENT_AT = iso_utc_sql(document_time_sql("d"))
# A message's stamp is UTC to the minute ('2026-09-24 18:03'); no ':' literal, which SQLAlchemy would bind.
_MESSAGE_AT = iso_utc_sql("CAST(msg.stamp || ' UTC' AS timestamptz)")

# When each potential fact was stated: its message's time when it is from a message, else its
# document's (db/recency.py). Distilled facts take the time of their most recent restatement.
FACT_TIMES = f"""
    SELECT f.id AS fact_id, f.document_id, f.distilled_fact_id,
           coalesce({iso_utc_sql("CAST(fm.stamp || ' UTC' AS timestamptz)")}, {_DOCUMENT_AT}) AS at
    FROM facts f JOIN documents d ON d.id = f.document_id
    LEFT JOIN ({FACT_MESSAGES}) fm ON fm.fact_id = f.id
"""

# Each distilled fact's most recent restatement: (distilled_fact_id, latest_fact_id, latest_document_id, at).
LATEST_RESTATEMENTS = f"""
    SELECT DISTINCT ON (ft.distilled_fact_id) ft.distilled_fact_id, ft.fact_id AS latest_fact_id,
           ft.document_id AS latest_document_id, ft.at
    FROM ({FACT_TIMES}) ft WHERE ft.distilled_fact_id IS NOT NULL
    ORDER BY ft.distilled_fact_id, ft.at DESC NULLS LAST, ft.fact_id DESC
"""

# What a vertex is: ``read`` from a source (a document, a message, who wrote it, a link in it), or
# ``derived`` by Garage from what it read (distilled facts, configured classes).
READ_LABELS = frozenset({"Document", "Message", "Author", "Link"})


def origin(label: str) -> str:
    """``read`` or ``derived``: whether ``label``'s vertices were read from a source or derived from one."""
    return "read" if label in READ_LABELS else "derived"


# label -> (id property, SELECT of (relational id, jsonb properties)); every one is run with PARAMS.
VERTICES: dict[str, tuple[str, str]] = {
    "Document": (
        "document_id",
        f"""
        SELECT d.id, jsonb_build_object('origin', 'read', 'document_id', d.id, 'title', d.title, 'uri', d.uri,
                                        'corpus_class', d.corpus_class::text, 'trust_tier', d.trust_tier::text,
                                        'at', {_DOCUMENT_AT})
        FROM documents d
        """,
    ),
    "Message": (
        "message_id",
        f"""
        SELECT msg.message_id, jsonb_strip_nulls(jsonb_build_object(
                   'origin', 'read', 'message_id', msg.message_id, 'document_id', msg.document_id, 'ord', msg.n,
                   'direction', msg.direction, 'sender', msg.sender, 'at', {_MESSAGE_AT},
                   'text', left(msg.text, 280)))
        FROM ({MESSAGES}) msg
        """,
    ),
    "Author": (
        "author_id",
        """
        SELECT a.id, jsonb_build_object('origin', 'read', 'author_id', a.id, 'display_name', a.display_name,
                                        'is_self', a.is_self)
        FROM authors a
        """,
    ),
    "Link": (
        "link_id",
        f"""
        SELECT {_LINK_ID}, jsonb_build_object(
                   'origin', 'read', 'link_id', {_LINK_ID}, 'href', k.href,
                   'text', coalesce(mode() WITHIN GROUP (ORDER BY k.text) FILTER (WHERE k.text IS NOT NULL), k.href))
        FROM ({LINKS}) k GROUP BY k.href
        """,
    ),
    "Fact": (
        "distilled_fact_id",
        f"""
        SELECT df.id, jsonb_strip_nulls(jsonb_build_object(
                   'origin', 'derived', 'distilled_fact_id', df.id, 'fact_class', df.fact_class,
                   'statement', df.statement, 'statement_generated', df.statement_generated, 'nodes', df.nodes,
                   'spread', df.spread, 'drift', df.drift, 'anchor_key', df.anchor_key,
                   'latest_fact_id', lr.latest_fact_id, 'latest_document_id', lr.latest_document_id,
                   'at', lr.at))
        FROM distilled_facts df LEFT JOIN ({LATEST_RESTATEMENTS}) lr ON lr.distilled_fact_id = df.id
        """,
    ),
}


def states(source: str, join: str = "", where: str = "") -> str:
    """STATES from ``source`` (a document or message id) to each distilled fact it states, one edge
    however often: its first statement's span, its closest statement's similarity, how many."""
    return f"""
        SELECT {source}, f.distilled_fact_id, jsonb_strip_nulls(jsonb_build_object(
                   'char_start', (array_agg(f.char_start ORDER BY f.char_start NULLS LAST, f.id))[1],
                   'char_end', (array_agg(f.char_end ORDER BY f.char_start NULLS LAST, f.id))[1],
                   'similarity', max(f.distilled_similarity), 'statements', count(*)))
        FROM facts f {join}
        WHERE f.distilled_fact_id IS NOT NULL {where}
        GROUP BY {source}, f.distilled_fact_id
        """


# A statement outside every message is the document's; one whose span starts in a message, the message's.
_IN_NO_MESSAGE = f"AND NOT EXISTS (SELECT 1 FROM ({FACT_MESSAGES}) fm WHERE fm.fact_id = f.id)"
_IN_A_MESSAGE = f"JOIN ({FACT_MESSAGES}) fm ON fm.fact_id = f.id"

# (label, from label, to label, SELECT of (from id, to id, jsonb properties)); every one is run with
# PARAMS. A label may appear more than once, between different labels.
EDGES: list[tuple[str, str, str, str]] = [
    (
        "HAS_MESSAGE",
        "Document",
        "Message",
        f"SELECT msg.document_id, msg.message_id, jsonb_build_object('ord', msg.n) FROM ({MESSAGES}) msg",
    ),
    (
        "WROTE",
        "Author",
        "Document",
        """
        SELECT da.author_id, da.document_id, jsonb_build_object('role', da.role::text, 'confidence', da.confidence)
        FROM document_authors da WHERE da.role IN ('author', 'committer', 'sender')
        """,
    ),
    (
        "RECEIVED",
        "Author",
        "Document",
        """
        SELECT da.author_id, da.document_id, jsonb_build_object('role', da.role::text, 'confidence', da.confidence)
        FROM document_authors da WHERE da.role IN ('recipient', 'cc')
        """,
    ),
    (
        "SENT",
        "Author",
        "Message",
        f"""
        SELECT DISTINCT a.author_id, msg.message_id, jsonb_build_object('direction', msg.direction)
        FROM ({MESSAGES}) msg CROSS JOIN LATERAL (
            SELECT ai.author_id FROM author_identities ai WHERE msg.sender <> 'me' AND ai.value = msg.sender
            UNION
            SELECT au.id FROM authors au WHERE msg.sender = 'me' AND au.is_self
        ) a
        """,
    ),
    ("STATES", "Document", "Fact", states("f.document_id", where=_IN_NO_MESSAGE)),
    ("STATES", "Message", "Fact", states("fm.message_id", join=_IN_A_MESSAGE)),
    (
        "LINKS_TO",
        "Document",
        "Link",
        f"""
        SELECT k.src_id, {_LINK_ID}, jsonb_strip_nulls(jsonb_build_object('text', k.text))
        FROM ({LINKS}) k WHERE k.src_label = 'Document'
        """,
    ),
    (
        "LINKS_TO",
        "Message",
        "Link",
        f"""
        SELECT k.src_id, {_LINK_ID}, jsonb_strip_nulls(jsonb_build_object('text', k.text))
        FROM ({LINKS}) k WHERE k.src_label = 'Message'
        """,
    ),
    (
        "REFERS_TO",
        "Link",
        "Document",
        f"""
        SELECT DISTINCT {_LINK_ID}, d.id, CAST('{{}}' AS jsonb)
        FROM ({LINKS}) k
        JOIN documents d ON d.uri = CASE WHEN k.href LIKE 'file://%' THEN substr(k.href, 8) ELSE k.href END
        """,
    ),
]

EDGE_LABELS: tuple[str, ...] = tuple(dict.fromkeys(label for label, *_ in EDGES))


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
    vertices = [VertexSet(label, key, select, dict(PARAMS)) for label, (key, select) in VERTICES.items()]
    edges = [EdgeSet(label, source, target, select, dict(PARAMS)) for label, source, target, select in EDGES]
    if mapped:
        # A configured class's distilled facts are vertices of its label, not Fact.
        not_mapped = "JOIN distilled_facts dm ON dm.id = {id} WHERE NOT (dm.fact_class = ANY(CAST(:mapped AS text[])))"
        vertices = [
            VertexSet(
                v.label,
                v.key,
                f"SELECT x.* FROM ({v.select}) x(rid, p) {not_mapped.format(id='x.rid')}",
                {**v.params, "mapped": mapped},
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
                {**e.params, "mapped": mapped},
            )
            if e.label == "STATES"
            else e
            for e in edges
        ]
    for fact_class, vertex in schema.vertices.items():
        params = {"cls": fact_class, "title": vertex.title}
        vertices.append(
            VertexSet(
                vertex.label,
                "distilled_fact_id",
                f"""
                SELECT df.id, jsonb_strip_nulls(jsonb_build_object(
                           'origin', 'derived', 'distilled_fact_id', df.id, 'fact_class', df.fact_class,
                           'title', coalesce(nullif(rep.attributes->>CAST(:title AS text), ''), df.statement),
                           'statement', df.statement, 'nodes', df.nodes, 'anchor_key', df.anchor_key,
                           'latest_fact_id', lr.latest_fact_id, 'latest_document_id', lr.latest_document_id,
                           'at', lr.at))
                FROM distilled_facts df LEFT JOIN facts rep ON rep.id = df.representative_fact_id
                LEFT JOIN ({LATEST_RESTATEMENTS}) lr ON lr.distilled_fact_id = df.id
                WHERE df.fact_class = :cls
                """,
                {**PARAMS, **params},
            )
        )
        of_class = "JOIN distilled_facts df ON df.id = f.distilled_fact_id"
        edges.append(
            EdgeSet(
                "STATES",
                "Document",
                vertex.label,
                states("f.document_id", join=of_class, where=f"AND df.fact_class = :cls {_IN_NO_MESSAGE}"),
                {**PARAMS, "cls": fact_class},
            )
        )
        edges.append(
            EdgeSet(
                "STATES",
                "Message",
                vertex.label,
                states("fm.message_id", join=f"{of_class} {_IN_A_MESSAGE}", where="AND df.fact_class = :cls"),
                {**PARAMS, "cls": fact_class},
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


# The shared subqueries a rebuild computes once, as temp tables, in dependency order: every set
# would otherwise group the messages, and scan every document's text for links, again.
MATERIALIZED: list[tuple[str, str]] = [
    ("graph_messages", MESSAGES),
    ("graph_fact_messages", FACT_MESSAGES),
    ("graph_links", LINKS),
    ("graph_fact_times", FACT_TIMES),
]


def _use_materialized(select: str, tables: list[tuple[str, str]]) -> str:
    """``select`` reading the temp ``tables`` in place of the subqueries they hold, the largest first."""
    for name, body in reversed(tables):
        select = select.replace(f"({body})", name)
    return select


def _materialize(session: Session) -> None:
    """Compute ``MATERIALIZED`` into temp tables, dropped at commit."""
    done: list[tuple[str, str]] = []
    for name, body in MATERIALIZED:
        session.execute(
            text(f"CREATE TEMP TABLE {name} ON COMMIT DROP AS {_use_materialized(body, done)}"), dict(PARAMS)
        )
        session.execute(text(f"ANALYZE {name}"))
        done.append((name, body))


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
    _materialize(session)
    for vertex_set in vertex_sets:
        label, key = vertex_set.label, vertex_set.key
        select = _use_materialized(vertex_set.select, MATERIALIZED)
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
        label, source, target = edge_set.label, edge_set.source, edge_set.target
        select = _use_materialized(edge_set.select, MATERIALIZED)
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
    "Message": "text",
    "Author": "display_name",
    "Link": "text",
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
    if label == "Link" and isinstance(properties.get("href"), str):
        return properties["href"]
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
    """The vertex of ``label`` whose relational id is ``key`` (a document id for ``Document``, ...).

    ``Fact`` names any distilled fact: one of a class a prompt's ``graph`` block
    maps to its own label is found under that label.
    """
    names = _label_names(session, "v")
    if label == "Fact":
        claims = [n for n in names if n == "Fact"] + [n for n in names if n != "Fact" and n not in VERTICES]
        for name in claims:
            found = _find_vertex(session, name, key)
            if found is not None:
                return found
        if claims:
            return None
    if label not in names:
        raise LookupError(f"the graph has no {label!r} vertices")
    return _find_vertex(session, label, key)


def _find_vertex(session: Session, label: str, key: int) -> GraphVertex | None:
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
    of each searchable label. Within a label the most recent come first
    (:func:`recency_order`). The owner's own Author vertex (``is_self``) comes
    before other authors, so the Graph page can open on it.
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
        order = f"{_IS_SELF} DESC, {recency_order(name)}" if name == "Author" else recency_order(name)
        rows = session.execute(
            text(f'SELECT {_VERTEX_COLUMNS} FROM {GRAPH}."{name}" v {where} ORDER BY {order} LIMIT :limit'),
            {"pattern": f"%{_like_escape(query)}%", "key": key, "limit": max(1, limit - len(found))},
        )
        vertices = [_vertex(*r) for r in rows]
        if name == "Author":
            _mark_self(session, vertices)
        found.extend(vertices)
        if len(found) >= limit:
            break
    return found[:limit]


def recency_order(label: str, alias: str = "v") -> str:
    """An ORDER BY putting ``label``'s most recent vertices first.

    By ``at`` where a vertex has it (a fact's is its most recent
    restatement's), else by relational id (the newest row last inserted),
    else by graph id.
    """
    keys = [f"ag_catalog.agtype_access_operator({alias}.properties, '\"at\"'::ag_catalog.agtype) DESC NULLS LAST"]
    key = key_property(label)
    if key and label != "Link":  # a link's id is a hash, in no order
        keys.append(f"ag_catalog.agtype_access_operator({alias}.properties, '\"{key}\"'::ag_catalog.agtype) DESC")
    keys.append(f"{alias}.id DESC")
    return ", ".join(keys)


# Whether an Author vertex is the owner's, read from ``authors`` rather than the projection: the
# owner is marked when ``identity.name`` is set (``ensure_self_author``), which can be after the
# graph was last rebuilt.
_IS_SELF = (
    "COALESCE((SELECT a.is_self FROM authors a WHERE a.id = CAST(CAST("
    "ag_catalog.agtype_access_operator(v.properties, '\"author_id\"'::ag_catalog.agtype) AS text) AS bigint)), false)"
)


def _mark_self(session: Session, vertices: list[GraphVertex]) -> None:
    """Set each Author vertex's ``is_self`` property to what ``authors`` says now."""
    owners = set(session.execute(text("SELECT id FROM authors WHERE is_self")).scalars())
    for vertex in vertices:
        vertex.properties["is_self"] = vertex.key in owners


def _like_escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


# How many new neighbours one vertex contributes to a neighbourhood walk.
EDGES_PER_VERTEX = 20

# Edge labels by how much they say about a claim, most first; a configured relation label, not
# listed, ranks first.
_EDGE_ORDER = (
    None,
    "STATES",
    "WROTE",
    "SENT",
    "RECEIVED",
    "HAS_MESSAGE",
    "LINKS_TO",
    "REFERS_TO",
)
_ROLE_ORDER = ("author", "sender", "committer", "recipient", "cc")


def _number(value: Any) -> float | None:
    return float(value) if isinstance(value, int | float) and not isinstance(value, bool) else None


def edge_rank(edge: GraphEdge) -> tuple:
    """Sort key for one vertex's edges, most germane first.

    By label (``_EDGE_ORDER``), then within a label: the closest statements
    (``similarity``), the surest attribution (``confidence``, then role), a
    document's facts in reading order (``char_start``) and messages by ``ord``;
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


def _vector_source(vertex: GraphVertex, chunks: str, facts: str) -> str | None:
    """A SELECT of (relational id, embedding) holding ``vertex``'s kind, or None for a kind with no vector.

    A document's vector is the mean of its content chunks', a message's of its own chunks'; an
    author and a link have none.
    """
    if vertex.label == "Message":
        # Only the threads of the messages compared (a message's id is its first chunk's), not every
        # message chunk in the corpus.
        threads = CHUNK_MESSAGES.replace(
            "WHERE c.direction IS NOT NULL AND c.fact_id IS NULL",
            "WHERE c.direction IS NOT NULL AND c.fact_id IS NULL AND c.document_id IN "
            "(SELECT t.document_id FROM chunks t WHERE t.id = ANY(CAST(:keys AS bigint[])) OR t.id = :center)",
        )
        return (
            f"SELECT cm.message_id, avg(e.embedding) FROM {chunks} e "
            f"JOIN ({threads}) cm ON cm.chunk_id = e.chunk_id GROUP BY cm.message_id"
        )
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
    from garage_rag.db.emb_tables import assert_safe_table, fact_table_name, get_model
    from garage_rag.db.registry import distance_operator

    try:
        with session.begin_nested():
            model = get_model(session)
            chunks = assert_safe_table(model.table_name)
            tables = (chunks, fact_table_name(chunks))
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
                    {"keys": list(ids), "center": center.key, **PARAMS},
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


# ---------------------------------------------------------------------------
# One document's links: what the Documents page's Linked view lists
# ---------------------------------------------------------------------------

# The labels a document's walk goes on through: what belongs to the document itself. Every other
# vertex (an author, a link, a distilled fact, another document) is where it stops, so a prolific
# author or a common fact cannot pull in the rest of the corpus.
DOCUMENT_PARTS = frozenset({"Message"})


def _edges_touching(session: Session, ids: list[int]) -> list[GraphEdge]:
    rows = session.execute(
        text(
            f'SELECT {_EDGE_COLUMNS} FROM {GRAPH}."_ag_label_edge" e '
            "WHERE e.start_id = ANY(CAST(CAST(:ids AS text[]) AS ag_catalog.graphid[])) "
            "OR e.end_id = ANY(CAST(CAST(:ids AS text[]) AS ag_catalog.graphid[])) ORDER BY e.id"
        ),
        {"ids": [str(i) for i in ids]},
    ).all()
    return [
        GraphEdge(int(eid), label_from_relation(rel), int(src), int(dst), parse_properties(props))
        for eid, rel, src, dst, props in rows
    ]


def most_recent_first(vertices: list[GraphVertex]) -> list[GraphVertex]:
    """``vertices`` with the most recent first: by ``at`` where a vertex has it, then by relational id."""
    by_key = sorted(vertices, key=lambda v: (v.key, v.id), reverse=True)
    timed = sorted(
        (v for v in by_key if isinstance(v.properties.get("at"), str)), key=lambda v: v.properties["at"], reverse=True
    )
    return [*timed, *(v for v in by_key if not isinstance(v.properties.get("at"), str))]


def document_links(session: Session, document_id: int, *, limit: int = 2000) -> Neighborhood:
    """Everything in the graph linked to one document, without limit per vertex.

    The document's messages, and each author, link, distilled fact and
    document it or they touch, but no further
    (``DOCUMENT_PARTS``); then the relation edges projected from the
    document's own facts (a configured edge's ``document_id``), and every edge
    between the vertices found. Vertices come center first, then most recent
    first (:func:`most_recent_first`). ``limit`` caps the vertices and sets
    ``truncated``. Raises ``LookupError`` when the document is not in the graph.
    """
    if not graph_exists(session):
        return Neighborhood(available=False)
    use_age(session)
    center = find_vertex(session, "Document", document_id)
    if center is None:
        raise LookupError("that document is not in the graph yet; Distill Facts or `garage graph rebuild` projects it")

    vertices: dict[int, GraphVertex] = {center.id: center}
    frontier = [center.id]
    truncated = False
    while frontier and not truncated:
        hop = _edges_touching(session, frontier)
        reached = {_other_end(e, vid) for e in hop for vid in frontier if vid in (e.source_id, e.target_id)}
        new_ids = sorted(reached - vertices.keys())
        if len(vertices) + len(new_ids) > limit:
            truncated = True
            new_ids = new_ids[: max(0, limit - len(vertices))]
        found = _vertices_by_id(session, new_ids, None)
        vertices.update({v.id: v for v in found})
        frontier = [v.id for v in found if v.label in DOCUMENT_PARTS]

    # Relation edges drawn from this document's statements, whose ends are distilled facts the walk may
    # not have reached (a name resolved by a statement elsewhere).
    own = session.execute(
        text(
            f'SELECT CAST(e.start_id AS text), CAST(e.end_id AS text) FROM {GRAPH}."_ag_label_edge" e '
            "WHERE ag_catalog.agtype_access_operator(e.properties, '\"document_id\"'::ag_catalog.agtype) "
            "= CAST(CAST(:doc AS text) AS ag_catalog.agtype)"
        ),
        {"doc": int(document_id)},
    ).all()
    ends = sorted({int(i) for row in own for i in row} - vertices.keys())
    room = max(0, limit - len(vertices))
    if len(ends) > room:
        truncated = True
        ends = ends[:room]
    vertices.update({v.id: v for v in _vertices_by_id(session, ends, None)})

    edges = {
        e.id: e for e in _edges_touching(session, list(vertices)) if e.source_id in vertices and e.target_id in vertices
    }
    rest = most_recent_first([v for v in vertices.values() if v.id != center.id])
    return Neighborhood(
        available=True,
        center=center,
        vertices=[center, *rest],
        edges=sorted(edges.values(), key=lambda e: e.id),
        truncated=truncated,
    )


# ---------------------------------------------------------------------------
# Raw openCypher: the app's Query page
# ---------------------------------------------------------------------------

# The dollar-quote tag a query is wrapped in; a query holding it is refused, so it cannot end the
# quote early.
_QUOTE = "$garage_cypher$"

_STRINGS_AND_COMMENTS = re.compile(r"'(?:[^'\\]|\\.)*'|\"(?:[^\"\\]|\\.)*\"|`[^`]*`|//[^\n]*|/\*.*?\*/", re.S)
_CLAUSE_END = re.compile(r"\b(ORDER\s+BY|SKIP|LIMIT|UNION)\b", re.I)
# An item's alias, on its masked text: ``AS`` then a name, or a backticked one (masked to blanks).
# A schema-qualified call (``pg_catalog.pg_read_file(...)``), which AGE passes to Postgres: refused,
# since the query runs with the database role. Cypher's own functions are unqualified.
_QUALIFIED_CALL = re.compile(r"(\w+|`[^`]*`)\s*\.\s*(\w+|`[^`]*`)\s*\(")
_STRINGS_AND_COMMENTS_ONLY = re.compile(r"'(?:[^'\\]|\\.)*'|\"(?:[^\"\\]|\\.)*\"|//[^\n]*|/\*.*?\*/", re.S)
_ALIAS = re.compile(r"\sAS\s+(?:\w+\s*|\s*)$", re.I)


def _masked(query: str) -> str:
    """``query`` with string literals and comments blanked out, same length, so positions still match."""
    return _STRINGS_AND_COMMENTS.sub(lambda m: " " * len(m.group(0)), query)


def _depths(masked: str) -> list[int]:
    """The bracket depth at each character of ``masked``."""
    depths: list[int] = []
    depth = 0
    for c in masked:
        if c in ")]}":
            depth -= 1
        depths.append(depth)
        if c in "([{":
            depth += 1
    return depths


def return_columns(query: str) -> list[str]:
    """The names of the columns a Cypher query's last ``RETURN`` gives, which ``cypher()`` must be told.

    An item's name is its ``AS`` alias, else its text. Raises ``ValueError`` for
    a query with no ``RETURN`` or one returning ``*``, whose columns cannot be
    known without running it.
    """
    masked = _masked(query)
    depths = _depths(masked)
    returns = [m for m in re.finditer(r"(?<![\w$])RETURN\b", masked, re.I) if depths[m.start()] == 0]
    if not returns:
        raise ValueError("the query returns nothing: end it with RETURN and the values to show")
    start = returns[-1].end()
    end = next(
        (m.start() for m in _CLAUSE_END.finditer(masked, start) if depths[m.start()] == 0),
        len(masked),
    )
    commas = [i for i in range(start, end) if masked[i] == "," and depths[i] == 0]
    names: list[str] = []
    for i, (a, b) in enumerate(zip([start, *(c + 1 for c in commas)], [*commas, end], strict=True)):
        # Trimmed by the query's own whitespace, so a backticked name blanked in the mask stays.
        raw = query[a:b]
        a, b = a + len(raw) - len(raw.lstrip()), b - (len(raw) - len(raw.rstrip()))
        if i == 0 and re.match(r"DISTINCT\b", masked[a:b], re.I):
            a += len("DISTINCT")
            a += len(query[a:b]) - len(query[a:b].lstrip())
        item, masked_item = query[a:b], masked[a:b]
        if not item:
            raise ValueError("RETURN has an empty item")
        if item == "*":
            raise ValueError("RETURN * cannot be shown: name each value to return")
        alias = _ALIAS.search(masked_item)
        names.append(item[alias.start() + len(" AS") :].strip().strip("`") if alias else " ".join(item.split()))
    return names


@dataclass(frozen=True)
class QueryCell:
    """One value of a result row, as agtype text; ``vertex`` is set when the value is a vertex."""

    text: str
    vertex: GraphVertex | None = None


@dataclass
class QueryResult:
    """A query's columns and rows; ``truncated`` says there were more than the limit."""

    available: bool
    columns: list[str] = field(default_factory=list)
    rows: list[list[QueryCell]] = field(default_factory=list)
    truncated: bool = False


_VERTEX_VALUE = re.compile(r"^\s*(\{.*\})::vertex\s*$", re.S)


def query_cell(value: str | None) -> QueryCell:
    """A result value as a cell, with the vertex it is when it is one."""
    if value is None:
        return QueryCell("null")
    match = _VERTEX_VALUE.match(value)
    if match:
        parsed = parse_properties(match.group(1))
        label, properties = parsed.get("label"), parsed.get("properties")
        if isinstance(parsed.get("id"), int) and isinstance(label, str) and isinstance(properties, dict):
            key = properties.get(key_property(label) or "", 0)
            return QueryCell(
                value,
                GraphVertex(
                    id=parsed["id"],
                    label=label,
                    key=key if isinstance(key, int) and not isinstance(key, bool) else 0,
                    title=vertex_title(label, properties),
                    properties=properties,
                ),
            )
    return QueryCell(value)


def run_query(session: Session, query: str, *, limit: int = 500, timeout_seconds: int = 30) -> QueryResult:
    """Run one openCypher query on the ``garage`` graph and return at most ``limit`` rows.

    Read only: the transaction is set read-only before the query runs, so
    ``CREATE``/``SET``/``DELETE`` fail rather than change the projection, and a
    statement timeout bounds it. A schema-qualified function call is refused:
    AGE hands it to Postgres, where ``pg_catalog.pg_read_file`` and its kin run
    with the database role. The query is passed to ``cypher()`` in a
    dollar quote it may not contain, and never through SQLAlchemy's parameter
    parsing (a Cypher label reads like a ``:name`` bind parameter). Raises
    ``ValueError`` for a query that cannot run, with the server's message.
    """
    from sqlalchemy.exc import DBAPIError

    query = query.strip().rstrip(";").strip()
    if not query:
        raise ValueError("write a query first")
    if _QUOTE in query:
        raise ValueError(f"the query may not contain {_QUOTE}")
    # Strings and comments blanked, backticked names kept: `pg_catalog`.f( is as qualified as pg_catalog.f(.
    if _QUALIFIED_CALL.search(_STRINGS_AND_COMMENTS_ONLY.sub(lambda m: " " * len(m.group(0)), query)):
        raise ValueError("the query may not call a schema-qualified function; use Cypher's own functions")
    if not graph_exists(session):
        return QueryResult(available=False)
    columns = return_columns(query)
    limit = max(1, min(int(limit), 10_000))
    use_age(session)
    conn = session.connection()
    conn.exec_driver_sql("SET TRANSACTION READ ONLY")
    conn.exec_driver_sql(f"SET LOCAL statement_timeout = {int(timeout_seconds) * 1000}")
    definitions = ", ".join(f"c{i} ag_catalog.agtype" for i in range(len(columns)))
    # agtype_out, not a cast: AGE casts no vertex, edge or path to text.
    values = ", ".join(f"ag_catalog.agtype_out(r.c{i})::text" for i in range(len(columns)))
    sql = (
        f"SELECT {values} FROM ag_catalog.cypher('{GRAPH}', {_QUOTE}{query}{_QUOTE}) AS r({definitions}) "
        f"LIMIT {limit + 1}"
    )
    try:
        with session.begin_nested():
            rows = conn.exec_driver_sql(sql).all()
    except DBAPIError as exc:
        message = str(getattr(exc, "orig", exc)).strip().splitlines()
        raise ValueError(message[0] if message else "the query failed") from exc
    return QueryResult(
        available=True,
        columns=columns,
        rows=[[query_cell(v) for v in row] for row in rows[:limit]],
        truncated=len(rows) > limit,
    )

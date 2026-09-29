"""Reading the AGE graph (db/graph.py) without a server: titles, properties and the neighbourhood walk.

The walk is exercised against a fake of AGE's label tables, dispatching on the
SQL it runs; ``test_postgres.py`` runs the same functions against real AGE.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from unittest.mock import MagicMock

import pytest

from garage_rag.db.graph import (
    GraphVertex,
    find_vertex,
    graph_labels,
    label_from_relation,
    neighborhood,
    parse_properties,
    vertex_title,
)


def test_a_label_table_name_gives_its_label():
    assert label_from_relation('garage."Document"') == "Document"
    assert label_from_relation("garage.chunk") == "chunk"
    assert label_from_relation('"Fact"') == "Fact"


def test_agtype_maps_parse_as_json_and_survive_numeric_suffixes():
    assert parse_properties('{"document_id": 5, "title": "Notes"}') == {"document_id": 5, "title": "Notes"}
    assert parse_properties('{"confidence": 0.9::numeric}') == {"confidence": 0.9}
    assert parse_properties("") == {}
    assert parse_properties("not json") == {"raw": "not json"}


@pytest.mark.parametrize(
    ("label", "properties", "title"),
    [
        ("Document", {"title": "House notes", "uri": "/a/b.md"}, "House notes"),
        ("Document", {"title": "", "uri": "/a/b.md"}, "b.md"),
        ("Chunk", {"chunk_id": 3, "ord": 2}, "Chunk 2"),
        ("Author", {"display_name": "Ada"}, "Ada"),
        ("PotentialFact", {"fact": " The roof is slate. "}, "The roof is slate."),
        ("Fact", {"statement": "The roof is slate."}, "The roof is slate."),
        ("Thing", {"thing_id": 9}, "Thing"),
        ("Entity", {"name": "Zürich", "kind": "place"}, "Zürich"),
    ],
)
def test_vertex_titles(label, properties, title):
    assert vertex_title(label, properties) == title


@dataclass
class FakeGraph:
    """The `garage` graph as AGE's tables: vertices (id, label, properties) and edges."""

    vertices: dict[int, tuple[str, dict]] = field(default_factory=dict)
    edges: dict[int, tuple[str, int, int, dict]] = field(default_factory=dict)
    has_age: bool = True

    def session(self) -> MagicMock:
        session = MagicMock()
        session.execute.side_effect = self._execute
        session.connection.return_value = MagicMock()
        return session

    def _rows(self, rows):
        result = MagicMock()
        result.all.return_value = rows
        result.first.return_value = rows[0] if rows else None
        result.__iter__.side_effect = lambda: iter(rows)
        result.scalar.return_value = rows[0][0] if rows else None
        result.scalar_one.return_value = rows[0][0] if rows else None
        return result

    def _execute(self, statement, params=None):
        sql = " ".join(str(statement).split())
        params = params or {}
        if "pg_extension" in sql:
            return self._rows([(self.has_age,)])
        if "FROM ag_catalog.ag_graph" in sql:
            return self._rows([(True,)])
        if "FROM ag_catalog.ag_label" in sql:
            labels = (
                {v[0] for v in self.vertices.values()} if params["kind"] == "v" else {e[0] for e in self.edges.values()}
            )
            return self._rows([(name,) for name in sorted(labels)])
        if "SELECT count(*) FROM garage." in sql:
            label = sql.split('garage."')[1].split('"')[0]
            n = sum(1 for v in self.vertices.values() if v[0] == label) + sum(
                1 for e in self.edges.values() if e[0] == label
            )
            return self._rows([(n,)])
        if '"_ag_label_edge" e' in sql:
            ids = {int(i) for i in params["ids"]}
            labels = params.get("labels")
            rows = [
                (str(eid), f'garage."{label}"', str(src), str(dst), json.dumps(props))
                for eid, (label, src, dst, props) in sorted(self.edges.items())
                if (src in ids or dst in ids) and ("labels" not in sql or label in labels)
            ]
            return self._rows(rows)
        if '"_ag_label_vertex" v' in sql:
            ids = {int(i) for i in params["ids"]}
            labels = params.get("labels")
            rows = [
                (str(vid), f'garage."{label}"', json.dumps(props))
                for vid, (label, props) in sorted(self.vertices.items())
                if vid in ids and ("labels" not in sql or label in labels)
            ]
            return self._rows(rows)
        if "agtype_access_operator" in sql and "LIMIT 1" in sql:
            label = sql.split('FROM garage."')[1].split('"')[0]
            prop = sql.split("'\"")[1].split('"')[0]
            rows = [
                (str(vid), f'garage."{vlabel}"', json.dumps(props))
                for vid, (vlabel, props) in sorted(self.vertices.items())
                if vlabel == label and props.get(prop) == params["key"]
            ]
            return self._rows(rows)
        raise AssertionError(f"unexpected SQL: {sql}")


@pytest.fixture
def graph() -> FakeGraph:
    """Ada wrote a document of two chunks, which states two potential facts backing one distilled fact."""
    g = FakeGraph()
    g.vertices[1] = ("Document", {"document_id": 10, "title": "House", "uri": "/h.md"})
    g.vertices[2] = ("Chunk", {"chunk_id": 20, "document_id": 10, "ord": 0})
    g.vertices[3] = ("Chunk", {"chunk_id": 21, "document_id": 10, "ord": 1})
    g.vertices[4] = ("Author", {"author_id": 30, "display_name": "Ada", "is_self": True})
    g.vertices[5] = ("PotentialFact", {"fact_id": 40, "document_id": 10, "fact": "The roof is slate."})
    g.vertices[6] = ("PotentialFact", {"fact_id": 41, "document_id": 10, "fact": "Slate covers the roof."})
    g.vertices[7] = ("Fact", {"distilled_fact_id": 50, "statement": "The roof is slate."})
    g.edges[100] = ("HAS_CHUNK", 1, 2, {"ord": 0})
    g.edges[101] = ("HAS_CHUNK", 1, 3, {"ord": 1})
    g.edges[102] = ("WROTE", 4, 1, {"role": "author", "confidence": 0.9})
    g.edges[103] = ("STATES", 1, 5, {"char_start": 0, "char_end": 18})
    g.edges[104] = ("STATES", 1, 6, {})
    g.edges[105] = ("SUPPORTS", 5, 7, {"similarity": 0.97})
    g.edges[106] = ("SUPPORTS", 6, 7, {"similarity": 0.95})
    return g


def test_labels_are_counted(graph: FakeGraph):
    labels = graph_labels(graph.session())
    assert labels.available
    assert labels.vertices == {"Author": 1, "Chunk": 2, "Document": 1, "Fact": 1, "PotentialFact": 2}
    assert labels.edges == {"HAS_CHUNK": 2, "STATES": 2, "SUPPORTS": 2, "WROTE": 1}


def test_without_age_nothing_is_available(graph: FakeGraph):
    graph.has_age = False
    assert not graph_labels(graph.session()).available
    assert not neighborhood(graph.session(), vertex_id=1).available


def test_a_vertex_is_found_by_label_and_relational_id(graph: FakeGraph):
    vertex = find_vertex(graph.session(), "PotentialFact", 41)
    assert vertex == GraphVertex(
        id=6,
        label="PotentialFact",
        key=41,
        title="Slate covers the roof.",
        properties={"fact_id": 41, "document_id": 10, "fact": "Slate covers the roof."},
    )
    assert find_vertex(graph.session(), "PotentialFact", 99) is None
    with pytest.raises(LookupError):
        find_vertex(graph.session(), "Planet", 1)


def test_one_hop_from_the_document(graph: FakeGraph):
    result = neighborhood(graph.session(), label="Document", key=10)
    assert result.available and result.center is not None and result.center.id == 1
    assert {v.id for v in result.vertices} == {1, 2, 3, 4, 5, 6}
    assert {e.id for e in result.edges} == {100, 101, 102, 103, 104}
    assert not result.truncated


def test_two_hops_reach_the_distilled_fact(graph: FakeGraph):
    result = neighborhood(graph.session(), vertex_id=1, depth=2)
    assert {v.id for v in result.vertices} == {1, 2, 3, 4, 5, 6, 7}
    assert {e.id for e in result.edges} == set(graph.edges)


def test_excluded_vertex_labels_are_neither_shown_nor_walked_through(graph: FakeGraph):
    # Without PotentialFact vertices the distilled fact is two hops away through nothing.
    result = neighborhood(graph.session(), vertex_id=1, depth=2, vertex_labels=["Document", "Author", "Fact"])
    assert {v.id for v in result.vertices} == {1, 4}
    assert {e.id for e in result.edges} == {102}


def test_edge_labels_filter_the_walk(graph: FakeGraph):
    result = neighborhood(graph.session(), vertex_id=7, depth=3, edge_labels=["SUPPORTS", "STATES"])
    assert {v.id for v in result.vertices} == {1, 5, 6, 7}
    assert {e.label for e in result.edges} == {"SUPPORTS", "STATES"}


def test_the_limit_cuts_the_walk_breadth_first_and_says_so(graph: FakeGraph):
    result = neighborhood(graph.session(), vertex_id=1, depth=2, limit=3)
    assert result.truncated
    assert len(result.vertices) == 3
    assert result.vertices[0].id == 1
    # Every edge kept has both ends kept.
    ids = {v.id for v in result.vertices}
    assert all(e.source_id in ids and e.target_id in ids for e in result.edges)


def test_a_missing_vertex_is_a_lookup_error(graph: FakeGraph):
    with pytest.raises(LookupError):
        neighborhood(graph.session(), vertex_id=999)
    with pytest.raises(ValueError):
        neighborhood(graph.session())

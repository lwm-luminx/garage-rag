"""The graph schema a fact prompt's ``graph`` block declares (config.fact_prompts, db.graph.projection)."""

from __future__ import annotations

import pytest
from pydantic import ValidationError

from garage_rag.config.fact_prompts import (
    FactPrompt,
    effective_prompts,
    graph_schema,
    validate_prompt_list,
)
from garage_rag.db.graph import EDGES, VERTICES, projection

EXAMPLES = [{"text": "Jane Doe works at Acme.", "extractions": [{"class": "person", "text": "Jane Doe"}]}]


def _prompt(name: str, graph: dict | None) -> FactPrompt:
    return FactPrompt.model_validate(
        {"name": name, "description": "Extract people.", "examples": EXAMPLES, **({"graph": graph} if graph else {})}
    )


ENTITIES = {
    "vertices": [
        {"class": "person", "label": "Person", "title": "name"},
        {"class": "organization", "label": "Organization"},
    ],
    "edges": [
        {
            "class": "relation",
            "source": "subject",
            "source_class": "person",
            "target": "object",
            "target_class": "organization",
            "label_attribute": "predicate",
            "labels": ["WORKS_AT", "MEMBER_OF"],
        }
    ],
}


def test_a_prompts_graph_block_becomes_the_schema() -> None:
    schema = graph_schema(effective_prompts([_prompt("entities", ENTITIES)]))
    assert schema.label_for("person") == "Person"
    assert schema.label_for("fact") == "Fact"
    assert schema.vertices["person"].title == "name"
    (edge,) = schema.edges
    assert (edge.label, edge.labels) == ("RELATED_TO", ["WORKS_AT", "MEMBER_OF"])


def test_the_graph_block_round_trips_through_the_config_entry() -> None:
    (prompt,) = [p for p in effective_prompts([_prompt("entities", ENTITIES)]) if p.name == "entities"]
    again = FactPrompt.model_validate(prompt.to_config())
    assert again.graph == prompt.graph


def test_the_graph_block_does_not_make_facts_stale() -> None:
    with_graph = [p for p in effective_prompts([_prompt("entities", ENTITIES)]) if p.name == "entities"][0]
    without = [p for p in effective_prompts([_prompt("entities", None)]) if p.name == "entities"][0]
    assert with_graph.sha256 == without.sha256


@pytest.mark.parametrize(
    ("prompts", "message"),
    [
        ([{"vertices": [{"class": "person", "label": "Fact"}]}], "built-in vertex label"),
        ([{"vertices": [{"class": "person", "label": "DOCUMENT"}]}], "built-in vertex label"),
        (
            [
                {"vertices": [{"class": "person", "label": "Person"}]},
                {"vertices": [{"class": "person", "label": "Human"}]},
            ],
            "is both",
        ),
        (
            [
                {"vertices": [{"class": "person", "label": "Person"}]},
                {"vertices": [{"class": "people", "label": "Person"}]},
            ],
            "is used for",
        ),
        (
            [
                {
                    "edges": [
                        {
                            "class": "r",
                            "source": "a",
                            "source_class": "x",
                            "target": "b",
                            "target_class": "y",
                            "label": "SUPPORTS",
                        }
                    ]
                }
            ],
            "built-in edge label",
        ),
    ],
)
def test_clashing_labels_are_refused_when_the_config_loads(prompts: list[dict], message: str) -> None:
    with pytest.raises(ValueError, match=message):
        validate_prompt_list([_prompt(f"p{i}", graph) for i, graph in enumerate(prompts)])


@pytest.mark.parametrize(
    "graph",
    [
        {"vertices": [{"class": "person", "label": "person"}]},
        {"vertices": [{"class": "person", "label": "Per-son"}]},
        {"vertices": [{"class": "person", "label": "Person", "title": "name'; drop"}]},
        {
            "edges": [
                {
                    "class": "r",
                    "source": "a",
                    "source_class": "x",
                    "target": "b",
                    "target_class": "y",
                    "labels": ["works at"],
                }
            ]
        },
        {"vertices": [{"class": "it's", "label": "Person"}]},
    ],
)
def test_labels_and_attribute_names_are_plain_identifiers(graph: dict) -> None:
    with pytest.raises(ValidationError):
        _prompt("entities", graph)


def test_the_projection_moves_a_configured_class_out_of_fact() -> None:
    schema = graph_schema(effective_prompts([_prompt("entities", ENTITIES)]))
    vertices, edges = projection(schema)
    labels = [v.label for v in vertices]
    assert labels == [*VERTICES, "Person", "Organization"]
    fact = next(v for v in vertices if v.label == "Fact")
    assert fact.params == {"mapped": ["organization", "person"]}
    states = [(e.source, e.target, e.params.get("cls")) for e in edges if e.label == "STATES"]
    assert states == [
        ("Document", "Fact", None),
        ("Document", "Person", "person"),
        ("Document", "Organization", "organization"),
    ]
    assert next(e for e in edges if e.label == "STATES").params == {"mapped": ["organization", "person"]}
    relation = [(e.label, e.source, e.target) for e in edges if e.label not in EDGES]
    assert relation == [
        ("WORKS_AT", "Person", "Organization"),
        ("MEMBER_OF", "Person", "Organization"),
        ("RELATED_TO", "Person", "Organization"),
    ]


def test_with_no_graph_blocks_the_projection_is_the_built_in_one() -> None:
    vertices, edges = projection(graph_schema(effective_prompts([])))
    assert [v.label for v in vertices] == list(VERTICES)
    assert [e.label for e in edges] == list(EDGES)
    assert all(not v.params for v in vertices) and all(not e.params for e in edges)


def test_a_configured_label_is_titled_and_keyed_like_a_distilled_fact() -> None:
    from garage_rag.db.graph import key_property, title_property, vertex_title

    assert (title_property("Person"), key_property("Person")) == ("title", "distilled_fact_id")
    assert (title_property("Author"), key_property("Author")) == ("display_name", "author_id")
    assert title_property("Chunk") is None
    assert vertex_title("Person", {"distilled_fact_id": 4, "title": "Jane Doe", "statement": "Jane Doe"}) == "Jane Doe"

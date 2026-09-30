"""The graph RPCs (GetGraphLabels, FindGraphVertices, GetGraphNeighborhood) map db.graph's results."""

from __future__ import annotations

import json
from unittest.mock import MagicMock, patch

import grpc
import pytest

from garage_rag.db.graph import GraphEdge, GraphLabels, GraphVertex, Neighborhood
from garage_rag.proto.garage_pb2 import FindGraphVerticesRequest, GraphLabelsRequest, GraphNeighborhoodRequest
from garage_rag.service.server import GarageRpcServicer

DOC = GraphVertex(id=1, label="Document", key=10, title="House", properties={"document_id": 10, "title": "House"})
FACT = GraphVertex(id=5, label="PotentialFact", key=40, title="The roof is slate.", properties={"fact_id": 40})


def test_graph_labels_are_listed_with_counts():
    servicer = GarageRpcServicer()
    labels = GraphLabels(available=True, vertices={"Document": 3, "Fact": 2}, edges={"STATES": 5})
    with patch("garage_rag.ops.graph.graph_labels", return_value=labels):
        response = servicer.GetGraphLabels(GraphLabelsRequest(), MagicMock())
    assert response.available
    assert [(c.label, c.count) for c in response.vertex_labels] == [("Document", 3), ("Fact", 2)]
    assert [(c.label, c.count) for c in response.edge_labels] == [("STATES", 5)]


def test_without_age_the_graph_is_unavailable():
    servicer = GarageRpcServicer()
    with patch("garage_rag.ops.graph.graph_labels", return_value=GraphLabels(available=False)):
        assert not servicer.GetGraphLabels(GraphLabelsRequest(), MagicMock()).available
        assert not servicer.FindGraphVertices(FindGraphVerticesRequest(query="x"), MagicMock()).available
    with patch("garage_rag.ops.graph.neighborhood", return_value=Neighborhood(available=False)):
        assert not servicer.GetGraphNeighborhood(GraphNeighborhoodRequest(vertex_id=1), MagicMock()).available


def test_find_vertices_passes_the_query_and_maps_the_vertices():
    servicer = GarageRpcServicer()
    with (
        patch("garage_rag.ops.graph.graph_labels", return_value=GraphLabels(available=True)),
        patch("garage_rag.ops.graph.find_vertices", return_value=[DOC, FACT]) as find,
    ):
        response = servicer.FindGraphVertices(FindGraphVerticesRequest(query="roof", label="Fact"), MagicMock())
    find.assert_called_once_with("roof", label="Fact", limit=50)
    assert response.available
    assert [(v.id, v.label, v.key, v.title) for v in response.vertices] == [
        (1, "Document", 10, "House"),
        (5, "PotentialFact", 40, "The roof is slate."),
    ]
    assert json.loads(response.vertices[0].properties_json) == {"document_id": 10, "title": "House"}


def test_neighborhood_maps_the_walk_and_its_filters():
    servicer = GarageRpcServicer()
    result = Neighborhood(
        available=True,
        center=DOC,
        vertices=[DOC, FACT],
        edges=[GraphEdge(id=103, label="STATES", source_id=1, target_id=5, properties={"char_start": 0})],
        truncated=True,
    )
    with patch("garage_rag.ops.graph.neighborhood", return_value=result) as walk:
        response = servicer.GetGraphNeighborhood(
            GraphNeighborhoodRequest(
                label="Document", key=10, depth=2, vertex_labels=["Document", "PotentialFact"], limit=50
            ),
            MagicMock(),
        )
    walk.assert_called_once_with(
        vertex_id=None,
        label="Document",
        key=10,
        depth=2,
        vertex_labels=["Document", "PotentialFact"],
        edge_labels=None,
        limit=50,
    )
    assert response.center.id == 1
    assert [v.id for v in response.vertices] == [1, 5]
    edge = response.edges[0]
    assert (edge.id, edge.label, edge.source_id, edge.target_id) == (103, "STATES", 1, 5)
    assert json.loads(edge.properties_json) == {"char_start": 0}
    assert response.truncated


def test_neighborhood_by_graph_id_defaults_depth_and_limit_and_honours_an_empty_filter():
    servicer = GarageRpcServicer()
    result = Neighborhood(available=True, center=DOC, vertices=[DOC])
    with patch("garage_rag.ops.graph.neighborhood", return_value=result) as walk:
        servicer.GetGraphNeighborhood(GraphNeighborhoodRequest(vertex_id=1, filter_edge_labels=True), MagicMock())
    walk.assert_called_once_with(
        vertex_id=1, label="", key=None, depth=1, vertex_labels=None, edge_labels=[], limit=200
    )


def test_a_vertex_not_in_the_graph_is_not_found():
    servicer = GarageRpcServicer()
    context = MagicMock()
    context.abort.side_effect = grpc.RpcError("aborted")
    with (
        patch("garage_rag.ops.graph.neighborhood", side_effect=LookupError("that vertex is not in the graph")),
        pytest.raises(grpc.RpcError),
    ):
        servicer.GetGraphNeighborhood(GraphNeighborhoodRequest(vertex_id=999), context)
    context.abort.assert_called_once()
    assert context.abort.call_args[0][0] == grpc.StatusCode.NOT_FOUND

import XCTest
import proto_garage_proto_swift
@testable import GarageApp

final class GraphItemsTests: XCTestCase {

    private func vertex(_ id: Int64, _ label: String, key: Int64 = 0, title: String = "", properties: String = "") -> Garage_GraphVertex {
        var vertex = Garage_GraphVertex()
        vertex.id = id
        vertex.label = label
        vertex.key = key
        vertex.title = title
        vertex.propertiesJson = properties
        return vertex
    }

    private func edge(_ id: Int64, _ label: String, _ source: Int64, _ target: Int64, properties: String = "") -> Garage_GraphEdge {
        var edge = Garage_GraphEdge()
        edge.id = id
        edge.label = label
        edge.sourceID = source
        edge.targetID = target
        edge.propertiesJson = properties
        return edge
    }

    func testMapsAVertexAndReadsItsKeyAsOptional() {
        let item = GraphVertexItem(proto: vertex(1, "Document", key: 10, title: "House", properties: #"{"document_id": 10, "title": "House", "uri": "/h.md"}"#))
        XCTAssertEqual(item.id, 1)
        XCTAssertEqual(item.key, 10)
        XCTAssertEqual(item.documentID, 10)
        XCTAssertEqual(item.documentURI, "/h.md")
        XCTAssertEqual(item.properties.map(\.key), ["document_id", "title", "uri"])
        XCTAssertNil(GraphVertexItem(proto: vertex(2, "Entity")).key)
    }

    func testAMessagePointsAtItsThreadAndAnAuthorAtNone() {
        let message = GraphVertexItem(proto: vertex(5, "Message", key: 40, properties: #"{"message_id": 40, "document_id": 10}"#))
        XCTAssertEqual(message.documentID, 10)
        XCTAssertEqual(message.documentURI, "")
        XCTAssertTrue(message.isRead)
        let author = GraphVertexItem(proto: vertex(4, "Author", key: 30, properties: #"{"author_id": 30, "is_self": true}"#))
        XCTAssertNil(author.documentID)
        XCTAssertEqual(author.properties, [GraphProperty(key: "author_id", value: "30"), GraphProperty(key: "is_self", value: "true")])
    }

    func testPropertiesRenderEveryJSONType() {
        let properties = GraphProperty.parse(#"{"n": 0.9, "s": "x", "b": false, "z": null, "list": [1, 2], "map": {"k": "v"}}"#)
        XCTAssertEqual(properties.map(\.key), ["b", "list", "map", "n", "s", "z"])
        XCTAssertEqual(properties.map(\.value), ["false", "[1,2]", #"{"k":"v"}"#, "0.9", "x", ""])
        XCTAssertEqual(GraphProperty.parse(""), [])
        XCTAssertEqual(GraphProperty.parse("not json"), [])
    }

    func testANeighborhoodKnowsEachVertexsConnections() {
        var response = Garage_GraphNeighborhoodResponse()
        response.available = true
        response.center = vertex(1, "Document", key: 10, title: "House")
        response.vertices = [
            response.center,
            vertex(4, "Author", key: 30, title: "Ada"),
            vertex(5, "Fact", key: 40, title: "The roof is slate."),
        ]
        response.edges = [edge(102, "WROTE", 4, 1), edge(103, "STATES", 1, 5)]
        response.truncated = true
        let neighborhood = GraphNeighborhood(response: response)

        XCTAssertEqual(neighborhood.center?.title, "House")
        XCTAssertTrue(neighborhood.truncated)
        let connections = neighborhood.connections(of: 1)
        XCTAssertEqual(connections.map(\.edge.label), ["WROTE", "STATES"])
        XCTAssertEqual(connections.map(\.other.title), ["Ada", "The roof is slate."])
        XCTAssertEqual(neighborhood.connections(of: 5).map(\.other.id), [1])
        XCTAssertEqual(neighborhood.edges[0].otherEnd(from: 4), 1)
        XCTAssertNil(neighborhood.edges[0].otherEnd(from: 5))
    }

    func testAnUnavailableGraphHasNoCenter() {
        var response = Garage_GraphNeighborhoodResponse()
        response.available = false
        let neighborhood = GraphNeighborhood(response: response)
        XCTAssertFalse(neighborhood.available)
        XCTAssertNil(neighborhood.center)
        XCTAssertTrue(neighborhood.vertices.isEmpty)
    }

    func testLabelsMapWithCounts() {
        var response = Garage_GraphLabelsResponse()
        response.available = true
        var count = Garage_GraphLabelCount()
        count.label = "Fact"
        count.count = 12
        response.vertexLabels = [count]
        let labels = GraphLabels(response: response)
        XCTAssertTrue(labels.available)
        XCTAssertEqual(labels.vertexLabels, [GraphLabelCount(label: "Fact", count: 12)])
        XCTAssertTrue(labels.edgeLabels.isEmpty)
    }
}

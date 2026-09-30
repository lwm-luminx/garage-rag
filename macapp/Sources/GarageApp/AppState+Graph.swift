import Foundation

extension AppState {
    /// The graph's labels with counts, via the gRPC server.
    func graphLabels() async throws -> GraphLabels {
        GraphLabels(response: try await grpc.graphLabels())
    }

    /// Vertices titled like `query`, or carrying it as their relational id.
    func findGraphVertices(query: String, label: String? = nil, limit: Int = 50) async throws -> [GraphVertexItem] {
        let response = try await grpc.findGraphVertices(query: query, label: label, limit: limit)
        return response.vertices.map { GraphVertexItem(proto: $0) }
    }

    /// One vertex and everything within `depth` hops of it, under the label filters.
    func graphNeighborhood(
        vertexID: Int64? = nil,
        focus: GraphFocus? = nil,
        depth: Int = 1,
        vertexLabels: [String]? = nil,
        edgeLabels: [String]? = nil,
        limit: Int = 200
    ) async throws -> GraphNeighborhood {
        let response = try await grpc.graphNeighborhood(
            vertexID: vertexID,
            label: focus?.label,
            key: focus?.key,
            depth: depth,
            vertexLabels: vertexLabels,
            edgeLabels: edgeLabels,
            limit: limit
        )
        return GraphNeighborhood(response: response)
    }
}

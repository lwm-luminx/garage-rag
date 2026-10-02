import Foundation
import GRPC
import NIO
import proto_garage_proto_swift

/// The Graph page's reads: the graph's labels, a vertex search, and one vertex's neighbourhood.
extension GarageGRPCService {
    func graphLabels() async throws -> Garage_GraphLabelsResponse {
        let client = try await graphClient()
        do {
            return try await client.getGraphLabels(Garage_GraphLabelsRequest(), callOptions: Self.graphCallOptions)
        } catch {
            throw GarageGRPCError.rpcFailed(Self.describe(error))
        }
    }

    func findGraphVertices(query: String, label: String? = nil, limit: Int = 50) async throws -> Garage_FindGraphVerticesResponse {
        let client = try await graphClient()
        var request = Garage_FindGraphVerticesRequest()
        request.query = query
        if let label, !label.isEmpty {
            request.label = label
        }
        request.limit = Int32(limit)
        do {
            return try await client.findGraphVertices(request, callOptions: Self.graphCallOptions)
        } catch {
            throw GarageGRPCError.rpcFailed(Self.describe(error))
        }
    }

    /// The neighbourhood of a vertex named by graph id, or by label and relational id.
    ///
    /// A nil label list keeps every label; an empty one keeps none.
    func graphNeighborhood(
        vertexID: Int64? = nil,
        label: String? = nil,
        key: Int64? = nil,
        depth: Int = 1,
        vertexLabels: [String]? = nil,
        edgeLabels: [String]? = nil,
        limit: Int = 200
    ) async throws -> Garage_GraphNeighborhoodResponse {
        let client = try await graphClient()
        var request = Garage_GraphNeighborhoodRequest()
        if let vertexID {
            request.vertexID = vertexID
        }
        if let label, let key {
            request.label = label
            request.key = key
        }
        request.depth = Int32(depth)
        if let vertexLabels {
            request.vertexLabels = vertexLabels
            request.filterVertexLabels = true
        }
        if let edgeLabels {
            request.edgeLabels = edgeLabels
            request.filterEdgeLabels = true
        }
        request.limit = Int32(limit)
        do {
            return try await client.getGraphNeighborhood(request, callOptions: Self.graphCallOptions)
        } catch {
            throw GarageGRPCError.rpcFailed(Self.describe(error))
        }
    }

    /// Everything in the graph linked to one document, uncapped per vertex: the Documents page's Linked view.
    func documentLinks(documentID: Int64, limit: Int = 2000) async throws -> Garage_GraphNeighborhoodResponse {
        let client = try await graphClient()
        var request = Garage_DocumentLinksRequest()
        request.documentID = documentID
        request.limit = Int32(limit)
        do {
            return try await client.getDocumentLinks(request, callOptions: Self.graphCallOptions)
        } catch {
            throw GarageGRPCError.rpcFailed(Self.describe(error))
        }
    }

    /// One read-only openCypher query: the Query page.
    func runGraphQuery(_ query: String, limit: Int = 500) async throws -> Garage_GraphQueryResponse {
        let client = try await graphClient()
        var request = Garage_GraphQueryRequest()
        request.query = query
        request.limit = Int32(limit)
        do {
            return try await client.runGraphQuery(request, callOptions: Self.graphCallOptions)
        } catch {
            throw GarageGRPCError.rpcFailed(Self.describe(error))
        }
    }

    private static var graphCallOptions: CallOptions {
        GarageGRPCAuth.callOptions(timeLimit: .timeout(.seconds(30)))
    }

    private func graphClient() async throws -> Garage_GarageServiceAsyncClient {
        if status != .running {
            try await start()
        }
        return Garage_GarageServiceAsyncClient(channel: getOrCreateChannel(), defaultCallOptions: GarageGRPCAuth.callOptions())
    }
}

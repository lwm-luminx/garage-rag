import Foundation
import GRPC
import NIO
import proto_garage_proto_swift

/// The Facts page's reads: every document's distilled facts, searched and filtered.
extension GarageGRPCService {
    func listFacts(
        query: String? = nil,
        source: String? = nil,
        factClass: String? = nil,
        corpusClass: String? = nil,
        documentID: Int64? = nil,
        limit: Int = 200,
        offset: Int = 0
    ) async throws -> Garage_ListFactsResponse {
        if status != .running {
            try await start()
        }

        let client = Garage_GarageServiceAsyncClient(channel: getOrCreateChannel(), defaultCallOptions: GarageGRPCAuth.callOptions())
        var request = Garage_ListFactsRequest()
        if let query, !query.isEmpty {
            request.query = query
        }
        if let source, !source.isEmpty {
            request.source = source
        }
        if let factClass, !factClass.isEmpty {
            request.factClass = factClass
        }
        if let corpusClass, !corpusClass.isEmpty {
            request.corpusClass = corpusClass
        }
        if let documentID {
            request.documentID = documentID
        }
        request.limit = Int32(limit)
        request.offset = Int32(offset)

        let callOptions = GarageGRPCAuth.callOptions(timeLimit: .timeout(.seconds(30)))
        do {
            return try await client.listFacts(request, callOptions: callOptions)
        } catch {
            throw GarageGRPCError.searchFailed(Self.describe(error))
        }
    }
}

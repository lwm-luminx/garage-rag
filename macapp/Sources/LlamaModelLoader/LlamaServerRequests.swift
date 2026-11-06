import Foundation
import GarageXPCKit
import LlamaClient

/// Sends llama-server requests to LlamaXPCService over NSXPC (`handleServerRequest`) rather than
/// HTTP, through the listener endpoint the app handed this process (`GarageLlamaEndpointStore`): a
/// sibling XPC service cannot look LlamaXPCService up by name. XPC only delivers these messages
/// between processes of the same team (`GarageXPCPeerRequirement`), and no socket or port is involved.
///
/// The Python bridge (`LlamaInferenceBridge`) and the Rust embed worker's host both send through it.
public enum LlamaServerRequests {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var client: LlamaClient?
    nonisolated(unsafe) private static var clientGeneration = -1

    /// One NSXPC connection for every request. Dropped after a failure, and replaced when a newer
    /// endpoint arrives, so the next request reconnects.
    private static func sharedClient(store: GarageLlamaEndpointStore = .shared) throws -> LlamaClient {
        lock.lock()
        defer { lock.unlock() }
        let generation = store.generation
        if let client, clientGeneration == generation { return client }
        guard let endpoint = store.endpoint else {
            throw LlamaClientError.serviceUnavailable("the app has not handed this process LlamaXPCService's endpoint yet")
        }
        let created = LlamaClient(endpoint: endpoint)
        client = created
        clientGeneration = generation
        return created
    }

    private static func dropClient(_ failed: LlamaClient) {
        lock.lock()
        if client === failed { client = nil }
        lock.unlock()
    }

    /// Sends one request and waits for LlamaXPCService's reply: the HTTP status and body.
    public static func perform(method: String, path: String, body: String?, timeout: TimeInterval) -> Result<(Int, String), Error> {
        let client: LlamaClient
        do {
            client = try sharedClient()
        } catch {
            return .failure(error)
        }
        let semaphore = DispatchSemaphore(value: 0)
        let box = ReplyBox()
        Task.detached {
            do {
                let reply = try await client.handleServerRequest(endpoint: path, method: method, jsonBody: body)
                box.set(.success((reply.statusCode, reply.responseBody)))
            } catch {
                box.set(.failure(error))
            }
            semaphore.signal()
        }
        let result: Result<(Int, String), Error>
        if semaphore.wait(timeout: .now() + max(1, timeout)) == .timedOut {
            result = .failure(LlamaClientError.serviceUnavailable("no reply within \(Int(timeout))s"))
        } else {
            result = box.get() ?? .failure(LlamaClientError.invalidResponse("no result"))
        }
        if case .failure = result {
            dropClient(client)
        }
        return result
    }
}

private final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<(Int, String), Error>?

    func set(_ value: Result<(Int, String), Error>) {
        lock.lock()
        result = value
        lock.unlock()
    }

    func get() -> Result<(Int, String), Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

import Foundation
import OSLog
import PythonXPCService

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag", category: "ImageEmbedClient")

/// Swift client for `GarageImageEmbedXPCService`, over macOS XPC by name (the app) or through a
/// handed-over listener endpoint (a sibling XPC service).
public final class ImageEmbedClient: @unchecked Sendable {
    private let connection: NSXPCConnection
    private let jsonDecoder = JSONDecoder()

    /// Connects to the service by name; only the app that bundles it can.
    public init(serviceName: String = ImageEmbedXPCConstants.serviceName) {
        let conn = GarageInProcessServices.makeConnection(serviceName: serviceName)
        conn.remoteObjectInterface = NSXPCInterface(with: GarageImageEmbedXPCServiceProtocol.self)
        conn.resume()
        connection = conn
    }

    /// Connects through the endpoint the app handed this process (`GarageImageEmbedEndpointStore`).
    public init(endpoint: NSXPCListenerEndpoint) {
        let conn = NSXPCConnection(listenerEndpoint: endpoint)
        conn.remoteObjectInterface = NSXPCInterface(with: GarageImageEmbedXPCServiceProtocol.self)
        conn.resume()
        connection = conn
    }

    deinit {
        connection.invalidate()
    }

    public func invalidate() {
        connection.invalidate()
    }

    // MARK: - Remote call helper

    private final class ContinuationRelay<T>: @unchecked Sendable {
        private var continuation: CheckedContinuation<T, Error>?
        private let lock = NSLock()

        init(_ continuation: CheckedContinuation<T, Error>) {
            self.continuation = continuation
        }

        func resume(returning value: T) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }

        func resume(throwing error: Error) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(throwing: error)
        }
    }

    private func call<T>(_ block: @escaping (GarageImageEmbedXPCServiceProtocol, ContinuationRelay<T>) -> Void) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let relay = ContinuationRelay(continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                relay.resume(throwing: ImageEmbedClientError.serviceUnavailable(error.localizedDescription))
            }) as? GarageImageEmbedXPCServiceProtocol else {
                relay.resume(throwing: ImageEmbedClientError.serviceUnavailable("no GarageImageEmbedXPCServiceProtocol proxy"))
                return
            }
            block(proxy, relay)
        }
    }

    private func decodeInfo(_ json: String?) throws -> ImageEmbedModelInfo {
        guard let json, let data = json.data(using: .utf8) else {
            throw ImageEmbedClientError.invalidResponse("empty model info")
        }
        do {
            return try jsonDecoder.decode(ImageEmbedModelInfo.self, from: data)
        } catch {
            throw ImageEmbedClientError.invalidResponse(error.localizedDescription)
        }
    }

    // MARK: - API

    public func ping() async throws -> String {
        try await call { proxy, relay in
            proxy.ping { reply in relay.resume(returning: reply) }
        }
    }

    public func loadModel(slug: String) async throws -> ImageEmbedModelInfo {
        let json: String? = try await call { proxy, relay in
            proxy.loadModel(slug: slug) { json, error in
                if let error { relay.resume(throwing: error) } else { relay.resume(returning: json) }
            }
        }
        return try decodeInfo(json)
    }

    @discardableResult
    public func unloadModel(slug: String) async throws -> Bool {
        try await call { proxy, relay in
            proxy.unloadModel(slug: slug) { unloaded, error in
                if let error { relay.resume(throwing: error) } else { relay.resume(returning: unloaded) }
            }
        }
    }

    public func listModels() async throws -> [ImageEmbedModelInfo] {
        let json: String? = try await call { proxy, relay in
            proxy.listModels { json, error in
                if let error { relay.resume(throwing: error) } else { relay.resume(returning: json) }
            }
        }
        guard let json, let data = json.data(using: .utf8) else { return [] }
        do {
            return try jsonDecoder.decode([ImageEmbedModelInfo].self, from: data)
        } catch {
            throw ImageEmbedClientError.invalidResponse(error.localizedDescription)
        }
    }

    /// One vector per image, in order.
    public func embedImages(_ images: [Data], model slug: String) async throws -> [[Float]] {
        if images.isEmpty { return [] }
        let data: Data? = try await call { proxy, relay in
            proxy.embedImages(images, model: slug) { data, error in
                if let error { relay.resume(throwing: error) } else { relay.resume(returning: data) }
            }
        }
        guard let data, let vectors = ImageEmbedVectors.decode(data, count: images.count) else {
            throw ImageEmbedClientError.invalidResponse("vectors of the wrong size for \(images.count) images")
        }
        return vectors
    }

    /// One vector per text, in order.
    public func embedTexts(_ texts: [String], model slug: String) async throws -> [[Float]] {
        if texts.isEmpty { return [] }
        let data: Data? = try await call { proxy, relay in
            proxy.embedTexts(texts, model: slug) { data, error in
                if let error { relay.resume(throwing: error) } else { relay.resume(returning: data) }
            }
        }
        guard let data, let vectors = ImageEmbedVectors.decode(data, count: texts.count) else {
            throw ImageEmbedClientError.invalidResponse("vectors of the wrong size for \(texts.count) texts")
        }
        return vectors
    }

    public func listenerEndpoint() async throws -> NSXPCListenerEndpoint {
        let endpoint: NSXPCListenerEndpoint? = try await call { proxy, relay in
            proxy.getListenerEndpoint { endpoint, error in
                if let error { relay.resume(throwing: error) } else { relay.resume(returning: endpoint) }
            }
        }
        guard let endpoint else { throw ImageEmbedClientError.invalidResponse("no listener endpoint") }
        return endpoint
    }
}

import Foundation
import GarageXPCKit
import ImageEmbedClient

/// Reaches GarageImageEmbedXPCService over NSXPC from a sibling XPC service, which cannot look it up
/// by name: through the listener endpoint the app hands the process
/// (`GarageImageEmbedEndpointStore`). No Python; the Python bridge (`ImageEmbedBridge`) and the
/// Rust embed worker's host both go through it. Nothing here opens a network connection.
public enum ImageEmbedAccess {
    /// What image embedding needs from the service; `ImageEmbedClient` in production, a fake in tests.
    public struct Service: Sendable {
        public var loadModel: @Sendable (String) async throws -> ImageEmbedModelInfo
        public var embedImages: @Sendable ([Data], String) async throws -> [[Float]]
        public var embedTexts: @Sendable ([String], String) async throws -> [[Float]]

        public init(
            loadModel: @escaping @Sendable (String) async throws -> ImageEmbedModelInfo,
            embedImages: @escaping @Sendable ([Data], String) async throws -> [[Float]],
            embedTexts: @escaping @Sendable ([String], String) async throws -> [[Float]]
        ) {
            self.loadModel = loadModel
            self.embedImages = embedImages
            self.embedTexts = embedTexts
        }

        /// Over NSXPC, through the endpoint the app handed this process. The client is remade
        /// whenever a new endpoint arrives (the service or the app was relaunched).
        public static func handedOverEndpoint(store: GarageImageEmbedEndpointStore = .shared) -> Service {
            let cache = ClientCache(store: store)
            return Service(
                loadModel: { slug in try await cache.client().loadModel(slug: slug) },
                embedImages: { images, slug in try await cache.client().embedImages(images, model: slug) },
                embedTexts: { texts, slug in try await cache.client().embedTexts(texts, model: slug) }
            )
        }
    }

    public enum AccessError: LocalizedError {
        case endpointNotHandedOver
        case badRequest(String)
        case timedOut(String)

        public var errorDescription: String? {
            switch self {
            case .endpointNotHandedOver:
                return "GarageImageEmbedXPCService endpoint not handed over yet: the Garage app hands it over after launch"
            case .badRequest(let message):
                return "Bad image embedding request: \(message)"
            case .timedOut(let what):
                return "\(what) did not finish within the time allowed"
            }
        }
    }

    /// Self test for a service that embeds with image models: GarageImageEmbedXPCService must
    /// answer this process over NSXPC, through the endpoint the app handed over, or image
    /// embeddings cannot work. Skipped until the app has handed one over; the service re-runs it
    /// when one arrives.
    public static func selfTest(store: GarageImageEmbedEndpointStore = .shared) -> GarageXPCSelfTest {
        GarageXPCSelfTest(
            name: GarageImageEmbedEndpointStore.dependentSelfTestName,
            description: "Reaches GarageImageEmbedXPCService over NSXPC, through the endpoint the app hands over, which image embeddings go through."
        ) {
            guard let endpoint = store.endpoint else {
                throw GarageXPCSelfTestSkipped("GarageImageEmbedXPCService endpoint not handed over yet: the Garage app hands it over after launch")
            }
            // Made here, not in the task: the endpoint is not Sendable, the client is.
            let client = ImageEmbedClient(endpoint: endpoint)
            let result = ImageEmbedAccess.blocking(timeout: .seconds(10), what: "GarageImageEmbedXPCService") {
                let reply = try await client.ping()
                let models = (try? await client.listModels().map(\.slug)) ?? []
                return "\(reply)\nResident: \(models.isEmpty ? "none" : models.joined(separator: ", "))"
            }
            switch result {
            case .success(let text):
                return text
            case .failure(let error):
                throw GarageXPCSelfTestFailure("GarageImageEmbedXPCService is unreachable through the handed-over endpoint", details: error.localizedDescription)
            }
        }
    }

    /// Runs `work` on a detached task and waits for it, as a C entry point must. The wait is
    /// bounded so a hung service surfaces as an error, not a stall.
    public static func blocking<T: Sendable>(
        timeout: DispatchTimeInterval,
        what: String,
        _ work: @escaping @Sendable () async throws -> T
    ) -> Result<T, Error> {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task.detached {
            do {
                box.set(.success(try await work()))
            } catch {
                box.set(.failure(error))
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success, let result = box.get() else {
            return .failure(AccessError.timedOut(what))
        }
        return result
    }
}

/// One `ImageEmbedClient` per handed-over endpoint generation.
private final class ClientCache: @unchecked Sendable {
    private let store: GarageImageEmbedEndpointStore
    private let lock = NSLock()
    private var cached: (generation: Int, client: ImageEmbedClient)?

    init(store: GarageImageEmbedEndpointStore) {
        self.store = store
    }

    func client() throws -> ImageEmbedClient {
        lock.lock()
        defer { lock.unlock() }
        let generation = store.generation
        if let cached, cached.generation == generation {
            return cached.client
        }
        guard let endpoint = store.endpoint else {
            throw ImageEmbedAccess.AccessError.endpointNotHandedOver
        }
        cached?.client.invalidate()
        let client = ImageEmbedClient(endpoint: endpoint)
        cached = (generation, client)
        return client
    }
}

private final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?

    func set(_ value: Result<T, Error>) {
        lock.lock()
        result = value
        lock.unlock()
    }

    func get() -> Result<T, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

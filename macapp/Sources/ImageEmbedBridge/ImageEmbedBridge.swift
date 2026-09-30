import Foundation
import ImageEmbedClient
import OSLog
import PythonKit
import PythonXPCService

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag", category: "ImageEmbedBridge")

/// Lets the Python embedded in this process embed with `image_xpc` models through its Swift host.
///
/// `install()` hands Python (`garage_rag.xpc.image_host.install_image_embedder`) the addresses of
/// two C functions; Python calls them through ctypes, which releases the GIL for the call, so a
/// batch running on the Neural Engine does not stall the interpreter's other threads. Both block on
/// `ImageEmbedClient`, which talks to GarageImageEmbedXPCService over NSXPC. Nothing here touches
/// Python while a call is in flight, and nothing here opens a network connection.
///
/// The services that install it are siblings of GarageImageEmbedXPCService, which cannot look it
/// up by name: they connect through the listener endpoint the app hands them
/// (`GarageImageEmbedEndpointStore`).
///
/// C signatures (mirrored in `garage_rag/xpc/image_host.py`):
///
/// `int32_t describe(const char *model_ref, char *json, size_t capacity)`: loads the model when it
/// is not resident and writes `{"dims": .., "image_size": .., "text_length": ..}`; nonzero on
/// failure, with the reason in `json`.
///
/// `int32_t embed(const char *request_json, const uint8_t *const *blobs, const size_t *sizes,
/// size_t count, float *out, size_t out_capacity, char *message, size_t capacity)`: `request_json`
/// is `{"model": ref, "texts": [...]}` or `{"model": ref, "images": n}` with `n` encoded image
/// files in `blobs`; writes the vectors one after another into `out`; nonzero on failure, with the
/// reason in `message`.
public enum ImageEmbedBridge {
    public typealias DescribeEntry = @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<CChar>?, Int) -> Int32
    public typealias EmbedEntry = @convention(c) (
        UnsafePointer<CChar>?,
        UnsafePointer<UnsafePointer<UInt8>?>?,
        UnsafePointer<Int>?,
        Int,
        UnsafeMutablePointer<Float>?,
        Int,
        UnsafeMutablePointer<CChar>?,
        Int
    ) -> Int32

    /// What the entry points need from the service; `ImageEmbedClient` in production, a fake in tests.
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

    public enum BridgeError: LocalizedError {
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

    private static let lock = NSLock()
    nonisolated(unsafe) private static var installedService: Service?
    nonisolated(unsafe) private static var registeredWithPython = false

    static var service: Service? {
        lock.lock()
        defer { lock.unlock() }
        return installedService
    }

    /// Sets the service the C entry points use (tests install a fake one).
    public static func setService(_ service: Service?) {
        lock.lock()
        installedService = service
        lock.unlock()
    }

    /// Loading a large Core ML package the first time can take a while; a batch is bounded by the
    /// service's own per-call work.
    static let loadTimeout: DispatchTimeInterval = .seconds(300)
    static let embedTimeout: DispatchTimeInterval = .seconds(600)

    // MARK: - Entry points

    /// The describe function Python calls. A global with no captures, as a C function pointer must be.
    public static let describeEntry: DescribeEntry = { refPointer, buffer, capacity in
        guard let refPointer else {
            ImageEmbedBridge.write("no model name given", to: buffer, capacity: capacity)
            return 2
        }
        let slug = String(cString: refPointer).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let service = ImageEmbedBridge.service else {
            ImageEmbedBridge.write("this process has no image embedding bridge", to: buffer, capacity: capacity)
            return 3
        }
        switch ImageEmbedBridge.blocking(timeout: ImageEmbedBridge.loadTimeout, what: "loading image model \(slug)", { try await service.loadModel(slug) }) {
        case .success(let info):
            ImageEmbedBridge.write("{\"dims\": \(info.dims), \"image_size\": \(info.imageSize), \"text_length\": \(info.textLength)}", to: buffer, capacity: capacity)
            return 0
        case .failure(let error):
            let text = error.localizedDescription
            logger.error("Loading image model \(slug, privacy: .public) failed: \(text, privacy: .public)")
            ImageEmbedBridge.write(text, to: buffer, capacity: capacity)
            return 1
        }
    }

    /// The embed function Python calls.
    public static let embedEntry: EmbedEntry = { requestPointer, blobs, sizes, count, out, outCapacity, message, capacity in
        guard let requestPointer else {
            ImageEmbedBridge.write("no request given", to: message, capacity: capacity)
            return 2
        }
        guard let service = ImageEmbedBridge.service else {
            ImageEmbedBridge.write("this process has no image embedding bridge", to: message, capacity: capacity)
            return 3
        }
        let request: Request
        do {
            request = try Request.parse(String(cString: requestPointer), blobs: blobs, sizes: sizes, count: count)
        } catch {
            ImageEmbedBridge.write(error.localizedDescription, to: message, capacity: capacity)
            return 2
        }
        let result: Result<[[Float]], Error>
        switch request.payload {
        case .images(let images):
            result = ImageEmbedBridge.blocking(timeout: ImageEmbedBridge.embedTimeout, what: "embedding \(images.count) image(s)") {
                try await service.embedImages(images, request.model)
            }
        case .texts(let texts):
            result = ImageEmbedBridge.blocking(timeout: ImageEmbedBridge.embedTimeout, what: "embedding \(texts.count) text(s)") {
                try await service.embedTexts(texts, request.model)
            }
        }
        switch result {
        case .success(let vectors):
            let total = vectors.reduce(0) { $0 + $1.count }
            guard vectors.count == request.count else {
                ImageEmbedBridge.write("the service returned \(vectors.count) vector(s) for \(request.count) input(s)", to: message, capacity: capacity)
                return 4
            }
            guard total <= outCapacity, let out else {
                ImageEmbedBridge.write("the service returned \(total) values but the caller has room for \(outCapacity)", to: message, capacity: capacity)
                return 4
            }
            var offset = 0
            for vector in vectors {
                vector.withUnsafeBufferPointer { source in
                    if let base = source.baseAddress {
                        (out + offset).update(from: base, count: source.count)
                    }
                }
                offset += vector.count
            }
            ImageEmbedBridge.write("", to: message, capacity: capacity)
            return 0
        case .failure(let error):
            let text = error.localizedDescription
            logger.error("image_xpc embed with \(request.model, privacy: .public) failed: \(text, privacy: .public)")
            ImageEmbedBridge.write(text, to: message, capacity: capacity)
            return 1
        }
    }

    /// The entry points' addresses, as Python receives them.
    public static var describeEntryAddress: Int {
        Int(bitPattern: unsafeBitCast(describeEntry, to: UnsafeRawPointer.self))
    }

    public static var embedEntryAddress: Int {
        Int(bitPattern: unsafeBitCast(embedEntry, to: UnsafeRawPointer.self))
    }

    // MARK: - Install

    /// Installs the standard NSXPC service, on the handed-over GarageImageEmbedXPCService endpoint
    /// (unless a service is set already), and registers the entry points with Python. Call once
    /// Python is ready; takes the GIL itself; later calls do nothing. Returns false (and logs) when
    /// `garage_rag` cannot be imported, so the service still starts.
    @discardableResult
    public static func install() -> Bool {
        lock.lock()
        if registeredWithPython {
            lock.unlock()
            return true
        }
        if installedService == nil {
            installedService = .handedOverEndpoint()
        }
        lock.unlock()
        do {
            try GaragePythonRuntime.shared.withGILDescribingErrors {
                let host = try Python.attemptImport("garage_rag.xpc.image_host")
                _ = try host.install_image_embedder.throwing.dynamicallyCall(withArguments: [describeEntryAddress, embedEntryAddress])
            }
            lock.lock()
            registeredWithPython = true
            lock.unlock()
            logger.info("image embedding bridge installed for Python")
            return true
        } catch {
            logger.error("Could not install the image embedding bridge: \(error.localizedDescription, privacy: .public)")
            GarageXPCOutputCapture.shared.log(level: "ERROR", message: "Could not install the image embedding bridge: \(error.localizedDescription)")
            return false
        }
    }

    /// Self test for a service that installs the bridge: GarageImageEmbedXPCService must answer this
    /// process over NSXPC, through the endpoint the app handed over, or image embeddings cannot work.
    /// Skipped until the app has handed one over; the service re-runs it when one arrives.
    public static func selfTest(store: GarageImageEmbedEndpointStore = .shared) -> GarageXPCSelfTest {
        GarageXPCSelfTest(
            name: GarageImageEmbedEndpointStore.dependentSelfTestName,
            description: "Reaches GarageImageEmbedXPCService over NSXPC, through the endpoint the app hands over, which image embeddings go through.",
            requiresPython: false
        ) {
            guard let endpoint = store.endpoint else {
                throw GarageXPCSelfTestSkipped("GarageImageEmbedXPCService endpoint not handed over yet: the Garage app hands it over after launch")
            }
            // Made here, not in the task: the endpoint is not Sendable, the client is.
            let client = ImageEmbedClient(endpoint: endpoint)
            let result = ImageEmbedBridge.blocking(timeout: .seconds(10), what: "GarageImageEmbedXPCService") {
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

    // MARK: - Helpers

    struct Request {
        enum Payload {
            case images([Data])
            case texts([String])
        }

        var model: String
        var payload: Payload

        var count: Int {
            switch payload {
            case .images(let images): return images.count
            case .texts(let texts): return texts.count
            }
        }

        static func parse(
            _ json: String,
            blobs: UnsafePointer<UnsafePointer<UInt8>?>?,
            sizes: UnsafePointer<Int>?,
            count: Int
        ) throws -> Request {
            guard let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let model = object["model"] as? String, !model.isEmpty
            else {
                throw BridgeError.badRequest("request is not a JSON object naming a model")
            }
            if let texts = object["texts"] as? [String] {
                return Request(model: model, payload: .texts(texts))
            }
            if let imageCount = object["images"] as? Int {
                guard imageCount == count, let blobs, let sizes else {
                    throw BridgeError.badRequest("request names \(imageCount) image(s) but \(count) blob(s) were passed")
                }
                var images: [Data] = []
                images.reserveCapacity(count)
                for index in 0..<count {
                    guard let base = blobs[index] else {
                        throw BridgeError.badRequest("image \(index) is null")
                    }
                    images.append(Data(bytes: base, count: sizes[index]))
                }
                return Request(model: model, payload: .images(images))
            }
            throw BridgeError.badRequest("request carries neither texts nor images")
        }
    }

    /// Runs `work` on a detached task and waits for it, as a C entry point (called with the GIL
    /// released) must. The wait is bounded so a hung service surfaces as an error, not a stall.
    static func blocking<T: Sendable>(
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
            return .failure(BridgeError.timedOut(what))
        }
        return result
    }

    static func write(_ text: String, to buffer: UnsafeMutablePointer<CChar>?, capacity: Int) {
        guard let buffer, capacity > 0 else { return }
        // Whole scalars only, so a truncated message is still valid UTF-8.
        var bytes: [UInt8] = []
        for scalar in text.unicodeScalars {
            let encoded = Array(String(scalar).utf8)
            if bytes.count + encoded.count > capacity - 1 { break }
            bytes.append(contentsOf: encoded)
        }
        bytes.withUnsafeBufferPointer { source in
            buffer.withMemoryRebound(to: UInt8.self, capacity: capacity) { dest in
                if let base = source.baseAddress {
                    dest.update(from: base, count: source.count)
                }
                dest[source.count] = 0
            }
        }
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
            throw ImageEmbedBridge.BridgeError.endpointNotHandedOver
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

import Foundation
import ImageEmbedBridgeCore
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

    /// What the entry points need from the service (`ImageEmbedAccess.Service`).
    public typealias Service = ImageEmbedAccess.Service
    public typealias BridgeError = ImageEmbedAccess.AccessError

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

    /// Self test for a service that installs the bridge (`ImageEmbedAccess.selfTest`).
    public static func selfTest(store: GarageImageEmbedEndpointStore = .shared) -> GarageXPCSelfTest {
        ImageEmbedAccess.selfTest(store: store)
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

    static func blocking<T: Sendable>(
        timeout: DispatchTimeInterval,
        what: String,
        _ work: @escaping @Sendable () async throws -> T
    ) -> Result<T, Error> {
        ImageEmbedAccess.blocking(timeout: timeout, what: what, work)
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

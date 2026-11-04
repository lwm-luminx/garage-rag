import Foundation
import GarageEmbedFFI
import ImageEmbedBridgeCore
import LlamaModelLoaderCore

/// The process the Rust embed worker runs in, as the worker sees it (`GarageEmbedHost` in
/// `garage_embed.h`): it carries the model-server requests the worker's egress rules approved, and
/// hears each step of a backfill.
///
/// - `llama_xpc` requests go to LlamaXPCService over NSXPC (`LlamaServerRequests`), never HTTP, and
///   a model it does not have loaded is loaded on demand (`LlamaModelLoader`).
/// - Ollama and LM Studio requests go over URLSession, to exactly the URL the worker approved: no
///   proxy, no cookies or cache, and a redirect comes back as the reply instead of being followed.
/// - Image models go to GarageImageEmbedXPCService over NSXPC (`ImageEmbedAccess`); the host reads
///   the image files the worker names.
///
/// Every member is replaceable, for tests.
public final class GarageEmbedWorkerHost: @unchecked Sendable {
    public typealias LlamaRequest = @Sendable (_ method: String, _ path: String, _ body: String?, _ timeout: TimeInterval) -> Result<(Int, String), Error>
    public typealias HTTPSend = @Sendable (URLRequest) -> Result<(Int, Data), Error>

    public var llamaRequest: LlamaRequest
    public var ensureLlamaModel: @Sendable (String) -> Result<String, Error>
    public var images: ImageEmbedAccess.Service?
    public var readImage: @Sendable (String) throws -> Data
    public var send: HTTPSend
    public var progress: @Sendable (GarageEmbedWorker.Event) -> Void
    public var isCancelled: @Sendable () -> Bool

    public init(
        llamaRequest: @escaping LlamaRequest = { LlamaServerRequests.perform(method: $0, path: $1, body: $2, timeout: $3) },
        ensureLlamaModel: @escaping @Sendable (String) -> Result<String, Error> = GarageEmbedWorkerHost.loadOnDemand,
        images: ImageEmbedAccess.Service? = .handedOverEndpoint(),
        readImage: @escaping @Sendable (String) throws -> Data = { try Data(contentsOf: URL(fileURLWithPath: $0)) },
        send: @escaping HTTPSend = { GarageEmbedHTTP.send($0) },
        progress: @escaping @Sendable (GarageEmbedWorker.Event) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) {
        self.llamaRequest = llamaRequest
        self.ensureLlamaModel = ensureLlamaModel
        self.images = images
        self.readImage = readImage
        self.send = send
        self.progress = progress
        self.isCancelled = isCancelled
    }

    /// One loader per process, so concurrent loads of one model share a load.
    private static let loader = LlamaModelLoader.standard(service: .handedOverEndpoint())

    /// Loads a llama_xpc model through the LlamaXPCService endpoint the app handed this process.
    public static let loadOnDemand: @Sendable (String) -> Result<String, Error> = { alias in
        loader.ensureLoadedBlocking(alias: alias).map { outcome in
            switch outcome {
            case .alreadyLoaded: return "\(alias) is already loaded"
            case .loaded(let detail): return detail
            }
        }
    }

    /// Loading a large Core ML package the first time can take a while; a batch is bounded by the
    /// service's own per-call work. The same bounds as the Python bridge's.
    static let imageTimeout: DispatchTimeInterval = .seconds(600)

    struct HostError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - The worker's calls

    /// `{"backend", "method", "url", "path", "headers", "body", "timeout"}` -> `{"status", "body"}`.
    public func http(_ request: [String: Any]) throws -> [String: Any] {
        let method = request["method"] as? String ?? "GET"
        let body = request["body"] as? String ?? ""
        let timeout = (request["timeout"] as? NSNumber)?.doubleValue ?? 600
        if request["backend"] as? String == "llama_xpc" {
            let path = request["path"] as? String ?? ""
            switch llamaRequest(method, path, body.isEmpty ? nil : body, timeout) {
            case .success(let (status, text)):
                return ["status": status, "body": text]
            case .failure(let error):
                throw HostError(message: "LlamaXPCService did not answer over XPC: \(error.localizedDescription)")
            }
        }
        guard let text = request["url"] as? String, let url = URL(string: text) else {
            throw HostError(message: "the worker asked for no URL")
        }
        var urlRequest = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        urlRequest.httpMethod = method
        urlRequest.httpShouldHandleCookies = false
        for case let pair as [String] in request["headers"] as? [Any] ?? [] where pair.count == 2 {
            urlRequest.setValue(pair[1], forHTTPHeaderField: pair[0])
        }
        if !body.isEmpty {
            urlRequest.httpBody = Data(body.utf8)
        }
        switch send(urlRequest) {
        case .success(let (status, data)):
            return ["status": status, "body": String(decoding: data, as: UTF8.self)]
        case .failure(let error):
            throw HostError(message: error.localizedDescription)
        }
    }

    /// `{"model"}` -> what was done.
    public func ensureModel(_ request: [String: Any]) throws -> String {
        guard let model = request["model"] as? String, !model.isEmpty else {
            throw HostError(message: "no model named")
        }
        switch ensureLlamaModel(model) {
        case .success(let detail): return detail
        case .failure(let error): throw HostError(message: error.localizedDescription)
        }
    }

    /// `{"model", "paths"}` -> `{"vectors"}`: the image tower over the files at `paths`.
    public func embedImages(_ request: [String: Any]) throws -> [String: Any] {
        guard let images else { throw HostError(message: "this process has no image embedding service") }
        guard let model = request["model"] as? String, let paths = request["paths"] as? [String] else {
            throw HostError(message: "the request names no model or paths")
        }
        let blobs = try paths.map { path in
            do {
                return try readImage(path)
            } catch {
                throw HostError(message: "cannot read \(path): \(error.localizedDescription)")
            }
        }
        let embed = images.embedImages
        let result = ImageEmbedAccess.blocking(timeout: Self.imageTimeout, what: "embedding \(blobs.count) image(s)") {
            try await embed(blobs, model)
        }
        return ["vectors": try result.get()]
    }

    /// `{"model", "texts"}` -> `{"vectors"}`: the text tower of an image model.
    public func embedImageTexts(_ request: [String: Any]) throws -> [String: Any] {
        guard let images else { throw HostError(message: "this process has no image embedding service") }
        guard let model = request["model"] as? String, let texts = request["texts"] as? [String] else {
            throw HostError(message: "the request names no model or texts")
        }
        let embed = images.embedTexts
        let result = ImageEmbedAccess.blocking(timeout: Self.imageTimeout, what: "embedding \(texts.count) text(s)") {
            try await embed(texts, model)
        }
        return ["vectors": try result.get()]
    }

    // MARK: - The C side

    /// The struct the worker calls through, with this host as its context. Valid while the host is.
    var cHost: GarageEmbedHost {
        GarageEmbedHost(
            context: Unmanaged.passUnretained(self).toOpaque(),
            http: Self.httpEntry,
            ensure_llama_model: Self.ensureModelEntry,
            embed_images: Self.embedImagesEntry,
            embed_image_texts: Self.embedImageTextsEntry,
            release: Self.releaseEntry,
            progress: Self.progressEntry,
            cancelled: Self.cancelledEntry
        )
    }

    /// Answers one call: 0 with the reply, or 1 with the reason.
    private static func answer(
        _ context: UnsafeMutableRawPointer?,
        _ request: UnsafePointer<CChar>?,
        _ reply: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
        _ handle: (GarageEmbedWorkerHost, [String: Any]) throws -> Any
    ) -> Int32 {
        guard let context, let request, let reply else {
            reply?.pointee = strdup("the host was called without a context, request or reply")
            return 2
        }
        let host = Unmanaged<GarageEmbedWorkerHost>.fromOpaque(context).takeUnretainedValue()
        do {
            guard let object = try JSONSerialization.jsonObject(with: Data(String(cString: request).utf8)) as? [String: Any] else {
                throw HostError(message: "the request is not a JSON object")
            }
            let answer = try handle(host, object)
            let text: String
            if let string = answer as? String {
                text = string
            } else {
                text = String(decoding: try JSONSerialization.data(withJSONObject: answer), as: UTF8.self)
            }
            reply.pointee = strdup(text)
            return 0
        } catch {
            reply.pointee = strdup(error.localizedDescription)
            return 1
        }
    }

    private static let httpEntry: GarageEmbedHostCall = { context, request, reply in
        GarageEmbedWorkerHost.answer(context, request, reply) { host, object in try host.http(object) }
    }

    private static let ensureModelEntry: GarageEmbedHostCall = { context, request, reply in
        GarageEmbedWorkerHost.answer(context, request, reply) { host, object in try host.ensureModel(object) }
    }

    private static let embedImagesEntry: GarageEmbedHostCall = { context, request, reply in
        GarageEmbedWorkerHost.answer(context, request, reply) { host, object in try host.embedImages(object) }
    }

    private static let embedImageTextsEntry: GarageEmbedHostCall = { context, request, reply in
        GarageEmbedWorkerHost.answer(context, request, reply) { host, object in try host.embedImageTexts(object) }
    }

    private static let releaseEntry: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<CChar>?) -> Void = { _, reply in
        free(reply)
    }

    private static let progressEntry: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void = { context, event in
        guard let context, let event else { return }
        let host = Unmanaged<GarageEmbedWorkerHost>.fromOpaque(context).takeUnretainedValue()
        if let decoded = try? JSONDecoder().decode(GarageEmbedWorker.Event.self, from: Data(String(cString: event).utf8)) {
            host.progress(decoded)
        }
    }

    private static let cancelledEntry: @convention(c) (UnsafeMutableRawPointer?) -> Bool = { context in
        guard let context else { return false }
        return Unmanaged<GarageEmbedWorkerHost>.fromOpaque(context).takeUnretainedValue().isCancelled()
    }
}

/// Ollama and LM Studio over HTTP, as the embed worker's egress rules require: exactly the URL
/// asked for, with no proxy, cookies or cache, and redirects returned rather than followed.
public enum GarageEmbedHTTP {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: false,
            kCFNetworkProxiesHTTPSEnable as String: false,
            kCFNetworkProxiesSOCKSEnable as String: false,
            kCFNetworkProxiesProxyAutoConfigEnable as String: false,
        ]
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration, delegate: RedirectRefuser(), delegateQueue: nil)
    }()

    /// Sends `request` and waits for the reply (the request's own timeout bounds the wait).
    public static func send(_ request: URLRequest) -> Result<(Int, Data), Error> {
        let semaphore = DispatchSemaphore(value: 0)
        let box = SendBox()
        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                box.result = .failure(error)
            } else if let response = response as? HTTPURLResponse {
                box.result = .success((response.statusCode, data ?? Data()))
            } else {
                box.result = .failure(URLError(.badServerResponse))
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        return box.result ?? .failure(URLError(.unknown))
    }

    private final class RedirectRefuser: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    /// Written once by the completion handler, read after the semaphore: no lock needed.
    private final class SendBox: @unchecked Sendable {
        var result: Result<(Int, Data), Error>?
    }
}

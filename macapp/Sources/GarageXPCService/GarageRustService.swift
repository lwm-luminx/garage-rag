import Foundation
import GarageEmbedWorker
import GarageServiceFFI

/// GarageService (`rust/garage-service`), linked into this process through its C ABI
/// (`garage_service.h`): the gRPC backend of `garage_rag.service.server` without Python.
///
/// - It listens where the app says: the Unix-domain socket in the App Group container
///   (`GarageSockets`), or a loopback port, and requires the app's per-launch token on every call
///   but `EnsureLlamaModel`.
/// - It runs on the `garage.json` in the app's working directory, writing it there on the first
///   `SetSetting`, and applies the bundled schema (`Contents/Resources/schema`) on `InitDb`.
/// - The model servers are reached through this process: llama_xpc over NSXPC with on-demand loads,
///   Ollama and LM Studio over URLSession, image models over NSXPC, only at the origins the
///   service's egress rules approved (`GarageEmbedWorkerHost`, the embed worker's host, carries all
///   three, as it does for the MCP server).
final class GarageRustService: @unchecked Sendable {
    /// Where the server listens: the socket wins over host and port.
    enum Endpoint: Equatable {
        case socket(String)
        case tcp(host: String, port: Int)

        var description: String {
            switch self {
            case .socket(let path): return "unix:\(path)"
            case .tcp(let host, let port): return "\(host):\(port)"
            }
        }

        fileprivate var json: [String: Any] {
            switch self {
            case .socket(let path): return ["socket": path]
            case .tcp(let host, let port): return ["host": host, "port": port]
            }
        }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The host the service calls back into. Owned here, so its context outlives the server.
    private let host: GarageServiceProcessHost
    private let lock = NSLock()
    private var server: OpaquePointer?

    /// Where the server listens, as bound: `unix:<path>` or `<ip>:<port>` (the real port of a `:0` bind).
    let endpoint: String
    /// The port bound, for a TCP endpoint.
    let port: Int?

    private init(host: GarageServiceProcessHost, server: OpaquePointer, endpoint: String, port: Int?) {
        self.host = host
        self.server = server
        self.endpoint = endpoint
        self.port = port
    }

    deinit {
        stop(graceSeconds: 0)
    }

    /// Starts the server and returns once it listens.
    ///
    /// - Parameters:
    ///   - token: the per-launch token every call but `EnsureLlamaModel` must carry; `nil` turns the
    ///     check off (then only a server on a socket answers the config-changing methods).
    ///   - configPath: the `garage.json` to run on; one that does not exist yet is written by
    ///     `SetSetting`. `nil` searches `./garage.json`, then `~/.garage.json`.
    ///   - sqlDir: the schema `InitDb` applies when its request names none.
    static func start(
        endpoint: Endpoint,
        token: String?,
        configPath: String?,
        sqlDir: String?,
        host: GarageServiceProcessHost = GarageServiceProcessHost()
    ) throws -> GarageRustService {
        var request: [String: Any] = ["endpoint": endpoint.json]
        if let token, !token.isEmpty {
            request["token"] = token
        }
        if let configPath, !configPath.isEmpty {
            request["config"] = configPath
        }
        if let sqlDir, !sqlDir.isEmpty {
            request["sql_dir"] = sqlDir
        }
        let text = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        var cHost = host.cHost
        var server: OpaquePointer?
        var result: UnsafeMutablePointer<CChar>?
        let status = text.withCString { garage_service_start($0, &cHost, &server, &result) }
        let reply = result.map { String(cString: $0) } ?? ""
        garage_service_string_free(result)
        let object = (try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any] ?? [:]
        guard status == GARAGE_SERVICE_OK, let server else {
            throw Failure(message: object["error"] as? String ?? "GarageService did not start (\(status))")
        }
        return GarageRustService(
            host: host,
            server: server,
            endpoint: object["endpoint"] as? String ?? endpoint.description,
            port: object["port"] as? Int
        )
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let server else { return false }
        return garage_service_is_running(server)
    }

    /// Stops the server: no new connections, calls in flight get `graceSeconds` to finish, the socket
    /// file is removed.
    func stop(graceSeconds: Double) {
        lock.lock()
        let running = server
        server = nil
        lock.unlock()
        if let running {
            garage_service_stop(running, graceSeconds)
        }
    }

    /// The service's version, as `GetVersion` reports it.
    static var version: String {
        String(cString: garage_service_version())
    }

    /// Connects to the database the configuration (or `GARAGE_DATABASE_URL`) names and returns its
    /// version and the redacted URL, for the Database Connection self test.
    static func probe(configPath: String?) throws -> (database: String, databaseURL: String) {
        var request: [String: Any] = [:]
        if let configPath, !configPath.isEmpty {
            request["config"] = configPath
        }
        let text = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        var result: UnsafeMutablePointer<CChar>?
        let status = text.withCString { garage_service_probe($0, &result) }
        let reply = result.map { String(cString: $0) } ?? ""
        garage_service_string_free(result)
        let object = (try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any] ?? [:]
        guard status == GARAGE_SERVICE_OK else {
            throw Failure(message: object["error"] as? String ?? "the database probe failed (\(status))")
        }
        return (object["database"] as? String ?? "unknown", object["database_url"] as? String ?? "")
    }

    /// The schema the app bundles (`Contents/Resources/schema`, `//macapp/externals:schema_output`),
    /// found from this bundle: the app's own when hosted in-process, else the app above the XPC
    /// service's bundle. `nil` outside an app bundle (tests), where the service's own search applies.
    static func bundledSchemaDirectory(from bundle: Bundle = .main) -> String? {
        var candidate: URL? = bundle.bundleURL
        while let url = candidate {
            let schema = url.appendingPathComponent("Contents/Resources/schema", isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: schema.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return schema.path
            }
            let parent = url.deletingLastPathComponent()
            candidate = parent.path == url.path ? nil : parent
        }
        return nil
    }
}

/// The process GarageService runs in, as the service sees it (`GarageServiceHost`): it carries the
/// model servers' requests, which the service's egress rules approved, through the embed worker's
/// host, loads llama_xpc models on demand (`EnsureLlamaModel`, and a request that found one not
/// loaded) and embeds with the image models over NSXPC. Its calls may come from any of the server's
/// threads, several at once.
final class GarageServiceProcessHost: @unchecked Sendable {
    let worker: GarageEmbedWorkerHost

    init(worker: GarageEmbedWorkerHost = GarageEmbedWorkerHost()) {
        self.worker = worker
    }

    /// The struct the service calls through, with this host as its context. Valid while the host is.
    var cHost: GarageServiceHost {
        GarageServiceHost(
            context: Unmanaged.passUnretained(self).toOpaque(),
            http: Self.httpEntry,
            ensure_llama_model: Self.ensureModelEntry,
            embed_images: Self.embedImagesEntry,
            embed_image_texts: Self.embedImageTextsEntry,
            release: Self.releaseEntry
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
        let host = Unmanaged<GarageServiceProcessHost>.fromOpaque(context).takeUnretainedValue()
        do {
            guard let object = try JSONSerialization.jsonObject(with: Data(String(cString: request).utf8)) as? [String: Any] else {
                throw GarageRustService.Failure(message: "the request is not a JSON object")
            }
            let answer = try handle(host.worker, object)
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

    private static let httpEntry: GarageServiceHostCall = { context, request, reply in
        GarageServiceProcessHost.answer(context, request, reply) { worker, object in try worker.http(object) }
    }

    private static let ensureModelEntry: GarageServiceHostCall = { context, request, reply in
        GarageServiceProcessHost.answer(context, request, reply) { worker, object in try worker.ensureModel(object) }
    }

    private static let embedImagesEntry: GarageServiceHostCall = { context, request, reply in
        GarageServiceProcessHost.answer(context, request, reply) { worker, object in try worker.embedImages(object) }
    }

    private static let embedImageTextsEntry: GarageServiceHostCall = { context, request, reply in
        GarageServiceProcessHost.answer(context, request, reply) { worker, object in try worker.embedImageTexts(object) }
    }

    private static let releaseEntry: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<CChar>?) -> Void = { _, reply in
        free(reply)
    }
}

import Foundation
import GarageEmbedWorker
import GarageMCPFFI

/// Garage's MCP server (`rust/garage-mcp`), linked into this process through its C ABI
/// (`garage_mcp.h`): the tools of `garage_rag.mcp_server` without Python.
///
/// - The corpus is read only through GarageService (its `Corpus*` calls), at the address and with the
///   per-launch token the app configured; GarageService is reached on the first tool call, so the
///   server may start before the backend and outlive a restart of it.
/// - The local model (`rag_ask`, `rag_generate`, `rag_agent`) is reached through this process: llama_xpc
///   over NSXPC with on-demand loads, Ollama and LM Studio over URLSession, only at the origins the
///   server's egress rules approved (`GarageEmbedWorkerHost`, the embed worker's host, carries both).
/// - Clients reach it over the streamable HTTP transport on loopback, the one listener the app opts in
///   to on the MCP page.
final class GarageMCPRustServer: @unchecked Sendable {
    /// Where GarageService listens: its socket wins over host and port.
    enum GRPCTarget: Equatable {
        case socket(String)
        case tcp(host: String, port: Int)

        var description: String {
            switch self {
            case .socket(let path): return "unix:\(path)"
            case .tcp(let host, let port): return "\(host):\(port)"
            }
        }

        fileprivate func json(token: String?) -> [String: Any] {
            var object: [String: Any]
            switch self {
            case .socket(let path): object = ["socket": path]
            case .tcp(let host, let port): object = ["host": host, "port": port]
            }
            if let token, !token.isEmpty {
                object["token"] = token
            }
            return object
        }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The host the server calls back into. Owned here, so its context outlives the server.
    private let host: GarageMCPServerHost
    private let lock = NSLock()
    private var server: OpaquePointer?

    /// `host:port` the listener bound.
    let address: String
    let path: String

    private init(host: GarageMCPServerHost, server: OpaquePointer, address: String, path: String) {
        self.host = host
        self.server = server
        self.address = address
        self.path = path
    }

    deinit {
        stop()
    }

    /// Starts the HTTP transport and returns once it listens.
    static func start(
        grpc: GRPCTarget,
        token: String?,
        httpHost: String,
        port: Int,
        path: String,
        host: GarageMCPServerHost = GarageMCPServerHost()
    ) throws -> GarageMCPRustServer {
        let request: [String: Any] = [
            "grpc": grpc.json(token: token),
            "http": ["host": httpHost, "port": port, "path": path],
        ]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        var cHost = host.cHost
        var server: OpaquePointer?
        var result: UnsafeMutablePointer<CChar>?
        let status = text.withCString { garage_mcp_http_start($0, &cHost, &server, &result) }
        let reply = result.map { String(cString: $0) } ?? ""
        garage_mcp_string_free(result)
        let object = (try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any] ?? [:]
        guard status == GARAGE_MCP_OK, let server else {
            throw Failure(message: object["error"] as? String ?? "the MCP server did not start (\(status))")
        }
        return GarageMCPRustServer(
            host: host,
            server: server,
            address: object["address"] as? String ?? "\(httpHost):\(port)",
            path: object["path"] as? String ?? path
        )
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let server else { return false }
        return garage_mcp_http_is_running(server)
    }

    /// Stops the listener; requests in flight get up to ten seconds to finish.
    func stop() {
        lock.lock()
        let running = server
        server = nil
        lock.unlock()
        if let running {
            garage_mcp_http_stop(running)
        }
    }

    /// Answers one JSON-RPC message without a listener, for the self test: `nil` for a notification.
    static func handle(
        message: [String: Any],
        grpc: GRPCTarget,
        token: String?,
        host: GarageMCPServerHost = GarageMCPServerHost()
    ) throws -> [String: Any]? {
        let request: [String: Any] = ["grpc": grpc.json(token: token), "message": message, "transport": "http"]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        var cHost = host.cHost
        var result: UnsafeMutablePointer<CChar>?
        let status = withExtendedLifetime(host) {
            text.withCString { garage_mcp_handle($0, &cHost, &result) }
        }
        let reply = result.map { String(cString: $0) } ?? ""
        garage_mcp_string_free(result)
        let object = (try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any] ?? [:]
        guard status == GARAGE_MCP_OK else {
            throw Failure(message: object["error"] as? String ?? "the MCP server failed (\(status))")
        }
        return object["reply"] as? [String: Any]
    }
}

/// The process the MCP server runs in, as the server sees it (`GarageMcpHost`): it carries the local
/// model's requests, which the server's egress rules approved, through the embed worker's host, and
/// loads llama_xpc models on demand. Its calls may come from any thread, several at once.
final class GarageMCPServerHost: @unchecked Sendable {
    let worker: GarageEmbedWorkerHost

    init(worker: GarageEmbedWorkerHost = GarageEmbedWorkerHost(images: nil)) {
        self.worker = worker
    }

    /// The struct the server calls through, with this host as its context. Valid while the host is.
    var cHost: GarageMcpHost {
        GarageMcpHost(
            context: Unmanaged.passUnretained(self).toOpaque(),
            http: Self.httpEntry,
            ensure_llama_model: Self.ensureModelEntry,
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
        let host = Unmanaged<GarageMCPServerHost>.fromOpaque(context).takeUnretainedValue()
        do {
            guard let object = try JSONSerialization.jsonObject(with: Data(String(cString: request).utf8)) as? [String: Any] else {
                throw GarageMCPRustServer.Failure(message: "the request is not a JSON object")
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

    private static let httpEntry: GarageMcpHostCall = { context, request, reply in
        GarageMCPServerHost.answer(context, request, reply) { worker, object in try worker.http(object) }
    }

    private static let ensureModelEntry: GarageMcpHostCall = { context, request, reply in
        GarageMCPServerHost.answer(context, request, reply) { worker, object in try worker.ensureModel(object) }
    }

    private static let releaseEntry: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<CChar>?) -> Void = { _, reply in
        free(reply)
    }
}

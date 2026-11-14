import Foundation
import GarageXPCKit
import LlamaModelLoader
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag.mcp-server-xpc", category: "GarageMCPServerService")

/// Hosts Garage's MCP server (`rust/garage-mcp`, `GarageMCPRustServer`) as a managed background
/// service, so the host can restart it gracefully or immediately. It links no Python.
final class GarageMCPManagedServer: GarageManagedService, @unchecked Sendable {
    let name = "mcp-server"

    struct Endpoint: Equatable {
        var host: String
        var port: Int
        var path: String
    }

    private let lock = NSLock()
    private var server: GarageMCPRustServer?
    private var endpoint: Endpoint?
    /// Where GarageService listens and its token, read when the server starts.
    private let backend: () -> (GarageMCPRustServer.GRPCTarget?, String?)

    init(backend: @escaping () -> (GarageMCPRustServer.GRPCTarget?, String?)) {
        self.backend = backend
    }

    /// Sets the endpoint the next `start()` listens on.
    func configure(_ endpoint: Endpoint) {
        lock.lock()
        self.endpoint = endpoint
        lock.unlock()
    }

    /// Whether the app asked for the server (`startServer`) and has not stopped it since.
    var isWanted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return endpoint != nil
    }

    var isRunning: Bool {
        lock.lock()
        let current = server
        lock.unlock()
        return current?.isRunning ?? false
    }

    func start() throws {
        lock.lock()
        let wanted = endpoint
        lock.unlock()
        guard let wanted else {
            logger.info("mcp-server not configured yet; waiting for startServer")
            return
        }
        let (target, token) = backend()
        guard let target else {
            throw GarageXPCServiceError.notRunning("The app has not told the MCP service where GarageService listens yet")
        }
        let started = try GarageMCPRustServer.start(grpc: target, token: token, httpHost: wanted.host, port: wanted.port, path: wanted.path)
        lock.lock()
        let previous = server
        server = started
        lock.unlock()
        previous?.stop()
        logger.info("Garage MCP server listening on \(started.address, privacy: .public)\(started.path, privacy: .public), reading GarageService at \(target.description, privacy: .public)")
        GarageXPCOutputCapture.shared.log(message: "MCP server listening on \(started.address)\(started.path)")
    }

    func stop(graceful: Bool) throws {
        lock.lock()
        let running = server
        server = nil
        lock.unlock()
        guard let running else { return }
        running.stop()
        logger.info("Garage MCP server stopped (graceful: \(graceful, privacy: .public))")
    }

    /// Forgets the endpoint: the app stopped the server, so a configuration change must not start it.
    func forgetEndpoint() {
        lock.lock()
        endpoint = nil
        lock.unlock()
    }
}

/// GarageMCPServerService's delegate: the loopback HTTP server the MCP page starts, its self tests and
/// `exchange`. Open, so a build with its own MCP service (the App Store build's, in garage-enterprise,
/// chosen with `//macapp/Sources/GarageMCPServerService:service`) can keep these and add its own calls.
open class GarageMCPServerServiceDelegate: GarageXPCServiceBase, GarageMCPServerServiceProtocol {
    private lazy var mcpServer = GarageMCPManagedServer { [weak self] in
        (self?.grpc, self?.configurationValue(GarageXPCConfigurationKey.grpcToken))
    }

    /// The listener-free transport `exchange` answers through, made on first use and again when
    /// GarageService's address or token changes.
    private let endpointLock = NSLock()
    private var endpoint: GarageMCPRustEndpoint?
    /// Exchanges block while a tool runs, so each runs off the XPC queue, several at once.
    private let exchangeQueue = DispatchQueue(label: "me.rickmark.garage-rag.mcp-server-xpc.exchange", attributes: .concurrent)

    override public init(serviceName: String = "GarageMCPServerService", logFileName: String? = "mcp-server-xpc.log") {
        super.init(serviceName: serviceName, logFileName: logFileName)
    }

    override open var exportedInterface: NSXPCInterface {
        NSXPCInterface(with: GarageMCPServerServiceProtocol.self)
    }

    override open func additionalSelfTests() -> [GarageXPCSelfTest] {
        [
            GarageXPCSelfTest(
                name: "MCP Server",
                description: "The Rust MCP server is linked into this process and answers initialize and tools/list."
            ) {
                // Neither message reads the corpus, so no backend is needed.
                let target = GarageMCPRustServer.GRPCTarget.tcp(host: "127.0.0.1", port: 1)
                let initialize: [String: Any] = [
                    "jsonrpc": "2.0", "id": 1, "method": "initialize",
                    "params": ["protocolVersion": "2025-06-18", "capabilities": [:] as [String: Any], "clientInfo": ["name": "self-test", "version": "1"]],
                ]
                let list: [String: Any] = ["jsonrpc": "2.0", "id": 2, "method": "tools/list"]
                do {
                    let hello = try GarageMCPRustServer.handle(message: initialize, grpc: target, token: nil)
                    let tools = try GarageMCPRustServer.handle(message: list, grpc: target, token: nil)
                    let info = (hello?["result"] as? [String: Any])?["serverInfo"] as? [String: Any]
                    let names = ((tools?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
                    guard !names.isEmpty else {
                        throw GarageXPCSelfTestFailure("The MCP server listed no tools")
                    }
                    return "Server: \(info?["name"] as? String ?? "unnamed")\nTools: \(names.joined(separator: ", "))"
                } catch let failure as GarageXPCSelfTestFailure {
                    throw failure
                } catch {
                    throw GarageXPCSelfTestFailure("The MCP server did not answer", details: error.localizedDescription)
                }
            },
            GarageXPCSelfTest(
                name: "gRPC Connection",
                description: "The MCP server reaches GarageService (its socket, or host and port) with the app's token and reads the corpus statistics."
            ) { [weak self] in
                guard let self, let target = self.grpc else {
                    throw GarageXPCSelfTestSkipped("GARAGE_GRPC_SOCKET / GARAGE_GRPC_PORT are not configured")
                }
                let token = self.configurationValue(GarageXPCConfigurationKey.grpcToken)
                let call: [String: Any] = [
                    "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                    "params": ["name": "rag_stats", "arguments": [:] as [String: Any]],
                ]
                let reply = try GarageMCPRustServer.handle(message: call, grpc: target, token: token)
                let result = reply?["result"] as? [String: Any]
                guard let result, result["isError"] as? Bool == false else {
                    let text = ((result?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "no result"
                    throw GarageXPCSelfTestFailure("GarageService at \(target.description) did not answer rag_stats", details: text)
                }
                let stats = result["structuredContent"] as? [String: Any] ?? [:]
                return "Target: \(target.description)\nDocuments: \(stats["documents"] ?? "?"), chunks: \(stats["chunks"] ?? "?")"
            },
            LlamaEndpointSelfTest.make(),
        ]
    }

    override open func registerManagedServices(in host: GarageXPCServiceHost) {
        host.register(mcpServer)
    }

    /// A server the app asked for before it said where GarageService listens starts once it does.
    override open func didMergeConfiguration(_ options: [String: String]) {
        if let token = options["GARAGE_LMSTUDIO_API_TOKEN"], !token.isEmpty {
            // The server's LM Studio client reads it as Python's does.
            setenv("GARAGE_LMSTUDIO_API_TOKEN", token, 1)
        }
        guard mcpServer.isWanted, !mcpServer.isRunning, grpc != nil else { return }
        host.restart(named: mcpServer.name, graceful: true) { state in
            logger.info("MCP server restarted after configuration: \(state.name, privacy: .public)")
        }
    }

    /// GarageService's per-launch token from the configuration.
    public var grpcToken: String? {
        configurationValue(GarageXPCConfigurationKey.grpcToken)
    }

    /// GarageService's address from the configuration: its socket wins over host and port.
    public var grpc: GarageMCPRustServer.GRPCTarget? {
        if let socket = configurationValue(GarageXPCConfigurationKey.grpcSocket), !socket.isEmpty {
            return .socket(socket)
        }
        guard let portText = configurationValue(GarageXPCConfigurationKey.grpcPort), let port = Int(portText), port > 0 else {
            return nil
        }
        return .tcp(host: configurationValue(GarageXPCConfigurationKey.grpcHost) ?? "127.0.0.1", port: port)
    }

    // MARK: - GarageMCPServerServiceProtocol

    public func startServer(host: String, port: Int, path: String, options: [String: String], with reply: @escaping (Bool, String?) -> Void) {
        logger.info("startServer requested for \(host, privacy: .public):\(port, privacy: .public)\(path, privacy: .public) (\(options.count, privacy: .public) options)")
        // Merged while no endpoint is wanted, so the merge does not start a server of its own.
        mcpServer.forgetEndpoint()
        mergeConfiguration(options)
        mcpServer.configure(.init(host: host, port: port, path: path))

        self.host.restart(named: mcpServer.name, graceful: true) { state in
            switch state {
            case .running:
                reply(true, "MCP server started on \(host):\(port)\(path)")
            case .failed(let message):
                logger.error("Failed to start MCP server: \(message, privacy: .public)")
                reply(false, "Failed to start MCP server: \(message)")
            default:
                reply(false, "MCP server is \(state.name)")
            }
        }
    }

    public func stopServer(with reply: @escaping (Bool, String?) -> Void) {
        logger.info("stopServer requested")
        // Forgotten first, so a configuration that arrives later does not start it again.
        mcpServer.forgetEndpoint()
        guard mcpServer.isRunning else {
            reply(true, "MCP server was not running")
            return
        }
        host.stopAll(graceful: true) { states in
            if case .failed(let message)? = states[self.mcpServer.name] {
                reply(true, "MCP server stopped with warning: \(message)")
            } else {
                reply(true, "MCP server stopped")
            }
        }
    }

    public func isServerRunning(with reply: @escaping (Bool) -> Void) {
        reply(mcpServer.isRunning)
    }

    public func exchange(_ request: Data, with reply: @escaping (Data?, String?) -> Void) {
        exchangeQueue.async { [weak self] in
            guard let self else {
                reply(nil, "The MCP service is shutting down")
                return
            }
            do {
                reply(try self.currentEndpoint().exchange(request), nil)
            } catch {
                logger.error("MCP exchange failed: \(error.localizedDescription, privacy: .public)")
                reply(nil, error.localizedDescription)
            }
        }
    }

    private func currentEndpoint() throws -> GarageMCPRustEndpoint {
        guard let target = grpc else {
            throw GarageXPCServiceError.notRunning("The app has not told the MCP service where GarageService listens yet")
        }
        let token = configurationValue(GarageXPCConfigurationKey.grpcToken)
        endpointLock.lock()
        defer { endpointLock.unlock() }
        if let endpoint, endpoint.target == target, endpoint.token == token {
            return endpoint
        }
        let made = try GarageMCPRustEndpoint(grpc: target, token: token)
        endpoint = made
        return made
    }
}

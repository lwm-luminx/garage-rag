import Foundation
import Darwin
import OSLog
import ImageEmbedBridge
import LlamaModelLoader
import PythonXPCService
import PythonKit

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag.mcp-server-xpc", category: "GarageMCPServerService")

/// Hosts the Garage MCP server (`garage_rag.mcp_server.server`) as a managed background service so the host
/// can restart it gracefully or immediately.
///
/// All Python access is funnelled through `GaragePythonRuntime.withGIL`.
final class GarageMCPManagedServer: GarageManagedService {
    let name = "mcp-server"

    private let lock = NSLock()
    private var running = false
    private(set) var host: String = "127.0.0.1"
    private(set) var port: Int = 8765
    private(set) var path: String = "/mcp"
    private var options: [String: String] = [:]
    private var autoStart = false

    /// Configures the endpoint / environment used by the next `start()`.
    func configure(host: String, port: Int, path: String, options: [String: String]) {
        lock.lock()
        self.host = host
        self.port = port
        self.path = path
        self.options = options
        self.autoStart = true
        lock.unlock()
    }

    var isRunning: Bool {
        lock.lock()
        let flag = running
        lock.unlock()
        // Prefer the Python side's view when the interpreter is available.
        let pyRunning: Bool? = try? GaragePythonRuntime.shared.withGIL { () -> Bool? in
            guard let mcpModule = try? Python.attemptImport("garage_rag.mcp_server.server") else { return nil }
            return Bool(mcpModule.is_background_server_running())
        }
        return pyRunning ?? flag
    }

    func start() throws {
        lock.lock()
        let shouldStart = autoStart
        let (h, p, pth, opts) = (host, port, path, options)
        lock.unlock()
        guard shouldStart else {
            logger.info("mcp-server not configured yet; waiting for startServer")
            return
        }

        // A PythonError is converted to a string error inside the GIL scope, so the host can report it safely.
        try GaragePythonRuntime.shared.withGILDescribingErrors {
            let os = Python.import("os")
            for (key, value) in opts {
                os.environ[key] = PythonObject(value)
            }
            if let dbURL = opts[GarageXPCConfigurationKey.databaseURL] ?? opts["database_url"] {
                // Normalize database URL to ensure psycopg is used
                os.environ[GarageXPCConfigurationKey.databaseURL] = PythonObject(XPCSitePathSetup.ensurePsycopgDatabaseURL(dbURL))
            }
            let mcpModule = try Python.attemptImport("garage_rag.mcp_server.server")
            let started = try mcpModule.start_background_server.throwing.dynamicallyCall(withKeywordArguments: [
                ("host", h),
                ("port", p),
                ("path", pth)
            ])
            let success = Bool(started) ?? true
            guard success else {
                var reason = "start_background_server returned False"
                if let errorFn = mcpModule.checking.background_server_error, errorFn != Python.None,
                   let detail = String(errorFn()), !detail.isEmpty {
                    reason = detail
                }
                throw GarageXPCServiceError.notRunning(reason)
            }
            lock.lock()
            running = true
            lock.unlock()
            logger.info("Garage MCP server started on \(h, privacy: .public):\(p, privacy: .public)\(pth, privacy: .public)")
            GarageXPCOutputCapture.shared.log(message: "MCP server listening on \(h):\(p)\(pth)")
        }
    }

    func stop(graceful: Bool) throws {
        lock.lock()
        let wasRunning = running
        running = false
        lock.unlock()
        guard wasRunning else { return }

        do {
            try GaragePythonRuntime.shared.withGILDescribingErrors {
                let mcpModule = try Python.attemptImport("garage_rag.mcp_server.server")
                _ = try mcpModule.stop_background_server.throwing.dynamicallyCall(withArguments: [])
            }
            logger.info("Garage MCP server stopped (graceful: \(graceful, privacy: .public))")
        } catch {
            // Mirror the previous behaviour: a failing stop is a warning, the server is considered stopped.
            // The error was already described inside the GIL scope; do not call back into Python here.
            logger.warning("MCP server stopped with warning: \(error.localizedDescription, privacy: .public)")
        }
    }
}

final class GarageMCPServerServiceDelegate: GarageXPCServiceBase, GarageMCPServerServiceProtocol {
    private let mcpServer = GarageMCPManagedServer()

    init() {
        super.init(
            serviceName: "GarageMCPServerService",
            logFileName: "mcp-server-xpc.log",
            requiredPythonModules: ["grpc", "psycopg", "google.protobuf", "typer", "garage_rag"]
        )
    }

    override var exportedInterface: NSXPCInterface {
        NSXPCInterface(with: GarageMCPServerServiceProtocol.self)
    }

    override func additionalSelfTests() -> [GarageXPCSelfTest] {
        [
            GarageXPCStandardSelfTests.serviceModule("garage_rag.mcp_server"),
            GarageXPCStandardSelfTests.serviceModule("garage_rag.mcp_server.server", attributes: ["start_background_server", "stop_background_server", "is_background_server_running", "background_server_error"]),
            GarageXPCStandardSelfTests.sitePackages(modules: ["uvicorn", "starlette", "mcp.server.streamable_http_manager"]),
            LlamaModelLoaderBridge.selfTest(),
            ImageEmbedBridge.selfTest(),
        ]
    }

    /// rag_search / rag_ask load their llama_xpc models on demand over NSXPC, through the
    /// LlamaXPCService endpoint the app hands this process (`setLlamaEndpoint`).
    override func pythonDidBecomeReady(_ environment: GaragePythonEnvironment) {
        LlamaModelLoaderBridge.install()
        ImageEmbedBridge.install()
    }

    override func registerManagedServices(in host: GarageXPCServiceHost) {
        host.register(mcpServer)
    }

    // MARK: - GarageMCPServerServiceProtocol

    func startServer(host: String, port: Int, path: String, options: [String: String], with reply: @escaping (Bool, String?) -> Void) {
        logger.info("startServer requested for \(host, privacy: .public):\(port, privacy: .public)\(path, privacy: .public) (\(options.count, privacy: .public) options)")
        guard ensurePythonReady() else {
            reply(false, "Python initialization error: \(runtime.statusSnapshot().error ?? "unavailable")")
            return
        }
        mergeConfiguration(options)
        mcpServer.configure(host: host, port: port, path: path, options: options)

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

    func stopServer(with reply: @escaping (Bool, String?) -> Void) {
        logger.info("stopServer requested")
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

    func isServerRunning(with reply: @escaping (Bool) -> Void) {
        reply(mcpServer.isRunning)
    }
}

// MARK: - Process Entry Point

let delegate = GarageMCPServerServiceDelegate()
delegate.bootstrap()
delegate.run()

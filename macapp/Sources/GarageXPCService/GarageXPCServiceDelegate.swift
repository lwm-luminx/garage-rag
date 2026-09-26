import Foundation
import Darwin
import OSLog
import LlamaModelLoader
import PythonXPCService
import PythonKit

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag.xpc", category: "GarageXPCService")

/// Hosts the Garage gRPC backend (`garage_rag.service.server`) as a managed background service.
///
/// All Python access is funnelled through `GaragePythonRuntime.withGIL` so the GIL is released whenever
/// Swift is idle, letting the gRPC server's Python worker threads make progress.
final class GarageGRPCManagedServer: GarageManagedService {
    let name = "grpc-server"

    private let lock = NSLock()
    private var server: PythonObject?
    private var stopEvent: PythonObject?
    private(set) var host: String = "127.0.0.1"
    private(set) var port: Int = 50051
    private var options: [String: String] = [:]
    private var autoStart = false

    /// Configures the endpoint / environment used by the next `start()`.
    func configure(host: String, port: Int, options: [String: String]) {
        lock.lock()
        self.host = host
        self.port = port
        self.options = options
        self.autoStart = true
        lock.unlock()
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return server != nil
    }

    func start() throws {
        lock.lock()
        let shouldStart = autoStart
        let (h, p, opts) = (host, port, options)
        lock.unlock()
        guard shouldStart else {
            logger.info("grpc-server not configured yet; waiting for startServer")
            return
        }

        // A PythonError is converted to a string error inside the GIL scope, so the host can report it safely.
        try GaragePythonRuntime.shared.withGILDescribingErrors {
            let os = Python.import("os")
            for (key, value) in opts {
                if key == GarageXPCConfigurationKey.databaseURL || key == "database_url" {
                    os.environ[GarageXPCConfigurationKey.databaseURL] = PythonObject(XPCSitePathSetup.ensurePsycopgDatabaseURL(value))
                } else if key == GarageXPCConfigurationKey.workingDirectory {
                    try FileManager.default.createDirectory(atPath: value, withIntermediateDirectories: true)
                    os.chdir(PythonObject(value))
                } else {
                    os.environ[key] = PythonObject(value)
                }
            }
            if opts[GarageXPCConfigurationKey.workingDirectory] != nil {
                // Settings cached under the previous directory would miss its garage.json.
                let config = try Python.attemptImport("garage_rag.config")
                _ = config.reset_settings()
            }

            lock.lock()
            let existing = server
            let existingEvent = stopEvent
            server = nil
            stopEvent = nil
            lock.unlock()
            if let existing = existing {
                logger.info("Stopping previous gRPC server before restart")
                _ = existingEvent?.set()
                _ = existing.stop(grace: 1.0)
            }

            let threading = Python.import("threading")
            let event = threading.Event()
            let serverModule = try Python.attemptImport("garage_rag.service.server")
            let created = try serverModule.create_grpc_server.throwing.dynamicallyCall(withKeywordArguments: [
                ("host", h),
                ("port", p),
                ("stop_event", event)
            ])
            let instance = created[0]
            _ = try instance.start.throwing.dynamicallyCall(withArguments: [])

            lock.lock()
            server = instance
            stopEvent = event
            lock.unlock()
            logger.info("Garage gRPC server started on \(h, privacy: .public):\(p, privacy: .public)")
            GarageXPCOutputCapture.shared.log(message: "gRPC server listening on \(h):\(p)")
        }
    }

    func stop(graceful: Bool) throws {
        guard isRunning else { return }
        // PythonObject references are created and released strictly inside the GIL scope.
        try GaragePythonRuntime.shared.withGIL {
            lock.lock()
            let instance = server
            let event = stopEvent
            server = nil
            stopEvent = nil
            lock.unlock()
            guard let instance = instance else { return }

            _ = event?.set()
            let grace: Double = graceful ? 5.0 : 0.0
            let stopping = instance.stop(grace: grace)
            if graceful {
                // grpc.Server.stop returns a threading.Event that is set once all RPCs completed.
                _ = stopping.wait(timeout: grace + 1.0)
            }
        }
        logger.info("Garage gRPC server stopped (graceful: \(graceful, privacy: .public))")
    }
}

final class GarageXPCServiceDelegate: GarageXPCServiceBase, GarageXPCServiceProtocol {
    private let grpcServer = GarageGRPCManagedServer()

    init() {
        super.init(
            serviceName: "GarageXPCService",
            logFileName: "garage-xpc.log",
            requiredPythonModules: ["grpc", "psycopg", "google.protobuf", "garage_rag"]
        )
    }

    override var exportedInterface: NSXPCInterface {
        NSXPCInterface(with: GarageXPCServiceProtocol.self)
    }

    override func additionalSelfTests() -> [GarageXPCSelfTest] {
        [
            GarageXPCStandardSelfTests.serviceModule("garage_rag.service"),
            GarageXPCStandardSelfTests.serviceModule("garage_rag.service.server", attributes: ["create_grpc_server"]),
            LlamaModelLoaderBridge.selfTest(),
        ]
    }

    /// Search, Backfill and EnrichFacts run here; their llama_xpc models load on demand over
    /// NSXPC, through the LlamaXPCService endpoint the app hands this process
    /// (`setLlamaEndpoint`). `EnsureLlamaModel` (the stdio launchers' way in) uses the same loader.
    override func pythonDidBecomeReady(_ environment: GaragePythonEnvironment) {
        LlamaModelLoaderBridge.install()
    }

    override func registerManagedServices(in host: GarageXPCServiceHost) {
        host.register(grpcServer)
    }

    // MARK: - GarageXPCServiceProtocol

    func startServer(host: String, port: Int, options: [String: String], with reply: @escaping (Bool, String?) -> Void) {
        logger.info("startServer requested for \(host, privacy: .public):\(port, privacy: .public) (\(options.count, privacy: .public) options)")
        guard ensurePythonReady() else {
            let message = runtime.statusSnapshot().error ?? "Python runtime unavailable"
            reply(false, "Python initialization error: \(message)")
            return
        }
        var merged = options
        merged[GarageXPCConfigurationKey.grpcHost] = host
        merged[GarageXPCConfigurationKey.grpcPort] = String(port)
        mergeConfiguration(merged)
        grpcServer.configure(host: host, port: port, options: merged)

        self.host.restart(named: grpcServer.name, graceful: true) { state in
            switch state {
            case .running:
                reply(true, "gRPC server started on \(host):\(port)")
            case .failed(let message):
                reply(false, "Failed to start gRPC server: \(message)")
            default:
                reply(false, "gRPC server is \(state.name)")
            }
        }
    }

    func stopServer(with reply: @escaping (Bool, String?) -> Void) {
        logger.info("stopServer requested")
        guard grpcServer.isRunning else {
            reply(true, "gRPC server was not running")
            return
        }
        host.stopAll(graceful: true) { states in
            if case .failed(let message)? = states[self.grpcServer.name] {
                reply(false, message)
            } else {
                reply(true, "gRPC server stopped")
            }
        }
    }

    func isServerRunning(with reply: @escaping (Bool) -> Void) {
        reply(grpcServer.isRunning)
    }
}

/// A new GarageXPCService delegate. `main.swift` runs it as the XPC service; the sandboxed app hosts one in its own
/// process (`GarageInProcessServices`), where the folders the user granted are readable.
public func makeGarageXPCServiceDelegate() -> GarageXPCServiceBase {
    GarageXPCServiceDelegate()
}

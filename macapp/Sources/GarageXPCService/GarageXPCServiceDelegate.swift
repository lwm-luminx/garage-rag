import Foundation
import Darwin
import GarageXPCKit
import ImageEmbedBridgeCore
import LlamaModelLoaderCore
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag.xpc", category: "GarageXPCService")

/// Hosts GarageService (`rust/garage-service`, `GarageRustService`) as a managed background service,
/// so the host can restart it gracefully or immediately. It links no Python.
final class GarageRustManagedServer: GarageManagedService, @unchecked Sendable {
    let name = "grpc-server"

    private let lock = NSLock()
    private var server: GarageRustService?
    private var endpoint: GarageRustService.Endpoint?
    private var options: [String: String] = [:]

    /// Sets the endpoint and the options the next `start()` uses.
    func configure(endpoint: GarageRustService.Endpoint, options: [String: String]) {
        lock.lock()
        self.endpoint = endpoint
        self.options = options
        lock.unlock()
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
        let opts = options
        lock.unlock()
        guard let wanted else {
            logger.info("grpc-server not configured yet; waiting for startServer")
            return
        }

        // The app's working directory, as when the app ran the `garage` CLI there: the service runs
        // on its garage.json, and McpInstall's project target writes beside it.
        var configPath: String?
        if let directory = opts[GarageXPCConfigurationKey.workingDirectory], !directory.isEmpty {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            FileManager.default.changeCurrentDirectoryPath(directory)
            configPath = (directory as NSString).appendingPathComponent("garage.json")
        }
        let sqlDir = opts["GARAGE_SQL_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? GarageRustService.bundledSchemaDirectory()

        let started = try GarageRustService.start(
            endpoint: wanted,
            token: opts[GarageXPCConfigurationKey.grpcToken],
            configPath: configPath,
            sqlDir: sqlDir
        )
        lock.lock()
        let previous = server
        server = started
        lock.unlock()
        previous?.stop(graceSeconds: 1)
        logger.info("Garage gRPC server started on \(started.endpoint, privacy: .public)")
        GarageXPCOutputCapture.shared.log(message: "gRPC server listening on \(started.endpoint)")
    }

    func stop(graceful: Bool) throws {
        lock.lock()
        let running = server
        server = nil
        lock.unlock()
        guard let running else { return }
        running.stop(graceSeconds: graceful ? 5 : 0)
        logger.info("Garage gRPC server stopped (graceful: \(graceful, privacy: .public))")
    }
}

/// The backend helper: GarageService in Rust, linked statically, answering the app, the ingest and
/// embed workers and the MCP server over gRPC. Search, Backfill, EnrichFacts and ClusterFacts run
/// here; their llama_xpc models load on demand over NSXPC, through the LlamaXPCService endpoint the
/// app hands this process (`setLlamaEndpoint`), and `EnsureLlamaModel` (the stdio launchers' way
/// in) uses the same loader. Image models are reached through the GarageImageEmbedXPCService
/// endpoint the app hands over too.
///
/// The sandboxed (App Store) app hosts it in its own process (`InProcessServiceHost`), because Scan,
/// AddSource and McpInstall read folders only the app can read.
final class GarageXPCServiceDelegate: GarageXPCServiceBase, GarageXPCServiceProtocol {
    private let grpcServer = GarageRustManagedServer()

    /// The variables the service's modules read, as the Python server read them from its
    /// environment: the database URL (the configuration), the model catalog, the `garage-mcp` the MCP
    /// registrations name, LM Studio's token and a `--data-directory` launch's models folder.
    private static let environmentKeys: [String] = [
        GarageXPCConfigurationKey.databaseURL,
        "GARAGE_MODEL_MANIFEST",
        "GARAGE_MCP_EXECUTABLE",
        "GARAGE_LMSTUDIO_API_TOKEN",
        GarageXPCConfigurationKey.modelsDirectory,
        "GARAGE_SQL_DIR",
    ]

    init() {
        super.init(serviceName: "GarageXPCService", logFileName: "garage-xpc.log")
    }

    override var exportedInterface: NSXPCInterface {
        NSXPCInterface(with: GarageXPCServiceProtocol.self)
    }

    override func additionalSelfTests() -> [GarageXPCSelfTest] {
        [
            GarageXPCSelfTest(
                name: "gRPC Server",
                description: "GarageService is linked into this process and binds a loopback port, then stops.",
                requiresPython: false
            ) {
                let scratch = FileManager.default.temporaryDirectory
                    .appendingPathComponent("garage-xpc-self-test-\(getpid())", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: scratch) }
                do {
                    let server = try GarageRustService.start(
                        endpoint: .tcp(host: "127.0.0.1", port: 0),
                        token: "self-test",
                        configPath: scratch.appendingPathComponent("garage.json").path,
                        sqlDir: GarageRustService.bundledSchemaDirectory()
                    )
                    defer { server.stop(graceSeconds: 0) }
                    guard server.isRunning else {
                        throw GarageXPCSelfTestFailure("GarageService stopped as soon as it started")
                    }
                    return "GarageService \(GarageRustService.version) listened on \(server.endpoint)"
                } catch let failure as GarageXPCSelfTestFailure {
                    throw failure
                } catch {
                    throw GarageXPCSelfTestFailure("GarageService did not start", details: error.localizedDescription)
                }
            },
            GarageXPCSelfTest(
                name: "Database Connection",
                description: "GarageService reaches the Postgres cluster the app configured (GARAGE_DATABASE_URL) and reads its version.",
                requiresPython: false
            ) { [weak self] in
                guard let self, let url = self.configurationValue(GarageXPCConfigurationKey.databaseURL), !url.isEmpty else {
                    throw GarageXPCSelfTestSkipped("GARAGE_DATABASE_URL is not configured")
                }
                // The probe reads the URL from the environment the configuration set (didMergeConfiguration).
                let configPath = self.configurationValue(GarageXPCConfigurationKey.workingDirectory)
                    .flatMap { $0.isEmpty ? nil : ($0 as NSString).appendingPathComponent("garage.json") }
                do {
                    let probed = try GarageRustService.probe(configPath: configPath)
                    return "Server: \(probed.database)\nDatabase: \(probed.databaseURL)"
                } catch {
                    throw GarageXPCSelfTestFailure("The database did not answer", details: error.localizedDescription)
                }
            },
            LlamaEndpointSelfTest.make(),
            ImageEmbedAccess.selfTest(),
        ]
    }

    override func registerManagedServices(in host: GarageXPCServiceHost) {
        host.register(grpcServer)
    }

    /// The service's modules read these from the environment, so they are set as they arrive (the
    /// Python server's `os.environ`), before a server starts on them.
    override func didMergeConfiguration(_ options: [String: String]) {
        for key in Self.environmentKeys {
            if let value = options[key], !value.isEmpty {
                setenv(key, value, 1)
            }
        }
    }

    // MARK: - GarageXPCServiceProtocol

    func startServer(host: String, port: Int, options: [String: String], with reply: @escaping (Bool, String?) -> Void) {
        logger.info("startServer requested for \(host, privacy: .public):\(port, privacy: .public) (\(options.count, privacy: .public) options)")
        var merged = options
        merged[GarageXPCConfigurationKey.grpcHost] = host
        merged[GarageXPCConfigurationKey.grpcPort] = String(port)
        mergeConfiguration(merged)
        // The app names a Unix-domain socket in its App Group container (`GarageSockets`); the server
        // then listens there instead of on host:port.
        let endpoint: GarageRustService.Endpoint
        if let socket = merged[GarageXPCConfigurationKey.grpcSocket], !socket.isEmpty {
            endpoint = .socket(socket)
        } else {
            endpoint = .tcp(host: host, port: port)
        }
        grpcServer.configure(endpoint: endpoint, options: merged)

        self.host.restart(named: grpcServer.name, graceful: true) { state in
            switch state {
            case .running:
                reply(true, "gRPC server started on \(endpoint.description)")
            case .failed(let message):
                logger.error("Failed to start gRPC server: \(message, privacy: .public)")
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

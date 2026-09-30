import Foundation

/// Objective-C protocol for bidirectional / client-side log and output streaming from XPC services.
@objc(GarageXPCLogReceiverProtocol)
public protocol GarageXPCLogReceiverProtocol: NSObjectProtocol {
    /// Receive streaming stdout output chunk.
    func didReceiveStdout(_ text: String)
    /// Receive streaming stderr output chunk.
    func didReceiveStderr(_ text: String)
    /// Receive structured log entry.
    func didReceiveLog(source: String, level: String, message: String, timestamp: Double)
}

/// Common Objective-C protocol that all Garage XPC services inherit.
/// Provides standardized ping, service information, configuration, self tests and stdout/stderr log retrieval.
@objc(GarageCommonXPCServiceProtocol)
public protocol GarageCommonXPCServiceProtocol: NSObjectProtocol {
    /// Health check / ping returning service identifier and status message.
    func ping(with reply: @escaping (String) -> Void)

    /// Health check returning structured status (service name, PID, uptime/timestamp, extra status string).
    func getServiceInfo(with reply: @escaping (String, Int32, Double, String?) -> Void)

    /// Updates runtime configuration used by the service and its self tests (for example `GARAGE_DATABASE_URL`,
    /// `GARAGE_GRPC_HOST`, `GARAGE_GRPC_PORT`, `GARAGE_GRPC_SOCKET`). Keys are merged into the existing configuration.
    func updateConfiguration(_ options: [String: String], with reply: @escaping (Bool, String?) -> Void)

    /// Runs a service diagnostic check returning success status, summary, and details.
    func runDiagnostic(with reply: @escaping (Bool, String?, String?) -> Void)

    /// Returns a JSON encoded `GarageXPCStatusReport` describing lifecycle state, Python runtime state,
    /// last self-test results and recent diagnostic log lines.
    func getServiceStatus(with reply: @escaping (String) -> Void)

    /// Re-runs the service self-test suite (Python runtime, stdlib extension modules, site-packages, database, gRPC, ...)
    /// and replies with overall success and a JSON encoded `GarageXPCStatusReport`.
    func runSelfTests(with reply: @escaping (Bool, String) -> Void)

    /// Restarts the managed background services of this XPC helper. `graceful` waits for in-flight work to drain
    /// before restarting; a non-graceful restart tears services down immediately.
    func restartServices(graceful: Bool, with reply: @escaping (Bool, String?) -> Void)

    /// Fetch buffered stdout and stderr strings since last fetch or since service startup.
    func fetchLogs(with reply: @escaping (String?, String?) -> Void)

    /// Fetch buffered stdout and stderr with option to clear buffer.
    func fetchBufferedOutput(clearBuffer: Bool, with reply: @escaping (String?, String?, Error?) -> Void)

    /// Clear in-memory log and output buffers.
    func clearLogs(with reply: @escaping (Bool) -> Void)

    /// Opts the calling connection in to live log streaming. The service only pushes `GarageXPCLogReceiverProtocol`
    /// messages over connections that subscribed, so clients that did not export a receiver never get unsolicited
    /// messages (which NSXPC treats as undecodable and answers by invalidating the connection).
    func subscribeToLogStream(with reply: @escaping (Bool) -> Void)
}

/// Objective-C protocol for MCP Server XPC Service communication. It receives the LlamaXPCService
/// endpoint because rag_search / rag_ask load llama_xpc models on demand, and the
/// GarageImageEmbedXPCService endpoint because rag_search embeds a query for an image model there.
@objc(GarageMCPServerServiceProtocol)
public protocol GarageMCPServerServiceProtocol: GarageCommonXPCServiceProtocol, GarageLlamaEndpointReceiverProtocol, GarageImageEmbedEndpointReceiverProtocol {
    func startServer(host: String, port: Int, path: String, options: [String: String], with reply: @escaping (Bool, String?) -> Void)
    func stopServer(with reply: @escaping (Bool, String?) -> Void)
    func isServerRunning(with reply: @escaping (Bool) -> Void)
}

/// Objective-C protocol for Garage Core Backend XPC Service communication. It receives the
/// LlamaXPCService endpoint because Search, Backfill and EnrichFacts load llama_xpc models on demand,
/// and the GarageImageEmbedXPCService endpoint because Search and Backfill embed with image models there.
@objc(GarageXPCServiceProtocol)
public protocol GarageXPCServiceProtocol: GarageCommonXPCServiceProtocol, GarageLlamaEndpointReceiverProtocol, GarageImageEmbedEndpointReceiverProtocol, GarageFolderAccessReceiverProtocol {
    func startServer(host: String, port: Int, options: [String: String], with reply: @escaping (Bool, String?) -> Void)
    func stopServer(with reply: @escaping (Bool, String?) -> Void)
    func isServerRunning(with reply: @escaping (Bool) -> Void)
}

// MARK: - Status / self-test report models (JSON over XPC)

/// Outcome of a single self test executed inside an XPC service.
public struct GarageXPCTestResult: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case passed
        case failed
        case skipped
    }

    public var name: String
    public var testDescription: String
    public var status: Status
    public var durationMs: Double
    public var summary: String
    public var details: String
    public var errorMessage: String?
    public var timestamp: Double

    public init(
        name: String,
        testDescription: String,
        status: Status,
        durationMs: Double,
        summary: String,
        details: String = "",
        errorMessage: String? = nil,
        timestamp: Double = Date().timeIntervalSince1970
    ) {
        self.name = name
        self.testDescription = testDescription
        self.status = status
        self.durationMs = durationMs
        self.summary = summary
        self.details = details
        self.errorMessage = errorMessage
        self.timestamp = timestamp
    }

    public var passed: Bool { status != .failed }
}

/// Snapshot of the Python runtime embedded in an XPC service.
public struct GarageXPCPythonStatus: Codable, Equatable, Sendable {
    /// One of `notStarted`, `starting`, `ready`, `failed`.
    public var state: String
    public var version: String?
    public var home: String?
    public var stdlibDir: String?
    public var libDynloadDir: String?
    public var sitePackagesDir: String?
    public var sysPath: [String]
    public var error: String?
    public var initializationMs: Double?
    /// Bundled `libpq.dylib` loaded into the process for psycopg (nil when none was found).
    public var libpqPath: String?
    /// `dlopen` failure for the bundled libpq, if any.
    public var libpqError: String?

    public init(
        state: String,
        version: String? = nil,
        home: String? = nil,
        stdlibDir: String? = nil,
        libDynloadDir: String? = nil,
        sitePackagesDir: String? = nil,
        sysPath: [String] = [],
        error: String? = nil,
        initializationMs: Double? = nil,
        libpqPath: String? = nil,
        libpqError: String? = nil
    ) {
        self.state = state
        self.version = version
        self.home = home
        self.stdlibDir = stdlibDir
        self.libDynloadDir = libDynloadDir
        self.sitePackagesDir = sitePackagesDir
        self.sysPath = sysPath
        self.error = error
        self.initializationMs = initializationMs
        self.libpqPath = libpqPath
        self.libpqError = libpqError
    }
}

/// Snapshot of a background service managed inside an XPC helper.
public struct GarageXPCManagedServiceStatus: Codable, Equatable, Sendable {
    public var name: String
    /// One of `stopped`, `starting`, `running`, `stopping`, `restarting`, `failed`.
    public var state: String
    public var detail: String?
    public var startedAt: Double?
    public var restartCount: Int

    public init(name: String, state: String, detail: String? = nil, startedAt: Double? = nil, restartCount: Int = 0) {
        self.name = name
        self.state = state
        self.detail = detail
        self.startedAt = startedAt
        self.restartCount = restartCount
    }
}

/// Full status report returned by `getServiceStatus` / `runSelfTests`.
public struct GarageXPCStatusReport: Codable, Equatable, Sendable {
    public var serviceName: String
    public var bundleIdentifier: String
    public var pid: Int32
    public var uptimeSeconds: Double
    /// Overall lifecycle: `bootstrapping`, `ready`, `degraded`, `failed`.
    public var lifecycle: String
    public var logFilePath: String?
    public var python: GarageXPCPythonStatus
    public var services: [GarageXPCManagedServiceStatus]
    public var tests: [GarageXPCTestResult]
    public var lastTestRun: Double?
    /// Recent stderr / error log lines to help diagnose failures.
    public var recentErrorLines: [String]
    public var lastCrashReport: String?

    public init(
        serviceName: String,
        bundleIdentifier: String,
        pid: Int32,
        uptimeSeconds: Double,
        lifecycle: String,
        logFilePath: String? = nil,
        python: GarageXPCPythonStatus,
        services: [GarageXPCManagedServiceStatus] = [],
        tests: [GarageXPCTestResult] = [],
        lastTestRun: Double? = nil,
        recentErrorLines: [String] = [],
        lastCrashReport: String? = nil
    ) {
        self.serviceName = serviceName
        self.bundleIdentifier = bundleIdentifier
        self.pid = pid
        self.uptimeSeconds = uptimeSeconds
        self.lifecycle = lifecycle
        self.logFilePath = logFilePath
        self.python = python
        self.services = services
        self.tests = tests
        self.lastTestRun = lastTestRun
        self.recentErrorLines = recentErrorLines
        self.lastCrashReport = lastCrashReport
    }

    public var allTestsPassed: Bool { tests.allSatisfy { $0.passed } }
    public var failedTests: [GarageXPCTestResult] { tests.filter { $0.status == .failed } }

    public func jsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    public static func decode(fromJSON json: String) -> GarageXPCStatusReport? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GarageXPCStatusReport.self, from: data)
    }
}

/// Well-known configuration keys accepted by `updateConfiguration`.
public enum GarageXPCConfigurationKey {
    public static let databaseURL = "GARAGE_DATABASE_URL"
    public static let grpcHost = "GARAGE_GRPC_HOST"
    public static let grpcPort = "GARAGE_GRPC_PORT"
    /// The app's per-launch token for the gRPC server (`x-garage-token`, `garage_rag.service.auth`).
    /// A secret: never log it or write it to garage.json.
    public static let grpcToken = "GARAGE_GRPC_TOKEN"
    /// The Unix-domain socket the gRPC server listens on (`GarageSockets`); wins over host and port.
    public static let grpcSocket = "GARAGE_GRPC_SOCKET"
    public static let logLevel = "GARAGE_LOG_LEVEL"
    /// Directory the Python server works in, and so where it finds `./garage.json`: the
    /// app's working directory, as when the app ran the `garage` CLI there.
    public static let workingDirectory = "GARAGE_WORKING_DIRECTORY"
    /// The models folder of a `--data-directory` launch (a UI test's), which an XPC service cannot
    /// learn from the app's arguments. Unset otherwise; `GarageAppGroup.modelsDirectory` reads it.
    public static let modelsDirectory = "GARAGE_MODELS_DIR"
}

public enum GarageMCPConstants {
    public static let serviceName = "me.rickmark.garage-rag.mcp-server-xpc"
}

public enum GarageXPCConstants {
    public static let serviceName = "me.rickmark.garage-rag.xpc"
}


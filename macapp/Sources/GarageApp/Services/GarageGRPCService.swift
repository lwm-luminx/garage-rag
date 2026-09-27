import Foundation
import GRPC
import NIO
import SwiftProtobuf
import IngestClient
import PythonXPCService
import proto_garage_proto_swift

public enum GarageGRPCStatus: Equatable {
    case stopped
    case starting
    case running
    case stopping
    case failed(String)
}

public enum GarageGRPCError: LocalizedError {
    case databaseNotOnline
    case cliNotFound
    case startupTimeout
    case launchFailed(String)
    case serverNotRunning
    case searchFailed(String)
    case rpcFailed(String)

    public var errorDescription: String? {
        switch self {
        case .databaseNotOnline:
            return "Database is not online. gRPC server requires an online database."
        case .cliNotFound:
            return "garage CLI not found at \(Paths.garageCLI.path)"
        case .startupTimeout:
            return "Timed out waiting for gRPC server to start."
        case .launchFailed(let message):
            return "Failed to launch garage server: \(message)"
        case .serverNotRunning:
            return "gRPC server is not running."
        case .searchFailed(let message):
            return "Search request failed: \(message)"
        case .rpcFailed(let message):
            return message
        }
    }
}

@MainActor
final class GarageGRPCService: ObservableObject {
    @Published private(set) var logs: [LogLine] = []
    @Published private(set) var status: GarageGRPCStatus = .stopped
    @Published var host: String = "127.0.0.1"
    @Published var port: Int = 50051
    /// The Unix-domain socket the server listens on (`GarageSockets`), so that only this account's Garage
    /// processes reach the corpus; nil only when its path is too long to bind, and `host:port` is used.
    let socketPath: String? = GarageSockets.path(for: GarageSockets.grpcName)

    /// Where the server listens, for display: `unix:<path>` or `host:port`.
    var address: String {
        socketPath.map { "unix:\($0)" } ?? "\(host):\(port)"
    }

    /// Where the server listens, in the few words a status line has room for.
    var shortAddress: String {
        socketPath == nil ? "\(host):\(port)" : "a private socket"
    }

    private let postgres: PostgresService
    private let client: GarageXPCClient
    private var group: EventLoopGroup?
    private var channel: GRPCChannel?
    private let maxLogLines = 4000
    private var logPollTask: Task<Void, Never>?

    init(postgres: PostgresService, port: Int = 50051, client: GarageXPCClient = GarageXPCClient()) {
        self.postgres = postgres
        self.port = port
        self.client = client
    }

    deinit {
        logPollTask?.cancel()
        try? group?.syncShutdownGracefully()
    }

    private func appendLog(_ line: LogLine) {
        logs.append(line)
        if logs.count > maxLogLines {
            logs.removeFirst(LogLine.trimCount(count: logs.count, limit: maxLogLines))
        }
    }

    func clearLogs() {
        logs.removeAll()
        Task { [client] in
            _ = try? await client.clearLogs()
        }
    }

    private func environment() throws -> [String: String] {
        var env: [String: String] = [:]
        env["GARAGE_DATABASE_URL"] = try postgres.connectionURL()
        env[GarageXPCConfigurationKey.workingDirectory] = Paths.garageWorkingDirectory.path
        // The server rejects any call without this launch's token (garage_rag.service.auth).
        env[GarageXPCConfigurationKey.grpcToken] = GarageGRPCAuth.token
        if let lmStudioToken = try LMStudioTokenStore.load() {
            env["GARAGE_LMSTUDIO_API_TOKEN"] = lmStudioToken
        }
        // McpInstall / McpStatus name the command MCP clients spawn, `garage-mcp`; without
        // this the server would name its own embedded interpreter, which clients cannot run.
        if FileManager.default.isExecutableFile(atPath: Paths.garageMCP.path) {
            // Not resolved through symlinks: Contents/MacOS/garage-mcp is a link to the forwarder script,
            // and the link is the stable path a client registration must keep.
            env["GARAGE_MCP_EXECUTABLE"] = Paths.garageMCP.standardizedFileURL.path
        }
        // The model catalog RegisterModel reads widths and distance metrics from:
        // the app's own models.json, so the presets and the pipeline agree.
        if FileManager.default.fileExists(atPath: Paths.modelsJSON.path) {
            env["GARAGE_MODEL_MANIFEST"] = Paths.modelsJSON.path
        }
        return env
    }

    /// What every Python helper needs to reach the database and this server: the settings the
    /// backend was started with, plus where it listens. `AppState.startBackend` pushes it to the
    /// ingest, embed and MCP helpers (`XPCServiceManager.configureHelpers`) once the server is up,
    /// so their Database Connection and gRPC Connection self tests check the real thing instead
    /// of being skipped for want of configuration, as they were when the helpers only heard of
    /// the database with their first job.
    func helperConfiguration() throws -> [String: String] {
        var options = try environment()
        options.merge(Self.addressOptions(socketPath: socketPath, host: host, port: port)) { _, new in new }
        return options
    }

    /// The configuration keys that name where the server listens: the socket when there is one,
    /// else host and port (`GarageXPCServiceBase.grpcTarget` reads them in that order).
    nonisolated static func addressOptions(socketPath: String?, host: String, port: Int) -> [String: String] {
        if let socketPath {
            return [GarageXPCConfigurationKey.grpcSocket: socketPath]
        }
        return [GarageXPCConfigurationKey.grpcHost: host, GarageXPCConfigurationKey.grpcPort: String(port)]
    }

    private func startLogPolling() {
        logPollTask?.cancel()
        logPollTask = Task { [weak self, client] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let (stdout, stderr) = try? await client.fetchBufferedOutput(clearBuffer: true) else {
                    continue
                }
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    if let stdout = stdout, !stdout.isEmpty {
                        for line in stdout.split(separator: "\n", omittingEmptySubsequences: false) {
                            let text = String(line)
                            if !text.isEmpty {
                                self.appendLog(LogLine(stream: .stdout, text: text, source: "garage-grpc"))
                            }
                        }
                    }
                    if let stderr = stderr, !stderr.isEmpty {
                        for line in stderr.split(separator: "\n", omittingEmptySubsequences: false) {
                            let text = String(line)
                            if !text.isEmpty {
                                self.appendLog(LogLine(stream: .stderr, text: text, source: "garage-grpc"))
                            }
                        }
                    }
                }
            }
        }
    }

    private func stopLogPolling() {
        logPollTask?.cancel()
        logPollTask = nil
    }

    func start(maxAttempts: Int = 3, readyTimeout: TimeInterval = 10) async throws {
        guard status == .stopped || isFailed else { return }
        guard postgres.status == .running else {
            let errorMsg = "Database is not online. gRPC server requires an online database."
            status = .failed(errorMsg)
            appendLog(LogLine(stream: .stderr, text: errorMsg, source: "garage-grpc"))
            throw GarageGRPCError.databaseNotOnline
        }

        var attemptsLeft = max(1, maxAttempts)
        var triedPorts: Set<Int> = []

        while attemptsLeft > 0 {
            let currentPort = port
            triedPorts.insert(currentPort)
            status = .starting

            do {
                // Reads the token off the main actor the first time, so a Keychain prompt never
                // blocks the window; environment() then gets it from the store's cache.
                try await LMStudioTokenStore.loadOffMainActor()
                var options = try environment()
                if let socketPath {
                    try GarageSockets.ensureDirectory(URL(fileURLWithPath: socketPath).deletingLastPathComponent())
                    options[GarageXPCConfigurationKey.grpcSocket] = socketPath
                }
                let result = try await client.startServer(host: host, port: currentPort, options: options)
                if !result.success {
                    let launchError = GarageGRPCError.launchFailed(result.message ?? "XPC service failed to start gRPC server")
                    status = .failed(launchError.localizedDescription)
                    throw launchError
                }
                startLogPolling()
            } catch let error as GarageGRPCError {
                status = .failed(error.localizedDescription)
                throw error
            } catch {
                let launchError = GarageGRPCError.launchFailed(error.localizedDescription)
                status = .failed(launchError.localizedDescription)
                throw launchError
            }

            let ready = await waitUntilReady(timeout: readyTimeout)
            if ready {
                status = .running
                return
            }

            attemptsLeft -= 1
            _ = try? await client.stopServer()

            if attemptsLeft > 0, let socketPath {
                // A socket cannot be taken by another program the way a port can; just try again.
                appendLog(LogLine(
                    stream: .stderr,
                    text: "Failed to connect to gRPC server on \(socketPath); retrying…",
                    source: "garage-grpc"
                ))
            } else if attemptsLeft > 0 {
                let newPort = Self.randomPort(excluding: triedPorts)
                appendLog(LogLine(
                    stream: .stderr,
                    text: "Failed to connect to gRPC server on port \(currentPort); retrying on port \(newPort)…",
                    source: "garage-grpc"
                ))
                self.port = newPort
            } else {
                status = .failed(GarageGRPCError.startupTimeout.localizedDescription)
                throw GarageGRPCError.startupTimeout
            }
        }
    }

    func stop() async {
        guard status == .running || status == .starting else { return }
        status = .stopping
        stopLogPolling()
        cleanupChannel()
        _ = try? await client.stopServer()
        status = .stopped
    }

    /// Fire-and-forget termination for application quit paths.
    func terminateImmediately() {
        status = .stopping
        stopLogPolling()
        cleanupChannel()
        Task { [client] in
            _ = try? await client.stopServer()
        }
    }

    private func cleanupChannel() {
        if let channel = self.channel as? ClientConnection {
            _ = channel.close()
        }
        self.channel = nil
        try? group?.syncShutdownGracefully()
        group = nil
    }

    private var isFailed: Bool {
        if case .failed = status {
            return true
        }
        return false
    }

    private static func randomPort(excluding: Set<Int>) -> Int {
        var port: Int
        repeat {
            port = Int.random(in: 49152...65535)
        } while excluding.contains(port)
        return port
    }

    func getOrCreateChannel() -> GRPCChannel {
        if let channel = self.channel {
            return channel
        }
        let group = PlatformSupport.makeEventLoopGroup(loopCount: 1)
        self.group = group
        // GetDocument returns every chunk, and a long Messages thread passes grpc-swift's 4 MiB default;
        // match the server's own 256 MiB request limit (MAX_REQUEST_BYTES in service/server.py).
        let maximumReceiveMessageLength = 256 * 1024 * 1024
        let connection: ClientConnection
        if let socketPath {
            var configuration = ClientConnection.Configuration.default(target: .unixDomainSocket(socketPath), eventLoopGroup: group)
            configuration.maximumReceiveMessageLength = maximumReceiveMessageLength
            connection = ClientConnection(configuration: configuration)
        } else {
            connection = ClientConnection.insecure(group: group)
                .withMaximumReceiveMessageLength(maximumReceiveMessageLength)
                .connect(host: host, port: port)
        }
        self.channel = connection
        return connection
    }

    /// Readiness is decided by the helper over XPC (`isServerRunning`, the authoritative view of the managed
    /// Python gRPC server); a ping over the gRPC channel then confirms the socket or port answers. When XPC says
    /// the daemon is up but the probe keeps failing within the timeout, the XPC verdict wins so the status is
    /// not stuck on "starting" because of a slow first channel connect.
    func waitUntilReady(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var xpcReportedRunning = false
        while Date() < deadline {
            if !xpcReportedRunning {
                xpcReportedRunning = (try? await client.isServerRunning()) ?? false
            }
            if xpcReportedRunning, await pingOverChannel() {
                return true
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return xpcReportedRunning
    }

    private func pingOverChannel() async -> Bool {
        do {
            let client = Garage_GarageServiceAsyncClient(channel: getOrCreateChannel(), defaultCallOptions: GarageGRPCAuth.callOptions())
            var pingReq = Garage_PingRequest()
            pingReq.message = "healthcheck"
            let callOptions = GarageGRPCAuth.callOptions(timeLimit: .timeout(.milliseconds(500)))
            let response = try await client.ping(pingReq, callOptions: callOptions)
            return !response.message.isEmpty
        } catch {
            cleanupChannel()
            return false
        }
    }

    /// Re-syncs `status` with the helper's view of the managed gRPC server (used by the status UI).
    func refreshStatus() async {
        guard status == .running || status == .stopped || isFailed else { return }
        let running = (try? await client.isServerRunning()) ?? false
        if running, status != .running {
            status = .running
        } else if !running, status == .running {
            status = .stopped
        }
    }

    func search(
        query: String,
        mode: String = "hybrid",
        model: String? = nil,
        limit: Int = 10,
        corpusClasses: [String] = [],
        trustTiers: [String] = [],
        sources: [String] = [],
        author: String? = nil,
        full: Bool = false
    ) async throws -> Garage_SearchResponse {
        if status != .running {
            try await start()
        }

        let client = Garage_GarageServiceAsyncClient(channel: getOrCreateChannel(), defaultCallOptions: GarageGRPCAuth.callOptions())
        var request = Garage_SearchRequest()
        request.query = query
        request.mode = mode
        if let model = model, !model.isEmpty {
            request.model = model
        }
        request.limit = Int32(limit)
        if !corpusClasses.isEmpty {
            request.corpusClasses = corpusClasses
        }
        if !trustTiers.isEmpty {
            request.trustTiers = trustTiers
        }
        if !sources.isEmpty {
            request.sources = sources
        }
        if let author = author, !author.isEmpty {
            request.author = author
        }
        request.full = full

        let callOptions = GarageGRPCAuth.callOptions(timeLimit: .timeout(.seconds(30)))
        do {
            let response = try await client.search(request, callOptions: callOptions)
            return response
        } catch {
            throw GarageGRPCError.searchFailed(Self.describe(error))
        }
    }

    /// The server's own message for a failed RPC. A `GRPCStatus` has no localized description, so
    /// `localizedDescription` reads "The operation couldn't be completed. (GRPC.GRPCStatus error 1.)"
    /// instead of, say, "no default model registered … run 'garage register-model' first".
    nonisolated static func describe(_ error: Error) -> String {
        if let status = error as? GRPCStatus {
            return status.message ?? "\(status.code)"
        }
        return error.localizedDescription
    }

    func listDocuments(
        source: String? = nil,
        corpusClass: String? = nil,
        trustTier: String? = nil,
        query: String? = nil,
        limit: Int = 200,
        offset: Int = 0
    ) async throws -> Garage_ListDocumentsResponse {
        if status != .running {
            try await start()
        }

        let client = Garage_GarageServiceAsyncClient(channel: getOrCreateChannel(), defaultCallOptions: GarageGRPCAuth.callOptions())
        var request = Garage_ListDocumentsRequest()
        if let source = source, !source.isEmpty {
            request.source = source
        }
        if let corpusClass = corpusClass, !corpusClass.isEmpty {
            request.corpusClass = corpusClass
        }
        if let trustTier = trustTier, !trustTier.isEmpty {
            request.trustTier = trustTier
        }
        if let query = query, !query.isEmpty {
            request.query = query
        }
        request.limit = Int32(limit)
        request.offset = Int32(offset)

        let callOptions = GarageGRPCAuth.callOptions(timeLimit: .timeout(.seconds(30)))
        do {
            return try await client.listDocuments(request, callOptions: callOptions)
        } catch {
            throw GarageGRPCError.searchFailed(Self.describe(error))
        }
    }

    func getDocument(documentID: Int64) async throws -> Garage_GetDocumentResponse {
        if status != .running {
            try await start()
        }

        let client = Garage_GarageServiceAsyncClient(channel: getOrCreateChannel(), defaultCallOptions: GarageGRPCAuth.callOptions())
        var request = Garage_GetDocumentRequest()
        request.documentID = documentID

        let callOptions = GarageGRPCAuth.callOptions(timeLimit: .timeout(.seconds(30)))
        do {
            return try await client.getDocument(request, callOptions: callOptions)
        } catch {
            throw GarageGRPCError.searchFailed(Self.describe(error))
        }
    }

    /// Functional test that performs structured gRPC RPC calls (GetStatus, GetVersion, ListModels, ListSources, GetStats)
    /// to thoroughly verify that the gRPC daemon and all underlying subsystems are operational beyond a simple ping.
    func testServiceQuery() async -> (isSuccess: Bool, summary: String, details: String, durationMs: Double) {
        let startTime = CFAbsoluteTimeGetCurrent()
        var queries: [String] = []
        var errors: [String] = []

        let client = Garage_GarageServiceAsyncClient(channel: getOrCreateChannel(), defaultCallOptions: GarageGRPCAuth.callOptions())
        let callOptions = GarageGRPCAuth.callOptions(timeLimit: .timeout(.seconds(5)))

        // 1. GetStatus
        do {
            let statusRes = try await client.getStatus(Garage_StatusRequest(), callOptions: callOptions)
            queries.append("GetStatus: ready=\(statusRes.isReady), pid=\(statusRes.pid), db=\(statusRes.dbStatus), type=\(statusRes.serverType)")
        } catch {
            errors.append("GetStatus error: \(Self.describe(error))")
        }

        // 2. GetVersion
        do {
            let versionRes = try await client.getVersion(Garage_VersionRequest(), callOptions: callOptions)
            queries.append("GetVersion: version=\(versionRes.version)")
        } catch {
            errors.append("GetVersion error: \(Self.describe(error))")
        }

        // 3. ListModels
        do {
            let modelsRes = try await client.listModels(Garage_ListModelsRequest(), callOptions: callOptions)
            queries.append("ListModels: returned \(modelsRes.models.count) registered model(s)")
        } catch {
            errors.append("ListModels error: \(Self.describe(error))")
        }

        // 4. ListSources
        do {
            let sourcesRes = try await client.listSources(Garage_ListSourcesRequest(), callOptions: callOptions)
            queries.append("ListSources: returned \(sourcesRes.sources.count) configured source(s)")
        } catch {
            errors.append("ListSources error: \(Self.describe(error))")
        }

        // 5. GetStats
        do {
            let statsRes = try await client.getStats(Garage_StatsRequest(), callOptions: callOptions)
            queries.append("GetStats: docs=\(statsRes.documents), chunks=\(statsRes.chunks)")
        } catch {
            errors.append("GetStats error: \(Self.describe(error))")
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
        let isSuccess = errors.isEmpty && !queries.isEmpty

        let summary: String
        if isSuccess {
            summary = "All \(queries.count) gRPC service queries completed successfully in \(String(format: "%.1f", elapsed))ms."
        } else if !queries.isEmpty {
            summary = "Partial success: \(queries.count) queries succeeded, \(errors.count) failed in \(String(format: "%.1f", elapsed))ms."
        } else {
            summary = "gRPC query failed: \(errors.first ?? "Server unreachable")"
        }

        var lines: [String] = []
        lines.append("gRPC Server: \(address) (daemon status: \(status))")
        lines.append("Latency: \(String(format: "%.2f", elapsed)) ms")
        if !queries.isEmpty {
            lines.append("\nSuccessful RPC Queries:")
            for q in queries {
                lines.append("  ✓ \(q)")
            }
        }
        if !errors.isEmpty {
            lines.append("\nRPC Query Errors:")
            for e in errors {
                lines.append("  ✗ \(e)")
            }
        }

        return (isSuccess, summary, lines.joined(separator: "\n"), elapsed)
    }
}

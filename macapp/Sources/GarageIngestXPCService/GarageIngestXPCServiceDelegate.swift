import Foundation
import GarageXPCKit
import IngestClient
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag.ingest-xpc", category: "GarageIngestXPCService")

// MARK: - Active Connection Management

final class GarageIngestActiveConnections: @unchecked Sendable {
    static let shared = GarageIngestActiveConnections()

    private var connections = Set<NSXPCConnection>()
    private let lock = NSLock()
    private var _activeIngestSource: String?

    private init() {}

    var activeIngestSource: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _activeIngestSource
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _activeIngestSource = newValue
        }
    }

    func add(_ connection: NSXPCConnection) {
        lock.lock()
        defer { lock.unlock() }
        connections.insert(connection)
        logger.debug("Active XPC connection added (total: \(self.connections.count, privacy: .public))")
    }

    func remove(_ connection: NSXPCConnection) {
        lock.lock()
        defer { lock.unlock() }
        connections.remove(connection)
        logger.debug("Active XPC connection removed (total: \(self.connections.count, privacy: .public))")
    }

    func sendProgress(jsonString: String) {
        let activeConns: [NSXPCConnection]
        lock.lock()
        activeConns = Array(connections)
        lock.unlock()

        for conn in activeConns {
            guard let receiver = conn.remoteObjectProxyWithErrorHandler({ error in
                logger.debug("Progress forwarding error to PID \(conn.processIdentifier): \(error.localizedDescription, privacy: .public)")
            }) as? GarageIngestProgressReceiverProtocol else {
                continue
            }
            receiver.didUpdateProgress(progressJson: jsonString)
        }
    }

    func sendLog(message: String, level: Int32) {
        let activeConns: [NSXPCConnection]
        lock.lock()
        activeConns = Array(connections)
        lock.unlock()

        for conn in activeConns {
            guard let receiver = conn.remoteObjectProxyWithErrorHandler({ error in
                logger.debug("Log forwarding error to PID \(conn.processIdentifier): \(error.localizedDescription, privacy: .public)")
            }) as? GarageIngestProgressReceiverProtocol else {
                continue
            }
            receiver.didReceiveLog(message: message, level: level)
        }
    }
}

/// The ingest helper: runs the Rust ingest loop (`GarageIngestRunner`, `rust/garage-ingest-ffi` linked
/// statically), which walks each source, reads every file with its own readers and stores it through
/// GarageService at the address and with the per-launch token the app configured. It links no Python.
final class GarageIngestXPCServiceDelegate: GarageXPCServiceBase, GarageIngestXPCServiceProtocol {
    private let engine = IngestEngine.shared
    private static let workerQueue = DispatchQueue(label: "me.rickmark.garage.ingest.worker", qos: .userInitiated)

    /// Set by `cancelIngest`; the Rust loop asks it before each file and between sources.
    private let cancelLock = NSLock()
    private var cancelRequested = false

    private var isCancelRequested: Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return cancelRequested
    }

    private func setCancelRequested(_ value: Bool) {
        cancelLock.lock()
        cancelRequested = value
        cancelLock.unlock()
    }

    init() {
        super.init(serviceName: "GarageIngestXPCService", logFileName: "ingest-xpc.log")
    }

    override var exportedInterface: NSXPCInterface {
        NSXPCInterface(with: GarageIngestXPCServiceProtocol.self)
    }

    override func additionalSelfTests() -> [GarageXPCSelfTest] {
        [
            GarageXPCSelfTest(
                name: "Ingest Library",
                description: "The Rust ingest loop is linked into this process and answers (the walker's default rules).",
                requiresPython: false
            ) {
                switch GarageIngestRunner.libraryCheck() {
                case .success(let summary):
                    return summary
                case .failure(let error):
                    throw GarageXPCSelfTestFailure("The ingest library did not answer", details: error.localizedDescription)
                }
            },
            GarageXPCSelfTest(
                name: "GarageService Address",
                description: "The app has told this service where GarageService listens, which every ingest stores through.",
                requiresPython: false
            ) { [weak self] in
                guard let self, let target = self.facadeTarget(grpcHost: nil, grpcPort: nil) else {
                    throw GarageXPCSelfTestSkipped("GARAGE_GRPC_SOCKET / GARAGE_GRPC_PORT are not configured")
                }
                switch target {
                case .socket(let path):
                    return "Socket: \(path)"
                case .tcp(let host, let port):
                    return "TCP: \(host):\(port)"
                }
            },
        ]
    }

    /// Ingest clients may receive progress updates in addition to the common log stream. Only the connection that
    /// actually requests an ingest is added to the progress fan-out (see `runIngest`): pushing progress at a
    /// connection whose client did not export a receiver makes NSXPC invalidate that connection.
    override func didAcceptConnection(_ connection: NSXPCConnection) {
        let clientPID = connection.processIdentifier
        logger.info("Ingest XPC listener received connection request from PID: \(clientPID), EUID: \(connection.effectiveUserIdentifier), EGID: \(connection.effectiveGroupIdentifier)")
        connection.remoteObjectInterface = NSXPCInterface(with: GarageIngestProgressReceiverProtocol.self)

        let baseInvalidation = connection.invalidationHandler
        connection.invalidationHandler = { [weak connection] in
            logger.info("Ingest XPC connection invalidated for PID: \(clientPID)")
            if let conn = connection {
                GarageIngestActiveConnections.shared.remove(conn)
            }
            baseInvalidation?()
        }
    }

    // MARK: - GarageIngestXPCServiceProtocol

    func setRootVolumeBookmark(_ bookmarkData: Data, with reply: @escaping (Bool, String?) -> Void) {
        logger.info("Setting root volume bookmark (\(bookmarkData.count) bytes)")
        let result = engine.setRootVolumeBookmark(bookmarkData)
        logger.info("Root volume bookmark result: success=\(result.success), message=\(result.message ?? "nil", privacy: .public)")
        reply(result.success, result.message)
    }

    func setSourceBookmark(path: String, bookmarkData: Data, with reply: @escaping (Bool, String?) -> Void) {
        logger.info("Setting source bookmark for path: '\(path, privacy: .public)' (\(bookmarkData.count) bytes)")
        let result = engine.setSourceBookmark(path: path, bookmarkData: bookmarkData)
        logger.info("Source bookmark result for '\(path, privacy: .public)': success=\(result.success), message=\(result.message ?? "nil", privacy: .public)")
        reply(result.success, result.message)
    }

    func revokeAccess(with reply: @escaping (Bool) -> Void) {
        logger.info("Revoking all volume access bookmarks requested")
        engine.revokeAccess()
        reply(true)
    }

    func cancelIngest(with reply: @escaping (Bool) -> Void) {
        logger.info("Cancel ingest requested")
        // The Rust loop stops at its next file or between sources.
        setCancelRequested(true)
        reply(true)
    }

    func testVolumeAccess(requestJson: String, with reply: @escaping (String?, Error?) -> Void) {
        logger.info("Testing volume access, request: \(requestJson, privacy: .public)")
        do {
            let request = try engine.deserialize(VolumeAccessTestRequest.self, from: requestJson)
            let result = engine.testVolumeAccess(request: request)
            let responseJson = engine.serialize(result)
            logger.info("Volume access test completed: accessible=\(result.isAccessible), testedPath=\(result.testedPath, privacy: .public), rootItemsCount=\(result.rootItemsCount), message=\(result.message, privacy: .public)")
            reply(responseJson, nil)
        } catch {
            logger.error("Failed volume access test: \(error.localizedDescription, privacy: .public)")
            reply(nil, error)
        }
    }

    /// Keeps the database URL in the configuration the app pushes. The Rust loop stores everything
    /// through GarageService and reads no database itself, and no model server is reached from here, so
    /// the LM Studio token is not kept.
    private func applyEnvironmentConfig(databaseUrl: String?) -> (Bool, String?) {
        if let dbURL = databaseUrl, !dbURL.isEmpty {
            mergeConfiguration([GarageXPCConfigurationKey.databaseURL: dbURL])
            // The URL carries the Postgres password: log only that it was set.
            logger.info("Configured GARAGE_DATABASE_URL in the ingest service (\(dbURL.count) characters)")
        }
        return (true, "Environment configured successfully")
    }

    func configureEnvironment(databaseUrl: String?, lmStudioApiToken: String?, with reply: @escaping (Bool, String?) -> Void) {
        logger.info("Configuring environment")
        let (success, msg) = applyEnvironmentConfig(databaseUrl: databaseUrl)
        reply(success, msg)
    }

    func setDatabaseURL(_ databaseUrl: String, lmStudioApiToken: String?, with reply: @escaping (Bool, String?) -> Void) {
        logger.info("Setting database URL")
        let (success, msg) = applyEnvironmentConfig(databaseUrl: databaseUrl)
        reply(success, msg)
    }

    /// Runs the Rust ingest loop on the worker queue, keeping the process alive and forwarding progress to
    /// the requesting client. Used by `ingestSource`.
    private func runIngest(
        source: String,
        includeCode: Bool,
        force: Bool,
        limit: Int?,
        grpcHost: String?,
        grpcPort: Int?,
        grpcToken: String?,
        databaseUrl: String?,
        contactNames: [[String]]?,
        successPrefix: String,
        with reply: @escaping (Bool, String?) -> Void
    ) {
        // The requesting connection is the one that exported a progress receiver; capture it on the XPC thread.
        let requester = NSXPCConnection.current()
        if let requester = requester {
            GarageIngestActiveConnections.shared.add(requester)
        }
        Self.workerQueue.async { [self] in
            let startTime = CFAbsoluteTimeGetCurrent()
            logger.info("Starting ingest synchronously on worker queue for source: '\(source, privacy: .public)'")
            GarageIngestActiveConnections.shared.activeIngestSource = source
            defer {
                GarageIngestActiveConnections.shared.activeIngestSource = nil
                if let requester = requester {
                    GarageIngestActiveConnections.shared.remove(requester)
                }
            }
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled, .suddenTerminationDisabled, .automaticTerminationDisabled],
                reason: "Garage document ingestion for \(source)"
            )
            defer {
                ProcessInfo.processInfo.endActivity(activity)
            }

            _ = applyEnvironmentConfig(databaseUrl: databaseUrl)
            if let grpcToken, !grpcToken.isEmpty {
                // A secret, so not logged.
                mergeConfiguration([GarageXPCConfigurationKey.grpcToken: grpcToken])
            }

            // Every ingest stores through GarageService; with no address for it there is nothing to run.
            guard let grpc = facadeTarget(grpcHost: grpcHost, grpcPort: grpcPort) else {
                let errorMsg = "Failed to run ingest for \(source): GarageService's address is not configured"
                logger.error("\(errorMsg, privacy: .public)")
                reply(false, errorMsg)
                return
            }
            let outcome = runRustIngest(
                source: source,
                grpc: grpc,
                token: grpcToken ?? configurationValue(GarageXPCConfigurationKey.grpcToken),
                includeCode: includeCode,
                force: force,
                limit: limit,
                contactNames: contactNames
            )
            let duration = String(format: "%.3f", CFAbsoluteTimeGetCurrent() - startTime)
            switch outcome {
            case .success(let run) where run.error == nil:
                let successMsg = "\(successPrefix) \(source) in \(duration)s"
                logger.info("\(successMsg, privacy: .public)")
                reply(true, successMsg)
            case .success(let run):
                let errorMsg = "Failed to run ingest for \(source) after \(duration)s: \(run.error ?? "")"
                logger.error("\(errorMsg, privacy: .public)")
                reply(false, errorMsg)
            case .failure(let error):
                let errorMsg = "Failed to run ingest for \(source) after \(duration)s: \(error.localizedDescription)"
                logger.error("\(errorMsg, privacy: .public)")
                reply(false, errorMsg)
            }
        }
    }

    /// GarageService's address, as Python's `get_storage_gateway` picks it: the socket the app configured
    /// wins, else the port the request or the configuration names. `nil` when neither names one.
    private func facadeTarget(grpcHost: String?, grpcPort: Int?) -> GarageIngestRunner.GRPCTarget? {
        if let socket = configurationValue(GarageXPCConfigurationKey.grpcSocket), !socket.isEmpty {
            return .socket(socket)
        }
        let configuredPort = configurationValue(GarageXPCConfigurationKey.grpcPort).flatMap(Int.init)
        guard let port = grpcPort ?? configuredPort, port > 0 else {
            return nil
        }
        let host = grpcHost ?? configurationValue(GarageXPCConfigurationKey.grpcHost) ?? "127.0.0.1"
        return .tcp(host: host, port: port)
    }

    /// Runs the ingest through the Rust loop (`GarageIngestRunner`), which reads every file with its own
    /// readers, so no Python runs for it. Called on the worker queue.
    private func runRustIngest(
        source: String,
        grpc: GarageIngestRunner.GRPCTarget,
        token: String?,
        includeCode: Bool,
        force: Bool,
        limit: Int?,
        contactNames: [[String]]?
    ) -> Result<GarageIngestRunner.Outcome, Error> {
        setCancelRequested(false)
        let runner = GarageIngestRunner(
            progress: { event in
                GarageIngestActiveConnections.shared.sendProgress(jsonString: event)
                Self.logProgress(event)
            },
            isCancelled: { [self] in isCancelRequested }
        )
        logger.info("Running the Rust ingest loop for source '\(source, privacy: .public)' (includeCode: \(includeCode), force: \(force), limit: \(String(describing: limit)))")
        return runner.run(
            source: source,
            grpc: grpc,
            token: token,
            includeCode: includeCode,
            force: force,
            limit: limit,
            contactNames: contactNames
        )
    }

    /// Logs a progress event as Python's `_emit_progress` did, to the file log and the clients' log stream.
    private static func logProgress(_ event: String) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(event.utf8))) as? [String: Any] else { return }
        let source = object["source"] as? String ?? ""
        let phase = object["phase"] as? String ?? ""
        let message = object["message"] as? String ?? ""
        let (level, text): (Int32, String)
        switch phase {
        case "error":
            (level, text) = (40, "[\(source)] (error) \(message): \(object["error"] as? String ?? "")")
        case "cancelled":
            (level, text) = (30, "[\(source)] (cancelled) \(message)")
        case "scan", "complete":
            (level, text) = (20, "[\(source)] (\(phase)) \(message)")
        default:
            let percent = (object["progress"] as? Double ?? 0) * 100
            (level, text) = (20, "[\(source)] (\(phase) \(String(format: "%.1f", percent))%) \(message)")
        }
        let levelName = level >= 40 ? "ERROR" : level >= 30 ? "WARN" : "INFO"
        GarageXPCOutputCapture.shared.log(source: "Ingest", level: levelName, message: text)
        GarageIngestActiveConnections.shared.sendLog(message: text, level: level)
    }

    func ingestSource(slug: String, optionsJson: String, with reply: @escaping (Bool, String?) -> Void) {
        // The options carry the database URL and the LM Studio token, so they stay out of the log.
        logger.info("Received ingestSource request for slug: '\(slug, privacy: .public)' (\(optionsJson.utf8.count)-byte options)")
        let options = (try? engine.deserialize(IngestOptions.self, from: optionsJson)) ?? .default

        runIngest(
            source: slug,
            includeCode: options.includeCode,
            force: options.force,
            limit: options.limit,
            grpcHost: options.grpcHost,
            grpcPort: options.grpcPort,
            grpcToken: options.grpcToken,
            databaseUrl: options.databaseUrl,
            contactNames: options.contactNames,
            successPrefix: "Ingestion completed successfully for",
            with: reply
        )
    }
}

/// A new GarageIngestXPCService delegate. `main.swift` runs it as the XPC service; the sandboxed app hosts one in its own
/// process (`GarageInProcessServices`), where the folders the user granted are readable.
public func makeGarageIngestXPCServiceDelegate() -> GarageXPCServiceBase {
    GarageIngestXPCServiceDelegate()
}

import Foundation
import IngestClient
import PythonXPCService
import OSLog
import PythonKit

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag.ingest-xpc", category: "GarageIngestXPCService")

// MARK: - C Callback Definitions and Active Connection Management

private typealias ProgressCFunction = @convention(c) (UnsafePointer<CChar>?) -> Void
private typealias LogCFunction = @convention(c) (Int32, UnsafePointer<CChar>?) -> Void

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

private let globalProgressCallback: ProgressCFunction = { cStr in
    guard let cStr = cStr else { return }
    let jsonString = String(cString: cStr)
    logger.debug("Ingest C progress callback received: \(jsonString, privacy: .public)")
    GarageIngestActiveConnections.shared.sendProgress(jsonString: jsonString)
}

private let globalLogCallback: LogCFunction = { level, cStr in
    guard let cStr = cStr else { return }
    let msg = String(cString: cStr)
    let lvlStr: String
    switch level {
    case 10: lvlStr = "DEBUG"
    case 20: lvlStr = "INFO"
    case 30: lvlStr = "WARN"
    case 40: lvlStr = "ERROR"
    case 50: lvlStr = "FATAL"
    default: lvlStr = "INFO"
    }
    // Single sink: `log` writes the file log, unified logging and the common XPC log stream once; the ingest
    // progress receivers additionally get the structured copy through `sendLog`.
    GarageXPCOutputCapture.shared.log(source: "IngestPython", level: lvlStr, message: msg)
    GarageIngestActiveConnections.shared.sendLog(message: msg, level: level)
}

/// Registers the C progress / log callback function pointers with `garage_rag.ingest`.
/// Must be called with the GIL held (inside `withGIL` / `withPython`). Uses the throwing PythonKit call path so a
/// Python exception surfaces as an error instead of trapping the process (`PythonObject.dynamicallyCall` uses `try!`).
private func registerIngestCallbacks(on ingestModule: PythonObject) throws {
    let cFuncPtr = unsafeBitCast(globalProgressCallback, to: Int.self)
    if let setProgress = ingestModule.checking.set_c_progress_callback, setProgress != Python.None {
        _ = try setProgress.throwing.dynamicallyCall(withArguments: [cFuncPtr])
    }

    let cLogFuncPtr = unsafeBitCast(globalLogCallback, to: Int.self)
    if let setLog = ingestModule.checking.set_c_log_callback, setLog != Python.None {
        _ = try setLog.throwing.dynamicallyCall(withArguments: [cLogFuncPtr])
    }
}

final class GarageIngestXPCServiceDelegate: GarageXPCServiceBase, GarageIngestXPCServiceProtocol {
    private let engine = IngestEngine.shared
    private static let workerQueue = DispatchQueue(label: "me.rickmark.garage.ingest.worker", qos: .userInitiated)

    private let callbackLock = NSLock()
    private var callbacksRegistered = false

    init() {
        super.init(
            serviceName: "GarageIngestXPCService",
            logFileName: "ingest-xpc.log",
            requiredPythonModules: ["grpc", "psycopg", "google.protobuf", "garage_rag"]
        )
    }

    override var exportedInterface: NSXPCInterface {
        NSXPCInterface(with: GarageIngestXPCServiceProtocol.self)
    }

    override func additionalSelfTests() -> [GarageXPCSelfTest] {
        [
            GarageXPCStandardSelfTests.serviceModule("garage_rag.ingest", attributes: ["ingest_xpc", "cancel_ingest", "set_c_progress_callback", "set_c_log_callback"]),
            GarageXPCStandardSelfTests.serviceModule("garage_rag.config", attributes: ["reset_settings"]),
            GarageXPCStandardSelfTests.serviceModule("garage_rag.db.engine", attributes: ["reset_engine"]),
        ]
    }

    /// Registers the C callbacks once the interpreter is up so progress / log forwarding works before the first ingest.
    override func pythonDidBecomeReady(_ environment: GaragePythonEnvironment) {
        callbackLock.lock()
        let already = callbacksRegistered
        callbacksRegistered = true
        callbackLock.unlock()
        guard !already else { return }

        do {
            // Python errors are described (traceback formatted) inside the GIL scope; only the string escapes it.
            try runtime.withGILDescribingErrors {
                let ingestModule = try Python.attemptImport("garage_rag.ingest")
                logger.info("Successfully imported garage_rag.ingest: \(String(describing: ingestModule), privacy: .public)")
                try registerIngestCallbacks(on: ingestModule)
                logger.info("Registered C progress/log callbacks with garage_rag.ingest")
            }
        } catch {
            callbackLock.lock()
            callbacksRegistered = false
            callbackLock.unlock()
            logger.error("Failed to register ingest callbacks: \(error.localizedDescription, privacy: .public)")
        }
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
        guard ensurePythonReady() else {
            logger.warning("Cannot cancel ingest via Python because Python is not initialized: \(self.runtime.statusSnapshot().error ?? "unavailable", privacy: .public)")
            reply(true)
            return
        }
        // Acknowledge right away and deliver the Python-side cancel
        // from a background thread. `withGIL` is not serialized, so this acquires the GIL as soon as the running
        // `ingest_xpc` call yields it (CPython switches between threads every few milliseconds).
        reply(true)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = withPython { () -> Void in
                let ingestModule = try Python.attemptImport("garage_rag.ingest")
                if ingestModule.cancel_ingest != Python.None {
                    _ = try ingestModule.cancel_ingest.throwing.dynamicallyCall(withArguments: [])
                    logger.info("Python cancel_ingest invoked successfully")
                }
            }
            if case .failure(let error) = result {
                logger.error("Failed to invoke Python cancel_ingest: \(error.localizedDescription, privacy: .public)")
            }
        }
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

    /// Applies database / LM Studio settings to the process environment, the base configuration (so the
    /// database self test can use it) and the Python interpreter (`os.environ` + cached settings reset).
    private func applyEnvironmentConfig(databaseUrl: String?, lmStudioApiToken: String?) -> (Bool, String?) {
        var normalizedDB: String?
        if let dbURL = databaseUrl, !dbURL.isEmpty {
            let normalized = XPCSitePathSetup.ensurePsycopgDatabaseURL(dbURL)
            setenv(GarageXPCConfigurationKey.databaseURL, normalized, 1)
            mergeConfiguration([GarageXPCConfigurationKey.databaseURL: normalized])
            normalizedDB = normalized
        }
        var token: String?
        if let lmToken = lmStudioApiToken, !lmToken.isEmpty {
            setenv("GARAGE_LMSTUDIO_API_TOKEN", lmToken, 1)
            token = lmToken
        }

        if (normalizedDB != nil || token != nil), runtime.isReady {
            let result = withPython { () -> Void in
                let os = Python.import("os")
                if let normalized = normalizedDB {
                    os.environ[GarageXPCConfigurationKey.databaseURL] = PythonObject(normalized)
                    if let configModule = try? Python.attemptImport("garage_rag.config") {
                        if configModule.reset_settings != Python.None {
                            _ = configModule.reset_settings()
                        }
                    }
                    if let engineModule = try? Python.attemptImport("garage_rag.db.engine") {
                        if engineModule.reset_engine != Python.None {
                            _ = engineModule.reset_engine()
                        }
                    }
                }
                if let lmToken = token {
                    os.environ["GARAGE_LMSTUDIO_API_TOKEN"] = PythonObject(lmToken)
                }
            }
            if case .failure(let error) = result {
                logger.warning("Environment configuration could not be mirrored into Python: \(error.localizedDescription, privacy: .public)")
            }
        }
        if let normalized = normalizedDB {
            // The URL carries the Postgres password: log only that it was set.
            logger.info("Successfully configured GARAGE_DATABASE_URL in XPC service (\(normalized.count) characters)")
        }
        if token != nil {
            logger.info("Successfully configured GARAGE_LMSTUDIO_API_TOKEN in XPC service")
        }
        return (true, "Environment configured successfully")
    }

    func configureEnvironment(databaseUrl: String?, lmStudioApiToken: String?, with reply: @escaping (Bool, String?) -> Void) {
        logger.info("Configuring environment")
        if !ensurePythonReady() {
            logger.warning("Environment configuration note: Python init: \(self.runtime.statusSnapshot().error ?? "unavailable", privacy: .public)")
        }
        let (success, msg) = applyEnvironmentConfig(databaseUrl: databaseUrl, lmStudioApiToken: lmStudioApiToken)
        reply(success, msg)
    }

    func setDatabaseURL(_ databaseUrl: String, lmStudioApiToken: String?, with reply: @escaping (Bool, String?) -> Void) {
        logger.info("Setting database URL")
        if !ensurePythonReady() {
            logger.warning("setDatabaseURL note: Python init: \(self.runtime.statusSnapshot().error ?? "unavailable", privacy: .public)")
        }
        let (success, msg) = applyEnvironmentConfig(databaseUrl: databaseUrl, lmStudioApiToken: lmStudioApiToken)
        reply(success, msg)
    }

    /// Runs `garage_rag.ingest.ingest_xpc` on the worker queue with the GIL held, keeping the process alive and
    /// forwarding progress to connected clients. Used by `ingestSource`.
    private func runIngest(
        source: String,
        includeCode: Bool,
        force: Bool,
        limit: Int?,
        grpcHost: String?,
        grpcPort: Int?,
        grpcToken: String?,
        databaseUrl: String?,
        lmStudioApiToken: String?,
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

            _ = applyEnvironmentConfig(databaseUrl: databaseUrl, lmStudioApiToken: lmStudioApiToken)
            if let grpcToken, !grpcToken.isEmpty {
                // Mirrored into os.environ, where garage_rag.service.client reads it; a secret, so not logged.
                mergeConfiguration([GarageXPCConfigurationKey.grpcToken: grpcToken])
            }

            let result = withPython { () -> Void in
                logger.info("Importing garage_rag.ingest in Python for source '\(source, privacy: .public)'...")
                let ingestModule = try Python.attemptImport("garage_rag.ingest")

                // Register C callback function pointers with Python
                try registerIngestCallbacks(on: ingestModule)

                let limitObj: PythonObject = limit != nil ? PythonObject(limit!) : Python.None
                let grpcPortObj: PythonObject = grpcPort != nil ? PythonObject(grpcPort!) : Python.None
                let grpcHostObj: PythonObject = grpcHost != nil ? PythonObject(grpcHost!) : Python.None

                logger.info("Invoking Python ingest_xpc synchronously for source '\(source, privacy: .public)' (includeCode: \(includeCode), force: \(force), limit: \(String(describing: limit)), grpcPort: \(String(describing: grpcPort)))")
                _ = try ingestModule.ingest_xpc.throwing.dynamicallyCall(withKeywordArguments: [
                    ("source", source),
                    ("include_code", includeCode),
                    ("limit", limitObj),
                    ("force", force),
                    ("grpc_host", grpcHostObj),
                    ("grpc_port", grpcPortObj)
                ])
            }

            let duration = String(format: "%.3f", CFAbsoluteTimeGetCurrent() - startTime)
            switch result {
            case .success:
                let successMsg = "\(successPrefix) \(source) in \(duration)s"
                logger.info("\(successMsg, privacy: .public)")
                reply(true, successMsg)
            case .failure(let error):
                let errorMsg = "Failed to run ingest for \(source) after \(duration)s: \(error.localizedDescription)"
                logger.error("\(errorMsg, privacy: .public)")
                reply(false, errorMsg)
            }
        }
    }

    func ingestSource(slug: String, optionsJson: String, with reply: @escaping (Bool, String?) -> Void) {
        // The options carry the database URL and the LM Studio token, so they stay out of the log.
        logger.info("Received ingestSource request for slug: '\(slug, privacy: .public)' (\(optionsJson.utf8.count)-byte options)")
        guard ensurePythonReady() else {
            let errorMsg = "Python initialization error: \(runtime.statusSnapshot().error ?? "unavailable")"
            logger.error("\(errorMsg, privacy: .public)")
            reply(false, errorMsg)
            return
        }
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
            lmStudioApiToken: options.lmStudioApiToken,
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

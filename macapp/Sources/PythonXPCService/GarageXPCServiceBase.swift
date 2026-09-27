import Foundation
import Darwin
import OSLog
import PythonKit
import PythonXPCService_protocol

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag", category: "GarageXPCServiceBase")

/// Common implementation shared by every Garage XPC helper.
///
/// Start-up sequence (see `bootstrap()`):
/// 1. crash handlers + stdout/stderr capture (file log in `~/Library/Logs/Garage`, unified logging, XPC streaming),
/// 2. the XPC listener is resumed immediately so `ping` answers even while Python is still loading,
/// 3. on the background host thread: resolve the app bundle, start the isolated Python environment,
/// 4. run the self-test suite (Python runtime, stdlib extensions, site-packages, database, gRPC, service module),
/// 5. register and start managed background services.
///
/// Subclasses override `additionalSelfTests()`, `registerManagedServices(in:)`, `exportedInterface`
/// and implement their service specific protocol methods, wrapping Python calls in
/// `GaragePythonRuntime.shared.withGIL { ... }`.
open class GarageXPCServiceBase: NSObject, NSXPCListenerDelegate, GarageCommonXPCServiceProtocol, GarageLlamaEndpointReceiverProtocol, GarageImageEmbedEndpointReceiverProtocol, GarageFolderAccessReceiverProtocol {
    public enum Lifecycle: String, Sendable {
        case bootstrapping
        case ready
        case degraded
        case failed
    }

    public let serviceName: String
    public let logFileName: String
    public let usesPython: Bool
    /// Third-party modules imported by the "Site Packages" self test.
    public let requiredPythonModules: [String]

    public let runtime: GaragePythonRuntime
    public let host: GarageXPCServiceHost
    private let launchDate = Date()

    private let stateLock = NSLock()
    private var _lifecycle: Lifecycle = .bootstrapping
    private var _configuration: [String: String] = [:]
    private var _lastTestResults: [GarageXPCTestResult] = []
    private var _lastTestRun: Date?
    private var _bootstrapError: String?
    private var _isRunningTests = false
    private var _servicesRegistered = false
    /// The anonymous listener behind `anonymousListenerEndpoint()`, kept for the life of the process.
    private var _anonymousListener: NSXPCListener?

    public init(
        serviceName: String,
        logFileName: String? = nil,
        usesPython: Bool = true,
        requiredPythonModules: [String] = ["grpc", "psycopg", "google.protobuf"],
        runtime: GaragePythonRuntime = .shared
    ) {
        self.serviceName = serviceName
        self.logFileName = logFileName ?? "\(serviceName).log"
        self.usesPython = usesPython
        self.requiredPythonModules = requiredPythonModules
        self.runtime = runtime
        self.host = GarageXPCServiceHost(label: "me.rickmark.garage-rag.\(serviceName).host")
        super.init()
        // Seed configuration from the process environment (launchd passes the app's environment through).
        let env = ProcessInfo.processInfo.environment
        for key in [GarageXPCConfigurationKey.databaseURL, GarageXPCConfigurationKey.grpcHost, GarageXPCConfigurationKey.grpcPort, GarageXPCConfigurationKey.grpcToken, GarageXPCConfigurationKey.grpcSocket, GarageXPCConfigurationKey.logLevel] {
            if let value = env[key], !value.isEmpty {
                _configuration[key] = value
            }
        }
    }

    // MARK: - Subclass hooks

    /// The Objective-C protocol exported to clients. Defaults to the common protocol.
    open var exportedInterface: NSXPCInterface {
        NSXPCInterface(with: GarageCommonXPCServiceProtocol.self)
    }

    /// Additional service-specific self tests appended to the standard suite.
    open func additionalSelfTests() -> [GarageXPCSelfTest] { [] }

    /// Registers long running components with the host. Called once after Python is ready.
    open func registerManagedServices(in host: GarageXPCServiceHost) {}

    /// Called on the host thread once Python is ready (before tests run).
    open func pythonDidBecomeReady(_ environment: GaragePythonEnvironment) {}

    /// Called when a client connection has been accepted (after the interface was configured).
    open func didAcceptConnection(_ connection: NSXPCConnection) {}

    // MARK: - Lifecycle

    public var lifecycle: Lifecycle {
        stateLock.lock(); defer { stateLock.unlock() }
        return _lifecycle
    }

    public var uptime: TimeInterval { Date().timeIntervalSince(launchDate) }

    /// Performs steps 1–5 described in the type documentation and returns immediately; work continues on the
    /// host thread. Call `run()` afterwards (or drive an `NSXPCListener` yourself).
    public func bootstrap() {
        GarageXPCCrashHandler.install(serviceName: serviceName)
        GarageXPCOutputCapture.shared.configure(serviceName: serviceName, logFileName: logFileName)
        GarageXPCOutputCapture.shared.startCapturing()
        if usesPython {
            // Before Python starts, so `os.environ` has it: the llama_xpc provider's socket.
            GarageSockets.exportLlamaSocket()
        }

        let info = ProcessInfo.processInfo
        logger.info("\(self.serviceName, privacy: .public) starting (pid \(info.processIdentifier, privacy: .public), bundle \(Bundle.main.bundleIdentifier ?? "?", privacy: .public), macOS \(info.operatingSystemVersionString, privacy: .public))")
        GarageXPCOutputCapture.shared.log(message: "\(serviceName) starting (pid \(info.processIdentifier)); logs in \(GarageFileLogger.logsDirectoryURL.path)")

        // Folder grants this service saved before a relaunch, ahead of any work that reads user files.
        let restored = GarageFolderAccessStore.shared.restorePersisted()
        if !restored.isEmpty {
            GarageXPCOutputCapture.shared.log(message: "Restored access to \(restored.count) granted folder(s)")
        }

        if let crash = GarageXPCCrashHandler.lastCrashReport(serviceName: serviceName) {
            logger.warning("\(self.serviceName, privacy: .public) found a crash report from a previous run (\(crash.count, privacy: .public) bytes)")
        }

        host.perform { [self] in
            bootstrapOnHostThread()
        }
    }

    /// Starts this service inside the app (`GarageInProcessServices`) rather than as its own process:
    /// the same host-thread start-up as `bootstrap()`, without what belongs to a process of its own
    /// (crash handlers, capturing stdout/stderr, restoring saved folder grants, which the app holds
    /// itself). Returns the endpoint of the listener that serves it, to register.
    public func bootstrapInProcess() -> NSXPCListenerEndpoint {
        logger.info("\(self.serviceName, privacy: .public) starting in the app process (pid \(ProcessInfo.processInfo.processIdentifier, privacy: .public))")
        let endpoint = anonymousListenerEndpoint()
        host.perform { [self] in
            bootstrapOnHostThread()
        }
        return endpoint
    }

    /// Creates the service listener, resumes it and blocks in `dispatchMain()`.
    public func run() -> Never {
        let listener = NSXPCListener.service()
        listener.delegate = self
        GarageXPCPeerRequirement.apply(to: listener, serviceName: serviceName)
        logger.info("\(self.serviceName, privacy: .public): resuming NSXPCListener")
        listener.resume()
        dispatchMain()
    }

    /// The endpoint of an anonymous listener that serves exactly like the service listener: its
    /// connections go through `listener(_:shouldAcceptNewConnection:)`, so they export
    /// `exportedInterface` and this object. The app hands it to sibling XPC services, which cannot
    /// look this service up by name. The listener is made once and lives as long as the process.
    public func anonymousListenerEndpoint() -> NSXPCListenerEndpoint {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let listener = _anonymousListener {
            return listener.endpoint
        }
        let listener = NSXPCListener.anonymous()
        listener.delegate = self
        GarageXPCPeerRequirement.apply(to: listener, serviceName: serviceName)
        listener.resume()
        _anonymousListener = listener
        logger.info("\(self.serviceName, privacy: .public): anonymous NSXPCListener resumed")
        return listener.endpoint
    }

    private func bootstrapOnHostThread() {
        if usesPython {
            ensurePythonReady()
        }
        registerServicesIfNeeded()
        // The self tests run once the managed services have started: some of them check those
        // services (llama's HTTP listener), which would otherwise always fail at launch.
        host.startAll { [self] states in
            let failed = states.filter { if case .failed = $0.value { return true } else { return false } }
            if !failed.isEmpty {
                GarageXPCOutputCapture.shared.log(level: "ERROR", message: "\(failed.count) managed service(s) failed to start: \(failed.keys.sorted().joined(separator: ", "))")
            }
            let results = performSelfTests()
            let failures = results.filter { $0.status == .failed }
            if failures.isEmpty {
                GarageXPCOutputCapture.shared.log(message: "\(serviceName) self tests passed (\(results.count) tests)")
            } else {
                GarageXPCOutputCapture.shared.log(level: "ERROR", message: "\(serviceName) self tests: \(failures.count) failed - \(failures.map { "\($0.name): \($0.summary)" }.joined(separator: "; "))")
            }
            recomputeLifecycle()
        }
        recomputeLifecycle()
    }

    /// Initializes Python if needed (idempotent). Safe to call from any thread.
    @discardableResult
    public func ensurePythonReady() -> Bool {
        guard usesPython else { return true }
        switch runtime.initializeIfNeeded() {
        case .success(let env):
            stateLock.lock()
            _bootstrapError = nil
            stateLock.unlock()
            pythonDidBecomeReady(env)
            return true
        case .failure(let error):
            let message = error.localizedDescription
            stateLock.lock()
            _bootstrapError = message
            stateLock.unlock()
            GarageXPCOutputCapture.shared.log(level: "ERROR", message: "Python initialization failed: \(message)")
            return false
        }
    }

    private func registerServicesIfNeeded() {
        stateLock.lock()
        let already = _servicesRegistered
        _servicesRegistered = true
        stateLock.unlock()
        if !already {
            registerManagedServices(in: host)
        }
    }

    private func recomputeLifecycle() {
        stateLock.lock()
        let tests = _lastTestResults
        let bootstrapError = _bootstrapError
        stateLock.unlock()

        let newLifecycle: Lifecycle
        if usesPython && !runtime.isReady {
            newLifecycle = .failed
        } else if bootstrapError != nil {
            newLifecycle = .failed
        } else if tests.contains(where: { $0.status == .failed }) || host.hasFailures {
            newLifecycle = .degraded
        } else {
            newLifecycle = .ready
        }
        stateLock.lock()
        _lifecycle = newLifecycle
        stateLock.unlock()
        logger.info("\(self.serviceName, privacy: .public) lifecycle -> \(newLifecycle.rawValue, privacy: .public)")
    }

    // MARK: - Configuration

    public var configuration: [String: String] {
        stateLock.lock(); defer { stateLock.unlock() }
        return _configuration
    }

    public func configurationValue(_ key: String) -> String? {
        stateLock.lock(); defer { stateLock.unlock() }
        return _configuration[key]
    }

    public var databaseURL: String? {
        configurationValue(GarageXPCConfigurationKey.databaseURL).map { XPCSitePathSetup.ensurePsycopgDatabaseURL($0) }
    }

    /// The gRPC server's address as grpc names it: `unix:<path>` when a socket is configured, else `host:port`.
    public var grpcTarget: String? {
        if let socket = configurationValue(GarageXPCConfigurationKey.grpcSocket), !socket.isEmpty {
            return "unix:\(socket)"
        }
        guard let portText = configurationValue(GarageXPCConfigurationKey.grpcPort), let port = Int(portText), port > 0 else {
            return nil
        }
        return "\(configurationValue(GarageXPCConfigurationKey.grpcHost) ?? "127.0.0.1"):\(port)"
    }

    /// Merges options into the configuration and mirrors well-known keys into `os.environ` for Python code.
    public func mergeConfiguration(_ options: [String: String]) {
        stateLock.lock()
        for (key, value) in options {
            _configuration[key] = value
        }
        stateLock.unlock()
        guard usesPython, runtime.isReady, !options.isEmpty else { return }
        runtime.perform {
            let os = Python.import("os")
            for (key, value) in options {
                if key == GarageXPCConfigurationKey.databaseURL {
                    os.environ[key] = PythonObject(XPCSitePathSetup.ensurePsycopgDatabaseURL(value))
                } else {
                    os.environ[key] = PythonObject(value)
                }
            }
        }
    }

    // MARK: - Self tests

    /// The complete self-test suite for this service.
    public func selfTests() -> [GarageXPCSelfTest] {
        var tests: [GarageXPCSelfTest] = [GarageXPCStandardSelfTests.logging(logFileName: logFileName)]
        if usesPython {
            tests.append(GarageXPCStandardSelfTests.pythonRuntime(runtime: runtime))
            tests.append(GarageXPCStandardSelfTests.stdlibExtensions())
            if !requiredPythonModules.isEmpty {
                tests.append(GarageXPCStandardSelfTests.sitePackages(modules: requiredPythonModules))
            }
            tests.append(GarageXPCStandardSelfTests.libpq(runtime: runtime))
            tests.append(GarageXPCStandardSelfTests.tlsTrust(runtime: runtime))
            tests.append(GarageXPCStandardSelfTests.libtesseract())
            tests.append(GarageXPCStandardSelfTests.database(urlProvider: { [weak self] in self?.databaseURL }))
            tests.append(GarageXPCStandardSelfTests.grpcConnection(addressProvider: { [weak self] in self?.grpcTarget }))
        }
        tests.append(contentsOf: additionalSelfTests())
        return tests
    }

    /// Runs the suite synchronously (on the calling thread; Python tests hop to the runtime queue) and stores results.
    @discardableResult
    public func performSelfTests() -> [GarageXPCTestResult] {
        stateLock.lock()
        if _isRunningTests {
            let cached = _lastTestResults
            stateLock.unlock()
            return cached
        }
        _isRunningTests = true
        stateLock.unlock()
        defer {
            stateLock.lock()
            _isRunningTests = false
            stateLock.unlock()
        }

        var results: [GarageXPCTestResult]
        if usesPython && !runtime.isReady {
            // Only the non-Python tests can run; report the runtime failure prominently.
            let status = runtime.statusSnapshot()
            results = GarageXPCSelfTestRunner.run(selfTests().filter { !$0.requiresPython }, runtime: runtime)
            results.insert(GarageXPCTestResult(
                name: "Python Runtime",
                testDescription: "Interpreter started from the bundled Python.framework with isolated home and sys.path.",
                status: .failed,
                durationMs: status.initializationMs ?? 0,
                summary: "Python environment failed to load",
                details: status.error ?? "unknown error",
                errorMessage: status.error
            ), at: 0)
            for test in selfTests() where test.requiresPython {
                results.append(GarageXPCTestResult(name: test.name, testDescription: test.testDescription, status: .skipped, durationMs: 0, summary: "Skipped: Python runtime unavailable"))
            }
        } else {
            results = GarageXPCSelfTestRunner.run(selfTests(), runtime: runtime)
        }

        stateLock.lock()
        _lastTestResults = results
        _lastTestRun = Date()
        stateLock.unlock()
        recomputeLifecycle()
        return results
    }

    /// Runs the named tests of the suite again and replaces their earlier results (for a test whose
    /// precondition has just changed, such as the LlamaXPCService endpoint arriving). Does nothing
    /// before the suite's first run, which will run them itself; waits and tries again while the
    /// whole suite is running, so its older result cannot overwrite the new one.
    public func rerunSelfTests(named names: Set<String>) {
        host.perform { [self] in
            stateLock.lock()
            let hasResults = !_lastTestResults.isEmpty
            let suiteRunning = _isRunningTests
            stateLock.unlock()
            guard hasResults else { return }
            guard !suiteRunning else {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.rerunSelfTests(named: names)
                }
                return
            }
            let tests = selfTests().filter { names.contains($0.name) && (!$0.requiresPython || runtime.isReady) }
            guard !tests.isEmpty else { return }
            let fresh = GarageXPCSelfTestRunner.run(tests, runtime: runtime)
            stateLock.lock()
            for result in fresh {
                if let index = _lastTestResults.firstIndex(where: { $0.name == result.name }) {
                    _lastTestResults[index] = result
                }
            }
            stateLock.unlock()
            recomputeLifecycle()
        }
    }

    public var lastTestResults: [GarageXPCTestResult] {
        stateLock.lock(); defer { stateLock.unlock() }
        return _lastTestResults
    }

    // MARK: - Status report

    public func statusReport() -> GarageXPCStatusReport {
        stateLock.lock()
        let tests = _lastTestResults
        let lastRun = _lastTestRun
        let lifecycle = _lifecycle
        stateLock.unlock()

        let (_, stderrText) = GarageXPCOutputCapture.shared.fetchLogs(clearBuffer: false)
        let errorLines = stderrText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(40)
            .map(String.init)

        return GarageXPCStatusReport(
            serviceName: serviceName,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "",
            pid: ProcessInfo.processInfo.processIdentifier,
            uptimeSeconds: uptime,
            lifecycle: lifecycle.rawValue,
            logFilePath: GarageFileLogger.logFileURL(named: logFileName).path,
            python: runtime.statusSnapshot(),
            services: host.statusSnapshot(),
            tests: tests,
            lastTestRun: lastRun?.timeIntervalSince1970,
            recentErrorLines: errorLines,
            lastCrashReport: GarageXPCCrashHandler.lastCrashReport(serviceName: serviceName)
        )
    }

    // MARK: - NSXPCListenerDelegate

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        let clientPID = newConnection.processIdentifier
        logger.info("\(self.serviceName, privacy: .public): accepting connection from pid \(clientPID, privacy: .public)")

        // Only processes signed by this build's team (the app, the other services, the launchers) may
        // talk to the service; messages from anything else are dropped and the connection invalidated.
        if let requirement = GarageXPCPeerRequirement.current {
            newConnection.setCodeSigningRequirement(requirement)
        }

        newConnection.remoteObjectInterface = NSXPCInterface(with: GarageXPCLogReceiverProtocol.self)
        newConnection.exportedInterface = exportedInterface
        newConnection.exportedObject = self

        // Log streaming is opt-in (`subscribeToLogStream`): most clients open short-lived connections without an
        // exported receiver, and pushing a message at such a connection makes NSXPC drop it as undecodable and
        // invalidate the connection - which also loses the reply of whatever call the client was waiting for.
        newConnection.invalidationHandler = { [weak newConnection] in
            logger.info("XPC connection invalidated for pid \(clientPID, privacy: .public)")
            if let conn = newConnection {
                GarageXPCOutputCapture.shared.removeConnection(conn)
            }
        }
        newConnection.interruptionHandler = { [weak newConnection] in
            logger.warning("XPC connection interrupted for pid \(clientPID, privacy: .public)")
            if let conn = newConnection {
                GarageXPCOutputCapture.shared.removeConnection(conn)
            }
        }

        didAcceptConnection(newConnection)
        newConnection.resume()
        return true
    }

    // MARK: - GarageCommonXPCServiceProtocol

    public func ping(with reply: @escaping (String) -> Void) {
        let state = lifecycle
        var response = "pong from \(serviceName) [\(state.rawValue)]"
        if usesPython {
            switch runtime.state {
            case .ready:
                response += " python=\(runtime.pythonVersion?.split(separator: " ").first.map(String.init) ?? "ready")"
            case .starting, .notStarted:
                response += " python=loading"
            case .failed(let message):
                response += " (with warning: \(message.split(separator: "\n").first.map(String.init) ?? message))"
            }
        }
        reply(response)
    }

    public func getServiceInfo(with reply: @escaping (String, Int32, Double, String?) -> Void) {
        let status: String
        switch lifecycle {
        case .ready: status = "ready"
        case .bootstrapping: status = "starting"
        case .degraded: status = "warning: \(lastTestResults.filter { $0.status == .failed }.map { $0.name }.joined(separator: ", ")) failed"
        case .failed:
            stateLock.lock()
            let err = _bootstrapError
            stateLock.unlock()
            status = "error: \(err ?? runtime.statusSnapshot().error ?? "unknown")"
        }
        reply(serviceName, ProcessInfo.processInfo.processIdentifier, uptime, status)
    }

    public func updateConfiguration(_ options: [String: String], with reply: @escaping (Bool, String?) -> Void) {
        mergeConfiguration(options)
        reply(true, "\(options.count) key(s) updated")
    }

    public func runDiagnostic(with reply: @escaping (Bool, String?, String?) -> Void) {
        host.perform { [self] in
            let results = performSelfTests()
            let failed = results.filter { $0.status == .failed }
            let skipped = results.filter { $0.status == .skipped }.count
            let summary = failed.isEmpty
                ? (skipped == 0 ? "All \(results.count) self tests passed" : "\(results.count - skipped) self tests passed, \(skipped) skipped")
                : "\(failed.count) of \(results.count) self tests failed: \(failed.map { $0.name }.joined(separator: ", "))"
            let details = results.map { "[\($0.status.rawValue.uppercased())] \($0.name): \($0.summary)\(($0.details.isEmpty || $0.status == .passed) ? "" : "\n\($0.details)")" }.joined(separator: "\n")
            reply(failed.isEmpty, summary, details)
        }
    }

    public func getServiceStatus(with reply: @escaping (String) -> Void) {
        reply(statusReport().jsonString())
    }

    public func runSelfTests(with reply: @escaping (Bool, String) -> Void) {
        host.perform { [self] in
            let results = performSelfTests()
            reply(results.allSatisfy { $0.passed }, statusReport().jsonString())
        }
    }

    public func restartServices(graceful: Bool, with reply: @escaping (Bool, String?) -> Void) {
        logger.info("\(self.serviceName, privacy: .public): restartServices(graceful: \(graceful, privacy: .public))")
        GarageXPCOutputCapture.shared.log(level: "WARN", message: "Restarting managed services (\(graceful ? "graceful" : "immediate"))")
        registerServicesIfNeeded()
        host.restartAll(graceful: graceful) { [self] states in
            recomputeLifecycle()
            let failed = states.filter { if case .failed = $0.value { return true } else { return false } }
            if failed.isEmpty {
                reply(true, "Restarted \(states.count) service(s)")
            } else {
                let detail = failed.map { name, state -> String in
                    if case .failed(let message) = state { return "\(name): \(message)" }
                    return name
                }.joined(separator: "; ")
                reply(false, detail)
            }
        }
    }

    public func fetchLogs(with reply: @escaping (String?, String?) -> Void) {
        let (out, err) = GarageXPCOutputCapture.shared.fetchLogs(clearBuffer: false)
        reply(out, err)
    }

    public func fetchBufferedOutput(clearBuffer: Bool, with reply: @escaping (String?, String?, Error?) -> Void) {
        let (out, err) = GarageXPCOutputCapture.shared.fetchLogs(clearBuffer: clearBuffer)
        reply(out, err, nil)
    }

    public func clearLogs(with reply: @escaping (Bool) -> Void) {
        GarageXPCOutputCapture.shared.clear()
        GarageXPCCrashHandler.clearCrashReport(serviceName: serviceName)
        reply(true)
    }

    public func subscribeToLogStream(with reply: @escaping (Bool) -> Void) {
        guard let connection = NSXPCConnection.current() else {
            reply(false)
            return
        }
        GarageXPCOutputCapture.shared.addConnection(connection)
        logger.info("\(self.serviceName, privacy: .public): pid \(connection.processIdentifier, privacy: .public) subscribed to log streaming")
        reply(true)
    }

    // MARK: - GarageLlamaEndpointReceiverProtocol

    /// Keeps the LlamaXPCService endpoint the app handed over for this process's llama clients
    /// (`LlamaModelLoader`), then re-runs the self test that needs it. Services whose exported
    /// protocol does not adopt `GarageLlamaEndpointReceiverProtocol` never receive this call.
    public func setLlamaEndpoint(_ endpoint: NSXPCListenerEndpoint, with reply: @escaping (Bool, String?) -> Void) {
        GarageLlamaEndpointStore.shared.set(endpoint)
        logger.info("\(self.serviceName, privacy: .public): received the LlamaXPCService endpoint")
        GarageXPCOutputCapture.shared.log(message: "Received the LlamaXPCService endpoint from the app")
        reply(true, "LlamaXPCService endpoint received by \(serviceName)")
        rerunSelfTests(named: [GarageLlamaEndpointStore.dependentSelfTestName])
    }

    // MARK: - GarageImageEmbedEndpointReceiverProtocol

    /// Keeps the GarageImageEmbedXPCService endpoint the app handed over for this process's
    /// image embedding bridge, then re-runs the self test that needs it. Services whose exported
    /// protocol does not adopt `GarageImageEmbedEndpointReceiverProtocol` never receive this call.
    public func setImageEmbedEndpoint(_ endpoint: NSXPCListenerEndpoint, with reply: @escaping (Bool, String?) -> Void) {
        GarageImageEmbedEndpointStore.shared.set(endpoint)
        logger.info("\(self.serviceName, privacy: .public): received the GarageImageEmbedXPCService endpoint")
        GarageXPCOutputCapture.shared.log(message: "Received the GarageImageEmbedXPCService endpoint from the app")
        reply(true, "GarageImageEmbedXPCService endpoint received by \(serviceName)")
        rerunSelfTests(named: [GarageImageEmbedEndpointStore.dependentSelfTestName])
    }

    // MARK: - GarageFolderAccessReceiverProtocol

    /// Starts accessing a folder or file the app granted (the URL carries this process's sandbox
    /// extension) and keeps a bookmark of its own for relaunches. Services whose exported protocol
    /// does not adopt `GarageFolderAccessReceiverProtocol` never receive this call.
    public func grantFolderAccess(_ url: URL, key: String, with reply: @escaping (Bool, String?) -> Void) {
        let result = GarageFolderAccessStore.shared.grant(url, key: key)
        logger.info("\(self.serviceName, privacy: .public): folder grant '\(key, privacy: .public)': \(result.message, privacy: .public)")
        GarageXPCOutputCapture.shared.log(level: result.success ? "INFO" : "WARN", message: result.message)
        reply(result.success, result.message)
    }

    public func revokeAllFolderAccess(with reply: @escaping (Bool) -> Void) {
        GarageFolderAccessStore.shared.revokeAll()
        logger.info("\(self.serviceName, privacy: .public): revoked every folder grant")
        GarageXPCOutputCapture.shared.log(message: "Revoked every folder grant")
        reply(true)
    }

    // MARK: - Helpers for subclasses

    /// Runs `body` with the GIL held and converts Python exceptions into readable error strings.
    public func withPython<T>(_ body: () throws -> T) -> Result<T, Error> {
        guard ensurePythonReady() else {
            stateLock.lock()
            let message = _bootstrapError ?? "Python runtime unavailable"
            stateLock.unlock()
            return .failure(GaragePythonRuntimeError.initializationFailed(code: -1, message: message))
        }
        do {
            return .success(try runtime.withGIL {
                do {
                    return try body()
                } catch {
                    throw GarageXPCServiceError.python(GaragePythonRuntime.describe(error))
                }
            })
        } catch {
            return .failure(error)
        }
    }
}

/// Error wrapper used by services when surfacing Python failures over XPC.
public enum GarageXPCServiceError: Error, LocalizedError {
    case python(String)
    case notRunning(String)
    case invalidArgument(String)

    public var errorDescription: String? {
        switch self {
        case .python(let message): return message
        case .notRunning(let message): return message
        case .invalidArgument(let message): return message
        }
    }
}

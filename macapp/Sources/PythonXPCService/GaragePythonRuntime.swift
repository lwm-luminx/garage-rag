import Foundation
import Darwin
import OSLog
import GaragePythonEmbed
import PythonKit
import PythonXPCService_protocol

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag", category: "GaragePythonRuntime")

/// Describes the on-disk layout of the isolated Python environment shipped inside `PythonXPCService.framework`.
///
/// Layout (relative to the framework):
/// ```
/// site-python/                 <- python stdlib (os.py, ...) == PyConfig.home / stdlib_dir
/// site-python/lib-dynload/     <- compiled stdlib extension modules
/// site-python/site-packages/   <- third-party packages + garage_rag
/// ```
public struct GaragePythonEnvironment: Equatable, Sendable {
    public static let sitePythonDirectoryName = "site-python"
    public static let libDynloadDirectoryName = "lib-dynload"
    public static let sitePackagesDirectoryName = "site-packages"

    /// `PyConfig.home`: the directory that holds the standard library.
    public let home: URL
    public let stdlibDir: URL
    public let libDynloadDir: URL
    public let sitePackagesDir: URL
    /// Additional `sys.path` entries appended after site-packages.
    public let extraSearchPaths: [URL]

    public init(sitePythonURL: URL, extraSearchPaths: [URL] = []) {
        self.home = sitePythonURL
        self.stdlibDir = sitePythonURL
        self.libDynloadDir = sitePythonURL.appendingPathComponent(Self.libDynloadDirectoryName, isDirectory: true)
        self.sitePackagesDir = sitePythonURL.appendingPathComponent(Self.sitePackagesDirectoryName, isDirectory: true)
        self.extraSearchPaths = extraSearchPaths
    }

    /// Ordered `sys.path` as it will be handed to the interpreter.
    public var searchPaths: [URL] {
        [stdlibDir, libDynloadDir, sitePackagesDir] + extraSearchPaths
    }

    /// Returns human readable problems with this layout (missing landmarks). Empty means the layout is valid.
    public func validationProblems() -> [String] {
        var problems: [String] = []
        let fm = FileManager.default
        var isDir: ObjCBool = false

        if !fm.fileExists(atPath: home.path, isDirectory: &isDir) || !isDir.boolValue {
            problems.append("Python home directory is missing: \(home.path)")
            return problems
        }
        let osLandmark = stdlibDir.appendingPathComponent("os.py").path
        if !fm.fileExists(atPath: osLandmark) {
            problems.append("Standard library landmark 'os.py' not found in \(stdlibDir.path)")
        }
        if !fm.fileExists(atPath: libDynloadDir.path, isDirectory: &isDir) || !isDir.boolValue {
            problems.append("lib-dynload directory is missing: \(libDynloadDir.path)")
        }
        if !fm.fileExists(atPath: sitePackagesDir.path, isDirectory: &isDir) || !isDir.boolValue {
            problems.append("site-packages directory is missing: \(sitePackagesDir.path)")
        }
        return problems
    }
}

/// Errors raised while resolving or starting the embedded interpreter.
public enum GaragePythonRuntimeError: Error, LocalizedError, Equatable {
    case invalidEnvironment([String])
    case initializationFailed(code: Int, message: String)
    case notInitialized

    public var errorDescription: String? {
        switch self {
        case .invalidEnvironment(let problems):
            return "Bundled Python environment is incomplete:\n  - " + problems.joined(separator: "\n  - ")
        case .initializationFailed(let code, let message):
            return "Py_InitializeFromConfig failed (code \(code)): \(message)"
        case .notInitialized:
            return "The embedded Python interpreter has not been initialized"
        }
    }
}

/// Owns the single embedded CPython interpreter of an XPC service.
///
/// Responsibilities:
/// - resolve the isolated environment (`site-python` in the loaded `PythonXPCService.framework`, which also
///   links libpq, so dyld has loaded it before the interpreter starts);
/// - start the interpreter through the PyConfig API (isolated mode, explicit `home` and `sys.path`);
/// - manage the GIL for host → Python calls so that Python threads (gRPC servers, thread pools)
///   keep running while Swift code is idle.
///
/// Rule for callers: create, use **and release** `PythonObject` values inside a single `withGIL` scope.
/// PythonKit decrements reference counts when a `PythonObject` is destroyed, which must happen with the GIL held,
/// so avoid storing `PythonObject`s in properties that may be released from arbitrary threads (store them only
/// where the release also happens inside `withGIL`, as `GarageGRPCManagedServer` does).
public final class GaragePythonRuntime: @unchecked Sendable {
    public static let shared = GaragePythonRuntime()

    public enum State: Equatable, Sendable {
        case notStarted
        case starting
        case ready
        case failed(String)

        public var name: String {
            switch self {
            case .notStarted: return "notStarted"
            case .starting: return "starting"
            case .ready: return "ready"
            case .failed: return "failed"
            }
        }

        public var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    private let stateLock = NSRecursiveLock()
    private var _state: State = .notStarted
    private var _environment: GaragePythonEnvironment?
    private var _initializationMs: Double?
    private var _pythonVersion: String?
    private var _sysPath: [String] = []

    /// Serial queue that owns interpreter initialization (exactly one `Py_InitializeFromConfig` per process).
    private let pythonQueue = DispatchQueue(label: "me.rickmark.garage-rag.python-runtime", qos: .userInitiated)
    private let pythonQueueKey = DispatchSpecificKey<Bool>()

    /// Environment variable that allows overriding the `site-python` location during development / testing.
    public static let sitePythonOverrideEnvironmentKey = "GARAGE_SITE_PYTHON"

    /// Environment variable naming the configuration file OpenSSL loads when it initializes. The runtime points it
    /// at the empty `openssl.cnf` shipped next to `site-python`, so no OpenSSL in the process reads a configuration
    /// from outside the bundle: `cryptography`'s statically linked copy defaults to `/opt/homebrew/etc/openssl@3`.
    public static let opensslConfEnvironmentKey = "OPENSSL_CONF"
    public static let opensslConfFileName = "openssl.cnf"

    public init() {
        pythonQueue.setSpecific(key: pythonQueueKey, value: true)
    }

    // MARK: - State

    public var state: State {
        stateLock.lock(); defer { stateLock.unlock() }
        return _state
    }

    public var environment: GaragePythonEnvironment? {
        stateLock.lock(); defer { stateLock.unlock() }
        return _environment
    }

    public var isReady: Bool { state.isReady }

    public var pythonVersion: String? {
        stateLock.lock(); defer { stateLock.unlock() }
        return _pythonVersion
    }

    private func setState(_ newState: State) {
        stateLock.lock()
        _state = newState
        stateLock.unlock()
    }

    // MARK: - Environment resolution

    /// Bundle identifier of `PythonXPCService.framework`, whose resources hold `site-python`.
    public static let frameworkBundleIdentifier = "me.rickmark.garage-rag.PythonXPCService"

    /// `site-python` inside `PythonXPCService.framework`, the framework every Python process links. A sandboxed
    /// XPC service may read inside the frameworks it links but not elsewhere in the enclosing app bundle, so this
    /// is where the App Store build's services find the interpreter home. Nil when the framework is not loaded.
    static var frameworkSitePythonURL: URL? {
        Bundle(identifier: frameworkBundleIdentifier)?.resourceURL?
            .appendingPathComponent(GaragePythonEnvironment.sitePythonDirectoryName, isDirectory: true)
    }

    /// Resolves the isolated environment from (in order): `GARAGE_SITE_PYTHON`, the loaded
    /// `PythonXPCService.framework`'s resources, then the running bundle's own `Resources`.
    public func resolveEnvironment() throws -> GaragePythonEnvironment {
        let fm = FileManager.default
        var candidates: [URL] = []

        if let override = ProcessInfo.processInfo.environment[Self.sitePythonOverrideEnvironmentKey], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override, isDirectory: true))
        }
        if let frameworkSitePython = Self.frameworkSitePythonURL {
            candidates.append(frameworkSitePython)
        }
        if let ownResources = Bundle.main.resourceURL {
            candidates.append(ownResources.appendingPathComponent(GaragePythonEnvironment.sitePythonDirectoryName, isDirectory: true))
        }

        var problems: [String] = []
        for sitePython in candidates {
            let env = GaragePythonEnvironment(sitePythonURL: sitePython.standardizedFileURL)
            let envProblems = env.validationProblems()
            if envProblems.isEmpty {
                logger.info("Resolved Python environment: home='\(env.home.path, privacy: .public)'")
                return env
            }
            if fm.fileExists(atPath: sitePython.path) {
                problems.append(contentsOf: envProblems)
            } else {
                problems.append("No site-python directory at \(sitePython.path)")
            }
        }
        if Self.frameworkSitePythonURL == nil {
            problems.append("PythonXPCService.framework is not loaded in this process (\(Bundle.main.bundleURL.path))")
        }
        throw GaragePythonRuntimeError.invalidEnvironment(problems)
    }

    // MARK: - Framework libraries

    /// Path of the loaded image that defines `symbol`: for libpq's, the copy
    /// `PythonXPCService.framework` links and dyld loaded with it. Nil when no loaded image defines it.
    public static func loadedImagePath(definingSymbol symbol: String) -> String? {
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT: every loaded image
        guard let address = dlsym(defaultHandle, symbol) else { return nil }
        var info = Dl_info()
        guard dladdr(address, &info) != 0, let name = info.dli_fname else { return nil }
        return String(cString: name)
    }

    /// The libpq psycopg uses: the framework's, loaded with it. Nil when it is not loaded.
    public var libpqPath: String? {
        Self.loadedImagePath(definingSymbol: "PQlibVersion")
    }

    // MARK: - OpenSSL

    /// The `openssl.cnf` shipped next to `site-python` (in `PythonXPCService.framework`), or nil when there is none.
    public static func bundledOpenSSLConfigURL(for environment: GaragePythonEnvironment) -> URL? {
        let url = environment.home.deletingLastPathComponent().appendingPathComponent(opensslConfFileName, isDirectory: false)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            return nil
        }
        return url
    }

    /// Exports `OPENSSL_CONF` naming the bundled `openssl.cnf`, replacing any value inherited from a shell (a
    /// Homebrew user's would bring its configuration back). Returns the exported path, or nil when the bundle has
    /// no `openssl.cnf`, in which case the environment is left alone.
    @discardableResult
    public static func exportBundledOpenSSLConfig(for environment: GaragePythonEnvironment) -> String? {
        guard let url = bundledOpenSSLConfigURL(for: environment) else {
            logger.warning("No \(opensslConfFileName, privacy: .public) next to '\(environment.home.path, privacy: .public)'; OPENSSL_CONF left unchanged")
            return nil
        }
        setenv(opensslConfEnvironmentKey, url.path, 1)
        return url.path
    }

    /// Python source executed right after interpreter start-up. It makes `ssl`'s default contexts verify against the
    /// macOS trust store (`truststore`), since the bundled OpenSSL has no CA files of its own. If `truststore` cannot
    /// be imported it falls back to `certifi`'s bundle through `SSL_CERT_FILE`, unless the caller already set one.
    static let trustStoreBootstrapSource = """
    import os as _os
    try:
        import truststore as _truststore
        _truststore.inject_into_ssl()
    except Exception:
        try:
            import certifi as _certifi
            _os.environ.setdefault("SSL_CERT_FILE", _certifi.where())
        except Exception:
            pass
    """

    /// Python source executed right after interpreter start-up: points psycopg's libpq lookup at the copy the
    /// framework loaded (`garage_rag.libpq.configure()`) before anything can import psycopg.
    static let libpqBootstrapSource = """
    try:
        from garage_rag import libpq as _garage_libpq
        _garage_libpq.configure()
    except ImportError:
        pass
    """

    // MARK: - Initialization

    /// Initializes the interpreter once. Safe to call repeatedly from any thread; subsequent calls return the
    /// cached result. Initialization happens on the runtime queue.
    @discardableResult
    public func initializeIfNeeded() -> Result<GaragePythonEnvironment, Error> {
        stateLock.lock()
        if case .ready = _state, let env = _environment {
            stateLock.unlock()
            return .success(env)
        }
        if case .failed(let message) = _state, GaragePythonEmbedIsInitialized() {
            // Interpreter exists but post-init checks failed; do not try to start a second interpreter.
            stateLock.unlock()
            return .failure(GaragePythonRuntimeError.initializationFailed(code: -1, message: message))
        }
        stateLock.unlock()

        return runOnPythonQueueSync { [self] in
            // Py_InitializeFromConfig imports `site`/`encodings` etc.; never do that on a 512 KB GCD stack.
            (try? onLargeStack { self.performInitialization() }) ?? .failure(GaragePythonRuntimeError.notInitialized)
        }
    }

    private func performInitialization() -> Result<GaragePythonEnvironment, Error> {
        stateLock.lock()
        if case .ready = _state, let env = _environment {
            stateLock.unlock()
            return .success(env)
        }
        _state = .starting
        stateLock.unlock()

        let start = CFAbsoluteTimeGetCurrent()
        let environment: GaragePythonEnvironment
        do {
            environment = try resolveEnvironment()
        } catch {
            let message = error.localizedDescription
            logger.error("Python environment resolution failed: \(message, privacy: .public)")
            setState(.failed(message))
            return .failure(error)
        }

        // OPENSSL_CONF, before anything in the process initializes OpenSSL.
        Self.exportBundledOpenSSLConfig(for: environment)

        if GaragePythonEmbedIsInitialized() {
            logger.warning("Interpreter already initialized before GaragePythonRuntime; adopting existing interpreter")
        } else {
            var options = GaragePythonEmbedOptionsDefault()
            options.disableBytecodeWriting = true
            options.skipSignalHandlers = true
            options.importSite = true
            options.releaseGILAfterInit = true
            options.verbose = ProcessInfo.processInfo.environment["GARAGE_PYTHON_VERBOSE"] != nil

            let extraPaths = environment.extraSearchPaths.map { $0.path }
            let programName = Bundle.main.executableURL?.path ?? "python3"

            var errorBuffer = [CChar](repeating: 0, count: 2048)
            let result: GaragePythonEmbedResult = withCStrings([environment.home.path, environment.stdlibDir.path, environment.libDynloadDir.path, environment.sitePackagesDir.path, programName] + extraPaths) { pointers in
                options.home = pointers[0]
                options.stdlibDir = pointers[1]
                options.platStdlibDir = pointers[2]
                options.programName = pointers[4]
                // site-packages first, then any extra search paths, NULL terminated.
                var extra: [UnsafePointer<CChar>?] = [pointers[3]]
                extra.append(contentsOf: pointers.dropFirst(5).map { Optional($0) })
                extra.append(nil)
                return extra.withUnsafeBufferPointer { buffer -> GaragePythonEmbedResult in
                    options.extraSearchPaths = UnsafeRawPointer(buffer.baseAddress!).assumingMemoryBound(to: UnsafePointer<CChar>?.self)
                    return GaragePythonEmbedInitialize(&options, &errorBuffer, errorBuffer.count)
                }
            }

            if result != GaragePythonEmbedResultOK && result != GaragePythonEmbedResultAlreadyInitialized {
                let message = String(cString: errorBuffer)
                let error = GaragePythonRuntimeError.initializationFailed(code: Int(result.rawValue), message: message)
                logger.error("Py_InitializeFromConfig failed: \(message, privacy: .public)")
                setState(.failed(error.localizedDescription))
                return .failure(error)
            }
        }

        // Post-init: capture version / sys.path and make PythonKit's wrapper initialize under the GIL.
        var version = ""
        var sysPath: [String] = []
        var postInitError: String?
        try? withGILUnchecked {
            version = String(cString: GaragePythonEmbedRuntimeVersion())
            do {
                let sys = try Python.attemptImport("sys")
                sysPath = Array(sys.path).compactMap { String($0) }
                // Make sure stdout/stderr exist so Python logging works even when launched by launchd
                // without a controlling terminal.
                let io = try Python.attemptImport("io")
                if sys.stdout == Python.None {
                    sys.stdout = io.open(1, mode: "w", buffering: 1, encoding: "utf-8", errors: "replace", closefd: false)
                }
                if sys.stderr == Python.None {
                    sys.stderr = io.open(2, mode: "w", buffering: 1, encoding: "utf-8", errors: "replace", closefd: false)
                }
                // Route psycopg's libpq lookup to the framework's library.
                let builtins = try Python.attemptImport("builtins")
                let namespace = Python.dict()
                _ = try builtins.exec.throwing.dynamicallyCall(withArguments: [Self.libpqBootstrapSource, namespace])
                // Default TLS contexts verify against the system trust store.
                _ = try builtins.exec.throwing.dynamicallyCall(withArguments: [Self.trustStoreBootstrapSource, Python.dict()])
            } catch {
                postInitError = Self.describe(error)
            }
        }

        let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
        stateLock.lock()
        _environment = environment
        _pythonVersion = version
        _sysPath = sysPath
        _initializationMs = elapsedMs
        if let postInitError = postInitError {
            _state = .failed("Interpreter started but post-initialization checks failed: \(postInitError)")
            stateLock.unlock()
            logger.error("Python post-initialization failed: \(postInitError, privacy: .public)")
            return .failure(GaragePythonRuntimeError.initializationFailed(code: -1, message: postInitError))
        }
        _state = .ready
        stateLock.unlock()

        logger.info("Embedded Python \(version, privacy: .public) ready in \(String(format: "%.1f", elapsedMs), privacy: .public)ms; home='\(environment.home.path, privacy: .public)'")
        for (idx, entry) in sysPath.enumerated() {
            logger.debug("sys.path[\(idx, privacy: .public)] = \(entry, privacy: .public)")
        }
        return .success(environment)
    }

    // MARK: - Execution

    private var isOnPythonQueue: Bool {
        DispatchQueue.getSpecific(key: pythonQueueKey) == true
    }

    private func runOnPythonQueueSync<T>(_ body: () -> T) -> T {
        if isOnPythonQueue {
            return body()
        }
        return pythonQueue.sync(execute: body)
    }

    // MARK: - Large stack execution

    /// Stack size for threads that run Python code. CPython on macOS assumes the 8 MB main-thread stack (its own
    /// threads get 16 MB); GCD worker threads only have 512 KB, which deep interpreter recursion
    /// (`slot_tp_new` → `_PyEval_EvalFrameDefault` → …) overruns within a few hundred frames and dies with
    /// `SIGBUS: KERN_PROTECTION_FAILURE` in the stack guard page.
    public static let pythonThreadStackSize = 16 * 1024 * 1024
    /// Threads with less stack than this are never allowed to execute Python.
    public static let minimumPythonStackSize = 4 * 1024 * 1024

    /// True when the calling thread's stack is large enough to run the interpreter.
    public static var currentThreadHasLargeStack: Bool {
        pthread_get_stacksize_np(pthread_self()) >= minimumPythonStackSize
    }

    /// Runs `body` synchronously on a freshly created thread with a `pythonThreadStackSize` stack.
    private func hopToLargeStack<T>(_ body: () -> T) -> T {
        var result: T?
        withoutActuallyEscaping(body) { escapable in
            // pthread + join keeps the closure strictly scoped (an NSThread would retain it past this block).
            var work: () -> Void = { result = escapable() }
            withUnsafeMutablePointer(to: &work) { workPointer in
                var attributes = pthread_attr_t()
                pthread_attr_init(&attributes)
                pthread_attr_setstacksize(&attributes, Self.pythonThreadStackSize)
                pthread_attr_set_qos_class_np(&attributes, qos_class_self(), 0)
                var thread: pthread_t?
                let rc = pthread_create(&thread, &attributes, { raw in
                    pthread_setname_np("me.rickmark.garage-rag.python-stack")
                    GarageXPCCrashHandler.installAlternateSignalStackForCurrentThread()
                    raw.assumingMemoryBound(to: (() -> Void).self).pointee()
                    return nil
                }, UnsafeMutableRawPointer(workPointer))
                pthread_attr_destroy(&attributes)
                if rc == 0, let thread = thread {
                    pthread_join(thread, nil)
                } else {
                    logger.error("pthread_create for Python stack failed (\(rc)); running on the caller's stack")
                    workPointer.pointee()
                }
            }
        }
        return result!
    }

    /// Guarantees `body` executes on a thread whose stack is big enough for CPython, hopping synchronously to a
    /// dedicated large-stack thread when the caller is a GCD worker. No-op on the main thread, on Python-created
    /// threads and on threads already created by this helper.
    public func onLargeStack<T>(_ body: () throws -> T) throws -> T {
        if Self.currentThreadHasLargeStack {
            return try body()
        }
        let outcome: Result<T, Error> = hopToLargeStack { Result { try body() } }
        return try outcome.get()
    }

    /// Acquires the GIL for the duration of `body` (on a large-stack thread) without checking runtime state.
    private func withGILUnchecked<T>(_ body: () throws -> T) throws -> T {
        try onLargeStack {
            let token = GaragePythonEmbedAcquireGIL()
            defer { GaragePythonEmbedReleaseGIL(token) }
            return try body()
        }
    }

    /// Executes `body` on the calling thread with the GIL held (`PyGILState_Ensure`/`Release`). Every use of
    /// PythonKit from Swift must go through this (or `perform`) so the GIL is owned by the calling thread
    /// and released again when Swift is done, letting Python's own threads make progress.
    ///
    /// Calls are *not* serialized: CPython's GIL arbitrates between concurrent callers, so a long running
    /// operation (for example an ingest run) does not block status queries, self tests or cancellation
    /// requests issued from other threads. Nested calls on the same thread are allowed.
    public func withGIL<T>(_ body: () throws -> T) throws -> T {
        guard isReady || GaragePythonEmbedIsInitialized() else {
            if case .failed(let message) = state {
                throw GaragePythonRuntimeError.initializationFailed(code: -1, message: message)
            }
            throw GaragePythonRuntimeError.notInitialized
        }
        return try withGILUnchecked(body)
    }

    /// Like `withGIL`, but a `PythonError` raised by `body` is converted to `GarageXPCServiceError.python` with the
    /// full traceback *while the GIL is still held*. Only the resulting string leaves the GIL scope, so callers can
    /// log the error without re-entering Python (`describe` itself needs the GIL to format the traceback).
    public func withGILDescribingErrors<T>(_ body: () throws -> T) throws -> T {
        try withGIL {
            do {
                return try body()
            } catch let error as PythonError {
                throw GarageXPCServiceError.python(Self.describe(error))
            }
        }
    }

    /// Background queue for fire-and-forget Python work (`perform`). Concurrent so that independent
    /// requests do not queue behind each other; the GIL provides the actual mutual exclusion.
    private let workQueue = DispatchQueue(label: "me.rickmark.garage-rag.python-work", qos: .userInitiated, attributes: .concurrent)

    /// Schedules `body` on a background thread with the GIL held.
    public func perform(_ body: @escaping () -> Void) {
        workQueue.async { [self] in
            guard GaragePythonEmbedIsInitialized() else {
                logger.error("perform() dropped: interpreter not initialized")
                return
            }
            try? withGILUnchecked(body)
        }
    }

    // MARK: - Diagnostics

    /// Formats a Swift/PythonKit error including the Python traceback where available.
    public static func describe(_ error: Error) -> String {
        if let pyError = error as? PythonError {
            switch pyError {
            case .exception(let value, let traceback):
                var text = "\(value)"
                if let tb = traceback, let tbModule = try? Python.attemptImport("traceback") {
                    let lines = tbModule.format_exception(Python.type(value), value, tb)
                    let joined = Array(lines).compactMap { String($0) }.joined()
                    if !joined.isEmpty { text = joined }
                }
                return text
            default:
                return pyError.description
            }
        }
        return error.localizedDescription
    }

    /// Snapshot for status reporting.
    public func statusSnapshot() -> GarageXPCPythonStatus {
        stateLock.lock()
        let st = _state
        let env = _environment
        let version = _pythonVersion
        let sysPath = _sysPath
        let initMs = _initializationMs
        stateLock.unlock()
        let libpqPath = self.libpqPath
        let libpqError = libpqPath == nil ? "libpq is not loaded: PythonXPCService.framework should link it" : nil

        var errorText: String? = nil
        if case .failed(let message) = st { errorText = message }

        return GarageXPCPythonStatus(
            state: st.name,
            version: version,
            home: env?.home.path,
            stdlibDir: env?.stdlibDir.path,
            libDynloadDir: env?.libDynloadDir.path,
            sitePackagesDir: env?.sitePackagesDir.path,
            sysPath: sysPath,
            error: errorText,
            initializationMs: initMs,
            libpqPath: libpqPath,
            libpqError: libpqError
        )
    }
}

// MARK: - Helpers

/// Calls `body` with stable C string pointers for every element of `strings`.
private func withCStrings<T>(_ strings: [String], _ body: ([UnsafePointer<CChar>]) -> T) -> T {
    var pointers: [UnsafeMutablePointer<CChar>] = []
    pointers.reserveCapacity(strings.count)
    for s in strings {
        pointers.append(strdup(s))
    }
    defer { pointers.forEach { free($0) } }
    return body(pointers.map { UnsafePointer($0) })
}

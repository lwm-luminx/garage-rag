import Foundation
import GarageXPCKit
import PythonKit

/// The base of every XPC helper that embeds Python: `GarageXPCServiceBase` with the isolated
/// interpreter from the bundled Python.framework started on the host thread.
///
/// On top of the base's start-up it exports the llama_xpc socket before the interpreter starts,
/// starts it (`ensurePythonReady()`), adds the interpreter's standard self tests (runtime, stdlib
/// extensions, site-packages, libpq, TLS trust, Tesseract, git history, database, gRPC) and mirrors
/// configuration into `os.environ`. Subclasses wrap their Python calls in `withPython { ... }` or
/// `GaragePythonRuntime.shared.withGIL { ... }`.
open class GaragePythonXPCServiceBase: GarageXPCServiceBase {
    /// Third-party modules imported by the "Site Packages" self test.
    public let requiredPythonModules: [String]
    public let runtime: GaragePythonRuntime

    public init(
        serviceName: String,
        logFileName: String? = nil,
        requiredPythonModules: [String] = ["grpc", "psycopg", "google.protobuf"],
        runtime: GaragePythonRuntime = .shared
    ) {
        self.requiredPythonModules = requiredPythonModules
        self.runtime = runtime
        super.init(serviceName: serviceName, logFileName: logFileName)
    }

    /// Called on the host thread once Python is ready (before tests run).
    open func pythonDidBecomeReady(_ environment: GaragePythonEnvironment) {}

    /// Initializes Python if needed (idempotent). Safe to call from any thread.
    @discardableResult
    public func ensurePythonReady() -> Bool {
        switch runtime.initializeIfNeeded() {
        case .success(let env):
            recordBootstrapError(nil)
            pythonDidBecomeReady(env)
            return true
        case .failure(let error):
            let message = error.localizedDescription
            recordBootstrapError(message)
            GarageXPCOutputCapture.shared.log(level: "ERROR", message: "Python initialization failed: \(message)")
            return false
        }
    }

    /// Runs `body` with the GIL held and converts Python exceptions into readable error strings.
    public func withPython<T>(_ body: () throws -> T) -> Result<T, Error> {
        guard ensurePythonReady() else {
            let message = bootstrapError ?? "Python runtime unavailable"
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

    // MARK: - Runtime hooks

    override open func prepareRuntime() {
        // Before Python starts, so `os.environ` has it: the llama_xpc provider's socket.
        GarageSockets.exportLlamaSocket()
    }

    override open func startRuntime() {
        ensurePythonReady()
    }

    override open var isRuntimeReady: Bool { runtime.isReady }

    override open func standardSelfTests() -> [GarageXPCSelfTest] {
        var tests: [GarageXPCSelfTest] = [
            GarageXPCStandardSelfTests.pythonRuntime(runtime: runtime),
            GarageXPCStandardSelfTests.stdlibExtensions(),
        ]
        if !requiredPythonModules.isEmpty {
            tests.append(GarageXPCStandardSelfTests.sitePackages(modules: requiredPythonModules))
        }
        tests.append(GarageXPCStandardSelfTests.libpq(runtime: runtime))
        tests.append(GarageXPCStandardSelfTests.tlsTrust(runtime: runtime))
        tests.append(GarageXPCStandardSelfTests.tesseract())
        tests.append(GarageXPCStandardSelfTests.gitHistory())
        tests.append(GarageXPCStandardSelfTests.database(urlProvider: { [weak self] in self?.databaseURL }))
        tests.append(GarageXPCStandardSelfTests.grpcConnection(addressProvider: { [weak self] in self?.grpcTarget }))
        return tests
    }

    override open var selfTestRuntimeExecutor: GarageXPCSelfTestRunner.RuntimeExecutor? {
        GarageXPCSelfTestRunner.pythonExecutor(runtime: runtime)
    }

    override open func runtimeUnavailableResult() -> GarageXPCTestResult? {
        let status = runtime.statusSnapshot()
        return GarageXPCTestResult(
            name: "Python Runtime",
            testDescription: "Interpreter started from the bundled Python.framework with isolated home and sys.path.",
            status: .failed,
            durationMs: status.initializationMs ?? 0,
            summary: "Python environment failed to load",
            details: status.error ?? "unknown error",
            errorMessage: status.error
        )
    }

    override open func runtimeStatus() -> GarageXPCPythonStatus {
        runtime.statusSnapshot()
    }

    override open func pingRuntimeDetail() -> String {
        switch runtime.state {
        case .ready:
            return " python=\(runtime.pythonVersion?.split(separator: " ").first.map(String.init) ?? "ready")"
        case .starting, .notStarted:
            return " python=loading"
        case .failed(let message):
            return " (with warning: \(message.split(separator: "\n").first.map(String.init) ?? message))"
        }
    }

    /// Mirrors well-known keys into `os.environ` for Python code.
    override open func didMergeConfiguration(_ options: [String: String]) {
        guard runtime.isReady, !options.isEmpty else { return }
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
}

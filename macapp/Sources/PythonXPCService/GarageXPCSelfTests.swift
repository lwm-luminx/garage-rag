import Foundation
import OSLog
import PythonKit
import PythonXPCService_protocol

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag", category: "GarageXPCSelfTests")

/// A single self test executed inside an XPC service after the Python environment has been loaded.
///
/// The `run` closure is executed on the Python runtime queue with the GIL held when `requiresPython` is
/// true, so it may use PythonKit directly. It returns human readable details on success and throws on failure.
public struct GarageXPCSelfTest: Sendable {
    public typealias Body = @Sendable () throws -> String

    public let name: String
    public let testDescription: String
    public let requiresPython: Bool
    public let body: Body

    public init(name: String, description: String, requiresPython: Bool = true, body: @escaping Body) {
        self.name = name
        self.testDescription = description
        self.requiresPython = requiresPython
        self.body = body
    }
}

/// Error used by self tests to report a failure with a summary and optional extra details.
public struct GarageXPCSelfTestFailure: Error, LocalizedError {
    public let summary: String
    public let details: String

    public init(_ summary: String, details: String = "") {
        self.summary = summary
        self.details = details
    }

    public var errorDescription: String? { details.isEmpty ? summary : "\(summary)\n\(details)" }
}

/// Marker error: the test could not run because a prerequisite (configuration) is missing.
public struct GarageXPCSelfTestSkipped: Error, LocalizedError {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
    public var errorDescription: String? { reason }
}

/// Runs self tests and produces `GarageXPCTestResult` records.
public enum GarageXPCSelfTestRunner {
    /// Executes the given tests sequentially. Python-based tests are skipped with a failure result when the
    /// runtime is not ready so the status page shows *why* nothing else could be verified.
    public static func run(_ tests: [GarageXPCSelfTest], runtime: GaragePythonRuntime = .shared) -> [GarageXPCTestResult] {
        var results: [GarageXPCTestResult] = []
        results.reserveCapacity(tests.count)

        for test in tests {
            let start = CFAbsoluteTimeGetCurrent()
            let result: GarageXPCTestResult
            do {
                let details: String
                if test.requiresPython {
                    details = try runtime.withGIL {
                        do {
                            return try test.body()
                        } catch let failure as GarageXPCSelfTestFailure {
                            throw failure
                        } catch let skipped as GarageXPCSelfTestSkipped {
                            throw skipped
                        } catch {
                            // Resolve Python tracebacks while the GIL is still held.
                            throw GarageXPCSelfTestFailure(error.localizedDescription, details: GaragePythonRuntime.describe(error))
                        }
                    }
                } else {
                    details = try test.body()
                }
                let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
                result = GarageXPCTestResult(
                    name: test.name,
                    testDescription: test.testDescription,
                    status: .passed,
                    durationMs: elapsed,
                    summary: "Passed in \(String(format: "%.1f", elapsed))ms",
                    details: details
                )
                logger.info("Self test '\(test.name, privacy: .public)' passed in \(String(format: "%.1f", elapsed), privacy: .public)ms")
            } catch let skipped as GarageXPCSelfTestSkipped {
                let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
                result = GarageXPCTestResult(
                    name: test.name,
                    testDescription: test.testDescription,
                    status: .skipped,
                    durationMs: elapsed,
                    summary: "Skipped: \(skipped.reason)",
                    details: skipped.reason
                )
                logger.notice("Self test '\(test.name, privacy: .public)' skipped: \(skipped.reason, privacy: .public)")
            } catch let failure as GarageXPCSelfTestFailure {
                let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
                result = GarageXPCTestResult(
                    name: test.name,
                    testDescription: test.testDescription,
                    status: .failed,
                    durationMs: elapsed,
                    summary: failure.summary,
                    details: failure.details,
                    errorMessage: failure.summary
                )
                logger.error("Self test '\(test.name, privacy: .public)' failed: \(failure.summary, privacy: .public)\n\(failure.details, privacy: .public)")
            } catch {
                let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
                let message = error.localizedDescription
                result = GarageXPCTestResult(
                    name: test.name,
                    testDescription: test.testDescription,
                    status: .failed,
                    durationMs: elapsed,
                    summary: message,
                    details: message,
                    errorMessage: message
                )
                logger.error("Self test '\(test.name, privacy: .public)' failed: \(message, privacy: .public)")
            }
            results.append(result)
        }
        return results
    }
}

// MARK: - Standard tests shared by all Python based XPC services

public enum GarageXPCStandardSelfTests {
    /// Verifies the interpreter is up, reports version / prefix and that every `sys.path` entry exists.
    public static func pythonRuntime(runtime: GaragePythonRuntime = .shared) -> GarageXPCSelfTest {
        GarageXPCSelfTest(name: "Python Runtime", description: "Interpreter started from the bundled Python.framework with isolated home and sys.path.") {
            guard let env = runtime.environment else {
                throw GarageXPCSelfTestFailure("Python environment not resolved", details: runtime.statusSnapshot().error ?? "")
            }
            let sys = try Python.attemptImport("sys")
            let version = String(sys.version) ?? "unknown"
            let prefix = String(sys[dynamicMember: "prefix"]) ?? ""
            let execPrefix = String(sys[dynamicMember: "exec_prefix"]) ?? ""
            let paths = Array(sys.path).compactMap { String($0) }
            let missing = paths.filter { !$0.isEmpty && !FileManager.default.fileExists(atPath: $0) }
            if !missing.isEmpty {
                throw GarageXPCSelfTestFailure("sys.path contains \(missing.count) missing entr\(missing.count == 1 ? "y" : "ies")", details: missing.joined(separator: "\n"))
            }
            let flags = sys.flags
            let isolated = Int(flags.isolated) ?? 0
            if isolated == 0 {
                throw GarageXPCSelfTestFailure("Interpreter is not running in isolated mode", details: "sys.flags.isolated == 0")
            }
            var lines: [String] = []
            lines.append("Version: \(version.replacingOccurrences(of: "\n", with: " "))")
            lines.append("Home: \(env.home.path)")
            lines.append("sys.prefix: \(prefix)")
            lines.append("sys.exec_prefix: \(execPrefix)")
            lines.append("Isolated: yes, no user site, environment ignored")
            lines.append("sys.path:")
            lines.append(contentsOf: paths.map { "  \($0)" })
            return lines.joined(separator: "\n")
        }
    }

    /// Imports compiled stdlib extension modules that live in `lib-dynload` to prove the platform library path works.
    public static func stdlibExtensions(modules: [String] = ["_socket", "_ssl", "_hashlib", "zlib", "_json", "_sqlite3", "_ctypes", "select", "math", "_datetime"]) -> GarageXPCSelfTest {
        GarageXPCSelfTest(name: "Standard Library Extensions", description: "Loads compiled extension modules from site-python/lib-dynload (sockets, TLS, zlib, sqlite, ctypes).") {
            var loaded: [String] = []
            var failures: [String] = []
            for name in modules {
                do {
                    let module = try Python.attemptImport(name)
                    let file = String(module.checking.__file__ ?? Python.None) ?? "(builtin)"
                    loaded.append("\(name) <- \(file)")
                } catch {
                    failures.append("\(name): \(GaragePythonRuntime.describe(error).trimmingCharacters(in: .whitespacesAndNewlines))")
                }
            }
            if !failures.isEmpty {
                throw GarageXPCSelfTestFailure("\(failures.count) of \(modules.count) extension modules failed to load", details: (failures + [""] + loaded).joined(separator: "\n"))
            }
            let ssl = try Python.attemptImport("ssl")
            let opensslVersion = String(ssl.OPENSSL_VERSION) ?? "unknown"
            return (["OpenSSL: \(opensslVersion)"] + loaded).joined(separator: "\n")
        }
    }

    /// Imports third-party packages from `site-packages` (defaults to the packages every Garage service relies on).
    public static func sitePackages(modules: [String]) -> GarageXPCSelfTest {
        GarageXPCSelfTest(name: "Site Packages", description: "Imports required packages from site-python/site-packages: \(modules.joined(separator: ", ")).") {
            var loaded: [String] = []
            var failures: [String] = []
            for name in modules {
                do {
                    let module = try Python.attemptImport(name)
                    let version = String(module.checking.__version__ ?? Python.None) ?? ""
                    let file = String(module.checking.__file__ ?? Python.None) ?? ""
                    loaded.append("\(name)\(version.isEmpty ? "" : " \(version)") <- \(file)")
                } catch {
                    failures.append("\(name): \(GaragePythonRuntime.describe(error).trimmingCharacters(in: .whitespacesAndNewlines))")
                }
            }
            if !failures.isEmpty {
                throw GarageXPCSelfTestFailure("\(failures.count) of \(modules.count) packages failed to import", details: (failures + [""] + loaded).joined(separator: "\n"))
            }
            return loaded.joined(separator: "\n")
        }
    }

    /// Verifies psycopg runs on its C implementation, built into this framework with libpq linked statically.
    public static func psycopg() -> GarageXPCSelfTest {
        GarageXPCSelfTest(name: "psycopg", description: "psycopg_c's modules are built in, psycopg picks its C implementation, and the libpq linked with it is the one it was built against.") {
            let sys = try Python.attemptImport("sys")
            let builtins = Set(Array(sys.builtin_module_names).compactMap { String($0) })
            let missing = ["psycopg_c.pq", "psycopg_c._psycopg"].filter { !builtins.contains($0) }
            if !missing.isEmpty {
                throw GarageXPCSelfTestFailure("psycopg_c is not built in", details: "missing: \(missing.joined(separator: ", "))")
            }
            let psycopg = try Python.attemptImport("psycopg")
            let pq = try Python.attemptImport("psycopg.pq")
            let impl = String(pq.__impl__) ?? "unknown"
            if impl != "c" {
                throw GarageXPCSelfTestFailure("psycopg uses its \(impl) implementation, not c", details: "")
            }
            let cmodule = try Python.attemptImport("psycopg._cmodule")
            let psycopgVersion = String(psycopg.__version__) ?? "?"
            let cVersion = String(cmodule.__version__) ?? "?"
            let version = Int(pq.version()) ?? 0
            let buildVersion = Int(pq.__build_version__) ?? 0
            if version != buildVersion {
                throw GarageXPCSelfTestFailure("libpq \(version) is not the \(buildVersion) psycopg_c was built against", details: "")
            }
            return ["psycopg \(psycopgVersion), psycopg_c \(cVersion)", "libpq version: \(version)"].joined(separator: "\n")
        }
    }

    /// Verifies OpenSSL reads the bundle's `openssl.cnf` and that default TLS contexts have a trust store to verify
    /// against. Offline: it inspects the configuration and makes no connection.
    public static func tlsTrust(runtime: GaragePythonRuntime = .shared) -> GarageXPCSelfTest {
        GarageXPCSelfTest(name: "TLS Trust", description: "OPENSSL_CONF names the bundled openssl.cnf, and ssl's default contexts verify against the system trust store.") {
            guard let env = runtime.environment else {
                throw GarageXPCSelfTestFailure("Python environment not resolved", details: runtime.statusSnapshot().error ?? "")
            }
            let expected = GaragePythonRuntime.bundledOpenSSLConfigURL(for: env)?.path
            // getenv, not ProcessInfo: the runtime set these with setenv after launch.
            let actual = getenv(GaragePythonRuntime.opensslConfEnvironmentKey).map { String(cString: $0) }
            let certFile = getenv("SSL_CERT_FILE").map { String(cString: $0) } ?? "(unset)"
            guard let expected, actual == expected else {
                throw GarageXPCSelfTestFailure("OPENSSL_CONF does not name the bundled openssl.cnf", details: "expected: \(expected ?? "(no openssl.cnf next to site-python)")\nactual:   \(actual ?? "(unset)")")
            }
            let ssl = try Python.attemptImport("ssl")
            let contextModule = String(ssl.SSLContext.__module__) ?? ""
            var lines = ["OPENSSL_CONF: \(expected)", "OpenSSL: \(String(ssl.OPENSSL_VERSION) ?? "unknown")"]
            if contextModule.hasPrefix("truststore") {
                let truststore = try Python.attemptImport("truststore")
                lines.append("Trust: macOS trust store (truststore \(String(truststore.__version__) ?? "?"))")
            } else {
                let count = Int(ssl.create_default_context().cert_store_stats()["x509_ca"]) ?? 0
                guard count > 0 else {
                    throw GarageXPCSelfTestFailure("Default TLS contexts have no CA certificates", details: "ssl.SSLContext is \(contextModule).SSLContext and loads 0 CAs; SSL_CERT_FILE=\(certFile)")
                }
                lines.append("Trust: \(count) CA certificates (SSL_CERT_FILE=\(certFile))")
            }
            return lines.joined(separator: "\n")
        }
    }

    /// Verifies the interpreter has `_garage_tesseract` built in (Tesseract and Leptonica linked statically), that
    /// garage_rag's OCR reads through it, and that an engine starts with the English data in the framework's `tessdata`.
    public static func tesseract() -> GarageXPCSelfTest {
        GarageXPCSelfTest(name: "Tesseract", description: "The embedded Python has _garage_tesseract built in, with Tesseract linked statically, garage_rag's OCR uses it, and it loads the English data in PythonXPCService.framework's tessdata.") {
            let sys = try Python.attemptImport("sys")
            guard Bool(sys.builtin_module_names.__contains__("_garage_tesseract")) == true else {
                throw GarageXPCSelfTestFailure("_garage_tesseract is not built into the interpreter", details: "//ext/python should build it through garage_tesseract.patch")
            }
            let tesseract = try Python.attemptImport("garage_rag.extract.tesseract")
            let module = tesseract.builtin_module()
            guard String(Python.getattr(module, "__name__", "")) == "_garage_tesseract" else {
                throw GarageXPCSelfTestFailure("garage_rag reads images through something else", details: String(describing: module))
            }
            guard let datapath = String(tesseract._bundled_datapath()) else {
                throw GarageXPCSelfTestFailure("No eng.traineddata in the framework's tessdata", details: "expected beside \(String(sys[dynamicMember: "prefix"]) ?? "sys.prefix")")
            }
            // Starting an engine loads the language data; it is dropped again at once.
            _ = try module.Engine.throwing.dynamicallyCall(withArguments: [datapath, tesseract.LANGUAGE, 3])
            let version = String(module.version()) ?? "unknown"
            return ["Version: \(version)", "tessdata: \(datapath)"].joined(separator: "\n")
        }
    }

    /// Verifies the interpreter has `_garage_git` built in (libgit2 linked statically, no network transports) and that
    /// garage_rag's git attribution reads through it.
    public static func gitHistory() -> GarageXPCSelfTest {
        GarageXPCSelfTest(name: "Git History", description: "The embedded Python has _garage_git built in, with a statically linked libgit2 without HTTPS or SSH, and garage_rag's git attribution uses it.") {
            let sys = try Python.attemptImport("sys")
            guard Bool(sys.builtin_module_names.__contains__("_garage_git")) == true else {
                throw GarageXPCSelfTestFailure("_garage_git is not built into the interpreter", details: "//ext/python should build it through garage_git.patch")
            }
            let module = try Python.attemptImport("_garage_git")
            let version = String(module.version()) ?? "unknown"
            let features = Int(module.features()) ?? 0
            // GIT_FEATURE_HTTPS and GIT_FEATURE_SSH.
            if features & (1 << 1) != 0 || features & (1 << 2) != 0 {
                throw GarageXPCSelfTestFailure("_garage_git's libgit2 has a network transport", details: "features: \(features)")
            }
            let git = try Python.attemptImport("garage_rag.attribute.git")
            let reader = git.git_reader()
            guard String(Python.getattr(reader, "__name__", "")) == "_garage_git" else {
                throw GarageXPCSelfTestFailure("garage_rag reads git history through something else", details: String(describing: reader))
            }
            return ["libgit2: \(version)", "Features: \(features)"].joined(separator: "\n")
        }
    }

    /// Connects to PostgreSQL with psycopg and runs `SELECT version()` plus pgvector and Apache AGE extension probes.
    public static func database(urlProvider: @escaping @Sendable () -> String?) -> GarageXPCSelfTest {
        GarageXPCSelfTest(name: "Database Connection", description: "Opens a psycopg connection to GARAGE_DATABASE_URL, runs SELECT version() and checks the vector and age extensions.") {
            guard let raw = urlProvider(), !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw GarageXPCSelfTestSkipped("GARAGE_DATABASE_URL is not configured")
            }
            // psycopg wants a plain libpq URL; strip SQLAlchemy driver suffixes.
            var conninfo = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if conninfo.hasPrefix("postgresql+psycopg://") {
                conninfo = "postgresql://" + conninfo.dropFirst("postgresql+psycopg://".count)
            } else if conninfo.hasPrefix("postgres://") {
                conninfo = "postgresql://" + conninfo.dropFirst("postgres://".count)
            }
            let psycopg = try Python.attemptImport("psycopg")
            let conn = try psycopg.connect.throwing.dynamicallyCall(withKeywordArguments: [("conninfo", conninfo), ("connect_timeout", 5)])
            defer { _ = try? conn.close.throwing.dynamicallyCall(withArguments: []) }
            let cursor = conn.cursor()
            _ = try cursor.execute.throwing.dynamicallyCall(withArguments: ["SELECT version()"])
            let version = String(cursor.fetchone()[0]) ?? "unknown"
            _ = try cursor.execute.throwing.dynamicallyCall(withArguments: ["SELECT extversion FROM pg_extension WHERE extname = 'vector'"])
            let row = cursor.fetchone()
            let vectorVersion = row == Python.None ? "not installed" : (String(row[0]) ?? "unknown")
            _ = try cursor.execute.throwing.dynamicallyCall(withArguments: ["SELECT extversion FROM pg_extension WHERE extname = 'age'"])
            let ageRow = cursor.fetchone()
            let ageVersion = ageRow == Python.None ? "not installed" : (String(ageRow[0]) ?? "unknown")
            let redacted = Self.redactCredentials(in: conninfo)
            return "URL: \(redacted)\nServer: \(version)\npgvector: \(vectorVersion)\nApache AGE: \(ageVersion)"
        }
    }

    /// Verifies a gRPC channel to the backend becomes ready within a timeout. The backend is a
    /// separate process the app starts alongside the helpers, so at launch it can take well over a
    /// few seconds (Python start-up, then the database) before it accepts a channel.
    public static func grpcConnection(addressProvider: @escaping @Sendable () -> String?, timeoutSeconds: Double = 30) -> GarageXPCSelfTest {
        GarageXPCSelfTest(name: "gRPC Connection", description: "Opens an insecure grpc channel to the Garage backend (its socket, or host and port) and waits for it to become ready.") {
            guard let address = addressProvider() else {
                throw GarageXPCSelfTestSkipped("GARAGE_GRPC_SOCKET / GARAGE_GRPC_PORT are not configured")
            }
            let grpc = try Python.attemptImport("grpc")
            let channel = try grpc.insecure_channel.throwing.dynamicallyCall(withArguments: [address])
            defer { _ = try? channel.close.throwing.dynamicallyCall(withArguments: []) }
            let future = grpc.channel_ready_future(channel)
            do {
                _ = try future.result.throwing.dynamicallyCall(withKeywordArguments: [("timeout", timeoutSeconds)])
            } catch {
                throw GarageXPCSelfTestFailure("gRPC channel to \(address) did not become ready within \(Int(timeoutSeconds))s", details: GaragePythonRuntime.describe(error))
            }
            let grpcVersion = String(grpc.checking.__version__ ?? Python.None) ?? "unknown"
            return "Target: \(address)\ngrpcio: \(grpcVersion)\nChannel state: READY"
        }
    }

    /// Imports a service specific module (for example `garage_rag.service`).
    public static func serviceModule(_ moduleName: String, attributes: [String] = []) -> GarageXPCSelfTest {
        GarageXPCSelfTest(name: "Service Module", description: "Imports \(moduleName)\(attributes.isEmpty ? "" : " and verifies \(attributes.joined(separator: ", "))").") {
            let module = try Python.attemptImport(moduleName)
            let file = String(module.checking.__file__ ?? Python.None) ?? "?"
            var missing: [String] = []
            for attribute in attributes where module.checking[dynamicMember: attribute] == nil {
                missing.append(attribute)
            }
            if !missing.isEmpty {
                throw GarageXPCSelfTestFailure("\(moduleName) is missing: \(missing.joined(separator: ", "))", details: "Loaded from \(file)")
            }
            return "\(moduleName) <- \(file)" + (attributes.isEmpty ? "" : "\nVerified: \(attributes.joined(separator: ", "))")
        }
    }

    /// Checks that the log directory is writable (non-Python test).
    public static func logging(logFileName: String) -> GarageXPCSelfTest {
        GarageXPCSelfTest(name: "Logging", description: "Log directory is writable and unified logging is configured.", requiresPython: false) {
            let dir = GarageFileLogger.logsDirectoryURL
            let probe = dir.appendingPathComponent(".write-probe-\(ProcessInfo.processInfo.processIdentifier)")
            do {
                try "ok".write(to: probe, atomically: true, encoding: .utf8)
                try? FileManager.default.removeItem(at: probe)
            } catch {
                throw GarageXPCSelfTestFailure("Log directory is not writable: \(dir.path)", details: error.localizedDescription)
            }
            return "Log directory: \(dir.path)\nService log: \(dir.appendingPathComponent(logFileName).path)\nUnified logging subsystem: \(Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag")"
        }
    }

    static func redactCredentials(in url: String) -> String {
        guard let schemeRange = url.range(of: "://"), let at = url.range(of: "@", range: schemeRange.upperBound..<url.endIndex) else {
            return url
        }
        let userInfo = url[schemeRange.upperBound..<at.lowerBound]
        guard let colon = userInfo.firstIndex(of: ":") else { return url }
        return String(url[..<colon]) + ":***" + String(url[at.lowerBound...])
    }
}

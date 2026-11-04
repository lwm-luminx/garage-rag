import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag", category: "GarageXPCSelfTests")

/// A single self test executed inside an XPC service once it has started.
///
/// The `body` runs on the service's host thread. It returns human readable details on success and
/// throws on failure.
public struct GarageXPCSelfTest: Sendable {
    public typealias Body = @Sendable () throws -> String

    public let name: String
    public let testDescription: String
    public let body: Body

    public init(name: String, description: String, body: @escaping Body) {
        self.name = name
        self.testDescription = description
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
    /// Executes the given tests sequentially.
    public static func run(_ tests: [GarageXPCSelfTest]) -> [GarageXPCTestResult] {
        var results: [GarageXPCTestResult] = []
        results.reserveCapacity(tests.count)

        for test in tests {
            let start = CFAbsoluteTimeGetCurrent()
            let result: GarageXPCTestResult
            do {
                let details = try test.body()
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

// MARK: - Standard tests

/// Self tests every XPC service shares.
public enum GarageXPCStandardSelfTests {
    /// Checks that the log directory is writable.
    public static func logging(logFileName: String) -> GarageXPCSelfTest {
        GarageXPCSelfTest(name: "Logging", description: "Log directory is writable and unified logging is configured.") {
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
}

import Foundation
import OSLog
import Darwin
import IngestClient
import ModelDownloadClient
import LlamaClient
import PythonXPCService

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag", category: "XPCServiceManager")

/// Represents the outcome of a functional beyond-ping diagnostic test on a service.
public struct ServiceDiagnosticTestResult: Identifiable, Equatable, Sendable {
    public var id: String { serviceId }
    public let serviceId: String
    public let testName: String
    public let testDescription: String
    public let isSuccess: Bool
    public let durationMs: Double
    public let timestamp: Date
    public let summary: String
    public let details: String
    public let errorMessage: String?

    public init(
        serviceId: String,
        testName: String,
        testDescription: String,
        isSuccess: Bool,
        durationMs: Double,
        timestamp: Date = Date(),
        summary: String,
        details: String,
        errorMessage: String? = nil
    ) {
        self.serviceId = serviceId
        self.testName = testName
        self.testDescription = testDescription
        self.isSuccess = isSuccess
        self.durationMs = durationMs
        self.timestamp = timestamp
        self.summary = summary
        self.details = details
        self.errorMessage = errorMessage
    }
}

/// The runtime status of an XPC helper service.
public enum XPCServiceState: Equatable, Sendable {
    case unknown
    case checking
    case running(pid: pid_t, latencyMs: Double, response: String)
    case restarting
    case unreachable(error: String)

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    public var isChecking: Bool {
        switch self {
        case .checking, .restarting: return true
        default: return false
        }
    }

    public var title: String {
        switch self {
        case .unknown: return "Unknown"
        case .checking: return "Checking"
        case .running: return "Running"
        case .restarting: return "Restarting"
        case .unreachable: return "Unreachable"
        }
    }
}

/// Metadata and real-time state for an individual XPC helper service.
/// The functional ("beyond ping") test a service's diagnostic runs: the name and
/// description on its result, and what the Status page shows before it runs.
public struct ServiceDiagnosticTest: Equatable, Sendable {
    public let name: String
    public let description: String

    public static let selfTests = ServiceDiagnosticTest(
        name: "In-Service Self Tests",
        description: "Runs the self tests embedded in the helper (Python runtime, imports, managed services)."
    )
    public static let generic = ServiceDiagnosticTest(
        name: "Generic Service Check",
        description: "Basic ping and responsiveness verification."
    )
    public static let modelDownload = ServiceDiagnosticTest(
        name: "Payload Download & SHA-256 Checksum Test",
        description: "Downloads fixed small test payload data and validates SHA-256 cryptographic hash integrity."
    )
    public static let llama = ServiceDiagnosticTest(
        name: "Llama Tokenizer & Health Status Test",
        description: "Tests Llama inference service properties, model slots, and tokenizer on a fixed prompt."
    )

    // Fallbacks run only when a Python-hosted helper does not answer its self tests.
    public static let embed = ServiceDiagnosticTest(
        name: "Embeddings Model (mxbai-embed-xsmall) & Fixed-Value Vector Test",
        description: "Loads vector embedding module with mxbai-embed-xsmall and computes float vector coordinates for a fixed sample text."
    )
    public static let ingestPing = ServiceDiagnosticTest(
        name: "Ingest Helper Reachability Test",
        description: "Pings the ingest helper over XPC and records its reply and latency."
    )
    public static let mcpPing = ServiceDiagnosticTest(
        name: "MCP Helper Reachability Test",
        description: "Pings the MCP server helper over XPC and records its reply and latency."
    )
    public static let backend = ServiceDiagnosticTest(
        name: "Garage Backend Core Coordination Test",
        description: "Tests Core XPC daemon coordination and backend lifecycle communication."
    )

    /// The test `XPCServiceManager.runDiagnosticTest(for:)` runs for a service id or bundle id.
    public static func primary(for serviceId: String) -> ServiceDiagnosticTest {
        switch serviceId {
        case "embed-xpc", "me.rickmark.garage-rag.embed-xpc",
             "ingest-xpc", "me.rickmark.garage-rag.ingest-xpc",
             "mcp-server-xpc", "me.rickmark.garage-rag.mcp-server-xpc",
             "garage-xpc", "me.rickmark.garage-rag.xpc":
            return .selfTests
        case "model-download-xpc", "me.rickmark.garage-rag.model-download-xpc":
            return .modelDownload
        case "llama-xpc", "me.rickmark.garage-rag.llama-xpc":
            return .llama
        default:
            return .generic
        }
    }
}

public struct XPCServiceInfo: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let bundleId: String
    public let serviceDescription: String
    public var state: XPCServiceState
    public var lastChecked: Date?

    public init(
        id: String,
        name: String,
        bundleId: String,
        serviceDescription: String,
        state: XPCServiceState = .unknown,
        lastChecked: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.bundleId = bundleId
        self.serviceDescription = serviceDescription
        self.state = state
        self.lastChecked = lastChecked
    }

    public var isRunning: Bool { state.isRunning }
    public var isChecking: Bool { state.isChecking }

    public var pid: pid_t? {
        if case let .running(pid, _, _) = state { return pid }
        return nil
    }

    public var latencyMs: Double? {
        if case let .running(_, latency, _) = state { return latency }
        return nil
    }

    public var pingResponse: String? {
        if case let .running(_, _, response) = state { return response }
        return nil
    }

    public var errorMessage: String? {
        if case let .unreachable(error) = state { return error }
        return nil
    }
}

/// Thread-safe buffer that coalesces bursts of XPC stdout/stderr/log callbacks so the main actor
/// only has to apply one batched update per flush interval instead of one per raw chunk. Without
/// this, a chatty helper process can drive `didReceiveStdout`/`didReceiveStderr` at very high
/// frequency, and each call previously did its own `Task.detached` + `MainActor.run` hop to append
/// a single entry (and O(n) trim) to `logs` - pegging the main thread under bursty output.
private final class XPCLogBatchBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingManagerLogs: [LogLine] = []
    private var pendingStreamLogs: [LogLine] = []

    func appendManagerLog(_ line: LogLine) {
        lock.lock()
        pendingManagerLogs.append(line)
        lock.unlock()
    }

    func appendStreamLogs(_ lines: [LogLine]) {
        guard !lines.isEmpty else { return }
        lock.lock()
        pendingStreamLogs.append(contentsOf: lines)
        lock.unlock()
    }

    func drain() -> (managerLogs: [LogLine], streamLogs: [LogLine]) {
        lock.lock()
        let managerLogs = pendingManagerLogs
        let streamLogs = pendingStreamLogs
        pendingManagerLogs.removeAll(keepingCapacity: true)
        pendingStreamLogs.removeAll(keepingCapacity: true)
        lock.unlock()
        return (managerLogs, streamLogs)
    }
}

/// Internal adapter to receive streaming logs and stdout/stderr chunks from XPC services.
private final class XPCLogReceiverAdapter: NSObject, GarageXPCLogReceiverProtocol, @unchecked Sendable {
    private let serviceId: String
    private weak var manager: XPCServiceManager?
    private weak var osLogStreamService: OSLogStreamService?
    private let buffer = XPCLogBatchBuffer()
    private let flushTask: Task<Void, Never>

    init(serviceId: String, manager: XPCServiceManager?, osLogStreamService: OSLogStreamService? = nil) {
        self.serviceId = serviceId
        self.manager = manager
        self.osLogStreamService = osLogStreamService
        let buffer = self.buffer
        let targetSource = Self.targetLogSource(for: serviceId)
        flushTask = Task.detached(priority: .utility) { [weak manager, weak osLogStreamService] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if Task.isCancelled { break }
                let (managerLogs, streamLogs) = buffer.drain()
                guard !managerLogs.isEmpty || !streamLogs.isEmpty else { continue }
                // Hand the main actor this iteration's values: the weak captures are vars, which a
                // concurrently-executing closure may not read. Both types are @MainActor, so Sendable.
                await MainActor.run { [manager, osLogStreamService] in
                    if !managerLogs.isEmpty {
                        manager?.appendLogs(managerLogs)
                    }
                    if !streamLogs.isEmpty {
                        osLogStreamService?.appendLogs(streamLogs, for: [targetSource, .unifiedLog])
                    }
                }
            }
        }
    }

    deinit {
        flushTask.cancel()
    }

    private static func targetLogSource(for serviceId: String) -> LogsView.LogSource {
        switch serviceId {
        case "ingest-xpc", "me.rickmark.garage-rag.ingest-xpc": return .ingest
        case "embed-xpc", "me.rickmark.garage-rag.embed-xpc": return .embed
        case "mcp-server-xpc", "me.rickmark.garage-rag.mcp-server-xpc": return .mcp
        case "garage-xpc", "me.rickmark.garage-rag.xpc": return .grpc
        case "llama-xpc", "me.rickmark.garage-rag.llama-xpc": return .llama
        case "model-download-xpc", "me.rickmark.garage-rag.model-download-xpc": return .modelDownload
        default: return .unifiedLog
        }
    }

    private var targetLogSource: LogsView.LogSource { Self.targetLogSource(for: serviceId) }

    func didReceiveStdout(_ text: String) {
        let targetSource = targetLogSource
        buffer.appendManagerLog(LogLine(stream: .stdout, text: text, source: serviceId, level: .info))
        buffer.appendStreamLogs(OSLogStreamService.makeLogLines(from: text, stream: .stdout, source: targetSource.rawValue))
    }

    func didReceiveStderr(_ text: String) {
        let targetSource = targetLogSource
        buffer.appendManagerLog(LogLine(stream: .stderr, text: text, source: serviceId, level: .error))
        buffer.appendStreamLogs(OSLogStreamService.makeLogLines(from: text, stream: .stderr, source: targetSource.rawValue))
    }

    func didReceiveLog(source: String, level: String, message: String, timestamp: Double) {
        let lvl: LogLevel
        switch level.uppercased() {
        case "ERROR", "CRITICAL", "FATAL": lvl = .error
        case "WARN", "WARNING": lvl = .warning
        case "DEBUG", "TRACE": lvl = .debug
        default: lvl = .info
        }
        buffer.appendManagerLog(LogLine(stream: lvl == .error ? .stderr : .stdout, text: message, source: source, level: lvl))
        buffer.appendStreamLogs([LogLine(
            date: Date(timeIntervalSince1970: timestamp),
            stream: lvl == .error ? .stderr : .stdout,
            text: message,
            source: targetLogSource.rawValue,
            level: lvl
        )])
    }
}

/// Coordinates status checking, real-time pinging, and on-demand restarting for all macOS XPC helper services.
@MainActor
public final class XPCServiceManager: ObservableObject {
    @Published public private(set) var services: [XPCServiceInfo] = []
    @Published public private(set) var isRefreshingAll: Bool = false
    @Published public private(set) var isRestartingAll: Bool = false
    @Published public private(set) var lastRefreshedAt: Date? = nil
    @Published public private(set) var diagnosticResults: [String: ServiceDiagnosticTestResult] = [:]
    @Published public private(set) var testingServiceIds: Set<String> = []
    @Published public private(set) var isTestingAll: Bool = false
    @Published public private(set) var logs: [LogLine] = []
    @Published public private(set) var statusReports: [String: GarageXPCStatusReport] = [:]
    @Published public private(set) var restartingServiceIds: Set<String> = []

    public weak var osLogStreamService: OSLogStreamService?
    private var streamingConnections: [String: NSXPCConnection] = [:]
    private var streamingAdapters: [String: XPCLogReceiverAdapter] = [:]
    /// How long to wait before subscribing a relaunched helper to the log stream again, per service.
    /// Doubles on each interruption up to a minute, so a helper that keeps crashing is not relaunched
    /// in a tight loop, and goes back to a second once a subscription succeeds.
    private var streamingResubscribeDelays: [String: TimeInterval] = [:]

    private let maxLogLines = 4000

    public typealias PingExecutor = @Sendable (String) async throws -> (pid: pid_t, latencyMs: Double, response: String)
    public typealias KillExecutor = @Sendable (pid_t) -> Bool

    private let pingExecutor: PingExecutor
    private let killExecutor: KillExecutor
    /// Hands LlamaXPCService's endpoint to the services that load llama_xpc models on demand, which
    /// cannot look it up by name themselves. None in unit tests unless one is injected.
    let llamaEndpointBroker: LlamaEndpointBroker?

    public nonisolated static let defaultServices: [XPCServiceInfo] = [
        XPCServiceInfo(
            id: "ingest-xpc",
            name: "Document Ingestion Helper",
            bundleId: "me.rickmark.garage-rag.ingest-xpc",
            serviceDescription: "Runs multi-threaded Python ingestion pipelines with crash isolation and sandboxed filesystem access."
        ),
        XPCServiceInfo(
            id: "embed-xpc",
            name: "Text Embeddings Helper",
            bundleId: "me.rickmark.garage-rag.embed-xpc",
            serviceDescription: "Computes vector embeddings and coordinates batch text embedding models via PythonKit."
        ),
        XPCServiceInfo(
            id: "llama-xpc",
            name: "Llama LLM Inference Helper",
            bundleId: "me.rickmark.garage-rag.llama-xpc",
            serviceDescription: "Runs local GGUF models and OpenAI-compatible completions through embedded llama.cpp."
        ),
        XPCServiceInfo(
            id: "model-download-xpc",
            name: "Model Downloader Helper",
            bundleId: "me.rickmark.garage-rag.model-download-xpc",
            serviceDescription: "Handles background downloads, progress tracking, and SHA256 integrity verification for models."
        ),
        XPCServiceInfo(
            id: "mcp-server-xpc",
            name: "MCP Server Helper",
            bundleId: "me.rickmark.garage-rag.mcp-server-xpc",
            serviceDescription: "Serves Model Context Protocol (MCP) endpoints and tools for Claude, JetBrains, and external agents."
        ),
        XPCServiceInfo(
            id: "garage-xpc",
            name: "Garage Core Backend Helper",
            bundleId: "me.rickmark.garage-rag.xpc",
            serviceDescription: "Provides backend execution and service coordination for CLI and daemon operations."
        )
    ]

    public nonisolated static let knownServiceExecutableNames: [String] = [
        "GarageIngestXPCService",
        "GarageEmbedXPCService",
        "LlamaXPCService",
        "ModelDownloadXPCService",
        "GarageMCPServerService",
        "GarageXPCService"
    ]

    private static let statusCallTimeout: UInt64 = 20_000_000_000
    private static let selfTestCallTimeout: UInt64 = 180_000_000_000
    private static let restartCallTimeout: UInt64 = 120_000_000_000

    public convenience init(
        initialServices: [XPCServiceInfo] = defaultServices,
        pingExecutor: PingExecutor? = nil,
        killExecutor: KillExecutor? = nil
    ) {
        let broker: LlamaEndpointBroker?
        if isRunningInTestEnvironment {
            broker = nil
        } else {
            var bundleIds: [String: String] = [:]
            for service in initialServices {
                bundleIds[service.id] = service.bundleId
            }
            let llamaBundleId = initialServices.first { $0.id == "llama-xpc" }?.bundleId ?? LlamaXPCConstants.serviceName
            broker = LlamaEndpointBroker(connector: .xpc(llamaBundleId: llamaBundleId, receiverBundleIds: bundleIds))
        }
        self.init(initialServices: initialServices, pingExecutor: pingExecutor, killExecutor: killExecutor, llamaEndpointBroker: broker)
    }

    init(
        initialServices: [XPCServiceInfo],
        pingExecutor: PingExecutor?,
        killExecutor: KillExecutor?,
        llamaEndpointBroker: LlamaEndpointBroker?
    ) {
        self.llamaEndpointBroker = llamaEndpointBroker
        self.services = initialServices
        self.pingExecutor = pingExecutor ?? { bundleId in
            try await Self.performXPCPing(bundleId: bundleId)
        }
        self.killExecutor = killExecutor ?? { pid in
            guard pid > 0 else { return false }
            let termResult = kill(pid, SIGTERM)
            if termResult != 0 {
                _ = kill(pid, SIGKILL)
            }
            return true
        }
        llamaEndpointBroker?.setReporter { [weak self] message, isError in
            Task { @MainActor [weak self] in
                self?.appendLog(message, stream: isError ? .stderr : .stdout, source: "llama-xpc", level: isError ? .error : .info)
            }
        }
    }

    // MARK: - Logging Operations

    public func appendLog(
        _ text: String,
        stream: LogLine.Stream = .stdout,
        source: String = "xpc-services",
        level: LogLevel? = nil,
        pid: Int32? = nil
    ) {
        appendLogs([LogLine(stream: stream, text: text, source: source, level: level, pid: pid)])
    }

    /// Appends a batch of log lines with a single `@Published` mutation and a single trim, instead of one of each
    /// per line. Callers streaming bursty output (e.g. `XPCLogReceiverAdapter`) should batch before calling this.
    public func appendLogs(_ lines: [LogLine]) {
        guard !lines.isEmpty else { return }
        logs.append(contentsOf: lines)
        if logs.count > maxLogLines {
            logs.removeFirst(LogLine.trimCount(count: logs.count, limit: maxLogLines))
        }
    }

    public func clearLogs() {
        logs.removeAll()
    }

    // MARK: - Status Operations

    /// Performs a ping and latency check for a single XPC service.
    @discardableResult
    public func refresh(serviceId: String) async -> XPCServiceState {
        guard let index = services.firstIndex(where: { $0.id == serviceId || $0.bundleId == serviceId }) else {
            return .unreachable(error: "Service '\(serviceId)' not registered")
        }

        services[index].state = .checking
        let bundleId = services[index].bundleId

        do {
            logger.info("Pinging XPC service '\(bundleId, privacy: .public)'...")
            let result = try await pingExecutor(bundleId)
            let newState = XPCServiceState.running(pid: result.pid, latencyMs: result.latencyMs, response: result.response)
            services[index].state = newState
            services[index].lastChecked = Date()
            logger.info("XPC service '\(bundleId, privacy: .public)' is active (pid: \(result.pid), latency: \(String(format: "%.2f", result.latencyMs))ms)")
            appendLog("[\(services[index].name)] Active (pid: \(result.pid), latency: \(String(format: "%.2f", result.latencyMs))ms): \(result.response)", source: services[index].id, level: .info, pid: result.pid)
            _ = await fetchStatusReport(serviceId: services[index].id)
            return newState
        } catch {
            let errorMsg = error.localizedDescription
            logger.warning("XPC service '\(bundleId, privacy: .public)' ping failed: \(errorMsg, privacy: .public)")
            let newState = XPCServiceState.unreachable(error: errorMsg)
            services[index].state = newState
            services[index].lastChecked = Date()
            appendLog("[\(services[index].name)] Ping failed: \(errorMsg)", stream: .stderr, source: services[index].id, level: .error)
            return newState
        }
    }

    /// Concurrently checks the status and ping latency of all registered XPC services.
    public func refreshAll() async {
        guard !isRefreshingAll else { return }
        isRefreshingAll = true
        defer {
            isRefreshingAll = false
            lastRefreshedAt = Date()
        }

        let serviceIds = services.map { $0.id }
        await withTaskGroup(of: (String, XPCServiceState).self) { group in
            for id in serviceIds {
                group.addTask { [weak self] in
                    guard let self = self else { return (id, .unknown) }
                    let state = await self.refresh(serviceId: id)
                    return (id, state)
                }
            }
            for await _ in group {}
        }
    }

    // MARK: - Status Reports & In-Service Self Tests

    private func resolveService(_ serviceId: String) -> XPCServiceInfo? {
        services.first(where: { $0.id == serviceId || $0.bundleId == serviceId })
    }

    /// Stores a status report and surfaces failed self tests in the manager log (once per distinct test run).
    private func storeStatusReport(_ report: GarageXPCStatusReport, for service: XPCServiceInfo, forceLogFailures: Bool = false) {
        let previous = statusReports[service.id]
        statusReports[service.id] = report

        let failed = report.failedTests
        guard !failed.isEmpty else { return }
        let previousFailedNames = Set(previous?.failedTests.map { $0.name } ?? [])
        let isNewRun = previous == nil || previous?.lastTestRun != report.lastTestRun || previousFailedNames != Set(failed.map { $0.name })
        guard forceLogFailures || isNewRun else { return }

        for test in failed {
            let reason = test.errorMessage ?? test.summary
            appendLog("[\(service.name)] Self test '\(test.name)' failed (\(String(format: "%.1f", test.durationMs))ms): \(reason)", stream: .stderr, source: service.id, level: .error, pid: report.pid)
        }
    }

    /// Fetches the structured status report (lifecycle, Python runtime, managed services, self tests) of a service.
    @discardableResult
    public func fetchStatusReport(serviceId: String) async -> GarageXPCStatusReport? {
        guard let service = resolveService(serviceId) else { return nil }
        let bundleId = service.bundleId
        do {
            let json: String = try await Self.performCommonCall(bundleId: bundleId, timeoutNanoseconds: Self.statusCallTimeout) { proxy, relay in
                proxy.getServiceStatus { json in
                    relay.resume(returning: json)
                }
            }
            guard let report = GarageXPCStatusReport.decode(fromJSON: json) else {
                logger.warning("Could not decode status report from '\(bundleId, privacy: .public)'")
                appendLog("[\(service.name)] Received an undecodable status report", stream: .stderr, source: service.id, level: .warning)
                return nil
            }
            storeStatusReport(report, for: service)
            return report
        } catch {
            logger.warning("Failed to fetch status report from '\(bundleId, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            appendLog("[\(service.name)] Status report unavailable: \(error.localizedDescription)", stream: .stderr, source: service.id, level: .warning)
            return nil
        }
    }

    /// Concurrently fetches the status reports of all registered services.
    public func refreshAllStatusReports() async {
        let serviceIds = services.map { $0.id }
        await withTaskGroup(of: Void.self) { group in
            for id in serviceIds {
                group.addTask { [weak self] in
                    guard let self = self else { return }
                    _ = await self.fetchStatusReport(serviceId: id)
                }
            }
        }
    }

    /// Re-runs the in-service self tests of a helper and mirrors the outcome into `diagnosticResults`.
    @discardableResult
    public func runServiceSelfTests(serviceId: String) async -> GarageXPCStatusReport? {
        guard let service = resolveService(serviceId) else { return nil }
        let bundleId = service.bundleId
        testingServiceIds.insert(service.id)
        defer { testingServiceIds.remove(service.id) }

        appendLog("[\(service.name)] Running in-service self tests...", source: service.id, level: .info)
        let startTime = CFAbsoluteTimeGetCurrent()

        do {
            let (passed, json): (Bool, String) = try await Self.performCommonCall(bundleId: bundleId, timeoutNanoseconds: Self.selfTestCallTimeout) { proxy, relay in
                proxy.runSelfTests { passed, json in
                    relay.resume(returning: (passed, json))
                }
            }
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0

            guard let report = GarageXPCStatusReport.decode(fromJSON: json) else {
                diagnosticResults[service.id] = ServiceDiagnosticTestResult(
                    serviceId: service.id,
                    testName: ServiceDiagnosticTest.selfTests.name,
                    testDescription: ServiceDiagnosticTest.selfTests.description,
                    isSuccess: false,
                    durationMs: elapsed,
                    summary: "Self tests \(passed ? "passed" : "failed") but the report could not be decoded",
                    details: json,
                    errorMessage: "Undecodable self test report"
                )
                return nil
            }

            storeStatusReport(report, for: service, forceLogFailures: true)
            let result = Self.makeDiagnosticResult(from: report, serviceId: service.id, durationMs: elapsed)
            diagnosticResults[service.id] = result
            appendLog("[\(service.name)] \(result.summary)", stream: result.isSuccess ? .stdout : .stderr, source: service.id, level: result.isSuccess ? .info : .error, pid: report.pid)
            return report
        } catch {
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            logger.warning("Self tests failed to run on '\(bundleId, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            diagnosticResults[service.id] = ServiceDiagnosticTestResult(
                serviceId: service.id,
                testName: ServiceDiagnosticTest.selfTests.name,
                testDescription: ServiceDiagnosticTest.selfTests.description,
                isSuccess: false,
                durationMs: elapsed,
                summary: "Self tests could not be run: \(error.localizedDescription)",
                details: error.localizedDescription,
                errorMessage: error.localizedDescription
            )
            appendLog("[\(service.name)] Self tests could not be run: \(error.localizedDescription)", stream: .stderr, source: service.id, level: .error)
            return nil
        }
    }

    /// Converts an in-service status report into the legacy diagnostic result consumed by the existing UI.
    nonisolated static func makeDiagnosticResult(from report: GarageXPCStatusReport, serviceId: String, durationMs: Double) -> ServiceDiagnosticTestResult {
        let total = report.tests.count
        let passedCount = report.tests.filter { $0.status == .passed }.count
        let skippedCount = report.tests.filter { $0.status == .skipped }.count
        let failed = report.failedTests

        var lines: [String] = []
        for test in report.tests {
            lines.append("[\(test.status.rawValue.uppercased())] \(test.name): \(test.summary)")
            if test.status == .failed {
                if let err = test.errorMessage, !err.isEmpty { lines.append("    error: \(err)") }
                if !test.details.isEmpty {
                    for detailLine in test.details.components(separatedBy: .newlines) where !detailLine.isEmpty {
                        lines.append("    \(detailLine)")
                    }
                }
            }
        }
        if total == 0 {
            lines.append("The service did not report any self tests (lifecycle: \(report.lifecycle), python: \(report.python.state)).")
        }

        var summary = "\(passedCount) of \(total) self tests passed"
        if skippedCount > 0 { summary += " (\(skippedCount) skipped)" }
        let errorMessage = failed.isEmpty ? nil : failed.map { "\($0.name): \($0.errorMessage ?? $0.summary)" }.joined(separator: "; ")

        return ServiceDiagnosticTestResult(
            serviceId: serviceId,
            testName: ServiceDiagnosticTest.selfTests.name,
            testDescription: ServiceDiagnosticTest.selfTests.description,
            isSuccess: report.allTestsPassed,
            durationMs: durationMs,
            summary: summary,
            details: lines.joined(separator: "\n"),
            errorMessage: errorMessage
        )
    }

    /// Restarts the background services managed inside a helper without killing the helper process.
    @discardableResult
    public func restartManagedServices(serviceId: String, graceful: Bool) async -> (success: Bool, message: String?) {
        guard let service = resolveService(serviceId) else {
            return (false, "Service '\(serviceId)' not registered")
        }
        let bundleId = service.bundleId
        restartingServiceIds.insert(service.id)
        defer { restartingServiceIds.remove(service.id) }

        appendLog("[\(service.name)] Restarting managed services (\(graceful ? "graceful" : "forced"))...", source: service.id, level: .warning, pid: service.pid)

        let outcome: (success: Bool, message: String?)
        do {
            outcome = try await Self.performCommonCall(bundleId: bundleId, timeoutNanoseconds: Self.restartCallTimeout) { proxy, relay in
                proxy.restartServices(graceful: graceful) { success, message in
                    relay.resume(returning: (success: success, message: message))
                }
            }
        } catch {
            outcome = (false, error.localizedDescription)
        }

        appendLog(
            "[\(service.name)] Managed services restart \(outcome.success ? "succeeded" : "failed")\(outcome.message.map { ": \($0)" } ?? "")",
            stream: outcome.success ? .stdout : .stderr,
            source: service.id,
            level: outcome.success ? .info : .error
        )
        _ = await fetchStatusReport(serviceId: service.id)
        return outcome
    }

    // MARK: - Restart Operations

    /// Restarts an individual XPC helper service by terminating its process and re-initiating connection.
    @discardableResult
    public func restart(serviceId: String) async -> Bool {
        guard let index = services.firstIndex(where: { $0.id == serviceId || $0.bundleId == serviceId }) else {
            return false
        }

        let service = services[index]
        services[index].state = .restarting
        logger.info("Restarting XPC service '\(service.bundleId, privacy: .public)'...")
        appendLog("[\(service.name)] Restarting service...", source: service.id, level: .warning, pid: service.pid)

        // If currently running with known PID, send termination signal. A service the app hosts
        // itself (GarageInProcessServices) answers with the app's own pid, which is never killed.
        if let currentPid = service.pid, currentPid > 0, currentPid != getpid() {
            logger.info("Terminating existing process for '\(service.bundleId, privacy: .public)' (pid: \(currentPid))")
            _ = killExecutor(currentPid)
            appendLog("[\(service.name)] Sent termination signal to pid \(currentPid)", source: service.id, level: .warning, pid: currentPid)
        }

        // Wait a brief moment for launchd to clean up the dead process
        try? await Task.sleep(nanoseconds: 300_000_000)

        // Ping the service to spawn a fresh instance via launchd / XPC runtime
        let newState = await refresh(serviceId: service.id)
        // A relaunched LlamaXPCService has a new endpoint, a relaunched receiver has none. The
        // broker also notices the lost connection; this covers a kill it did not see.
        if service.id == "llama-xpc" {
            llamaEndpointBroker?.handOverAgain(refetch: true)
        } else if LlamaEndpointBroker.receiverServiceIds.contains(service.id) {
            llamaEndpointBroker?.handOverAgain()
        }
        appendLog("[\(service.name)] Restart finished with state: \(newState.title)", source: service.id, level: newState.isRunning ? .info : .error)
        return newState.isRunning
    }

    /// Restarts all registered XPC helper services.
    public func restartAll() async {
        guard !isRestartingAll else { return }
        isRestartingAll = true
        defer {
            isRestartingAll = false
            lastRefreshedAt = Date()
        }

        appendLog("Restarting all XPC helper services...", source: "xpc-services", level: .warning)
        let serviceIds = services.map { $0.id }
        for id in serviceIds {
            _ = await restart(serviceId: id)
        }
    }

    // MARK: - Termination Operations

    /// Terminates all known running XPC helper services and drops the live log streaming connections.
    public func terminateAll() {
        appendLog("Terminating all active XPC helper processes...", source: "xpc-services", level: .warning)
        // First, so the broker does not relaunch the helpers it sees go away.
        llamaEndpointBroker?.stop()
        stopAllStreaming()
        for service in services {
            if let currentPid = service.pid, currentPid > 0, currentPid != getpid() {
                logger.info("Terminating XPC service '\(service.bundleId, privacy: .public)' (pid: \(currentPid))")
                _ = killExecutor(currentPid)
                appendLog("[\(service.name)] Terminated process pid \(currentPid)", source: service.id, level: .warning, pid: currentPid)
            }
        }
        Self.stopAnyRunningInstances()
    }

    /// Finds and terminates any active Garage XPC service helper processes across the system.
    public static func stopAnyRunningInstances() {
        // This walks the whole process table and SIGTERM/SIGKILLs by executable name; never do that from a unit test.
        guard !isRunningInTestEnvironment else { return }
        let targetNames = Set(knownServiceExecutableNames)
        var pids = [pid_t](repeating: 0, count: 2048)
        let bytesReturned = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(MemoryLayout<pid_t>.size * pids.count))
        guard bytesReturned > 0 else { return }

        let count = Int(bytesReturned) / MemoryLayout<pid_t>.size
        let currentPid = getpid()
        var matchedPids: [pid_t] = []

        for i in 0..<count {
            let pid = pids[i]
            guard pid > 0, pid != currentPid else { continue }
            var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let pathLen = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            if pathLen > 0 {
                let path = String(cString: pathBuffer)
                let name = (path as NSString).lastPathComponent
                if targetNames.contains(name) {
                    matchedPids.append(pid)
                }
            }
        }

        for pid in matchedPids {
            kill(pid, SIGTERM)
        }

        if !matchedPids.isEmpty {
            usleep(50_000)
            for pid in matchedPids {
                if kill(pid, 0) == 0 {
                    kill(pid, SIGKILL)
                }
            }
        }
    }

    // MARK: - Live XPC Log Streaming Connections

    /// Starts a continuous background XPC connection to stream logs and output chunks in real-time.
    public func startStreamingLogs(for serviceId: String) {
        guard let service = services.first(where: { $0.id == serviceId || $0.bundleId == serviceId }) else { return }
        let key = service.id
        if let existing = streamingConnections[key] {
            existing.invalidate()
        }

        let bundleId = service.bundleId
        let connection = GarageInProcessServices.makeConnection(serviceName: bundleId)
        let adapter = XPCLogReceiverAdapter(serviceId: service.id, manager: self, osLogStreamService: osLogStreamService)
        streamingAdapters[key] = adapter

        connection.remoteObjectInterface = NSXPCInterface(with: GarageCommonXPCServiceProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: GarageXPCLogReceiverProtocol.self)
        connection.exportedObject = adapter

        // An interruption means the helper exited (a crash, a restart, the system reclaiming it). The
        // connection stays usable, but the next instance knows nothing of this subscription, so its
        // lines would never reach the Logs page: subscribe again, which also relaunches it.
        connection.interruptionHandler = { [weak self, weak connection] in
            logger.warning("Live log streaming connection for '\(bundleId, privacy: .public)' was interrupted")
            Task { @MainActor [weak self] in
                guard let self, let connection, self.streamingConnections[key] === connection else { return }
                let delay = self.streamingResubscribeDelays[key] ?? 1
                self.streamingResubscribeDelays[key] = min(delay * 2, 60)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard self.streamingConnections[key] === connection else { return }
                self.subscribeToLogStream(on: connection, key: key, bundleId: bundleId)
            }
        }
        // Only drop the registry entry if it still belongs to this connection: a restart replaces the entry with a
        // new connection, and the old connection's invalidation must not remove the new one.
        connection.invalidationHandler = { [weak self, weak connection] in
            Task { @MainActor [weak self] in
                guard let self = self, let connection = connection, self.streamingConnections[key] === connection else { return }
                self.streamingConnections.removeValue(forKey: key)
                self.streamingAdapters.removeValue(forKey: key)
            }
        }

        connection.resume()
        streamingConnections[key] = connection
        subscribeToLogStream(on: connection, key: key, bundleId: bundleId)
    }

    /// Opts `connection` in to live log streaming on the service side.
    private func subscribeToLogStream(on connection: NSXPCConnection, key: String, bundleId: String) {
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            logger.debug("Failed to initialize log streaming proxy for '\(bundleId, privacy: .public)': \(error.localizedDescription, privacy: .public)")
        }) as? GarageCommonXPCServiceProtocol else { return }
        proxy.subscribeToLogStream { [weak self] subscribed in
            if subscribed {
                logger.debug("Live log streaming successfully registered for '\(bundleId, privacy: .public)'")
                Task { @MainActor [weak self] in self?.streamingResubscribeDelays[key] = nil }
            } else {
                logger.warning("Service '\(bundleId, privacy: .public)' declined the log streaming subscription")
            }
        }
    }

    /// Starts streaming logs for all known XPC helper services, and the LlamaXPCService endpoint
    /// hand-over (`LlamaEndpointBroker`), which every launch path and a failed reset go through.
    public func startStreamingAllServices() {
        for service in services {
            startStreamingLogs(for: service.id)
        }
        llamaEndpointBroker?.start()
    }

    /// Stops live log streaming for a given service.
    public func stopStreamingLogs(for serviceId: String) {
        let key = services.first(where: { $0.id == serviceId || $0.bundleId == serviceId })?.id ?? serviceId
        streamingResubscribeDelays.removeValue(forKey: key)
        if let connection = streamingConnections.removeValue(forKey: key) {
            connection.invalidate()
        }
        streamingAdapters.removeValue(forKey: key)
    }

    /// Stops all live log streaming connections.
    public func stopAllStreaming() {
        for (_, conn) in streamingConnections {
            conn.invalidate()
        }
        streamingConnections.removeAll()
        streamingAdapters.removeAll()
        streamingResubscribeDelays.removeAll()
    }

    // MARK: - Static XPC Ping Implementation

    private final class ContinuationRelay<T>: @unchecked Sendable {
        private var continuation: CheckedContinuation<T, Error>?
        private let lock = NSLock()

        init(_ continuation: CheckedContinuation<T, Error>) {
            self.continuation = continuation
        }

        func resume(returning value: T) {
            lock.lock()
            let cont = continuation
            continuation = nil
            lock.unlock()
            cont?.resume(returning: value)
        }

        func resume(throwing error: Error) {
            lock.lock()
            let cont = continuation
            continuation = nil
            lock.unlock()
            cont?.resume(throwing: error)
        }
    }

    /// Invalidates `connection` (which fails every call pending on it) once the timeout elapses, unless the returned
    /// task is cancelled first. Every one-shot helper call goes through this so a hung helper cannot wedge a caller.
    private static func invalidate(_ connection: NSXPCConnection, bundleId: String, afterNanoseconds timeoutNanoseconds: UInt64) -> Task<Void, Error> {
        Task {
            try await Task.sleep(nanoseconds: timeoutNanoseconds)
            logger.warning("XPC call to '\(bundleId, privacy: .public)' timed out; invalidating connection")
            connection.invalidate()
        }
    }

    /// Opens a one-shot connection using the common protocol, performs the bundle handshake, and runs `body`.
    /// The connection is invalidated (which fails the pending call) if no reply arrives within the timeout.
    private static func performCommonCall<T>(
        bundleId: String,
        timeoutNanoseconds: UInt64,
        _ body: @escaping (GarageCommonXPCServiceProtocol, ContinuationRelay<T>) -> Void
    ) async throws -> T {
        let connection = GarageInProcessServices.makeConnection(serviceName: bundleId)
        connection.remoteObjectInterface = NSXPCInterface(with: GarageCommonXPCServiceProtocol.self)
        connection.resume()
        defer { connection.invalidate() }

        let timeoutTask = invalidate(connection, bundleId: bundleId, afterNanoseconds: timeoutNanoseconds)
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            let relay = ContinuationRelay(continuation)

            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                relay.resume(throwing: error)
            }) as? GarageCommonXPCServiceProtocol else {
                relay.resume(throwing: NSError(domain: "XPCServiceManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create XPC proxy for \(bundleId)"]))
                return
            }

            body(proxy, relay)
        }
    }

    private static func performXPCPing(bundleId: String) async throws -> (pid: pid_t, latencyMs: Double, response: String) {
        let startTime = CFAbsoluteTimeGetCurrent()
        let connection = GarageInProcessServices.makeConnection(serviceName: bundleId)
        connection.remoteObjectInterface = NSXPCInterface(with: GarageCommonXPCServiceProtocol.self)
        connection.resume()
        defer { connection.invalidate() }

        // Same timeout as the other status calls: a helper that never answers must not wedge refreshAll().
        let timeoutTask = invalidate(connection, bundleId: bundleId, afterNanoseconds: statusCallTimeout)
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            let relay = ContinuationRelay(continuation)

            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                logger.error("XPC remote object proxy error for service '\(bundleId, privacy: .public)': \(error.localizedDescription, privacy: .public)")
                relay.resume(throwing: error)
            }) as? GarageCommonXPCServiceProtocol else {
                let err = NSError(domain: "XPCServiceManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create XPC proxy for \(bundleId)"])
                logger.error("\(err.localizedDescription, privacy: .public)")
                relay.resume(throwing: err)
                return
            }

            proxy.ping { reply in
                let durationMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
                let pid = connection.processIdentifier
                relay.resume(returning: (pid: pid, latencyMs: durationMs, response: reply))
            }
        }
    }

    // MARK: - Diagnostic Functional Tests (Beyond-Ping)

    /// Runs an in-depth functional diagnostic test (beyond a simple ping) for a specific service.
    @discardableResult
    public func runDiagnosticTest(for serviceId: String) async -> ServiceDiagnosticTestResult {
        testingServiceIds.insert(serviceId)
        defer { testingServiceIds.remove(serviceId) }

        appendLog("[\(serviceId)] Starting diagnostic test...", source: serviceId, level: .info)

        let result: ServiceDiagnosticTestResult
        switch serviceId {
        case "embed-xpc", "me.rickmark.garage-rag.embed-xpc",
             "ingest-xpc", "me.rickmark.garage-rag.ingest-xpc",
             "mcp-server-xpc", "me.rickmark.garage-rag.mcp-server-xpc",
             "garage-xpc", "me.rickmark.garage-rag.xpc":
            result = await runSelfTestDiagnostic(for: serviceId)
        case "model-download-xpc", "me.rickmark.garage-rag.model-download-xpc":
            result = await runModelDownloadDiagnosticTest()
            _ = await fetchStatusReport(serviceId: serviceId)
        case "llama-xpc", "me.rickmark.garage-rag.llama-xpc":
            result = await runLlamaDiagnosticTest()
            _ = await fetchStatusReport(serviceId: serviceId)
        default:
            result = ServiceDiagnosticTestResult(
                serviceId: serviceId,
                testName: ServiceDiagnosticTest.generic.name,
                testDescription: ServiceDiagnosticTest.generic.description,
                isSuccess: false,
                durationMs: 0,
                summary: "Unknown service ID: \(serviceId)",
                details: "No diagnostic test configured for \(serviceId)",
                errorMessage: "Unknown service"
            )
        }

        diagnosticResults[serviceId] = result
        let stream: LogLine.Stream = result.isSuccess ? .stdout : .stderr
        let level: LogLevel = result.isSuccess ? .info : .error
        appendLog("[\(result.serviceId)] Diagnostic '\(result.testName)' \(result.isSuccess ? "passed" : "failed") (\(String(format: "%.1f", result.durationMs))ms): \(result.summary)\n\(result.details)", stream: stream, source: result.serviceId, level: level)
        return result
    }

    /// Runs functional diagnostic tests on all registered services concurrently.
    public func runAllDiagnosticTests() async {
        guard !isTestingAll else { return }
        isTestingAll = true
        defer { isTestingAll = false }

        let ids = services.map { $0.id }
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { [weak self] in
                    guard let self = self else { return }
                    _ = await self.runDiagnosticTest(for: id)
                }
            }
        }
    }

    /// Diagnostic for helpers built on the shared Python runtime base: run the in-service self tests and
    /// fall back to the legacy bespoke check when the helper does not answer with a report.
    private func runSelfTestDiagnostic(for serviceId: String) async -> ServiceDiagnosticTestResult {
        let resolvedId = resolveService(serviceId)?.id ?? serviceId
        if await runServiceSelfTests(serviceId: serviceId) != nil, let converted = diagnosticResults[resolvedId] {
            return converted
        }
        let failure = diagnosticResults[resolvedId]

        let legacy: ServiceDiagnosticTestResult
        switch resolvedId {
        case "embed-xpc": legacy = await runEmbedDiagnosticTest()
        case "ingest-xpc": legacy = await runIngestDiagnosticTest()
        case "mcp-server-xpc": legacy = await runMCPDiagnosticTest()
        default: legacy = await runGarageBackendDiagnosticTest()
        }

        guard let failure = failure else { return legacy }
        return ServiceDiagnosticTestResult(
            serviceId: legacy.serviceId,
            testName: legacy.testName,
            testDescription: legacy.testDescription,
            isSuccess: false,
            durationMs: legacy.durationMs + failure.durationMs,
            summary: failure.summary,
            details: "\(failure.details)\n\nFallback check '\(legacy.testName)': \(legacy.summary)\n\(legacy.details)",
            errorMessage: failure.errorMessage ?? legacy.errorMessage
        )
    }

    private func runEmbedDiagnosticTest() async -> ServiceDiagnosticTestResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        let bundleId = "me.rickmark.garage-rag.embed-xpc"
        let testString = "Garage vector embedding verification test."

        do {
            let connection = GarageInProcessServices.makeConnection(serviceName: bundleId)
            connection.remoteObjectInterface = NSXPCInterface(with: GarageEmbedXPCServiceProtocol.self)
            connection.resume()
            defer { connection.invalidate() }
            let timeoutTask = Self.invalidate(connection, bundleId: bundleId, afterNanoseconds: Self.selfTestCallTimeout)
            defer { timeoutTask.cancel() }

            let (success, details): (Bool, String) = try await withCheckedThrowingContinuation { continuation in
                let relay = ContinuationRelay(continuation)
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                    relay.resume(throwing: error)
                }) as? GarageEmbedXPCServiceProtocol else {
                    relay.resume(throwing: NSError(domain: "EmbedTest", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create Embed XPC proxy"]))
                    return
                }

                proxy.embedTexts([testString], model: "mxbai-embed-xsmall") { isOk, output in
                    relay.resume(returning: (isOk, output ?? "No output"))
                }
            }

            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            let summary = success ? "Model mxbai-embed-xsmall loaded & embedded test string in \(String(format: "%.1f", elapsed))ms" : "Embedding computation failed"
            return ServiceDiagnosticTestResult(
                serviceId: "embed-xpc",
                testName: ServiceDiagnosticTest.embed.name,
                testDescription: ServiceDiagnosticTest.embed.description,
                isSuccess: success,
                durationMs: elapsed,
                summary: summary,
                details: "Model: mxbai-embed-xsmall\nInput text: \"\(testString)\"\nResult: \(details)\nLatency: \(String(format: "%.2f", elapsed)) ms"
            )
        } catch {
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            return ServiceDiagnosticTestResult(
                serviceId: "embed-xpc",
                testName: ServiceDiagnosticTest.embed.name,
                testDescription: ServiceDiagnosticTest.embed.description,
                isSuccess: false,
                durationMs: elapsed,
                summary: "Embed XPC service test failed: \(error.localizedDescription)",
                details: (error as NSError).userInfo["XPCDiagnosticReport"] as? String ?? error.localizedDescription,
                errorMessage: error.localizedDescription
            )
        }
    }

    private func runModelDownloadDiagnosticTest() async -> ServiceDiagnosticTestResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        do {
            let client = ModelDownloadClient()
            let (isValid, details) = try await client.testDownloadAndVerifySha256()
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            let summary = isValid ? "Payload downloaded and SHA-256 hash verified in \(String(format: "%.1f", elapsed))ms" : "SHA-256 integrity verification failed"
            return ServiceDiagnosticTestResult(
                serviceId: "model-download-xpc",
                testName: ServiceDiagnosticTest.modelDownload.name,
                testDescription: ServiceDiagnosticTest.modelDownload.description,
                isSuccess: isValid,
                durationMs: elapsed,
                summary: summary,
                details: "\(details)\nLatency: \(String(format: "%.2f", elapsed)) ms"
            )
        } catch {
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            return ServiceDiagnosticTestResult(
                serviceId: "model-download-xpc",
                testName: ServiceDiagnosticTest.modelDownload.name,
                testDescription: ServiceDiagnosticTest.modelDownload.description,
                isSuccess: false,
                durationMs: elapsed,
                summary: "Download test failed: \(error.localizedDescription)",
                details: error.localizedDescription,
                errorMessage: error.localizedDescription
            )
        }
    }

    /// Whether the engine's health JSON (`LlamaCppEngine.handleHealth`) says a model is loaded:
    /// status "ok" is true, "no_model_loaded" or "loading model" is false. Anything else (no reply,
    /// not JSON, no or an unknown status) throws, so a broken health route fails the test rather
    /// than reading as an engine with no model.
    nonisolated static func llamaHealthReportsLoadedModel(_ json: String?) throws -> Bool {
        guard let json, let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = object["status"] as? String
        else {
            throw NSError(domain: "LlamaTest", code: -2, userInfo: [NSLocalizedDescriptionKey: "Llama health returned no status: \(json ?? "no reply")"])
        }
        switch status {
        case "ok": return true
        case "no_model_loaded", "loading model": return false
        default:
            throw NSError(domain: "LlamaTest", code: -3, userInfo: [NSLocalizedDescriptionKey: "Llama health returned an unknown status: \(status)"])
        }
    }

    private func runLlamaDiagnosticTest() async -> ServiceDiagnosticTestResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        let bundleId = "me.rickmark.garage-rag.llama-xpc"
        do {
            let connection = GarageInProcessServices.makeConnection(serviceName: bundleId)
            connection.remoteObjectInterface = NSXPCInterface(with: LlamaXPCServiceProtocol.self)
            connection.resume()
            defer { connection.invalidate() }
            let timeoutTask = Self.invalidate(connection, bundleId: bundleId, afterNanoseconds: Self.selfTestCallTimeout)
            defer { timeoutTask.cancel() }

            let pingResponse: String = try await withCheckedThrowingContinuation { continuation in
                let relay = ContinuationRelay(continuation)
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                    relay.resume(throwing: error)
                }) as? LlamaXPCServiceProtocol else {
                    relay.resume(throwing: NSError(domain: "LlamaTest", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create Llama XPC proxy"]))
                    return
                }
                proxy.ping { reply in relay.resume(returning: reply) }
            }

            let healthResponse: String? = try await withCheckedThrowingContinuation { continuation in
                let relay = ContinuationRelay(continuation)
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                    relay.resume(throwing: error)
                }) as? LlamaXPCServiceProtocol else {
                    relay.resume(returning: nil)
                    return
                }
                proxy.health { reply, err in
                    if let err = err { relay.resume(throwing: err) }
                    else { relay.resume(returning: reply) }
                }
            }

            // Tokenizing needs a loaded model. With none loaded (no default model yet, or before its
            // load finishes) the engine is still healthy, so the tokenizer check is skipped, as the
            // service's own Model File self test is, instead of failing the row.
            let modelLoaded = try Self.llamaHealthReportsLoadedModel(healthResponse)
            var tokenizeResponse: String?
            if modelLoaded {
                tokenizeResponse = try await withCheckedThrowingContinuation { continuation in
                    let relay = ContinuationRelay(continuation)
                    guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                        relay.resume(throwing: error)
                    }) as? LlamaXPCServiceProtocol else {
                        relay.resume(returning: nil)
                        return
                    }
                    proxy.tokenize(requestJson: "{\"content\": \"Garage local AI prompt test.\"}") { reply, err in
                        if let err = err { relay.resume(throwing: err) }
                        else { relay.resume(returning: reply) }
                    }
                }
            }

            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            var details = "Ping response: \(pingResponse)\n"
            if let health = healthResponse { details += "Health status: \(health)\n" }
            if let tok = tokenizeResponse {
                details += "Tokenize test: \(tok)\n"
            } else if !modelLoaded {
                details += "Tokenize test: skipped, no model loaded\n"
            }
            details += "Latency: \(String(format: "%.2f", elapsed)) ms"

            return ServiceDiagnosticTestResult(
                serviceId: "llama-xpc",
                testName: ServiceDiagnosticTest.llama.name,
                testDescription: ServiceDiagnosticTest.llama.description,
                isSuccess: true,
                durationMs: elapsed,
                summary: modelLoaded
                    ? "Llama XPC tokenizer & health check completed in \(String(format: "%.1f", elapsed))ms"
                    : "Llama XPC health check completed in \(String(format: "%.1f", elapsed))ms; tokenizer skipped, no model loaded",
                details: details
            )
        } catch {
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            return ServiceDiagnosticTestResult(
                serviceId: "llama-xpc",
                testName: ServiceDiagnosticTest.llama.name,
                testDescription: ServiceDiagnosticTest.llama.description,
                isSuccess: false,
                durationMs: elapsed,
                summary: "Llama XPC test failed: \(error.localizedDescription)",
                details: (error as NSError).userInfo["XPCDiagnosticReport"] as? String ?? error.localizedDescription,
                errorMessage: error.localizedDescription
            )
        }
    }

    private func runIngestDiagnosticTest() async -> ServiceDiagnosticTestResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        let bundleId = "me.rickmark.garage-rag.ingest-xpc"

        // 1. Perform XPC Ping
        var pingResult: String?
        var pingErr: Error?
        do {
            let (_, _, response) = try await Self.performXPCPing(bundleId: bundleId)
            pingResult = response
        } catch {
            pingErr = error
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
        let isSuccess = pingErr == nil

        var lines: [String] = []
        lines.append("Ingest XPC Ping: \(pingResult ?? "Failed (\(pingErr?.localizedDescription ?? "unknown"))")")
        lines.append("\nLatency: \(String(format: "%.2f", elapsed)) ms")

        let summary = isSuccess ? "Ingest service check completed in \(String(format: "%.1f", elapsed))ms" : "Ingest service check failed: \(pingErr?.localizedDescription ?? "Unreachable")"

        return ServiceDiagnosticTestResult(
            serviceId: "ingest-xpc",
            testName: ServiceDiagnosticTest.ingestPing.name,
            testDescription: ServiceDiagnosticTest.ingestPing.description,
            isSuccess: isSuccess,
            durationMs: elapsed,
            summary: summary,
            details: lines.joined(separator: "\n"),
            errorMessage: pingErr?.localizedDescription
        )
    }

    private func runMCPDiagnosticTest() async -> ServiceDiagnosticTestResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        let bundleId = "me.rickmark.garage-rag.mcp-server-xpc"

        var pingResult: String?
        var pingErr: Error?
        do {
            let (_, _, response) = try await Self.performXPCPing(bundleId: bundleId)
            pingResult = response
        } catch {
            pingErr = error
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
        let isSuccess = pingErr == nil

        var lines: [String] = []
        lines.append("MCP Server XPC: \(pingResult ?? "Unreachable (\(pingErr?.localizedDescription ?? "error"))")")
        lines.append("Latency: \(String(format: "%.2f", elapsed)) ms")

        let summary = isSuccess ? "MCP helper ping completed in \(String(format: "%.1f", elapsed))ms" : "MCP server check failed: \(pingErr?.localizedDescription ?? "Unreachable")"

        return ServiceDiagnosticTestResult(
            serviceId: "mcp-server-xpc",
            testName: ServiceDiagnosticTest.mcpPing.name,
            testDescription: ServiceDiagnosticTest.mcpPing.description,
            isSuccess: isSuccess,
            durationMs: elapsed,
            summary: summary,
            details: lines.joined(separator: "\n"),
            errorMessage: pingErr?.localizedDescription
        )
    }

    private func runGarageBackendDiagnosticTest() async -> ServiceDiagnosticTestResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        let bundleId = "me.rickmark.garage-rag.xpc"

        do {
            let connection = GarageInProcessServices.makeConnection(serviceName: bundleId)
            connection.remoteObjectInterface = NSXPCInterface(with: GarageXPCServiceProtocol.self)
            connection.resume()
            defer { connection.invalidate() }
            let timeoutTask = Self.invalidate(connection, bundleId: bundleId, afterNanoseconds: Self.selfTestCallTimeout)
            defer { timeoutTask.cancel() }

            let (success, summaryText, detailsText): (Bool, String, String) = try await withCheckedThrowingContinuation { continuation in
                let relay = ContinuationRelay(continuation)
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                    relay.resume(throwing: error)
                }) as? GarageXPCServiceProtocol else {
                    relay.resume(throwing: NSError(domain: "GarageXPCTest", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create GarageXPC proxy"]))
                    return
                }

                proxy.runDiagnostic { isOk, sum, det in
                    relay.resume(returning: (isOk, sum ?? (isOk ? "Garage backend healthy" : "Diagnostic failed"), det ?? ""))
                }
            }

            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            var lines: [String] = []
            lines.append("Garage Core Backend XPC: \(summaryText)")
            if !detailsText.isEmpty {
                lines.append("Details: \(detailsText)")
            }
            lines.append("Latency: \(String(format: "%.2f", elapsed)) ms")

            return ServiceDiagnosticTestResult(
                serviceId: "garage-xpc",
                testName: ServiceDiagnosticTest.backend.name,
                testDescription: ServiceDiagnosticTest.backend.description,
                isSuccess: success,
                durationMs: elapsed,
                summary: "\(summaryText) in \(String(format: "%.1f", elapsed))ms",
                details: lines.joined(separator: "\n"),
                errorMessage: success ? nil : summaryText
            )
        } catch {
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            return ServiceDiagnosticTestResult(
                serviceId: "garage-xpc",
                testName: ServiceDiagnosticTest.backend.name,
                testDescription: ServiceDiagnosticTest.backend.description,
                isSuccess: false,
                durationMs: elapsed,
                summary: "Garage backend helper check failed: \(error.localizedDescription)",
                details: "Error: \(error.localizedDescription)\nLatency: \(String(format: "%.2f", elapsed)) ms",
                errorMessage: error.localizedDescription
            )
        }
    }
}

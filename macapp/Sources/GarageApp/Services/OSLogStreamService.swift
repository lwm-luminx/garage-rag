import Foundation
import OSLog
import Combine
import PythonXPCService

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag", category: "OSLogStreamService")

/// Time window presets for fetching historical unified logs.
public enum OSLogTimeWindow: String, CaseIterable, Identifiable, Sendable {
    case recent1m = "1 min"
    case recent5m = "5 mins"
    case recent15m = "15 mins"
    case recent1h = "1 hour"
    case recent24h = "24 hours"

    public var id: String { rawValue }

    public var interval: TimeInterval {
        switch self {
        case .recent1m: return 60
        case .recent5m: return 300
        case .recent15m: return 900
        case .recent1h: return 3600
        case .recent24h: return 86400
        }
    }
}

/// A log line and the Logs page sources it belongs to.
public struct RoutedLogLine: Sendable {
    public let line: LogLine
    public let targets: Set<LogsView.LogSource>
}

/// A service that continuously queries and streams real-time log entries from Apple's Unified Logging System (`OSLogStore`),
/// distributing logs to per-service streams.
///
/// `OSLogStore(scope: .currentProcessIdentifier)` sees only this process: the app logs everything under its bundle
/// identifier, and `targetSources` routes each entry by category. Helper processes are not visible here; their logs
/// arrive over the XPC services' log streams and from the files `loadAllPersistedLogs` reads.
@MainActor
public final class OSLogStreamService: ObservableObject {
    @Published public private(set) var serviceLogs: [LogsView.LogSource: [LogLine]] = [:]
    @Published public private(set) var isStreaming: Bool = false
    @Published public private(set) var isPaused: Bool = true
    @Published public private(set) var lastPolledDate: Date? = nil

    /// Everything this process logs under the app's subsystems.
    nonisolated static let appPredicateFormat = "subsystem BEGINSWITH 'me.rickmark.garage'"

    private var streamTask: Task<Void, Never>? = nil
    private var seenLogKeys: Set<String> = []
    private var seenLogKeyQueue: [String] = []
    private let maxSeenKeys = 5000
    private let maxLogLinesPerService = 4000
    private var lastStreamDate: Date = Date().addingTimeInterval(-300)

    public init(startStreaming: Bool = false) {
        if startStreaming {
            self.startStreaming(paused: true)
        }
    }

    deinit {
        streamTask?.cancel()
    }

    /// Returns all accumulated log lines across unified logging.
    public var logs: [LogLine] {
        logs(for: .unifiedLog)
    }

    /// Returns the accumulated log lines for a specific log source.
    public func logs(for source: LogsView.LogSource) -> [LogLine] {
        serviceLogs[source] ?? []
    }

    // MARK: - Streaming Controls

    /// Starts polling `OSLogStore` for new log entries starting from `since`.
    public func startStreaming(since startDate: Date = Date().addingTimeInterval(-300), pollInterval: TimeInterval = 0.25, paused: Bool = true) {
        stopStreaming()
        isStreaming = true
        isPaused = paused
        lastStreamDate = startDate

        guard #available(macOS 12.0, *) else { return }

        // Detached: reading OSLogStore takes a while, and on the main actor it stalled the whole app.
        streamTask = Task.detached(priority: .utility) { [weak self] in
            let predicate = NSPredicate(format: Self.appPredicateFormat)
            guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else {
                logger.debug("OSLogStreamService: Failed to open OSLogStore")
                return
            }

            var lastDate = startDate
            var lastPosition = store.position(date: startDate)

            while !Task.isCancelled {
                guard let self = self else { break }

                let paused = await MainActor.run { self.isPaused }
                if !paused {
                    do {
                        let entries = try store.getEntries(at: lastPosition, matching: predicate)
                        var maxDate = lastDate
                        var routed: [RoutedLogLine] = []

                        for entry in entries {
                            if let line = Self.routedLine(for: entry) {
                                routed.append(line)
                            }
                            if entry.date > maxDate {
                                maxDate = entry.date
                            }
                        }

                        if !routed.isEmpty {
                            await self.appendRouted(routed)
                        }

                        lastDate = maxDate
                        lastPosition = store.position(date: lastDate)
                        await MainActor.run {
                            self.lastPolledDate = Date()
                            self.lastStreamDate = lastDate
                        }
                    } catch {
                        logger.debug("OSLogStreamService: OSLogStore polling error: \(error.localizedDescription, privacy: .public)")
                    }
                }

                try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            }
        }
    }

    /// Stops polling `OSLogStore`.
    public func stopStreaming() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        isPaused = true
    }

    /// Pauses streaming without cancelling the task.
    public func pauseStreaming() {
        isPaused = true
    }

    /// Resumes streaming if paused.
    public func resumeStreaming() {
        isPaused = false
    }

    /// Toggles between paused and active streaming.
    public func togglePause() {
        if !isStreaming {
            startStreaming(since: lastStreamDate)
        } else {
            isPaused.toggle()
        }
    }

    /// Drains recent entries from `OSLogStore` within a given time window, routing each to its sources.
    /// The store is read off the main actor and the entries are added in one batch: a window holds
    /// thousands of entries, and reading and adding them one by one on the main actor hung the app.
    @discardableResult
    public func fetchRecentLogs(timeWindow: TimeInterval = 300) -> Task<Void, Never> {
        let startDate = Date().addingTimeInterval(-timeWindow)
        return Task { [weak self] in
            let routed = await Task.detached(priority: .userInitiated) { () -> [RoutedLogLine]? in
                guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return nil }
                do {
                    let entries = try store.getEntries(
                        at: store.position(date: startDate),
                        matching: NSPredicate(format: Self.appPredicateFormat)
                    )
                    return entries.compactMap { Self.routedLine(for: $0) }
                } catch {
                    logger.debug("OSLogStreamService: OSLogStore fetch failed: \(error.localizedDescription, privacy: .public)")
                    return nil
                }
            }.value
            guard let self, let routed else { return }
            self.appendRouted(routed)
            self.lastPolledDate = Date()
        }
    }

    /// Clears recorded log lines for a specific source, or all sources if nil.
    public func clearLogs(for source: LogsView.LogSource? = nil) {
        if let source = source {
            serviceLogs[source] = []
        } else {
            serviceLogs.removeAll()
            seenLogKeys.removeAll()
            seenLogKeyQueue.removeAll()
        }
    }

    // MARK: - Entry Processing

    /// Target mapping: routes an OSLogEntryLog to the appropriate service log streams.
    nonisolated public func targetSources(for logEntry: OSLogEntryLog) -> Set<LogsView.LogSource> {
        Self.targetSources(for: logEntry)
    }

    nonisolated static func targetSources(for logEntry: OSLogEntryLog) -> Set<LogsView.LogSource> {
        var targets: Set<LogsView.LogSource> = [.unifiedLog]
        let category = logEntry.category.lowercased()
        let process = logEntry.process.lowercased()
        let message = logEntry.composedMessage

        // Postgres
        if category.contains("postgres") || category.contains("initdb") || category.contains("psql") || category.contains("pg_") || process.contains("postgres") {
            targets.insert(.postgres)
        }

        // garage CLI
        if category.contains("garage-cli") || category.contains("garagecli") || category.contains("garagecliservice") || (category.contains("garage") && !category.contains("ingest") && !category.contains("mcp") && !category.contains("grpc") && !category.contains("llama") && !category.contains("model")) || process.contains("garage_bin") || process == "garage" {
            targets.insert(.garage)
        }

        // Ingest
        if category.contains("ingest") ||
            category == "garagexpcoutputcapture" ||
            category == "ingestservice" ||
            category == "ingestclient" ||
            category == "garageingestxpcservice" ||
            process.contains("garageingest") ||
            message.hasPrefix("[Python]") {
            targets.insert(.ingest)
        }

        // Embedding / Backfill
        if category.contains("embed") || category.contains("backfill") || process.contains("embed") {
            targets.insert(.embed)
        }

        // MCP Server
        if category.contains("mcp") || process.contains("mcp") || category.contains("garagemcpservice") {
            targets.insert(.mcp)
        }

        // gRPC Server
        if category.contains("grpc") || process.contains("grpc") || category.contains("garagegrpcservice") {
            targets.insert(.grpc)
        }

        // Llama Service
        if category.contains("llama") || process.contains("llama") {
            targets.insert(.llama)
        }

        // Model Downloader
        if category.contains("modeldownload") || process.contains("modeldownload") {
            targets.insert(.modelDownload)
        }

        return targets
    }

    /// Processes an individual `OSLogEntry` and converts it to a `LogLine`.
    public func processOSLogEntry(_ entry: OSLogEntry) {
        guard let routed = Self.routedLine(for: entry) else { return }
        appendRouted([routed])
    }

    /// `entry` as a `LogLine` with the sources it belongs to; nil for an entry that is not a log message.
    /// Pure, so it runs wherever the store is read.
    nonisolated static func routedLine(for entry: OSLogEntry) -> RoutedLogLine? {
        guard let logEntry = entry as? OSLogEntryLog else { return nil }
        let category = logEntry.category
        let message = logEntry.composedMessage
        let process = logEntry.process

        let stream: LogLine.Stream = (logEntry.level == .fault || logEntry.level == .error) ? .stderr : .stdout
        let level: LogLevel
        switch logEntry.level {
        case .fault, .error:
            level = .error
        case .info, .notice:
            level = .info
        case .debug:
            level = .debug
        default:
            level = LogLine.inferLevel(stream: stream, text: message)
        }

        let sourceLabel: String
        if !category.isEmpty {
            sourceLabel = category
        } else if !process.isEmpty {
            sourceLabel = process
        } else {
            sourceLabel = "OSLog"
        }

        let line = LogLine(
            id: UUID(),
            date: logEntry.date,
            stream: stream,
            text: message,
            source: sourceLabel,
            level: level,
            pid: logEntry.processIdentifier
        )

        return RoutedLogLine(line: line, targets: targetSources(for: logEntry))
    }

    /// Appends a new `LogLine` to target services while deduplicating by text content, source, and timestamp bucket.
    public func appendLog(_ line: LogLine, for targets: Set<LogsView.LogSource>) {
        appendLogs([line], for: targets)
    }

    /// Appends a batch of `LogLine`s to target services in a single `@Published` update per target, deduplicating by
    /// text content, source, and timestamp bucket. Batching avoids triggering a Combine publish (and the array
    /// copy/trim it entails) once per line, which is what stalls the main thread under bursty log volume.
    public func appendLogs(_ lines: [LogLine], for targets: Set<LogsView.LogSource>) {
        appendRouted(lines.map { RoutedLogLine(line: $0, targets: targets) })
    }

    /// Appends lines that each name their own sources, in order, with one `@Published` update for the
    /// whole batch.
    public func appendRouted(_ routed: [RoutedLogLine]) {
        guard !routed.isEmpty else { return }

        var accepted: [LogsView.LogSource: [LogLine]] = [:]

        for item in routed {
            let line = item.line
            let textTrimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !textTrimmed.isEmpty else { continue }

            let timeBucket = Int(line.date.timeIntervalSince1970)
            let key = "\(textTrimmed)|\(timeBucket)|\(line.source)|\(line.pid ?? 0)"

            if seenLogKeys.contains(key) {
                continue
            }
            seenLogKeys.insert(key)
            seenLogKeyQueue.append(key)
            for target in item.targets {
                accepted[target, default: []].append(line)
            }
        }

        if seenLogKeyQueue.count > maxSeenKeys {
            let overflow = seenLogKeyQueue.count - maxSeenKeys
            for removed in seenLogKeyQueue.prefix(overflow) {
                seenLogKeys.remove(removed)
            }
            seenLogKeyQueue.removeFirst(overflow)
        }

        guard !accepted.isEmpty else { return }

        var updated = serviceLogs
        for (target, lines) in accepted {
            var current = updated[target] ?? []
            current.append(contentsOf: lines)
            if current.count > maxLogLinesPerService {
                current.removeFirst(LogLine.trimCount(count: current.count, limit: maxLogLinesPerService))
            }
            updated[target] = current
        }
        serviceLogs = updated
    }

    // MARK: - Direct XPC Log Streaming

    /// Splits a raw stdout/stderr text chunk into individual `LogLine`s. This does string scanning (line splitting,
    /// level inference) and is safe to call off the main actor so bursty output doesn't do that work on the main thread.
    public nonisolated static func makeLogLines(from text: String, stream: LogLine.Stream, source: String, pid: Int32? = nil) -> [LogLine] {
        text.split(separator: "\n", omittingEmptySubsequences: true).map { line in
            let str = String(line)
            return LogLine(
                id: UUID(),
                date: Date(),
                stream: stream,
                text: str,
                source: source,
                level: LogLine.inferLevel(stream: stream, text: str),
                pid: pid
            )
        }
    }

    /// Ingests stdout streamed chunk over XPC from a helper service.
    public func receiveXPCStdout(_ text: String, source: LogsView.LogSource, pid: Int32? = nil) {
        let lines = Self.makeLogLines(from: text, stream: .stdout, source: source.rawValue, pid: pid)
        appendLogs(lines, for: [source, .unifiedLog])
    }

    /// Ingests stderr streamed chunk over XPC from a helper service.
    public func receiveXPCStderr(_ text: String, source: LogsView.LogSource, pid: Int32? = nil) {
        let lines = Self.makeLogLines(from: text, stream: .stderr, source: source.rawValue, pid: pid)
        appendLogs(lines, for: [source, .unifiedLog])
    }

    /// Ingests a structured log entry emitted over XPC from a helper service.
    public func receiveXPCLog(source: LogsView.LogSource, level: LogLevel, message: String, timestamp: Double = Date().timeIntervalSince1970, pid: Int32? = nil) {
        let logLine = LogLine(
            id: UUID(),
            date: Date(timeIntervalSince1970: timestamp),
            stream: level == .error ? .stderr : .stdout,
            text: message,
            source: source.rawValue,
            level: level,
            pid: pid
        )
        appendLog(logLine, for: [source, .unifiedLog])
    }

    // MARK: - Disk File Log Ingestion

    /// Reads persisted logs from the shared App Group / Application Support log file and inserts them.
    public func loadLogsFromFile(fileName: String, for source: LogsView.LogSource) {
        let logContent = GarageFileLogger.shared.readLogs(fileName: fileName)
        guard !logContent.isEmpty else { return }

        let lines = logContent.split(separator: "\n")
        var collected: [LogLine] = []
        for line in lines {
            let text = String(line)
            guard !text.isEmpty else { continue }
            let level = LogLine.inferLevel(stream: .stdout, text: text)
            let stream: LogLine.Stream = level == .error ? .stderr : .stdout
            collected.append(LogLine(
                id: UUID(),
                date: Date(),
                stream: stream,
                text: text,
                source: source.rawValue,
                level: level
            ))
        }

        appendLogs(collected, for: [source, .unifiedLog])
    }

    /// Loads all persisted log files for all XPC helper services.
    public func loadAllPersistedLogs() {
        loadLogsFromFile(fileName: "ingest-xpc.log", for: .ingest)
        loadLogsFromFile(fileName: "embed-xpc.log", for: .embed)
        loadLogsFromFile(fileName: "mcp-server-xpc.log", for: .mcp)
        loadLogsFromFile(fileName: "garage-xpc.log", for: .grpc)
        loadLogsFromFile(fileName: "llama-xpc.log", for: .llama)
        loadLogsFromFile(fileName: "model-download-xpc.log", for: .modelDownload)
    }
}

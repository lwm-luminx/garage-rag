import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag", category: "ProcessRunner")

/// Severity level for log entries, supporting filtering and priority ordering.
public enum LogLevel: String, CaseIterable, Identifiable, Comparable, Sendable {
    case debug = "Debug"
    case info = "Info"
    case warning = "Warning"
    case error = "Error"

    public var id: String { rawValue }

    public var priority: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warning: return 2
        case .error: return 3
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.priority < rhs.priority
    }
}

/// A line of output captured from a subprocess, for the log viewer.
public struct LogLine: Identifiable, Hashable, Sendable {
    public enum Stream: String, CaseIterable, Identifiable, Comparable, Sendable {
        case stdout = "stdout"
        case stderr = "stderr"

        public var id: String { rawValue }

        public static func < (lhs: Stream, rhs: Stream) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public let id: UUID
    public let date: Date
    public let stream: Stream
    public let text: String
    public let source: String
    public let level: LogLevel
    public let pid: Int32?
    public let rawText: String?

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        stream: Stream,
        text: String,
        source: String,
        level: LogLevel? = nil,
        pid: Int32? = nil,
        rawText: String? = nil
    ) {
        self.id = id
        self.date = date
        self.stream = stream
        self.text = text
        self.source = source
        self.level = level ?? Self.inferLevel(stream: stream, text: text)
        self.pid = pid
        self.rawText = rawText
    }

    private static let levelPrefixRegex: NSRegularExpression = {
        let pattern = "^(?:(?:\\d{4}[-/]\\d{2}[-/]\\d{2}[T\\s]\\d{2}:\\d{2}:\\d{2}(?:[\\.,]\\d+)?(?:Z|[+-]\\d{2}:?\\d{2})?|\\d{2}:\\d{2}:\\d{2}(?:[\\.,]\\d+)?|(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\\s+\\d+\\s+\\d{2}:\\d{2}:\\d{2})\\s*)?(?:[-:\\|]\\s*|\\[[^\\]]+\\]\\s*|\\([^\\)]+\\)\\s*|\\<[^\\>]+\\>\\s*|[\\w\\.-]+@\\w+\\s*|[\\w\\.-]+\\s*[-:\\|]\\s*)*[\\[\\(\\<]?(FATAL|CRITICAL|CRIT|PANIC|ERROR|ERR|WARNING|WARN|WRN|DEBUG(?:[1-5])?|TRACE|TRC|DBG|INFO|INFORMATION|INF|NOTICE|LOG|DETAIL|HINT|STATEMENT|NOTE)[\\]\\)\\>]?(?=[:\\s\\-\\|/\\[\\(\\<]|$)"
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private static func parseTokenLevel(_ token: String) -> LogLevel? {
        let upper = token.uppercased()
        switch upper {
        case "FATAL", "CRITICAL", "CRIT", "PANIC", "ERROR", "ERR":
            return .error
        case "WARNING", "WARN", "WRN":
            return .warning
        case "DEBUG", "DEBUG1", "DEBUG2", "DEBUG3", "DEBUG4", "DEBUG5", "TRACE", "TRC", "DBG":
            return .debug
        case "INFO", "INFORMATION", "INF", "NOTICE", "LOG", "DETAIL", "HINT", "STATEMENT", "NOTE":
            return .info
        default:
            return nil
        }
    }

    public static func inferLevel(stream: Stream, text: String) -> LogLevel {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return stream == .stderr ? .error : .info
        }

        let lower = trimmed.lowercased()

        // 1. Python tracebacks
        if lower.contains("traceback (most recent call last):") {
            return .error
        }

        // 2. Structured key-value / JSON logging
        if lower.contains("\"level\":\"error\"") || lower.contains("\"level\": \"error\"")
            || lower.contains("\"level\":\"fatal\"") || lower.contains("\"level\": \"fatal\"")
            || lower.contains("\"level\":\"critical\"") || lower.contains("\"level\": \"critical\"")
            || lower.contains("\"level\":\"panic\"") || lower.contains("\"level\": \"panic\"")
            || lower.contains("level=error") || lower.contains("level=fatal")
            || lower.contains("level=critical") || lower.contains("level=panic") {
            return .error
        }
        if lower.contains("\"level\":\"warn\"") || lower.contains("\"level\": \"warn\"")
            || lower.contains("\"level\":\"warning\"") || lower.contains("\"level\": \"warning\"")
            || lower.contains("level=warn") || lower.contains("level=warning") {
            return .warning
        }
        if lower.contains("\"level\":\"debug\"") || lower.contains("\"level\": \"debug\"")
            || lower.contains("\"level\":\"trace\"") || lower.contains("\"level\": \"trace\"")
            || lower.contains("level=debug") || lower.contains("level=trace") {
            return .debug
        }
        if lower.contains("\"level\":\"info\"") || lower.contains("\"level\": \"info\"")
            || lower.contains("\"level\":\"notice\"") || lower.contains("\"level\": \"notice\"")
            || lower.contains("level=info") || lower.contains("level=notice") {
            return .info
        }

        // 3. Match leading prefix/token (Python logging, Uvicorn, timestamps, etc.)
        let fullRange = NSRange(location: 0, length: (trimmed as NSString).length)
        if let match = levelPrefixRegex.firstMatch(in: trimmed, options: [], range: fullRange),
           match.range(at: 1).location != NSNotFound,
           let tokenRange = Range(match.range(at: 1), in: trimmed) {
            let token = String(trimmed[tokenRange])
            if let level = parseTokenLevel(token) {
                return level
            }
        }

        // 4. Bracketed / tagged levels anywhere in the line
        if lower.contains("[error]") || lower.contains("error:") || lower.contains("[fatal]")
            || lower.contains("fatal:") || lower.contains("panic:") {
            return .error
        }
        if lower.contains("[warn]") || lower.contains("[warning]") || lower.contains("warning:")
            || lower.contains("warn:") {
            return .warning
        }
        if lower.contains("[debug]") || lower.contains("[trace]") || lower.contains("debug:")
            || lower.contains("trace:") {
            return .debug
        }
        if lower.contains("[info]") || lower.contains("info:") || lower.contains("log:")
            || lower.contains("notice:") || lower.contains("detail:") || lower.contains("hint:") {
            return .info
        }

        if stream == .stderr {
            return .error
        }
        return .info
    }

    public func matches(searchText: String) -> Bool {
        guard !searchText.isEmpty else { return true }
        if let pid, String(pid).localizedCaseInsensitiveContains(searchText) {
            return true
        }
        if let rawText, rawText.localizedCaseInsensitiveContains(searchText) {
            return true
        }
        return text.localizedCaseInsensitiveContains(searchText)
            || source.localizedCaseInsensitiveContains(searchText)
            || stream.rawValue.localizedCaseInsensitiveContains(searchText)
            || level.rawValue.localizedCaseInsensitiveContains(searchText)
    }
}

extension LogLine {
    /// How many of the oldest lines to drop from a log buffer of `count` lines capped at `limit`: once it passes
    /// `limit`, enough to bring it down to three quarters of `limit`, not just back to `limit`.
    ///
    /// Log tables list the oldest line first. Trimming only the overflow dropped a few lines on every flush once a
    /// buffer was full, so every flush removed the rows on screen; during a fast ingest (a Mail source logs a line per
    /// message) tearing down those rows' hosting views held the main thread for over a second, every second.
    /// Trimming a quarter at a time removes the rows on screen once per `limit / 4` lines instead.
    static func trimCount(count: Int, limit: Int) -> Int {
        guard count > limit else { return 0 }
        return count - (limit - limit / 4)
    }
}

/// Thin wrapper around Process that streams stdout/stderr line-by-line to a
/// callback and reports exit status. Used for both the long-running Postgres
/// server process and one-shot `garage` CLI invocations.
final class ProcessRunner: @unchecked Sendable {
    private(set) var process: Process?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private let stdoutLock = NSLock()
    private let stderrLock = NSLock()
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?

    @discardableResult
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        source: String,
        onExit: (@Sendable (Int32) -> Void)? = nil,
        onLine: @escaping (LogLine) -> Void
    ) throws -> Process {
        let process = Process()
        if let onExit {
            process.terminationHandler = { finished in onExit(finished.terminationStatus) }
        }
        process.executableURL = executable
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        self.stdoutHandle = stdoutHandle
        self.stderrHandle = stderrHandle

        stdoutHandle.readabilityHandler = { [weak self] handle in
            guard let self else {
                handle.readabilityHandler = nil
                return
            }
            self.consume(handle: handle, lock: self.stdoutLock, buffer: \.stdoutBuffer, stream: .stdout, source: source, onLine: onLine)
        }
        stderrHandle.readabilityHandler = { [weak self] handle in
            guard let self else {
                handle.readabilityHandler = nil
                return
            }
            self.consume(handle: handle, lock: self.stderrLock, buffer: \.stderrBuffer, stream: .stderr, source: source, onLine: onLine)
        }

        self.process = process
        try process.run()
        return process
    }

    /// Runs to completion and returns (exitCode, combined output). For short CLI calls.
    static func runSync(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil
    ) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            let errText = "failed to launch \(executable.path): \(error.localizedDescription)"
            emitToOSLog(stream: .stderr, text: errText, source: executable.lastPathComponent)
            return (-1, errText)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        if !output.isEmpty {
            for rawLine in output.split(separator: "\n") {
                let lineStr = String(rawLine)
                emitToOSLog(stream: .stdout, text: lineStr, source: executable.lastPathComponent)
            }
        }
        return (process.terminationStatus, output)
    }

    private func consume(
        handle: FileHandle,
        lock: NSLock,
        buffer: ReferenceWritableKeyPath<ProcessRunner, Data>,
        stream: LogLine.Stream,
        source: String,
        onLine: @escaping (LogLine) -> Void
    ) {
        let data = handle.availableData
        var linesToEmit: [String] = []

        lock.lock()
        if data.isEmpty {
            handle.readabilityHandler = nil
            if !self[keyPath: buffer].isEmpty {
                if let text = String(data: self[keyPath: buffer], encoding: .utf8), !text.isEmpty {
                    linesToEmit.append(text)
                }
                self[keyPath: buffer].removeAll()
            }
            lock.unlock()
        } else {
            self[keyPath: buffer].append(data)
            while let range = self[keyPath: buffer].firstRange(of: Data([0x0A])) {
                let lineData = self[keyPath: buffer].subdata(in: self[keyPath: buffer].startIndex..<range.lowerBound)
                self[keyPath: buffer].removeSubrange(self[keyPath: buffer].startIndex..<range.upperBound)
                if let text = String(data: lineData, encoding: .utf8) {
                    linesToEmit.append(text)
                }
            }
            lock.unlock()
        }

        for text in linesToEmit {
            Self.emitToOSLog(stream: stream, text: text, source: source)
            DispatchQueue.main.async {
                onLine(LogLine(stream: stream, text: text, source: source))
            }
        }
    }

    private static func emitToOSLog(stream: LogLine.Stream, text: String, source: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let category: String
        let normalizedSource = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedSource.contains("postgres") || normalizedSource.contains("initdb") || normalizedSource.contains("psql") || normalizedSource.contains("pg_") {
            category = "postgres"
        } else if normalizedSource.contains("garage") {
            category = "garage-cli"
        } else {
            category = source.replacingOccurrences(of: " ", with: "")
        }

        let subLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag", category: category)
        let level = LogLine.inferLevel(stream: stream, text: trimmed)
        switch level {
        case .error:
            subLogger.error("\(trimmed, privacy: .public)")
        case .warning:
            subLogger.warning("\(trimmed, privacy: .public)")
        case .info:
            subLogger.info("\(trimmed, privacy: .public)")
        case .debug:
            subLogger.debug("\(trimmed, privacy: .public)")
        }
    }

    private func cleanupHandlers() {
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        stdoutHandle = nil
        stderrHandle = nil
    }

    func terminate() {
        cleanupHandlers()
        guard let process, process.isRunning else { return }
        process.terminate()
    }

    /// SIGINT. For Postgres this is a fast shutdown: it disconnects clients and writes a shutdown
    /// checkpoint, where SIGTERM (`terminate()`) is a smart shutdown that waits for every client to leave.
    func interrupt() {
        guard let process, process.isRunning else { return }
        kill(process.processIdentifier, SIGINT)
    }

    func forceKill() {
        cleanupHandlers()
        guard let process, process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
    }

    var isRunning: Bool {
        process?.isRunning ?? false
    }

    /// The pid of the process last launched with `run`, while it is still running.
    var runningProcessIdentifier: Int32? {
        guard let process, process.isRunning else { return nil }
        return process.processIdentifier
    }

    deinit {
        cleanupHandlers()
    }
}

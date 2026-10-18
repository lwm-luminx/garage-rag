import Foundation
import OSLog

private let fileLoggerInternal = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag", category: "GarageFileLogger")

/// Manages writing structured and captured log files to the shared App Group directory or local Application Support.
public final class GarageFileLogger: @unchecked Sendable {
    public static let shared = GarageFileLogger()

    private let lock = NSLock()
    private var fileHandles: [String: FileHandle] = [:]
    private let dateFormatter: ISO8601DateFormatter
    private let maxFileSize: Int64 = 10 * 1024 * 1024 // 10 MB per log file

    public init() {
        self.dateFormatter = ISO8601DateFormatter()
        self.dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    deinit {
        lock.lock()
        for (_, handle) in fileHandles {
            try? handle.close()
        }
        fileHandles.removeAll()
        lock.unlock()
    }

    /// Name of the folder created below `~/Library/Logs` (or the group container's `Library/Logs`).
    public static let logsFolderName = "Garage"

    /// App Group shared by the host application and its XPC helpers.
    public static let appGroupIdentifier = GarageAppGroup.identifier

    private static let resolvedLogsDirectory: URL = {
        let fm = FileManager.default

        func usable(_ url: URL) -> Bool {
            if (try? fm.createDirectory(at: url, withIntermediateDirectories: true)) == nil {
                return false
            }
            return fm.isWritableFile(atPath: url.path)
        }

        // 1. Standard per-user location. Inside the App Sandbox this resolves to the container's
        //    `Library/Logs`, which Console.app and `log collect` still pick up.
        if let library = fm.urls(for: .libraryDirectory, in: .userDomainMask).first {
            let logsDir = library.appendingPathComponent("Logs", isDirectory: true).appendingPathComponent(logsFolderName, isDirectory: true)
            if usable(logsDir) {
                return logsDir
            }
        }
        // 2. Shared App Group container so the host app and every XPC service write to the same place
        //    even when their individual containers differ (App Store builds).
        if GarageAppGroup.isEntitled,
           let container = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            let logsDir = container.appendingPathComponent("Library/Logs", isDirectory: true).appendingPathComponent(logsFolderName, isDirectory: true)
            if usable(logsDir) {
                return logsDir
            }
        }
        // 3. Application Support fallback.
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let logsDir = appSupport.appendingPathComponent("GarageApp/logs", isDirectory: true)
            if usable(logsDir) {
                return logsDir
            }
        }
        let tempLogs = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("garage-logs", isDirectory: true)
        try? fm.createDirectory(at: tempLogs, withIntermediateDirectories: true)
        return tempLogs
    }()

    /// Resolves the base directory for log files.
    ///
    /// Order of preference: `~/Library/Logs/Garage` (standard macOS location, container-relative when
    /// sandboxed), the shared App Group container, `~/Library/Application Support/GarageApp/logs`, and
    /// finally a temporary directory. The result is computed once per process.
    public static var logsDirectoryURL: URL {
        resolvedLogsDirectory
    }

    /// Full path of a log file inside `logsDirectoryURL`.
    public static func logFileURL(named fileName: String) -> URL {
        logsDirectoryURL.appendingPathComponent(fileName)
    }

    /// Appends a raw or structured log line to a specified log file.
    public func append(fileName: String, text: String, stream: String = "stdout", level: String? = nil, source: String? = nil, timestamp: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }

        let logsDir = Self.logsDirectoryURL
        let fileURL = logsDir.appendingPathComponent(fileName)

        // Ensure file exists
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }

        // Check file size and rotate if needed
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let size = attrs[.size] as? Int64, size > maxFileSize {
            rotateFile(at: fileURL, maxBackups: 3)
        }

        let handle: FileHandle
        if let existing = fileHandles[fileName] {
            handle = existing
        } else {
            guard let opened = try? FileHandle(forWritingTo: fileURL) else {
                fileLoggerInternal.error("Failed to open log file for writing: \(fileURL.path, privacy: .public)")
                return
            }
            fileHandles[fileName] = opened
            handle = opened
        }

        let timeStr = dateFormatter.string(from: timestamp)
        let lvl = (level ?? (stream == "stderr" ? "ERROR" : "INFO")).uppercased()
        let src = source ?? "Service"

        // Format message lines
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var formattedData = Data()
        for (idx, line) in lines.enumerated() {
            if idx == lines.count - 1 && line.isEmpty { continue }
            let lineStr = "\(timeStr) [\(lvl)] [\(src)] \(line)\n"
            if let d = lineStr.data(using: .utf8) {
                formattedData.append(d)
            }
        }

        if !formattedData.isEmpty {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: formattedData)
            try? handle.synchronize()
        }
    }

    /// Reads recent log entries from the file.
    public func readLogs(fileName: String, maxBytes: Int = 512 * 1024) -> String {
        lock.lock()
        defer { lock.unlock() }

        if let existing = fileHandles[fileName] {
            try? existing.synchronize()
        }

        let fileURL = Self.logsDirectoryURL.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return ""
        }
        defer { try? handle.close() }

        guard let fileSize = try? handle.seekToEnd(), fileSize > 0 else {
            return ""
        }

        let readOffset = max(0, Int64(fileSize) - Int64(maxBytes))
        _ = try? handle.seek(toOffset: UInt64(readOffset))
        let data = handle.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Clears the log file.
    public func clear(fileName: String) {
        lock.lock()
        defer { lock.unlock() }

        if let handle = fileHandles.removeValue(forKey: fileName) {
            try? handle.close()
        }

        let fileURL = Self.logsDirectoryURL.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: fileURL)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
    }

    private func rotateFile(at fileURL: URL, maxBackups: Int) {
        if let handle = fileHandles.removeValue(forKey: fileURL.lastPathComponent) {
            try? handle.close()
        }
        for i in stride(from: maxBackups - 1, through: 1, by: -1) {
            let fromPath = "\(fileURL.path).\(i)"
            let toPath = "\(fileURL.path).\(i + 1)"
            try? FileManager.default.removeItem(atPath: toPath)
            try? FileManager.default.moveItem(atPath: fromPath, toPath: toPath)
        }
        let backupPath = "\(fileURL.path).1"
        try? FileManager.default.removeItem(atPath: backupPath)
        try? FileManager.default.moveItem(atPath: fileURL.path, toPath: backupPath)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
    }
}

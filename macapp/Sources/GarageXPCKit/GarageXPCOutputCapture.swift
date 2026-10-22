import Foundation
import Darwin
import OSLog
import PythonXPCService_protocol

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag", category: "GarageXPCOutputCapture")

/// Captures stdout and stderr streams in-process, writes to log files, buffers them for retrieval,
/// and streams logs over XPC to connected host receivers.
/// Preserves console / system logging by tee-ing captured data back to the original file descriptors.
public final class GarageXPCOutputCapture: @unchecked Sendable {
    public static let shared = GarageXPCOutputCapture()

    private let lock = NSLock()
    private var isCapturing = false

    private var originalStdoutFd: Int32 = -1
    private var originalStderrFd: Int32 = -1

    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    // Per stream: a pipe read can end inside a multibyte character. Guarded by `lock`.
    private var stdoutDecoder = UTF8StreamDecoder()
    private var stderrDecoder = UTF8StreamDecoder()
    private let maxBufferSize: Int

    public var serviceName: String = "GarageXPC"
    public var logFileName: String = "garage-xpc.log"

    private var activeConnections = Set<NSXPCConnection>()

    public init(maxBufferSize: Int = 1_048_576) { // 1 MB default buffer
        self.maxBufferSize = maxBufferSize
    }

    /// Configures the service identity and target log file name.
    public func configure(serviceName: String, logFileName: String) {
        lock.lock()
        defer { lock.unlock() }
        self.serviceName = serviceName
        self.logFileName = logFileName
        logger.debug("Configured GarageXPCOutputCapture for service '\(serviceName, privacy: .public)' (log file: \(logFileName, privacy: .public))")
    }

    /// Adds an active NSXPCConnection to receive streamed log events.
    public func addConnection(_ connection: NSXPCConnection) {
        lock.lock()
        defer { lock.unlock() }
        activeConnections.insert(connection)
        logger.debug("Added active XPC log streaming connection for PID \(connection.processIdentifier, privacy: .public) (total: \(self.activeConnections.count, privacy: .public))")
    }

    /// Removes an NSXPCConnection from receiving streamed log events.
    public func removeConnection(_ connection: NSXPCConnection) {
        lock.lock()
        defer { lock.unlock() }
        activeConnections.remove(connection)
        logger.debug("Removed active XPC log streaming connection for PID \(connection.processIdentifier, privacy: .public) (total: \(self.activeConnections.count, privacy: .public))")
    }

    /// Starts capturing stdout and stderr descriptors (fd 1 and fd 2).
    public func startCapturing() {
        lock.lock()
        defer { lock.unlock() }

        guard !isCapturing else { return }

        // Save original file descriptors
        originalStdoutFd = dup(STDOUT_FILENO)
        originalStderrFd = dup(STDERR_FILENO)

        let outPipe = Pipe()
        let errPipe = Pipe()
        self.stdoutPipe = outPipe
        self.stderrPipe = errPipe

        // Redirect stdout and stderr to the pipe write ends
        fflush(stdout)
        fflush(stderr)
        dup2(outPipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        dup2(errPipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

        let origOut = originalStdoutFd
        let origErr = originalStderrFd

        // Background reader for stdout
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            // Tee to original stdout so terminal output still works
            if origOut >= 0 {
                data.withUnsafeBytes { ptr in
                    if let base = ptr.baseAddress {
                        _ = write(origOut, base, data.count)
                    }
                }
            }

            self?.appendStdoutData(data)
        }

        // Background reader for stderr
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            // Tee to original stderr
            if origErr >= 0 {
                data.withUnsafeBytes { ptr in
                    if let base = ptr.baseAddress {
                        _ = write(origErr, base, data.count)
                    }
                }
            }

            self?.appendStderrData(data)
        }

        isCapturing = true
        logger.info("GarageXPCOutputCapture started capturing stdout and stderr for \(self.serviceName, privacy: .public).")
    }

    /// Appends data to the stdout buffer, writes to log file, and streams over XPC.
    private func appendStdoutData(_ data: Data) {
        lock.lock()
        let text = stdoutDecoder.decode(data)
        lock.unlock()
        guard !text.isEmpty else { return }

        let currentFile: String
        let currentSource: String
        let conns: [NSXPCConnection]

        lock.lock()
        stdoutBuffer.append(data)
        if stdoutBuffer.count > maxBufferSize {
            let overflow = stdoutBuffer.count - maxBufferSize
            stdoutBuffer.removeSubrange(0..<overflow)
        }
        currentFile = logFileName
        currentSource = serviceName
        conns = Array(activeConnections)
        lock.unlock()

        // Write to log file
        GarageFileLogger.shared.append(fileName: currentFile, text: text, stream: "stdout", level: "INFO", source: currentSource)

        // Log to unified logging
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            logger.info("[\(currentSource, privacy: .public)] \(line, privacy: .public)")
        }

        // Stream over active XPC connections
        for conn in conns {
            guard let proxy = conn.remoteObjectProxyWithErrorHandler({ _ in }) as? GarageXPCLogReceiverProtocol else {
                continue
            }
            proxy.didReceiveStdout(text)
        }
    }

    /// Appends data to the stderr buffer, writes to log file, and streams over XPC.
    private func appendStderrData(_ data: Data) {
        lock.lock()
        let text = stderrDecoder.decode(data)
        lock.unlock()
        guard !text.isEmpty else { return }

        let currentFile: String
        let currentSource: String
        let conns: [NSXPCConnection]

        lock.lock()
        stderrBuffer.append(data)
        if stderrBuffer.count > maxBufferSize {
            let overflow = stderrBuffer.count - maxBufferSize
            stderrBuffer.removeSubrange(0..<overflow)
        }
        currentFile = logFileName
        currentSource = serviceName
        conns = Array(activeConnections)
        lock.unlock()

        // Write to log file
        GarageFileLogger.shared.append(fileName: currentFile, text: text, stream: "stderr", level: "ERROR", source: currentSource)

        // Log to unified logging
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            logger.error("[\(currentSource, privacy: .public)] \(line, privacy: .public)")
        }

        // Stream over active XPC connections
        for conn in conns {
            guard let proxy = conn.remoteObjectProxyWithErrorHandler({ _ in }) as? GarageXPCLogReceiverProtocol else {
                continue
            }
            proxy.didReceiveStderr(text)
        }
    }

    /// Appends a manual log line to the captured output and streams it.
    public func appendCustomLog(stream: String = "stdout", message: String, source: String? = nil, level: String? = nil) {
        let formatted = message.hasSuffix("\n") ? message : "\(message)\n"
        if let data = formatted.data(using: .utf8) {
            if stream.lowercased() == "stderr" {
                appendStderrData(data)
            } else {
                appendStdoutData(data)
            }
        }
    }

    /// Emits a structured log message, records to file, and broadcasts over XPC.
    public func log(source: String? = nil, level: String = "INFO", message: String) {
        let src = source ?? serviceName
        let timestamp = Date().timeIntervalSince1970

        let currentFile: String
        let conns: [NSXPCConnection]

        lock.lock()
        currentFile = logFileName
        conns = Array(activeConnections)
        lock.unlock()

        // Write to log file
        GarageFileLogger.shared.append(fileName: currentFile, text: message, stream: level == "ERROR" ? "stderr" : "stdout", level: level, source: src, timestamp: Date(timeIntervalSince1970: timestamp))

        // Log to unified logging
        switch level.uppercased() {
        case "ERROR", "CRITICAL", "FATAL":
            logger.error("[\(src, privacy: .public)] \(message, privacy: .public)")
        case "WARN", "WARNING":
            logger.warning("[\(src, privacy: .public)] \(message, privacy: .public)")
        case "DEBUG", "TRACE":
            logger.debug("[\(src, privacy: .public)] \(message, privacy: .public)")
        default:
            logger.info("[\(src, privacy: .public)] \(message, privacy: .public)")
        }

        // Broadcast structured log over active XPC connections
        for conn in conns {
            guard let proxy = conn.remoteObjectProxyWithErrorHandler({ _ in }) as? GarageXPCLogReceiverProtocol else {
                continue
            }
            proxy.didReceiveLog(source: src, level: level, message: message, timestamp: timestamp)
        }
    }

    /// Fetches the captured stdout and stderr buffers as UTF-8 strings.
    public func fetchLogs(clearBuffer: Bool = false) -> (stdout: String, stderr: String) {
        lock.lock()
        defer { lock.unlock() }

        let outText = String(data: stdoutBuffer, encoding: .utf8) ?? ""
        let errText = String(data: stderrBuffer, encoding: .utf8) ?? ""

        if clearBuffer {
            stdoutBuffer.removeAll()
            stderrBuffer.removeAll()
        }

        return (stdout: outText, stderr: errText)
    }

    /// Clears the accumulated stdout and stderr buffers and resets log file.
    public func clear() {
        let currentFile: String
        lock.lock()
        stdoutBuffer.removeAll()
        stderrBuffer.removeAll()
        currentFile = logFileName
        lock.unlock()

        GarageFileLogger.shared.clear(fileName: currentFile)
    }

    /// Stops capturing and restores original file descriptors.
    public func stopCapturing() {
        lock.lock()
        defer { lock.unlock() }

        guard isCapturing else { return }

        fflush(stdout)
        fflush(stderr)

        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil

        if originalStdoutFd >= 0 {
            dup2(originalStdoutFd, STDOUT_FILENO)
            close(originalStdoutFd)
            originalStdoutFd = -1
        }

        if originalStderrFd >= 0 {
            dup2(originalStderrFd, STDERR_FILENO)
            close(originalStderrFd)
            originalStderrFd = -1
        }

        stdoutPipe = nil
        stderrPipe = nil
        isCapturing = false
        logger.info("GarageXPCOutputCapture stopped capturing.")
    }
}

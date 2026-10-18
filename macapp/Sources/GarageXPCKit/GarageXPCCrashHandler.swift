import Foundation
import Darwin
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag", category: "GarageXPCCrashHandler")

/// Installs fatal-signal and uncaught-exception handlers for an XPC service.
///
/// On a crash the handler writes a report (signal, dyld error, backtrace) to
/// - the process' stderr (which `GarageXPCOutputCapture` tees into the service log and streams to the app),
/// - unified logging (`fault` level), and
/// - `<logs>/<service>-crash.log` using only async-signal-safe primitives (`write(2)`, `backtrace(3)`),
/// then re-raises the signal so launchd / ReportCrash still produce a regular crash report.
public enum GarageXPCCrashHandler {
    private static var installed = false
    private static var crashLogFd: Int32 = -1
    private static var serviceNameBytes: [UInt8] = []

    /// Preallocated so the signal handler never touches the heap or the Swift metadata runtime
    /// (a stack overflow leaves no room for either; the previous array-based handler died with a second SIGBUS).
    private static let maxFrames = 128
    private static let frameBuffer = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: maxFrames)
    private static let alternateStackSize = max(Int(SIGSTKSZ), 256 * 1024)

    /// Gives the calling thread an alternate signal stack so `SIGSEGV`/`SIGBUS` caused by stack exhaustion can
    /// still run the handler. Called for the main thread by `install` and for every large-stack Python thread.
    public static func installAlternateSignalStackForCurrentThread() {
        var current = stack_t()
        if sigaltstack(nil, &current) == 0, current.ss_flags & SS_DISABLE == 0, current.ss_sp != nil {
            return
        }
        guard let memory = malloc(alternateStackSize) else { return }
        var altStack = stack_t(ss_sp: memory, ss_size: alternateStackSize, ss_flags: 0)
        if sigaltstack(&altStack, nil) != 0 {
            free(memory)
        }
    }

    /// Installs the handlers once. `serviceName` is used for the crash log file name and report header.
    public static func install(serviceName: String) {
        guard !installed else { return }
        installed = true

        serviceNameBytes = Array(serviceName.utf8)

        // Pre-open the crash log so the signal handler never has to allocate or touch Foundation.
        let crashURL = GarageFileLogger.logsDirectoryURL.appendingPathComponent("\(serviceName)-crash.log")
        crashLogFd = open(crashURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        if crashLogFd < 0 {
            logger.warning("Unable to open crash log at \(crashURL.path, privacy: .public): \(String(cString: strerror(errno)), privacy: .public)")
        }

        NSSetUncaughtExceptionHandler { exception in
            let callStack = exception.callStackSymbols.joined(separator: "\n  ")
            let msg = "CRITICAL: Uncaught NSException '\(exception.name.rawValue)': \(exception.reason ?? "none")\nUserInfo: \(String(describing: exception.userInfo))\nCall Stack:\n  \(callStack)\n"
            fputs(msg, stderr)
            fflush(stderr)
            GarageXPCCrashHandler.writeCrashLog(msg)
            logger.fault("CRITICAL: Uncaught NSException '\(exception.name.rawValue, privacy: .public)': \(exception.reason ?? "none", privacy: .public)\nCall Stack:\n  \(callStack, privacy: .public)")
        }

        _ = frameBuffer // force allocation up-front
        installAlternateSignalStackForCurrentThread()

        let fatalSignals: [Int32] = [SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGFPE, SIGTRAP]
        for sig in fatalSignals {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = { signum in
                GarageXPCCrashHandler.handleFatalSignal(signum)
            }
            action.sa_flags = SA_RESETHAND | SA_NODEFER | SA_ONSTACK
            sigemptyset(&action.sa_mask)
            sigaction(sig, &action, nil)
        }

        // SIGPIPE is not fatal for a server process: writing to a closed XPC/gRPC socket must not kill the service.
        signal(SIGPIPE, SIG_IGN)

        logger.debug("Crash handlers installed for \(serviceName, privacy: .public) (crash log: \(crashURL.path, privacy: .public))")
    }

    /// Returns the contents of the crash log if one exists (used for status reports).
    public static func lastCrashReport(serviceName: String, maxBytes: Int = 16 * 1024) -> String? {
        let text = GarageFileLogger.shared.readLogs(fileName: "\(serviceName)-crash.log", maxBytes: maxBytes)
        return text.isEmpty ? nil : text
    }

    /// Removes the crash log (after it has been surfaced to the user).
    public static func clearCrashReport(serviceName: String) {
        GarageFileLogger.shared.clear(fileName: "\(serviceName)-crash.log")
    }

    // MARK: - Signal handling (async-signal-safe)

    private static func handleFatalSignal(_ signum: Int32) {
        // Build the header with only static strings and raw writes.
        writeRaw("\n==== ")
        writeRaw(serviceNameBytes)
        writeRaw(" crashed: ")
        writeRaw(signalName(signum))
        writeRaw(" ====\n")

        if let err = dlerror() {
            writeRaw("dyld error: ")
            writeRaw(err)
            writeRaw("\n")
        }

        writeRaw("Backtrace:\n")
        let count = backtrace(frameBuffer, Int32(maxFrames))
        if count > 0 {
            if crashLogFd >= 0 {
                backtrace_symbols_fd(frameBuffer, count, crashLogFd)
            }
            backtrace_symbols_fd(frameBuffer, count, STDERR_FILENO)
        } else {
            writeRaw("  (unavailable)\n")
        }
        writeRaw("==== end of crash report ====\n")

        if crashLogFd >= 0 {
            fsync(crashLogFd)
        }

        // Restore default disposition (SA_RESETHAND already did) and re-raise so the system crash reporter runs.
        signal(signum, SIG_DFL)
        raise(signum)
    }

    private static func signalName(_ signum: Int32) -> StaticString {
        switch signum {
        case SIGSEGV: return "SIGSEGV (Segmentation Fault)"
        case SIGBUS: return "SIGBUS (Bus Error)"
        case SIGABRT: return "SIGABRT (Abort)"
        case SIGILL: return "SIGILL (Illegal Instruction)"
        case SIGFPE: return "SIGFPE (Floating Point Exception)"
        case SIGTRAP: return "SIGTRAP (Trace/BPT Trap)"
        default: return "fatal signal"
        }
    }

    private static func writeRaw(_ text: StaticString) {
        text.withUTF8Buffer { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = write(STDERR_FILENO, base, buffer.count)
            if crashLogFd >= 0 {
                _ = write(crashLogFd, base, buffer.count)
            }
        }
    }

    private static func writeRaw(_ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = write(STDERR_FILENO, base, buffer.count)
            if crashLogFd >= 0 {
                _ = write(crashLogFd, base, buffer.count)
            }
        }
    }

    private static func writeRaw(_ cString: UnsafeMutablePointer<CChar>) {
        let len = strlen(cString)
        _ = write(STDERR_FILENO, cString, len)
        if crashLogFd >= 0 {
            _ = write(crashLogFd, cString, len)
        }
    }

    private static func writeCrashLog(_ text: String) {
        guard crashLogFd >= 0 else { return }
        var data = Array(text.utf8)
        data.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = write(crashLogFd, base, buffer.count)
        }
    }
}

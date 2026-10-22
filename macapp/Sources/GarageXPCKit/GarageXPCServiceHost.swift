import Foundation
import OSLog
import PythonXPCService_protocol

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag", category: "GarageXPCServiceHost")

/// A long-running component owned by an XPC helper (gRPC server, MCP server, worker pool, ...).
///
/// All callbacks are invoked on the host's background thread, never on the XPC listener thread.
/// Implementations that call into Python must wrap those calls in `GaragePythonRuntime.shared.withGIL`.
public protocol GarageManagedService: AnyObject {
    /// Stable identifier shown in status reports.
    var name: String { get }
    /// Starts the service. Throwing marks the service as `failed`.
    func start() throws
    /// Stops the service. `graceful` allows in-flight work to drain; otherwise stop immediately.
    func stop(graceful: Bool) throws
    /// Whether the service currently considers itself healthy / running.
    var isRunning: Bool { get }
}

/// Manages the lifecycle of `GarageManagedService`s on a dedicated background thread and supports graceful and
/// non-graceful restarts. State is observable through `statusSnapshot()`.
public final class GarageXPCServiceHost: @unchecked Sendable {
    public enum ServiceState: Equatable, Sendable {
        case stopped
        case starting
        case running
        case stopping
        case restarting
        case failed(String)

        public var name: String {
            switch self {
            case .stopped: return "stopped"
            case .starting: return "starting"
            case .running: return "running"
            case .stopping: return "stopping"
            case .restarting: return "restarting"
            case .failed: return "failed"
            }
        }
    }

    private struct Entry {
        let service: GarageManagedService
        var state: ServiceState = .stopped
        var startedAt: Date?
        var restartCount: Int = 0
        var detail: String?
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    /// Serial background queue that owns every start/stop transition.
    private let queue: DispatchQueue
    /// Grace period used for graceful restarts when the service does not stop on its own.
    public var gracefulStopTimeout: TimeInterval = 10

    public init(label: String = "me.rickmark.garage-rag.service-host") {
        self.queue = DispatchQueue(label: label, qos: .utility)
    }

    // MARK: - Registration

    public func register(_ service: GarageManagedService) {
        lock.lock()
        defer { lock.unlock() }
        if entries.contains(where: { $0.service === service || $0.service.name == service.name }) {
            logger.warning("Managed service '\(service.name, privacy: .public)' is already registered")
            return
        }
        entries.append(Entry(service: service))
        logger.info("Registered managed service '\(service.name, privacy: .public)'")
    }

    public var registeredServiceNames: [String] {
        lock.lock(); defer { lock.unlock() }
        return entries.map { $0.service.name }
    }

    // MARK: - Lifecycle

    /// Starts every registered service on the background thread.
    public func startAll(completion: (([String: ServiceState]) -> Void)? = nil) {
        enqueue { [self] in
            let names = registeredServiceNames
            for name in names {
                startService(named: name)
            }
            completion?(currentStates())
        }
    }

    /// Stops every registered service on the background thread.
    public func stopAll(graceful: Bool, completion: (([String: ServiceState]) -> Void)? = nil) {
        enqueue { [self] in
            let names = registeredServiceNames.reversed()
            for name in names {
                stopService(named: name, graceful: graceful)
            }
            completion?(currentStates())
        }
    }

    /// Restarts every registered service. A graceful restart drains in-flight work first; a non-graceful restart
    /// tears the services down immediately.
    public func restartAll(graceful: Bool, completion: (([String: ServiceState]) -> Void)? = nil) {
        enqueue { [self] in
            let names = registeredServiceNames
            for name in names {
                setState(.restarting, for: name)
            }
            for name in names.reversed() {
                stopService(named: name, graceful: graceful, keepRestartingState: true)
            }
            for name in names {
                incrementRestartCount(for: name)
                startService(named: name)
            }
            completion?(currentStates())
        }
    }

    /// Restarts a single service by name.
    public func restart(named name: String, graceful: Bool, completion: ((ServiceState) -> Void)? = nil) {
        enqueue { [self] in
            setState(.restarting, for: name)
            stopService(named: name, graceful: graceful, keepRestartingState: true)
            incrementRestartCount(for: name)
            startService(named: name)
            completion?(state(of: name) ?? .failed("unknown service"))
        }
    }

    /// Runs arbitrary work on the host thread, serialized with lifecycle transitions.
    public func perform(_ body: @escaping () -> Void) {
        enqueue(body)
    }

    // MARK: - Status

    public func state(of name: String) -> ServiceState? {
        lock.lock(); defer { lock.unlock() }
        return entries.first(where: { $0.service.name == name })?.state
    }

    public func currentStates() -> [String: ServiceState] {
        lock.lock(); defer { lock.unlock() }
        var result: [String: ServiceState] = [:]
        for entry in entries {
            result[entry.service.name] = entry.state
        }
        return result
    }

    public func statusSnapshot() -> [GarageXPCManagedServiceStatus] {
        lock.lock(); defer { lock.unlock() }
        return entries.map { entry in
            var detail = entry.detail
            if case .failed(let message) = entry.state {
                detail = message
            }
            return GarageXPCManagedServiceStatus(
                name: entry.service.name,
                state: entry.state.name,
                detail: detail,
                startedAt: entry.startedAt?.timeIntervalSince1970,
                restartCount: entry.restartCount
            )
        }
    }

    /// True when at least one service is in the `failed` state.
    public var hasFailures: Bool {
        lock.lock(); defer { lock.unlock() }
        return entries.contains { if case .failed = $0.state { return true } else { return false } }
    }

    // MARK: - Internals (run on `queue`)

    private func enqueue(_ body: @escaping () -> Void) {
        queue.async {
            body()
        }
    }

    private func entry(named name: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return entries.first(where: { $0.service.name == name })
    }

    private func setState(_ state: ServiceState, for name: String, detail: String? = nil) {
        lock.lock()
        if let idx = entries.firstIndex(where: { $0.service.name == name }) {
            entries[idx].state = state
            if let detail = detail {
                entries[idx].detail = detail
            }
            if state == .running {
                entries[idx].startedAt = Date()
            } else if state == .stopped {
                entries[idx].startedAt = nil
            }
        }
        lock.unlock()
    }

    private func incrementRestartCount(for name: String) {
        lock.lock()
        if let idx = entries.firstIndex(where: { $0.service.name == name }) {
            entries[idx].restartCount += 1
        }
        lock.unlock()
    }

    private func startService(named name: String) {
        guard let entry = entry(named: name) else { return }
        if entry.service.isRunning, entry.state == .running {
            logger.debug("Managed service '\(name, privacy: .public)' already running")
            return
        }
        setState(.starting, for: name)
        logger.info("Starting managed service '\(name, privacy: .public)'...")
        let start = CFAbsoluteTimeGetCurrent()
        do {
            try entry.service.start()
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
            setState(.running, for: name, detail: "started in \(String(format: "%.0f", elapsed))ms")
            logger.info("Managed service '\(name, privacy: .public)' running (\(String(format: "%.0f", elapsed), privacy: .public)ms)")
        } catch {
            let message = error.localizedDescription
            setState(.failed(message), for: name)
            logger.error("Managed service '\(name, privacy: .public)' failed to start: \(message, privacy: .public)")
            GarageXPCOutputCapture.shared.log(level: "ERROR", message: "Service '\(name)' failed to start: \(message)")
        }
    }

    private func stopService(named name: String, graceful: Bool, keepRestartingState: Bool = false) {
        guard let entry = entry(named: name) else { return }
        if !keepRestartingState {
            setState(.stopping, for: name)
        }
        logger.info("Stopping managed service '\(name, privacy: .public)' (graceful: \(graceful, privacy: .public))...")
        do {
            if graceful {
                // Give the service a bounded amount of time to drain; escalate to a hard stop afterwards.
                let group = DispatchGroup()
                group.enter()
                var stopError: Error?
                let worker = Thread {
                    do { try entry.service.stop(graceful: true) } catch { stopError = error }
                    group.leave()
                }
                worker.name = "\(name)-graceful-stop"
                worker.start()
                if group.wait(timeout: .now() + gracefulStopTimeout) == .timedOut {
                    logger.warning("Graceful stop of '\(name, privacy: .public)' timed out after \(self.gracefulStopTimeout, privacy: .public)s; forcing")
                    try entry.service.stop(graceful: false)
                } else if let stopError = stopError {
                    throw stopError
                }
            } else {
                try entry.service.stop(graceful: false)
            }
            if !keepRestartingState {
                setState(.stopped, for: name)
            }
            logger.info("Managed service '\(name, privacy: .public)' stopped")
        } catch {
            let message = error.localizedDescription
            setState(.failed("stop failed: \(message)"), for: name)
            logger.error("Managed service '\(name, privacy: .public)' failed to stop: \(message, privacy: .public)")
        }
    }
}

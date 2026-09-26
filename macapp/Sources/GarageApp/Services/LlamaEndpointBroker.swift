import Foundation
import OSLog
import LlamaClient
import PythonXPCService

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag", category: "LlamaEndpointBroker")

/// A live connection the broker holds to one XPC service.
protocol LlamaEndpointLink: AnyObject {
    func invalidate()
}

/// The connection to LlamaXPCService, which hands out its anonymous listener's endpoint.
protocol LlamaEndpointSource: LlamaEndpointLink {
    /// Replies once: the endpoint, or nil and why not.
    func fetchEndpoint(_ reply: @escaping (NSXPCListenerEndpoint?, String?) -> Void)
}

/// The connection to a service that loads llama_xpc models on demand and needs the endpoint.
protocol LlamaEndpointReceiver: LlamaEndpointLink {
    /// Replies once: whether the service took the endpoint, and its message.
    func deliver(_ endpoint: NSXPCListenerEndpoint, _ reply: @escaping (Bool, String?) -> Void)
}

/// Makes the broker's connections. `onLost` is called (on any queue) when the connection is
/// interrupted or invalidated, which is how the broker learns that a service was relaunched.
struct LlamaEndpointConnector {
    var connectSource: (_ onLost: @escaping () -> Void) -> LlamaEndpointSource
    var connectReceiver: (_ serviceId: String, _ onLost: @escaping () -> Void) -> LlamaEndpointReceiver
}

/// Brokers LlamaXPCService's connection to the XPC services that load llama_xpc models on demand.
///
/// An XPC service is private to the app that bundles it: only the app can look
/// `me.rickmark.garage-rag.llama-xpc` up by name, so garage-xpc, embed-xpc and mcp-server-xpc cannot.
/// The broker fetches the endpoint of LlamaXPCService's anonymous listener (`getListenerEndpoint`)
/// and hands it to each of them (`setLlamaEndpoint`), which connect with
/// `NSXPCConnection(listenerEndpoint:)`.
///
/// It keeps one connection open to every one of those services. When LlamaXPCService's connection
/// is interrupted or invalidated (the service was restarted or crashed) it fetches a new endpoint
/// and hands it to all of them; when a receiver's is, it hands the endpoint to that service again.
/// A failed hand-over is retried with a growing delay. All work happens on the broker's own serial
/// queue, never on the main actor; `stop()` (at quit and before the helpers are killed) closes every
/// connection so nothing relaunches a service that is being shut down.
final class LlamaEndpointBroker: @unchecked Sendable {
    /// The services that receive the endpoint (XPCServiceManager ids).
    static let receiverServiceIds = ["garage-xpc", "embed-xpc", "mcp-server-xpc"]

    private let queue = DispatchQueue(label: "me.rickmark.garage-rag.llama-endpoint-broker", qos: .utility)
    private let connector: LlamaEndpointConnector
    private let receiverIds: [String]
    /// Delay before retrying after the n-th failed round in a row (the last one repeats).
    private let retryDelays: [TimeInterval]
    /// Delay after a connection was lost, so the relaunched service has a moment to come up.
    private let lostDelay: TimeInterval
    /// A round that has not heard back from every service by then counts as failed.
    private let roundTimeout: TimeInterval
    private var report: (String, Bool) -> Void

    // Everything below is confined to `queue`.
    private var running = false
    private var source: (link: LlamaEndpointSource, token: UUID)?
    private var receivers: [String: (link: LlamaEndpointReceiver, token: UUID)] = [:]
    private var endpoint: NSXPCListenerEndpoint?
    private var round: UUID?
    private var pendingReceivers: Set<String> = []
    private var failedReceivers: [String] = []
    private var rerunRequested = false
    private var scheduled = false
    private var consecutiveFailures = 0
    private var _successfulRounds = 0

    /// - Parameter report: called with a message and whether it is an error, for the app's log.
    init(
        connector: LlamaEndpointConnector,
        receiverIds: [String] = LlamaEndpointBroker.receiverServiceIds,
        retryDelays: [TimeInterval] = [1, 2, 5, 10, 30, 60],
        lostDelay: TimeInterval = 1,
        roundTimeout: TimeInterval = 30,
        report: @escaping (String, Bool) -> Void = { _, _ in }
    ) {
        self.connector = connector
        self.receiverIds = receiverIds
        self.retryDelays = retryDelays.isEmpty ? [1] : retryDelays
        self.lostDelay = lostDelay
        self.roundTimeout = roundTimeout
        self.report = report
    }

    /// Replaces the closure that hears about hand-overs (called on the broker's queue).
    func setReporter(_ report: @escaping (String, Bool) -> Void) {
        queue.async { [self] in
            self.report = report
        }
    }

    /// Rounds in which every receiver took the endpoint (for tests and diagnostics).
    var successfulRounds: Int {
        queue.sync { _successfulRounds }
    }

    var isRunning: Bool {
        queue.sync { running }
    }

    /// Starts handing the endpoint over (now, and again whenever a service comes back). Idempotent.
    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            consecutiveFailures = 0
            runRound()
        }
    }

    /// Hands the endpoint over again soon, fetching a new one first when `refetch` is set (for
    /// example after the app restarted a helper by killing it).
    func handOverAgain(refetch: Bool = false) {
        queue.async { [self] in
            guard running else { return }
            if refetch {
                dropSource()
            }
            schedule(after: lostDelay)
        }
    }

    /// Closes every connection and stops reacting to lost ones. Blocks until done, so a caller can
    /// kill the helpers right after without the broker relaunching them. `start()` resumes.
    func stop() {
        queue.sync {
            running = false
            round = nil
            pendingReceivers = []
            failedReceivers = []
            rerunRequested = false
            dropSource()
            for id in Array(receivers.keys) {
                dropReceiver(id)
            }
        }
    }

    // MARK: - Rounds (on `queue`)

    private func runRound() {
        guard running else { return }
        guard round == nil else {
            rerunRequested = true
            return
        }
        let current = UUID()
        round = current
        queue.asyncAfter(deadline: .now() + roundTimeout) { [weak self] in
            self?.roundTimedOut(current)
        }
        if let endpoint {
            deliver(endpoint, round: current)
            return
        }
        currentSource().fetchEndpoint { [weak self] endpoint, message in
            self?.queue.async {
                self?.endpointFetched(endpoint, message: message, round: current)
            }
        }
    }

    private func endpointFetched(_ fetched: NSXPCListenerEndpoint?, message: String?, round current: UUID) {
        guard round == current else { return }
        guard let fetched else {
            dropSource()
            finishRound(failure: "LlamaXPCService gave no endpoint: \(message ?? "no reason given")")
            return
        }
        endpoint = fetched
        deliver(fetched, round: current)
    }

    private func deliver(_ endpoint: NSXPCListenerEndpoint, round current: UUID) {
        pendingReceivers = Set(receiverIds)
        failedReceivers = []
        guard !receiverIds.isEmpty else {
            finishRound(failure: nil)
            return
        }
        for id in receiverIds {
            currentReceiver(id).deliver(endpoint) { [weak self] accepted, message in
                self?.queue.async {
                    self?.delivered(to: id, accepted: accepted, message: message, round: current)
                }
            }
        }
    }

    private func delivered(to id: String, accepted: Bool, message: String?, round current: UUID) {
        guard round == current, pendingReceivers.remove(id) != nil else { return }
        if !accepted {
            failedReceivers.append("\(id): \(message ?? "refused")")
            // A fresh connection next time: this one may be invalid for good.
            dropReceiver(id)
        }
        guard pendingReceivers.isEmpty else { return }
        finishRound(failure: failedReceivers.isEmpty ? nil : "Could not hand the LlamaXPCService endpoint to \(failedReceivers.joined(separator: "; "))")
    }

    private func roundTimedOut(_ current: UUID) {
        guard round == current else { return }
        let waitingOn = pendingReceivers.isEmpty ? ["llama-xpc"] : pendingReceivers.sorted()
        if pendingReceivers.isEmpty {
            dropSource()
        }
        for id in pendingReceivers {
            dropReceiver(id)
        }
        finishRound(failure: "The LlamaXPCService endpoint hand-over timed out waiting on \(waitingOn.joined(separator: ", "))")
    }

    private func finishRound(failure: String?) {
        round = nil
        pendingReceivers = []
        if let failure {
            consecutiveFailures += 1
            let delay = retryDelay()
            logger.error("\(failure, privacy: .public); retrying in \(delay, privacy: .public)s")
            report("\(failure); retrying in \(Int(delay))s", true)
            schedule(after: delay)
        } else {
            consecutiveFailures = 0
            _successfulRounds += 1
            logger.info("Handed the LlamaXPCService endpoint to \(self.receiverIds.joined(separator: ", "), privacy: .public)")
            report("Handed the LlamaXPCService endpoint to \(receiverIds.joined(separator: ", "))", false)
        }
        if rerunRequested {
            rerunRequested = false
            schedule(after: 0)
        }
    }

    private func retryDelay() -> TimeInterval {
        guard consecutiveFailures > 0 else { return lostDelay }
        return retryDelays[min(consecutiveFailures, retryDelays.count) - 1]
    }

    /// Runs a round after `delay`; requests while one is scheduled merge into it.
    private func schedule(after delay: TimeInterval) {
        guard running, !scheduled else { return }
        scheduled = true
        queue.asyncAfter(deadline: .now() + max(delay, 0)) { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.runRound()
        }
    }

    // MARK: - Connections (on `queue`)

    private func currentSource() -> LlamaEndpointSource {
        if let source {
            return source.link
        }
        let token = UUID()
        let link = connector.connectSource { [weak self] in
            self?.queue.async { self?.sourceLost(token) }
        }
        source = (link, token)
        return link
    }

    private func currentReceiver(_ id: String) -> LlamaEndpointReceiver {
        if let existing = receivers[id] {
            return existing.link
        }
        let token = UUID()
        let link = connector.connectReceiver(id) { [weak self] in
            self?.queue.async { self?.receiverLost(id, token: token) }
        }
        receivers[id] = (link, token)
        return link
    }

    /// LlamaXPCService went away: its endpoint died with it. Fetch a new one and hand it to everyone.
    private func sourceLost(_ token: UUID) {
        guard running, source?.token == token else { return }
        logger.warning("Lost the connection to LlamaXPCService; handing a new endpoint over")
        dropSource()
        schedule(after: max(lostDelay, consecutiveFailures > 0 ? retryDelay() : 0))
    }

    /// A receiver went away: a relaunched service has no endpoint. Hand it over again.
    private func receiverLost(_ id: String, token: UUID) {
        guard running, receivers[id]?.token == token else { return }
        logger.warning("Lost the connection to \(id, privacy: .public); handing the endpoint over again")
        dropReceiver(id)
        schedule(after: max(lostDelay, consecutiveFailures > 0 ? retryDelay() : 0))
    }

    /// Forgets the LlamaXPCService connection and its endpoint. Cleared before invalidating, so the
    /// connection's own invalidation callback finds a different token and does nothing.
    private func dropSource() {
        endpoint = nil
        guard let old = source else { return }
        source = nil
        old.link.invalidate()
    }

    private func dropReceiver(_ id: String) {
        guard let old = receivers.removeValue(forKey: id) else { return }
        old.link.invalidate()
    }
}

// MARK: - NSXPC

extension LlamaEndpointConnector {
    /// Connections by service name, which the app (unlike its XPC services) may look up.
    static func xpc(llamaBundleId: String = LlamaXPCConstants.serviceName, receiverBundleIds: [String: String]) -> LlamaEndpointConnector {
        LlamaEndpointConnector(
            connectSource: { onLost in
                XPCLlamaEndpointSource(bundleId: llamaBundleId, onLost: onLost)
            },
            connectReceiver: { id, onLost in
                XPCLlamaEndpointReceiver(bundleId: receiverBundleIds[id] ?? id, onLost: onLost)
            }
        )
    }
}

private final class XPCLlamaEndpointSource: LlamaEndpointSource {
    private let connection: NSXPCConnection
    private let bundleId: String

    init(bundleId: String, onLost: @escaping () -> Void) {
        self.bundleId = bundleId
        connection = GarageInProcessServices.makeConnection(serviceName: bundleId)
        connection.remoteObjectInterface = NSXPCInterface(with: LlamaXPCServiceProtocol.self)
        connection.interruptionHandler = onLost
        connection.invalidationHandler = onLost
        connection.resume()
    }

    func fetchEndpoint(_ reply: @escaping (NSXPCListenerEndpoint?, String?) -> Void) {
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            reply(nil, error.localizedDescription)
        }) as? LlamaXPCServiceProtocol else {
            reply(nil, "no LlamaXPCServiceProtocol proxy for \(bundleId)")
            return
        }
        proxy.getListenerEndpoint { endpoint, error in
            reply(endpoint, error?.localizedDescription ?? (endpoint == nil ? "empty reply" : nil))
        }
    }

    func invalidate() {
        connection.invalidate()
    }
}

private final class XPCLlamaEndpointReceiver: LlamaEndpointReceiver {
    private let connection: NSXPCConnection
    private let bundleId: String

    init(bundleId: String, onLost: @escaping () -> Void) {
        self.bundleId = bundleId
        connection = GarageInProcessServices.makeConnection(serviceName: bundleId)
        // The receiver protocol alone: the services export protocols that adopt it, and NSXPC
        // matches calls by selector.
        connection.remoteObjectInterface = NSXPCInterface(with: GarageLlamaEndpointReceiverProtocol.self)
        connection.interruptionHandler = onLost
        connection.invalidationHandler = onLost
        connection.resume()
    }

    func deliver(_ endpoint: NSXPCListenerEndpoint, _ reply: @escaping (Bool, String?) -> Void) {
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            reply(false, error.localizedDescription)
        }) as? GarageLlamaEndpointReceiverProtocol else {
            reply(false, "no GarageLlamaEndpointReceiverProtocol proxy for \(bundleId)")
            return
        }
        proxy.setLlamaEndpoint(endpoint) { accepted, message in
            reply(accepted, message)
        }
    }

    func invalidate() {
        connection.invalidate()
    }
}

import Foundation
import OSLog
import PythonXPCService

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag", category: "GarageXPCClient")

/// High-level Swift client for communicating with `GarageXPCService`.
public final class GarageXPCClient: @unchecked Sendable {
    public static let serviceName = GarageXPCConstants.serviceName

    private let customServiceName: String?

    public init(serviceName: String = GarageXPCClient.serviceName) {
        self.customServiceName = serviceName
    }

    // MARK: - XPC Connection Helper

    public func makeConnection() -> NSXPCConnection {
        let name = customServiceName ?? GarageXPCClient.serviceName
        logger.debug("Creating NSXPCConnection to GarageXPCService '\(name, privacy: .public)'")
        let connection = GarageInProcessServices.makeConnection(serviceName: name)
        connection.remoteObjectInterface = NSXPCInterface(with: GarageXPCServiceProtocol.self)

        connection.interruptionHandler = {
            logger.warning("GarageXPCClient NSXPCConnection to '\(name, privacy: .public)' was interrupted.")
        }
        connection.invalidationHandler = {
            logger.info("GarageXPCClient NSXPCConnection to '\(name, privacy: .public)' was invalidated.")
        }

        connection.resume()
        return connection
    }

    // MARK: - Relay & Remote Call Helper

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

    private func performRemoteCall<T>(
        _ block: @escaping (GarageXPCServiceProtocol, ContinuationRelay<T>) -> Void
    ) async throws -> T {
        let connection = makeConnection()
        defer { connection.invalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            let relay = ContinuationRelay(continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                logger.error("XPC remote object proxy error for service '\(self.customServiceName ?? GarageXPCClient.serviceName, privacy: .public)': \(error.localizedDescription, privacy: .public)")
                relay.resume(throwing: error)
            }) as? GarageXPCServiceProtocol else {
                let err = NSError(domain: "GarageXPCClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create XPC proxy for GarageXPCService"])
                relay.resume(throwing: err)
                return
            }

            block(proxy, relay)
        }
    }

    // MARK: - Server Control & Operations

    public func ping() async throws -> String {
        try await performRemoteCall { proxy, relay in
            proxy.ping { pong in
                relay.resume(returning: pong)
            }
        }
    }

    public func getServiceInfo() async throws -> (name: String, pid: Int32, uptime: Double, status: String?) {
        try await performRemoteCall { proxy, relay in
            proxy.getServiceInfo { name, pid, uptime, status in
                relay.resume(returning: (name, pid, uptime, status))
            }
        }
    }

    public func runDiagnostic() async throws -> (success: Bool, summary: String?, details: String?) {
        try await performRemoteCall { proxy, relay in
            proxy.runDiagnostic { success, summary, details in
                relay.resume(returning: (success, summary, details))
            }
        }
    }

    public func startServer(host: String, port: Int, options: [String: String]) async throws -> (success: Bool, message: String?) {
        try await performRemoteCall { proxy, relay in
            proxy.startServer(host: host, port: port, options: options) { success, message in
                relay.resume(returning: (success, message))
            }
        }
    }

    public func stopServer() async throws -> (success: Bool, message: String?) {
        try await performRemoteCall { proxy, relay in
            proxy.stopServer { success, message in
                relay.resume(returning: (success, message))
            }
        }
    }

    public func isServerRunning() async throws -> Bool {
        try await performRemoteCall { proxy, relay in
            proxy.isServerRunning { isRunning in
                relay.resume(returning: isRunning)
            }
        }
    }

    public func fetchBufferedOutput(clearBuffer: Bool = true) async throws -> (stdout: String?, stderr: String?) {
        try await performRemoteCall { proxy, relay in
            proxy.fetchBufferedOutput(clearBuffer: clearBuffer) { stdout, stderr, error in
                if let error = error {
                    relay.resume(throwing: error)
                } else {
                    relay.resume(returning: (stdout, stderr))
                }
            }
        }
    }

    public func clearLogs() async throws -> Bool {
        try await performRemoteCall { proxy, relay in
            proxy.clearLogs { success in
                relay.resume(returning: success)
            }
        }
    }
}

import Foundation
import GarageXPCKit
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag", category: "EmbedClient")

/// Swift client for GarageEmbedXPCService, which runs the Rust embed worker (backfill).
public final class EmbedClient: Sendable {
    private let serviceName: String

    public init(serviceName: String = EmbedXPCConstants.serviceName) {
        self.serviceName = serviceName
    }

    /// Receives the steps of one backfill. Log messages are ignored: they also reach the app's log stream.
    private final class ProgressReceiver: NSObject, GarageEmbedProgressReceiverProtocol, @unchecked Sendable {
        private let onEvent: @Sendable (EmbedBackfillEvent) -> Void

        init(onEvent: @escaping @Sendable (EmbedBackfillEvent) -> Void) {
            self.onEvent = onEvent
        }

        func didUpdateBackfill(eventJson: String) {
            guard let event = try? JSONDecoder().decode(EmbedBackfillEvent.self, from: Data(eventJson.utf8)) else {
                logger.warning("Ignoring a backfill event that did not decode")
                return
            }
            onEvent(event)
        }

        func didReceiveStdout(_ text: String) {}
        func didReceiveStderr(_ text: String) {}
        func didReceiveLog(source: String, level: String, message: String, timestamp: Double) {}
    }

    private final class ContinuationRelay<T>: @unchecked Sendable {
        private var continuation: CheckedContinuation<T, Error>?
        private let lock = NSLock()

        init(_ continuation: CheckedContinuation<T, Error>) {
            self.continuation = continuation
        }

        func resume(with result: Result<T, Error>) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(with: result)
        }
    }

    private func call<T>(
        receiver: GarageEmbedProgressReceiverProtocol? = nil,
        _ block: @escaping (GarageEmbedXPCServiceProtocol, @escaping (Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        let connection = GarageInProcessServices.makeConnection(serviceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: GarageEmbedXPCServiceProtocol.self)
        // The service pushes progress at the connection that asked for a backfill; one with no
        // exported receiver would be invalidated by NSXPC, so always export one.
        connection.exportedInterface = NSXPCInterface(with: GarageEmbedProgressReceiverProtocol.self)
        connection.exportedObject = receiver ?? ProgressReceiver(onEvent: { _ in })
        connection.resume()
        defer { connection.invalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            let relay = ContinuationRelay(continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                relay.resume(with: .failure(error))
            }) as? GarageEmbedXPCServiceProtocol else {
                relay.resume(with: .failure(EmbedBackfillError(status: .failed, message: "Failed to create the embed service's XPC proxy")))
                return
            }
            block(proxy) { relay.resume(with: $0) }
        }
    }

    /// Embeds what each model (or `request.model`) lacks; `progress` hears every step. Returns each
    /// model's outcome, or throws `EmbedBackfillError` (`cancelled` when `cancelBackfill` stopped it).
    public func backfill(
        _ request: EmbedBackfillRequest = EmbedBackfillRequest(),
        progress: @escaping @Sendable (EmbedBackfillEvent) -> Void = { _ in }
    ) async throws -> [EmbedBackfillEvent] {
        let requestJson = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        let receiver = ProgressReceiver(onEvent: progress)
        let reply: EmbedBackfillReply = try await call(receiver: receiver) { proxy, done in
            proxy.backfill(requestJson: requestJson) { json in
                do {
                    done(.success(try JSONDecoder().decode(EmbedBackfillReply.self, from: Data(json.utf8))))
                } catch {
                    done(.failure(EmbedBackfillError(status: .failed, message: "The embed service's reply did not decode: \(error.localizedDescription)")))
                }
            }
        }
        guard reply.status == .ok else {
            throw EmbedBackfillError(status: reply.status, message: reply.error ?? "The backfill did not finish")
        }
        return reply.outcomes
    }

    /// Tells the service where GarageService listens and with which token (`helperConfiguration`).
    public func updateConfiguration(_ options: [String: String]) async throws {
        let (accepted, message): (Bool, String?) = try await call { proxy, done in
            proxy.updateConfiguration(options) { done(.success(($0, $1))) }
        }
        if !accepted {
            throw EmbedBackfillError(status: .failed, message: message ?? "The embed service did not take the configuration")
        }
    }

    /// Stops the backfill in progress at its next batch.
    @discardableResult
    public func cancelBackfill() async throws -> Bool {
        try await call { proxy, done in
            proxy.cancelBackfill { done(.success($0)) }
        }
    }
}

import Foundation
import OSLog
import PythonXPCService

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag", category: "IngestClient")

/// Progress receiver adapter for XPC callbacks.
private final class IngestProgressReceiver: NSObject, GarageIngestProgressReceiverProtocol {
    private let onProgress: (@Sendable (IngestProgressUpdate) -> Void)?
    private let onLog: (@Sendable (String, Int32) -> Void)?
    private let engine = IngestEngine.shared

    init(
        onProgress: (@Sendable (IngestProgressUpdate) -> Void)? = nil,
        onLog: (@Sendable (String, Int32) -> Void)? = nil
    ) {
        self.onProgress = onProgress
        self.onLog = onLog
    }

    func didUpdateProgress(progressJson: String) {
        if let update = try? engine.deserialize(IngestProgressUpdate.self, from: progressJson) {
            logger.debug("IngestProgressReceiver received update: phase=\(update.phase, privacy: .public), seen=\(update.seen)/\(update.totalItems), msg=\(update.message, privacy: .public)")
            onProgress?(update)
        } else {
            logger.warning("IngestProgressReceiver failed to decode progress JSON: \(progressJson, privacy: .public)")
        }
    }

    func didReceiveLog(message: String, level: Int32) {
        onLog?(message, level)
    }

    func didReceiveStdout(_ text: String) {
        onLog?(text, 20)
    }

    func didReceiveStderr(_ text: String) {
        onLog?(text, 40)
    }

    func didReceiveLog(source: String, level: String, message: String, timestamp: Double) {
        let numericLevel: Int32
        switch level.uppercased() {
        case "ERROR", "CRITICAL", "FATAL": numericLevel = 40
        case "WARN", "WARNING": numericLevel = 30
        case "DEBUG", "TRACE": numericLevel = 10
        default: numericLevel = 20
        }
        onLog?("[\(source)] \(message)", numericLevel)
    }
}

/// High-level Swift client for communicating with `GarageIngestXPCService`.
public final class IngestClient: Sendable {
    public static let serviceName = IngestXPCConstants.serviceName

    private let customServiceName: String?

    public init(serviceName: String = IngestClient.serviceName) {
        self.customServiceName = serviceName
    }

    // MARK: - XPC Connection Helper

    private func makeConnection(progressReceiver: GarageIngestProgressReceiverProtocol? = nil) -> NSXPCConnection {
        let name = customServiceName ?? IngestClient.serviceName
        logger.debug("Creating NSXPCConnection to service '\(name, privacy: .public)'")
        let connection = GarageInProcessServices.makeConnection(serviceName: name)
        connection.remoteObjectInterface = NSXPCInterface(with: GarageIngestXPCServiceProtocol.self)

        // The ingest helper fans progress / log messages out to every connected client. A connection without an
        // exported receiver would treat those as undecodable messages and get invalidated mid-call, so always
        // export one (a silent receiver when the caller is not interested in progress).
        connection.exportedInterface = NSXPCInterface(with: GarageIngestProgressReceiverProtocol.self)
        connection.exportedObject = progressReceiver ?? IngestProgressReceiver()

        connection.interruptionHandler = {
            logger.warning("IngestClient NSXPCConnection to '\(name, privacy: .public)' was interrupted.")
        }
        connection.invalidationHandler = {
            logger.info("IngestClient NSXPCConnection to '\(name, privacy: .public)' was invalidated.")
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
        progressReceiver: GarageIngestProgressReceiverProtocol? = nil,
        _ block: @escaping (GarageIngestXPCServiceProtocol, ContinuationRelay<T>) -> Void
    ) async throws -> T {
        let connection = makeConnection(progressReceiver: progressReceiver)
        defer { connection.invalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            let relay = ContinuationRelay(continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                logger.error("XPC remote object proxy error for service '\(self.customServiceName ?? IngestClient.serviceName, privacy: .public)': \(error.localizedDescription, privacy: .public)")
                relay.resume(throwing: error)
            }) as? GarageIngestXPCServiceProtocol else {
                let err = NSError(domain: "IngestClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create XPC proxy"])
                logger.error("\(err.localizedDescription, privacy: .public)")
                relay.resume(throwing: err)
                return
            }

            block(proxy, relay)
        }
    }

    // MARK: - API Methods

    public func ping() async throws -> String {
        logger.info("ping: dispatching remote XPC ping")
        return try await performRemoteCall { proxy, relay in
            proxy.ping { reply in
                relay.resume(returning: reply)
            }
        }
    }

    public func setRootVolumeBookmark(_ bookmarkData: Data) async throws -> Bool {
        logger.info("setRootVolumeBookmark: dispatching via XPC (\(bookmarkData.count) bytes)")
        return try await performRemoteCall { proxy, relay in
            proxy.setRootVolumeBookmark(bookmarkData) { success, _ in
                relay.resume(returning: success)
            }
        }
    }

    public func setSourceBookmark(path: String, bookmarkData: Data) async throws -> Bool {
        logger.info("setSourceBookmark: dispatching via XPC for '\(path, privacy: .public)' (\(bookmarkData.count) bytes)")
        return try await performRemoteCall { proxy, relay in
            proxy.setSourceBookmark(path: path, bookmarkData: bookmarkData) { success, _ in
                relay.resume(returning: success)
            }
        }
    }

    public func revokeAccess() async throws -> Bool {
        logger.info("revokeAccess: dispatching via XPC")
        return try await performRemoteCall { proxy, relay in
            proxy.revokeAccess { success in
                relay.resume(returning: success)
            }
        }
    }

    public func cancelIngest() async throws -> Bool {
        logger.info("cancelIngest: dispatching via XPC")
        return try await performRemoteCall { proxy, relay in
            proxy.cancelIngest { success in
                relay.resume(returning: success)
            }
        }
    }

    public func configureEnvironment(databaseUrl: String?, lmStudioApiToken: String? = nil) async throws -> (Bool, String?) {
        logger.info("configureEnvironment: dispatching via XPC")
        return try await performRemoteCall { proxy, relay in
            proxy.configureEnvironment(databaseUrl: databaseUrl, lmStudioApiToken: lmStudioApiToken) { success, message in
                relay.resume(returning: (success, message))
            }
        }
    }

    public func setDatabaseURL(_ databaseUrl: String, lmStudioApiToken: String? = nil) async throws -> Bool {
        logger.info("setDatabaseURL: dispatching via XPC")
        return try await performRemoteCall { proxy, relay in
            proxy.setDatabaseURL(databaseUrl, lmStudioApiToken: lmStudioApiToken) { success, _ in
                relay.resume(returning: success)
            }
        }
    }

    public func testVolumeAccess(request: VolumeAccessTestRequest) async throws -> IngestVolumeAccessTestResult {
        guard let jsonString = IngestEngine.shared.serialize(request) else {
            let err = NSError(domain: "IngestClient", code: 400, userInfo: [NSLocalizedDescriptionKey: "Failed to encode VolumeAccessTestRequest"])
            logger.error("\(err.localizedDescription, privacy: .public)")
            throw err
        }

        logger.info("testVolumeAccess: dispatching via XPC")
        return try await performRemoteCall { proxy, relay in
            proxy.testVolumeAccess(requestJson: jsonString) { replyJson, error in
                if let error = error {
                    relay.resume(throwing: error)
                } else if let replyJson = replyJson {
                    do {
                        let result = try IngestEngine.shared.deserialize(IngestVolumeAccessTestResult.self, from: replyJson)
                        relay.resume(returning: result)
                    } catch {
                        relay.resume(throwing: error)
                    }
                } else {
                    relay.resume(throwing: NSError(domain: "IngestClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Empty reply from service"]))
                }
            }
        }
    }

    public func ingest(
        slug: String,
        options: IngestOptions = .default,
        onLog: (@Sendable (String, Int32) -> Void)? = nil,
        onProgress: (@Sendable (IngestProgressUpdate) -> Void)? = nil
    ) async throws -> IngestResult {
        logger.info("IngestClient.ingest called for slug '\(slug, privacy: .public)' (includeCode: \(options.includeCode), force: \(options.force), limit: \(String(describing: options.limit)))")

        guard let optionsJson = IngestEngine.shared.serialize(options) else {
            let errorMsg = "Failed to encode IngestOptions for \(slug)"
            logger.error("\(errorMsg, privacy: .public)")
            onProgress?(IngestProgressUpdate(
                source: slug,
                phase: "error",
                message: errorMsg,
                error: errorMsg
            ))
            return IngestResult(succeeded: false, message: errorMsg)
        }

        let receiver: IngestProgressReceiver? = (onProgress != nil || onLog != nil) ? IngestProgressReceiver(onProgress: onProgress, onLog: onLog) : nil

        do {
            logger.info("Dispatching ingestSource via XPC for '\(slug, privacy: .public)'")
            let result = try await performRemoteCall(progressReceiver: receiver) { proxy, relay in
                proxy.ingestSource(slug: slug, optionsJson: optionsJson) { success, message in
                    relay.resume(returning: IngestResult(succeeded: success, message: message))
                }
            }
            logger.info("IngestSource XPC reply for '\(slug, privacy: .public)': succeeded=\(result.succeeded), message=\(result.message ?? "nil", privacy: .public)")
            if !result.succeeded, let message = result.message {
                onProgress?(IngestProgressUpdate(
                    source: slug,
                    phase: "error",
                    message: message,
                    error: message
                ))
            }
            return result
        } catch {
            let errorMsg = "XPC helper error for '\(slug)': \(error.localizedDescription)"
            logger.error("\(errorMsg, privacy: .public)")
            onProgress?(IngestProgressUpdate(
                source: slug,
                phase: "error",
                message: errorMsg,
                error: errorMsg
            ))
            return IngestResult(succeeded: false, message: errorMsg)
        }
    }

    public func ingestStream(
        slug: String,
        options: IngestOptions = .default
    ) -> AsyncThrowingStream<IngestProgressUpdate, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let result = try await self.ingest(slug: slug, options: options, onLog: nil) { progress in
                        continuation.yield(progress)
                    }
                    if !result.succeeded {
                        let errMsg = result.message ?? "Ingest failed"
                        continuation.finish(throwing: NSError(domain: "IngestClient", code: 500, userInfo: [NSLocalizedDescriptionKey: errMsg]))
                    } else {
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

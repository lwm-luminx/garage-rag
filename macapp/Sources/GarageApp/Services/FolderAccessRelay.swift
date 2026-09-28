import Foundation
import OSLog
import IngestClient
import PythonXPCService

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag", category: "FolderAccessRelay")

/// Passes the folders and files the user granted in the app on to the XPC services that touch them.
public protocol FolderAccessRelaying: Sendable {
    /// Sends `url` to every receiving service under `key` (`GarageFolderAccessKey`). Returns once
    /// each has replied, true when all of them can reach it.
    @discardableResult
    func grant(_ url: URL, key: String) async -> Bool

    /// Makes every receiving service drop all its grants.
    func revokeAll() async
}

/// Sends grants over NSXPC as `URL`s, which carry a sandbox extension for the receiving service
/// (`GarageFolderAccessReceiverProtocol`); the app's own bookmarks would resolve to nothing there.
///
/// The receivers are the ingest service, which reads the sources, and GarageXPCService, the gRPC
/// host, which runs Scan, AddSource's existence check and McpInstall's client config writes.
public final class XPCFolderAccessRelay: FolderAccessRelaying {
    public static let receiverServiceNames = [IngestXPCConstants.serviceName, GarageXPCConstants.serviceName]

    private let serviceNames: [String]

    public init(serviceNames: [String] = XPCFolderAccessRelay.receiverServiceNames) {
        self.serviceNames = serviceNames
    }

    @discardableResult
    public func grant(_ url: URL, key: String) async -> Bool {
        var allReached = true
        for name in serviceNames {
            let (reached, message) = await call(name) { proxy, reply in
                proxy.grantFolderAccess(url, key: key) { ok, message in reply(ok, message) }
            }
            if reached {
                logger.info("\(name, privacy: .public) took the grant for \(url.path, privacy: .public): \(message ?? "", privacy: .public)")
            } else {
                logger.error("\(name, privacy: .public) could not take the grant for \(url.path, privacy: .public): \(message ?? "no reply", privacy: .public)")
                allReached = false
            }
        }
        return allReached
    }

    public func revokeAll() async {
        for name in serviceNames {
            _ = await call(name) { proxy, reply in
                proxy.revokeAllFolderAccess { ok in reply(ok, nil) }
            }
        }
    }

    /// One call on a fresh connection that lives until the reply. The receiver protocol alone: the
    /// services export protocols that adopt it, and NSXPC matches calls by selector.
    private func call(
        _ serviceName: String,
        _ body: @escaping (GarageFolderAccessReceiverProtocol, @escaping (Bool, String?) -> Void) -> Void
    ) async -> (Bool, String?) {
        let connection = GarageInProcessServices.makeConnection(serviceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: GarageFolderAccessReceiverProtocol.self)
        connection.resume()
        defer { connection.invalidate() }

        return await withCheckedContinuation { continuation in
            let once = ReplyOnce(continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                once.resume((false, error.localizedDescription))
            }) as? GarageFolderAccessReceiverProtocol else {
                once.resume((false, "no GarageFolderAccessReceiverProtocol proxy for \(serviceName)"))
                return
            }
            body(proxy) { ok, message in once.resume((ok, message)) }
        }
    }

    private final class ReplyOnce: @unchecked Sendable {
        private var continuation: CheckedContinuation<(Bool, String?), Never>?
        private let lock = NSLock()

        init(_ continuation: CheckedContinuation<(Bool, String?), Never>) {
            self.continuation = continuation
        }

        func resume(_ value: (Bool, String?)) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }
}

/// Records grants instead of sending them, for tests and headless runs.
public final class RecordingFolderAccessRelay: FolderAccessRelaying, @unchecked Sendable {
    private let lock = NSLock()
    private var _grants: [(key: String, path: String)] = []
    private var _revocations = 0
    /// What `grant` returns.
    public var grantSucceeds = true

    public init() {}

    public var grants: [(key: String, path: String)] {
        lock.lock()
        defer { lock.unlock() }
        return _grants
    }

    public var revocations: Int {
        lock.lock()
        defer { lock.unlock() }
        return _revocations
    }

    @discardableResult
    public func grant(_ url: URL, key: String) async -> Bool {
        lock.lock()
        _grants.append((key, url.path))
        let result = grantSucceeds
        lock.unlock()
        return result
    }

    public func revokeAll() async {
        lock.lock()
        _revocations += 1
        lock.unlock()
    }
}

import Foundation

/// Hands a folder (or file) the user granted in the app to an XPC service that reads or writes it.
///
/// In the App Store build the app and each XPC service are sandboxed separately. A security-scoped
/// bookmark the app makes is app-scoped: no other process can resolve it into access. A file `URL`
/// sent over NSXPC is different: while the sending process can reach the item, the URL carries a
/// sandbox extension, which the receiving service consumes with `startAccessingSecurityScopedResource()`.
/// That is how the app gives its folder grants to the ingest service (reads sources) and to the gRPC
/// host, GarageXPCService (Scan, AddSource's check, McpInstall's client config writes).
///
/// Adopted by `GarageXPCServiceProtocol` and `GarageIngestXPCServiceProtocol`; `GarageXPCServiceBase`
/// implements it over `GarageFolderAccessStore.shared`.
@objc(GarageFolderAccessReceiverProtocol)
public protocol GarageFolderAccessReceiverProtocol: NSObjectProtocol {
    /// Starts accessing `url` in this process and keeps it under `key` (see `GarageFolderAccessKey`),
    /// replacing what was kept there. Replies whether the service can now reach `url`.
    func grantFolderAccess(_ url: URL, key: String, with reply: @escaping (Bool, String?) -> Void)

    /// Stops accessing everything granted so far and forgets it, including the saved bookmarks.
    func revokeAllFolderAccess(with reply: @escaping (Bool) -> Void)
}

/// Keys the app files grants under, so a new root grant replaces the old one.
public enum GarageFolderAccessKey {
    /// The home folder or startup disk every source is read through.
    public static let root = "root"

    /// A folder granted for one source (Mail, Messages, a custom folder).
    public static func source(_ path: String) -> String {
        "source:\(path)"
    }

    /// A single file, such as an MCP client config chosen in an open panel.
    public static func file(_ path: String) -> String {
        "file:\(path)"
    }
}

/// The grants one process holds (`GarageFolderAccessReceiverProtocol`'s receiving side).
///
/// A service keeps a bookmark of its own for each grant it could start accessing, in its own
/// defaults, and `restorePersisted()` resolves them at launch. An XPC service can be relaunched
/// between the app's hand-overs (idle exit, a crash, the app restarting it), and its own bookmarks,
/// unlike the app's, resolve in it.
public final class GarageFolderAccessStore: @unchecked Sendable {
    public static let shared = GarageFolderAccessStore()

    public static let defaultsKey = "garage.folderAccessBookmarks"

    private struct Grant {
        let url: URL
        let scoped: Bool
    }

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let defaultsKey: String
    private var grants: [String: Grant] = [:]

    public init(defaults: UserDefaults = .standard, defaultsKey: String = GarageFolderAccessStore.defaultsKey) {
        self.defaults = defaults
        self.defaultsKey = defaultsKey
    }

    /// The paths currently granted, by key.
    public var grantedPaths: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return grants.mapValues(\.url.path)
    }

    /// Starts accessing `url` under `key`. Succeeds when the URL's sandbox extension could be
    /// consumed, or when the item is reachable anyway (an unsandboxed Developer ID service, where
    /// there is no extension to consume).
    @discardableResult
    public func grant(_ url: URL, key: String) -> (success: Bool, message: String) {
        let scoped = url.startAccessingSecurityScopedResource()
        let reachable = scoped || FileManager.default.isReadableFile(atPath: url.path)

        lock.lock()
        let previous = grants[key]
        if reachable {
            grants[key] = Grant(url: url, scoped: scoped)
        }
        lock.unlock()

        guard reachable else {
            return (false, "Cannot reach \(url.path): the grant carried no access for this process")
        }
        if let previous, previous.scoped {
            previous.url.stopAccessingSecurityScopedResource()
        }
        if scoped, let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            updateSaved { $0[key] = data }
        } else {
            updateSaved { $0.removeValue(forKey: key) }
        }
        return (true, "Granted \(url.path) (\(scoped ? "security-scoped" : "direct"))")
    }

    /// Resolves the bookmarks saved by earlier grants and starts accessing them. Ones that no
    /// longer resolve are dropped; stale ones are saved again.
    @discardableResult
    public func restorePersisted() -> [String] {
        var restored: [String] = []
        for (key, data) in saved() {
            var isStale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale),
                  url.startAccessingSecurityScopedResource() else {
                updateSaved { $0.removeValue(forKey: key) }
                continue
            }
            lock.lock()
            let previous = grants[key]
            grants[key] = Grant(url: url, scoped: true)
            lock.unlock()
            if let previous, previous.scoped {
                previous.url.stopAccessingSecurityScopedResource()
            }
            if isStale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                updateSaved { $0[key] = fresh }
            }
            restored.append(url.path)
        }
        return restored
    }

    /// Stops accessing every grant and deletes the saved bookmarks.
    public func revokeAll() {
        lock.lock()
        let old = grants
        grants.removeAll()
        lock.unlock()
        for grant in old.values where grant.scoped {
            grant.url.stopAccessingSecurityScopedResource()
        }
        defaults.removeObject(forKey: defaultsKey)
    }

    private func saved() -> [String: Data] {
        (defaults.dictionary(forKey: defaultsKey) as? [String: Data]) ?? [:]
    }

    private func updateSaved(_ change: (inout [String: Data]) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var dict = saved()
        change(&dict)
        if dict.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
        } else {
            defaults.set(dict, forKey: defaultsKey)
        }
    }
}

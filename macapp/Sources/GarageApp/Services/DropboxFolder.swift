import Foundation
import PythonXPCService

/// Where this account's Dropbox folder is.
///
/// Dropbox on File Provider (macOS 12.5 and later) keeps the folder at
/// `~/Library/CloudStorage/Dropbox`. A Mac that migrated to it keeps `~/Dropbox` as a link, and a
/// Mac still on the older client has the folder there, but a fresh File Provider install may have
/// no `~/Dropbox` at all. Dropbox also writes the folder path of each linked account to
/// `~/.dropbox/info.json`, which it documents as the way other apps find the folder.
enum DropboxFolder {
    /// The folder Dropbox on File Provider uses, under the home folder.
    static let cloudStoragePath = "Library/CloudStorage/Dropbox"

    /// The path the Dropbox preset offers, with the home folder as `~`. `~/Dropbox` when it exists
    /// (a real folder or the link the migration leaves), then the personal account's folder from
    /// `info.json`, then a business account's, then the File Provider folder; nil when none exists.
    static func locate(
        home: URL,
        exists: (String) -> Bool,
        infoJSON: () -> Data?
    ) -> String? {
        let homePath = home.standardizedFileURL.path
        var candidates = [homePath + "/Dropbox"]
        candidates += accountPaths(in: infoJSON())
        candidates.append(homePath + "/" + cloudStoragePath)
        guard let found = candidates.first(where: exists) else { return nil }
        return abbreviatingHome(found, home: homePath)
    }

    /// `locate` against the real home folder and disk. A folder once found is remembered for the
    /// rest of the launch (it does not move); "not found" is probed again on every call, because in
    /// the sandbox the folder only becomes visible once the user grants the home folder.
    static func locate() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let found {
            return found
        }
        let home = URL(fileURLWithPath: GarageAppGroup.realHomeDirectory, isDirectory: true)
        found = locate(
            home: home,
            exists: { FileManager.default.fileExists(atPath: $0) },
            infoJSON: { try? Data(contentsOf: home.appendingPathComponent(".dropbox/info.json")) }
        )
        return found
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var found: String?

    /// The `path` of each account in `info.json` (`{"personal": {"path": ...}, "business": {...}}`),
    /// personal first.
    static func accountPaths(in data: Data?) -> [String] {
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let order = ["personal", "business"]
        let ordered = order.compactMap { json[$0] } + json.filter { !order.contains($0.key) }.sorted { $0.key < $1.key }.map(\.value)
        return ordered.compactMap { ($0 as? [String: Any])?["path"] as? String }.filter { $0.hasPrefix("/") }
    }

    /// `path` with the home folder written as `~`, so the preset reads and stores like the others.
    static func abbreviatingHome(_ path: String, home: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

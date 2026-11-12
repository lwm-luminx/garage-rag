import Foundation
import GarageXPCKit

/// The desktop clients behind the cloud folder kinds, and where each keeps its folder on this node.
///
/// A cloud source is linked to its service's own app when the app keeps its folder on this node:
/// the API lists the files and spots changes, and a file whose copy in the folder is on disk and
/// matches is read from there (`garage-ingest`'s `dropbox::local_folder`, which finds the folder the
/// way `locate` does). Online-only files are downloaded through the API. Without the app, the Sources
/// page offers to install it. Dropbox is linked today; OneDrive and Google Drive keep their folders
/// in the same place and are found here for when their sources link too.
enum CloudClientFolders {
    struct Client: Equatable {
        /// The app's name, as the page shows it.
        let app: String
        /// Where to get the app.
        let installURL: URL
    }

    /// Whether a source's app keeps its folder on this node.
    enum State: Equatable {
        /// The folder, with the home folder as `~`.
        case linked(Client, folder: String)
        case notInstalled(Client)
    }

    /// The desktop client a source of `kind` is linked to; nil for a kind that does not link.
    static func client(for kind: String) -> Client? {
        switch kind.lowercased() {
        case "dropbox":
            Client(app: "Dropbox", installURL: URL(string: "https://www.dropbox.com/install")!)
        default:
            nil
        }
    }

    /// The link state of a source of `kind` on this node; nil for a kind that does not link.
    static func state(for kind: String) -> State? {
        guard let client = client(for: kind) else { return nil }
        return locate(kind: kind).map { .linked(client, folder: $0) } ?? .notInstalled(client)
    }

    /// The folder `kind`'s client keeps, with the home folder as `~`, or nil when it is not found.
    ///
    /// - Dropbox: `DropboxFolder.locate` (`~/Dropbox`, `~/.dropbox/info.json`, File Provider).
    /// - OneDrive: the File Provider folder `~/Library/CloudStorage/OneDrive-…` (personal before a
    ///   business account's), else the older client's `~/OneDrive`.
    /// - Google Drive: `~/Library/CloudStorage/GoogleDrive-<account>/My Drive`, or the account's
    ///   folder when it has no My Drive.
    static func locate(
        kind: String,
        home: String,
        cloudStorageEntries: [String],
        exists: (String) -> Bool,
        dropbox: () -> String?
    ) -> String? {
        let cloudStorage = home + "/Library/CloudStorage"
        let found: String?
        switch kind.lowercased() {
        case "dropbox":
            return dropbox()
        case "onedrive":
            let accounts = cloudStorageEntries.filter { $0.hasPrefix("OneDrive") }.sorted { lhs, rhs in
                let lhsPersonal = lhs == "OneDrive-Personal" || lhs == "OneDrive"
                let rhsPersonal = rhs == "OneDrive-Personal" || rhs == "OneDrive"
                return lhsPersonal != rhsPersonal ? lhsPersonal : lhs < rhs
            }
            found = accounts.first.map { cloudStorage + "/" + $0 } ?? [home + "/OneDrive"].first(where: exists)
        case "google_drive":
            found = cloudStorageEntries.filter { $0.hasPrefix("GoogleDrive-") }.sorted().first.map { account in
                let myDrive = cloudStorage + "/" + account + "/My Drive"
                return exists(myDrive) ? myDrive : cloudStorage + "/" + account
            }
        default:
            return nil
        }
        return found.map { DropboxFolder.abbreviatingHome($0, home: home) }
    }

    /// `locate` against the real home folder and disk. In the sandbox the folders are visible only
    /// once the person has granted the home folder, so this is asked afresh each time.
    static func locate(kind: String) -> String? {
        let home = URL(fileURLWithPath: GarageAppGroup.realHomeDirectory, isDirectory: true).standardizedFileURL.path
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: home + "/Library/CloudStorage")) ?? []
        return locate(
            kind: kind,
            home: home,
            cloudStorageEntries: entries,
            exists: { FileManager.default.fileExists(atPath: $0) },
            dropbox: { DropboxFolder.locate() }
        )
    }
}

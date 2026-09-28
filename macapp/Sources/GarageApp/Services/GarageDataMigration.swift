import Darwin
import Foundation
import OSLog
import PythonXPCService

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag", category: "GarageDataMigration")

/// Moves the data directory from where builds before the App Group kept it (the per-user
/// Application Support, or the App Store build's sandbox container) into the group container
/// both distributions share.
///
/// It only renames, never copies or deletes data:
/// - an entry moves when the shared folder has nothing by that name, or only an empty directory
///   (XPC services may have created `models/` or `logs/` first);
/// - anything the shared folder already has is left where it is, so a second build's cluster never
///   overwrites the first one's;
/// - `pgdata` stays put while a postmaster still runs from it.
/// Once the old folder is empty it becomes a symlink to the shared one, so older builds and any
/// saved path keep working.
enum GarageDataMigration {
    struct Outcome: Equatable {
        var moved: [String] = []
        /// Entry name → why it stayed in the old folder.
        var skipped: [String: String] = [:]
        var linkedLegacyDirectory = false
    }

    /// Runs once at app launch, before Postgres or any XPC service starts. Never in tests, and never
    /// on a `--data-directory` override: in both, the legacy folder is the developer's real one, and
    /// moving it into a test's folder would let that test's reset delete it.
    @discardableResult
    static func runAtLaunch() -> Outcome {
        guard !isRunningInTestEnvironment, GarageAppGroup.dataDirectoryOverride == nil,
              let shared = GarageAppGroup.sharedDataDirectory else {
            return Outcome()
        }
        let outcome = migrate(from: GarageAppGroup.legacyDataDirectory, to: shared)
        for name in outcome.moved {
            logger.notice("Moved \(name, privacy: .public) into the shared data folder \(shared.path, privacy: .public)")
        }
        for (name, reason) in outcome.skipped.sorted(by: { $0.key < $1.key }) {
            logger.warning("Left \(name, privacy: .public) in \(GarageAppGroup.legacyDataDirectory.path, privacy: .public): \(reason, privacy: .public)")
        }
        if !GarageAppGroup.isSandboxed, !outcome.linkedLegacyDirectory,
           linkLegacyDirectory(GarageAppGroup.legacyDataDirectory, to: shared) {
            logger.notice("Linked \(GarageAppGroup.legacyDataDirectory.path, privacy: .public) to the shared data folder \(shared.path, privacy: .public)")
        }
        return outcome
    }

    /// Unsandboxed (Developer ID) builds: keep `~/Library/Application Support/GarageApp` as a link to
    /// the shared folder, which otherwise sits out of sight in `~/Library/Group Containers`, so Finder,
    /// Terminal and support instructions that name the familiar path still land on the data. The
    /// migration leaves this link when it empties an old folder; this also makes it on a fresh
    /// install. It only fills a vacancy: a folder still there (data another build left behind) or any
    /// other link, even a dangling one, is left alone. Returns whether it made the link.
    @discardableResult
    static func linkLegacyDirectory(_ legacy: URL, to shared: URL, fileManager: FileManager = .default) -> Bool {
        let legacy = legacy.standardizedFileURL
        let shared = shared.standardizedFileURL
        guard legacy.resolvingSymlinksInPath() != shared.resolvingSymlinksInPath(),
              (try? fileManager.attributesOfItem(atPath: legacy.path)) == nil else {
            return false
        }
        do {
            try fileManager.createDirectory(at: shared, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.createSymbolicLink(at: legacy, withDestinationURL: shared)
            return true
        } catch {
            logger.warning("Could not link \(legacy.path, privacy: .public) to the shared folder: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// `isPostmaster` decides whether the pid in `pgdata/postmaster.pid` is a running postgres; tests
    /// replace it, since no test process is one.
    static func migrate(
        from legacy: URL,
        to shared: URL,
        fileManager: FileManager = .default,
        isPostmaster: (Int32) -> Bool = GarageDataMigration.isPostgresProcess
    ) -> Outcome {
        var outcome = Outcome()
        let legacy = legacy.standardizedFileURL
        let shared = shared.standardizedFileURL
        guard legacy.resolvingSymlinksInPath() != shared.resolvingSymlinksInPath(),
              isRealDirectory(legacy, fileManager) else {
            return outcome
        }
        do {
            try fileManager.createDirectory(at: shared, withIntermediateDirectories: true)
        } catch {
            outcome.skipped["*"] = "could not create the shared folder: \(error.localizedDescription)"
            return outcome
        }

        for name in entries(of: legacy, fileManager) {
            let source = legacy.appendingPathComponent(name)
            let destination = shared.appendingPathComponent(name)
            if name == "pgdata", let pid = runningPostmaster(in: source, isPostmaster: isPostmaster) {
                outcome.skipped[name] = "postgres (pid \(pid)) is still running from it"
                continue
            }
            if fileManager.fileExists(atPath: destination.path) {
                guard isEmptyDirectory(destination, fileManager) else {
                    outcome.skipped[name] = "the shared folder already has one"
                    continue
                }
                do {
                    try removeEmptyDirectory(destination, fileManager)
                } catch {
                    outcome.skipped[name] = "could not replace the empty one in the shared folder: \(error.localizedDescription)"
                    continue
                }
            }
            do {
                try fileManager.moveItem(at: source, to: destination)
                outcome.moved.append(name)
            } catch {
                outcome.skipped[name] = "move failed: \(error.localizedDescription)"
            }
        }

        if entries(of: legacy, fileManager).isEmpty {
            do {
                try removeEmptyDirectory(legacy, fileManager)
                try fileManager.createSymbolicLink(at: legacy, withDestinationURL: shared)
                outcome.linkedLegacyDirectory = true
            } catch {
                logger.warning("Could not link \(legacy.path, privacy: .public) to the shared folder: \(error.localizedDescription, privacy: .public)")
            }
        }
        return outcome
    }

    /// True when `legacy` still holds a cluster that did not reach `shared`: starting Postgres
    /// would otherwise initdb a new, empty one and hide the real corpus.
    static func hasUnmigratedCluster(legacy: URL = GarageAppGroup.legacyDataDirectory, shared: URL = Paths.appSupportDir) -> Bool {
        guard legacy.resolvingSymlinksInPath() != shared.resolvingSymlinksInPath() else { return false }
        return FileManager.default.fileExists(atPath: legacy.appendingPathComponent("pgdata/PG_VERSION").path)
    }

    /// The pid in `pgdata/postmaster.pid` when that process is alive and is a `postgres`. A stale
    /// file (after a crash, or a reboot that handed its pid to another process) does not block the
    /// move; postgres clears it on the next start.
    static func runningPostmaster(in pgdata: URL, isPostmaster: (Int32) -> Bool = GarageDataMigration.isPostgresProcess) -> Int32? {
        let pidFile = pgdata.appendingPathComponent("postmaster.pid")
        guard let content = try? String(contentsOf: pidFile, encoding: .utf8),
              let firstLine = content.split(separator: "\n").first,
              let pid = Int32(firstLine.trimmingCharacters(in: .whitespaces)),
              pid > 0,
              isPostmaster(pid) else {
            return nil
        }
        return pid
    }

    /// Whether `pid` may be a live postmaster: a process whose executable is named `postgres`.
    /// A pid that is gone, or that belongs to another user (the app's postmaster always runs as this
    /// user), is not. A live process of this user whose path cannot be read counts as one, so a
    /// failed lookup never lets a running cluster lose its lock file.
    static func isPostgresProcess(_ pid: Int32) -> Bool {
        guard kill(pid, 0) == 0 else { return false }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return true }
        return (String(cString: buffer) as NSString).lastPathComponent == "postgres"
    }

    private static let ignoredNames: Set<String> = [".DS_Store"]

    private static func entries(of directory: URL, _ fileManager: FileManager) -> [String] {
        ((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { !ignoredNames.contains($0) }
            .sorted()
    }

    private static func isRealDirectory(_ url: URL, _ fileManager: FileManager) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { return false }
        return attributes[.type] as? FileAttributeType == .typeDirectory
    }

    private static func isEmptyDirectory(_ url: URL, _ fileManager: FileManager) -> Bool {
        isRealDirectory(url, fileManager) && entries(of: url, fileManager).isEmpty
    }

    /// Removes a directory that holds nothing but ignored files such as `.DS_Store`.
    private static func removeEmptyDirectory(_ url: URL, _ fileManager: FileManager) throws {
        for name in ignoredNames where fileManager.fileExists(atPath: url.appendingPathComponent(name).path) {
            try fileManager.removeItem(at: url.appendingPathComponent(name))
        }
        guard rmdir(url.path) == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path, NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)])
        }
    }
}

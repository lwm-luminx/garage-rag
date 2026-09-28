import Foundation
import AppKit
import IngestClient
import PythonXPCService

/// Represents categories of TCC (Transparency, Consent, and Control) permissions in macOS.
public enum TCCPermissionCategory: String, Sendable, Codable, CaseIterable {
    case messages = "apple-sms"
    case mail = "apple-mail"
    case documents = "documents"
    case downloads = "downloads"
    case desktop = "desktop"
    case fullDiskAccess = "full-disk-access"
    case filesAndFolders = "files-and-folders"

    public var displayName: String {
        switch self {
        case .messages:
            return "Messages"
        case .mail:
            return "Mail"
        case .documents:
            return "Documents"
        case .downloads:
            return "Downloads"
        case .desktop:
            return "Desktop"
        case .fullDiskAccess:
            return "Full Disk Access"
        case .filesAndFolders:
            return "Files & Folders"
        }
    }

    public var iconName: String {
        switch self {
        case .messages:
            return "message.fill"
        case .mail:
            return "envelope.fill"
        case .documents:
            return "doc.text.fill"
        case .downloads:
            return "arrow.down.circle.fill"
        case .desktop:
            return "menubar.dock.rectangle"
        case .fullDiskAccess:
            return "internaldrive.fill"
        case .filesAndFolders:
            return "folder.fill.badge.gearshape"
        }
    }

    public var systemSettingsURL: URL? {
        switch self {
        case .messages, .mail, .fullDiskAccess:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        case .documents, .downloads, .desktop, .filesAndFolders:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")
        }
    }

    public var helpMessage: String {
        switch self {
        case .messages:
            return fullDiskAccessSteps(sandboxed: GarageAppGroup.isSandboxed)
        case .mail:
            return fullDiskAccessSteps(sandboxed: GarageAppGroup.isSandboxed)
        case .documents:
            return "Permission to access your Documents directory is required to index local documents."
        case .downloads:
            return "Permission to access your Downloads directory is required to index downloaded items."
        case .desktop:
            return "Permission to access your Desktop directory is required to index desktop files."
        case .fullDiskAccess:
            return "Full Disk Access in macOS System Settings is required for complete system ingestion."
        case .filesAndFolders:
            return "File access permission is required to index files in this location."
        }
    }

    /// Mail and Messages sit behind Full Disk Access. macOS refuses them to an app without it, and
    /// choosing the folder in an open panel does not get around that (the panel greys out
    /// `~/Library/Messages` and a Mail folder chosen there still cannot be read).
    public var needsFullDiskAccess: Bool {
        self == .messages || self == .mail
    }

    /// The folder macOS protects for a Full Disk Access category.
    public var protectedFolder: String? {
        switch self {
        case .messages: return "~/Library/Messages"
        case .mail: return "~/Library/Mail"
        default: return nil
        }
    }

    /// What someone does, in order, to let Garage index Mail or Messages, and what is missing until
    /// they do. `sandboxed` (the App Store build) adds the folder grant the sandbox also needs.
    public func fullDiskAccessSteps(sandboxed: Bool) -> String {
        let folder = protectedFolder ?? "the folder"
        let what = self == .messages ? "SMS and iMessage history" : "email"
        var text = "macOS keeps \(displayName) (\(folder)) behind Full Disk Access, so Garage can't index your \(what) without it, even if you choose the folder. "
            + "Turn on Garage in System Settings → Privacy & Security → Full Disk Access, then quit and reopen Garage."
        if sandboxed {
            text += " Then grant access to \(folder), or select your startup disk, so the App Store version can open it."
        }
        return text
    }

    /// Detects the relevant TCC permission category based on the slug or path.
    public static func detect(slug: String, path: String) -> TCCPermissionCategory? {
        let lowerSlug = slug.lowercased()
        let lowerPath = GarageAppGroup.expandingTilde(in: path).lowercased()

        if lowerSlug == "apple-sms" || lowerSlug == "sms" || lowerSlug == "messages" || lowerSlug == "imessage"
            || lowerPath.contains("/library/messages") || lowerPath.hasSuffix("/messages") {
            return .messages
        }

        if lowerSlug == "apple-mail" || lowerSlug == "mail" || lowerSlug == "maildir"
            || lowerPath.contains("/library/mail") || lowerPath.hasSuffix("/mail") {
            return .mail
        }

        if lowerSlug == "documents" || lowerPath.contains("/documents") {
            return .documents
        }

        if lowerSlug == "downloads" || lowerPath.contains("/downloads") {
            return .downloads
        }

        if lowerSlug == "desktop" || lowerPath.contains("/desktop") {
            return .desktop
        }

        return nil
    }
}

/// Represents the status of volume access inside the sandbox.
public enum VolumeAccessStatus: Equatable {
    case notConfigured
    case accessGranted(url: URL, isSecurityScoped: Bool)
    case accessDenied(reason: String)
    case staleBookmark(url: URL)

    public var isGranted: Bool {
        if case .accessGranted = self {
            return true
        }
        return false
    }

    public var displayDescription: String {
        switch self {
        case .notConfigured:
            return "Not configured (no root volume selected)"
        case .accessGranted(let url, let isSecurityScoped):
            let scopeLabel = isSecurityScoped ? "security-scoped" : "direct"
            return "Granted: \(url.path) (\(scopeLabel))"
        case .accessDenied(let reason):
            return "Denied: \(reason)"
        case .staleBookmark(let url):
            return "Saved access to \(url.path) no longer works"
        }
    }
}

/// Detailed result of checking disk access for an individual ingest source path.
public struct SourcePathAccessResult: Identifiable, Hashable, Equatable, Sendable, Codable {
    public var id: String { slug.isEmpty ? rawPath : "\(slug):\(rawPath)" }
    public let slug: String
    public let rawPath: String
    public let resolvedPath: String
    public let exists: Bool
    public let isReadable: Bool
    public let isDirectory: Bool
    public let itemCount: Int?
    public let errorMessage: String?
    public let tccCategory: TCCPermissionCategory?
    public let requiresTCCPermission: Bool
    public let tccHelpMessage: String?
    public let canOpenFiles: Bool?
    public let sampleFilesTested: Int?
    public let sampleFilesOpened: Int?
    public let fileOpenErrorMessage: String?

    public init(
        slug: String,
        rawPath: String,
        resolvedPath: String,
        exists: Bool,
        isReadable: Bool,
        isDirectory: Bool,
        itemCount: Int?,
        errorMessage: String? = nil,
        tccCategory: TCCPermissionCategory? = nil,
        requiresTCCPermission: Bool = false,
        tccHelpMessage: String? = nil,
        canOpenFiles: Bool? = nil,
        sampleFilesTested: Int? = nil,
        sampleFilesOpened: Int? = nil,
        fileOpenErrorMessage: String? = nil
    ) {
        self.slug = slug
        self.rawPath = rawPath
        self.resolvedPath = resolvedPath
        self.exists = exists
        self.isReadable = isReadable
        self.isDirectory = isDirectory
        self.itemCount = itemCount
        self.errorMessage = errorMessage
        self.tccCategory = tccCategory
        self.requiresTCCPermission = requiresTCCPermission
        self.tccHelpMessage = tccHelpMessage
        self.canOpenFiles = canOpenFiles
        self.sampleFilesTested = sampleFilesTested
        self.sampleFilesOpened = sampleFilesOpened
        self.fileOpenErrorMessage = fileOpenErrorMessage
    }

    public var isAccessible: Bool {
        exists && isReadable && errorMessage == nil && (canOpenFiles ?? true)
    }

    public var statusDescription: String {
        if !exists {
            return "Path does not exist"
        }
        if !isReadable {
            if let cat = tccCategory {
                return "Needs permission (\(cat.displayName))"
            }
            return "Garage isn't allowed to read this folder"
        }
        if let error = errorMessage {
            return "Error: \(error)"
        }
        if let fileErr = fileOpenErrorMessage {
            return "Listing OK, but opening files failed: \(fileErr)"
        }
        if let count = itemCount {
            if let opened = sampleFilesOpened, opened > 0 {
                return "Accessible (\(count) \(count == 1 ? "item" : "items"), \(opened) test file\(opened == 1 ? "" : "s") opened)"
            }
            return "Accessible (\(count) \(count == 1 ? "item" : "items"))"
        }
        if let opened = sampleFilesOpened, opened > 0 {
            return "Accessible (file opened)"
        }
        return "Accessible"
    }
}

/// Detailed result of a volume access verification test.
public struct VolumeAccessTestResult: Equatable, Sendable {
    public let isAccessible: Bool
    public let testedURL: URL
    public let rootItemsCount: Int
    public let accessibleSubpaths: [String]
    public let inaccessibleSubpaths: [String]
    public let sourcePathResults: [SourcePathAccessResult]
    public let message: String
    public let isSecurityScoped: Bool

    public init(
        isAccessible: Bool,
        testedURL: URL,
        rootItemsCount: Int,
        accessibleSubpaths: [String],
        inaccessibleSubpaths: [String],
        sourcePathResults: [SourcePathAccessResult] = [],
        message: String,
        isSecurityScoped: Bool
    ) {
        self.isAccessible = isAccessible
        self.testedURL = testedURL
        self.rootItemsCount = rootItemsCount
        self.accessibleSubpaths = accessibleSubpaths
        self.inaccessibleSubpaths = inaccessibleSubpaths
        self.sourcePathResults = sourcePathResults
        self.message = message
        self.isSecurityScoped = isSecurityScoped
    }
}

/// Protocol defining bookmark storage for testing and persistence.
public protocol VolumeBookmarkStoring {
    func loadBookmarkData() -> Data?
    func saveBookmarkData(_ data: Data, path: String)
    func loadBookmarkPath() -> String?
    func clearBookmark()

    func loadBookmarkData(forPath path: String) -> Data?
    func saveBookmarkData(_ data: Data, forPath path: String)
    func clearBookmark(forPath path: String)
    func loadAllSourceBookmarks() -> [String: Data]
}

/// Standard UserDefaults-backed bookmark store.
public final class UserDefaultsVolumeBookmarkStore: VolumeBookmarkStoring {
    private let defaults: UserDefaults
    private let bookmarkKey: String
    private let pathKey: String
    private let sourceBookmarksKey: String

    public init(
        defaults: UserDefaults = .standard,
        bookmarkKey: String = "garage.rootVolumeBookmark",
        pathKey: String = "garage.rootVolumePath",
        sourceBookmarksKey: String = "garage.sourceBookmarks"
    ) {
        self.defaults = defaults
        self.bookmarkKey = bookmarkKey
        self.pathKey = pathKey
        self.sourceBookmarksKey = sourceBookmarksKey
    }

    public func loadBookmarkData() -> Data? {
        defaults.data(forKey: bookmarkKey)
    }

    public func saveBookmarkData(_ data: Data, path: String) {
        defaults.set(data, forKey: bookmarkKey)
        defaults.set(path, forKey: pathKey)
    }

    public func loadBookmarkPath() -> String? {
        defaults.string(forKey: pathKey)
    }

    public func clearBookmark() {
        defaults.removeObject(forKey: bookmarkKey)
        defaults.removeObject(forKey: pathKey)
    }

    public func loadBookmarkData(forPath path: String) -> Data? {
        let dict = defaults.dictionary(forKey: sourceBookmarksKey) as? [String: Data]
        return dict?[path]
    }

    public func saveBookmarkData(_ data: Data, forPath path: String) {
        var dict = (defaults.dictionary(forKey: sourceBookmarksKey) as? [String: Data]) ?? [:]
        dict[path] = data
        defaults.set(dict, forKey: sourceBookmarksKey)
    }

    public func clearBookmark(forPath path: String) {
        var dict = (defaults.dictionary(forKey: sourceBookmarksKey) as? [String: Data]) ?? [:]
        dict.removeValue(forKey: path)
        defaults.set(dict, forKey: sourceBookmarksKey)
    }

    public func loadAllSourceBookmarks() -> [String: Data] {
        (defaults.dictionary(forKey: sourceBookmarksKey) as? [String: Data]) ?? [:]
    }
}

/// Protocol for filesystem operations to enable testing.
public protocol FileSystemAccessing {
    func contentsOfDirectory(at url: URL) throws -> [URL]
    func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool
    func isReadableFile(atPath path: String) -> Bool
    func openFile(atPath path: String) -> Bool
}

public extension FileSystemAccessing {
    func openFile(atPath path: String) -> Bool {
        if let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) {
            try? handle.close()
            return true
        }
        return false
    }
}

/// Standard FileManager-backed filesystem accessor.
public final class DefaultFileSystemAccessor: FileSystemAccessing {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func contentsOfDirectory(at url: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
    }

    public func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        fileManager.fileExists(atPath: path, isDirectory: isDirectory)
    }

    public func isReadableFile(atPath path: String) -> Bool {
        fileManager.isReadableFile(atPath: path)
    }

    public func openFile(atPath path: String) -> Bool {
        if let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) {
            try? handle.close()
            return true
        }
        return false
    }
}

/// In-memory mock bookmark store for testing and headless execution.
public final class MockVolumeBookmarkStore: VolumeBookmarkStoring, @unchecked Sendable {
    public var storedData: Data?
    public var storedPath: String?
    public var sourceBookmarks: [String: Data] = [:]

    public init(storedData: Data? = nil, storedPath: String? = nil) {
        self.storedData = storedData
        self.storedPath = storedPath
    }

    public func loadBookmarkData() -> Data? {
        storedData
    }

    public func saveBookmarkData(_ data: Data, path: String) {
        storedData = data
        storedPath = path
    }

    public func loadBookmarkPath() -> String? {
        storedPath
    }

    public func clearBookmark() {
        storedData = nil
        storedPath = nil
        sourceBookmarks.removeAll()
    }

    public func loadBookmarkData(forPath path: String) -> Data? {
        sourceBookmarks[path]
    }

    public func saveBookmarkData(_ data: Data, forPath path: String) {
        sourceBookmarks[path] = data
    }

    public func clearBookmark(forPath path: String) {
        sourceBookmarks.removeValue(forKey: path)
    }

    public func loadAllSourceBookmarks() -> [String: Data] {
        sourceBookmarks
    }
}

/// In-memory mock filesystem accessor for testing and headless execution without TCC prompts.
open class MockFileSystemAccessor: FileSystemAccessing, @unchecked Sendable {
    public var directoryContents: [URL] = []
    public var shouldThrowOnContents = false
    public var readablePaths: Set<String> = ["/", "/System", "/Library", "/Applications", "/Users", "/Volumes"]
    public var unopenablePaths: Set<String> = []
    public var filePaths: Set<String> = []

    public init() {}

    open func contentsOfDirectory(at url: URL) throws -> [URL] {
        if shouldThrowOnContents {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError, userInfo: nil)
        }
        return directoryContents
    }

    open func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        let isFile = filePaths.contains(path) || path.contains(".")
        isDirectory?.pointee = ObjCBool(!isFile)
        return true
    }

    open func isReadableFile(atPath path: String) -> Bool {
        readablePaths.contains(path) || readablePaths.contains(GarageAppGroup.expandingTilde(in: path)) || path.hasPrefix("/tmp") || path.hasPrefix("/var/folders")
    }

    open func openFile(atPath path: String) -> Bool {
        if unopenablePaths.contains(path) || unopenablePaths.contains(GarageAppGroup.expandingTilde(in: path)) {
            return false
        }
        if isReadableFile(atPath: path) {
            return true
        }
        let parent = (path as NSString).deletingLastPathComponent
        return isReadableFile(atPath: parent)
    }
}

/// Service managing full volume access, security-scoped bookmark lifecycle, and verification.
@MainActor
public final class VolumeAccessService: ObservableObject {
    @Published public private(set) var status: VolumeAccessStatus = .notConfigured
    @Published public private(set) var activeRootURL: URL?
    @Published public private(set) var lastTestResult: VolumeAccessTestResult?
    @Published public private(set) var activeSourceURLs: [String: URL] = [:]

    private let bookmarkStore: VolumeBookmarkStoring
    private let fileSystem: FileSystemAccessing
    public let ingestClient: IngestClient?
    /// Passes each grant on to the ingest service and the gRPC host. The bookmarks above are
    /// app-scoped, so they give those separately sandboxed services nothing; the URL itself does.
    public let folderAccess: FolderAccessRelaying
    /// In the sandbox `/` reads as readable, but that shows only the container's view of it and
    /// grants nothing, so there only a bookmark counts as access.
    private let isSandboxed: Bool
    private var isAccessingSecurityScope = false

    public init(
        bookmarkStore: VolumeBookmarkStoring? = nil,
        fileSystem: FileSystemAccessing? = nil,
        ingestClient: IngestClient? = nil,
        folderAccess: FolderAccessRelaying? = nil,
        isSandboxed: Bool = GarageAppGroup.isSandboxed
    ) {
        let defaultStore: VolumeBookmarkStoring = isRunningInTestEnvironment ? MockVolumeBookmarkStore() : UserDefaultsVolumeBookmarkStore()
        let defaultFS: FileSystemAccessing = isRunningInTestEnvironment ? MockFileSystemAccessor() : DefaultFileSystemAccessor()
        let defaultRelay: FolderAccessRelaying = isRunningInTestEnvironment ? RecordingFolderAccessRelay() : XPCFolderAccessRelay()
        self.bookmarkStore = bookmarkStore ?? defaultStore
        self.fileSystem = fileSystem ?? defaultFS
        self.ingestClient = ingestClient
        self.folderAccess = folderAccess ?? defaultRelay
        self.isSandboxed = isSandboxed
    }

    /// Hands `url`, which this process can reach right now, to the services that read user files.
    private func relayGrant(_ url: URL, key: String) {
        let relay = folderAccess
        Task {
            await relay.grant(url, key: key)
        }
    }

    deinit {
        MainActor.assumeIsolated {
            stopAccessingCurrentScope()
            stopAccessingAllSourceScopes()
        }
    }

    /// Automatically restores persisted bookmark and validates access.
    @discardableResult
    public func restoreAndVerifyAccess() -> Bool {
        restoreSourceBookmarks()

        guard let bookmarkData = bookmarkStore.loadBookmarkData() else {
            // Without a sandbox a readable root means the whole disk is reachable (e.g. the
            // Developer ID build). In the sandbox it means nothing: the user has to pick a folder.
            let rootURL = URL(fileURLWithPath: "/")
            if !isSandboxed, fileSystem.isReadableFile(atPath: rootURL.path) {
                activeRootURL = rootURL
                status = .accessGranted(url: rootURL, isSecurityScoped: false)
                return true
            }
            status = .notConfigured
            return false
        }

        var isStale = false
        do {
            #if os(macOS)
            let resolvedURL: URL
            do {
                resolvedURL = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
            } catch {
                resolvedURL = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
            }
            #else
            let resolvedURL = try URL(
                resolvingBookmarkData: bookmarkData,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            #endif

            stopAccessingCurrentScope()

            let started = resolvedURL.startAccessingSecurityScopedResource()
            if started {
                isAccessingSecurityScope = true
                activeRootURL = resolvedURL

                if isStale {
                    status = .staleBookmark(url: resolvedURL)
                    // Attempt to refresh stale bookmark
                    _ = try? persistSecurityScopedBookmark(for: resolvedURL)
                } else {
                    status = .accessGranted(url: resolvedURL, isSecurityScoped: true)
                }

                _ = IngestEngine.shared.setRootVolumeBookmark(bookmarkData)
                relayGrant(resolvedURL, key: GarageFolderAccessKey.root)
                return true
            } else if fileSystem.isReadableFile(atPath: resolvedURL.path) {
                activeRootURL = resolvedURL
                status = .accessGranted(url: resolvedURL, isSecurityScoped: false)
                _ = IngestEngine.shared.setRootVolumeBookmark(bookmarkData)
                relayGrant(resolvedURL, key: GarageFolderAccessKey.root)
                return true
            } else {
                status = .accessDenied(reason: "Failed to start accessing security-scoped resource for \(resolvedURL.path)")
                return false
            }
        } catch {
            status = .accessDenied(reason: "Failed to resolve stored bookmark: \(error.localizedDescription)")
            return false
        }
    }

    /// Restores individual security-scoped bookmarks saved for specific source directories.
    private func restoreSourceBookmarks() {
        let sourceBookmarks = bookmarkStore.loadAllSourceBookmarks()
        for (path, data) in sourceBookmarks {
            var isStale = false
            #if os(macOS)
            if let resolvedURL = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) {
                if resolvedURL.startAccessingSecurityScopedResource() {
                    activeSourceURLs[path] = resolvedURL
                    relayGrant(resolvedURL, key: GarageFolderAccessKey.source(path))
                }
            }
            #endif
            _ = IngestEngine.shared.setSourceBookmark(path: path, bookmarkData: data)
        }
    }

    /// Displays an NSOpenPanel configured to assist the user in choosing the root hard-drive.
    public func promptForRootVolumeSelection() -> URL? {
        if isRunningInTestEnvironment {
            let defaultURL = URL(fileURLWithPath: "/")
            try? grantAccess(for: defaultURL)
            return defaultURL
        }

        let panel = NSOpenPanel()
        panel.title = "Select Startup Disk"
        panel.message = "Select your startup disk (usually Macintosh HD) and click Grant Access."
        panel.prompt = "Grant Access"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = false
        panel.directoryURL = URL(fileURLWithPath: "/")

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return nil
        }

        do {
            try grantAccess(for: selectedURL)
            return selectedURL
        } catch {
            status = .accessDenied(reason: "Failed to create security-scoped bookmark: \(error.localizedDescription)")
            return nil
        }
    }

    /// Asks for the account's home folder: one grant that covers Documents, Desktop, Downloads,
    /// iCloud Drive, cloud folders, Mail and Messages. The startup disk also works, for sources on
    /// other folders; either one becomes the root grant every source is read through.
    public func promptForHomeFolderSelection() -> URL? {
        let home = URL(fileURLWithPath: GarageAppGroup.realHomeDirectory, isDirectory: true)
        if isRunningInTestEnvironment {
            try? grantAccess(for: home)
            return home
        }

        let panel = NSOpenPanel()
        panel.title = "Select Your Home Folder"
        panel.message = "Select your home folder (\(home.lastPathComponent)) and click Grant Access. It covers Documents, Desktop, Downloads, iCloud Drive, Mail and Messages. To index other disks too, select your startup disk instead."
        panel.prompt = "Grant Access"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = false
        panel.directoryURL = home

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return nil
        }

        do {
            try grantAccess(for: selectedURL)
            return selectedURL
        } catch {
            status = .accessDenied(reason: "Failed to create security-scoped bookmark: \(error.localizedDescription)")
            return nil
        }
    }

    /// Whether this process has Full Disk Access, by opening the account's own TCC database, which
    /// only Full Disk Access unlocks. In the sandbox the home folder or startup disk must be granted
    /// first, so until then this reports false whatever System Settings says.
    public func hasFullDiskAccess() -> Bool {
        if isRunningInTestEnvironment {
            return true
        }
        let probe = URL(fileURLWithPath: GarageAppGroup.realHomeDirectory, isDirectory: true)
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        guard let handle = try? FileHandle(forReadingFrom: probe) else {
            return false
        }
        try? handle.close()
        return true
    }

    /// Displays an NSOpenPanel configured to select a specific source directory such as Messages or Mail.
    public func promptForSourceDirectoryAccess(slug: String? = nil, suggestedPath: String) -> URL? {
        let resolvedPath = GarageAppGroup.expandingTilde(in: suggestedPath)
        if isRunningInTestEnvironment {
            let defaultURL = URL(fileURLWithPath: resolvedPath)
            try? grantSourceAccess(for: defaultURL, forSourcePath: suggestedPath)
            return defaultURL
        }

        let cat = TCCPermissionCategory.detect(slug: slug ?? "", path: resolvedPath)
        let displayName = cat?.displayName ?? (slug ?? "Source Directory")

        let panel = NSOpenPanel()
        panel.title = "Grant Access to \(displayName)"
        panel.message = "To allow Garage to index \(displayName) ('\(suggestedPath)'), please select the folder and click 'Grant Access'."
        panel.prompt = "Grant Access"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: resolvedPath)

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return nil
        }

        do {
            try grantSourceAccess(for: selectedURL, forSourcePath: suggestedPath)
            return selectedURL
        } catch {
            return nil
        }
    }

    /// Grants access for a specific source path and persists its security-scoped bookmark.
    public func grantSourceAccess(for url: URL, forSourcePath path: String) throws {
        _ = url.startAccessingSecurityScopedResource()
        let resolvedPath = GarageAppGroup.expandingTilde(in: path)
        activeSourceURLs[resolvedPath] = url

        #if os(macOS)
        let bookmarkData: Data
        do {
            bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            bookmarkData = try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }
        bookmarkStore.saveBookmarkData(bookmarkData, forPath: resolvedPath)
        _ = IngestEngine.shared.setSourceBookmark(path: resolvedPath, bookmarkData: bookmarkData)
        #endif
        relayGrant(url, key: GarageFolderAccessKey.source(resolvedPath))

        _ = testFullVolumeAccess()
    }

    /// Opens macOS System Settings to the appropriate Privacy & Security pane.
    public func openPrivacySettings(for category: TCCPermissionCategory = .fullDiskAccess) {
        if isRunningInTestEnvironment {
            return
        }
        if let url = category.systemSettingsURL, NSWorkspace.shared.open(url) {
            return
        }
        if let fallbackURL = URL(string: "x-apple.systempreferences:com.apple.preference.security"), NSWorkspace.shared.open(fallbackURL) {
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    /// Displays an interactive TCC prompt alert explaining the missing permission and offering direct actions.
    @discardableResult
    public func promptForTCCPermission(
        category: TCCPermissionCategory,
        sourceSlug: String? = nil,
        sourcePath: String? = nil
    ) -> Bool {
        if isRunningInTestEnvironment {
            return false
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        if category.needsFullDiskAccess {
            // Choosing the folder does nothing until Full Disk Access is on, so settings come first
            // and the folder is offered only where the sandbox also needs it.
            alert.messageText = "\(category.displayName) needs Full Disk Access"
            alert.informativeText = category.helpMessage
            alert.addButton(withTitle: "Open System Settings")
            if GarageAppGroup.isSandboxed {
                alert.addButton(withTitle: "Select Folder…")
            }
            alert.addButton(withTitle: "Cancel")
        } else {
            alert.messageText = "Garage needs permission to read \(category.displayName)"
            alert.informativeText = "\(category.helpMessage)\n\nSelect the folder, or turn on Full Disk Access in System Settings."
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Select Folder Directly…")
            alert.addButton(withTitle: "Cancel")
        }

        let offersFolder = !category.needsFullDiskAccess || GarageAppGroup.isSandboxed
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openPrivacySettings(for: category)
            return true
        } else if response == .alertSecondButtonReturn, offersFolder {
            if let path = sourcePath ?? sourceSlug {
                _ = promptForSourceDirectoryAccess(slug: sourceSlug, suggestedPath: path)
                return true
            } else {
                _ = promptForRootVolumeSelection()
                return true
            }
        }
        return false
    }

    /// Grants access for a user-selected URL and saves the security-scoped bookmark.
    public func grantAccess(for url: URL) throws {
        stopAccessingCurrentScope()

        let started = url.startAccessingSecurityScopedResource()
        if started {
            isAccessingSecurityScope = true
        }

        activeRootURL = url
        try persistSecurityScopedBookmark(for: url)
        status = .accessGranted(url: url, isSecurityScoped: started)

        if let bookmarkData = bookmarkStore.loadBookmarkData() {
            _ = IngestEngine.shared.setRootVolumeBookmark(bookmarkData)
        }
        relayGrant(url, key: GarageFolderAccessKey.root)

        _ = testFullVolumeAccess()
    }

    /// Revokes stored bookmark and terminates security-scoped access.
    public func revokeAccess() {
        stopAccessingCurrentScope()
        stopAccessingAllSourceScopes()
        bookmarkStore.clearBookmark()
        activeRootURL = nil
        lastTestResult = nil
        status = .notConfigured
        IngestEngine.shared.revokeAccess()
        let relay = folderAccess
        Task {
            await relay.revokeAll()
        }
    }

    /// Runs a verification test against the root hard drive / volume and each registered ingest source path.
    @discardableResult
    public func testFullVolumeAccess(sourcePaths: [(slug: String, root: String)] = []) -> VolumeAccessTestResult {
        let rootData = bookmarkStore.loadBookmarkData()
        let sourceBookmarks = bookmarkStore.loadAllSourceBookmarks()
        let request = VolumeAccessTestRequest(
            rootBookmarkData: rootData,
            sourceBookmarks: sourceBookmarks,
            sourcePaths: sourcePaths.map { SourcePathTestItem(slug: $0.slug, root: $0.root) }
        )

        if fileSystem is DefaultFileSystemAccessor {
            let ingestResult = IngestEngine.shared.testVolumeAccess(request: request)
            let targetURL = activeRootURL ?? URL(fileURLWithPath: ingestResult.testedPath)
            let sourceResults = ingestResult.sourcePathResults.map { res in
                SourcePathAccessResult(
                    slug: res.slug,
                    rawPath: res.rawPath,
                    resolvedPath: res.resolvedPath,
                    exists: res.exists,
                    isReadable: res.isReadable,
                    isDirectory: res.isDirectory,
                    itemCount: res.itemCount,
                    errorMessage: res.errorMessage,
                    tccCategory: res.tccCategory.flatMap { TCCPermissionCategory(rawValue: $0) },
                    requiresTCCPermission: res.requiresTCCPermission,
                    tccHelpMessage: res.tccHelpMessage,
                    canOpenFiles: res.canOpenFiles,
                    sampleFilesTested: res.sampleFilesTested,
                    sampleFilesOpened: res.sampleFilesOpened,
                    fileOpenErrorMessage: res.fileOpenErrorMessage
                )
            }

            let result = VolumeAccessTestResult(
                isAccessible: ingestResult.isAccessible,
                testedURL: targetURL,
                rootItemsCount: ingestResult.rootItemsCount,
                accessibleSubpaths: ingestResult.accessibleSubpaths,
                inaccessibleSubpaths: ingestResult.inaccessibleSubpaths,
                sourcePathResults: sourceResults,
                message: ingestResult.message,
                isSecurityScoped: ingestResult.isSecurityScoped
            )

            self.lastTestResult = result
            if ingestResult.rootItemsCount > 0 || !ingestResult.accessibleSubpaths.isEmpty || fileSystem.isReadableFile(atPath: targetURL.path) {
                self.status = .accessGranted(url: targetURL, isSecurityScoped: ingestResult.isSecurityScoped)
            } else if ingestResult.isAccessible {
                self.status = .accessGranted(url: targetURL, isSecurityScoped: ingestResult.isSecurityScoped)
            } else {
                self.status = .accessDenied(reason: ingestResult.message)
            }

            return result
        }

        let targetURL = activeRootURL ?? URL(fileURLWithPath: "/")
        var isSecurityScoped = false

        if isAccessingSecurityScope {
            isSecurityScoped = true
        }

        var rootItems: [URL] = []
        var rootAccessible = false
        do {
            rootItems = try fileSystem.contentsOfDirectory(at: targetURL)
            rootAccessible = true
        } catch {
            rootAccessible = false
        }

        let isRootVolume = targetURL.path == "/" || targetURL.path.hasPrefix("/Volumes")
        let commonSubpaths = ["System", "Library", "Applications", "Users", "Volumes"]
        var accessibleSubpaths: [String] = []
        var inaccessibleSubpaths: [String] = []

        if isRootVolume {
            for subpath in commonSubpaths {
                let subURL = targetURL.path == "/" ? URL(fileURLWithPath: "/\(subpath)") : targetURL.appendingPathComponent(subpath)
                if fileSystem.isReadableFile(atPath: subURL.path) {
                    accessibleSubpaths.append("/\(subpath)")
                } else {
                    inaccessibleSubpaths.append("/\(subpath)")
                }
            }
        }

        // Test each ingest source path
        var sourceResults: [SourcePathAccessResult] = []
        for source in sourcePaths {
            let rawPath = source.root
            let slug = source.slug
            let resolvedPath = GarageAppGroup.expandingTilde(in: rawPath)
            var isDir: ObjCBool = false
            let exists = fileSystem.fileExists(atPath: resolvedPath, isDirectory: &isDir)
            let isReadable = fileSystem.isReadableFile(atPath: resolvedPath)
            var count: Int? = nil
            var errorMsg: String? = nil
            var canOpenFiles: Bool? = nil
            var sampleTested: Int? = nil
            var sampleOpened: Int? = nil
            var fileOpenError: String? = nil

            let tccCategory = TCCPermissionCategory.detect(slug: slug, path: resolvedPath)
            let requiresTCC = !isReadable && exists && (tccCategory != nil)
            let helpMsg = requiresTCC ? tccCategory?.helpMessage : nil

            if exists && isReadable {
                if isDir.boolValue {
                    do {
                        let contents = try fileSystem.contentsOfDirectory(at: URL(fileURLWithPath: resolvedPath))
                        count = contents.count

                        var testedCount = 0
                        var openedCount = 0
                        for itemURL in contents.prefix(10) {
                            var isSubDir: ObjCBool = false
                            if fileSystem.fileExists(atPath: itemURL.path, isDirectory: &isSubDir), !isSubDir.boolValue {
                                testedCount += 1
                                if fileSystem.openFile(atPath: itemURL.path) {
                                    openedCount += 1
                                } else {
                                    fileOpenError = "Failed to open file '\(itemURL.lastPathComponent)' for reading"
                                }
                            }
                        }
                        sampleTested = testedCount
                        sampleOpened = openedCount
                        canOpenFiles = testedCount == 0 ? true : (fileOpenError == nil && openedCount == testedCount)
                    } catch {
                        errorMsg = error.localizedDescription
                        canOpenFiles = false
                    }
                } else {
                    sampleTested = 1
                    if fileSystem.openFile(atPath: resolvedPath) {
                        sampleOpened = 1
                        canOpenFiles = true
                    } else {
                        sampleOpened = 0
                        canOpenFiles = false
                        fileOpenError = "Failed to open file for reading"
                    }
                }
            } else if !exists {
                errorMsg = "Path does not exist"
                canOpenFiles = false
            } else if !isReadable {
                if let cat = tccCategory {
                    errorMsg = "Needs permission (\(cat.displayName))"
                } else {
                    errorMsg = "Garage isn't allowed to read this folder"
                }
                canOpenFiles = false
            }

            sourceResults.append(SourcePathAccessResult(
                slug: slug,
                rawPath: rawPath,
                resolvedPath: resolvedPath,
                exists: exists,
                isReadable: isReadable,
                isDirectory: isDir.boolValue,
                itemCount: count,
                errorMessage: errorMsg,
                tccCategory: tccCategory,
                requiresTCCPermission: requiresTCC || (!isReadable && exists),
                tccHelpMessage: helpMsg,
                canOpenFiles: canOpenFiles,
                sampleFilesTested: sampleTested,
                sampleFilesOpened: sampleOpened,
                fileOpenErrorMessage: fileOpenError
            ))
        }

        let rootVolumeAccessible: Bool
        if isRootVolume {
            rootVolumeAccessible = rootAccessible && (!accessibleSubpaths.isEmpty || !rootItems.isEmpty)
        } else {
            rootVolumeAccessible = rootAccessible && fileSystem.isReadableFile(atPath: targetURL.path)
        }

        let allSourcesAccessible = sourceResults.isEmpty || sourceResults.allSatisfy(\.isAccessible)
        let isOverallAccessible = rootVolumeAccessible && allSourcesAccessible

        let message: String
        if !sourceResults.isEmpty {
            let totalCount = sourceResults.count
            if isOverallAccessible {
                message = "Volume & source access verified at '\(targetURL.path)'. All \(totalCount) ingest source \(totalCount == 1 ? "path is" : "paths are") accessible."
            } else if !rootVolumeAccessible {
                message = "Root volume access test failed for '\(targetURL.path)'."
            } else {
                let inaccessible = sourceResults.filter { !$0.isAccessible }
                let details = inaccessible.map { res in
                    let label = res.slug.isEmpty ? res.rawPath : res.slug
                    return "\(label) (\(res.statusDescription))"
                }.joined(separator: ", ")
                message = "Volume access granted at '\(targetURL.path)', but \(inaccessible.count) of \(totalCount) ingest source \(totalCount == 1 ? "path is" : "paths are") inaccessible: \(details)"
            }
        } else {
            if rootVolumeAccessible {
                if !accessibleSubpaths.isEmpty {
                    message = "Full volume access verified at '\(targetURL.path)'. Found \(rootItems.count) root items, and \(accessibleSubpaths.count) common directories are readable."
                } else {
                    message = "Volume access verified at '\(targetURL.path)'. Found \(rootItems.count) items."
                }
            } else {
                message = "Volume access test failed for '\(targetURL.path)'. The directory could not be enumerated or read."
            }
        }

        let result = VolumeAccessTestResult(
            isAccessible: isOverallAccessible,
            testedURL: targetURL,
            rootItemsCount: rootItems.count,
            accessibleSubpaths: accessibleSubpaths,
            inaccessibleSubpaths: inaccessibleSubpaths,
            sourcePathResults: sourceResults,
            message: message,
            isSecurityScoped: isSecurityScoped
        )

        self.lastTestResult = result
        if rootVolumeAccessible {
            self.status = .accessGranted(url: targetURL, isSecurityScoped: isSecurityScoped)
        } else {
            self.status = .accessDenied(reason: message)
        }

        return result
    }

    /// Asynchronously runs the full volume access test directly across the XPC boundary inside the XPC process.
    public func testFullVolumeAccessViaXPC(sourcePaths: [(slug: String, root: String)] = []) async throws -> VolumeAccessTestResult {
        let client = ingestClient ?? IngestClient()
        let rootData = bookmarkStore.loadBookmarkData()
        let sourceBookmarks = bookmarkStore.loadAllSourceBookmarks()
        let request = VolumeAccessTestRequest(
            rootBookmarkData: rootData,
            sourceBookmarks: sourceBookmarks,
            sourcePaths: sourcePaths.map { SourcePathTestItem(slug: $0.slug, root: $0.root) }
        )

        let ingestResult = try await client.testVolumeAccess(request: request)
        let targetURL = activeRootURL ?? URL(fileURLWithPath: ingestResult.testedPath)
        let sourceResults = ingestResult.sourcePathResults.map { res in
            SourcePathAccessResult(
                slug: res.slug,
                rawPath: res.rawPath,
                resolvedPath: res.resolvedPath,
                exists: res.exists,
                isReadable: res.isReadable,
                isDirectory: res.isDirectory,
                itemCount: res.itemCount,
                errorMessage: res.errorMessage,
                tccCategory: res.tccCategory.flatMap { TCCPermissionCategory(rawValue: $0) },
                requiresTCCPermission: res.requiresTCCPermission,
                tccHelpMessage: res.tccHelpMessage,
                canOpenFiles: res.canOpenFiles,
                sampleFilesTested: res.sampleFilesTested,
                sampleFilesOpened: res.sampleFilesOpened,
                fileOpenErrorMessage: res.fileOpenErrorMessage
            )
        }

        let result = VolumeAccessTestResult(
            isAccessible: ingestResult.isAccessible,
            testedURL: targetURL,
            rootItemsCount: ingestResult.rootItemsCount,
            accessibleSubpaths: ingestResult.accessibleSubpaths,
            inaccessibleSubpaths: ingestResult.inaccessibleSubpaths,
            sourcePathResults: sourceResults,
            message: ingestResult.message,
            isSecurityScoped: ingestResult.isSecurityScoped
        )

        self.lastTestResult = result
        if ingestResult.rootItemsCount > 0 || !ingestResult.accessibleSubpaths.isEmpty || fileSystem.isReadableFile(atPath: targetURL.path) {
            self.status = .accessGranted(url: targetURL, isSecurityScoped: ingestResult.isSecurityScoped)
        } else if ingestResult.isAccessible {
            self.status = .accessGranted(url: targetURL, isSecurityScoped: ingestResult.isSecurityScoped)
        } else {
            self.status = .accessDenied(reason: ingestResult.message)
        }

        return result
    }

    private func persistSecurityScopedBookmark(for url: URL) throws {
        #if os(macOS)
        let bookmarkData: Data
        do {
            bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            // Fallback for non-sandboxed or un-entitled environments (such as unit test bundles)
            bookmarkData = try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }
        #else
        let bookmarkData = try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        #endif
        bookmarkStore.saveBookmarkData(bookmarkData, path: url.path)
    }

    private func stopAccessingCurrentScope() {
        if isAccessingSecurityScope, let active = activeRootURL {
            active.stopAccessingSecurityScopedResource()
            isAccessingSecurityScope = false
        }
    }

    private func stopAccessingAllSourceScopes() {
        for (_, url) in activeSourceURLs {
            url.stopAccessingSecurityScopedResource()
        }
        activeSourceURLs.removeAll()
    }
}

import XCTest
import AppKit
import PythonXPCService
@testable import GarageApp

@MainActor
final class VolumeAccessServiceTests: XCTestCase {

    func testInitialStateNotConfiguredWhenUnreadable() {
        let mockStore = MockVolumeBookmarkStore()
        let mockFS = MockFileSystemAccessor()
        mockFS.readablePaths = [] // root not readable

        let service = VolumeAccessService(bookmarkStore: mockStore, fileSystem: mockFS)
        XCTAssertEqual(service.status, .notConfigured)
        XCTAssertFalse(service.status.isGranted)
        XCTAssertNil(service.activeRootURL)
        XCTAssertNil(service.lastTestResult)
    }

    func testDirectAccessFallbackWhenRootReadable() {
        let mockStore = MockVolumeBookmarkStore()
        let mockFS = MockFileSystemAccessor()
        mockFS.readablePaths = ["/"]

        let service = VolumeAccessService(bookmarkStore: mockStore, fileSystem: mockFS, isSandboxed: false)
        let restored = service.restoreAndVerifyAccess()

        XCTAssertTrue(restored)
        XCTAssertTrue(service.status.isGranted)
        XCTAssertEqual(service.activeRootURL?.path, "/")
        if case .accessGranted(let url, let isSecurityScoped) = service.status {
            XCTAssertEqual(url.path, "/")
            XCTAssertFalse(isSecurityScoped)
        } else {
            XCTFail("Expected .accessGranted")
        }
    }

    /// A sandboxed app with no bookmark can still read `/`, but it has no grant: it must not claim
    /// the whole disk, or the Sources page never offers Select Home Folder….
    func testSandboxedReadableRootWithoutBookmarkIsNotAGrant() {
        let mockFS = MockFileSystemAccessor()
        mockFS.readablePaths = ["/"]

        let service = VolumeAccessService(bookmarkStore: MockVolumeBookmarkStore(), fileSystem: mockFS, isSandboxed: true)
        let restored = service.restoreAndVerifyAccess()

        XCTAssertFalse(restored)
        XCTAssertEqual(service.status, .notConfigured)
        XCTAssertNil(service.activeRootURL)
    }

    func testGrantAccessPersistsBookmark() throws {
        let mockStore = MockVolumeBookmarkStore()
        let mockFS = MockFileSystemAccessor()
        let testDir = URL(fileURLWithPath: NSTemporaryDirectory())
        mockFS.readablePaths = [testDir.path, "/Users", "/System", "/Library"]
        mockFS.directoryContents = [testDir.appendingPathComponent("test1")]

        let service = VolumeAccessService(bookmarkStore: mockStore, fileSystem: mockFS)
        try service.grantAccess(for: testDir)

        XCTAssertNotNil(mockStore.storedData)
        XCTAssertEqual(mockStore.storedPath, testDir.path)
        XCTAssertEqual(service.activeRootURL?.path, testDir.path)
        XCTAssertTrue(service.status.isGranted)
    }

    /// Polls until `condition` holds; the relay runs in a Task.
    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// The services get the granted URL itself, which carries their sandbox extension; the app's
    /// app-scoped bookmark bytes would resolve to nothing in them.
    func testGrantAccessRelaysTheRootURLToTheServices() async throws {
        let relay = RecordingFolderAccessRelay()
        let mockFS = MockFileSystemAccessor()
        let testDir = URL(fileURLWithPath: NSTemporaryDirectory())
        mockFS.readablePaths = [testDir.path]

        let service = VolumeAccessService(bookmarkStore: MockVolumeBookmarkStore(), fileSystem: mockFS, folderAccess: relay)
        try service.grantAccess(for: testDir)

        await waitUntil { !relay.grants.isEmpty }
        XCTAssertEqual(relay.grants.map { $0.key }, [GarageFolderAccessKey.root])
        XCTAssertEqual(relay.grants.first?.path, testDir.path)
    }

    func testGrantSourceAccessRelaysUnderTheSourceKey() async throws {
        let relay = RecordingFolderAccessRelay()
        let mockFS = MockFileSystemAccessor()
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("garage-source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let service = VolumeAccessService(bookmarkStore: MockVolumeBookmarkStore(), fileSystem: mockFS, folderAccess: relay)
        try service.grantSourceAccess(for: folder, forSourcePath: folder.path)

        await waitUntil { !relay.grants.isEmpty }
        XCTAssertEqual(relay.grants.map { $0.key }, [GarageFolderAccessKey.source(folder.path)])
        XCTAssertEqual(relay.grants.first?.path, folder.path)
    }

    func testRevokeAccessRevokesTheServicesGrants() async throws {
        let relay = RecordingFolderAccessRelay()
        let mockFS = MockFileSystemAccessor()
        let testDir = URL(fileURLWithPath: NSTemporaryDirectory())
        mockFS.readablePaths = [testDir.path]

        let service = VolumeAccessService(bookmarkStore: MockVolumeBookmarkStore(), fileSystem: mockFS, folderAccess: relay)
        try service.grantAccess(for: testDir)
        service.revokeAccess()

        await waitUntil { relay.revocations > 0 }
        XCTAssertEqual(relay.revocations, 1)
    }

    func testRevokeAccessClearsBookmarkAndState() throws {
        let mockStore = MockVolumeBookmarkStore()
        let mockFS = MockFileSystemAccessor()
        let testDir = URL(fileURLWithPath: NSTemporaryDirectory())
        mockFS.readablePaths = [testDir.path]

        let service = VolumeAccessService(bookmarkStore: mockStore, fileSystem: mockFS)
        try service.grantAccess(for: testDir)

        XCTAssertNotNil(mockStore.storedData)
        service.revokeAccess()

        XCTAssertNil(mockStore.storedData)
        XCTAssertNil(mockStore.storedPath)
        XCTAssertNil(service.activeRootURL)
        XCTAssertNil(service.lastTestResult)
        XCTAssertEqual(service.status, .notConfigured)
    }

    func testTestFullVolumeAccessSuccess() {
        let mockStore = MockVolumeBookmarkStore()
        let mockFS = MockFileSystemAccessor()
        mockFS.readablePaths = ["/", "/System", "/Library", "/Applications", "/Users", "/Volumes"]
        mockFS.directoryContents = [
            URL(fileURLWithPath: "/System"),
            URL(fileURLWithPath: "/Library"),
            URL(fileURLWithPath: "/Users")
        ]

        let service = VolumeAccessService(bookmarkStore: mockStore, fileSystem: mockFS)
        let result = service.testFullVolumeAccess()

        XCTAssertTrue(result.isAccessible)
        XCTAssertEqual(result.rootItemsCount, 3)
        XCTAssertTrue(result.accessibleSubpaths.contains("/System"))
        XCTAssertTrue(result.accessibleSubpaths.contains("/Users"))
        XCTAssertTrue(result.inaccessibleSubpaths.isEmpty)
        XCTAssertTrue(result.message.contains("Full volume access verified"))
        XCTAssertEqual(service.lastTestResult, result)
        XCTAssertTrue(service.status.isGranted)
    }

    func testTestFullVolumeAccessFailureWhenDirectoryListingFails() {
        let mockStore = MockVolumeBookmarkStore()
        let mockFS = MockFileSystemAccessor()
        mockFS.shouldThrowOnContents = true
        mockFS.readablePaths = []

        let service = VolumeAccessService(bookmarkStore: mockStore, fileSystem: mockFS)
        let result = service.testFullVolumeAccess()

        XCTAssertFalse(result.isAccessible)
        XCTAssertEqual(result.rootItemsCount, 0)
        XCTAssertTrue(result.accessibleSubpaths.isEmpty)
        XCTAssertTrue(result.message.contains("Volume access test failed"))
        XCTAssertFalse(service.status.isGranted)
        if case .accessDenied(let reason) = service.status {
            XCTAssertTrue(reason.contains("Volume access test failed"))
        } else {
            XCTFail("Expected .accessDenied")
        }
    }

    func testUserDefaultsVolumeBookmarkStore() {
        let suiteName = "test.garage.volumeaccess.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = UserDefaultsVolumeBookmarkStore(defaults: defaults)
        XCTAssertNil(store.loadBookmarkData())
        XCTAssertNil(store.loadBookmarkPath())

        let sampleData = Data("sample_bookmark_data".utf8)
        let samplePath = "/Volumes/Macintosh HD"
        store.saveBookmarkData(sampleData, path: samplePath)

        XCTAssertEqual(store.loadBookmarkData(), sampleData)
        XCTAssertEqual(store.loadBookmarkPath(), samplePath)

        store.clearBookmark()
        XCTAssertNil(store.loadBookmarkData())
        XCTAssertNil(store.loadBookmarkPath())
    }

    func testVolumeAccessStatusDisplayDescriptions() {
        let notConfigured = VolumeAccessStatus.notConfigured
        XCTAssertEqual(notConfigured.displayDescription, "Not configured (no root volume selected)")
        XCTAssertFalse(notConfigured.isGranted)

        let granted = VolumeAccessStatus.accessGranted(url: URL(fileURLWithPath: "/"), isSecurityScoped: true)
        XCTAssertTrue(granted.displayDescription.contains("Granted: / (security-scoped)"))
        XCTAssertTrue(granted.isGranted)

        let denied = VolumeAccessStatus.accessDenied(reason: "Permission denied")
        XCTAssertEqual(denied.displayDescription, "Denied: Permission denied")
        XCTAssertFalse(denied.isGranted)

        let stale = VolumeAccessStatus.staleBookmark(url: URL(fileURLWithPath: "/"))
        XCTAssertTrue(stale.displayDescription.contains("Saved access to / no longer works"))
        XCTAssertFalse(stale.isGranted)
    }

    func testVolumeAccessWithSourcePathsAllAccessible() {
        let mockStore = MockVolumeBookmarkStore()
        let mockFS = MockFileSystemAccessor()
        let sourcePath1 = "/Users/test/Dropbox"
        let sourcePath2 = "/Users/test/Developer"
        mockFS.readablePaths = ["/", "/System", "/Library", "/Applications", "/Users", "/Volumes", sourcePath1, sourcePath2]
        mockFS.directoryContents = [URL(fileURLWithPath: "\(sourcePath1)/doc1.pdf"), URL(fileURLWithPath: "\(sourcePath1)/doc2.pdf")]

        let service = VolumeAccessService(bookmarkStore: mockStore, fileSystem: mockFS)
        let result = service.testFullVolumeAccess(sourcePaths: [
            (slug: "dropbox", root: sourcePath1),
            (slug: "dev", root: sourcePath2)
        ])

        XCTAssertTrue(result.isAccessible)
        XCTAssertEqual(result.sourcePathResults.count, 2)
        XCTAssertTrue(result.sourcePathResults[0].isAccessible)
        XCTAssertEqual(result.sourcePathResults[0].slug, "dropbox")
        XCTAssertEqual(result.sourcePathResults[0].itemCount, 2)
        XCTAssertTrue(result.sourcePathResults[1].isAccessible)
        XCTAssertTrue(result.message.contains("All 2 ingest source paths are accessible"))
    }

    func testVolumeAccessWithInaccessibleSourcePath() {
        let mockStore = MockVolumeBookmarkStore()
        let mockFS = MockFileSystemAccessor()
        let sourcePath1 = "/Users/test/Dropbox"
        let sourcePath2 = "/Users/test/Restricted"
        mockFS.readablePaths = ["/", "/System", "/Library", "/Applications", "/Users", "/Volumes", sourcePath1] // sourcePath2 not readable

        let service = VolumeAccessService(bookmarkStore: mockStore, fileSystem: mockFS)
        let result = service.testFullVolumeAccess(sourcePaths: [
            (slug: "dropbox", root: sourcePath1),
            (slug: "restricted", root: sourcePath2)
        ])

        XCTAssertFalse(result.isAccessible)
        XCTAssertEqual(result.sourcePathResults.count, 2)
        XCTAssertTrue(result.sourcePathResults[0].isAccessible)
        XCTAssertFalse(result.sourcePathResults[1].isAccessible)
        XCTAssertEqual(result.sourcePathResults[1].statusDescription, "Garage isn't allowed to read this folder")
        XCTAssertTrue(result.message.contains("1 of 2 ingest source paths are inaccessible"))
    }

    func testVolumeAccessWithNonExistentSourcePath() {
        let mockStore = MockVolumeBookmarkStore()
        let mockFS = MockFileSystemAccessor()
        mockFS.readablePaths = ["/", "/System", "/Library", "/Applications", "/Users", "/Volumes"]

        final class NonExistentFileSystemAccessor: FileSystemAccessing {
            var readablePaths: Set<String> = ["/", "/System", "/Library", "/Applications", "/Users", "/Volumes"]
            func contentsOfDirectory(at url: URL) throws -> [URL] { [URL(fileURLWithPath: "/Users")] }
            func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
                if path.contains("missing") { return false }
                isDirectory?.pointee = true
                return true
            }
            func isReadableFile(atPath path: String) -> Bool { readablePaths.contains(path) }
        }

        let nonExistentFS = NonExistentFileSystemAccessor()
        let service = VolumeAccessService(bookmarkStore: mockStore, fileSystem: nonExistentFS)
        let result = service.testFullVolumeAccess(sourcePaths: [
            (slug: "missing_docs", root: "/Users/test/missing_dir")
        ])

        XCTAssertFalse(result.isAccessible)
        XCTAssertEqual(result.sourcePathResults.count, 1)
        XCTAssertFalse(result.sourcePathResults[0].isAccessible)
        XCTAssertEqual(result.sourcePathResults[0].statusDescription, "Path does not exist")
    }

    func testTCCPermissionCategoryDetection() {
        XCTAssertEqual(TCCPermissionCategory.detect(slug: "apple-sms", path: "~/Library/Messages"), .messages)
        XCTAssertEqual(TCCPermissionCategory.detect(slug: "sms", path: "/Users/user/Library/Messages"), .messages)
        XCTAssertEqual(TCCPermissionCategory.detect(slug: "messages", path: "/tmp/custom"), .messages)
        XCTAssertEqual(TCCPermissionCategory.detect(slug: "custom", path: "~/Library/Messages"), .messages)

        XCTAssertEqual(TCCPermissionCategory.detect(slug: "apple-mail", path: "~/Library/Mail"), .mail)
        XCTAssertEqual(TCCPermissionCategory.detect(slug: "mail", path: "/Users/user/Library/Mail"), .mail)
        XCTAssertEqual(TCCPermissionCategory.detect(slug: "maildir", path: "~/Library/Mail"), .mail)
        XCTAssertEqual(TCCPermissionCategory.detect(slug: "custom", path: "~/Library/Mail"), .mail)

        XCTAssertEqual(TCCPermissionCategory.detect(slug: "documents", path: "~/Documents"), .documents)
        XCTAssertEqual(TCCPermissionCategory.detect(slug: "downloads", path: "~/Downloads"), .downloads)
        XCTAssertEqual(TCCPermissionCategory.detect(slug: "desktop", path: "~/Desktop"), .desktop)

        XCTAssertNil(TCCPermissionCategory.detect(slug: "random-corpus", path: "/opt/corpus"))
    }

    func testTCCPermissionCategoryProperties() {
        let messages = TCCPermissionCategory.messages
        XCTAssertEqual(messages.displayName, "Messages")
        XCTAssertEqual(messages.iconName, "message.fill")
        XCTAssertTrue(messages.systemSettingsURL?.absoluteString.contains("Privacy_AllFiles") == true)
        XCTAssertTrue(messages.helpMessage.contains("SMS and iMessage history"))

        let mail = TCCPermissionCategory.mail
        XCTAssertEqual(mail.displayName, "Mail")
        XCTAssertEqual(mail.iconName, "envelope.fill")
        XCTAssertTrue(mail.systemSettingsURL?.absoluteString.contains("Privacy_AllFiles") == true)
        XCTAssertTrue(mail.helpMessage.contains("Full Disk Access"))

        let docs = TCCPermissionCategory.documents
        XCTAssertEqual(docs.displayName, "Documents")
        XCTAssertTrue(docs.systemSettingsURL?.absoluteString.contains("Privacy_FilesAndFolders") == true)
    }

    func testVolumeAccessWithMessagesAndMailTCCRestriction() {
        let mockStore = MockVolumeBookmarkStore()
        let mockFS = MockFileSystemAccessor()
        mockFS.readablePaths = ["/", "/System", "/Library", "/Applications", "/Users", "/Volumes"] // Messages & Mail not readable

        let service = VolumeAccessService(bookmarkStore: mockStore, fileSystem: mockFS)
        let result = service.testFullVolumeAccess(sourcePaths: [
            (slug: "apple-sms", root: "~/Library/Messages"),
            (slug: "apple-mail", root: "~/Library/Mail")
        ])

        XCTAssertFalse(result.isAccessible)
        XCTAssertEqual(result.sourcePathResults.count, 2)

        let smsResult = result.sourcePathResults[0]
        XCTAssertFalse(smsResult.isAccessible)
        XCTAssertEqual(smsResult.tccCategory, .messages)
        XCTAssertTrue(smsResult.requiresTCCPermission)
        XCTAssertEqual(smsResult.statusDescription, "Needs permission (Messages)")
        XCTAssertTrue(smsResult.tccHelpMessage?.contains("SMS and iMessage history") == true)

        let mailResult = result.sourcePathResults[1]
        XCTAssertFalse(mailResult.isAccessible)
        XCTAssertEqual(mailResult.tccCategory, .mail)
        XCTAssertTrue(mailResult.requiresTCCPermission)
        XCTAssertEqual(mailResult.statusDescription, "Needs permission (Mail)")
        XCTAssertTrue(mailResult.tccHelpMessage?.contains("Full Disk Access") == true)
    }

    func testUserDefaultsVolumeBookmarkStorePathSpecific() {
        let suiteName = "test.garage.volumeaccess.paths.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = UserDefaultsVolumeBookmarkStore(defaults: defaults)
        let samplePath = "/Users/test/Library/Messages"
        let sampleData = Data("messages_bookmark".utf8)

        XCTAssertNil(store.loadBookmarkData(forPath: samplePath))
        XCTAssertTrue(store.loadAllSourceBookmarks().isEmpty)

        store.saveBookmarkData(sampleData, forPath: samplePath)
        XCTAssertEqual(store.loadBookmarkData(forPath: samplePath), sampleData)
        XCTAssertEqual(store.loadAllSourceBookmarks()[samplePath], sampleData)

        store.clearBookmark(forPath: samplePath)
        XCTAssertNil(store.loadBookmarkData(forPath: samplePath))
        XCTAssertTrue(store.loadAllSourceBookmarks().isEmpty)
    }

    func testGrantSourceAccessUpdatesActiveSources() throws {
        let mockStore = MockVolumeBookmarkStore()
        let mockFS = MockFileSystemAccessor()
        let testDir = URL(fileURLWithPath: NSTemporaryDirectory())
        mockFS.readablePaths = ["/", "/System", "/Library", "/Applications", "/Users", "/Volumes", testDir.path]

        let service = VolumeAccessService(bookmarkStore: mockStore, fileSystem: mockFS)
        try service.grantSourceAccess(for: testDir, forSourcePath: testDir.path)

        XCTAssertNotNil(service.activeSourceURLs[testDir.path])
        XCTAssertEqual(service.activeSourceURLs[testDir.path]?.path, testDir.path)
    }
}

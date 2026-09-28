import XCTest
import PythonXPCService

/// The receiving side of a folder grant. The unit tests run unsandboxed and hand over plain URLs, so
/// they check the bookkeeping; consuming a real sandbox extension needs a store-signed build.
final class GarageFolderAccessStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "GarageFolderAccessStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testReachableFolderIsGrantedUnderItsKey() {
        let store = GarageFolderAccessStore(defaults: defaults)
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

        let result = store.grant(folder, key: GarageFolderAccessKey.root)

        XCTAssertTrue(result.success, result.message)
        XCTAssertEqual(store.grantedPaths[GarageFolderAccessKey.root], folder.path)
    }

    func testUnreachableURLIsRefusedAndKeepsThePreviousGrant() {
        let store = GarageFolderAccessStore(defaults: defaults)
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        store.grant(folder, key: GarageFolderAccessKey.root)

        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        let result = store.grant(missing, key: GarageFolderAccessKey.root)

        XCTAssertFalse(result.success)
        XCTAssertEqual(store.grantedPaths[GarageFolderAccessKey.root], folder.path)
    }

    func testANewGrantReplacesTheOldOneUnderTheSameKey() {
        let store = GarageFolderAccessStore(defaults: defaults)
        let first = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let second = URL(fileURLWithPath: "/", isDirectory: true)

        store.grant(first, key: GarageFolderAccessKey.root)
        store.grant(second, key: GarageFolderAccessKey.root)
        store.grant(first, key: GarageFolderAccessKey.source(first.path))

        XCTAssertEqual(store.grantedPaths[GarageFolderAccessKey.root], "/")
        XCTAssertEqual(store.grantedPaths.count, 2)
    }

    func testRevokeAllForgetsGrantsAndSavedBookmarks() {
        defaults.set(["root": Data([1, 2, 3])], forKey: GarageFolderAccessStore.defaultsKey)
        let store = GarageFolderAccessStore(defaults: defaults)
        store.grant(URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true), key: GarageFolderAccessKey.root)

        store.revokeAll()

        XCTAssertTrue(store.grantedPaths.isEmpty)
        XCTAssertNil(defaults.object(forKey: GarageFolderAccessStore.defaultsKey))
    }

    func testRestoreDropsBookmarksThatNoLongerResolve() {
        defaults.set([GarageFolderAccessKey.root: Data("not a bookmark".utf8)], forKey: GarageFolderAccessStore.defaultsKey)
        let store = GarageFolderAccessStore(defaults: defaults)

        XCTAssertEqual(store.restorePersisted(), [])
        XCTAssertTrue(store.grantedPaths.isEmpty)
        XCTAssertNil(defaults.object(forKey: GarageFolderAccessStore.defaultsKey))
    }

    func testKeysKeepGrantKindsApart() {
        XCTAssertEqual(GarageFolderAccessKey.root, "root")
        XCTAssertNotEqual(GarageFolderAccessKey.source("/a"), GarageFolderAccessKey.file("/a"))
    }
}

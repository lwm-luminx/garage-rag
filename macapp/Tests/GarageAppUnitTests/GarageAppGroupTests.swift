import Security
import XCTest
import PythonXPCService
@testable import GarageApp
@testable import PythonXPCService_protocol

/// `--data-directory` is what keeps a UI test's "Reset Database" away from the real cluster, so a
/// path that reaches real data must be refused rather than used or silently ignored.
final class GarageAppGroupTests: XCTestCase {
    private var root: URL!
    private var real: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("GarageAppGroupTests-\(UUID().uuidString)", isDirectory: true)
        real = root.appendingPathComponent("Group Containers/group/GarageApp", isDirectory: true)
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func override(_ arguments: [String]) throws -> URL? {
        try GarageAppGroup.dataDirectoryOverride(in: ["GarageApp"] + arguments, realDirectories: [real])
    }

    func testNoArgumentMeansNoOverride() throws {
        XCTAssertNil(try override([]))
        XCTAssertNil(GarageAppGroup.dataDirectoryOverride, "the test host must run on the default folder")
    }

    func testAcceptsASeparateFolderThatDoesNotExistYet() throws {
        let isolated = root.appendingPathComponent("ui-test/data", isDirectory: true)
        let url = try override([GarageAppLaunch.dataDirectoryArgument, isolated.path])
        XCTAssertEqual(url?.path, isolated.standardizedFileURL.path)
    }

    func testRefusesAMissingOrRelativePath() {
        XCTAssertThrowsError(try override([GarageAppLaunch.dataDirectoryArgument]))
        XCTAssertThrowsError(try override([GarageAppLaunch.dataDirectoryArgument, "relative/data"]))
    }

    func testRefusesTheRealFolderAndAnythingInsideIt() {
        XCTAssertThrowsError(try override([GarageAppLaunch.dataDirectoryArgument, real.path]))
        XCTAssertThrowsError(try override([GarageAppLaunch.dataDirectoryArgument, real.appendingPathComponent("pgdata").path]))
    }

    func testRefusesAFolderThatContainsTheRealOne() {
        XCTAssertThrowsError(try override([GarageAppLaunch.dataDirectoryArgument, root.path]))
        XCTAssertThrowsError(try override([GarageAppLaunch.dataDirectoryArgument, "/"]))
    }

    /// `~/Library/Application Support/GarageApp` is a link to the group folder on Developer ID builds.
    func testRefusesAPathThatReachesTheRealFolderThroughALink() throws {
        let link = root.appendingPathComponent("Application Support/GarageApp", isDirectory: true)
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: real)

        XCTAssertThrowsError(try override([GarageAppLaunch.dataDirectoryArgument, link.path]))
        XCTAssertThrowsError(try override([GarageAppLaunch.dataDirectoryArgument, link.appendingPathComponent("isolated").path]))
    }

    /// The App Store build's UI tests keep their folders in `<group container>/UITests`, inside a
    /// real directory but beside the real data folder.
    func testAcceptsAFolderInsideATestRootInsideARealDirectory() throws {
        let container = root.appendingPathComponent("Group Containers/group", isDirectory: true)
        let testRoot = container.appendingPathComponent("UITests", isDirectory: true)
        let isolated = testRoot.appendingPathComponent("run-1", isDirectory: true)
        let url = try GarageAppGroup.dataDirectoryOverride(
            in: ["GarageApp", GarageAppLaunch.dataDirectoryArgument, isolated.path],
            realDirectories: [container, real],
            testRoots: [testRoot]
        )
        XCTAssertEqual(url?.path, isolated.standardizedFileURL.path)
        // Without the test root, the container itself is real.
        XCTAssertThrowsError(try GarageAppGroup.dataDirectoryOverride(
            in: ["GarageApp", GarageAppLaunch.dataDirectoryArgument, isolated.path],
            realDirectories: [container, real]
        ))
    }

    func testRefusesTheTestRootItselfAndATestRootThatLinksToTheRealFolder() throws {
        let container = root.appendingPathComponent("Group Containers/group", isDirectory: true)
        let testRoot = container.appendingPathComponent("UITests", isDirectory: true)
        XCTAssertThrowsError(try GarageAppGroup.dataDirectoryOverride(
            in: ["GarageApp", GarageAppLaunch.dataDirectoryArgument, testRoot.path],
            realDirectories: [container, real],
            testRoots: [testRoot]
        ))

        let linked = root.appendingPathComponent("LinkedTests", isDirectory: true)
        try fm.createSymbolicLink(at: linked, withDestinationURL: real)
        XCTAssertThrowsError(try GarageAppGroup.dataDirectoryOverride(
            in: ["GarageApp", GarageAppLaunch.dataDirectoryArgument, linked.appendingPathComponent("run-1").path],
            realDirectories: [container, real],
            testRoots: [linked]
        ))
    }

    func testTheUITestRootIsInTheGroupContainerBesideTheDataFolder() {
        XCTAssertTrue(GarageAppGroup.uiTestDataRoot.path.hasSuffix("Library/Group Containers/\(GarageAppGroup.identifier)/UITests"))
    }

    func testTheRealDirectoriesCoverEveryKnownLocation() {
        let paths = GarageAppGroup.realDataDirectories.map(\.path)
        XCTAssertTrue(paths.contains { $0.hasSuffix("Library/Application Support/GarageApp") })
        XCTAssertTrue(paths.contains { $0.hasSuffix("Library/Group Containers/\(GarageAppGroup.identifier)") })
        XCTAssertTrue(paths.contains { $0.hasSuffix("Library/Containers/me.rickmark.garage-rag") })
    }

    func testTheRealKeychainItemIsUsedWithoutAnOverride() {
        XCTAssertEqual(GaragePostgresEndpoint.keychainService, "com.rickmark.garage.postgres")
        XCTAssertNil(GaragePostgresEndpoint.isolatedPasswordFile)
    }

    /// The shared item lives in the data-protection keychain under the App Group, which the app and
    /// the launcher helper bundles are all entitled to; the login-keychain item it replaces has
    /// neither key, so a build without an application identifier still finds its own item.
    func testThePasswordItemIsInTheAppGroupKeychain() {
        XCTAssertEqual(GaragePostgresEndpoint.keychainAccessGroup, GarageAppGroup.identifier)
        let group = GaragePostgresEndpoint.groupItemQuery()
        XCTAssertEqual(group[kSecAttrAccessGroup] as? String, "DWVXMLB45Y.group.me.rickmark.garage-rag")
        XCTAssertEqual(group[kSecUseDataProtectionKeychain] as? Bool, true)
        XCTAssertEqual(group[kSecAttrSynchronizable] as? Bool, false)
        XCTAssertEqual(group[kSecAttrService] as? String, GaragePostgresEndpoint.keychainService)
        XCTAssertEqual(group[kSecAttrAccount] as? String, NSUserName())

        let legacy = GaragePostgresEndpoint.legacyItemQuery()
        XCTAssertNil(legacy[kSecAttrAccessGroup])
        XCTAssertNil(legacy[kSecUseDataProtectionKeychain])
        XCTAssertEqual(legacy[kSecAttrService] as? String, GaragePostgresEndpoint.keychainService)
        XCTAssertEqual(legacy[kSecAttrAccount] as? String, NSUserName())
    }

    /// The test host is signed without a provisioning profile, so the data-protection keychain refuses
    /// it with errSecMissingEntitlement; that is reported as "unavailable", never as an error or as a
    /// missing password, which is what keeps unentitled builds on the login keychain.
    func testAnUnentitledProcessSeesTheGroupKeychainAsUnavailable() throws {
        switch try GaragePostgresEndpoint.readGroupPassword() {
        case .unavailable, .notFound:
            break
        case .found:
            XCTFail("the unit test host should not be able to read the shared password item")
        }
    }

    /// `~` expands against the account's home folder, not `NSHomeDirectory()`: in the sandbox that
    /// is the app's container, and the grant dialog for `~/Library/Mail` opened in its empty copy.
    func testTildeExpandsAgainstTheRealHomeFolder() {
        let home = GarageAppGroup.realHomeDirectory
        XCTAssertEqual(GarageAppGroup.expandingTilde(in: "~/Library/Mail"), home + "/Library/Mail")
        XCTAssertEqual(GarageAppGroup.expandingTilde(in: "~"), home)
        XCTAssertEqual(GarageAppGroup.expandingTilde(in: "/Users/someone/Mail"), "/Users/someone/Mail")
        XCTAssertEqual(GarageAppGroup.expandingTilde(in: "~other/Mail"), "~other/Mail")
        XCTAssertFalse(home.contains("/Library/Containers/"))
    }
}

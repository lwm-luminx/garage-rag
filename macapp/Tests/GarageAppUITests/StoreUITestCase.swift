import Foundation
import Security
import XCTest

/// Base for UI tests of the sandboxed App Store build (StoreMailMessagesUITests,
/// StoreScreenshotsUITests, and the store-only features' tests of the repository that builds it).
///
/// The test target's host app is the unsandboxed build, so these launch the store bundle named by
/// `GARAGE_UITEST_STORE_APP` (with `xcodebuild test`, set `TEST_RUNNER_GARAGE_UITEST_STORE_APP`):
///
///     aspect build //macapp:GarageStore.app      # in garage-enterprise, which holds the store platform
///     TEST_RUNNER_GARAGE_UITEST_STORE_APP=$PWD/bazel-bin/macapp/GarageStore.app \
///       xcodebuild test -project macapp/Garage.xcodeproj -scheme GarageAppUITests \
///       -only-testing:GarageAppUITests/StoreMailMessagesUITests
///
/// Unzip the bundle first if Bazel produced `GarageStore.app.zip`. Each test's data folder lives in
/// the App Group container's `UITests` folder, as every UI test's does (`GarageUITestCase`), the one
/// place the sandboxed app and the sandboxed runner both reach.
class StoreUITestCase: GarageUITestCase {
    static let storeAppVariable = "GARAGE_UITEST_STORE_APP"

    private static func storeAppURL() throws -> URL {
        let path = ProcessInfo.processInfo.environment[storeAppVariable] ?? ""
        try XCTSkipIf(path.isEmpty, "Set \(storeAppVariable) to a GarageStore.app built with garage-enterprise's --config=appstore.")
        let url = URL(fileURLWithPath: path, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "\(storeAppVariable) names \(path), which does not exist")
        return url
    }

    override func makeApplication() throws -> XCUIApplication {
        let url = try Self.storeAppURL()
        let entitlements = try Self.entitlements(of: url)
        XCTAssertEqual(
            entitlements["com.apple.security.app-sandbox"] as? Bool, true,
            "\(url.path) is not sandboxed, so it is not the App Store build"
        )
        return XCUIApplication(url: url)
    }

    /// The sandboxed store build reaches no test root but the App Group's.
    override func makeDataDirectoryParent() throws -> URL {
        Self.storeDataDirectoryRoot
    }

    static func entitlements(of bundle: URL) throws -> [String: Any] {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else {
            throw XCTSkip("could not read the code signature of \(bundle.path)")
        }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        let status = SecCodeCopySigningInformation(code, flags, &info)
        guard status == errSecSuccess, let dictionary = info as? [String: Any] else {
            throw XCTSkip("could not read the signing information of \(bundle.path)")
        }
        let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        return entitlements ?? [:]
    }

    // MARK: - Sources page

    /// Fills the Add form from a Quick Presets entry, so kind, class and trust are the preset's, then
    /// replaces the slug and root when given.
    func addSource(preset: String, slug: String? = nil, root: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        open(section: "sources", file: file, line: line)
        let slugField = revealCustomSourceForm(file: file, line: line)

        let menu = app.menuButtons["Choose preset…"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "no Quick Presets menu", file: file, line: line)
        click(menu)
        let item = app.menuItems[preset]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no \(preset) preset", file: file, line: line)
        item.click()

        if let slug { replaceText(in: slugField, with: slug, file: file, line: line) }
        if let root { replaceText(in: element(identifier: "sources.form.root"), with: root, file: file, line: line) }

        let submit = element(identifier: "sources.form.submit")
        XCTAssertTrue(waitForEnabled(submit), "Add / Update Source stayed disabled", file: file, line: line)
        click(submit)
    }

    func sourceRow(_ slug: String) -> XCUIElement {
        element(identifier: "sources.row.\(slug)")
    }
}

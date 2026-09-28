import XCTest
@testable import GarageApp

final class DropboxFolderTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

    private func locate(existing: Set<String>, info: String? = nil) -> String? {
        DropboxFolder.locate(home: home, exists: { existing.contains($0) }, infoJSON: { info?.data(using: .utf8) })
    }

    func testHomeFolderLinkWinsWhenPresent() {
        let found = locate(
            existing: ["/Users/tester/Dropbox", "/Users/tester/Library/CloudStorage/Dropbox"],
            info: #"{"personal": {"path": "/Users/tester/Library/CloudStorage/Dropbox"}}"#
        )
        XCTAssertEqual(found, "~/Dropbox")
    }

    func testInfoJSONNamesTheFolderWhenThereIsNoLink() {
        let found = locate(
            existing: ["/Volumes/Data/Dropbox"],
            info: #"{"personal": {"path": "/Volumes/Data/Dropbox", "host": 1}}"#
        )
        XCTAssertEqual(found, "/Volumes/Data/Dropbox")
    }

    func testPersonalAccountComesBeforeBusiness() {
        let info = #"{"business": {"path": "/Users/tester/Dropbox (Acme)"}, "personal": {"path": "/Users/tester/Library/CloudStorage/Dropbox"}}"#
        let both: Set<String> = ["/Users/tester/Dropbox (Acme)", "/Users/tester/Library/CloudStorage/Dropbox"]
        XCTAssertEqual(locate(existing: both, info: info), "~/Library/CloudStorage/Dropbox")
        XCTAssertEqual(locate(existing: ["/Users/tester/Dropbox (Acme)"], info: info), "~/Dropbox (Acme)")
    }

    func testFileProviderFolderIsTheLastFallback() {
        XCTAssertEqual(locate(existing: ["/Users/tester/Library/CloudStorage/Dropbox"]), "~/Library/CloudStorage/Dropbox")
    }

    func testNothingFoundIsNil() {
        XCTAssertNil(locate(existing: []))
        XCTAssertNil(locate(existing: [], info: "not json"))
        XCTAssertNil(locate(existing: [], info: #"{"personal": {"path": "relative/Dropbox"}}"#))
    }

    func testAccountPathsIgnoreMalformedEntries() {
        let info = #"{"personal": {"path": "/a"}, "business": "nope", "other": {"path": "/c"}}"#.data(using: .utf8)
        XCTAssertEqual(DropboxFolder.accountPaths(in: info), ["/a", "/c"])
        XCTAssertEqual(DropboxFolder.accountPaths(in: nil), [])
    }

    func testAbbreviatingHome() {
        XCTAssertEqual(DropboxFolder.abbreviatingHome("/Users/tester/Dropbox", home: "/Users/tester"), "~/Dropbox")
        XCTAssertEqual(DropboxFolder.abbreviatingHome("/Users/tester", home: "/Users/tester"), "~")
        XCTAssertEqual(DropboxFolder.abbreviatingHome("/Users/testerx/Dropbox", home: "/Users/tester"), "/Users/testerx/Dropbox")
    }

    func testPresetRootIsAlwaysSet() {
        XCTAssertFalse(SourcePreset.dropbox.spec.root.isEmpty)
        XCTAssertEqual(SourcePreset.dropbox.spec.slug, "dropbox")
    }
}

import XCTest
@testable import GarageApp

final class CloudClientFoldersTests: XCTestCase {
    private let home = "/Users/rick"

    private func locate(_ kind: String, entries: [String], existing: Set<String> = [], dropbox: String? = nil) -> String? {
        CloudClientFolders.locate(
            kind: kind,
            home: home,
            cloudStorageEntries: entries,
            exists: { existing.contains($0) },
            dropbox: { dropbox }
        )
    }

    func testOnlyDropboxLinksToItsAppToday() {
        XCTAssertEqual(CloudClientFolders.client(for: "dropbox")?.app, "Dropbox")
        XCTAssertEqual(CloudClientFolders.client(for: "Dropbox")?.installURL.host, "www.dropbox.com")
        for kind in ["onedrive", "google_drive", "outlook", "gmail", "filesystem", "git", "maildir"] {
            XCTAssertNil(CloudClientFolders.client(for: kind), kind)
            XCTAssertNil(CloudClientFolders.state(for: kind), kind)
        }
    }

    func testDropboxIsWhereDropboxFolderFindsIt() {
        XCTAssertEqual(locate("dropbox", entries: ["Dropbox"], dropbox: "~/Dropbox"), "~/Dropbox")
        XCTAssertNil(locate("dropbox", entries: []))
    }

    func testOneDrivePrefersThePersonalAccount() {
        XCTAssertEqual(
            locate("onedrive", entries: ["Dropbox", "OneDrive-Contoso", "OneDrive-Personal"]),
            "~/Library/CloudStorage/OneDrive-Personal"
        )
        XCTAssertEqual(locate("onedrive", entries: ["OneDrive-Contoso"]), "~/Library/CloudStorage/OneDrive-Contoso")
        XCTAssertEqual(locate("onedrive", entries: [], existing: ["/Users/rick/OneDrive"]), "~/OneDrive")
        XCTAssertNil(locate("onedrive", entries: ["Dropbox"]))
    }

    func testGoogleDriveIsTheAccountsMyDrive() {
        let account = "GoogleDrive-rick@example.com"
        XCTAssertEqual(
            locate("google_drive", entries: [account], existing: ["/Users/rick/Library/CloudStorage/\(account)/My Drive"]),
            "~/Library/CloudStorage/\(account)/My Drive"
        )
        XCTAssertEqual(locate("google_drive", entries: [account]), "~/Library/CloudStorage/\(account)")
        XCTAssertNil(locate("google_drive", entries: ["OneDrive-Personal"]))
    }

    func testKindsWithoutAClientHaveNoFolder() {
        XCTAssertNil(locate("gmail", entries: ["GoogleDrive-rick@example.com"]))
        XCTAssertNil(locate("outlook", entries: ["OneDrive-Personal"]))
    }
}

import Foundation
import Security
import SQLite3
import XCTest

/// Base for UI tests of the sandboxed App Store build, which the site promises can index Apple Mail
/// and Messages.
///
/// The test target's host app is the unsandboxed build, so these launch the store bundle named by
/// `GARAGE_UITEST_STORE_APP` (with `xcodebuild test`, set `TEST_RUNNER_GARAGE_UITEST_STORE_APP`):
///
///     aspect build //macapp:GarageStore.app
///     TEST_RUNNER_GARAGE_UITEST_STORE_APP=$PWD/bazel-bin/macapp/GarageStore.app \
///       xcodebuild test -project macapp/Garage.xcodeproj -scheme GarageAppUITests \
///       -only-testing:GarageAppUITests/StoreMailMessagesUITests
///
/// Unzip the bundle first if Bazel produced `GarageStore.app.zip`. The sandbox keeps the app out of
/// the runner's temporary folder, so each test's data folder lives in the App Group container's
/// `UITests` folder (`GarageAppGroup.uiTestDataRoot`), the one place both can reach. The runner is
/// sandboxed too (Xcode's XCTRunner template), so it writes there through the App Group the test
/// target's entitlements give it; without that, setup fails with Cocoa error 513. On macOS 15 the
/// first run may ask whether the test runner may access data from other apps.
class StoreUITestCase: GarageUITestCase {
    static let storeAppVariable = "GARAGE_UITEST_STORE_APP"
    static let appGroup = "DWVXMLB45Y.group.me.rickmark.garage-rag"

    /// The account's real home folder. The runner is sandboxed, so `NSHomeDirectory()` is its
    /// container, and the app's view of `~` is exactly what these tests check.
    static var realHome: String {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }

    private static func storeAppURL() throws -> URL {
        let path = ProcessInfo.processInfo.environment[storeAppVariable] ?? ""
        try XCTSkipIf(path.isEmpty, "Set \(storeAppVariable) to a GarageStore.app built with --config=appstore.")
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

    override func makeDataDirectoryParent() throws -> URL {
        URL(fileURLWithPath: Self.realHome, isDirectory: true)
            .appendingPathComponent("Library/Group Containers/\(Self.appGroup)/UITests", isDirectory: true)
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

/// Mail and Messages in the App Store build: registering the presets, what the build can read at
/// their real locations, and indexing a fixture chat.db and Mail folder end to end.
///
/// The fixture tests put their data in the test's own folder, which the sandbox can read without a
/// grant, so they show whether the pipeline handles the formats. The preset tests point at the real
/// `~/Library/Messages` and `~/Library/Mail` but read nothing from them: they check where the
/// source points and what the disk access check reports.
final class StoreMailMessagesUITests: StoreUITestCase {

    // MARK: - Presets at their real locations

    /// Inside the sandbox `~` is the app's container, so the preset's `~/Library/Messages` must still
    /// register the account's real Messages folder, not `…/Library/Containers/…/Data/Library/Messages`.
    func testMessagesPresetRegistersTheRealMessagesFolder() throws {
        try assertPresetRegistersRealFolder(preset: "Messages", slug: "apple-sms", folder: "Library/Messages")
    }

    func testMailPresetRegistersTheRealMailFolder() throws {
        try assertPresetRegistersRealFolder(preset: "Apple Mail", slug: "apple-mail", folder: "Library/Mail")
    }

    /// Full Disk Access does not lift the App Sandbox, so without a folder the person picked, the store
    /// build cannot read Messages or Mail and must say so and offer the folder grant. If this fails
    /// because the folders read fine, Full Disk Access (or something else) does reach them.
    func testWithoutAFolderGrantMessagesAndMailNeedPermission() throws {
        let messages = URL(fileURLWithPath: Self.realHome).appendingPathComponent("Library/Messages")
        let mail = URL(fileURLWithPath: Self.realHome).appendingPathComponent("Library/Mail")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: messages.path), "this account has no ~/Library/Messages")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: mail.path), "this account has no ~/Library/Mail")

        try launchApp()
        waitForBackend()
        addSource(preset: "Messages")
        XCTAssertTrue(sourceRow("apple-sms").waitForExistence(timeout: 30), "the Messages preset was not added")
        addSource(preset: "Apple Mail")
        XCTAssertTrue(sourceRow("apple-mail").waitForExistence(timeout: 30), "the Apple Mail preset was not added")

        let refresh = element(identifier: "sources.diskAccess.refresh")
        XCTAssertTrue(refresh.waitForExistence(timeout: 10), "no disk access refresh button")
        click(refresh)

        let needed = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@ OR value == %@", "PERMISSIONS NEEDED", "PERMISSIONS NEEDED")
        )
        XCTAssertTrue(
            waitUntil(timeout: 30) { needed.count >= 2 },
            "Messages and Mail are not both reported as needing permission (\(needed.count) found); check what the store build can read"
        )
        XCTAssertTrue(
            button(label: "Grant Folder Access…").exists,
            "no Grant Folder Access button, the one way into these folders from the sandbox"
        )
        XCTAssertFalse(
            element(text: "DISK OK").exists,
            "a source reads as DISK OK without a folder grant"
        )
    }

    private func assertPresetRegistersRealFolder(preset: String, slug: String, folder: String,
                                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let real = URL(fileURLWithPath: Self.realHome).appendingPathComponent(folder).path
        try XCTSkipUnless(FileManager.default.fileExists(atPath: real), "this account has no \(real)")

        try launchApp()
        waitForBackend()
        addSource(preset: preset, file: file, line: line)
        XCTAssertTrue(
            sourceRow(slug).waitForExistence(timeout: 30),
            "the \(preset) preset was not added (the app may have resolved ~ to its container, where the folder does not exist)",
            file: file,
            line: line
        )
        let container = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "/Library/Containers/", "/Library/Containers/")
        ).firstMatch
        XCTAssertFalse(container.exists, "the \(preset) source points into the sandbox container: \(container.debugDescription)", file: file, line: line)
        XCTAssertTrue(
            element(textContaining: real).exists || element(text: "~/\(folder)").exists,
            "the \(preset) source does not show \(real)",
            file: file,
            line: line
        )
        // Register it the way people keep it: in garage.json, where it must still say the real folder.
        let sync = element(identifier: "sources.sync")
        XCTAssertTrue(waitForEnabled(sync), "the sync button stayed disabled", file: file, line: line)
        click(sync)
        XCTAssertTrue(
            waitUntil(timeout: 30) { ((try? String(contentsOf: self.configFile, encoding: .utf8)) ?? "").contains(slug) },
            "sync did not write the \(preset) source to garage.json",
            file: file,
            line: line
        )
        let config = (try? String(contentsOf: configFile, encoding: .utf8)) ?? ""
        XCTAssertFalse(config.contains("/Library/Containers/"), "garage.json points \(slug) into the sandbox container:\n\(config)", file: file, line: line)
    }

    // MARK: - Fixtures, end to end

    /// A two-conversation chat.db with Apple's table layout: Scan counts the conversations and
    /// Scan & Ingest makes each one a document.
    func testIndexesAMessagesDatabase() throws {
        let folder = dataDirectory.appendingPathComponent("Messages", isDirectory: true)
        try Self.writeMessagesFixture(to: folder)
        try launchApp()
        waitForBackend()

        addSource(preset: "Messages", slug: "uitest-messages", root: folder.path)
        try assertScanAndIngest(slug: "uitest-messages", expected: 2)
    }

    /// Two messages in Apple Mail's layout (`V10/<account>/INBOX.mbox/<store>/Data/Messages/N.emlx`).
    func testIndexesAMailFolder() throws {
        let folder = dataDirectory.appendingPathComponent("Mail", isDirectory: true)
        try Self.writeMailFixture(to: folder)
        try launchApp()
        waitForBackend()

        addSource(preset: "Apple Mail", slug: "uitest-mail", root: folder.path)
        try assertScanAndIngest(slug: "uitest-mail", expected: 2)
    }

    private func assertScanAndIngest(slug: String, expected: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(sourceRow(slug).waitForExistence(timeout: 30), "the fixture source was not added", file: file, line: line)
        let scanIngest = element(identifier: "sources.row.\(slug).scanIngest")
        XCTAssertTrue(waitForEnabled(scanIngest), "Scan & Ingest stayed disabled", file: file, line: line)
        click(scanIngest)

        // The scan's count is the source's expected total, shown as "<ingested>/<expected> DOCS".
        XCTAssertTrue(
            element(textContaining: "/\(expected) DOCS").waitForExistence(timeout: 120),
            "the scan did not count \(expected) items in the fixture",
            file: file,
            line: line
        )
        open(section: "status", file: file, line: line)
        let documents = element(identifier: "status.figure.documents")
        XCTAssertTrue(
            waitUntil(timeout: 240) { documents.exists && self.shownText(of: documents) == "\(expected)" },
            "the Status page never counted the \(expected) fixture items",
            file: file,
            line: line
        )
    }

    // MARK: - Fixture writers

    static let conversations: [(chat: String, handle: String, messages: [(fromMe: Bool, text: String)])] = [
        ("+15550100", "+15550100", [
            (false, "Are we still on for the garage sale Saturday morning?"),
            (true, "Yes, bring the folding tables and the price stickers."),
            (false, "Great, I will be there by eight with coffee."),
        ]),
        ("fixture.friend@example.com", "fixture.friend@example.com", [
            (true, "The lighthouse photos from the coast trip came out beautifully."),
            (false, "Send me the one with the fog rolling over the rocks please."),
        ]),
    ]

    /// Writes `chat.db` with the tables Garage's scanner recognizes Messages by (chat, message,
    /// handle) and the join tables that tie them together.
    static func writeMessagesFixture(to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var db: OpaquePointer?
        let path = folder.appendingPathComponent("chat.db").path
        guard sqlite3_open(path, &db) == SQLITE_OK, let db else {
            throw XCTSkip("could not create \(path)")
        }
        defer { sqlite3_close(db) }

        func exec(_ sql: String) throws {
            var error: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
                let message = error.map { String(cString: $0) } ?? "unknown error"
                sqlite3_free(error)
                XCTFail("chat.db fixture: \(message)\n\(sql)")
            }
        }
        func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "''") + "'" }

        try exec("""
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL, country TEXT, service TEXT NOT NULL, uncanonicalized_id TEXT);
            CREATE TABLE chat (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT UNIQUE NOT NULL, style INTEGER, state INTEGER, chat_identifier TEXT, service_name TEXT, display_name TEXT);
            CREATE TABLE message (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT UNIQUE NOT NULL, text TEXT, handle_id INTEGER DEFAULT 0, service TEXT, date INTEGER, is_from_me INTEGER DEFAULT 0, attributedBody BLOB);
            CREATE TABLE chat_message_join (chat_id INTEGER REFERENCES chat (ROWID) ON DELETE CASCADE, message_id INTEGER REFERENCES message (ROWID) ON DELETE CASCADE, message_date INTEGER DEFAULT 0, PRIMARY KEY (chat_id, message_id));
            CREATE TABLE chat_handle_join (chat_id INTEGER REFERENCES chat (ROWID) ON DELETE CASCADE, handle_id INTEGER REFERENCES handle (ROWID) ON DELETE CASCADE, UNIQUE(chat_id, handle_id));
            """)
        // Apple's `date` is nanoseconds since 2001-01-01; a day apart, a minute between messages.
        var date: Int64 = 780_000_000 * 1_000_000_000
        var messageID = 0
        for (index, conversation) in conversations.enumerated() {
            let chatID = index + 1
            try exec("INSERT INTO handle (ROWID, id, country, service) VALUES (\(chatID), \(quoted(conversation.handle)), 'us', 'iMessage');")
            try exec("""
                INSERT INTO chat (ROWID, guid, style, state, chat_identifier, service_name, display_name)
                VALUES (\(chatID), \(quoted("iMessage;-;" + conversation.chat)), 45, 3, \(quoted(conversation.chat)), 'iMessage', '');
                INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (\(chatID), \(chatID));
                """)
            for message in conversation.messages {
                messageID += 1
                date += 60 * 1_000_000_000
                try exec("""
                    INSERT INTO message (ROWID, guid, text, handle_id, service, date, is_from_me)
                    VALUES (\(messageID), \(quoted("fixture-\(messageID)")), \(quoted(message.text)), \(message.fromMe ? 0 : chatID), 'iMessage', \(date), \(message.fromMe ? 1 : 0));
                    INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (\(chatID), \(messageID), \(date));
                    """)
            }
            date += 86_400 * 1_000_000_000
        }
    }

    static let mailMessages: [(subject: String, from: String, body: String)] = [
        ("Seed swap at the community garden",
         "Fixture Gardener <gardener@example.com>",
         "Bring any spare tomato and bean seeds on Sunday. We will label them by variety and trade over lunch."),
        ("Invoice for the kayak rental",
         "Fixture Outfitters <billing@example.org>",
         "Thanks for paddling with us. Two kayaks for four hours comes to eighty dollars, paid in full."),
    ]

    /// Writes an Apple Mail tree: each `.emlx` is the RFC 822 message's byte count on the first line,
    /// the message, then an XML property list of Mail's flags.
    static func writeMailFixture(to folder: URL) throws {
        let messages = folder.appendingPathComponent(
            "V10/00000000-0000-4000-8000-000000000001/INBOX.mbox/00000000-0000-4000-8000-000000000002/Data/Messages",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true)
        for (index, mail) in mailMessages.enumerated() {
            let rfc822 = """
                From: \(mail.from)\r
                To: Fixture Owner <owner@example.net>\r
                Subject: \(mail.subject)\r
                Date: Wed, 1\(index) Sep 2026 09:30:00 -0700\r
                Message-ID: <fixture-\(index + 1)@example.com>\r
                MIME-Version: 1.0\r
                Content-Type: text/plain; charset=utf-8\r
                \r
                \(mail.body)\r

                """
            let body = Data(rfc822.utf8)
            let plist = """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0">
                <dict>
                \t<key>flags</key>
                \t<integer>8590195713</integer>
                </dict>
                </plist>

                """
            var file = Data("\(body.count)\n".utf8)
            file.append(body)
            file.append(Data(plist.utf8))
            try file.write(to: messages.appendingPathComponent("\(index + 1).emlx"))
        }
    }
}

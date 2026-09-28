import CoreFoundation
import XCTest

/// The setup assistant walked to the end, and skipped. On a `--data-directory` launch the app keeps
/// Finish and Skip for that launch only (`FirstRunCoordinator.persistsCompletion`), so these tests
/// leave the real `garage.firstRun.completed` alone, and they check that they did.
///
/// Nothing real is touched: no location card is committed (they name real folders such as
/// ~/Documents), no model is registered or downloaded, and no assistant is connected (that writes
/// its real configuration file). The custom-folder button is left alone too: its open panel saves a
/// security-scoped bookmark in the real preferences.
final class SetupAssistantUITests: GarageUITestCase {

    private static let completedKey = "garage.firstRun.completed"

    /// The real preference, as the app's own domain holds it outside this test's argument domain.
    private static func savedCompletion() -> String {
        let value = CFPreferencesCopyAppValue(completedKey as CFString, bundleIdentifier as CFString)
        return value.map { "\($0)" } ?? "unset"
    }

    /// A checkbox's state, which XCUITest reports as a number (or, on some systems, its string).
    private func isOn(_ checkbox: XCUIElement) -> Bool {
        (checkbox.value as? NSNumber)?.boolValue ?? ((checkbox.value as? String) == "1")
    }

    private func waitForDataPage(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element(identifier: "firstRun.root").waitForExistence(timeout: 20), "the setup assistant did not open", file: file, line: line)
        // The first page moves on by itself once the database and services are up.
        XCTAssertTrue(
            element(identifier: "firstRun.decideLater").waitForExistence(timeout: 120),
            "the assistant never reached the data page",
            file: file,
            line: line
        )
    }

    private func assertMainWindowReplacedTheAssistant(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element(identifier: "sidebar.status").waitForExistence(timeout: 20), "no main window after the assistant", file: file, line: line)
        XCTAssertTrue(
            waitUntil(timeout: 10) { !self.element(identifier: "firstRun.root").exists },
            "the assistant stayed up",
            file: file,
            line: line
        )
    }

    /// Data → models → agent → Finish, choosing nothing on each page, ends on the main window with
    /// nothing added.
    func testWalkingEveryPageToFinishOpensTheMainWindow() throws {
        let savedBefore = Self.savedCompletion()
        try launchApp(firstRunCompleted: false)
        waitForDataPage()

        // Data: a location card toggles the pick, which the Next button counts. Only the pick
        // changes; nothing is added until Next, which this test never presses with a pick.
        let next = element(identifier: "firstRun.next")
        XCTAssertTrue(next.exists, "the data page has no Next")
        let documents = element(identifier: "firstRun.source.documents")
        if documents.exists, documents.isEnabled {
            let before = next.label
            click(documents)
            XCTAssertTrue(waitUntil(timeout: 10) { next.label != before }, "picking a location did not change Next (\(before))")
            click(documents)
            XCTAssertTrue(waitUntil(timeout: 10) { next.label == before }, "unpicking a location did not restore Next (\(next.label))")
        }
        // "I'll decide later" clears the picks, so no card is added.
        click(element(identifier: "firstRun.decideLater"))

        // Models: the presets are listed and preselection is left uncommitted; downloads are off.
        let download = element(identifier: "firstRun.downloadModels")
        XCTAssertTrue(download.waitForExistence(timeout: 30), "the assistant did not move on to the models page")
        let models = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "firstRun.model."))
        XCTAssertTrue(waitUntil(timeout: 15) { models.count > 0 }, "the models page lists no presets")
        if isOn(download) {
            click(download)
        }
        XCTAssertTrue(waitUntil(timeout: 5) { !self.isOn(download) }, "the download checkbox did not turn off (\(download.value ?? "nil"))")
        // "I'll decide later" clears the model picks, so nothing is registered or downloaded.
        click(element(identifier: "firstRun.decideLater"))

        // Agent: the server card and the assistants are shown; none is connected.
        let finish = element(identifier: "firstRun.finish")
        XCTAssertTrue(finish.waitForExistence(timeout: 30), "the assistant did not move on to the agent page")
        XCTAssertTrue(element(identifier: "firstRun.mcpServer").exists, "the agent page has no server card")
        XCTAssertTrue(element(identifier: "firstRun.registerClients").exists, "the agent page has no Connect button")
        XCTAssertTrue(element(identifier: "firstRun.agentPrivacy").exists, "the agent page does not say what an agent receives")
        XCTAssertFalse(element(identifier: "firstRun.decideLater").exists, "the agent page still shows the models page's buttons")

        XCTAssertTrue(waitForEnabled(finish), "Finish stayed disabled")
        click(finish)
        assertMainWindowReplacedTheAssistant()

        // Nothing was added on the way.
        waitForBackend()
        open(section: "sources")
        XCTAssertTrue(element(text: "No sources configured yet.").waitForExistence(timeout: 15), "the walk added a source")
        open(section: "models")
        XCTAssertTrue(element(text: "No embedding model").waitForExistence(timeout: 30), "the walk registered an embedding model")
        XCTAssertEqual(Self.savedCompletion(), savedBefore, "Finish saved the real garage.firstRun.completed")
    }

    /// Skip setup, offered while services still start, goes straight to the main window.
    func testSkipOpensTheMainWindow() throws {
        let savedBefore = Self.savedCompletion()
        try launchApp(firstRunCompleted: false)
        XCTAssertTrue(element(identifier: "firstRun.root").waitForExistence(timeout: 20), "the setup assistant did not open")

        let skip = element(identifier: "firstRun.skipSetup")
        XCTAssertTrue(skip.exists, "the setup assistant offers no way to skip it")
        XCTAssertTrue(waitForEnabled(skip), "Skip setup stayed disabled")
        skip.click()
        assertMainWindowReplacedTheAssistant()
        XCTAssertEqual(Self.savedCompletion(), savedBefore, "Skip saved the real garage.firstRun.completed")
    }
}

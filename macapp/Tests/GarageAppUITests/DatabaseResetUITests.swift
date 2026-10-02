import AppKit
import XCTest

/// Drives Database → Reset Database… → Reset and Relaunch in the real app and checks the handoff
/// between the instance that deletes the database and the one it relaunches.
final class DatabaseResetUITests: GarageUITestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Each step below is worth reporting on its own.
        continueAfterFailure = true
    }

    /// Start Over: the relaunch opens the setup assistant.
    func testResetHandsOverToTheRelaunchedInstance() throws {
        try checkResetHandsOver(startingOver: true)
    }

    /// Keep Settings, the sheet's default: the relaunch fills the new database with no assistant.
    func testAResetThatKeepsTheSettingsSkipsTheAssistant() throws {
        try checkResetHandsOver(startingOver: false)
    }

    private func checkResetHandsOver(startingOver: Bool) throws {
        let app = try launchApp()
        let oldPID = try XCTUnwrap(appPID)

        // The first cluster, which the reset must replace.
        XCTAssertTrue(waitUntil(timeout: 90) { self.postgresIsServing(from: oldPID) }, "Postgres never came up on the test folder")
        let firstCluster = try clusterIdentity()

        open(section: "database")
        let reset = app.buttons["database.reset"]
        XCTAssertTrue(reset.waitForExistence(timeout: 10), "no Reset Database… button")
        XCTAssertTrue(waitForEnabled(reset), "Reset Database… stayed disabled")
        reset.click()

        let confirm = app.buttons["reset.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "the reset sheet did not open")
        // The sheet names the folder it deletes: the test's own, never the familiar real one.
        let pathNote = app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", pgdata.path)).firstMatch
        XCTAssertTrue(pathNote.exists, "the reset sheet does not name \(pgdata.path)")
        if startingOver {
            // A segment of the Settings picker, which accessibility reports as a radio button.
            let startOver = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@ OR title == %@", "Start over", "Start over")).firstMatch
            XCTAssertTrue(startOver.waitForExistence(timeout: 5), "the reset sheet has no Start over choice")
            startOver.click()
        }
        let clickedAt = Date()
        confirm.click()

        // 1. The instance that reset must quit on its own. Before b107e82 it deadlocked in `terminate:`
        //    (called from inside a main-actor job, it waited for a reply scheduled as another one), so
        //    the relaunched instance could only time out of its 30s wait.
        let oldExited = waitUntil(timeout: 20) { !Self.isAlive(oldPID) }
        XCTAssertTrue(oldExited, "the old instance (pid \(oldPID)) was still running 20s after Reset and Relaunch")

        // 2. Exactly one new instance, launched with the reset flag.
        let newPID = try XCTUnwrap(
            waitUntilValue(timeout: 30) { Self.runningGarageInstances().map(\.processIdentifier).first { $0 != oldPID } },
            "no relaunched instance appeared"
        )
        launchedPIDs.insert(newPID)
        XCTAssertTrue(Self.arguments(of: newPID).contains("--after-database-reset"), "the relaunch did not carry --after-database-reset")
        XCTAssertTrue(Self.arguments(of: newPID).contains(dataDirectory.path), "the relaunch did not carry --data-directory")
        XCTAssertEqual(
            Self.arguments(of: newPID).contains("--keep-settings"), !startingOver,
            startingOver ? "Start over carried --keep-settings" : "Keep settings did not carry --keep-settings"
        )

        // 3. A new cluster in the test folder, served by the new instance.
        XCTAssertTrue(
            waitUntil(timeout: 90) { self.postgresIsServing(from: newPID) && (try? self.clusterIdentity()) != firstCluster },
            "no new cluster served by the relaunched instance"
        )
        if let created = try? clusterIdentity().created {
            XCTAssertGreaterThan(created, clickedAt.addingTimeInterval(-1), "PG_VERSION predates the reset")
        }

        // 4. It keeps serving once the old instance is gone (its quit path stops Postgres by pid file).
        if oldExited {
            XCTAssertTrue(
                holds(for: 10) { self.postgresIsServing(from: newPID) },
                "the relaunched instance's Postgres did not survive the old instance's quit"
            )
        }
        XCTAssertEqual(Self.runningGarageInstances().map(\.processIdentifier), [newPID], "more than one Garage is running")

        // 5. The second half of the reset ran and said so.
        guard oldExited else { return }
        // Attach by the relaunched process's own bundle, not the bundle identifier: several copies of
        // Garage are usually registered with LaunchServices, and the identifier can resolve to one that
        // is not running.
        let bundleURL = try XCTUnwrap(NSRunningApplication(processIdentifier: newPID)?.bundleURL, "no bundle for pid \(newPID)")
        let relaunched = XCUIApplication(url: bundleURL)
        relaunched.activate()
        XCTAssertFalse(relaunched.buttons["splash.continue"].waitForExistence(timeout: 3), "the relaunched instance showed the splash")
        if startingOver {
            try finishThroughTheAssistant(relaunched)
        }
        let databaseRow = relaunched.descendants(matching: .any).matching(identifier: "sidebar.database").firstMatch
        XCTAssertTrue(databaseRow.waitForExistence(timeout: 30), "no sidebar on the relaunched instance")
        if !startingOver {
            XCTAssertFalse(
                relaunched.descendants(matching: .any).matching(identifier: "firstRun.skipSetup").firstMatch.exists,
                "a reset that kept the settings opened the setup assistant"
            )
        }
        databaseRow.click()
        // No garage.json in the test folder, so no sources come back, and the message says so.
        // By identifier: the message is selectable text, which accessibility need not report as a
        // static text.
        let message = relaunched.descendants(matching: .any).matching(identifier: "database.resetOutcome").firstMatch
        // The second half of the reset starts only once the assistant is skipped, or at launch when the
        // settings were kept: the cluster, the schema, then the gRPC and MCP services, and only then the
        // report. On a Mac running the whole suite that is longer than the 30 s this once allowed. So the
        // page must first say the reset is under way (or be done), and the report then gets as long as
        // the services got on the first launch.
        let progress = relaunched.descendants(matching: .any).matching(identifier: "database.resetProgress").firstMatch
        XCTAssertTrue(
            waitUntil(timeout: 30) { progress.exists || message.exists },
            "the Database page shows neither the reset in progress nor its outcome"
        )
        XCTAssertTrue(
            waitUntil(timeout: 120) { message.exists && self.shownText(of: message).hasPrefix("Database reset: a new") },
            "finishDatabaseReset did not report a new database (\(message.exists ? self.shownText(of: message) : "no message"))"
        )
        XCTAssertTrue(shownText(of: message).contains("declares no sources"), "the message does not say that no sources came back")
    }

    private func finishThroughTheAssistant(_ relaunched: XCUIApplication) throws {
        // The relaunch opens the setup assistant, whose first page runs `finishDatabaseReset`; skipping it
        // (disabled while that page is working) lands on the main window with the reset finished.
        // A link-styled button, which accessibility reports as a link rather than a button.
        let skip = relaunched.descendants(matching: .any).matching(identifier: "firstRun.skipSetup").firstMatch
        XCTAssertTrue(skip.waitForExistence(timeout: 30), "the relaunched instance did not open the setup assistant")
        // The assistant's own size (MainWindowSizing.assistantSize), whatever frame the relaunch restored.
        let window = relaunched.windows.firstMatch
        XCTAssertTrue(
            waitUntil(timeout: 5) { abs(window.frame.width - 920) < 2 && window.frame.height >= 648 },
            "the relaunched assistant window is \(window.frame.size), not the assistant's 920×650"
        )
        XCTAssertTrue(waitUntil(timeout: 60) { skip.isEnabled }, "Skip setup stayed disabled")
        skip.click()
    }
}

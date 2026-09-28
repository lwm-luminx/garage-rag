import XCTest

/// What a person sees when Garage opens: the splash, and the setup assistant on an unfinished setup.
final class LaunchUITests: GarageUITestCase {

    func testSplashShowsAtLaunchAndContinueOpensTheMainWindow() throws {
        try launchApp(showSplash: true)

        let continueButton = app.buttons["splash.continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 20), "the splash did not show at launch")
        XCTAssertTrue(element(identifier: "splash.version").exists, "the splash does not show the version")
        XCTAssertTrue(element(identifier: "splash.acknowledgements").exists, "the splash has no acknowledgements link")
        XCTAssertTrue(element(identifier: "splash.showAtLaunch").exists, "the splash has no show-at-launch toggle")
        // Sparkle prompts for updates itself; the splash no longer carries an update card.
        XCTAssertFalse(element(text: "Stay up to date").exists, "the splash still shows the update card")

        continueButton.click()
        XCTAssertTrue(
            waitUntil(timeout: 10) { !continueButton.exists },
            "Continue did not close the splash"
        )
        XCTAssertTrue(element(identifier: "sidebar.status").waitForExistence(timeout: 10), "no main window after the splash")
    }

    func testSetupAssistantShowsWhenSetupIsIncomplete() throws {
        try launchApp(firstRunCompleted: false)

        XCTAssertTrue(element(identifier: "firstRun.root").waitForExistence(timeout: 20), "the setup assistant did not open")
        // A link-styled button, which accessibility reports as a link rather than a button.
        XCTAssertTrue(element(identifier: "firstRun.skipSetup").exists, "the setup assistant offers no way to skip it")
        XCTAssertFalse(element(identifier: "sidebar.status").exists, "the sidebar showed alongside the setup assistant")
        let window = app.windows.firstMatch
        XCTAssertTrue(
            waitUntil(timeout: 5) { abs(window.frame.width - 920) < 2 && window.frame.height >= 648 },
            "the setup assistant opened at \(window.frame.size), not its 920×650"
        )
        // SetupAssistantUITests walks it to Finish and skips it.
    }

    /// The data page at the assistant's size: the locations lay out in three columns and the footer is
    /// inside the window, not clipped off the bottom.
    func testSetupAssistantDataPageFitsItsWindow() throws {
        try launchApp(firstRunCompleted: false)
        XCTAssertTrue(element(identifier: "firstRun.root").waitForExistence(timeout: 20), "the setup assistant did not open")

        // The first page moves on by itself once the database and services are up.
        let cards = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'firstRun.source.' AND NOT (identifier BEGINSWITH 'firstRun.source.remove.')")
        )
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 120), "the data page never showed its locations")

        let columns = Set(cards.allElementsBoundByIndex.map { Int($0.frame.minX.rounded()) })
        XCTAssertGreaterThanOrEqual(columns.count, 3, "the locations lay out in \(columns.count) column(s), not three")

        let window = app.windows.firstMatch.frame
        let skip = element(identifier: "firstRun.skipSetup").frame
        XCTAssertTrue(window.contains(skip), "the footer (Skip setup at \(skip)) is outside the window \(window)")
    }
}

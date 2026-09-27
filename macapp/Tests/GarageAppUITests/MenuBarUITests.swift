import XCTest

/// The menu bar item's popover: its services and corpus summary, and the pages it opens in the
/// main window. Quick search is only handed on to the Search page here; results need a model.
final class MenuBarUITests: GarageUITestCase {

    /// With the database and the MCP server up, the services row folds into "All systems go", and
    /// the activity line says there is nothing to index yet, with Ingest Now off.
    func testPopoverSummarizesAnEmptyCorpus() throws {
        try launchApp()
        waitForBackend()
        openPopover()

        let allGo = element(identifier: "menubar.allSystemsGo")
        XCTAssertTrue(allGo.waitForExistence(timeout: 60), "the popover never said all systems go")
        // The row combines its title and detail into one label: "All systems go, Database and MCP running · …".
        XCTAssertTrue(shownText(of: allGo).hasPrefix("All systems go"), "the services row reads \"\(shownText(of: allGo))\"")
        XCTAssertFalse(element(identifier: "menubar.problem").exists, "the popover lists a problem beside all systems go")

        let status = element(identifier: "menubar.status")
        XCTAssertTrue(status.waitForExistence(timeout: 10), "the popover has no activity line")
        XCTAssertTrue(shownText(of: status).contains("No sources yet"), "the activity line is \"\(shownText(of: status))\"")
        let ingest = element(identifier: "menubar.ingest")
        XCTAssertTrue(ingest.exists, "an idle popover offers no Ingest Now")
        XCTAssertFalse(ingest.isEnabled, "Ingest Now is enabled with no sources")
        XCTAssertTrue(element(identifier: "menubar.search.field").exists, "the popover has no search field")
        XCTAssertTrue(element(identifier: "menubar.openGarage").exists, "the popover has no Open Garage button")
    }

    /// After an ingest the activity line counts the corpus.
    func testPopoverCountsTheIngestedCorpus() throws {
        try launchApp()
        waitForBackend()
        try ingestFixtureCorpus()

        openPopover()
        let status = element(identifier: "menubar.status")
        let expected = "\(FixtureCorpus.indexedWithoutCode.count) documents in 1 source"
        XCTAssertTrue(
            waitUntil(timeout: 30) { status.exists && self.shownText(of: status).contains(expected) },
            "the activity line does not say \"\(expected)\" (\(status.exists ? shownText(of: status) : "missing"))"
        )
        XCTAssertTrue(waitForEnabled(element(identifier: "menubar.ingest")), "Ingest Now stayed disabled with a source")
    }

    /// The services row opens the Status page, whichever page the window was on.
    func testServicesRowOpensStatus() throws {
        try launchApp()
        waitForBackend()
        open(section: "logs")
        XCTAssertTrue(element(text: "Log Source").waitForExistence(timeout: 15), "Logs did not open")

        openPopover()
        let row = element(identifier: "menubar.allSystemsGo")
        XCTAssertTrue(row.waitForExistence(timeout: 60), "the popover never said all systems go")
        row.click()
        XCTAssertTrue(element(text: "Helper Services").waitForExistence(timeout: 15), "the services row did not open Status")
        XCTAssertFalse(element(text: "Log Source").exists, "the window stayed on Logs")
    }

    /// Return in the popover's search field opens the Search page with the query in its field.
    func testQuickSearchHandsTheQueryToTheSearchPage() throws {
        try launchApp()
        waitForBackend()
        open(section: "status")

        openPopover()
        let field = element(identifier: "menubar.search.field")
        XCTAssertTrue(waitForEnabled(field), "the popover's search field stayed disabled with the database up")
        // The popover puts the cursor in the field as it opens; click it anyway in case it did not.
        field.click()
        field.typeText(FixtureCorpus.quillonBridge.token + "\n")

        let query = element(identifier: "search.query")
        XCTAssertTrue(query.waitForExistence(timeout: 15), "Return did not open the Search page")
        XCTAssertTrue(
            waitUntil(timeout: 10) { (query.value as? String) == FixtureCorpus.quillonBridge.token },
            "the Search page's field holds \"\(query.value ?? "nil")\", not the popover's query"
        )
    }
}

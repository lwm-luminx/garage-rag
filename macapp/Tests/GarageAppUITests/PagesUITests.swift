import XCTest

/// The Status, Models, Search, MCP Server and Logs pages on a new, empty corpus, and the bug
/// reporter reached from the window and from Logs.
final class PagesUITests: GarageUITestCase {

    func testStatusShowsOverviewAndServiceControls() throws {
        try launchApp()
        waitForBackend()
        open(section: "status")

        for heading in ["Health", "Library", "Index Manager", "Helper Services"] {
            XCTAssertTrue(element(text: heading).waitForExistence(timeout: 15), "Status does not show \"\(heading)\"")
        }
        XCTAssertTrue(element(text: "Nothing to index yet").waitForExistence(timeout: 30), "a new corpus does not say there is nothing to index")
        XCTAssertTrue(element(identifier: "status.addSource").exists, "an empty corpus does not offer Add a Source")
        XCTAssertTrue(element(text: "No sources yet").exists, "Health does not list the missing sources")

        // Each XPC helper row offers Test and Restart; the separate Ping button is gone.
        XCTAssertTrue(element(identifier: "status.service.ingest-xpc.restart").waitForExistence(timeout: 30), "no XPC service row with Restart")
        XCTAssertTrue(element(identifier: "status.service.ingest-xpc.test").exists, "no XPC service row with Test")
        XCTAssertTrue(element(identifier: "status.service.grpc.test").exists, "no gRPC row with Test")
        XCTAssertFalse(button(label: "Ping").exists, "the Status page still has a Ping button")
        for retired in ["Run All Tests", "Query Services", "Expand All"] {
            XCTAssertFalse(button(label: retired).exists, "the retired \"\(retired)\" button is back")
        }
    }

    func testModelsToolbarOnAnEmptyRegistry() throws {
        try launchApp()
        waitForBackend()
        open(section: "models")

        let refresh = element(identifier: "models.refresh")
        XCTAssertTrue(refresh.waitForExistence(timeout: 15), "no models refresh button")
        XCTAssertTrue(waitForEnabled(refresh), "the models refresh button stayed disabled")
        refresh.click()

        let embedAll = element(identifier: "models.embedAll")
        XCTAssertTrue(embedAll.exists, "no Embed All button")
        XCTAssertFalse(embedAll.isEnabled, "Embed All is enabled with no registered models")
        // ("Refresh" stays: the Llama section's status refresh still uses it.)
        for retired in ["Backfill All (*)", "Backfill", "Verify All SHA-256"] {
            XCTAssertFalse(button(label: retired).exists, "the retired \"\(retired)\" button is back")
        }
    }

    /// Hybrid search needs an embedding model; on a new install none is registered, and the page
    /// says so instead of failing without a reason.
    func testSearchWithoutAModelSaysToRegisterOne() throws {
        try launchApp()
        waitForBackend()
        open(section: "search")

        let query = element(identifier: "search.query")
        XCTAssertTrue(query.waitForExistence(timeout: 15), "no search field")
        // The plain-style field only takes focus when the click lands on its text area.
        query.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).click()
        app.typeText("system architecture\n")
        XCTAssertTrue(element(text: "Search Failed").waitForExistence(timeout: 60), "a search with no registered model did not report a failure")
        XCTAssertTrue(element(textContaining: "register").exists, "the failure does not say to register a model")
        XCTAssertTrue(button(label: "Retry").exists, "the failure offers no Retry")
    }

    func testMCPServerPageShowsStatusAndControls() throws {
        try launchApp()
        waitForBackend()
        open(section: "mcp")

        for heading in ["Server", "Connected Assistants", "Try It"] {
            XCTAssertTrue(element(text: heading).waitForExistence(timeout: 15), "MCP Server does not show \"\(heading)\"")
        }
        XCTAssertTrue(element(identifier: "mcp.copyEndpoint").exists, "MCP Server does not offer to copy its address")

        // The server row offers Start while stopped, and Test, Restart and Stop while it runs; the app
        // starts the server once the database is up.
        let stop = element(identifier: "mcp.stop")
        XCTAssertTrue(
            waitUntil(timeout: 60) { stop.exists || element(identifier: "mcp.start").exists },
            "the server row offers neither Start nor Stop"
        )
        if stop.exists {
            XCTAssertTrue(element(identifier: "mcp.restart").exists, "a running server has no Restart")
            XCTAssertTrue(element(identifier: "mcp.test").exists, "a running server has no Test")
            XCTAssertFalse(element(identifier: "mcp.start").exists, "a running server still offers Start")
        }

        XCTAssertTrue(element(identifier: "mcp.connectAll").exists, "no Connect All")
        XCTAssertTrue(element(identifier: "mcp.try.run").exists, "Try It has no Run")
        for retired in ["Execute Tool", "Register All Found Configs", "Test MCP Server", "Check MCP Status"] {
            XCTAssertFalse(button(label: retired).exists, "the retired \"\(retired)\" button is back")
        }
    }

    func testLogsReportBugOpensAndCancelsTheBugReporter() throws {
        try launchApp()
        open(section: "logs")

        XCTAssertTrue(element(text: "Log Source").waitForExistence(timeout: 15), "Logs has no source picker")
        let reportBug = element(identifier: "logs.reportBug")
        XCTAssertTrue(reportBug.waitForExistence(timeout: 10), "Logs has no Report Bug button")
        reportBug.click()
        assertBugReporterOpensAndCancels()
    }

    func testBugNubOpensTheBugReporter() throws {
        try launchApp()
        let nub = element(identifier: "bugNub")
        XCTAssertTrue(nub.waitForExistence(timeout: 15), "the window has no bug nub")
        nub.click()
        assertBugReporterOpensAndCancels()
    }

    private func assertBugReporterOpensAndCancels(file: StaticString = #filePath, line: UInt = #line) {
        let title = element(identifier: "bugReport.title")
        XCTAssertTrue(title.waitForExistence(timeout: 10), "the bug reporter did not open", file: file, line: line)
        // The preview sits in a collapsed disclosure group, so only the always-visible controls are checked.
        XCTAssertTrue(element(identifier: "bugReport.includeLogs").exists, "the bug reporter has no include-logs option", file: file, line: line)
        XCTAssertTrue(element(identifier: "bugReport.save").exists, "the bug reporter cannot save a report", file: file, line: line)
        XCTAssertTrue(element(identifier: "bugReport.openIssue").exists, "the bug reporter cannot open an issue", file: file, line: line)

        let cancel = button(label: "Cancel")
        XCTAssertTrue(cancel.exists, "the bug reporter has no Cancel", file: file, line: line)
        cancel.click()
        XCTAssertTrue(waitUntil(timeout: 10) { !title.exists }, "Cancel did not close the bug reporter", file: file, line: line)
    }
}

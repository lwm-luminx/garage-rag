import XCTest

/// The MCP Server page beyond its headings (PagesUITests): the server's details, stopping and
/// starting it, and the assistants list. No assistant is connected: Connect writes the assistant's
/// real configuration file, so those buttons are only looked at.
final class MCPServerUITests: GarageUITestCase {

    func testDetailsShowTheServersSettings() throws {
        try launchApp()
        waitForBackend()
        open(section: "mcp")

        let toggle = element(identifier: "mcp.details.toggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 15), "the Server box has no Details button")
        XCTAssertFalse(element(identifier: "mcp.port").exists, "the details are open before anyone asked for them")

        click(toggle)
        let port = element(identifier: "mcp.port")
        XCTAssertTrue(port.waitForExistence(timeout: 10), "Details did not show the port")
        for label in ["Port", "Path", "Transport"] {
            XCTAssertTrue(element(text: label).exists, "the details do not show \"\(label)\"")
        }
        XCTAssertFalse(((port.value as? String) ?? "").isEmpty, "the port field is empty")

        click(toggle)
        XCTAssertTrue(waitUntil(timeout: 10) { !port.exists }, "Details did not fold away")
    }

    /// The app starts the server once the database is up; Stop offers Start and nothing else, and
    /// Start brings back Test, Restart and Stop.
    func testStopAndStartTheServer() throws {
        try launchApp()
        waitForBackend()
        open(section: "mcp")

        let stop = element(identifier: "mcp.stop")
        let start = element(identifier: "mcp.start")
        XCTAssertTrue(waitForEnabled(stop, timeout: 60), "the server did not come up with the database")
        click(stop)

        XCTAssertTrue(start.waitForExistence(timeout: 30), "a stopped server does not offer Start")
        for running in ["mcp.stop", "mcp.restart", "mcp.test"] {
            XCTAssertFalse(element(identifier: running).exists, "a stopped server still offers \(running)")
        }

        XCTAssertTrue(waitForEnabled(start), "Start stayed disabled")
        click(start)
        XCTAssertTrue(waitForEnabled(stop, timeout: 60), "Start did not bring the server back")
        XCTAssertTrue(element(identifier: "mcp.restart").exists, "a running server has no Restart")
        XCTAssertTrue(element(identifier: "mcp.test").exists, "a running server has no Test")
        XCTAssertFalse(start.exists, "a running server still offers Start")
    }

    /// Every assistant Garage knows about is a row, found on this Mac or folded under "Not found on
    /// this Mac"; which is which depends on the machine, so the test reaches both.
    func testAssistantsListEveryKnownClient() throws {
        try launchApp()
        waitForBackend()
        open(section: "mcp")

        XCTAssertTrue(element(identifier: "mcp.rescan").waitForExistence(timeout: 15), "no Look for Assistants Again button")
        XCTAssertTrue(element(identifier: "mcp.assistants.more").exists, "no More menu")
        XCTAssertTrue(element(identifier: "mcp.agentPrivacy").exists, "the page does not say what an assistant receives")

        let missing = element(identifier: "mcp.missingClients.toggle")
        if missing.exists {
            click(missing)
        }
        let rows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND NOT identifier ENDSWITH %@", "mcp.client.", ".connect")
        )
        // (Whether a row offers Connect depends on what this Mac's assistants already point at.)
        XCTAssertTrue(waitUntil(timeout: 10) { rows.count > 0 }, "no assistant rows")

        click(element(identifier: "mcp.rescan"))
        XCTAssertTrue(waitUntil(timeout: 10) { rows.count > 0 }, "looking again emptied the list")
    }
}

import XCTest

/// MCP over stdio, the default since the HTTP server became opt-in: the app opens no MCP port,
/// assistants start `garage-mcp` themselves, and nothing about that reads as a problem. Every test
/// launches with HTTP off. None clicks Start: starting the server saves HTTP on in the real
/// preferences, which the argument domain only overrides for a test's own launch.
final class MCPStdioUITests: GarageUITestCase {

    /// The MCP page says HTTP is off, offers Start and nothing that needs a running server, and no
    /// port is open.
    func testMCPPageSaysHTTPIsOff() throws {
        try launchApp(mcpHTTP: false)
        waitForBackend()
        open(section: "mcp")

        XCTAssertTrue(element(text: "HTTP off").waitForExistence(timeout: 30), "the MCP page does not say HTTP is off")
        XCTAssertTrue(
            element(textContaining: "over stdio; no port is open").exists,
            "the headline does not explain that assistants use stdio"
        )
        XCTAssertTrue(element(identifier: "mcp.start").waitForExistence(timeout: 15), "an HTTP-off page offers no Start")
        for running in ["mcp.stop", "mcp.restart", "mcp.test"] {
            XCTAssertFalse(element(identifier: running).exists, "an HTTP-off page offers \(running)")
        }
        XCTAssertTrue(element(identifier: "mcp.rescan").exists, "the assistants list is missing with HTTP off")
        XCTAssertTrue(
            holds(for: 5) { !Self.isListening(on: UInt16(8787)) },
            "something listens on the MCP port with HTTP off"
        )
    }

    /// The popover's services row is all go over stdio, and the field searches without offering Ask
    /// Garage, which needs the HTTP server.
    func testPopoverIsAllGoOverStdioWithoutAsk() throws {
        try launchApp(mcpHTTP: false)
        waitForBackend()
        openPopover()

        let allGo = element(identifier: "menubar.allSystemsGo")
        XCTAssertTrue(allGo.waitForExistence(timeout: 60), "the popover never said all systems go over stdio")
        // "All systems go, Database running · no assistants connected" (the count depends on this Mac).
        XCTAssertTrue(shownText(of: allGo).contains("Database running"), "the services row reads \"\(shownText(of: allGo))\"")
        XCTAssertFalse(shownText(of: allGo).contains("MCP running"), "the services row claims an MCP server over stdio")
        XCTAssertFalse(element(identifier: "menubar.problem").exists, "HTTP off reads as a problem")

        let field = element(identifier: "menubar.search.field")
        XCTAssertTrue(waitForEnabled(field), "the popover's search field stayed disabled with the database up")
        XCTAssertEqual(field.placeholderValue, "Search your corpus", "the field offers to ask with no MCP server")
        typeInPopoverField("lanterns")
        XCTAssertTrue(
            holds(for: 3) { !self.element(identifier: "menubar.ask").exists },
            "the popover offers Ask Garage with HTTP off"
        )
    }

    /// Status's Health does not list the stopped HTTP server as a problem.
    func testHealthDoesNotFlagTheStoppedServer() throws {
        try launchApp(mcpHTTP: false)
        waitForBackend()
        open(section: "status")

        // The missing sources show once Health has read the services, so the list is settled.
        XCTAssertTrue(element(identifier: "status.health.sources").waitForExistence(timeout: 60), "Health never listed the missing sources")
        XCTAssertTrue(
            holds(for: 5) { !self.element(identifier: "status.health.mcp").exists },
            "Health lists the MCP server with HTTP off"
        )
    }

    /// The setup assistant's agent page has no server card with HTTP off; assistants are still listed.
    func testSetupAgentPageHasNoServerCard() throws {
        try launchApp(firstRunCompleted: false, mcpHTTP: false)
        XCTAssertTrue(element(identifier: "firstRun.root").waitForExistence(timeout: 20), "the setup assistant did not open")
        // The services page lists no MCP server to wait for; it moves on by itself, so look while it shows.
        if element(identifier: "firstRun.check.postgres").exists {
            XCTAssertFalse(element(identifier: "firstRun.check.mcp").exists, "the assistant waits for an MCP server with HTTP off")
        }

        let decideLater = element(identifier: "firstRun.decideLater")
        XCTAssertTrue(decideLater.waitForExistence(timeout: 120), "the assistant never reached the data page")
        click(decideLater)
        XCTAssertTrue(element(identifier: "firstRun.downloadModels").waitForExistence(timeout: 30), "the assistant did not move on to the models page")
        click(element(identifier: "firstRun.decideLater"))

        XCTAssertTrue(element(identifier: "firstRun.finish").waitForExistence(timeout: 30), "the assistant did not move on to the agent page")
        XCTAssertTrue(element(identifier: "firstRun.registerClients").exists, "the agent page has no Connect button")
        XCTAssertFalse(element(identifier: "firstRun.mcpServer").exists, "the agent page shows a server card with HTTP off")
    }
}

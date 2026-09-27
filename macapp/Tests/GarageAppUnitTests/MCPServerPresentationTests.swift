import XCTest
@testable import GarageApp

@MainActor
final class MCPServerPresentationTests: XCTestCase {
    private let endpoint = URL(string: "http://127.0.0.1:8787/mcp")!

    private func client(
        _ id: String = "claude-desktop",
        exists: Bool = true,
        registered: Bool = false,
        url: String? = nil
    ) -> MCPClientConfig {
        MCPClientConfig(
            id: id,
            label: id,
            path: URL(fileURLWithPath: "/tmp/\(id).json"),
            existsOnDisk: exists,
            isRegistered: registered,
            registeredURL: url
        )
    }

    // MARK: - Server headline

    func testRunningServerThatAnsweredCountsItsTools() {
        let test = MCPTestResult(isSuccess: true, tools: [MCPToolInfo(name: "rag_search", description: ""), MCPToolInfo(name: "rag_stats", description: "")])
        let headline = MCPServerHeadline(status: .running, test: test, isTesting: false, isDatabaseRunning: true, connectedCount: 1)
        XCTAssertEqual(headline.title, "Running")
        XCTAssertEqual(headline.detail, "Answering on this Mac only · 2 tools")
        XCTAssertEqual(headline.tint, .green)
        XCTAssertFalse(headline.detailIsError)
    }

    func testRunningServerThatFailedItsCheckSaysSo() {
        let test = MCPTestResult(isSuccess: false, errorMessage: "connection refused")
        let headline = MCPServerHeadline(status: .running, test: test, isTesting: false, isDatabaseRunning: true, connectedCount: 0)
        XCTAssertEqual(headline.title, "Running, but not answering")
        XCTAssertEqual(headline.detail, "connection refused")
        XCTAssertTrue(headline.detailIsError)
    }

    func testCheckInFlightWinsOverAnOldResult() {
        let test = MCPTestResult(isSuccess: false, errorMessage: "old")
        let headline = MCPServerHeadline(status: .running, test: test, isTesting: true, isDatabaseRunning: true, connectedCount: 0)
        XCTAssertEqual(headline.detail, "Checking that it answers…")
    }

    func testStoppedServerNamesTheAssistantsItStrands() {
        let headline = MCPServerHeadline(status: .stopped, test: nil, isTesting: false, isDatabaseRunning: false, connectedCount: 2)
        XCTAssertEqual(headline.title, "Stopped")
        XCTAssertEqual(headline.detail, "2 connected assistants can't reach Garage until it runs. Starting it also starts the database.")
        XCTAssertFalse(headline.isActive)
    }

    func testStoppedServerIgnoresAnEarlierCheck() {
        let test = MCPTestResult(isSuccess: true, tools: [MCPToolInfo(name: "rag_search", description: "")])
        let headline = MCPServerHeadline(status: .stopped, test: test, isTesting: false, isDatabaseRunning: true, connectedCount: 0)
        XCTAssertEqual(headline.detail, "Assistants reach Garage through this server once they're connected.")
    }

    func testStoppedServerWithHTTPOffIsTheNormalStdioState() {
        let headline = MCPServerHeadline(status: .stopped, test: nil, isTesting: false, isDatabaseRunning: true, connectedCount: 2, httpEnabled: false)
        XCTAssertEqual(headline.title, "HTTP off")
        XCTAssertEqual(headline.symbol, "terminal")
        XCTAssertTrue(headline.isActive)
        XCTAssertFalse(headline.detailIsError)
        XCTAssertFalse(MCPServerHeadline(status: .stopped, test: nil, isTesting: false, isDatabaseRunning: true, connectedCount: 0, httpEnabled: false).isActive)
    }

    func testFailedServerShowsItsError() {
        let headline = MCPServerHeadline(status: .failed("port in use"), test: nil, isTesting: false, isDatabaseRunning: true, connectedCount: 0)
        XCTAssertEqual(headline.title, "Couldn't start")
        XCTAssertEqual(headline.detail, "port in use")
        XCTAssertTrue(headline.detailIsError)
    }

    // MARK: - Assistant rows

    func testRegisteredAtThisAddressIsConnected() {
        let row = MCPClientRowPresentation(client: client(registered: true, url: "http://127.0.0.1:8787/mcp/"), endpoint: endpoint)
        XCTAssertEqual(row.state, .connected)
        XCTAssertEqual(row.status, "Connected")
        XCTAssertNil(row.actionTitle)
    }

    func testStdioEntryWithoutAURLIsConnected() {
        let row = MCPClientRowPresentation(client: client(registered: true, url: nil), endpoint: endpoint)
        XCTAssertEqual(row.state, .connected)
    }

    func testHTTPEntryNeedsUpdatingWhenHTTPIsOff() {
        let row = MCPClientRowPresentation(client: client(registered: true, url: "http://127.0.0.1:8787/mcp"), endpoint: nil)
        XCTAssertEqual(row.state, .outdated(registeredURL: "http://127.0.0.1:8787/mcp"))
        XCTAssertEqual(row.actionTitle, "Update")
        XCTAssertEqual(row.status, "Points at http://127.0.0.1:8787/mcp, but the HTTP server is off")
    }

    func testStdioEntryIsConnectedWhenHTTPIsOff() {
        let row = MCPClientRowPresentation(client: client(registered: true, url: nil), endpoint: nil)
        XCTAssertEqual(row.state, .connected)
        XCTAssertNil(row.actionTitle)
    }

    func testRegisteredAtAnOldPortNeedsUpdating() {
        let row = MCPClientRowPresentation(client: client(registered: true, url: "http://127.0.0.1:9000/mcp"), endpoint: endpoint)
        XCTAssertEqual(row.state, .outdated(registeredURL: "http://127.0.0.1:9000/mcp"))
        XCTAssertTrue(row.isOutdated)
        XCTAssertEqual(row.actionTitle, "Update")
        XCTAssertEqual(row.status, "Points at http://127.0.0.1:9000/mcp, not http://127.0.0.1:8787/mcp")
    }

    func testInstalledButUnregisteredOffersConnect() {
        let row = MCPClientRowPresentation(client: client(exists: true), endpoint: endpoint)
        XCTAssertEqual(row.state, .notConnected)
        XCTAssertEqual(row.status, "Installed, not connected")
        XCTAssertEqual(row.actionTitle, "Connect")
    }

    func testMissingConfigIsNotInstalled() {
        let row = MCPClientRowPresentation(client: client(exists: false), endpoint: endpoint)
        XCTAssertEqual(row.state, .notInstalled)
        XCTAssertEqual(row.status, "Not found on this Mac")
    }

    func testEachKnownClientHasItsOwnSymbol() {
        XCTAssertEqual(MCPClientRowPresentation.symbol(for: "claude-code-user"), "terminal")
        XCTAssertEqual(MCPClientRowPresentation.symbol(for: "cursor"), "cursorarrow.rays")
        XCTAssertEqual(MCPClientRowPresentation.symbol(for: "something-new"), "puzzlepiece.extension")
    }

    // MARK: - Summary

    private func rows(_ clients: [MCPClientConfig]) -> [MCPClientRowPresentation] {
        clients.map { MCPClientRowPresentation(client: $0, endpoint: endpoint) }
    }

    func testSummaryWithNothingInstalled() {
        let list = rows([client("a", exists: false), client("b", exists: false)])
        XCTAssertEqual(MCPPagePresentation.clientSummary(list), "No assistants found on this Mac")
        XCTAssertFalse(MCPPagePresentation.canConnectAll(list))
    }

    func testSummaryWithNoneConnected() {
        let list = rows([client("a"), client("b"), client("c", exists: false)])
        XCTAssertEqual(MCPPagePresentation.clientSummary(list), "None of 2 installed assistants connected yet")
        XCTAssertTrue(MCPPagePresentation.canConnectAll(list))
    }

    func testSummaryWithSomeConnectedAndOneOutdated() {
        let list = rows([
            client("a", registered: true),
            client("b", registered: true, url: "http://127.0.0.1:1/mcp"),
            client("c"),
        ])
        XCTAssertEqual(MCPPagePresentation.clientSummary(list), "1 of 3 installed assistants connected · 1 needs updating")
        XCTAssertTrue(MCPPagePresentation.canConnectAll(list))
    }

    func testSummaryWithEveryInstalledAssistantConnected() {
        let list = rows([client("a", registered: true), client("b", registered: true), client("c", exists: false)])
        XCTAssertEqual(MCPPagePresentation.clientSummary(list), "All 2 installed assistants are connected")
        XCTAssertFalse(MCPPagePresentation.canConnectAll(list))
    }

    func testSummaryWithTheOnlyAssistantConnected() {
        let list = rows([client("a", registered: true)])
        XCTAssertEqual(MCPPagePresentation.clientSummary(list), "Your assistant is connected")
    }
}

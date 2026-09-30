import XCTest
@testable import GarageApp

final class AppSectionTests: XCTestCase {

    func testAppSectionAllCasesCount() {
        XCTAssertEqual(AppSection.allCases.count, 10)
    }

    func testAppSectionIdentifiers() {
        XCTAssertEqual(AppSection.status.id, "Status")
        XCTAssertEqual(AppSection.database.id, "Database")
        XCTAssertEqual(AppSection.sources.id, "Sources")
        XCTAssertEqual(AppSection.documents.id, "Documents")
        XCTAssertEqual(AppSection.facts.id, "Facts")
        XCTAssertEqual(AppSection.graph.id, "Graph")
        XCTAssertEqual(AppSection.models.id, "Models")
        XCTAssertEqual(AppSection.mcp.id, "MCP Server")
        XCTAssertEqual(AppSection.search.id, "Search")
        XCTAssertEqual(AppSection.logs.id, "Logs")
    }

    func testAppSectionSymbols() {
        XCTAssertEqual(AppSection.status.symbol, "gauge.with.dots.needle.50percent")
        XCTAssertEqual(AppSection.database.symbol, "cylinder.split.1x2")
        XCTAssertEqual(AppSection.sources.symbol, "tray.and.arrow.down")
        XCTAssertEqual(AppSection.documents.symbol, "doc.text.magnifyingglass")
        XCTAssertEqual(AppSection.facts.symbol, "lightbulb")
        XCTAssertEqual(AppSection.graph.symbol, "point.3.connected.trianglepath.dotted")
        XCTAssertEqual(AppSection.models.symbol, "cpu")
        XCTAssertEqual(AppSection.mcp.symbol, "server.rack")
        XCTAssertEqual(AppSection.search.symbol, "magnifyingglass")
        XCTAssertEqual(AppSection.logs.symbol, "terminal")
    }

    func testSidebarGroups() {
        XCTAssertEqual(SidebarGroup.configuration.sections, [.sources, .models, .mcp])
        XCTAssertEqual(SidebarGroup.data.sections, [.documents, .facts, .graph, .search])
        XCTAssertEqual(SidebarGroup.advanced.sections, [.database, .logs])
        XCTAssertNil(AppSection.status.group)
    }

    /// Every page is in the sidebar exactly once, and `allCases` follows the sidebar's order.
    func testSidebarListsEveryPageOnceInOrder() {
        let sidebar = [AppSection.status] + SidebarGroup.allCases.flatMap(\.sections)
        XCTAssertEqual(sidebar, AppSection.allCases)
    }
}

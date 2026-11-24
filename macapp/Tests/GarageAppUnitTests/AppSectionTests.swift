import XCTest
@testable import GarageApp

final class AppSectionTests: XCTestCase {

    func testAppSectionAllCasesCount() {
        XCTAssertEqual(AppSection.allCases.count, 13)
    }

    func testAppSectionIdentifiers() {
        XCTAssertEqual(AppSection.status.id, "Status")
        XCTAssertEqual(AppSection.chat.id, "Chat")
        XCTAssertEqual(AppSection.database.id, "Database")
        XCTAssertEqual(AppSection.sources.id, "Sources")
        XCTAssertEqual(AppSection.documents.id, "Documents")
        XCTAssertEqual(AppSection.facts.id, "Facts")
        XCTAssertEqual(AppSection.graph.id, "Graph")
        XCTAssertEqual(AppSection.models.id, "Models")
        XCTAssertEqual(AppSection.mcp.id, "MCP Server")
        XCTAssertEqual(AppSection.access.id, "Access")
        XCTAssertEqual(AppSection.search.id, "Search")
        XCTAssertEqual(AppSection.services.id, "Services")
        XCTAssertEqual(AppSection.logs.id, "Logs")
    }

    func testAppSectionSymbols() {
        XCTAssertEqual(AppSection.status.symbol, "gauge.with.dots.needle.50percent")
        XCTAssertEqual(AppSection.chat.symbol, "bubble.left.and.text.bubble.right")
        XCTAssertEqual(AppSection.database.symbol, "cylinder.split.1x2")
        XCTAssertEqual(AppSection.sources.symbol, "tray.and.arrow.down")
        XCTAssertEqual(AppSection.documents.symbol, "doc.text.magnifyingglass")
        XCTAssertEqual(AppSection.facts.symbol, "lightbulb")
        XCTAssertEqual(AppSection.graph.symbol, "point.3.connected.trianglepath.dotted")
        XCTAssertEqual(AppSection.models.symbol, "cpu")
        XCTAssertEqual(AppSection.mcp.symbol, "server.rack")
        XCTAssertEqual(AppSection.access.symbol, "lock.shield")
        XCTAssertEqual(AppSection.search.symbol, "magnifyingglass")
        XCTAssertEqual(AppSection.services.symbol, "gearshape.2")
        XCTAssertEqual(AppSection.logs.symbol, "terminal")
    }

    func testSidebarGroups() {
        XCTAssertEqual(SidebarGroup.configuration.sections, [.sources, .models, .mcp, .access])
        XCTAssertEqual(SidebarGroup.data.sections, [.documents, .facts, .graph, .search])
        XCTAssertEqual(SidebarGroup.advanced.sections, [.database, .services, .logs])
    }

    func testTheGraphPageIsOnlyOfferedWhereTheBuildTurnsItOn() {
        XCTAssertEqual(SidebarGroup.data.sections(showsGraph: false), [.documents, .facts, .search])
        XCTAssertEqual(SidebarGroup.data.sections(showsGraph: true), [.documents, .facts, .graph, .search])
        XCTAssertEqual(SidebarGroup.configuration.sections(showsGraph: false), [.sources, .models, .mcp, .access])
        XCTAssertNil(AppSection.status.group)
        XCTAssertNil(AppSection.chat.group)
    }

    /// Every page is in the sidebar exactly once, and `allCases` follows the sidebar's order.
    func testSidebarListsEveryPageOnceInOrder() {
        XCTAssertEqual(AppSection.leading, [.status, .chat])
        let sidebar = AppSection.leading + SidebarGroup.allCases.flatMap(\.sections)
        XCTAssertEqual(sidebar, AppSection.allCases)
    }
}

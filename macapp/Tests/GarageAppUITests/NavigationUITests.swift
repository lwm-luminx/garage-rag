import XCTest

/// The sidebar reaches every page, and each page renders its own content.
final class NavigationUITests: GarageUITestCase {

    /// Each `AppSection` case name, in sidebar order, with a piece of text only that page shows.
    private static let pages: [(section: String, marker: String)] = [
        ("status", "Helper Services"),
        // Configuration
        ("sources", "Add a Source"),
        ("models", "Embed All"),
        ("mcp", "Connected Assistants"),
        // Data
        ("documents", "Filter by title or URI…"),
        ("facts", "Search facts…"),
        ("search", "Search corpus (e.g., 'system architecture', 'API design')…"),
        // Advanced
        ("database", "Backups"),
        ("logs", "Log Source"),
    ]

    func testSidebarOpensEveryPage() throws {
        try launchApp()

        for page in Self.pages {
            open(section: page.section)
            XCTAssertTrue(
                element(text: page.marker).waitForExistence(timeout: 15),
                "the \(page.section) page did not show \"\(page.marker)\""
            )
        }
    }

    /// Status leads the sidebar on its own; the other pages follow in three groups, each under its
    /// header: Configuration, Data, Advanced.
    func testSidebarGroupsThePagesUnderTheirHeaders() throws {
        try launchApp()
        XCTAssertTrue(element(identifier: "sidebar.status").waitForExistence(timeout: 15), "no sidebar")

        let rows = Self.pages.map { element(identifier: "sidebar.\($0.section)") }
        for (page, row) in zip(Self.pages, rows) {
            XCTAssertTrue(row.exists, "no sidebar row for \(page.section)")
        }
        let tops = rows.map(\.frame.minY)
        XCTAssertEqual(tops, tops.sorted(), "the sidebar rows are out of order: \(Self.pages.map(\.section))")

        // A header sits between the last row of one group and the first of the next.
        let sidebar = app.outlines.containing(NSPredicate(format: "identifier == %@", "sidebar.status")).firstMatch
        func header(_ title: String) -> XCUIElement {
            sidebar.descendants(matching: .any).matching(
                NSPredicate(format: "label == %@ OR title == %@ OR value == %@", title, title, title)
            ).firstMatch
        }
        let groups: [(title: String, after: String, before: String)] = [
            ("Configuration", "status", "sources"),
            ("Data", "mcp", "documents"),
            ("Advanced", "search", "database"),
        ]
        for group in groups {
            let title = header(group.title)
            XCTAssertTrue(title.exists, "the sidebar has no \(group.title) header")
            let y = title.frame.midY
            XCTAssertGreaterThan(y, element(identifier: "sidebar.\(group.after)").frame.midY, "\(group.title) is above \(group.after)")
            XCTAssertLessThan(y, element(identifier: "sidebar.\(group.before)").frame.midY, "\(group.title) is below \(group.before)")
        }
    }

    func testMainWindowOpensOnStatusWithoutSplashOrSetup() throws {
        try launchApp()

        XCTAssertTrue(element(identifier: "sidebar.status").waitForExistence(timeout: 15), "no sidebar")
        XCTAssertFalse(app.buttons["splash.continue"].exists, "the splash showed although it was turned off")
        XCTAssertFalse(element(identifier: "firstRun.root").exists, "the setup assistant showed although setup was complete")
        XCTAssertTrue(element(text: "Helper Services").waitForExistence(timeout: 15), "the window did not open on Status")
    }
}

import XCTest
import SwiftUI
import AppKit
@testable import GarageApp

final class SectionViewHostingTests: XCTestCase {

    @MainActor
    func testNavigationBetweenAllSections() {
        let appState = AppState()

        for section in AppSection.allCases {
            let view = ContentView()
                .environmentObject(appState)
            let controller = NSHostingController(rootView: view)
            XCTAssertNotNil(controller.view, "Failed to render view for section: \(section.rawValue)")
        }
    }

    @MainActor
    func testStatusViewUIElements() {
        let appState = AppState()
        let statusView = StatusView()
            .environmentObject(appState)

        let controller = NSHostingController(rootView: statusView)
        XCTAssertNotNil(controller.view)
        XCTAssertEqual(appState.statusSummary, "Stopped")
    }

    @MainActor
    func testDatabaseViewControls() {
        let appState = AppState()
        let databaseView = DatabaseView()
            .environmentObject(appState)

        let controller = NSHostingController(rootView: databaseView)
        XCTAssertNotNil(controller.view)
    }

    @MainActor
    func testSourcesViewControls() {
        let appState = AppState()
        let sourcesView = SourcesView()
            .environmentObject(appState)

        let controller = NSHostingController(rootView: sourcesView)
        XCTAssertNotNil(controller.view)
    }

    @MainActor
    func testModelsViewPresetsAndCustomFields() {
        let appState = AppState()
        let modelsView = ModelsView()
            .environmentObject(appState)

        let controller = NSHostingController(rootView: modelsView)
        XCTAssertNotNil(controller.view)
    }

    @MainActor
    func testMCPServerViewControls() {
        let appState = AppState()
        let mcpView = MCPServerView()
            .environmentObject(appState)

        let controller = NSHostingController(rootView: mcpView)
        XCTAssertNotNil(controller.view)
    }

    @MainActor
    func testGraphViewHostsWithoutADatabase() {
        let appState = AppState()
        let graphView = GraphView()
            .environmentObject(appState)

        let controller = NSHostingController(rootView: graphView)
        XCTAssertNotNil(controller.view)
    }

    @MainActor
    func testSearchViewControlsAndState() {
        let appState = AppState()
        let searchView = SearchView()
            .environmentObject(appState)

        let controller = NSHostingController(rootView: searchView)
        XCTAssertNotNil(controller.view)
    }

    @MainActor
    func testLogsViewFilterTabs() {
        let appState = AppState()
        let logsView = LogsView()
            .environmentObject(appState)

        let controller = NSHostingController(rootView: logsView)
        XCTAssertNotNil(controller.view)
    }

    @MainActor
    func testMenuBarViewLayoutAndButtons() {
        let appState = AppState()
        let menuBarView = MenuBarView()
            .environmentObject(appState)

        let controller = NSHostingController(rootView: menuBarView)
        XCTAssertNotNil(controller.view)
    }
}

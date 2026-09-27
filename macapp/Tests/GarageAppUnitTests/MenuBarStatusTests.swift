import XCTest
@testable import GarageApp

final class MenuBarStatusTests: XCTestCase {

    // MARK: - Icon

    func testIdleRunningDatabaseShowsAnOpenDoorAtRest() {
        let status = MenuBarStatus(database: .running, mcp: .running(clients: 1))
        XCTAssertEqual(status.symbol, "door.garage.open")
        XCTAssertFalse(status.isPulsing)
        XCTAssertEqual(status.headline, "Ready")
        XCTAssertFalse(status.isBusy)
        XCTAssertFalse(status.needsAttention)
        XCTAssertTrue(status.attentions.isEmpty)
    }

    func testStoppedDatabaseShowsAClosedDoor() {
        let status = MenuBarStatus(database: .stopped)
        XCTAssertEqual(status.symbol, "door.garage.closed")
        XCTAssertFalse(status.isPulsing)
        XCTAssertEqual(status.headline, "Database stopped")
        XCTAssertFalse(status.canSearch)
        XCTAssertFalse(status.canIngest)
    }

    func testStartingDatabasePulsesBehindAClosedDoor() {
        let status = MenuBarStatus(database: .starting)
        XCTAssertEqual(status.symbol, "door.garage.closed")
        XCTAssertTrue(status.isPulsing)
        XCTAssertTrue(status.isDatabaseTransitioning)
    }

    func testWorkPulsesTheOpenDoor() {
        let activities: [MenuBarStatus.Activity] = [
            .scanning(itemsSoFar: nil),
            .ingesting(.init(source: "notes")),
            .embedding,
            .distilling,
        ]
        for activity in activities {
            let status = MenuBarStatus(database: .running, activity: activity)
            XCTAssertEqual(status.symbol, "door.garage.open", "\(activity)")
            XCTAssertTrue(status.isPulsing, "\(activity)")
            XCTAssertTrue(status.isBusy, "\(activity)")
        }
    }

    func testBlockingProblemsSwapTheIconForAWarningAndStopTheMotion() {
        for database in [MenuBarStatus.Database.failed("port in use"), .needsMigration] {
            let status = MenuBarStatus(database: database, activity: .embedding)
            XCTAssertTrue(status.needsAttention, "\(database)")
            XCTAssertEqual(status.symbol, "exclamationmark.triangle", "\(database)")
            XCTAssertFalse(status.isPulsing, "\(database)")
        }
    }

    func testMCPFailureIsAWarningOnlyWhileTheDatabaseRuns() {
        let running = MenuBarStatus(database: .running, mcp: .failed("port 8787 in use"))
        XCTAssertTrue(running.needsAttention)
        XCTAssertEqual(running.attentions, [.mcpFailed("port 8787 in use")])

        // Stopping the database fails MCP as a consequence; that is not a second problem.
        let stopped = MenuBarStatus(database: .stopped, mcp: .failed("Database is not online"))
        XCTAssertFalse(stopped.needsAttention)
        XCTAssertTrue(stopped.attentions.isEmpty)
        XCTAssertEqual(stopped.symbol, "door.garage.closed")
    }

    func testAFailedIngestIsListedButDoesNotShoutFromTheMenuBar() {
        let status = MenuBarStatus(database: .running, lastIngestError: "3 files failed")
        XCTAssertEqual(status.attentions, [.ingestFailed("3 files failed")])
        XCTAssertFalse(status.needsAttention)
        XCTAssertEqual(status.symbol, "door.garage.open")
    }

    func testAStaleIngestErrorIsHiddenWhileANewRunIsUnderway() {
        let status = MenuBarStatus(database: .running, activity: .ingesting(.init(source: "notes")), lastIngestError: "old")
        XCTAssertTrue(status.attentions.isEmpty)
    }

    func testAttentionsAreOrderedWorstFirst() {
        let status = MenuBarStatus(database: .needsMigration, mcp: .failed("x"), lastIngestError: "y")
        // MCP is not listed: the database is not running, so its failure is a consequence.
        XCTAssertEqual(status.attentions, [.databaseNeedsMigration, .ingestFailed("y")])
    }

    // MARK: - Headline and progress

    func testIngestHeadlineNamesTheSourceAndThePercentageComesFromTheCounts() {
        let progress = MenuBarStatus.IngestProgress(source: "notes", processed: 424, total: 1000, itemType: "documents", reportedFraction: 0.1)
        let status = MenuBarStatus(database: .running, activity: .ingesting(progress))
        XCTAssertEqual(status.headline, "Reading notes")
        XCTAssertEqual(status.ingestFraction, 0.424)
        XCTAssertEqual(status.activityDetail, "424 of 1,000 documents")
        XCTAssertEqual(status.stage, .ingest)
    }

    func testIngestFallsBackToTheReportedFractionUntilTheScanHasSizedTheRun() {
        let progress = MenuBarStatus.IngestProgress(source: "", processed: 12, total: 0, reportedFraction: 0.3)
        let status = MenuBarStatus(database: .running, activity: .ingesting(progress))
        XCTAssertEqual(status.headline, "Reading")
        XCTAssertEqual(status.ingestFraction, 0.3)
        XCTAssertEqual(status.activityDetail, "12 documents")
    }

    func testIngestWithoutAnyProgressYetHasNoFraction() {
        let status = MenuBarStatus(database: .running, activity: .ingesting(.init(source: "notes")))
        XCTAssertNil(status.ingestFraction)
        XCTAssertNil(status.currentItem)
    }

    func testCurrentItemIsOnlyReportedWhenNonEmpty() {
        let empty = MenuBarStatus(database: .running, activity: .ingesting(.init(source: "n", currentItem: "")))
        XCTAssertNil(empty.currentItem)
        let file = MenuBarStatus(database: .running, activity: .ingesting(.init(source: "n", currentItem: "/tmp/a.md")))
        XCTAssertEqual(file.currentItem, "/tmp/a.md")
    }

    func testScanReportsWhatItHasFoundSoFar() {
        XCTAssertNil(MenuBarStatus(database: .running, activity: .scanning(itemsSoFar: nil)).activityDetail)
        let status = MenuBarStatus(database: .running, activity: .scanning(itemsSoFar: 1234))
        XCTAssertEqual(status.headline, "Scanning sources")
        XCTAssertEqual(status.activityDetail, "1,234 items found so far")
        XCTAssertEqual(status.stage, .scan)
    }

    func testDatabaseStateWinsOverActivityInTheHeadline() {
        let status = MenuBarStatus(database: .stopping, activity: .ingesting(.init(source: "notes")))
        XCTAssertEqual(status.headline, "Stopping…")
    }

    func testStageTrailAddsDistillationOnlyWhileItRuns() {
        XCTAssertEqual(MenuBarStatus(database: .running, activity: .embedding).stageTrail, [.scan, .ingest, .embed, .distill])
        XCTAssertEqual(MenuBarStatus(database: .running, activity: .distilling).stageTrail, [.scan, .ingest, .embed, .distill])
        XCTAssertNil(MenuBarStatus(database: .running).stage)
    }

    // MARK: - Rows

    func testCorpusLineReadsNaturally() {
        XCTAssertEqual(MenuBarStatus(database: .running).corpusLine, "No sources yet")
        XCTAssertEqual(MenuBarStatus(database: .running, sourceCount: 2).corpusLine, "No documents yet")
        XCTAssertEqual(MenuBarStatus(database: .running, sourceCount: 1, documentCount: 1).corpusLine, "1 document in 1 source")
        XCTAssertEqual(MenuBarStatus(database: .running, sourceCount: 3, documentCount: 1234).corpusLine, "1,234 documents in 3 sources")
    }

    func testIngestNowNeedsARunningDatabaseAnIdlePipelineAndASource() {
        XCTAssertTrue(MenuBarStatus(database: .running, sourceCount: 1).canIngest)
        XCTAssertFalse(MenuBarStatus(database: .running, sourceCount: 0).canIngest)
        XCTAssertFalse(MenuBarStatus(database: .running, activity: .embedding, sourceCount: 1).canIngest)
        XCTAssertFalse(MenuBarStatus(database: .stopped, sourceCount: 1).canIngest)
    }

    func testMCPDetailCountsRegisteredClients() {
        XCTAssertEqual(MenuBarStatus(database: .running, mcp: .running(clients: 0)).mcpDetail, "Serving · no assistants connected")
        XCTAssertEqual(MenuBarStatus(database: .running, mcp: .running(clients: 1)).mcpDetail, "Serving · 1 assistant connected")
        XCTAssertEqual(MenuBarStatus(database: .running, mcp: .running(clients: 2)).mcpDetail, "Serving · 2 assistants connected")
        XCTAssertEqual(MenuBarStatus(database: .running, mcp: .stopped).mcpDetail, "Not running")
        XCTAssertEqual(MenuBarStatus(database: .stopped, mcp: .stopped).mcpDetail, "Waits for the database")
        XCTAssertEqual(MenuBarStatus(database: .running, mcp: .failed("boom")).mcpDetail, "boom")
    }

    func testDatabaseDetailCarriesTheFailureMessage() {
        XCTAssertEqual(MenuBarStatus(database: .failed("port in use")).databaseDetail, "port in use")
        XCTAssertEqual(MenuBarStatus(database: .needsMigration).databaseDetail, "Schema update needed")
    }

    // MARK: - Formatting

    func testPercentClamps() {
        XCTAssertEqual(MenuBarStatus.percent(-0.2), "0%")
        XCTAssertEqual(MenuBarStatus.percent(0.424), "42%")
        XCTAssertEqual(MenuBarStatus.percent(1.7), "100%")
    }

    func testProgressLineFallsBackToDocuments() {
        XCTAssertEqual(MenuBarStatus.progressLine(processed: 3, total: 10, itemType: "messages"), "3 of 10 messages")
        XCTAssertEqual(MenuBarStatus.progressLine(processed: 3, total: 0, itemType: ""), "3 documents")
    }

    func testAbbreviatedPathReplacesTheHomeFolder() {
        XCTAssertEqual(MenuBarStatus.abbreviatedPath("/Users/rick/Notes/a.md", home: "/Users/rick"), "~/Notes/a.md")
        XCTAssertEqual(MenuBarStatus.abbreviatedPath("/Users/rickmark/a.md", home: "/Users/rick"), "/Users/rickmark/a.md")
        XCTAssertEqual(MenuBarStatus.abbreviatedPath("/tmp/a.md", home: ""), "/tmp/a.md")
    }

    // MARK: - Live state

    @MainActor
    func testReadsAFreshAppStateAsStoppedAndIdle() {
        let appState = AppState()
        let status = MenuBarStatus(appState: appState)
        // The MCP row follows the HTTP choice this Mac's defaults already hold.
        let mcp: MenuBarStatus.Server = appState.mcp.httpEnabled ? .stopped : .stdio(clients: appState.mcp.detectedClients.filter(\.isRegistered).count)
        XCTAssertEqual(status, MenuBarStatus(database: .stopped, mcp: mcp, activity: .idle))
    }

    @MainActor
    func testReadsTheCorpusFromTheAppState() {
        let appState = AppState()
        appState.setRegisteredSourcesForTesting([])
        var stats = CorpusStats()
        stats.documentsCount = 42
        appState.setCorpusStatsForTesting(stats)
        let status = MenuBarStatus(appState: appState)
        XCTAssertEqual(status.documentCount, 42)
        XCTAssertEqual(status.sourceCount, 0)
    }

    // MARK: - All systems go

    func testDatabaseAndServingMCPFoldIntoAllSystemsGo() {
        let status = MenuBarStatus(database: .running, mcp: .running(clients: 2))
        XCTAssertTrue(status.allSystemsGo)
        XCTAssertEqual(status.allSystemsGoDetail, "Database and MCP running · 2 assistants connected")
        XCTAssertEqual(MenuBarStatus(database: .running, mcp: .running(clients: 1)).allSystemsGoDetail, "Database and MCP running · 1 assistant connected")
        XCTAssertEqual(MenuBarStatus(database: .running, mcp: .running(clients: 0)).allSystemsGoDetail, "Database and MCP running · no assistants connected")
    }

    func testAnyServiceNotFineSpellsTheRowsOutAgain() {
        XCTAssertFalse(MenuBarStatus(database: .running, mcp: .stopped).allSystemsGo)
        XCTAssertFalse(MenuBarStatus(database: .running, mcp: .failed("port in use")).allSystemsGo)
        XCTAssertFalse(MenuBarStatus(database: .running, mcp: .starting).allSystemsGo)
        XCTAssertFalse(MenuBarStatus(database: .stopped, mcp: .running(clients: 1)).allSystemsGo)
        XCTAssertFalse(MenuBarStatus(database: .needsMigration, mcp: .running(clients: 1)).allSystemsGo)
    }

    func testStdioWithHTTPOffIsAllSystemsGo() {
        let status = MenuBarStatus(database: .running, mcp: .stdio(clients: 2))
        XCTAssertTrue(status.allSystemsGo)
        XCTAssertEqual(status.allSystemsGoDetail, "Database running · 2 assistants connected")
        XCTAssertEqual(MenuBarStatus(database: .running, mcp: .stdio(clients: 0)).allSystemsGoDetail, "Database running · no assistants connected")
        XCTAssertEqual(status.summary.title, "All systems go")
        XCTAssertEqual(status.mcpDetail, "Over stdio · 2 assistants connected")
        XCTAssertFalse(MenuBarStatus(database: .stopped, mcp: .stdio(clients: 1)).allSystemsGo)
    }

    func testIdleOnARunningDatabaseHasNoSecondStatusDot() {
        XCTAssertFalse(MenuBarStatus(database: .running, mcp: .running(clients: 1)).showsActivityDot)
        XCTAssertTrue(MenuBarStatus(database: .running, mcp: .running(clients: 1), activity: .embedding).showsActivityDot)
        XCTAssertTrue(MenuBarStatus(database: .stopped).showsActivityDot)
    }

    // MARK: - Summary row

    func testSummaryIsAllSystemsGoWhenEverythingRuns() {
        let summary = MenuBarStatus(database: .running, mcp: .running(clients: 2)).summary
        XCTAssertEqual(summary.title, "All systems go")
        XCTAssertEqual(summary.detail, "Database and MCP running · 2 assistants connected")
        XCTAssertEqual(summary.tint, .green)
    }

    func testSummaryNamesTheWorstProblemFirst() {
        // A database failure hides the MCP server's knock-on failure.
        let failed = MenuBarStatus(database: .failed("port 14824 already in use\nFATAL: ..."), mcp: .failed("no database")).summary
        XCTAssertEqual(failed.title, "Database failed to start")
        XCTAssertEqual(failed.detail, "port 14824 already in use")
        XCTAssertEqual(failed.tint, .red)

        XCTAssertEqual(MenuBarStatus(database: .needsMigration).summary.title, "Database needs a schema update")
        XCTAssertEqual(MenuBarStatus(database: .stopped).summary.title, "Database stopped")
        XCTAssertEqual(MenuBarStatus(database: .running, mcp: .failed("")).summary.detail, "Open Status to fix it.")
        XCTAssertEqual(MenuBarStatus(database: .running, mcp: .stopped).summary.title, "MCP server not running")
    }

    // MARK: - Review fixes

    func testQuickSearchOpensPlainPathsAndFileURLsOnly() {
        XCTAssertEqual(MenuBarQuickSearch.fileURL(forURI: "/Users/me/notes.md")?.path, "/Users/me/notes.md")
        XCTAssertEqual(MenuBarQuickSearch.fileURL(forURI: "file:///Users/me/notes.md")?.path, "/Users/me/notes.md")
        XCTAssertNil(MenuBarQuickSearch.fileURL(forURI: "imessage://chat/123"))
        XCTAssertNil(MenuBarQuickSearch.fileURL(forURI: "notes.md"))
    }

    func testIngestAllKeepsAnEarlierSourcesFailure() {
        XCTAssertNil(AppState.ingestAllFailureSummary([]))
        XCTAssertEqual(AppState.ingestAllFailureSummary([("notes", "permission denied\n")]), "notes: permission denied")
        XCTAssertEqual(AppState.ingestAllFailureSummary([("notes", "")]), "notes failed")
        XCTAssertEqual(AppState.ingestAllFailureSummary([("notes", "a"), ("mail", "b")]), "2 sources failed: notes, mail")
    }
}

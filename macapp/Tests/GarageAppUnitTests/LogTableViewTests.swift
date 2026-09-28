import XCTest
import SwiftUI
@testable import GarageApp

final class LogTableViewTests: XCTestCase {

    func testLogLevelOrderingAndComparison() {
        XCTAssertTrue(LogLevel.debug < LogLevel.info)
        XCTAssertTrue(LogLevel.info < LogLevel.warning)
        XCTAssertTrue(LogLevel.warning < LogLevel.error)
        XCTAssertEqual(LogLevel.allCases.count, 4)
    }

    func testLogLevelInferencing() {
        let errorLine = LogLine(stream: .stdout, text: "FATAL: database cluster corrupted", source: "postgres")
        XCTAssertEqual(errorLine.level, .error)

        let panicLine = LogLine(stream: .stdout, text: "panic: runtime error: index out of range", source: "app")
        XCTAssertEqual(panicLine.level, .error)

        let tracebackLine = LogLine(stream: .stdout, text: "Traceback (most recent call last):", source: "python")
        XCTAssertEqual(tracebackLine.level, .error)

        let warnLine = LogLine(stream: .stdout, text: "[WARN] high memory consumption detected", source: "garage")
        XCTAssertEqual(warnLine.level, .warning)

        let warningLine = LogLine(stream: .stdout, text: "WARNING: relation does not exist", source: "postgres")
        XCTAssertEqual(warningLine.level, .warning)

        let debugLine = LogLine(stream: .stdout, text: "[DEBUG] fetching 100 vector embeddings", source: "llama")
        XCTAssertEqual(debugLine.level, .debug)

        let infoLine = LogLine(stream: .stdout, text: "server started on port 14824", source: "postgres")
        XCTAssertEqual(infoLine.level, .info)

        let stderrLine = LogLine(stream: .stderr, text: "something failed", source: "cli")
        XCTAssertEqual(stderrLine.level, .error)

        let explicitOverride = LogLine(stream: .stdout, text: "just a notice", source: "custom", level: .warning)
        XCTAssertEqual(explicitOverride.level, .warning)
    }

    func testLogLineSearchMatching() {
        let line = LogLine(stream: .stdout, text: "vacuum analyze completed", source: "postgres-worker")

        XCTAssertTrue(line.matches(searchText: ""))
        XCTAssertTrue(line.matches(searchText: "vacuum"))
        XCTAssertTrue(line.matches(searchText: "VACUUM"))
        XCTAssertTrue(line.matches(searchText: "worker"))
        XCTAssertTrue(line.matches(searchText: "stdout"))
        XCTAssertTrue(line.matches(searchText: "info"))
        XCTAssertFalse(line.matches(searchText: "nonexistent_token_xyz"))
    }

    func testLogLevelFilterMatching() {
        XCTAssertTrue(LogLevelFilter.all.matches(.debug))
        XCTAssertTrue(LogLevelFilter.all.matches(.error))

        XCTAssertTrue(LogLevelFilter.error.matches(.error))
        XCTAssertFalse(LogLevelFilter.error.matches(.warning))

        XCTAssertTrue(LogLevelFilter.warning.matches(.warning))
        XCTAssertFalse(LogLevelFilter.warning.matches(.info))

        XCTAssertTrue(LogLevelFilter.info.matches(.info))
        XCTAssertFalse(LogLevelFilter.info.matches(.debug))

        XCTAssertTrue(LogLevelFilter.debug.matches(.debug))
        XCTAssertFalse(LogLevelFilter.debug.matches(.error))

        XCTAssertTrue(LogLevelFilter.warningsAndErrors.matches(.warning))
        XCTAssertTrue(LogLevelFilter.warningsAndErrors.matches(.error))
        XCTAssertFalse(LogLevelFilter.warningsAndErrors.matches(.info))
        XCTAssertFalse(LogLevelFilter.warningsAndErrors.matches(.debug))
    }

    func testStatusBarCountText() {
        XCTAssertEqual(LogTableView.countText(shown: 0, matching: 0, total: 0), "0 of 0 entries")
        XCTAssertEqual(LogTableView.countText(shown: 1, matching: 1, total: 1), "1 of 1 entry")
        XCTAssertEqual(LogTableView.countText(shown: 3, matching: 3, total: 12), "3 of 12 entries")
        XCTAssertEqual(
            LogTableView.countText(shown: 500, matching: 4000, total: 4000),
            "4000 of 4000 entries, showing the latest 500"
        )
    }

    func testLogTableViewFilteredLines() {
        let lines: [LogLine] = [
            LogLine(stream: .stdout, text: "Starting server", source: "app", level: .info),
            LogLine(stream: .stdout, text: "Memory cache warming", source: "app", level: .debug),
            LogLine(stream: .stdout, text: "Connection pool exhausted", source: "db", level: .warning),
            LogLine(stream: .stderr, text: "Crash in worker process", source: "worker", level: .error),
        ]

        let view = LogTableView(lines: lines, sourceName: "TestApp")
        XCTAssertEqual(view.filteredLines.count, 4)
    }

    /// Past the cap the table keeps the newest lines, then sorts them as asked.
    func testRowsShownKeepsTheNewestLinesPastTheCap() {
        let start = Date(timeIntervalSince1970: 1_000)
        let lines = (0..<10).map { index in
            LogLine(date: start.addingTimeInterval(Double(index)), stream: .stdout, text: "line \(index)", source: "app")
        }
        let byDate = [KeyPathComparator(\LogLine.date, order: .forward)]

        let shown = LogTableView.rowsShown(from: lines.shuffled(), sortOrder: byDate, limit: 3)
        XCTAssertEqual(shown.map(\.text), ["line 7", "line 8", "line 9"])

        let newestFirst = LogTableView.rowsShown(from: lines, sortOrder: [KeyPathComparator(\LogLine.date, order: .reverse)], limit: 3)
        XCTAssertEqual(newestFirst.map(\.text), ["line 9", "line 8", "line 7"])

        XCTAssertEqual(LogTableView.rowsShown(from: lines, sortOrder: byDate, limit: 50).count, 10)
    }

    @MainActor
    func testLogTableViewHosting() {
        let lines = [
            LogLine(stream: .stdout, text: "Sample log line 1", source: "test"),
            LogLine(stream: .stderr, text: "Sample error line 2", source: "test"),
        ]
        let view = LogTableView(lines: lines, sourceName: "TestService", onClear: {})
        let hostingController = NSHostingController(rootView: view)
        XCTAssertNotNil(hostingController.view)
    }

    @MainActor
    func testAppStateClearLogs() {
        let appState = AppState()
        appState.clearLogs(for: "Postgres")
        appState.clearLogs(for: "garage CLI")
        appState.clearLogs(for: "Ingest")
        appState.clearLogs(for: "Backfill")
        appState.clearLogs(for: "MCP Server")
        appState.clearLogs(for: "Llama Service")
        appState.clearLogs(for: "Model Downloader")
        appState.clearLogs(for: "Unified Log")

        XCTAssertTrue(appState.postgres.logs.isEmpty)
        XCTAssertTrue(appState.garage.logs.isEmpty)
        XCTAssertTrue(appState.ingestService.logs.isEmpty)
        XCTAssertTrue(appState.backfill.logs.isEmpty)
        XCTAssertTrue(appState.mcp.logs.isEmpty)
        XCTAssertTrue(appState.llama.logs.isEmpty)
        XCTAssertTrue(appState.osLogStreamService.logs.isEmpty)
    }

    @MainActor
    func testOSLogStreamServiceOperations() {
        let streamer = OSLogStreamService(startStreaming: false)
        XCTAssertFalse(streamer.isStreaming)
        XCTAssertTrue(streamer.isPaused)

        // Test appending log entries for specific targets
        let line1 = LogLine(stream: .stdout, text: "Ingest completed for 10 docs", source: "IngestService", level: .info)
        streamer.appendLog(line1, for: [.ingest, .unifiedLog])
        XCTAssertEqual(streamer.logs(for: .ingest).count, 1)
        XCTAssertEqual(streamer.logs(for: .unifiedLog).count, 1)
        XCTAssertEqual(streamer.logs(for: .llama).count, 0)
        XCTAssertEqual(streamer.logs(for: .ingest).first?.text, "Ingest completed for 10 docs")

        // Test deduplication
        streamer.appendLog(line1, for: [.ingest, .unifiedLog])
        XCTAssertEqual(streamer.logs(for: .ingest).count, 1)

        // Test time windows
        XCTAssertEqual(OSLogTimeWindow.allCases.count, 5)
        XCTAssertEqual(OSLogTimeWindow.recent5m.interval, 300)

        // Test streaming controls
        streamer.startStreaming(since: Date().addingTimeInterval(-60))
        XCTAssertTrue(streamer.isStreaming)
        XCTAssertTrue(streamer.isPaused)

        streamer.resumeStreaming()
        XCTAssertFalse(streamer.isPaused)

        streamer.pauseStreaming()
        XCTAssertTrue(streamer.isPaused)

        streamer.resumeStreaming()
        XCTAssertFalse(streamer.isPaused)

        streamer.togglePause()
        XCTAssertTrue(streamer.isPaused)

        streamer.togglePause()
        XCTAssertFalse(streamer.isPaused)

        streamer.stopStreaming()
        XCTAssertFalse(streamer.isStreaming)

        // Test per-source clear and fetch
        streamer.clearLogs(for: .ingest)
        XCTAssertTrue(streamer.logs(for: .ingest).isEmpty)
        XCTAssertFalse(streamer.logs(for: .unifiedLog).isEmpty)

        streamer.clearLogs()
        XCTAssertTrue(streamer.logs(for: .unifiedLog).isEmpty)
    }

    /// A batch keeps its order in every source and each line lands only in the sources it names; a
    /// repeated line is dropped once.
    @MainActor
    func testARoutedBatchKeepsItsOrderPerSource() {
        let streamer = OSLogStreamService(startStreaming: false)
        let lines = (0..<4).map { LogLine(stream: .stdout, text: "line \($0)", source: "test", level: .info) }
        streamer.appendRouted([
            RoutedLogLine(line: lines[0], targets: [.unifiedLog, .ingest]),
            RoutedLogLine(line: lines[1], targets: [.unifiedLog]),
            RoutedLogLine(line: lines[2], targets: [.unifiedLog, .ingest]),
            RoutedLogLine(line: lines[0], targets: [.unifiedLog, .ingest]),
            RoutedLogLine(line: lines[3], targets: [.llama]),
        ])

        XCTAssertEqual(streamer.logs(for: .unifiedLog).map(\.text), ["line 0", "line 1", "line 2"])
        XCTAssertEqual(streamer.logs(for: .ingest).map(\.text), ["line 0", "line 2"])
        XCTAssertEqual(streamer.logs(for: .llama).map(\.text), ["line 3"])
    }

    /// The store sees only this process, which logs under the app's bundle identifier;
    /// the one predicate must cover it (per-source routing is by category).
    func testAppPredicateCoversTheAppSubsystem() {
        let bundleID = "me.rickmark.garage-rag"
        let predicate = NSPredicate(format: OSLogStreamService.appPredicateFormat)
        XCTAssertTrue(predicate.evaluate(with: ["subsystem": bundleID]))
        XCTAssertFalse(predicate.evaluate(with: ["subsystem": "com.apple.network"]))
    }
}

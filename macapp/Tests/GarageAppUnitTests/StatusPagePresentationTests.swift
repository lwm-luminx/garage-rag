import XCTest
import SwiftUI
import PythonXPCService
@testable import GarageApp

final class StatusPagePresentationTests: XCTestCase {

    // MARK: - Health

    func testEverythingRunningIsAllSystemsGo() {
        let health = StatusHealth(database: .running, mcp: .running(clients: 2), sourceCount: 1, embeddingModelCount: 1)
        XCTAssertTrue(health.isHealthy)
        XCTAssertEqual(health.summary.title, "All systems go")
        XCTAssertEqual(health.summary.detail, "Database and MCP running · 2 assistants connected")
    }

    func testStartingServicesAreNotAProblem() {
        let health = StatusHealth(database: .starting, sourceCount: 1, embeddingModelCount: 1)
        XCTAssertTrue(health.isHealthy)
        XCTAssertEqual(health.summary.title, "Starting up…")
    }

    func testDatabaseProblemsComeWithTheirFix() throws {
        let failed = StatusHealth(database: .failed("port 14824 already in use\nmore"), sourceCount: 1, embeddingModelCount: 1)
        let problem = try XCTUnwrap(failed.problems.first)
        XCTAssertEqual(problem.title, "Database couldn't start")
        XCTAssertEqual(problem.detail, "port 14824 already in use")
        XCTAssertTrue(problem.detailIsError)
        XCTAssertEqual(problem.fix, .startDatabase)
        XCTAssertEqual(problem.fixLabel, "Try Again")
        XCTAssertEqual(problem.severity, .critical)
        XCTAssertEqual(problem.section, .database)

        let stopped = StatusHealth(database: .stopped, sourceCount: 1, embeddingModelCount: 1)
        XCTAssertEqual(stopped.problems.map(\.title), ["Database stopped"])
        XCTAssertEqual(stopped.problems.first?.fixLabel, "Start")

        let migration = StatusHealth(database: .needsMigration, sourceCount: 1, embeddingModelCount: 1)
        XCTAssertEqual(migration.problems.first?.title, "Database needs a schema update")
        XCTAssertEqual(migration.problems.first?.fix, .applyMigrations)
    }

    func testMCPProblemsAreListedOnlyWhileTheDatabaseRuns() {
        let down = StatusHealth(database: .stopped, mcp: .failed("boom"), sourceCount: 1, embeddingModelCount: 1)
        XCTAssertEqual(down.problems.map(\.id), ["database"])

        let up = StatusHealth(database: .running, mcp: .failed("boom"), sourceCount: 1, embeddingModelCount: 1)
        XCTAssertEqual(up.problems.map(\.id), ["mcp"])
        XCTAssertEqual(up.problems.first?.title, "MCP server failed")
        XCTAssertEqual(up.problems.first?.fixLabel, "Try Again")

        let stopped = StatusHealth(database: .running, mcp: .stopped, sourceCount: 1, embeddingModelCount: 1)
        XCTAssertEqual(stopped.problems.first?.title, "MCP server not running")
        XCTAssertEqual(stopped.problems.first?.fix, .startMCP)

        let notAnswering = StatusHealth(database: .running, mcp: .running(clients: 1), mcpCheckFailure: "HTTP 500", sourceCount: 1, embeddingModelCount: 1)
        XCTAssertEqual(notAnswering.problems.first?.title, "MCP server isn't answering")
        XCTAssertEqual(notAnswering.problems.first?.fix, .testMCP)
    }

    func testCriticalProblemsComeFirst() {
        let health = StatusHealth(
            database: .running,
            mcp: .stopped,
            sourceAccess: [.init(slug: "apple-sms", name: "Messages", path: "/Users/rick/Library/Messages", needsPermission: true)],
            sourceCount: 1,
            embeddingModelCount: 0,
            llamaError: "Couldn't communicate with a helper application."
        )
        XCTAssertEqual(health.problems.map(\.id), ["llama", "mcp", "source.apple-sms", "models"])
        XCTAssertEqual(health.problems[2].title, "Messages needs permission")
        XCTAssertEqual(health.problems[2].fix, .grantFolder(slug: "apple-sms", path: "/Users/rick/Library/Messages"))
        XCTAssertEqual(health.problems[3].title, "No embedding model")
        XCTAssertNil(health.problems[3].fix)
    }

    func testMailAndMessagesPointAtFullDiskAccess() {
        let health = StatusHealth(
            database: .running,
            mcp: .running(clients: 1),
            sourceAccess: [.init(slug: "apple-mail", name: "Mail", path: "/Users/rick/Library/Mail", needsPermission: true, needsFullDiskAccess: true)],
            sourceCount: 1,
            embeddingModelCount: 1
        )
        let problem = health.problems.first { $0.id == "source.apple-mail" }
        XCTAssertEqual(problem?.title, "Mail needs Full Disk Access")
        XCTAssertEqual(problem?.fix, .openPrivacySettings)
    }

    func testEmptyCorpusProblemsNeedARunningDatabase() {
        let stopped = StatusHealth(database: .stopped)
        XCTAssertEqual(stopped.problems.map(\.id), ["database"])

        let running = StatusHealth(database: .running, mcp: .running(clients: 0))
        XCTAssertEqual(running.problems.map(\.id), ["sources", "models"])
    }

    func testAFailedIngestIsListedOnlyWhileIdle() {
        let idle = StatusHealth(database: .running, mcp: .running(clients: 0), sourceCount: 1, embeddingModelCount: 1, lastIngestError: "notes: permission denied")
        XCTAssertEqual(idle.problems.map(\.id), ["ingest"])
        XCTAssertEqual(idle.problems.first?.detail, "notes: permission denied")

        let busy = StatusHealth(database: .running, mcp: .running(clients: 0), sourceCount: 1, embeddingModelCount: 1, lastIngestError: "notes: permission denied", isPipelineBusy: true)
        XCTAssertTrue(busy.isHealthy)
    }

    func testDiskAccessProblems() {
        let denied = StatusHealth(database: .running, mcp: .running(clients: 0), diskAccess: .denied(reason: "no bookmark"), sourceCount: 1, embeddingModelCount: 1)
        XCTAssertEqual(denied.problems.first?.title, "Garage can't read your disk")
        XCTAssertEqual(denied.problems.first?.severity, .critical)
        XCTAssertEqual(denied.problems.first?.fix, .chooseDisk)

        let stale = StatusHealth(database: .running, mcp: .running(clients: 0), diskAccess: .stale(path: "/Volumes/Data"), sourceCount: 1, embeddingModelCount: 1)
        XCTAssertEqual(stale.problems.first?.title, "Disk access needs renewing")
        XCTAssertEqual(stale.problems.first?.severity, .warning)
    }

    // MARK: - Indexing

    private func stats(
        documents: Int, expected: Int = 0, chunks: Int = 0, embedded: [Int] = [], distilled: Int = 0, facts: Int = 0, failed: Int = 0
    ) -> CorpusStats {
        CorpusStats(
            sourcesCount: 1,
            documentsCount: documents,
            documentsOkCount: documents - failed,
            documentsFailedCount: failed,
            totalChunks: chunks,
            embeddedChunks: embedded.first ?? 0,
            totalExpectedElements: expected,
            modelStats: embedded.enumerated().map {
                CorpusStats.ModelEmbeddingStats(slug: "m\($0.offset)", tableName: "emb_m\($0.offset)", isDefault: $0.offset == 0, embeddedCount: $0.element)
            },
            factsCount: facts,
            documentsDistilledCount: distilled,
            lastUpdated: Date()
        )
    }

    func testNoSourcesHasNothingToIndex() {
        let indexing = IndexingPresentation(stats: CorpusStats(), sourceCount: 0, modelCount: 0, distillsFacts: false)
        XCTAssertEqual(indexing.headline.title, "Nothing to index yet")
        XCTAssertEqual(indexing.action, .addSource)
        XCTAssertNil(indexing.headline.progress)
    }

    func testSourcesNeverScannedAreNotIndexedYet() {
        let indexing = IndexingPresentation(stats: CorpusStats(sourcesCount: 2), sourceCount: 2, modelCount: 1, distillsFacts: false)
        XCTAssertEqual(indexing.headline.title, "Not indexed yet")
        XCTAssertEqual(indexing.headline.detail, "2 sources · Update Everything scans, reads, indexes and gleans them.")
        XCTAssertEqual(indexing.action, .updateEverything(enabled: true))
    }

    func testUpToDateNamesTheCorpus() {
        let indexing = IndexingPresentation(
            stats: stats(documents: 1234, expected: 1234, chunks: 100, embedded: [100, 100], distilled: 1234, facts: 4000),
            sourceCount: 3, modelCount: 2, distillsFacts: true
        )
        XCTAssertEqual(indexing.headline.title, "Up to date")
        XCTAssertEqual(indexing.headline.detail, "1,234 documents in 3 sources · indexed with 2 models · facts gleaned")
        XCTAssertEqual(indexing.headline.tint, .green)
        XCTAssertNil(indexing.headline.progress)
        XCTAssertEqual(indexing.fraction, 1)
    }

    func testUpToDateWithoutAModelOrFactsSaysOnlyWhatIsThere() {
        let indexing = IndexingPresentation(stats: stats(documents: 2, expected: 2, chunks: 10), sourceCount: 1, modelCount: 0, distillsFacts: false)
        XCTAssertEqual(indexing.headline.title, "Up to date")
        XCTAssertEqual(indexing.headline.detail, "2 documents in 1 source")
        XCTAssertNil(indexing.remaining.embeddingsToGo, "no model registered: nothing to embed with")
        XCTAssertNil(indexing.remaining.documentsToDistill)
    }

    func testBehindCountsEveryStageAndAveragesTheBar() throws {
        let indexing = IndexingPresentation(
            stats: stats(documents: 1180, expected: 1204, chunks: 10_000, embedded: [9_120], distilled: 880),
            sourceCount: 1, modelCount: 1, distillsFacts: true
        )
        XCTAssertEqual(indexing.remaining, IndexingPresentation.Remaining(documentsToIngest: 24, embeddingsToGo: 880, documentsToDistill: 300))
        XCTAssertEqual(indexing.headline.title, "1,204 items to index")
        XCTAssertEqual(indexing.headline.detail, "24 documents to read · 880 chunks to index · 300 documents to glean")
        XCTAssertEqual(indexing.headline.tint, .orange)
        let expected = (1180.0 / 1204.0 + 9_120.0 / 10_000.0 + 880.0 / 1180.0) / 3
        XCTAssertEqual(try XCTUnwrap(indexing.headline.progress), expected, accuracy: 0.0001)
        XCTAssertEqual(indexing.headline.percent, MenuBarStatus.percent(expected))
        XCTAssertEqual(indexing.action, .updateEverything(enabled: true))
    }

    func testOneEmbeddingToGoIsSingular() {
        let indexing = IndexingPresentation(stats: stats(documents: 1, expected: 1, chunks: 1, embedded: [0]), sourceCount: 1, modelCount: 1, distillsFacts: false)
        XCTAssertEqual(indexing.headline.title, "1 item to index")
        XCTAssertEqual(indexing.headline.detail, "1 chunk to index")
    }

    func testTheLastRunsErrorReplacesTheLine() {
        let indexing = IndexingPresentation(
            stats: stats(documents: 2, expected: 2), sourceCount: 1, modelCount: 0, distillsFacts: false,
            lastRunError: "notes: permission denied\nstack"
        )
        XCTAssertEqual(indexing.headline.title, "Up to date")
        XCTAssertEqual(indexing.headline.detail, "notes: permission denied")
        XCTAssertTrue(indexing.headline.detailIsError)
    }

    func testAStoppedDatabaseHasNoAction() {
        let indexing = IndexingPresentation(stats: CorpusStats(), sourceCount: 2, modelCount: 1, distillsFacts: false, databaseIsRunning: false)
        XCTAssertEqual(indexing.headline.title, "Database stopped")
        XCTAssertEqual(indexing.action, .updateEverything(enabled: false))
    }

    func testRunningStagesShowTheirBarsAndStop() throws {
        let base = stats(documents: 10, expected: 20, chunks: 100, embedded: [50], distilled: 0)

        let scanning = IndexingPresentation(stats: base, sourceCount: 1, modelCount: 1, distillsFacts: true, activity: .scanning(source: "*", itemsSoFar: 1234))
        XCTAssertEqual(scanning.headline.title, "Scanning all sources…")
        XCTAssertEqual(scanning.headline.detail, "1,234 items so far")
        XCTAssertTrue(scanning.headline.isIndeterminate)
        XCTAssertEqual(scanning.headline.stage, .scan)
        XCTAssertEqual(scanning.action, .stop(isStopping: false))
        XCTAssertEqual(scanning.stageTrail, MenuBarStatus.Stage.allCases)

        let ingesting = IndexingPresentation(
            stats: base, sourceCount: 1, modelCount: 1, distillsFacts: true,
            activity: .ingesting(.init(subject: "notes", processed: 1204, total: 2860, indexed: 1180, skipped: 24, currentItem: "/Users/rick/Notes/retro.md"))
        )
        XCTAssertEqual(ingesting.headline.title, "Reading notes")
        XCTAssertEqual(ingesting.headline.percent, "42%")
        XCTAssertEqual(ingesting.headline.detail, "1,204 of 2,860 documents · 1,180 indexed · 24 skipped")
        XCTAssertEqual(ingesting.headline.stage, .ingest)
        XCTAssertEqual(try XCTUnwrap(ingesting.headline.progress), 1204.0 / 2860.0, accuracy: 0.0001)

        let embedding = IndexingPresentation(stats: base, sourceCount: 1, modelCount: 1, distillsFacts: true, activity: .embedding(model: "bge-m3", embedded: 9120, total: 10_000))
        XCTAssertEqual(embedding.headline.title, "Indexing with bge-m3")
        XCTAssertEqual(embedding.headline.percent, "91%")
        XCTAssertEqual(embedding.headline.detail, "9,120 of 10,000 chunks")
        XCTAssertEqual(embedding.headline.stage, .embed)

        let unsized = IndexingPresentation(stats: base, sourceCount: 1, modelCount: 1, distillsFacts: true, activity: .embedding(model: nil, embedded: 0, total: 0))
        XCTAssertEqual(unsized.headline.title, "Indexing new chunks")
        XCTAssertTrue(unsized.headline.isIndeterminate)

        let distilling = IndexingPresentation(stats: base, sourceCount: 1, modelCount: 1, distillsFacts: true, activity: .distilling(index: 30, total: 1000, document: "file:///Users/rick/Notes/a.md"))
        XCTAssertEqual(distilling.headline.title, "Gleaning facts")
        XCTAssertEqual(distilling.headline.percent, "3%")
        XCTAssertEqual(distilling.headline.detail, "30 of 1,000 documents")
        XCTAssertEqual(distilling.headline.stage, .distill)
        XCTAssertEqual(distilling.stageTrail, MenuBarStatus.Stage.allCases)

        let stopping = IndexingPresentation(stats: base, sourceCount: 1, modelCount: 1, distillsFacts: true, activity: .scanning(source: "*", itemsSoFar: 0), isStopping: true)
        XCTAssertEqual(stopping.headline.title, "Stopping…")
        XCTAssertEqual(stopping.action, .stop(isStopping: true))
    }

    func testFiguresCarryTheirNotes() {
        let indexing = IndexingPresentation(
            stats: stats(documents: 1234, expected: 1234, chunks: 56_789, embedded: [56_789, 50_000], distilled: 1200, facts: 4120, failed: 12),
            sourceCount: 3, modelCount: 2, distillsFacts: true
        )
        let figures = indexing.figures
        XCTAssertEqual(figures.map(\.label), ["Sources", "Documents", "Chunks", "Indexed", "Facts"])
        XCTAssertEqual(figures[0].value, "3")
        XCTAssertEqual(figures[1].value, "1,234")
        XCTAssertEqual(figures[1].note, "12 failed")
        XCTAssertTrue(figures[1].noteIsWarning)
        XCTAssertEqual(figures[2].value, "56,789")
        XCTAssertEqual(figures[3].value, "94%")
        XCTAssertEqual(figures[3].note, "2 models")
        XCTAssertEqual(figures[4].value, "4,120")
        XCTAssertEqual(figures[4].note, "from 1,200 documents")

        let noModel = IndexingPresentation(stats: stats(documents: 2, expected: 2), sourceCount: 1, modelCount: 0, distillsFacts: false)
        XCTAssertEqual(noModel.figures.map(\.label), ["Sources", "Documents", "Chunks", "Indexed"])
        XCTAssertEqual(noModel.figures[3].value, "–")
        XCTAssertEqual(noModel.figures[3].note, "no model")
    }

    // MARK: - Helper services

    func testGRPCRowReadsItsState() {
        let running = ServiceRowPresentation.grpc(status: .running, listening: "On 127.0.0.1:50051", lastTest: nil)
        XCTAssertEqual(running.name, "Index Manager")
        XCTAssertEqual(running.state, .running)
        XCTAssertEqual(running.stateTitle, "Running")
        XCTAssertTrue(running.detail.hasPrefix("On 127.0.0.1:50051 · "), running.detail)
        XCTAssertEqual(running.tint, .green)

        let tested = ServiceRowPresentation.grpc(status: .running, listening: "On 127.0.0.1:50051", lastTest: (isSuccess: true, summary: "5 queries"))
        XCTAssertEqual(tested.detail, "On 127.0.0.1:50051 · test passed")

        let failedTest = ServiceRowPresentation.grpc(status: .running, listening: "On 127.0.0.1:50051", lastTest: (isSuccess: false, summary: "GetStats: unavailable"))
        XCTAssertEqual(failedTest.detail, "GetStats: unavailable")
        XCTAssertTrue(failedTest.detailIsError)

        let failed = ServiceRowPresentation.grpc(status: .failed("bind: address in use"), listening: "On 127.0.0.1:50051", lastTest: nil)
        XCTAssertEqual(failed.state, .unreachable)
        XCTAssertEqual(failed.detail, "bind: address in use")
        XCTAssertTrue(failed.detailIsError)

        let stopped = ServiceRowPresentation.grpc(status: .stopped, listening: "On 127.0.0.1:50051", lastTest: nil)
        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertEqual(stopped.stateTitle, "Stopped")

        let onSocket = ServiceRowPresentation.grpc(status: .running, listening: "Without remote access", lastTest: nil)
        XCTAssertTrue(onSocket.detail.hasPrefix("Without remote access · "), onSocket.detail)
    }

    func testXPCRowReadsPingReportAndTest() {
        let service = XPCServiceInfo(
            id: "garage-xpc", name: "Garage Core Backend Helper", bundleId: "me.rickmark.garage-rag.xpc", serviceDescription: "",
            state: .running(pid: 42, latencyMs: 12.4, response: "pong")
        )
        let plain = ServiceRowPresentation.xpc(service, report: nil, test: nil)
        XCTAssertEqual(plain.name, "Garage Backend")
        XCTAssertEqual(plain.detail, "Running · 12 ms")
        XCTAssertFalse(plain.detailIsError)
        XCTAssertNil(plain.restartTint, "a healthy helper does not ask for a restart")

        let python = GarageXPCPythonStatus(state: "ready")
        let report = GarageXPCStatusReport(
            serviceName: "garage", bundleIdentifier: service.bundleId, pid: 42, uptimeSeconds: 10, lifecycle: "ready", python: python,
            tests: [
                GarageXPCTestResult(name: "Python Runtime", testDescription: "", status: .passed, durationMs: 1, summary: "ok", details: ""),
                GarageXPCTestResult(name: "Llama Loader", testDescription: "", status: .failed, durationMs: 1, summary: "no reply", details: "", errorMessage: "timeout"),
            ]
        )
        let reported = ServiceRowPresentation.xpc(service, report: report, test: nil)
        XCTAssertEqual(reported.detail, "Running · 12 ms · 1 passed, 1 failed")
        XCTAssertTrue(reported.detailIsError, "a failed self test colours the line")
        XCTAssertEqual(reported.restartTint, .yellow, "a failed self test suggests a restart")

        let withSkips = GarageXPCStatusReport(
            serviceName: "garage", bundleIdentifier: service.bundleId, pid: 42, uptimeSeconds: 10, lifecycle: "ready", python: python,
            tests: [
                GarageXPCTestResult(name: "Python Runtime", testDescription: "", status: .passed, durationMs: 1, summary: "ok", details: ""),
                GarageXPCTestResult(name: "Database Connection", testDescription: "", status: .skipped, durationMs: 0, summary: "not configured", details: ""),
            ]
        )
        let skipping = ServiceRowPresentation.xpc(service, report: withSkips, test: nil)
        XCTAssertEqual(skipping.detail, "Running · 12 ms · 1 passed, 1 skipped (Database Connection)")
        XCTAssertFalse(skipping.detailIsError, "a skipped self test is not a failure")

        let failedTest = ServiceDiagnosticTestResult(
            serviceId: "garage-xpc", testName: "Self Tests", testDescription: "", isSuccess: false, durationMs: 3,
            summary: "1 of 2 self tests failed", details: ""
        )
        let tested = ServiceRowPresentation.xpc(service, report: report, test: failedTest)
        XCTAssertEqual(tested.detail, "1 of 2 self tests failed")
        XCTAssertTrue(tested.detailIsError)

        let unreachable = XPCServiceInfo(id: "llama-xpc", name: "", bundleId: "", serviceDescription: "", state: .unreachable(error: "Couldn't communicate with a helper application.\ndetails"))
        let down = ServiceRowPresentation.xpc(unreachable, report: nil, test: nil)
        XCTAssertEqual(down.name, "Built-in Engine")
        XCTAssertEqual(down.state, .unreachable)
        XCTAssertEqual(down.detail, "Can't be reached: Couldn't communicate with a helper application.")
        XCTAssertEqual(down.tint, .red)
        XCTAssertEqual(down.restartTint, .red, "an unreachable helper needs a restart")

        let checking = XPCServiceInfo(id: "embed-xpc", name: "", bundleId: "", serviceDescription: "", state: .checking)
        XCTAssertTrue(ServiceRowPresentation.xpc(checking, report: nil, test: nil).isBusy)
    }

    // MARK: - Health: the rest of the problems

    func testEachFixHasItsButtonLabel() {
        XCTAssertEqual(StatusHealth.Fix.startDatabase.label, "Start")
        XCTAssertEqual(StatusHealth.Fix.applyMigrations.label, "Apply Updates")
        XCTAssertEqual(StatusHealth.Fix.startMCP.label, "Start")
        XCTAssertEqual(StatusHealth.Fix.testMCP.label, "Test Again")
        XCTAssertEqual(StatusHealth.Fix.chooseDisk.label, "Select Folder…")
        XCTAssertEqual(StatusHealth.Fix.grantFolder(slug: "mail", path: "/Users/rick/Library/Mail").label, "Grant Access…")
        XCTAssertEqual(StatusHealth.Fix.openPrivacySettings.label, "Open Privacy Settings…")
        XCTAssertEqual(StatusHealth.Fix.checkSourceAccess.label, "Check Again")
        XCTAssertEqual(StatusHealth.Fix.refreshLlama.label, "Try Again")
    }

    func testServicesOnTheirWayUpOrDownAreNotProblems() {
        for database in [MenuBarStatus.Database.starting, .stopping] {
            XCTAssertTrue(StatusHealth(database: database, sourceCount: 1, embeddingModelCount: 1).isHealthy, "\(database)")
        }
        for mcp in [MenuBarStatus.Server.starting, .stopping] {
            XCTAssertTrue(StatusHealth(database: .running, mcp: mcp, sourceCount: 1, embeddingModelCount: 1).isHealthy, "\(mcp)")
        }
    }

    func testAnUnconfiguredDiskAsksForOne() throws {
        let health = StatusHealth(database: .running, mcp: .running(clients: 0), diskAccess: .notConfigured, sourceCount: 1, embeddingModelCount: 1)
        let problem = try XCTUnwrap(health.problems.first)
        XCTAssertEqual(problem.id, "disk")
        XCTAssertEqual(problem.title, "Garage has no disk access yet")
        XCTAssertEqual(problem.severity, .warning)
        XCTAssertEqual(problem.fix, .chooseDisk)
        XCTAssertEqual(problem.section, .sources)
    }

    func testAnUnreadableSourceOffersToCheckAgain() throws {
        let health = StatusHealth(
            database: .running,
            mcp: .running(clients: 0),
            sourceAccess: [.init(slug: "usb", name: "usb", path: "/Volumes/Backup/Notes", needsPermission: false)],
            sourceCount: 1,
            embeddingModelCount: 1
        )
        let problem = try XCTUnwrap(health.problems.first)
        XCTAssertEqual(problem.id, "source.usb")
        XCTAssertEqual(problem.title, "usb can't be read")
        XCTAssertEqual(problem.detail, "/Volumes/Backup/Notes")
        XCTAssertEqual(problem.fix, .checkSourceAccess)
        XCTAssertEqual(problem.fixLabel, "Check Again")
    }

    func testAFailedAccessCheckThatNamesNoSourceIsStillListed() {
        let health = StatusHealth(
            database: .running, mcp: .running(clients: 0), sourceAccessMessage: "The check could not run.",
            sourceCount: 1, embeddingModelCount: 1
        )
        XCTAssertEqual(health.problems.map(\.id), ["source.access"])
        XCTAssertEqual(health.problems.first?.detail, "The check could not run.")
        XCTAssertTrue(health.problems.first?.detailIsError ?? false)

        let empty = StatusHealth(database: .running, mcp: .running(clients: 0), sourceAccessMessage: "", sourceCount: 1, embeddingModelCount: 1)
        XCTAssertTrue(empty.isHealthy, "an empty message is not a problem")
    }

    func testMissingCommandLineToolsSendToLogs() throws {
        let health = StatusHealth(
            database: .running, mcp: .running(clients: 0), sourceCount: 1, embeddingModelCount: 1,
            launcherPath: "/Applications/Garage.app/Contents/MacOS/garage-mcp"
        )
        let problem = try XCTUnwrap(health.problems.first)
        XCTAssertEqual(problem.id, "launcher")
        XCTAssertEqual(problem.title, "Command-line tools missing")
        XCTAssertTrue(problem.detail?.contains("/Applications/Garage.app/Contents/MacOS/garage-mcp") ?? false)
        XCTAssertEqual(problem.section, .logs)
        XCTAssertNil(problem.fix)
    }

    /// Within one severity the problems keep the order the pipeline needs them fixed in.
    func testWarningsKeepThePipelineOrder() {
        let health = StatusHealth(
            database: .running,
            mcp: .stopped,
            diskAccess: .notConfigured,
            sourceAccess: [.init(slug: "notes", name: "notes", path: "/Users/rick/Notes", needsPermission: false)],
            sourceCount: 0,
            embeddingModelCount: 0,
            lastIngestError: "notes: permission denied",
            launcherPath: "/nowhere/garage-mcp"
        )
        XCTAssertEqual(health.problems.map(\.id), ["mcp", "disk", "source.notes", "sources", "models", "ingest", "launcher"])
        XCTAssertTrue(health.problems.allSatisfy { $0.severity == .warning })
    }

    func testTheSummaryRowFollowsTheServices() {
        XCTAssertEqual(StatusHealth(database: .running, mcp: .running(clients: 1)).summary.title, "All systems go")
        XCTAssertEqual(StatusHealth(database: .starting).summary.title, "Starting up…")
    }

    // MARK: - Indexing: the rest of the states

    func testWaitingNamesTheFirstThreeQueuedSources() {
        let few = IndexingPresentation(stats: CorpusStats(), sourceCount: 2, modelCount: 1, distillsFacts: false, activity: .waiting(queued: ["notes", "mail"]))
        XCTAssertEqual(few.headline.title, "Waiting to scan notes, mail")
        XCTAssertTrue(few.headline.isIndeterminate)
        XCTAssertNil(few.headline.stage)
        XCTAssertEqual(few.action, .stop(isStopping: false))

        let many = IndexingPresentation(
            stats: CorpusStats(), sourceCount: 5, modelCount: 1, distillsFacts: false,
            activity: .waiting(queued: ["notes", "mail", "photos", "code", "docs"])
        )
        XCTAssertEqual(many.headline.title, "Waiting to scan notes, mail, photos and 2 more")
    }

    func testScanningOneSourceNamesIt() {
        let indexing = IndexingPresentation(stats: CorpusStats(), sourceCount: 2, modelCount: 1, distillsFacts: false, activity: .scanning(source: "notes", itemsSoFar: 0))
        XCTAssertEqual(indexing.headline.title, "Scanning notes…")
        XCTAssertEqual(indexing.headline.detail, "Counting what there is to index.")
        XCTAssertTrue(indexing.isRunning)
    }

    func testAnIngestOfAllBeforeTheScanSizedItUsesTheReportedFraction() throws {
        let sized = IndexingPresentation(
            stats: CorpusStats(), sourceCount: 2, modelCount: 1, distillsFacts: false,
            activity: .ingesting(.init(subject: nil, processed: 40, total: 0, reportedFraction: 0.25))
        )
        XCTAssertEqual(sized.headline.title, "Reading all sources")
        XCTAssertEqual(try XCTUnwrap(sized.headline.progress), 0.25, accuracy: 0.0001)
        XCTAssertEqual(sized.headline.percent, "25%")
        XCTAssertFalse(sized.headline.isIndeterminate)

        let unsized = IndexingPresentation(
            stats: CorpusStats(), sourceCount: 2, modelCount: 1, distillsFacts: false,
            activity: .ingesting(.init(subject: "", processed: 40, total: 0))
        )
        XCTAssertEqual(unsized.headline.title, "Reading all sources", "an empty subject is not a source name")
        XCTAssertNil(unsized.headline.progress)
        XCTAssertNil(unsized.headline.percent)
        XCTAssertTrue(unsized.headline.isIndeterminate)
    }

    func testAnIngestThatOverrunsItsTotalStopsAtAFullBar() throws {
        let indexing = IndexingPresentation(
            stats: CorpusStats(), sourceCount: 1, modelCount: 1, distillsFacts: false,
            activity: .ingesting(.init(subject: "notes", processed: 130, total: 100))
        )
        XCTAssertEqual(try XCTUnwrap(indexing.headline.progress), 1)
        XCTAssertEqual(indexing.headline.percent, "100%")
    }

    func testDistillingBeforeItsCountIsKnown() {
        let indexing = IndexingPresentation(stats: CorpusStats(), sourceCount: 1, modelCount: 1, distillsFacts: true, activity: .distilling(index: 0, total: 0, document: nil))
        XCTAssertEqual(indexing.headline.detail, "Facts for each document no prompt has distilled yet.")
        XCTAssertTrue(indexing.headline.isIndeterminate)
        XCTAssertNil(indexing.headline.currentItem)
    }

    func testNotIndexedYetShowsTheLastRunsError() {
        let indexing = IndexingPresentation(
            stats: CorpusStats(sourcesCount: 1), sourceCount: 1, modelCount: 1, distillsFacts: false,
            lastRunError: "notes: folder not found\ntrace"
        )
        XCTAssertEqual(indexing.headline.title, "Not indexed yet")
        XCTAssertEqual(indexing.headline.detail, "notes: folder not found")
        XCTAssertTrue(indexing.headline.detailIsError)
    }

    func testNothingKnownYetHasNoBarAndNoRemainingLine() {
        let indexing = IndexingPresentation(stats: CorpusStats(), sourceCount: 1, modelCount: 1, distillsFacts: true)
        XCTAssertEqual(indexing.remaining, IndexingPresentation.Remaining())
        XCTAssertEqual(indexing.remaining.total, 0)
        XCTAssertNil(indexing.fraction)
        XCTAssertNil(indexing.remainingLine)
        XCTAssertFalse(indexing.isRunning)
    }

    func testTheCorpusLineIsSingularForOne() {
        let indexing = IndexingPresentation(
            stats: stats(documents: 1, expected: 1, chunks: 3, embedded: [3], distilled: 1, facts: 2),
            sourceCount: 1, modelCount: 1, distillsFacts: true
        )
        XCTAssertEqual(indexing.corpusLine, "1 document in 1 source · indexed with 1 model · facts gleaned")
    }

    func testAStoppedDatabaseWithoutSourcesOffersNothingToRun() {
        let indexing = IndexingPresentation(stats: CorpusStats(), sourceCount: 0, modelCount: 0, distillsFacts: false, databaseIsRunning: false)
        XCTAssertEqual(indexing.headline.title, "Database stopped")
        XCTAssertEqual(indexing.action, .updateEverything(enabled: false), "Add Source needs the database")
    }

    func testFactsShowWhenThereAreSomeEvenWithoutAFactsModel() {
        let indexing = IndexingPresentation(
            stats: stats(documents: 4, expected: 4, chunks: 0, embedded: [], distilled: 0, facts: 9),
            sourceCount: 1, modelCount: 1, distillsFacts: false
        )
        let figures = indexing.figures
        XCTAssertEqual(figures.map(\.label), ["Sources", "Documents", "Chunks", "Indexed", "Facts"])
        XCTAssertEqual(figures[3].value, "–", "a model with no chunks yet has no percentage")
        XCTAssertEqual(figures[3].note, "1 model")
        XCTAssertEqual(figures[4].value, "9")
        XCTAssertNil(figures[4].note, "no document distilled yet")
        XCTAssertNil(figures[1].note, "nothing failed")
    }

    func testPlural() {
        XCTAssertEqual(IndexingPresentation.plural("source", 0), "sources")
        XCTAssertEqual(IndexingPresentation.plural("source", 1), "source")
        XCTAssertEqual(IndexingPresentation.plural("source", 2), "sources")
    }

    // MARK: - Helper services: every state

    func testEachServiceIdHasItsShortName() {
        XCTAssertEqual(ServiceRowPresentation.name(forServiceId: "ingest-xpc"), "Ingest")
        XCTAssertEqual(ServiceRowPresentation.name(forServiceId: "embed-xpc"), "Embeddings")
        XCTAssertEqual(ServiceRowPresentation.name(forServiceId: "llama-xpc"), "Built-in Engine")
        XCTAssertEqual(ServiceRowPresentation.name(forServiceId: "model-download-xpc"), "Model Downloads")
        XCTAssertEqual(ServiceRowPresentation.name(forServiceId: "image-embed-xpc"), "Image Embeddings")
        XCTAssertEqual(ServiceRowPresentation.name(forServiceId: "mcp-server-xpc"), "MCP Server")
        XCTAssertEqual(ServiceRowPresentation.name(forServiceId: "garage-xpc"), "Garage Backend")
        XCTAssertEqual(ServiceRowPresentation.name(forServiceId: "something-new"), "something-new")
    }

    func testEachStateHasItsSymbolTintAndTitle() {
        func row(_ state: ServiceRowPresentation.State) -> ServiceRowPresentation {
            ServiceRowPresentation(id: "x", name: "X", state: state, detail: "", detailIsError: false)
        }
        let expected: [(ServiceRowPresentation.State, String, Color, Bool, String, Bool)] = [
            (.running, "checkmark", .green, true, "Running", false),
            (.checking, "ellipsis", .yellow, false, "Checking…", true),
            (.restarting, "ellipsis", .yellow, false, "Restarting…", true),
            (.stopped, "pause.fill", .secondary, false, "Stopped", false),
            (.unreachable, "exclamationmark", .red, true, "Can't be reached", false),
            (.unknown, "questionmark", .secondary, false, "Not checked yet", false),
        ]
        for (state, symbol, tint, isActive, title, isBusy) in expected {
            let presentation = row(state)
            XCTAssertEqual(presentation.symbol, symbol, "\(state)")
            XCTAssertEqual(presentation.tint, tint, "\(state)")
            XCTAssertEqual(presentation.isActive, isActive, "\(state)")
            XCTAssertEqual(presentation.stateTitle, title, "\(state)")
            XCTAssertEqual(presentation.isBusy, isBusy, "\(state)")
        }
    }

    func testGRPCOnItsWayUpOrDownIsChecking() {
        let starting = ServiceRowPresentation.grpc(status: .starting, listening: "On 127.0.0.1:50051", lastTest: nil)
        XCTAssertEqual(starting.state, .checking)
        XCTAssertEqual(starting.detail, "Starting with the database…")

        let stopping = ServiceRowPresentation.grpc(status: .stopping, listening: "On 127.0.0.1:50051", lastTest: nil)
        XCTAssertEqual(stopping.state, .checking)
        XCTAssertEqual(stopping.detail, "Stopping…")

        // A test result only speaks for a running backend.
        let stoppedAfterATest = ServiceRowPresentation.grpc(status: .stopped, listening: "On 127.0.0.1:50051", lastTest: (isSuccess: false, summary: "old"))
        XCTAssertFalse(stoppedAfterATest.detailIsError)
        XCTAssertTrue(stoppedAfterATest.detail.hasPrefix("Starts with the database."), stoppedAfterATest.detail)
    }

    func testXPCRestartingUnknownAndAPassedTest() {
        let restarting = XPCServiceInfo(id: "ingest-xpc", name: "", bundleId: "", serviceDescription: "", state: .restarting)
        let restartingRow = ServiceRowPresentation.xpc(restarting, report: nil, test: nil)
        XCTAssertEqual(restartingRow.state, .restarting)
        XCTAssertEqual(restartingRow.detail, "Restarting…")

        let unknown = XPCServiceInfo(id: "model-download-xpc", name: "", bundleId: "", serviceDescription: "", state: .unknown)
        let unknownRow = ServiceRowPresentation.xpc(unknown, report: nil, test: nil)
        XCTAssertEqual(unknownRow.name, "Model Downloads")
        XCTAssertEqual(unknownRow.detail, "Not checked yet")

        let running = XPCServiceInfo(id: "embed-xpc", name: "", bundleId: "", serviceDescription: "", state: .running(pid: 7, latencyMs: 3.0, response: "pong"))
        let passed = ServiceDiagnosticTestResult(
            serviceId: "embed-xpc", testName: "Ping", testDescription: "", isSuccess: true, durationMs: 3, summary: "pong", details: ""
        )
        let tested = ServiceRowPresentation.xpc(running, report: nil, test: passed)
        XCTAssertEqual(tested.detail, "Running · 3 ms · test passed")
        XCTAssertFalse(tested.detailIsError)
    }
}

import XCTest
import PythonXPCService
import SwiftUI
import IngestClient
import ModelDownloadClient
@testable import GarageApp

final class AppStateTests: XCTestCase {

    @MainActor
    func testInitialState() {
        let state = AppState()

        XCTAssertTrue(state.autoStartPostgres)
        XCTAssertEqual(state.lastCommandOutput, "")
        XCTAssertNil(state.lastCommandSucceeded)
        XCTAssertEqual(state.postgres.status, .stopped)
        XCTAssertNotNil(state.llama)
        XCTAssertFalse(state.llama.isConnected)
    }

    @MainActor
    func testTheAccountNameIsRecordedOnlyWhenNoOwnerIsConfigured() {
        XCTAssertEqual(AppState.ownerNameToRecord(configured: nil, accountName: " Ada Lovelace "), "Ada Lovelace")
        XCTAssertNil(AppState.ownerNameToRecord(configured: "Ada", accountName: "Ada Lovelace"))
        XCTAssertNil(AppState.ownerNameToRecord(configured: nil, accountName: "  "))
    }

    func testStatusSummaryMapping() {
        let state = AppState()

        XCTAssertEqual(state.statusSummary, "Stopped")
        XCTAssertEqual(state.statusColor, .secondary)
    }

    @MainActor
    func testScheduledMaintenanceDefaultInterval() {
        let state = AppState()
        XCTAssertGreaterThan(state.scheduledMaintenanceInterval, 0)
    }

    @MainActor
    func testSaveLMStudioTokenValidation() {
        let state = AppState()

        // Empty token should set failure and proper output message
        let result = state.saveLMStudioToken("   ")
        XCTAssertFalse(result)
        XCTAssertEqual(state.lastCommandSucceeded, false)
        XCTAssertEqual(state.lastCommandOutput, "LM Studio API token must not be empty.")
    }

    @MainActor
    func testRemoveLMStudioTokenSetsMessage() {
        let state = AppState()
        state.removeLMStudioToken()

        XCTAssertEqual(state.lastCommandSucceeded, true)
        XCTAssertEqual(state.lastCommandOutput, "LM Studio API token removed from Keychain.")
        XCTAssertFalse(state.lmStudioTokenConfigured)
    }

    @MainActor
    func testRunOperationReportsItsOutput() async {
        let state = AppState()

        let result = await state.runOperation { _ in "default model = bge-m3" }

        XCTAssertTrue(result)
        XCTAssertEqual(state.lastCommandSucceeded, true)
        XCTAssertEqual(state.lastCommandOutput, "default model = bge-m3")
        XCTAssertEqual(state.garage.logs.last?.text, "default model = bge-m3")
    }

    @MainActor
    func testRunOperationReportsTheServerError() async {
        let state = AppState()

        let result = await state.runOperation { _ in
            throw GarageGRPCError.rpcFailed("/nowhere does not exist")
        }

        XCTAssertFalse(result)
        XCTAssertEqual(state.lastCommandSucceeded, false)
        XCTAssertEqual(state.lastCommandOutput, "/nowhere does not exist")
    }

    @MainActor
    func testOperationNeedingTheServiceFailsWhileTheDatabaseIsOffline() async {
        let state = AppState()

        let result = await state.runOperation { try await $0.syncSources().message }

        XCTAssertFalse(result)
        XCTAssertEqual(state.lastCommandOutput, GarageGRPCError.databaseNotOnline.localizedDescription)
    }

    @MainActor
    func testVolumeAccessIntegration() {
        let mockStore = MockVolumeBookmarkStore()
        let mockFS = MockFileSystemAccessor()
        mockFS.readablePaths = ["/", "/System", "/Library", "/Applications", "/Users", "/Volumes"]
        mockFS.directoryContents = [URL(fileURLWithPath: "/System")]

        let volumeService = VolumeAccessService(bookmarkStore: mockStore, fileSystem: mockFS)
        let state = AppState(llama: LlamaService(), volumeAccess: volumeService)

        let testResult = state.testVolumeAccess()
        XCTAssertTrue(testResult.isAccessible)
        XCTAssertEqual(state.lastCommandSucceeded, true)
        XCTAssertTrue(state.lastCommandOutput.contains("Full volume access verified"))

        state.revokeVolumeAccess()
        XCTAssertEqual(state.lastCommandSucceeded, true)
        XCTAssertEqual(state.lastCommandOutput, "Volume access revoked and saved bookmark cleared.")
        XCTAssertEqual(state.volumeAccess.status, .notConfigured)
    }

    @MainActor
    func testModelDownloadTaskInfoWithModelId() {
        let task = DownloadTaskInfo(
            url: "https://example.com/bge-m3.gguf",
            filename: "bge-m3.gguf",
            destinationPath: "/tmp/bge-m3.gguf",
            modelId: "BAAI/bge-m3"
        )
        XCTAssertEqual(task.modelId, "BAAI/bge-m3")
        XCTAssertEqual(task.filename, "bge-m3.gguf")
        XCTAssertEqual(task.status, .queued)
    }

    @MainActor
    func testRegisteredSourcesInitialAndFetch() async {
        let state = AppState()
        XCTAssertTrue(state.registeredSources.isEmpty)
        XCTAssertFalse(state.isFetchingSources)

        await state.fetchRegisteredSources()
        // Should complete without error and update isFetchingSources to false
        XCTAssertFalse(state.isFetchingSources)
    }

    @MainActor
    func testPresetModelsComeFromTheCatalog() {
        // The presets are whatever models.json the loader finds; there is no hand-written list
        // behind it, so without a catalog (as in this test bundle) the app offers none.
        let state = AppState()
        let catalog = GarageConfigLoader.loadModelPresets()
        XCTAssertEqual(state.presetModels.map(\.slug), catalog.map(\.slug))
        XCTAssertEqual(state.factDistilPresets.map(\.slug), GarageConfigLoader.loadFactDistilPresets().map(\.slug))
        if !catalog.isEmpty {
            XCTAssertTrue(state.presetModels.contains { $0.slug == "bge-m3" })
            XCTAssertTrue(state.presetModels.contains { $0.slug == "nomic-embed-text" })
        }
    }

    @MainActor
    func testADatabaseResetIsNotBeingFinishedAtLaunch() {
        let state = AppState()
        XCTAssertFalse(state.isFinishingDatabaseReset)
        XCTAssertNil(state.databaseResetOutcome)
        XCTAssertTrue(AppState.databaseResetInProgressMessage.hasPrefix("Finishing the database reset"))
    }

    @MainActor
    func testVolumeAccessPassesSourcePaths() {
        let mockStore = MockVolumeBookmarkStore()
        let mockFS = MockFileSystemAccessor()
        let sourcePath = "/Users/test/Dropbox"
        mockFS.readablePaths = ["/", "/System", "/Library", "/Applications", "/Users", "/Volumes", sourcePath]
        mockFS.directoryContents = [URL(fileURLWithPath: "\(sourcePath)/file1.txt")]

        let volumeService = VolumeAccessService(bookmarkStore: mockStore, fileSystem: mockFS)
        let state = AppState(llama: LlamaService(), volumeAccess: volumeService)

        let result = state.testVolumeAccess()
        XCTAssertTrue(result.isAccessible)
        XCTAssertEqual(state.lastCommandSucceeded, true)
    }

    @MainActor
    func testCopyDatabaseURLToClipboard() {
        let state = AppState()
        let result = state.copyDatabaseURLToClipboard()
        XCTAssertTrue(result)
        XCTAssertEqual(state.lastCommandSucceeded, true)
        XCTAssertTrue(state.lastCommandOutput.contains("Copied PostgreSQL connection URL to clipboard:"))
        let clipboardContent = NSPasteboard.general.string(forType: .string)
        XCTAssertTrue(clipboardContent?.starts(with: "postgresql://") == true)
    }

    @MainActor
    func testResetDatabaseStopsServicesButNeitherDeletesNorRelaunchesInTests() async {
        let state = AppState()
        XCTAssertEqual(state.postgres.status, .stopped)
        await state.resetDatabaseAndRelaunch()
        // Under XCTest the cluster is never deleted and the test host never relaunched.
        XCTAssertEqual(state.postgres.status, .stopped)
        XCTAssertFalse(state.isResettingDatabase)
        XCTAssertFalse(state.lastCommandOutput.isEmpty)
    }

    func testDatabaseResetMessageSaysHowManySourcesCameBack() {
        XCTAssertTrue(AppState.databaseResetMessage(registeredSourceCount: 0).contains("declares no sources"))
        XCTAssertTrue(AppState.databaseResetMessage(registeredSourceCount: 1).contains("The 1 source in garage.json"))
        XCTAssertTrue(AppState.databaseResetMessage(registeredSourceCount: 3).contains("The 3 sources in garage.json"))
    }

    func testDatabaseResetParentIsReadFromTheLaunchArguments() {
        XCTAssertEqual(AppState.databaseResetParent(in: ["GarageApp", GarageAppLaunch.databaseResetArgument, "4242"]), 4242)
        XCTAssertNil(AppState.databaseResetParent(in: ["GarageApp"]))
        XCTAssertNil(AppState.databaseResetParent(in: ["GarageApp", GarageAppLaunch.databaseResetArgument]))
        XCTAssertNil(AppState.databaseResetParent(in: ["GarageApp", GarageAppLaunch.databaseResetArgument, "zero"]))
        XCTAssertNil(AppState.databaseResetParent(in: ["GarageApp", GarageAppLaunch.databaseResetArgument, "0"]))
    }

    func testRelaunchArgumentsCarryTheResetParent() {
        XCTAssertEqual(
            AppState.relaunchArguments(parentPID: 4242, currentArguments: ["GarageApp"]),
            [GarageAppLaunch.databaseResetArgument, "4242"]
        )
    }

    func testRelaunchArgumentsForwardTheDataDirectoryOverride() {
        let arguments = AppState.relaunchArguments(
            parentPID: 4242,
            currentArguments: ["GarageApp", GarageAppLaunch.dataDirectoryArgument, "/tmp/garage-ui-test", "--other"]
        )
        XCTAssertEqual(arguments, [
            GarageAppLaunch.databaseResetArgument, "4242",
            GarageAppLaunch.dataDirectoryArgument, "/tmp/garage-ui-test",
        ])
    }

    func testRelaunchArgumentsCarryTheKeepSettingsChoice() {
        let arguments = AppState.relaunchArguments(
            parentPID: 4242,
            currentArguments: ["GarageApp", GarageAppLaunch.dataDirectoryArgument, "/tmp/garage-ui-test"],
            keepingSettings: true
        )
        XCTAssertEqual(arguments, [
            GarageAppLaunch.databaseResetArgument, "4242", GarageAppLaunch.keepSettingsArgument,
            GarageAppLaunch.dataDirectoryArgument, "/tmp/garage-ui-test",
        ])
        XCTAssertEqual(AppState.databaseResetParent(in: ["GarageApp"] + arguments), 4242)
    }

    func testStartingOverSetsGarageJSONAsideWithoutDeletingIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("garage.json")
        try Data(#"{"sources": []}"#.utf8).write(to: config)

        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let setAside = try XCTUnwrap(AppState.setAsideConfigForReset(in: directory, now: now))

        XCTAssertFalse(FileManager.default.fileExists(atPath: config.path))
        XCTAssertTrue(setAside.lastPathComponent.hasPrefix("garage.json.before-reset-"))
        XCTAssertEqual(try String(contentsOf: setAside, encoding: .utf8), #"{"sources": []}"#)
        XCTAssertNil(try AppState.setAsideConfigForReset(in: directory, now: now), "no garage.json, nothing to move")
    }

    func testTheResetMessageNamesARestoredDefaultModel() {
        let message = AppState.databaseResetMessage(registeredSourceCount: 2, restoredModel: "bge-m3")
        XCTAssertTrue(message.contains("The 2 sources in garage.json"))
        XCTAssertTrue(message.contains("bge-m3, was registered again"))
    }

    func testRelaunchArgumentsDoNotForwardAnEarlierResetParent() {
        let arguments = AppState.relaunchArguments(
            parentPID: 7,
            currentArguments: ["GarageApp", GarageAppLaunch.databaseResetArgument, "4242"]
        )
        XCTAssertEqual(arguments, [GarageAppLaunch.databaseResetArgument, "7"])
    }

    func testWaitForExitReturnsAtOnceForAProcessThatIsGone() async {
        let started = Date()
        // Above macOS's pid ceiling, so no such process.
        await AppState.waitForExit(of: 999_999, timeout: 5)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testWaitForExitGivesUpAtTheTimeout() async {
        let started = Date()
        await AppState.waitForExit(of: getpid(), timeout: 0.3)
        let waited = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(waited, 0.3)
        XCTAssertLessThan(waited, 2)
    }

    @MainActor
    func testAppStateTCCConvenienceMethods() {
        let mockStore = MockVolumeBookmarkStore()
        let mockFS = MockFileSystemAccessor()
        mockFS.readablePaths = ["/", "/System", "/Library", "/Applications", "/Users", "/Volumes"]
        mockFS.directoryContents = [URL(fileURLWithPath: "/System")]

        let volumeService = VolumeAccessService(bookmarkStore: mockStore, fileSystem: mockFS)
        let state = AppState(llama: LlamaService(), volumeAccess: volumeService)

        // Test openPrivacySettings invocation (does not crash or throw)
        state.openPrivacySettings(for: .messages)
        state.openPrivacySettings(for: .mail)
        state.openPrivacySettings(for: .fullDiskAccess)
    }

    @MainActor
    func testMigrationInitialStateAndMethods() async {
        let state = AppState()
        XCTAssertFalse(state.isApplyingMigrations)
        XCTAssertTrue(state.postgres.pendingMigrations.isEmpty)

        state.checkPendingMigrations()
        XCTAssertTrue(state.postgres.pendingMigrations.isEmpty)

        // Calling applyMigrations when postgres is stopped should return early without hanging or crashing
        await state.applyMigrations()
        XCTAssertFalse(state.isApplyingMigrations)
    }

    @MainActor
    func testBackfillExecutionAndLogs() async {
        let state = AppState()
        XCTAssertFalse(state.backfill.isRunning)
        XCTAssertTrue(state.backfill.logs.isEmpty)

        // With the database offline the gRPC service cannot start, so the run fails and says why.
        let succeeded = await state.runBackfill(model: "test-model")
        XCTAssertFalse(succeeded)
        XCTAssertFalse(state.backfill.isRunning)
        XCTAssertFalse(state.backfill.logs.isEmpty)

        // Clear logs for backfill
        state.clearLogs(for: "Backfill")
        XCTAssertTrue(state.backfill.logs.isEmpty)
    }

    @MainActor
    func testCombinedIngestLogsCombinesAndOrdersLogs() {
        let state = AppState()

        let now = Date()
        let line1 = LogLine(date: now.addingTimeInterval(-10), stream: .stdout, text: "XPC Ingest Line 1", source: "ingest-xpc")
        let line2 = LogLine(date: now.addingTimeInterval(-5), stream: .stdout, text: "XPC Ingest Line 2", source: "ingest-xpc")
        let line3 = LogLine(date: now, stream: .stdout, text: "XPC Ingest Line 3", source: "ingest-xpc")

        state.ingestService.appendLog(line1.text)
        state.ingestService.appendLog(line2.text)
        state.ingestService.appendLog(line3.text)

        let combined = state.combinedIngestLogs
        XCTAssertEqual(combined.count, 3)
        XCTAssertTrue(combined.contains { $0.text == "XPC Ingest Line 1" })
        XCTAssertTrue(combined.contains { $0.text == "XPC Ingest Line 2" })
        XCTAssertTrue(combined.contains { $0.text == "XPC Ingest Line 3" })

        // Check chronological ordering
        for i in 0..<(combined.count - 1) {
            XCTAssertLessThanOrEqual(combined[i].date, combined[i + 1].date)
        }
    }

    @MainActor
    func testClearLogsForIngestClearsStream() {
        let state = AppState()

        state.ingestService.appendLog("XPC log")

        XCTAssertFalse(state.ingestService.logs.isEmpty)
        XCTAssertFalse(state.combinedIngestLogs.isEmpty)

        state.clearLogs(for: "Ingest")

        XCTAssertTrue(state.ingestService.logs.isEmpty)
        XCTAssertTrue(state.combinedIngestLogs.isEmpty)
    }

    @MainActor
    func testXPCServiceManagerLogsAndClear() async {
        let state = AppState()

        state.xpcServices.appendLog("Test XPC log line", source: "llama-xpc", level: .info)
        XCTAssertEqual(state.xpcServices.logs.count, 1)
        XCTAssertEqual(state.xpcServices.logs.first?.text, "Test XPC log line")
        XCTAssertEqual(state.xpcServices.logs.first?.source, "llama-xpc")

        state.clearLogs(for: "XPC Services")
        XCTAssertTrue(state.xpcServices.logs.isEmpty)
    }

    @MainActor
    func testCombinedIngestProgressUsesPriorScanTotalsAcrossSources() {
        let state = AppState()

        let source1 = RegisteredSource(slug: "source-a", root: "/tmp/a", expectedElements: 100)
        let source2 = RegisteredSource(slug: "source-b", root: "/tmp/b", expectedElements: 300)
        let source3 = RegisteredSource(slug: "source-c", root: "/tmp/c", expectedElements: 600)
        state.registeredSources = [source1, source2, source3]
        state.corpusStats.totalExpectedElements = 1000

        state.ingestService.setPendingSources(["source-a", "source-b", "source-c"])
        XCTAssertEqual(state.combinedIngestTotalExpected, 1000)
        XCTAssertEqual(state.combinedIngestProcessedCount, 0)
        XCTAssertEqual(state.combinedIngestProgressFraction, 0.0)
        XCTAssertEqual(state.combinedIngestProgressPercent, "0%")

        // Source 1 starts and reports 50 items seen
        state.ingestService.markSourceActive("source-a")
        let prog1Active = IngestProgressUpdate(
            source: "source-a",
            phase: "ingest",
            seen: 50,
            totalItems: 100,
            indexed: 45,
            skipped: 5,
            failed: 0,
            placeholders: 0,
            chunksWritten: 90,
            itemType: "documents",
            progress: 0.5,
            message: "Ingesting source-a: 50/100",
            error: nil,
            currentItem: "file1.txt"
        )
        state.ingestService.handleProgress(prog1Active)

        XCTAssertEqual(state.combinedIngestTotalExpected, 1000)
        XCTAssertEqual(state.combinedIngestProcessedCount, 50)
        XCTAssertEqual(state.combinedIngestProgressFraction, 0.05, accuracy: 0.001)
        XCTAssertEqual(state.combinedIngestProgressPercent, "5%")
        XCTAssertEqual(state.combinedIngestIndexedCount, 45)
        XCTAssertEqual(state.combinedIngestSkippedCount, 5)

        // Source 1 completes
        let prog1Complete = IngestProgressUpdate(
            source: "source-a",
            phase: "complete",
            seen: 100,
            totalItems: 100,
            indexed: 95,
            skipped: 5,
            failed: 0,
            placeholders: 0,
            chunksWritten: 190,
            itemType: "documents",
            progress: 1.0,
            message: "Completed source-a",
            error: nil,
            currentItem: nil
        )
        state.ingestService.handleProgress(prog1Complete)

        // Source 2 starts and reports 150 items seen
        state.ingestService.markSourceActive("source-b")
        let prog2Active = IngestProgressUpdate(
            source: "source-b",
            phase: "ingest",
            seen: 150,
            totalItems: 300,
            indexed: 150,
            skipped: 0,
            failed: 0,
            placeholders: 0,
            chunksWritten: 300,
            itemType: "documents",
            progress: 0.5,
            message: "Ingesting source-b: 150/300",
            error: nil,
            currentItem: "file2.txt"
        )
        state.ingestService.handleProgress(prog2Active)

        // Combined should be 100 (from completed source-a) + 150 (from active source-b) = 250 / 1000 = 25%
        XCTAssertEqual(state.combinedIngestTotalExpected, 1000)
        XCTAssertEqual(state.combinedIngestProcessedCount, 250)
        XCTAssertEqual(state.combinedIngestProgressFraction, 0.25, accuracy: 0.001)
        XCTAssertEqual(state.combinedIngestProgressPercent, "25%")
        XCTAssertEqual(state.combinedIngestIndexedCount, 245)

        // Source 2 completes
        let prog2Complete = IngestProgressUpdate(
            source: "source-b",
            phase: "complete",
            seen: 300,
            totalItems: 300,
            indexed: 300,
            skipped: 0,
            failed: 0,
            placeholders: 0,
            chunksWritten: 600,
            itemType: "documents",
            progress: 1.0,
            message: "Completed source-b",
            error: nil,
            currentItem: nil
        )
        state.ingestService.handleProgress(prog2Complete)

        // Source 3 starts and reports 600 items seen
        state.ingestService.markSourceActive("source-c")
        let prog3Complete = IngestProgressUpdate(
            source: "source-c",
            phase: "complete",
            seen: 600,
            totalItems: 600,
            indexed: 590,
            skipped: 10,
            failed: 0,
            placeholders: 0,
            chunksWritten: 1200,
            itemType: "documents",
            progress: 1.0,
            message: "Completed source-c",
            error: nil,
            currentItem: nil
        )
        state.ingestService.handleProgress(prog3Complete)

        XCTAssertEqual(state.combinedIngestTotalExpected, 1000)
        XCTAssertEqual(state.combinedIngestProcessedCount, 1000)
        XCTAssertEqual(state.combinedIngestProgressFraction, 1.0, accuracy: 0.001)
        XCTAssertEqual(state.combinedIngestProgressPercent, "100%")
        XCTAssertEqual(state.combinedIngestIndexedCount, 985)
        XCTAssertEqual(state.combinedIngestSkippedCount, 15)
    }

    @MainActor
    func testCombinedIngestProgressSingleSourceWithPriorScan() {
        let state = AppState()

        let source = RegisteredSource(slug: "manual-docs", root: "/tmp/docs", expectedElements: 500)
        state.registeredSources = [source]
        state.corpusStats.totalExpectedElements = 500

        let prog = IngestProgressUpdate(
            source: "manual-docs",
            phase: "ingest",
            seen: 250,
            totalItems: 500,
            indexed: 240,
            skipped: 10,
            failed: 0,
            placeholders: 0,
            chunksWritten: 480,
            itemType: "documents",
            progress: 0.5,
            message: "Ingesting manual-docs: 250/500",
            error: nil,
            currentItem: "chapter1.pdf"
        )
        state.ingestService.handleProgress(prog)

        XCTAssertEqual(state.combinedIngestTotalExpected, 500)
        XCTAssertEqual(state.combinedIngestProcessedCount, 250)
        XCTAssertEqual(state.combinedIngestProgressFraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(state.combinedIngestProgressPercent, "50%")
    }

    @MainActor
    func testCombinedIngestProgressFallbackWhenNoPriorScan() {
        let state = AppState()

        let source = RegisteredSource(slug: "unscanned", root: "/tmp/unscanned", expectedElements: 0)
        state.registeredSources = [source]
        state.corpusStats.totalExpectedElements = 0

        let prog = IngestProgressUpdate(
            source: "unscanned",
            phase: "ingest",
            seen: 20,
            totalItems: 40,
            indexed: 20,
            skipped: 0,
            failed: 0,
            placeholders: 0,
            chunksWritten: 40,
            itemType: "documents",
            progress: 0.5,
            message: "Ingesting unscanned: 20/40",
            error: nil,
            currentItem: "file.txt"
        )
        state.ingestService.handleProgress(prog)

        XCTAssertEqual(state.combinedIngestTotalExpected, 40)
        XCTAssertEqual(state.combinedIngestProcessedCount, 20)
        XCTAssertEqual(state.combinedIngestProgressFraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(state.combinedIngestProgressPercent, "50%")
    }

    @MainActor
    func testSingleSourceProgressDiffersFromOverallProgressBar() {
        let state = AppState()

        let source1 = RegisteredSource(slug: "source-a", root: "/tmp/a", expectedElements: 100)
        let source2 = RegisteredSource(slug: "source-b", root: "/tmp/b", expectedElements: 300)
        let source3 = RegisteredSource(slug: "source-c", root: "/tmp/c", expectedElements: 600)
        state.registeredSources = [source1, source2, source3]
        state.corpusStats.totalExpectedElements = 1000

        state.ingestService.setPendingSources(["source-a", "source-b", "source-c"])

        // Source 1 starts and reports 50 of its 100 items seen
        state.ingestService.markSourceActive("source-a")
        let prog1 = IngestProgressUpdate(
            source: "source-a",
            phase: "ingest",
            seen: 50,
            totalItems: 100,
            indexed: 45,
            skipped: 5,
            failed: 0,
            placeholders: 0,
            chunksWritten: 90,
            itemType: "documents",
            progress: 0.5,
            message: "Ingesting source-a: 50/100",
            error: nil,
            currentItem: "file1.txt"
        )
        state.ingestService.handleProgress(prog1)

        // Overall progress: 50 / 1000 = 5%
        XCTAssertEqual(state.combinedIngestTotalExpected, 1000)
        XCTAssertEqual(state.combinedIngestProcessedCount, 50)
        XCTAssertEqual(state.combinedIngestProgressFraction, 0.05, accuracy: 0.001)
        XCTAssertEqual(state.combinedIngestProgressPercent, "5%")

        // Single source progress for source-a: 50 / 100 = 50%
        XCTAssertEqual(state.sourceTotalExpected(for: "source-a"), 100)
        XCTAssertEqual(state.sourceProcessedCount(for: "source-a"), 50)
        XCTAssertEqual(state.sourceProgressFraction(for: "source-a"), 0.5, accuracy: 0.001)
        XCTAssertEqual(state.sourceProgressPercent(for: "source-a"), "50%")

        // Single source progress for pending source-b: 0 / 300 = 0%
        XCTAssertEqual(state.sourceTotalExpected(for: "source-b"), 300)
        XCTAssertEqual(state.sourceProcessedCount(for: "source-b"), 0)
        XCTAssertEqual(state.sourceProgressFraction(for: "source-b"), 0.0)
        XCTAssertEqual(state.sourceProgressPercent(for: "source-b"), "0%")
    }

    @MainActor
    func testScheduledMaintenanceDefaults() {
        let state = AppState()
        XCTAssertTrue(state.scheduledMaintenanceEnabled)
        XCTAssertEqual(state.scheduledMaintenanceInterval, 3600)
    }

    @MainActor
    func testScanSourcesSkippedWhenIngesting() async {
        let state = AppState()
        state.setIngestingForTesting(true)

        let scanResult = await state.scanSources()
        XCTAssertFalse(scanResult)
        XCTAssertNil(state.scanProgress, "a scan that never ran leaves no progress behind")
    }

    @MainActor
    func testScanSkippedWhenIngestingSaysWhy() async {
        let state = AppState()
        state.setIngestingForTesting(true)

        let result = await state.scanSources(source: "*")
        XCTAssertFalse(result)
        XCTAssertEqual(state.lastCommandSucceeded, false)
        XCTAssertEqual(state.lastCommandOutput, "Cannot scan while ingestion is in progress.")
    }

    // MARK: - Scans on their own runner

    @MainActor
    func testIsScanningTracksOnlyTheScanRunner() {
        let state = AppState()
        state.garage.isRunning = true
        XCTAssertFalse(state.isScanning, "an ordinary operation on the general runner is not a scan")

        state.scanner.isRunning = true
        XCTAssertTrue(state.isScanning)
    }

    @MainActor
    func testQuickOperationsRunWhileAScanDoes() async {
        let state = AppState()
        state.scanner.isRunning = true

        let succeeded = await state.runOperation { _ in "removed source notes" }

        XCTAssertTrue(succeeded, "a scan turned away an ordinary operation: \(state.lastCommandOutput)")
        XCTAssertEqual(state.lastCommandOutput, "removed source notes")
    }

    @MainActor
    func testASecondScanIsTurnedAway() async {
        let state = AppState()
        state.scanner.isRunning = true

        let result = await state.scanSources(source: "*")

        XCTAssertFalse(result)
        XCTAssertEqual(state.lastCommandOutput, "A scan is already running.")
    }

    @MainActor
    func testEverySourceIsBusyDuringAnIngestOfAll() {
        let state = AppState()
        XCTAssertFalse(state.isBusy(source: "notes"))

        state.setIngestingForTesting(true)

        XCTAssertTrue(state.isBusy(source: "notes"))
        XCTAssertTrue(state.isBusy(source: "documents"))
    }

    @MainActor
    func testAScanOfAllLeavesANewSourceFree() {
        let state = AppState()
        state.setScanningForTesting(source: "*", slugs: ["notes", "documents"])
        defer { state.setScanningForTesting(source: nil) }

        XCTAssertTrue(state.isBusy(source: "notes"))
        XCTAssertTrue(state.isBusy(source: "documents"))
        XCTAssertFalse(state.isBusy(source: "photos"))
    }

    @MainActor
    func testAnIngestOfAllLeavesANewSourceFree() {
        let state = AppState()
        state.setIngestingForTesting(true)
        state.ingestService.setPendingSources(["notes", "documents"])
        defer {
            state.ingestService.clearPendingSources()
            state.setIngestingForTesting(false)
        }

        XCTAssertTrue(state.isBusy(source: "notes"))
        XCTAssertFalse(state.isBusy(source: "photos"))
    }

    @MainActor
    func testASourceAddedDuringARunIsQueuedOnce() {
        let state = AppState()
        let wasEnabled = state.scheduledMaintenanceEnabled
        state.scheduledMaintenanceEnabled = true
        defer { state.scheduledMaintenanceEnabled = wasEnabled }

        state.queueSourceScan("photos")
        state.queueSourceScan("photos")
        state.queueSourceScan("mail")

        XCTAssertEqual(state.sourcesAwaitingScan, ["photos", "mail"])
    }

    @MainActor
    func testNothingIsQueuedWithoutAutomaticMaintenance() {
        let state = AppState()
        let wasEnabled = state.scheduledMaintenanceEnabled
        state.scheduledMaintenanceEnabled = false
        defer { state.scheduledMaintenanceEnabled = wasEnabled }

        state.queueSourceScan("photos")

        XCTAssertTrue(state.sourcesAwaitingScan.isEmpty)
    }

    // MARK: - Queue and cancel

    @MainActor
    func testCancelAllEmptiesEveryQueue() {
        let state = AppState()
        state.scanner.isRunning = true
        state.setQueuesForTesting(ingest: ["notes", "mail"], awaitingScan: ["photos"])

        state.cancelAll()

        XCTAssertTrue(state.isCancellingAll)
        XCTAssertEqual(state.ingestQueue, [])
        XCTAssertEqual(state.sourcesAwaitingScan, [])
        XCTAssertFalse(state.isQueued(source: "mail"))
    }

    @MainActor
    func testCancelAllWithNothingRunningDoesNothing() {
        let state = AppState()

        state.cancelAll()

        XCTAssertFalse(state.isCancellingAll, "nothing ran, so nothing waits for the cancel to finish")
    }

    @MainActor
    func testCancellingAQueuedSourceTakesOnlyItOut() async {
        let state = AppState()
        state.setQueuesForTesting(ingest: ["notes", "mail", "photos"], awaitingScan: ["mail"])

        await state.cancel(source: "mail")

        XCTAssertEqual(state.ingestQueue, ["notes", "photos"])
        XCTAssertEqual(state.sourcesAwaitingScan, [])
        XCTAssertFalse(state.isCancellingAll, "cancelling one source leaves the rest of the run going")
    }

    @MainActor
    func testCancellingOneSourceDuringAScanOfAllLeavesTheOthers() async {
        let state = AppState()
        state.setScanningForTesting(source: "*", slugs: ["notes", "mail"])
        XCTAssertTrue(state.isPending(source: "mail"))

        await state.cancel(source: "mail")

        XCTAssertFalse(state.isPending(source: "mail"))
        XCTAssertFalse(state.isBusy(source: "mail"))
        XCTAssertTrue(state.isPending(source: "notes"))
    }

    @MainActor
    func testASourceAnIngestOfAllHasFinishedIsNotPendingAndCanLeaveTheRun() async {
        let state = AppState()
        state.setIngestingForTesting(true)
        state.ingestService.setPendingSources(["notes", "mail"])
        state.ingestService.markSourceActive("notes")
        state.ingestService.markSourceActive("mail")
        XCTAssertFalse(state.isPending(source: "notes"), "notes is done; mail is the one ingesting")
        XCTAssertTrue(state.isBusy(source: "notes"))

        await state.cancel(source: "notes")

        XCTAssertFalse(state.isBusy(source: "notes"), "a finished source can be removed while the run goes on")
        XCTAssertTrue(state.isBusy(source: "mail"))
        XCTAssertTrue(state.isPending(source: "mail"))
    }

    @MainActor
    func testAnIngestOfAllStaysCancellableBetweenSources() {
        let state = AppState()
        state.setIngestingAllForTesting(true)
        XCTAssertFalse(state.isIngesting, "between sources no single ingest runs")

        XCTAssertTrue(state.hasCancellableWork, "Cancel All stays up while the run goes on to its next source")
    }

    @MainActor
    func testAQueuedSourceKeepsStopUpAndStopEmptiesTheQueue() {
        let state = AppState()
        // A Scan & Ingest of one source between its scan and its ingest: nothing runs, the source waits.
        state.setQueuesForTesting(ingest: ["notes"])
        XCTAssertTrue(state.hasCancellableWork, "Stop went away between the scan and the ingest")

        state.cancelAll()

        XCTAssertTrue(state.ingestQueue.isEmpty, "Stop left the source queued, so its ingest would still start")
    }

    @MainActor
    func testAScanAndIngestThatCannotScanLeavesNothingQueued() async {
        let state = AppState()
        XCTAssertEqual(state.postgres.status, .stopped)

        let result = await state.scanAndIngestSource(slug: "notes")

        XCTAssertFalse(result)
        XCTAssertTrue(state.ingestQueue.isEmpty)
        XCTAssertFalse(state.isIngesting, "the ingest ran although the scan did not")
    }

    @MainActor
    func testAScanAndIngestOfAQueuedSourceIsTurnedAway() async {
        let state = AppState()
        state.setQueuesForTesting(ingest: ["notes"])

        let result = await state.scanAndIngestSource(slug: "notes")

        XCTAssertFalse(result)
        XCTAssertEqual(state.ingestQueue, ["notes"], "the second run took the first run's place in the queue")
    }

    @MainActor
    func testASecondIngestOfAllIsTurnedAway() async {
        let state = AppState()
        state.setIngestingAllForTesting(true)

        let result = await state.ingestAllSources()

        XCTAssertFalse(result)
        XCTAssertEqual(state.lastCommandOutput, "An ingest of every source is already running.")
    }

    // MARK: - Update Everything and updates at launch

    @MainActor
    func testUpdateEverythingDoesNothingWhileTheDatabaseIsDown() async {
        let state = AppState()
        XCTAssertEqual(state.postgres.status, .stopped)

        await state.updateEverything()

        XCTAssertFalse(state.isUpdatingEverything)
        XCTAssertFalse(state.isScanning, "Update Everything scanned with the database down")
        XCTAssertFalse(state.backfill.isRunning)
        XCTAssertFalse(state.enrichFacts.isRunning)
        XCTAssertNil(state.lastCommandSucceeded, "a run that never started reports no outcome")
    }

    @MainActor
    func testUpdateEverythingIsNotUnderWayAtLaunch() {
        let state = AppState()
        XCTAssertFalse(state.isUpdatingEverything)
        XCTAssertFalse(state.hasCancellableWork)
    }

    @MainActor
    func testUpdatesAtLaunchFollowTheSavedPreference() {
        let state = AppState()
        XCTAssertEqual(state.maintenanceRunsAtLaunch, UserDefaults.standard.bool(forKey: "scheduledMaintenanceRunsAtLaunch"))
    }

    @MainActor
    func testUpdatesAtLaunchWaitForTheDatabase() async {
        let state = AppState()
        // Called before any launch and with the database down, it must neither start a run nor fail.
        state.runMaintenanceAtLaunchIfEnabled()
        // The run is gated on the backend and the helpers too; give a wrongly scheduled one time to show.
        try? await Task.sleep(nanoseconds: 1_200_000_000)

        XCTAssertFalse(state.isScanning)
        XCTAssertFalse(state.isUpdatingEverything)
        XCTAssertFalse(state.hasCancellableWork)
        XCTAssertFalse(state.isMaintenanceRunning, "a launch run started with the database and the backend down")
    }
}

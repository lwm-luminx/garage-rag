import XCTest
import SwiftUI
import AppKit
@testable import GarageApp
import PythonXPCService

final class FirstRunTests: XCTestCase {

    // MARK: - Steps

    func testStepsAreOrderedAndLinked() {
        XCTAssertEqual(FirstRunStep.allCases, [.settingUp, .selectData, .selectModels, .setupAgent])
        XCTAssertEqual(FirstRunStep.settingUp.next, .selectData)
        XCTAssertEqual(FirstRunStep.selectData.next, .selectModels)
        XCTAssertEqual(FirstRunStep.selectModels.next, .setupAgent)
        XCTAssertNil(FirstRunStep.setupAgent.next)
        XCTAssertNil(FirstRunStep.settingUp.previous)
        XCTAssertEqual(FirstRunStep.setupAgent.previous, .selectModels)
        XCTAssertLessThan(FirstRunStep.settingUp, FirstRunStep.setupAgent)
    }

    func testStepTitlesMatchTheFlow() {
        XCTAssertEqual(FirstRunStep.settingUp.title, "Setting things up")
        XCTAssertEqual(FirstRunStep.selectData.title, "Select your data")
        XCTAssertEqual(FirstRunStep.selectModels.title, "Select your models")
        XCTAssertEqual(FirstRunStep.setupAgent.title, "Set up your assistant")
        for step in FirstRunStep.allCases {
            XCTAssertFalse(step.symbol.isEmpty)
        }
    }

    // MARK: - Readiness

    func testReadinessIsPendingWhileEverythingIsStopped() {
        let checks = FirstRunReadiness.checks(
            postgres: .stopped, pendingMigrations: [], isApplyingMigrations: false, grpc: .stopped, mcp: .stopped
        )
        XCTAssertEqual(checks.map(\.id), ["postgres", "schema", "grpc", "mcp"])
        XCTAssertTrue(checks.allSatisfy { $0.state == .pending })
        XCTAssertFalse(FirstRunReadiness.isReady(checks))
        XCTAssertFalse(FirstRunReadiness.hasFailure(checks))
    }

    func testReadinessRequiresDatabaseSchemaAndGrpcButNotMcp() {
        let checks = FirstRunReadiness.checks(
            postgres: .running, pendingMigrations: [], isApplyingMigrations: false, grpc: .running, mcp: .stopped
        )
        XCTAssertTrue(FirstRunReadiness.isReady(checks), "MCP is optional on the first page")
        XCTAssertEqual(checks.first { $0.id == "mcp" }?.state, .inProgress)

        let withMcpFailure = FirstRunReadiness.checks(
            postgres: .running, pendingMigrations: [], isApplyingMigrations: false, grpc: .running, mcp: .failed("port in use")
        )
        XCTAssertTrue(FirstRunReadiness.isReady(withMcpFailure))
        XCTAssertTrue(FirstRunReadiness.hasFailure(withMcpFailure))
        XCTAssertFalse(FirstRunReadiness.hasBlockingFailure(withMcpFailure), "an MCP port clash must not trap the user on page one")
    }

    func testReadinessTracksPendingMigrations() {
        let pending = FirstRunReadiness.checks(
            postgres: .needsMigration, pendingMigrations: ["001.sql", "002.sql"], isApplyingMigrations: false, grpc: .stopped, mcp: .stopped
        )
        XCTAssertEqual(pending.first { $0.id == "postgres" }?.state, .inProgress)
        XCTAssertEqual(pending.first { $0.id == "schema" }?.state, .pending)
        XCTAssertTrue(pending.first { $0.id == "schema" }?.detail.contains("2 pending migrations") ?? false)
        XCTAssertFalse(FirstRunReadiness.isReady(pending))

        let applying = FirstRunReadiness.checks(
            postgres: .running, pendingMigrations: ["001.sql"], isApplyingMigrations: true, grpc: .running, mcp: .running
        )
        XCTAssertEqual(applying.first { $0.id == "schema" }?.state, .inProgress)
        XCTAssertFalse(FirstRunReadiness.isReady(applying))
    }

    func testReadinessSurfacesPostgresFailure() {
        let checks = FirstRunReadiness.checks(
            postgres: .failed("initdb failed"), pendingMigrations: [], isApplyingMigrations: false, grpc: .stopped, mcp: .stopped
        )
        XCTAssertEqual(checks.first { $0.id == "postgres" }?.state, .failed("initdb failed"))
        XCTAssertEqual(checks.first { $0.id == "schema" }?.state, .failed("initdb failed"))
        XCTAssertTrue(FirstRunReadiness.hasFailure(checks))
        XCTAssertTrue(FirstRunReadiness.hasBlockingFailure(checks))
        XCTAssertFalse(FirstRunReadiness.isReady(checks))
    }

    // MARK: - Source templates

    func testBuiltInTemplatesResolveAvailabilityAgainstHome() {
        let home = URL(fileURLWithPath: "/Users/tester")
        let present: Set<String> = ["/Users/tester/Documents", "/Users/tester/Library/Messages", "/Users/tester/Library/Mail"]
        // Mail's folder is there but closed (no Full Disk Access); Messages can be read.
        let readable: Set<String> = ["/Users/tester/Library/Messages"]
        let templates = FirstRunSourceTemplate.builtIn(
            home: home,
            exists: { present.contains($0) },
            readable: { readable.contains($0) }
        )

        XCTAssertFalse(templates.isEmpty)
        XCTAssertTrue(templates.allSatisfy { !$0.isCustom })

        let documents = templates.first { $0.id == "documents" }
        XCTAssertEqual(documents?.isAvailable, true)
        XCTAssertEqual(documents?.root, "~/Documents")
        XCTAssertEqual(documents?.corpusClass, "document")

        let dropbox = templates.first { $0.id == "dropbox" }
        XCTAssertEqual(dropbox?.isAvailable, false)

        let messages = templates.first { $0.id == "apple-sms" }
        XCTAssertEqual(messages?.isAvailable, true)
        XCTAssertEqual(messages?.kind, "sqlite")
        XCTAssertEqual(messages?.corpusClass, "communication")
        XCTAssertEqual(messages?.trust, "received")
        XCTAssertEqual(messages?.isCommunication, true)
        XCTAssertEqual(messages?.needsFullDiskAccess, false)

        let mail = templates.first { $0.id == "apple-mail" }
        XCTAssertEqual(mail?.isAvailable, false, "a Mail folder whose contents can't be listed can't be picked")
        XCTAssertEqual(mail?.needsFullDiskAccess, true)
        XCTAssertEqual(documents?.needsFullDiskAccess, false)
    }

    func testTheSandboxBeforeAnyGrantAssumesEveryLocationIsThere() {
        let templates = FirstRunSourceTemplate.builtIn(
            home: URL(fileURLWithPath: "/Users/tester"),
            assumeAvailable: true,
            exists: { _ in false },
            readable: { _ in false }
        )
        XCTAssertTrue(templates.allSatisfy(\.isAvailable))
        XCTAssertFalse(templates.contains(where: \.needsFullDiskAccess))
    }

    func testTemplateSlugsAndIDsAreUnique() {
        let templates = FirstRunSourceTemplate.builtIn(home: URL(fileURLWithPath: "/Users/tester"), exists: { _ in true }, readable: { _ in true })
        XCTAssertEqual(Set(templates.map(\.slug)).count, templates.count)
        XCTAssertEqual(Set(templates.map(\.id)).count, templates.count)
    }

    func testSharedTemplatesAgreeWithTheSourcePresets() {
        let templates = FirstRunSourceTemplate.builtIn(home: URL(fileURLWithPath: "/Users/tester"), exists: { _ in true }, readable: { _ in true })
        for preset in [SourcePreset.documents, .desktop, .downloads, .dropbox, .messages, .mail] {
            let template = templates.first { $0.id == preset.id }
            XCTAssertNotNil(template, preset.id)
            XCTAssertEqual(template?.spec, preset.spec, preset.id)
            XCTAssertEqual(template?.title, preset.title, preset.id)
        }
    }

    func testAbsoluteRootsAreCheckedAsTheyAre() {
        // The Dropbox folder info.json names may be on another volume; `~/…` stays home-relative.
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        XCTAssertEqual(FirstRunSourceTemplate.resolvedPath("/Volumes/Data/Dropbox", home: home), "/Volumes/Data/Dropbox")
        XCTAssertEqual(FirstRunSourceTemplate.resolvedPath("~/Documents", home: home), "/Users/tester/Documents")
        XCTAssertEqual(FirstRunSourceTemplate.resolvedPath("~", home: home), "/Users/tester")

        var checked: [String] = []
        let templates = FirstRunSourceTemplate.builtIn(home: home, exists: { checked.append($0); return true }, readable: { _ in true })
        let dropbox = templates.first { $0.id == "dropbox" }
        XCTAssertNotNil(dropbox)
        XCTAssertTrue(checked.contains(FirstRunSourceTemplate.resolvedPath(SourcePreset.dropbox.spec.root, home: home)))
        XCTAssertFalse(checked.contains { $0.hasPrefix("/Users/tester//") || $0.contains("/Users/tester/Volumes") })
    }

    func testSpecMatchesTheAddSourceRPC() {
        let template = FirstRunSourceTemplate(
            id: "documents", title: "Documents", subtitle: "", symbol: "doc", slug: "documents", root: "~/Documents",
            kind: "filesystem", corpusClass: "document", trust: "authored", isAvailable: true, isCustom: false
        )
        XCTAssertEqual(
            template.spec,
            SourceSpec(slug: "documents", root: "~/Documents", kind: "filesystem", corpusClass: "document", trust: "authored")
        )
    }

    func testFolderSlugs() {
        XCTAssertEqual(FirstRunSourceTemplate.slug(forFolderNamed: "My Notes (2024)"), "my-notes-2024")
        XCTAssertEqual(FirstRunSourceTemplate.slug(forFolderNamed: "Projects"), "projects")
        XCTAssertEqual(FirstRunSourceTemplate.slug(forFolderNamed: "  ---  "), "folder")
        XCTAssertEqual(FirstRunSourceTemplate.slug(forFolderNamed: "Résumé_v2"), "resume-v2")
        XCTAssertEqual(FirstRunSourceTemplate.slug(forFolderNamed: "Ünïcödé Ñotes"), "unicode-notes")
        XCTAssertEqual(FirstRunSourceTemplate.uniqueSlug(base: "docs", taken: []), "docs")
        XCTAssertEqual(FirstRunSourceTemplate.uniqueSlug(base: "docs", taken: ["docs"]), "docs-2")
        XCTAssertEqual(FirstRunSourceTemplate.uniqueSlug(base: "docs", taken: ["docs", "docs-2"]), "docs-3")
    }

    func testCustomTemplateUsesTheFolderAndAvoidsTakenSlugs() {
        let folder = URL(fileURLWithPath: "/Volumes/Archive/Old Notes")
        let template = FirstRunSourceTemplate.custom(folder: folder, existingSlugs: ["old-notes"])
        XCTAssertTrue(template.isCustom)
        XCTAssertTrue(template.isAvailable)
        XCTAssertEqual(template.title, "Old Notes")
        XCTAssertEqual(template.slug, "old-notes-2")
        XCTAssertEqual(template.root, "/Volumes/Archive/Old Notes")
        XCTAssertEqual(template.subtitle, "/Volumes/Archive/Old Notes")
        XCTAssertEqual(template.id, "custom:/Volumes/Archive/Old Notes")
    }

    // MARK: - Model plan

    func testFactsProviderFallsBackToThePythonDefault() {
        XCTAssertEqual(FirstRunModelPlan.factsProvider(for: ModelPresetEntry(name: "Gemma", slug: "gemma2-2b", provider: "ollama")), "ollama")
        XCTAssertEqual(FirstRunModelPlan.factsProvider(for: ModelPresetEntry(name: "Gemma", slug: "gemma2-2b", provider: "  ")), GarageConfigLoader.defaultFactsProvider)
        XCTAssertEqual(FirstRunModelPlan.factsProvider(for: ModelPresetEntry(name: "Gemma", slug: "gemma2-2b", provider: nil)), GarageConfigLoader.defaultFactsProvider)
    }

    func testOrderedPutsFeaturedPresetsFirstAndDefaultSelectsTheFirst() {
        let presets = [
            ModelPresetEntry(name: "Zeta", slug: "zeta", featured: false),
            ModelPresetEntry(name: "Beta", slug: "beta", featured: true),
            ModelPresetEntry(name: "Alpha", slug: "alpha", featured: false),
            ModelPresetEntry(name: "Gamma", slug: "gamma", featured: true),
        ]
        XCTAssertEqual(FirstRunModelPlan.ordered(presets).map(\.slug), ["beta", "gamma", "alpha", "zeta"])
        XCTAssertEqual(FirstRunModelPlan.defaultSelection(from: presets), ["beta"])
        XCTAssertEqual(FirstRunModelPlan.defaultSelection(from: []), [])
    }

    // MARK: - Coordinator

    private func makeDefaults() -> UserDefaults {
        let suite = "FirstRunTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
        }
        return defaults
    }

    @MainActor
    func testCoordinatorStartsInactiveAndNeverAutoPresentsUnderTests() {
        let coordinator = FirstRunCoordinator(defaults: makeDefaults())
        XCTAssertFalse(coordinator.isActive)
        XCTAssertFalse(coordinator.hasCompleted)
        XCTAssertFalse(coordinator.shouldPresentAtLaunch, "tests run under XCTest, where the assistant must stay hidden")
        XCTAssertEqual(coordinator.step, .settingUp)
    }

    @MainActor
    func testRelaunchAfterDatabaseResetOpensOnTheAssistant() {
        // Decided at init, before the window exists, so the window never draws the main pages first.
        let coordinator = FirstRunCoordinator(
            defaults: makeDefaults(),
            arguments: ["GarageApp", GarageAppLaunch.databaseResetArgument, "123"]
        )
        XCTAssertTrue(coordinator.isActive)
        XCTAssertTrue(coordinator.isAfterDatabaseReset)
        XCTAssertEqual(coordinator.step, .settingUp)
    }

    @MainActor
    func testBeginAndFinishToggleActivityAndRememberCompletion() {
        let coordinator = FirstRunCoordinator(defaults: makeDefaults())

        coordinator.begin()
        XCTAssertTrue(coordinator.isActive)
        XCTAssertEqual(coordinator.step, .settingUp)
        XCTAssertFalse(coordinator.sourceTemplates.isEmpty)

        coordinator.finish()
        XCTAssertFalse(coordinator.isActive)
        XCTAssertTrue(coordinator.hasCompleted)

        // Once completed, a plain begin() is a no-op; force re-opens it.
        coordinator.begin()
        XCTAssertFalse(coordinator.isActive)
        coordinator.begin(force: true)
        XCTAssertTrue(coordinator.isActive)

        coordinator.skip()
        XCTAssertFalse(coordinator.isActive)
        XCTAssertTrue(coordinator.hasCompleted)

        coordinator.resetCompletion()
        XCTAssertFalse(coordinator.hasCompleted)
    }

    /// On an overridden data folder (UI tests) finishing or skipping lasts for the launch only, so a
    /// test that walks the assistant leaves the real preference alone.
    @MainActor
    func testCompletionOnAThrowawayDataFolderIsNotSaved() {
        let defaults = makeDefaults()
        let coordinator = FirstRunCoordinator(defaults: defaults, persistsCompletion: false)

        coordinator.begin()
        coordinator.finish()
        XCTAssertFalse(coordinator.isActive)
        XCTAssertTrue(coordinator.hasCompleted, "a finished assistant counts as completed for the rest of the launch")
        XCTAssertNil(defaults.object(forKey: FirstRunPreferences.completedKey), "finishing saved the preference")

        coordinator.begin(force: true)
        coordinator.skip()
        XCTAssertTrue(coordinator.hasCompleted)
        XCTAssertNil(defaults.object(forKey: FirstRunPreferences.completedKey), "skipping saved the preference")

        coordinator.resetCompletion()
        XCTAssertFalse(coordinator.hasCompleted)
    }

    @MainActor
    func testAfterDatabaseResetRunsEvenWhenCompletedAndClearsOnSkip() {
        let coordinator = FirstRunCoordinator(defaults: makeDefaults())
        coordinator.begin()
        coordinator.finish()
        XCTAssertTrue(coordinator.hasCompleted)

        // A reset reopens the assistant even though it was completed before,
        // and says so on its first page.
        coordinator.begin(afterDatabaseReset: true)
        XCTAssertTrue(coordinator.isActive)
        XCTAssertTrue(coordinator.isAfterDatabaseReset)
        XCTAssertEqual(coordinator.step, .settingUp)

        // Skipping lands on the main window and leaves reset mode behind, so a
        // later "Setup Assistant…" is an ordinary run.
        coordinator.skip()
        XCTAssertFalse(coordinator.isActive)
        XCTAssertFalse(coordinator.isAfterDatabaseReset)
        XCTAssertTrue(coordinator.hasCompleted)

        coordinator.begin(force: true)
        XCTAssertFalse(coordinator.isAfterDatabaseReset)
    }

    @MainActor
    func testSourceSelectionIgnoresUnavailableTemplatesAndDedupesCustomFolders() {
        let coordinator = FirstRunCoordinator(defaults: makeDefaults())
        let available = FirstRunSourceTemplate(
            id: "documents", title: "Documents", subtitle: "", symbol: "doc", slug: "documents", root: "~/Documents",
            kind: "filesystem", corpusClass: "document", trust: "authored", isAvailable: true, isCustom: false
        )
        let missing = FirstRunSourceTemplate(
            id: "dropbox", title: "Dropbox", subtitle: "", symbol: "box", slug: "dropbox", root: "~/Dropbox",
            kind: "filesystem", corpusClass: "document", trust: "authored", isAvailable: false, isCustom: false
        )
        coordinator.setSourceTemplatesForTesting([available, missing])

        coordinator.toggleSource(missing)
        XCTAssertTrue(coordinator.selectedSourceIDs.isEmpty)

        coordinator.toggleSource(available)
        XCTAssertEqual(coordinator.selectedSourceIDs, ["documents"])
        XCTAssertEqual(coordinator.selectedSources.map(\.slug), ["documents"])
        coordinator.toggleSource(available)
        XCTAssertTrue(coordinator.selectedSourceIDs.isEmpty)

        let folder = URL(fileURLWithPath: "/tmp/garage-first-run/Documents")
        coordinator.addCustomFolder(folder)
        coordinator.addCustomFolder(folder)
        let custom = coordinator.sourceTemplates.filter(\.isCustom)
        XCTAssertEqual(custom.count, 1)
        XCTAssertEqual(custom.first?.slug, "documents-2", "must not collide with the built-in documents slug")
        XCTAssertTrue(coordinator.selectedSourceIDs.contains(custom.first!.id))

        coordinator.removeCustomFolder(custom.first!)
        XCTAssertTrue(coordinator.sourceTemplates.filter(\.isCustom).isEmpty)
        XCTAssertFalse(coordinator.selectedSourceIDs.contains(custom.first!.id))
        // Built-ins cannot be removed through the custom-folder path.
        coordinator.removeCustomFolder(available)
        XCTAssertEqual(coordinator.sourceTemplates.count, 2)
    }

    @MainActor
    func testModelAndClientTogglesAndBackNavigation() {
        let coordinator = FirstRunCoordinator(defaults: makeDefaults())
        let embedding = ModelPresetEntry(name: "BGE-M3", slug: "bge-m3", nativeDims: 1024)
        let distiller = ModelPresetEntry(name: "Gemma", slug: "gemma2-2b")
        let otherDistiller = ModelPresetEntry(name: "Llama", slug: "llama-3.2-1b-instruct")

        coordinator.toggleEmbedding(embedding)
        coordinator.toggleDistillation(distiller)
        XCTAssertEqual(coordinator.selectedEmbeddingSlugs, ["bge-m3"])
        XCTAssertEqual(coordinator.selectedDistillationSlug, "gemma2-2b")
        // Distillation is a single slot: picking another replaces, picking again clears.
        coordinator.toggleDistillation(otherDistiller)
        XCTAssertEqual(coordinator.selectedDistillationSlug, "llama-3.2-1b-instruct")
        coordinator.toggleDistillation(otherDistiller)
        XCTAssertNil(coordinator.selectedDistillationSlug)
        coordinator.toggleEmbedding(embedding)
        XCTAssertTrue(coordinator.selectedEmbeddingSlugs.isEmpty)

        let client = MCPClientConfig(id: "claude-desktop", label: "Claude Desktop", path: URL(fileURLWithPath: "/tmp/x.json"), existsOnDisk: true, isRegistered: false)
        coordinator.toggleClient(client)
        XCTAssertEqual(coordinator.selectedClientIDs, ["claude-desktop"])
        coordinator.toggleClient(client)
        XCTAssertTrue(coordinator.selectedClientIDs.isEmpty)

        coordinator.setStepForTesting(.setupAgent)
        coordinator.goBack()
        XCTAssertEqual(coordinator.step, .selectModels)
        coordinator.goBack()
        XCTAssertEqual(coordinator.step, .selectData)
        coordinator.goBack()
        XCTAssertEqual(coordinator.step, .selectData, "the services page is never re-entered by going back")
    }

    @MainActor
    func testCommitSourcesWithoutAnAppStateStaysPut() async {
        let coordinator = FirstRunCoordinator(defaults: makeDefaults())
        coordinator.setStepForTesting(.selectData)
        XCTAssertTrue(coordinator.selectedSources.isEmpty)
        await coordinator.commitSources()
        // No AppState attached: nothing to run, and the step stays put so the
        // assistant never claims to have added sources it could not add.
        XCTAssertEqual(coordinator.step, .selectData)
    }

    func testLooksAlreadyConfigured() {
        XCTAssertFalse(FirstRunCoordinator.looksAlreadyConfigured(configSources: [], registeredModels: []))
        XCTAssertTrue(FirstRunCoordinator.looksAlreadyConfigured(configSources: [RegisteredSource(slug: "docs", root: "~/Documents")], registeredModels: []))
        XCTAssertTrue(FirstRunCoordinator.looksAlreadyConfigured(
            configSources: [],
            registeredModels: [RegisteredModel(slug: "bge-m3", provider: "llama_xpc", modelRef: "bge-m3", dims: 1024, storedDims: 1024, storageKind: "vector", indexKind: "hnsw", tableName: "emb_bge_m3", isDefault: true, modelId: nil)]
        ))
    }

    // MARK: - AppState integration & rendering

    @MainActor
    func testAppStateOwnsAnInactiveCoordinator() {
        let state = AppState()
        XCTAssertFalse(state.firstRun.isActive)
        XCTAssertFalse(state.firstRun.shouldPresentAtLaunch)
        XCTAssertTrue(state.firstRun.serviceChecks.allSatisfy { $0.state == .pending })
        XCTAssertFalse(state.firstRun.servicesReady)
    }

    @MainActor
    func testEveryPageRenders() {
        let state = AppState()
        state.setRegisteredSourcesForTesting([RegisteredSource(slug: "documents", root: "~/Documents")])
        for step in FirstRunStep.allCases {
            state.firstRun.setStepForTesting(step)
            let view = FirstRunView().environmentObject(state)
            let controller = NSHostingController(rootView: view)
            XCTAssertNotNil(controller.view, "page \(step.title) failed to host")
        }
        state.firstRun.setStepForTesting(.settingUp, active: false)
    }

    @MainActor
    func testMaintenanceWaitsUntilTheAssistantCloses() async {
        let state = AppState()
        let wasEnabled = state.scheduledMaintenanceEnabled
        state.scheduledMaintenanceEnabled = true
        defer { state.scheduledMaintenanceEnabled = wasEnabled }

        // A scan started by the data page would hold runOperation while the models page
        // tries to register its picks, so maintenance only notes that it came due.
        state.firstRun.setStepForTesting(.selectModels, active: true)
        await state.triggerMaintenanceIfEnabled()
        XCTAssertTrue(state.isMaintenanceDeferredForFirstRun)

        state.firstRun.setStepForTesting(.settingUp, active: false)
        state.resumeMaintenanceAfterFirstRun()
        XCTAssertFalse(state.isMaintenanceDeferredForFirstRun)

        // Nothing owed: resuming again is a no-op.
        state.resumeMaintenanceAfterFirstRun()
        XCTAssertFalse(state.isMaintenanceDeferredForFirstRun)
    }

    @MainActor
    func testContentViewShowsTheAssistantWhileActive() {
        let state = AppState()
        state.firstRun.setStepForTesting(.selectData, active: true)
        let controller = NSHostingController(rootView: ContentView().environmentObject(state))
        XCTAssertNotNil(controller.view)
        state.firstRun.setStepForTesting(.settingUp, active: false)
        XCTAssertNotNil(NSHostingController(rootView: ContentView().environmentObject(state)).view)
    }
}

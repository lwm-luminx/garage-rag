import AppKit
import Foundation
import SwiftUI
import Combine
import OSLog
import GarageUpdater
import IngestClient
import PythonXPCService

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag", category: "AppState")

@MainActor
final class AppState: ObservableObject {
    static weak var shared: AppState?
    private static let scheduledMaintenanceEnabledKey = "scheduledMaintenanceEnabled"
    private static let scheduledMaintenanceIntervalKey = "scheduledMaintenanceInterval"
    private static let maintenanceRunsAtLaunchKey = "scheduledMaintenanceRunsAtLaunch"

    let postgres = PostgresService()
    /// General operations (sources, models, schema, settings), one at a time.
    let garage: OperationRunner
    /// Embedding backfill and fact distillation run on their own runners so a long
    /// job never blocks an ordinary operation.
    let backfill: OperationRunner
    let enrichFacts: OperationRunner
    /// Scans run here rather than on `garage`: walking a folder can take minutes, and on the general
    /// runner it would turn away every other operation ("A garage command is already running").
    let scanner: OperationRunner
    /// The slug a running scan covers ("*" for all sources), or nil when no scan runs.
    @Published private(set) var scanningSource: String?
    /// The sources registered when a "*" scan started. The scan never walks a source added while it
    /// runs, so that source is not busy: it can be added, and gets its own scan once the scan ends.
    @Published private(set) var scanningSlugs: Set<String> = []
    /// Sources added while a scan or ingest ran, waiting for their own scan and ingest once it ends.
    @Published private(set) var sourcesAwaitingScan: [String] = []
    /// Sources a running ingest of every source has yet to reach, in the order it takes them.
    /// Cancelling one (`cancel(source:)`) takes it out; `cancelAll()` empties it.
    @Published private(set) var ingestQueue: [String] = []
    /// Set by `cancelAll()` until the work it stopped has ended. An ingest of every source stops before
    /// its next source, and maintenance and the queued source scans stop before their next step.
    @Published private(set) var isCancellingAll = false
    /// Sources `removeSource(slug:)` is cancelling and then removing.
    @Published private(set) var sourcesBeingRemoved: Set<String> = []
    /// Sources cancelled while a "*" scan still covered them. One server call walks every source, so the
    /// scan cannot skip one; the ingest after it does. Emptied when that ingest ends or the scan fails.
    private var sourcesCancelledFromRun: Set<String> = []
    /// A "*" scan was cancelled so that a source it covered could be removed. It counts as finished,
    /// so the ingest after it still runs, only without the rest of the scan's counts.
    private var scanStoppedForRemoval = false
    /// An ingest of every source is under way, including the moments between sources when
    /// `IngestService.isRunning` is false. A second one waits for it: both would share `ingestQueue`.
    @Published private(set) var isIngestingAll = false
    let mcp: GarageMCPService
    let grpc: GarageGRPCService
    let llama: LlamaService
    let modelDownload: ModelDownloadService
    let volumeAccess: VolumeAccessService
    /// Sparkle front end. Inert in App Store builds, which update
    /// through the App Store rather than embedding Sparkle at all.
    let updater = UpdaterService.shared
    /// First-run setup assistant state (pages, picks, and the commands they run).
    let firstRun = FirstRunCoordinator()
    @Published var ingestService: IngestService
    let xpcServices: XPCServiceManager
    @Published var osLogStreamService: OSLogStreamService
    private var cancellables = Set<AnyCancellable>()

    /// Output of the most recent manual or scheduled operation,
    /// separate from the rolling activity log.
    @Published var lastCommandOutput: String = ""
    @Published var lastCommandSucceeded: Bool?
    @Published var autoStartPostgres = true
    @Published private(set) var lmStudioTokenConfigured = false
    @Published private(set) var presetModels: [ModelPresetEntry] = []
    /// Every generative preset (models.json `inference_models`), for chat, `rag_ask` and distillation.
    @Published private(set) var inferencePresets: [ModelPresetEntry] = []
    /// The inference presets tagged for fact distillation, which the setup assistant offers.
    @Published private(set) var factDistilPresets: [ModelPresetEntry] = []
    /// The catalog's `image_embedding` presets: CLIP-style models the image embedding helper runs.
    @Published private(set) var imageEmbeddingPresets: [ModelPresetEntry] = []
    /// The `facts` section of garage.json: which model answers `enrich-facts` and `rag_ask`.
    @Published private(set) var factsModel: String = GarageConfigLoader.defaultFactsModel
    @Published private(set) var factsProvider: String = GarageConfigLoader.defaultFactsProvider
    /// The `inference` section: the chat model `rag_ask` / `rag_generate` use. nil follows the
    /// distillation model, which is how a fresh install (the setup assistant asks only for that) runs.
    @Published private(set) var inferenceModel: String?
    @Published private(set) var inferenceProvider: String?
    /// The effective fact-extraction prompts (`ListFactPrompts`): the built-in default and `facts.prompts`.
    @Published private(set) var factPrompts: [FactPromptItem] = []
    /// `facts.prompts` as configured, a JSON array; edits are applied to it and written back whole.
    @Published private(set) var factPromptsConfiguredJSON: String = "[]"
    @Published private(set) var factPromptsError: String?
    @Published private(set) var registeredModels: [RegisteredModel] = []
    /// The llama_xpc alias of the default embedding model this launch already loaded, so a later
    /// refresh does not load it again after the Models page unloaded it. See `AppState+LlamaModels`.
    var preloadedEmbeddingModel: String?
    /// The facts model the running `enrich-facts` loaded and unloads when it ends.
    var factsModelHeldForDistilling: String?
    @Published private(set) var isFetchingModels = false
    @Published var registeredSources: [RegisteredSource] = []
    @Published private(set) var isFetchingSources = false
    @Published var corpusStats = CorpusStats()
    /// Why the last "ingest every source" run failed, kept for the whole batch: each source's ingest
    /// clears `IngestService.lastError` as it starts, so a later success would otherwise hide an
    /// earlier failure. Cleared when the next batch starts.
    @Published private(set) var lastIngestAllFailure: String?
    /// Where the running backfill is, from its stream: the model being embedded and its counts.
    @Published private(set) var backfillProgress: BackfillProgress?
    /// Where the running `enrich-facts` is, from its stream.
    @Published private(set) var enrichFactsProgress: EnrichFactsProgress?

    struct BackfillProgress: Equatable {
        var model: String
        var embedded: Int
        var total: Int
    }

    struct EnrichFactsProgress: Equatable {
        var index: Int
        var total: Int
        var documentURI: String?
    }
    /// What the running scan has found so far; nil when no scan is running.
    @Published var scanProgress: ScanProgress?
    @Published private(set) var isFetchingStats = false
    @Published private(set) var isApplyingMigrations = false
    @Published var scheduledMaintenanceEnabled: Bool {
        didSet {
            UserDefaults.standard.set(
                scheduledMaintenanceEnabled,
                forKey: Self.scheduledMaintenanceEnabledKey
            )
            configureScheduledMaintenance()
        }
    }
    @Published var scheduledMaintenanceInterval: TimeInterval {
        didSet {
            UserDefaults.standard.set(
                scheduledMaintenanceInterval,
                forKey: Self.scheduledMaintenanceIntervalKey
            )
            configureScheduledMaintenance()
        }
    }
    /// With automatic updates on, also run them once the database is up after launch, rather than
    /// waiting a whole interval for the first run.
    @Published var maintenanceRunsAtLaunch: Bool {
        didSet {
            UserDefaults.standard.set(maintenanceRunsAtLaunch, forKey: Self.maintenanceRunsAtLaunchKey)
        }
    }
    /// Set at launch and cleared by the first `runMaintenanceAtLaunchIfEnabled()`, so a later
    /// database restart does not count as a launch.
    private var maintenanceAtLaunchPending = false

    private var commandInProgress = false
    /// True from the moment "Reset Database" starts stopping services until this instance quits.
    @Published private(set) var isResettingDatabase = false
    /// How the second half of a reset went (`finishDatabaseReset`), for the Database page. Kept apart
    /// from `lastCommandOutput`, which the next operation overwrites and no page shows any more.
    @Published private(set) var databaseResetOutcome: (succeeded: Bool, message: String)?
    /// `finishDatabaseReset` is running: the Database page says so until `databaseResetOutcome`
    /// arrives, since after "Skip setup" that second half starts from scratch (cluster, schema,
    /// services) and can take a minute on a busy Mac.
    @Published private(set) var isFinishingDatabaseReset = false
    private var hasLaunched = false
    private var hasTerminated = false
    /// Set once "Reset Database" has asked a new instance to start. From then on this instance's
    /// services are already stopped, and the Postgres pid file and XPC service names belong to the new
    /// instance, so quitting must not run the usual shutdown (which stops both by pid file and name).
    private(set) var hasHandedOffToRelaunch = false
    private var scheduledMaintenanceTask: Task<Void, Never>?
    private var pendingMaintenanceTask: Task<Void, Never>?
    /// `startBackend`'s hand-over of the database URL and the backend's address to the helpers,
    /// which the launch run of automatic updates waits for: until the ingest and embed helpers
    /// have taken their configuration, a scan started at launch fails against helpers that have
    /// no database yet.
    private var helperConfigurationTask: Task<Void, Never>?
    private var queuedSourceScanTask: Task<Void, Never>?
    /// Maintenance came due while the setup assistant was open; run it when it closes.
    private(set) var isMaintenanceDeferredForFirstRun = false
    /// Scheduled maintenance is between or inside its scan, ingest and backfill steps.
    private(set) var isMaintenanceRunning = false
    /// "Update Everything" is between or inside its scan, ingest, embed and glean-facts steps.
    @Published private(set) var isUpdatingEverything = false

    convenience init() {
        // Before anything below connects to the services the sandboxed app hosts itself.
        InProcessServiceHost.startIfSandboxed()
        self.init(llama: LlamaService(), volumeAccess: VolumeAccessService(), modelDownload: ModelDownloadService())
    }

    init(llama: LlamaService, volumeAccess: VolumeAccessService? = nil, modelDownload: ModelDownloadService? = nil, xpcServices: XPCServiceManager? = nil, osLogStreamService: OSLogStreamService? = nil) {
        self.llama = llama
        let client = volumeAccess?.ingestClient ?? IngestClient()
        self.volumeAccess = volumeAccess ?? VolumeAccessService(ingestClient: client)
        let downloadService = modelDownload ?? ModelDownloadService()
        self.modelDownload = downloadService
        self.ingestService = IngestService(client: self.volumeAccess.ingestClient ?? client, postgres: postgres)
        let xpcMgr = xpcServices ?? XPCServiceManager()
        let osLogSvc = osLogStreamService ?? OSLogStreamService()
        xpcMgr.osLogStreamService = osLogSvc
        self.xpcServices = xpcMgr
        self.osLogStreamService = osLogSvc
        garage = OperationRunner(label: "garage")
        backfill = OperationRunner(label: "garage backfill")
        enrichFacts = OperationRunner(label: "garage enrich-facts")
        scanner = OperationRunner(label: "garage scan")
        let grpcService = GarageGRPCService(postgres: postgres)
        let mcpService = GarageMCPService(postgres: postgres)
        // Client registration (McpInstall) goes over gRPC, to a service that writes only what it was granted.
        mcpService.grpc = grpcService
        mcpService.folderAccess = self.volumeAccess.folderAccess
        mcp = mcpService
        grpc = grpcService

        // `bool(forKey:)` rather than `as? Bool`: a launch argument (`-scheduledMaintenanceEnabled NO`,
        // as the UI tests pass) arrives as the string "NO", which only `bool(forKey:)` converts.
        if UserDefaults.standard.object(forKey: Self.scheduledMaintenanceEnabledKey) != nil {
            scheduledMaintenanceEnabled = UserDefaults.standard.bool(forKey: Self.scheduledMaintenanceEnabledKey)
        } else {
            scheduledMaintenanceEnabled = true
        }
        let storedInterval = UserDefaults.standard.double(
            forKey: Self.scheduledMaintenanceIntervalKey
        )
        scheduledMaintenanceInterval = storedInterval > 0 ? storedInterval : 60 * 60
        maintenanceRunsAtLaunch = UserDefaults.standard.bool(forKey: Self.maintenanceRunsAtLaunchKey)

        // Forward changes from child ObservableObjects to AppState observers
        downloadService.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        // A Gemma 4 download becomes the chat model when chat would otherwise have no tools.
        // Checked again once the backend is up, since the setting is written through it.
        // Typed pieces: the whole chain as one expression is too much for the type checker.
        let downloadedPaths: AnyPublisher<[String], Never> = downloadService.$downloadedModels
            .map { $0.map(\.path) }
            .eraseToAnyPublisher()
        let backendRunning: AnyPublisher<Bool, Never> = grpc.$status
            .map { $0 == .running }
            .eraseToAnyPublisher()
        Publishers.CombineLatest(downloadedPaths, backendRunning)
            .removeDuplicates { (old: ([String], Bool), new: ([String], Bool)) -> Bool in old == new }
            .sink { [weak self] _ in Task { @MainActor in await self?.adoptDownloadedGemma4ForInference() } }
            .store(in: &cancellables)
        llama.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        postgres.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        mcp.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        grpc.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        backfill.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        enrichFacts.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        scanner.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        garage.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        self.volumeAccess.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        self.ingestService.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        self.xpcServices.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        self.osLogStreamService.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        updater.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        firstRun.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        firstRun.attach(to: self)

        Task {
            do {
                lmStudioTokenConfigured = try await LMStudioTokenStore.loadOffMainActor()
            } catch {
                lastCommandSucceeded = false
                lastCommandOutput = error.localizedDescription
            }
        }

        fetchPresetModels()
        Self.shared = self
    }

    func launch() {
        guard !hasLaunched else { return }
        hasLaunched = true
        let arguments = GarageAppLaunch.arguments
        guard arguments.contains(GarageAppLaunch.databaseResetArgument) else {
            maintenanceAtLaunchPending = true
            launchServices(startsPostgres: autoStartPostgres)
            return
        }
        lastCommandOutput = "Creating a new database…"
        Task {
            // The instance that deleted the database quits right after launching this one, and its
            // quit path stops Postgres by pid file and XPC services by executable name. Start
            // nothing of our own until it is gone.
            if let parent = Self.databaseResetParent(in: arguments) {
                await Self.waitForExit(of: parent, timeout: 30)
            }
            // The reset kept garage.json: fill the new database from it, with no assistant.
            if arguments.contains(GarageAppLaunch.keepSettingsArgument) {
                launchServices(startsPostgres: false)
                await finishDatabaseReset(startingPostgres: true, restoringSettings: true)
                resumeMaintenanceAfterFirstRun()
                return
            }
            // The setup assistant's first page creates the new database and
            // registers garage.json's sources again; "Skip setup" finishes the
            // reset without it and leaves the unconfigured main window.
            launchServices(startsPostgres: false)
            firstRun.begin(afterDatabaseReset: true)
        }
    }

    /// The pid after `--after-database-reset`, when this instance was launched by a reset.
    nonisolated static func databaseResetParent(in arguments: [String]) -> pid_t? {
        guard let flag = arguments.firstIndex(of: GarageAppLaunch.databaseResetArgument),
              flag + 1 < arguments.count,
              let pid = pid_t(arguments[flag + 1]), pid > 0 else {
            return nil
        }
        return pid
    }

    /// Returns once `pid` has exited, or after `timeout` seconds.
    nonisolated static func waitForExit(of pid: pid_t, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, kill(pid, 0) == 0 || errno == EPERM {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func launchServices(startsPostgres: Bool) {
        // Before anything reads the data folder's contents or starts Postgres / an XPC service.
        GarageDataMigration.runAtLaunch()
        fetchPresetModels()
        // UI tests turn this off, so the page shows the bundled catalog of the build under test
        // rather than whatever the website serves.
        // `bool(forKey:)` because a launch argument's "NO" arrives as a string, which `as? Bool` misses.
        let defaults = UserDefaults.standard
        let refreshesCatalog = defaults.object(forKey: ModelCatalog.refreshAtLaunchDefaultsKey) == nil
            || defaults.bool(forKey: ModelCatalog.refreshAtLaunchDefaultsKey)
        if refreshesCatalog {
            Task {
                if await ModelCatalog.refresh() {
                    fetchPresetModels()
                }
            }
        }
        volumeAccess.restoreAndVerifyAccess()
        osLogStreamService.loadAllPersistedLogs()
        xpcServices.startStreamingAllServices()
        Task { await fetchRegisteredSources() }
        Task { await fetchCorpusStats() }
        configureScheduledMaintenance()
        Task { await llama.refreshStatus() }
        Task { await modelDownload.refresh() }
        Task { await xpcServices.refreshAll() }
        // The window already opened on the assistant (`FirstRunCoordinator.init`); its first page
        // drives Postgres and service startup itself so it can show progress and retry on failure.
        // After "Reset Database", `launch()` begins it once the old instance has exited.
        if firstRun.isActive {
            if !firstRun.isAfterDatabaseReset { firstRun.begin() }
            return
        }
        guard startsPostgres else { return }
        Task { await startPostgres() }
    }

    /// Starts the gRPC backend and, once it listens, hands the ingest, embed and MCP helpers the
    /// database URL and its address (`XPCServiceManager.configureHelpers`), off this task so the
    /// pages fill without waiting on the helpers' self tests.
    func startBackend() async {
        try? await grpc.start()
        guard grpc.status == .running, let options = try? grpc.helperConfiguration() else { return }
        helperConfigurationTask = Task { [xpcServices] in
            await xpcServices.configureHelpers(options)
        }
        await recordOwnerNameIfMissing()
    }

    /// Fills in `identity.name` from the Mac account's full name when garage.json names no owner.
    /// Without it no author is the owner's: attribution has no "authored" by name, and the Graph page
    /// cannot open on the owner's own vertex. Setting it also marks the owner's existing author row.
    func recordOwnerNameIfMissing(
        configured: String? = GarageConfigLoader.loadIdentityName(),
        accountName: String = NSFullUserName()
    ) async {
        guard let name = Self.ownerNameToRecord(configured: configured, accountName: accountName) else { return }
        do {
            _ = try await grpc.setSetting("identity.name", to: name)
        } catch {
            logger.warning("Could not record the owner's name: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The account name to write as `identity.name`, or nil when one is configured or there is none.
    nonisolated static func ownerNameToRecord(configured: String?, accountName: String) -> String? {
        guard configured?.isEmpty ?? true else { return nil }
        let name = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    func startPostgres() async {
        do {
            try await postgres.start()
            // The migrations in data/sql are idempotent and meant to be re-applied, so bring the
            // schema up to date at start rather than waiting for Apply on the Database page.
            // applyMigrations() also starts MCP and gRPC and refreshes what the pages show.
            if postgres.status == .needsMigration {
                await applyMigrations()
                runMaintenanceAtLaunchIfEnabled()
                return
            }
            if postgres.status == .running {
                // Each daemon starts independently: an MCP failure must not keep the gRPC backend down.
                try? await mcp.startIfEnabled()
                await startBackend()
            }
            await fetchRegisteredModels()
            await fetchRegisteredSources()
            await fetchCorpusStats()
            runMaintenanceAtLaunchIfEnabled()
        } catch {
            // Status already reflects .failed(...); nothing else to do here.
        }
    }

    /// Every preset the Embedding page can register: text models, then image models.
    var embeddingPresets: [ModelPresetEntry] {
        presetModels + imageEmbeddingPresets
    }

    func fetchPresetModels() {
        self.presetModels = GarageConfigLoader.loadModelPresets()
        self.inferencePresets = GarageConfigLoader.loadInferencePresets()
        self.factDistilPresets = inferencePresets.filter(\.isForDistillation)
        self.imageEmbeddingPresets = GarageConfigLoader.loadImageEmbeddingPresets()
        fetchFactsSettings()
    }

    /// Re-reads the `facts` section of garage.json.
    func fetchFactsSettings() {
        let facts = GarageConfigLoader.loadFactsSettings()
        self.factsModel = facts.model
        self.factsProvider = facts.provider
        let inference = GarageConfigLoader.loadInferenceSettings()
        self.inferenceModel = inference.model
        self.inferenceProvider = inference.provider
    }

    /// The model that answers chat: `inference.model`, else the distillation model.
    var effectiveInferenceModel: String { inferenceModel ?? factsModel }

    /// Points `rag_ask` / `rag_generate` at a model, or with nil clears `inference.*` so chat
    /// follows the distillation model again.
    @discardableResult
    func setInferenceModel(_ slug: String?, provider: String = GarageConfigLoader.defaultFactsProvider) async -> Bool {
        let succeeded = await runOperation { grpc in
            let model = try await grpc.setSetting("inference.model", to: slug ?? "")
            let chosen = try await grpc.setSetting("inference.provider", to: slug == nil ? "" : provider)
            return [model.summary, chosen.summary].joined(separator: "\n")
        }
        fetchFactsSettings()
        return succeeded
    }

    /// Names a downloaded Gemma 4 as `inference.model` when nothing is chosen for inference and the
    /// distillation model calls no tools (`ModelsPresentation.gemma4ToAdoptForInference`). Waits
    /// for the backend, since the setting is written through it.
    func adoptDownloadedGemma4ForInference() async {
        guard grpc.status == .running, !commandInProgress else { return }
        guard let preset = ModelsPresentation.gemma4ToAdoptForInference(
            inferenceModel: inferenceModel,
            factsModel: factsModel,
            presets: inferencePresets,
            isDownloaded: { preset in preset.effectiveFilename.map { self.modelDownload.isModelDownloaded(filename: $0) } ?? false }
        ) else { return }
        await setInferenceModel(preset.slug, provider: FirstRunModelPlan.factsProvider(for: preset))
    }

    /// Points `enrich-facts` / `rag_ask` at a model: sets `facts.model`, then `facts.provider`.
    @discardableResult
    func setFactsModel(_ slug: String, provider: String = GarageConfigLoader.defaultFactsProvider) async -> Bool {
        let succeeded = await runOperation { grpc in
            let model = try await grpc.setSetting("facts.model", to: slug)
            let chosen = try await grpc.setSetting("facts.provider", to: provider)
            return [model.summary, chosen.summary].joined(separator: "\n")
        }
        fetchFactsSettings()
        return succeeded
    }

    /// Re-reads the effective fact prompts from the service.
    func fetchFactPrompts() async {
        guard postgres.status == .running else { return }
        do {
            let response = try await grpc.listFactPrompts()
            factPrompts = response.prompts.map(FactPromptItem.init)
            factPromptsConfiguredJSON = response.configuredJson.isEmpty ? "[]" : response.configuredJson
            factPromptsError = nil
        } catch {
            factPromptsError = error.localizedDescription
        }
    }

    /// Writes `facts.prompts` (a JSON array) through `SetSetting`, which validates it first.
    @discardableResult
    func saveFactPrompts(configuredJSON: String) async -> Bool {
        let succeeded = await runOperation { grpc in
            let response = try await grpc.setSetting("facts.prompts", to: configuredJSON)
            return "facts.prompts updated (wrote \(response.path))"
        }
        await fetchFactPrompts()
        return succeeded
    }

    func fetchRegisteredModels() async {
        fetchPresetModels()
        guard postgres.status == .running else { return }
        isFetchingModels = true
        defer { isFetchingModels = false }
        do {
            let models = try await postgres.listRegisteredModels()
            self.registeredModels = models
        } catch {
            // Silently ignore or leave models as-is if table not yet migrated
        }
        // At launch, and whenever the default changes, so a search finds its model resident.
        Task { await preloadDefaultEmbeddingModel() }
    }

    func fetchRegisteredSources() async {
        isFetchingSources = true
        defer { isFetchingSources = false }

        let configSources = GarageConfigLoader.loadSourcesFromConfig()
        var dbSources: [RegisteredSource] = []
        if postgres.status == .running {
            do {
                dbSources = try await postgres.listRegisteredSources()
            } catch {
                // Table might not exist yet or error
            }
        }

        var merged: [String: RegisteredSource] = [:]
        for cs in configSources {
            merged[cs.slug] = cs
        }
        for ds in dbSources {
            if let existing = merged[ds.slug] {
                merged[ds.slug] = RegisteredSource(
                    slug: ds.slug,
                    kind: ds.kind.isEmpty ? existing.kind : ds.kind,
                    root: ds.root.isEmpty ? existing.root : ds.root,
                    corpusClass: ds.corpusClass.isEmpty ? existing.corpusClass : ds.corpusClass,
                    trust: ds.trust.isEmpty ? existing.trust : ds.trust,
                    enabled: ds.enabled,
                    includeCode: existing.includeCode,
                    origin: .both,
                    documentCount: ds.documentCount,
                    expectedElements: ds.expectedElements
                )
            } else {
                merged[ds.slug] = ds
            }
        }

        self.registeredSources = Array(merged.values).sorted { $0.slug < $1.slug }
    }

    func fetchCorpusStats() async {
        guard postgres.status == .running else {
            var stats = CorpusStats()
            stats.sourcesCount = registeredSources.count
            self.corpusStats = stats
            return
        }
        isFetchingStats = true
        defer { isFetchingStats = false }
        do {
            var stats = try await postgres.fetchCorpusStats()
            if stats.sourcesCount == 0 && !registeredSources.isEmpty {
                stats.sourcesCount = registeredSources.count
            }
            self.corpusStats = stats
            let docCounts = stats.sourceDocumentCounts
            if !docCounts.isEmpty {
                self.registeredSources = self.registeredSources.map { source in
                    var updated = source
                    if let count = docCounts[source.slug] {
                        updated.documentCount = count
                    }
                    return updated
                }
            }
        } catch {
            logger.error("Corpus stats query failed: \(error.localizedDescription, privacy: .public)")
            var fallback = self.corpusStats
            if fallback.sourcesCount == 0 {
                fallback.sourcesCount = registeredSources.count
            }
            fallback.lastUpdated = Date()
            self.corpusStats = fallback
        }
    }

    func stopPostgres() async {
        await mcp.stop()
        await grpc.stop()
        await postgres.stop()
    }

    /// Synchronously terminates all child and daemon processes, CLI runs, and XPC helper services.
    /// Idempotent: every quit path (applicationShouldTerminate, applicationWillTerminate) calls it once.
    func terminateImmediately() {
        guard !hasTerminated, !hasHandedOffToRelaunch else { return }
        hasTerminated = true
        scheduledMaintenanceTask?.cancel()
        scheduledMaintenanceTask = nil
        pendingMaintenanceTask?.cancel()
        pendingMaintenanceTask = nil
        queuedSourceScanTask?.cancel()
        queuedSourceScanTask = nil
        mcp.terminateImmediately()
        grpc.terminateImmediately()
        // postgres.terminateImmediately() already runs PostgresService.stopAnyRunningInstance().
        postgres.terminateImmediately()
        garage.cancel()
        backfill.cancel()
        enrichFacts.cancel()
        scanner.cancel()
        // xpcServices.terminateAll() already runs XPCServiceManager.stopAnyRunningInstances().
        xpcServices.terminateAll()
    }

    /// "Reset Database": stops every service, deletes the Postgres cluster, and relaunches the app,
    /// which creates a new, empty database (`finishDatabaseReset`). Only what Garage built goes: the
    /// sources' own files, downloaded model files, logs and the database password stay.
    ///
    /// `keepingSettings` keeps garage.json: the new instance fills the new database from it, sources
    /// and default embedding model, and skips the setup assistant. Without it, garage.json is set
    /// aside (`setAsideConfigForReset`, renamed, never deleted) and the assistant starts from scratch.
    func resetDatabaseAndRelaunch(keepingSettings: Bool = true) async {
        guard !isResettingDatabase else { return }
        isResettingDatabase = true
        lastCommandOutput = "Stopping Garage's services…"

        scheduledMaintenanceTask?.cancel()
        scheduledMaintenanceTask = nil
        pendingMaintenanceTask?.cancel()
        pendingMaintenanceTask = nil
        queuedSourceScanTask?.cancel()
        queuedSourceScanTask = nil
        garage.cancel()
        backfill.cancel()
        enrichFacts.cancel()
        scanner.cancel()
        await mcp.stop()
        await grpc.stop()
        await postgres.stop()
        // Anything still holding pgdata: an orphaned postmaster from an earlier run.
        await PostgresService.stopAnyRunningInstance()
        xpcServices.terminateAll()

        do {
            try await postgres.deleteClusterForReset()
        } catch {
            isResettingDatabase = false
            lastCommandSucceeded = false
            lastCommandOutput = "Reset stopped: \(error.localizedDescription) Restarting the services."
            xpcServices.startStreamingAllServices()
            configureScheduledMaintenance()
            await startPostgres()
            return
        }
        // Never relaunch the test host.
        guard !isRunningInTestEnvironment else {
            isResettingDatabase = false
            return
        }
        if !keepingSettings {
            do {
                if let setAside = try Self.setAsideConfigForReset() {
                    logger.info("Set garage.json aside as \(setAside.lastPathComponent, privacy: .public)")
                }
            } catch {
                // The database is already gone; carry on with the settings rather than strand the reset.
                logger.error("Could not set garage.json aside: \(error.localizedDescription, privacy: .public)")
            }
        }
        lastCommandOutput = "Database deleted. Relaunching Garage to create a new one…"
        relaunchAfterDatabaseReset(keepingSettings: keepingSettings)
    }

    /// Renames the app's garage.json to `garage.json.before-reset-<date>` beside it, so a reset that
    /// starts over begins with no settings and the old ones can still be brought back by hand.
    /// Returns the new name, or nil when there was no file.
    @discardableResult
    nonisolated static func setAsideConfigForReset(
        in directory: URL = Paths.garageWorkingDirectory,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> URL? {
        let config = directory.appendingPathComponent("garage.json")
        guard fileManager.fileExists(atPath: config.path) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let destination = directory.appendingPathComponent("garage.json.before-reset-\(formatter.string(from: now))")
        try fileManager.moveItem(at: config, to: destination)
        return destination
    }

    private func relaunchAfterDatabaseReset(keepingSettings: Bool) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        let arguments = Self.relaunchArguments(
            parentPID: getpid(), currentArguments: GarageAppLaunch.arguments, keepingSettings: keepingSettings)
        // Ignored when this process is sandboxed (the App Store build); the new instance then
        // takes them from the handoff instead.
        configuration.arguments = arguments
        GarageRelaunchHandoff.record(arguments)
        // Before the new instance can start anything: a quit from here on must leave its services alone.
        markHandedOffToRelaunch()
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            let failure = error?.localizedDescription
            Task { @MainActor in
                guard let failure else {
                    Self.terminateFromRunLoop()
                    return
                }
                // No second instance: create the new database in this one instead.
                logger.error("Relaunch after reset failed: \(failure, privacy: .public)")
                GarageRelaunchHandoff.discard()
                self.hasHandedOffToRelaunch = false
                self.isResettingDatabase = false
                if keepingSettings {
                    await self.finishDatabaseReset(startingPostgres: true, restoringSettings: true)
                } else {
                    self.firstRun.begin(afterDatabaseReset: true)
                }
            }
        }
    }

    func markHandedOffToRelaunch() {
        hasHandedOffToRelaunch = true
    }

    /// `NSApp.terminate` from the run loop rather than from inside a main-actor job. Called from a
    /// job, AppKit's wait for `reply(toApplicationShouldTerminate:)` runs a nested event loop inside
    /// that job, and since the main queue is serial, any reply scheduled as another main-actor job
    /// never runs: the app hangs in `terminate:` until it is killed.
    private static func terminateFromRunLoop() {
        RunLoop.main.perform {
            NSApp.terminate(nil)
        }
    }

    /// Arguments for the instance a reset launches: the reset flag with this pid, and the
    /// `--data-directory` override when this instance runs on one. LaunchServices passes neither the
    /// arguments nor the environment on, and without it the new instance would open the real folder.
    nonisolated static func relaunchArguments(
        parentPID: pid_t, currentArguments: [String], keepingSettings: Bool = false
    ) -> [String] {
        var arguments = [GarageAppLaunch.databaseResetArgument, String(parentPID)]
        if keepingSettings {
            arguments.append(GarageAppLaunch.keepSettingsArgument)
        }
        if let flag = currentArguments.firstIndex(of: GarageAppLaunch.dataDirectoryArgument),
           flag + 1 < currentArguments.count {
            arguments += [GarageAppLaunch.dataDirectoryArgument, currentArguments[flag + 1]]
        }
        return arguments
    }

    /// Second half of a reset, once Postgres has initialized a new cluster: apply the schema,
    /// start the gRPC and MCP services, and register the sources garage.json declares again.
    /// The setup assistant runs it from its first page after a reset, or in the background
    /// when the user skips the assistant before that page gets this far; that path passes
    /// `startingPostgres`, so the cluster's creation, the slowest stage, also counts as the
    /// reset in progress on the Database page.
    ///
    /// `restoringSettings` is a reset that kept garage.json: it also registers the embedding model
    /// garage.json declares as the default (`embedding.default_model`), when the catalog lists it.
    /// Everything goes from garage.json to the database; nothing is written back to the file.
    func finishDatabaseReset(startingPostgres: Bool = false, restoringSettings: Bool = false) async {
        isFinishingDatabaseReset = true
        defer { isFinishingDatabaseReset = false }
        if startingPostgres { await startPostgres() }
        // "Skip setup" can land here while the assistant's first start is still initializing the
        // cluster or applying the schema: wait for that to finish rather than calling the reset failed.
        await waitForPostgresToSettle()
        do {
            if postgres.status == .needsMigration {
                isApplyingMigrations = true
                defer { isApplyingMigrations = false }
                try await postgres.applyMigrations()
            }
            guard postgres.status == .running else {
                throw PostgresError.other("Postgres did not start with the new database; see the Database page.")
            }
            await startBackend()
            try? await mcp.startIfEnabled()
            let synced = await runOperation { try await $0.syncSources().message }
            let syncOutput = lastCommandOutput
            var restoredModel: String?
            if restoringSettings {
                if let slug = GarageConfigLoader.loadDeclaredDefaultEmbeddingModel(),
                   let preset = presetModels.first(where: { $0.slug == slug }),
                   await registerModel(preset: preset, makeDefault: true) {
                    restoredModel = slug
                }
            }
            await fetchRegisteredModels()
            await fetchRegisteredSources()
            await fetchCorpusStats()
            lastCommandSucceeded = synced
            lastCommandOutput = synced
                ? Self.databaseResetMessage(registeredSourceCount: registeredSources.count, restoredModel: restoredModel)
                : "Database reset: a new database was created, but registering the sources from garage.json "
                    + "failed: \(syncOutput)"
        } catch {
            lastCommandSucceeded = false
            lastCommandOutput = "Database reset: the new database could not be set up: \(error.localizedDescription)"
        }
        databaseResetOutcome = (lastCommandSucceeded == true, lastCommandOutput)
    }

    /// Polls, as the setup assistant's readiness loop does, until Postgres is no longer starting and
    /// no migration run is in flight, for at most `timeout` seconds.
    private func waitForPostgresToSettle(timeout: TimeInterval = 150) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !Task.isCancelled, postgres.status == .starting || isApplyingMigrations, Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    /// What the Database page shows while `finishDatabaseReset` runs.
    static let databaseResetInProgressMessage =
        "Finishing the database reset: creating the database, applying the schema and starting the services…"

    nonisolated static func databaseResetMessage(registeredSourceCount: Int, restoredModel: String? = nil) -> String {
        let sources = switch registeredSourceCount {
        case 0: "garage.json declares no sources, so none are registered; add them on the Sources page."
        case 1: "The 1 source in garage.json was registered again."
        default: "The \(registeredSourceCount) sources in garage.json were registered again."
        }
        let models = if let restoredModel {
            "Its default embedding model, \(restoredModel), was registered again; register any others "
                + "on the Models page, then run ingest to rebuild the index."
        } else {
            "Register your embedding models on the Models page, then run ingest to rebuild the index."
        }
        return "Database reset: a new, empty database was created. \(sources) \(models)"
    }

    func applyMigrations() async {
        // One run at a time: startPostgres, the setup assistant and the Database page can each ask.
        guard !isApplyingMigrations else { return }
        guard postgres.status == .running || postgres.status == .needsMigration else { return }
        isApplyingMigrations = true
        defer { isApplyingMigrations = false }
        do {
            try await postgres.applyMigrations()
            await fetchRegisteredModels()
            await fetchRegisteredSources()
            await fetchCorpusStats()
            if postgres.status == .running {
                if mcp.status == .stopped {
                    try? await mcp.startIfEnabled()
                }
                if grpc.status == .stopped {
                    await startBackend()
                }
            }
            lastCommandSucceeded = true
            lastCommandOutput = "Applied schema migrations successfully."
        } catch {
            lastCommandSucceeded = false
            lastCommandOutput = "Failed to apply migrations: \(error.localizedDescription)"
        }
    }

    func checkPendingMigrations() {
        Task {
            await postgres.refreshPendingMigrations()
            guard postgres.status == .running else { return }
            if mcp.status == .stopped {
                try? await mcp.startIfEnabled()
            }
            if grpc.status == .stopped {
                await startBackend()
            }
        }
    }

    @discardableResult
    func copyDatabaseURLToClipboard() -> Bool {
        do {
            let urlString = try postgres.copyStandardConnectionURLToClipboard()
            lastCommandSucceeded = true
            lastCommandOutput = "Copied PostgreSQL connection URL to clipboard: \(urlString)"
            return true
        } catch {
            lastCommandSucceeded = false
            lastCommandOutput = "Failed to copy database connection URL: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func openDatabaseInHandler() -> Bool {
        do {
            let opened = try postgres.openInRegisteredHandler()
            if opened {
                lastCommandSucceeded = true
                lastCommandOutput = "Opened PostgreSQL database URL in registered handler: \(try postgres.standardConnectionURLString())"
            } else {
                lastCommandSucceeded = false
                lastCommandOutput = "No application registered to open postgresql:// URLs."
            }
            return opened
        } catch {
            lastCommandSucceeded = false
            lastCommandOutput = "Failed to open database connection URL: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func saveLMStudioToken(_ rawToken: String) -> Bool {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            lastCommandSucceeded = false
            lastCommandOutput = "LM Studio API token must not be empty."
            return false
        }
        do {
            try LMStudioTokenStore.save(token)
            lmStudioTokenConfigured = true
            lastCommandSucceeded = true
            lastCommandOutput = "LM Studio API token saved in Keychain."
            return true
        } catch {
            lastCommandSucceeded = false
            lastCommandOutput = error.localizedDescription
            return false
        }
    }

    func removeLMStudioToken() {
        do {
            try LMStudioTokenStore.remove()
            lmStudioTokenConfigured = false
            lastCommandSucceeded = true
            lastCommandOutput = "LM Studio API token removed from Keychain."
        } catch {
            lastCommandSucceeded = false
            lastCommandOutput = error.localizedDescription
        }
    }

    /// Writes a dump of the database to `destination` and records it as the last backup.
    @discardableResult
    func backupDatabase(to destination: URL) async -> Bool {
        let succeeded = await performDatabaseOperation { try await postgres.backupDatabase(to: destination) }
        if succeeded {
            DatabaseBackupRecord.record(destination)
            lastCommandOutput = "Backed up the database to \(destination.path)."
        }
        return succeeded
    }

    /// Replaces the database with the dump at `source`, then rereads what the pages show from it: a
    /// dump from an older build can be missing migrations, and its sources and models are its own.
    @discardableResult
    func restoreDatabase(from source: URL) async -> Bool {
        let succeeded = await performDatabaseOperation { try await postgres.restoreDatabase(from: source) }
        await postgres.refreshPendingMigrations()
        await fetchRegisteredSources()
        await fetchRegisteredModels()
        await fetchCorpusStats()
        if succeeded {
            lastCommandOutput = "Restored the database from \(source.path)."
        }
        return succeeded
    }

    @discardableResult
    func promptAndSelectRootVolume() -> URL? {
        let url = volumeAccess.promptForRootVolumeSelection()
        if let url = url {
            lastCommandSucceeded = true
            lastCommandOutput = "Granted full volume access for: \(url.path)"
        }
        return url
    }

    @discardableResult
    func promptAndSelectSourceDirectory(slug: String? = nil, suggestedPath: String) -> URL? {
        let url = volumeAccess.promptForSourceDirectoryAccess(slug: slug, suggestedPath: suggestedPath)
        if let url = url {
            lastCommandSucceeded = true
            lastCommandOutput = "Granted access for '\(slug ?? suggestedPath)' at: \(url.path)"
            _ = testVolumeAccess()
        }
        return url
    }

    @discardableResult
    func promptTCCPermission(category: TCCPermissionCategory, sourceSlug: String? = nil, sourcePath: String? = nil) -> Bool {
        let handled = volumeAccess.promptForTCCPermission(category: category, sourceSlug: sourceSlug, sourcePath: sourcePath)
        if handled {
            _ = testVolumeAccess()
        }
        return handled
    }

    func openPrivacySettings(for category: TCCPermissionCategory = .fullDiskAccess) {
        volumeAccess.openPrivacySettings(for: category)
    }

    /// The App Store build's one grant for the usual sources: the home folder.
    @discardableResult
    func promptAndSelectHomeFolder() -> URL? {
        let url = volumeAccess.promptForHomeFolderSelection()
        if let url {
            lastCommandSucceeded = true
            lastCommandOutput = "Granted folder access for: \(url.path)"
        }
        return url
    }

    @discardableResult
    func testVolumeAccess() -> VolumeAccessTestResult {
        let sourceTuples = registeredSources.map { (slug: $0.slug, root: $0.root) }
        let result = volumeAccess.testFullVolumeAccess(sourcePaths: sourceTuples)
        lastCommandSucceeded = result.isAccessible
        lastCommandOutput = result.message
        return result
    }

    func revokeVolumeAccess() {
        volumeAccess.revokeAccess()
        lastCommandSucceeded = true
        lastCommandOutput = "Volume access revoked and saved bookmark cleared."
    }

    #if DEBUG
    func setRegisteredSourcesForTesting(_ sources: [RegisteredSource]) {
        self.registeredSources = sources
    }

    func setRegisteredModelsForTesting(_ models: [RegisteredModel]) {
        self.registeredModels = models
    }

    func setCorpusStatsForTesting(_ stats: CorpusStats) {
        self.corpusStats = stats
    }

    func setIngestingForTesting(_ isIngesting: Bool) {
        self.ingestService.setRunningForTesting(isIngesting)
    }

    func setScanningForTesting(source: String?, slugs: Set<String> = []) {
        self.scanningSource = source
        self.scanningSlugs = slugs
    }

    func setQueuesForTesting(ingest: [String] = [], awaitingScan: [String] = []) {
        self.ingestQueue = ingest
        self.sourcesAwaitingScan = awaitingScan
    }

    func setIngestingAllForTesting(_ running: Bool) {
        self.isIngestingAll = running
    }
    #endif

    /// Items a running scan has found: `sourceItems` in `source`, the one being walked, and
    /// `totalItems` across every source the scan has covered.
    struct ScanProgress: Equatable {
        var source: String
        var sourceItems: Int
        var totalItems: Int
    }

    /// Performs a scan on configured sources to calculate item counts and update expected element totals.
    @discardableResult
    /// `followedByIngest`: an ingest of every source runs right after this scan (maintenance, "Scan & Ingest
    /// All"), so the sources cancelled during it are kept for that ingest to skip. Any other scan drops them,
    /// or a later, unrelated ingest would skip them.
    func scanSources(source: String = "*", includeCode: Bool = false, followedByIngest: Bool = false) async -> Bool {
        guard !isIngesting, !isIngestingAll else {
            lastCommandSucceeded = false
            lastCommandOutput = "Cannot scan while ingestion is in progress."
            logger.info("Scan skipped because ingestion is in progress.")
            return false
        }
        guard !isScanning, scanningSource == nil else {
            lastCommandSucceeded = false
            lastCommandOutput = "A scan is already running."
            return false
        }
        guard postgres.status == .running, !isCancellingAll else { return false }
        scanningSource = source
        scanProgress = ScanProgress(source: source, sourceItems: 0, totalItems: 0)
        defer {
            scanningSource = nil
            scanningSlugs = []
            scanProgress = nil
            scanStoppedForRemoval = false
        }
        if source == "*" {
            sourcesCancelledFromRun.removeAll()
            await fetchRegisteredSources()
            scanningSlugs = Set(registeredSources.map(\.slug)).subtracting(sourcesBeingRemoved)
            // Cancelled while the sources were fetched, before the scan runner had anything to stop.
            guard !isCancellingAll else { return false }
        }
        let grpc = self.grpc
        let result = await scanner.run { [weak self] _ in
            try await grpc.scan(source: source, includeCode: includeCode) { status in
                guard status.phase != "finished" else { return }
                self?.scanProgress = ScanProgress(
                    source: status.source,
                    sourceItems: Int(status.sourceItems),
                    totalItems: Int(status.totalItems)
                )
            }.message
        }
        var succeeded = result.succeeded
        lastCommandOutput = result.output
        if !succeeded, scanStoppedForRemoval, !isCancellingAll {
            succeeded = true
            lastCommandOutput = "Scan stopped to remove a source; the rest of its counts are skipped."
        }
        lastCommandSucceeded = succeeded
        if !succeeded || !followedByIngest {
            // No ingest follows this scan, so nothing should skip these.
            sourcesCancelledFromRun.removeAll()
        }
        await fetchRegisteredSources()
        await fetchCorpusStats()
        return succeeded
    }

    /// Runs one operation over gRPC on the general runner and shows what it reports.
    /// `triggersMaintenance` schedules ingest + backfill afterwards (a new source or
    /// model has nothing indexed yet) when automatic maintenance is enabled.
    @discardableResult
    func runOperation(
        triggersMaintenance: Bool = false,
        _ operation: @escaping @MainActor (GarageGRPCService) async throws -> String
    ) async -> Bool {
        guard !commandInProgress else {
            lastCommandSucceeded = false
            lastCommandOutput = "A garage command is already running."
            return false
        }

        commandInProgress = true
        defer { commandInProgress = false }
        let grpc = self.grpc
        let result = await garage.run { _ in try await operation(grpc) }
        lastCommandOutput = result.output
        lastCommandSucceeded = result.succeeded

        if result.succeeded, triggersMaintenance {
            scheduleDebouncedMaintenanceTrigger()
        }

        return result.succeeded
    }

    /// Scan & Ingest of one source. The source waits in `ingestQueue` from the start of its scan until its
    /// ingest ends, so there is no moment between the scan and the ingest with nothing running: the page
    /// keeps its Stop button, and Stop (or the row's Cancel) in that hand-over takes the source out of the
    /// queue, so the ingest never starts.
    @discardableResult
    func scanAndIngestSource(slug: String, options: IngestOptions = .default) async -> Bool {
        guard !ingestQueue.contains(slug) else { return false }
        ingestQueue.append(slug)
        defer { ingestQueue.removeAll { $0 == slug } }
        guard await scanSources(source: slug, includeCode: options.includeCode) else { return false }
        guard ingestQueue.contains(slug), !isCancellingAll else { return false }
        return await ingestSource(slug: slug, options: options)
    }

    /// Runs ingestion through the configured execution mode (XPC helper or CLI) streaming real-time progress.
    @discardableResult
    func ingestSource(slug: String, options: IngestOptions = .default, mode: IngestExecutionMode? = nil) async -> Bool {
        if slug == "*" {
            return await ingestAllSources(options: options, mode: mode)
        }
        let result = await ingestService.ingest(
            slug: slug, options: options, mode: mode, namesContacts: Self.sourceNamesContacts(slug: slug, in: registeredSources)
        )
        await fetchRegisteredSources()
        await fetchCorpusStats()
        lastCommandSucceeded = result.succeeded
        lastCommandOutput = result.message ?? (result.succeeded ? "Ingestion completed" : "Ingestion failed")
        return result.succeeded
    }

    /// Whether a source's people are named from Contacts: only communications (Mail, Messages) carry
    /// handles to name, so only their ingest asks for Contacts access (App Review guideline 5.1.1).
    static func sourceNamesContacts(_ source: RegisteredSource) -> Bool {
        source.corpusClass.lowercased() == "communication"
    }

    static func sourceNamesContacts(slug: String, in sources: [RegisteredSource]) -> Bool {
        sources.first(where: { $0.slug == slug }).map(sourceNamesContacts) ?? false
    }

    /// Ingests all registered sources sequentially, looping over each source and streaming individual progress.
    @discardableResult
    func ingestAllSources(options: IngestOptions = .default, mode: IngestExecutionMode? = nil) async -> Bool {
        guard !isIngestingAll else {
            lastCommandSucceeded = false
            lastCommandOutput = "An ingest of every source is already running."
            return false
        }
        isIngestingAll = true
        defer { isIngestingAll = false }
        await fetchRegisteredSources()
        let sources = registeredSources
        guard !sources.isEmpty else {
            let msg = "No sources registered to ingest."
            logger.warning("\(msg, privacy: .public)")
            return false
        }
        // Sources cancelled during the scan before this ingest, or being removed, sit this run out.
        let skipped = sourcesCancelledFromRun.union(sourcesBeingRemoved)
        let queued = sources.filter { !skipped.contains($0.slug) }
        ingestService.clearProgressBySource()
        ingestService.setPendingSources(Set(queued.map(\.slug)))
        ingestQueue = queued.map(\.slug)
        defer {
            ingestQueue = []
            sourcesCancelledFromRun.removeAll()
            ingestService.clearPendingSources()
        }
        var allSucceeded = true
        var failures: [(slug: String, message: String)] = []
        lastIngestAllFailure = nil
        defer {
            lastIngestAllFailure = Self.ingestAllFailureSummary(failures)
        }
        // The queue, not `sources`, decides what runs next: `cancel(source:)` takes a source out of it,
        // and `cancelAll()` empties it. `IngestService.isCancelling` cannot stop the run, since it
        // resets as each source's ingest ends.
        while !ingestQueue.isEmpty {
            if isCancellingAll {
                logger.info("ingestAllSources stopped because every source was cancelled.")
                break
            }
            let slug = ingestQueue.removeFirst()
            guard let source = queued.first(where: { $0.slug == slug }) else { continue }
            ingestService.markSourceActive(source.slug)
            let sourceOptions = IngestOptions(
                includeCode: options.includeCode || source.includeCode,
                limit: options.limit,
                force: options.force,
                grpcHost: options.grpcHost,
                grpcPort: options.grpcPort
            )
            let result = await ingestService.ingest(
                slug: source.slug, options: sourceOptions, mode: mode, namesContacts: Self.sourceNamesContacts(source)
            )
            await fetchRegisteredSources()
            await fetchCorpusStats()
            if !result.succeeded {
                allSucceeded = false
                failures.append((source.slug, result.message ?? ""))
            }
        }
        return allSucceeded
    }

    /// "notes: permission denied" for one failed source, "2 sources failed: notes, mail" for more.
    nonisolated static func ingestAllFailureSummary(_ failures: [(slug: String, message: String)]) -> String? {
        guard let first = failures.first else { return nil }
        if failures.count == 1 {
            let message = first.message.trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? "\(first.slug) failed" : "\(first.slug): \(message)"
        }
        return "\(failures.count) sources failed: \(failures.map(\.slug).joined(separator: ", "))"
    }

    /// Embeds pending chunks for `model` (nil = every registered model) on the backfill
    /// runner, logging each progress step the server streams back.
    @discardableResult
    func runBackfill(model: String? = nil) async -> Bool {
        let grpc = self.grpc
        backfillProgress = nil
        let result = await backfill.run { runner in
            _ = try await grpc.backfill(model: model) { status in
                if !status.message.isEmpty {
                    runner.appendLog(status.message)
                }
                // "started" and "progress" carry the model's counts; the per-model outcomes end it.
                if status.phase == "started" || status.phase == "progress" {
                    self.backfillProgress = BackfillProgress(
                        model: status.modelSlug,
                        embedded: Int(status.embedded),
                        total: Int(status.total)
                    )
                }
            }
            return ""
        }
        backfillProgress = nil
        await fetchCorpusStats()
        await fetchRegisteredModels()
        return result.succeeded
    }

    /// Distills documents into facts ("glean facts") on the enrich-facts runner: every
    /// document of `source`, or just `documentID` when given. `staleOnly` skips a document a prompt
    /// already distilled with the same prompt text, content and model.
    @discardableResult
    func runEnrichFacts(source: String = "*", documentID: Int64? = nil, prompts: [String] = [], staleOnly: Bool = false) async -> Bool {
        let grpc = self.grpc
        enrichFactsProgress = nil
        let result = await enrichFacts.run { runner in
            // Inside the runner, so a run refused as "already running" never loads or unloads.
            await self.loadFactsModelForDistilling(runner)
            let finished = try await grpc.enrichFacts(source: source, documentID: documentID, prompts: prompts, staleOnly: staleOnly) { status in
                // The summary is logged once, as the operation's result.
                if status.phase != "finished", !status.message.isEmpty {
                    runner.appendLog(status.message, stream: status.error.isEmpty ? .stdout : .stderr)
                }
                if status.phase == "started" || status.phase == "document" {
                    self.enrichFactsProgress = EnrichFactsProgress(
                        index: Int(status.index),
                        total: Int(status.total),
                        documentURI: status.documentUri.isEmpty ? nil : status.documentUri
                    )
                }
            }
            return finished?.message ?? ""
        }
        enrichFactsProgress = nil
        await unloadFactsModelAfterDistilling()
        return result.succeeded
    }

    /// Distills the potential facts into distinct facts ("Distill Facts"): groups restatements by
    /// their embeddings and has the local model state each group once, on the enrich-facts runner.
    /// `full` ("Regroup All Facts") regroups the corpus; otherwise only new facts are placed.
    @discardableResult
    func runClusterFacts(full: Bool = false) async -> Bool {
        let grpc = self.grpc
        let result = await enrichFacts.run { runner in
            await self.loadFactsModelForDistilling(runner)
            let finished = try await grpc.clusterFacts(full: full) { status in
                if status.phase != "finished", !status.message.isEmpty {
                    runner.appendLog(status.message, stream: .stdout)
                }
                for error in status.errors {
                    runner.appendLog(error, stream: .stderr)
                }
            }
            if let finished, !finished.graph.isEmpty {
                runner.appendLog(finished.graph, stream: .stdout)
            }
            return finished?.message ?? ""
        }
        await unloadFactsModelAfterDistilling()
        return result.succeeded
    }

    /// XPC ingestion logs as a chronologically ordered stream.
    var combinedIngestLogs: [LogLine] {
        ingestService.logs.sorted { $0.date < $1.date }
    }

    func clearLogs(for sourceName: String) {
        switch sourceName {
        case "Postgres":
            postgres.clearLogs()
            osLogStreamService.clearLogs(for: .postgres)
        case "garage CLI", "garage", "App":
            garage.clearLogs()
            osLogStreamService.clearLogs(for: .garage)
        case "Ingest", "Ingest XPC", "Ingest (XPC)", "Ingest (CLI)":
            ingestService.clearLogs()
            osLogStreamService.clearLogs(for: .ingest)
        case "Embedding", "Backfill", "Embed":
            backfill.clearLogs()
            osLogStreamService.clearLogs(for: .embed)
        case "Glean Facts", "Enrich Facts", "garage enrich-facts":
            enrichFacts.clearLogs()
        case "Scan", "garage scan":
            scanner.clearLogs()
        case "MCP Server":
            mcp.clearLogs()
            osLogStreamService.clearLogs(for: .mcp)
        case "Index Manager", "gRPC Server":
            grpc.clearLogs()
            osLogStreamService.clearLogs(for: .grpc)
        case "Built-in Engine", "Llama Service", "Llama XPC", "LLaMa":
            llama.clearLogs()
            osLogStreamService.clearLogs(for: .llama)
        case "Model Downloader", "Model Download XPC", "Downloader":
            modelDownload.clearLogs()
            osLogStreamService.clearLogs(for: .modelDownload)
        case "XPC Services", "XPC Service", "XPC":
            xpcServices.clearLogs()
        case "Unified Log", "Unified Logs", "Unified (OSLog)", "OSLog", "System Log":
            osLogStreamService.clearLogs()
        default:
            osLogStreamService.clearLogs()
        }
    }

    /// Performs search using the gRPC server endpoint.
    func search(
        query: String,
        mode: String = "hybrid",
        model: String? = nil,
        limit: Int = 10,
        corpusClasses: [String] = [],
        trustTiers: [String] = [],
        sources: [String] = [],
        author: String? = nil,
        full: Bool = false
    ) async throws -> [SearchResultItem] {
        let response = try await grpc.search(
            query: query,
            mode: mode,
            model: model,
            limit: limit,
            corpusClasses: corpusClasses,
            trustTiers: trustTiers,
            sources: sources,
            author: author,
            full: full
        )
        return response.hits.map { SearchResultItem(hit: $0) }
    }

    /// Lists documents via the gRPC server, optionally filtered by source/class/trust/query.
    func listDocuments(
        source: String? = nil,
        corpusClass: String? = nil,
        trustTier: String? = nil,
        query: String? = nil,
        limit: Int = 200,
        offset: Int = 0
    ) async throws -> (items: [DocumentListItem], totalCount: Int) {
        let response = try await grpc.listDocuments(
            source: source,
            corpusClass: corpusClass,
            trustTier: trustTier,
            query: query,
            limit: limit,
            offset: offset
        )
        return (response.documents.map { DocumentListItem(summary: $0) }, Int(response.totalCount))
    }

    /// Fetches a single document's metadata and chunks via the gRPC server.
    func getDocument(documentID: Int64) async throws -> DocumentDetailItem {
        let response = try await grpc.getDocument(documentID: documentID)
        return DocumentDetailItem(response: response)
    }

    private func configureScheduledMaintenance() {
        scheduledMaintenanceTask?.cancel()
        scheduledMaintenanceTask = nil

        guard hasLaunched, scheduledMaintenanceEnabled else { return }

        let interval = UInt64(scheduledMaintenanceInterval * 1_000_000_000)
        scheduledMaintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.runScheduledMaintenance()
            }
        }
    }

    var isIngesting: Bool {
        ingestService.isRunning
    }

    var isScanning: Bool {
        scanner.isRunning
    }

    /// The scan's own Stop stops everything after it too: in a maintenance run or "Scan & Ingest All" the
    /// ingest and backfill that would follow are part of the same run.
    func cancelScan() {
        cancelAll()
    }

    /// True while a scan or ingest covers `slug`: it cannot be removed or reconciled until that ends.
    /// A run over every source covers only the sources registered when it started, so a new source
    /// can be added meanwhile (`queueSourceScan` then scans it once the run ends).
    func isBusy(source slug: String) -> Bool {
        let scanning = scanningSource.map { $0 == slug || ($0 == "*" && scanningSlugs.contains(slug)) } ?? false
        let ingesting: Bool
        if !ingestService.isRunning {
            ingesting = false
        } else if !ingestService.runSources.isEmpty {
            ingesting = ingestService.runSources.contains(slug) || ingestService.currentSource == slug
        } else {
            let current = ingestService.currentSource
            ingesting = current == nil || current == "*" || current == slug
        }
        return scanning || ingesting
    }

    /// Queues a scan and ingest of `slug`, added while a scan or ingest ran: that run never walks it,
    /// so it gets its own once the run ends, followed by a backfill, as automatic maintenance would.
    func queueSourceScan(_ slug: String) {
        guard scheduledMaintenanceEnabled else { return }
        if firstRun.isActive {
            isMaintenanceDeferredForFirstRun = true
            return
        }
        if !sourcesAwaitingScan.contains(slug) {
            sourcesAwaitingScan.append(slug)
        }
        guard queuedSourceScanTask == nil else { return }
        queuedSourceScanTask = Task { [weak self] in
            await self?.runQueuedSourceScans()
        }
    }

    /// No scan, ingest or backfill runs, nor maintenance between its steps.
    private var isIdleForQueuedScans: Bool {
        !isScanning && scanningSource == nil && !isIngesting && !isIngestingAll && !backfill.isRunning
            && !isMaintenanceRunning
    }

    private func runQueuedSourceScans() async {
        defer { queuedSourceScanTask = nil }
        var ingestedAny = false
        while !sourcesAwaitingScan.isEmpty {
            // Wait until the running job has been over for a second on two looks in a row: a scan
            // started from the Sources page is followed at once by its ingest, and starting in that
            // gap would turn the ingest away.
            var idleLooks = 0
            while idleLooks < 2 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                idleLooks = isIdleForQueuedScans ? idleLooks + 1 : 0
            }
            // `cancelAll()` or `cancel(source:)` may have emptied the queue while this waited.
            guard postgres.status == .running, !isCancellingAll, !sourcesAwaitingScan.isEmpty else { break }
            let slug = sourcesAwaitingScan.removeFirst()
            guard !sourcesBeingRemoved.contains(slug) else { continue }
            let includeCode = registeredSources.first(where: { $0.slug == slug })?.includeCode ?? false
            if await scanSources(source: slug, includeCode: includeCode) {
                let options = IngestOptions(includeCode: includeCode)
                if await ingestSource(slug: slug, options: options, mode: .xpcService) {
                    ingestedAny = true
                }
            }
        }
        if ingestedAny, !Task.isCancelled, !isCancellingAll {
            _ = await runBackfill()
            await fetchCorpusStats()
        }
    }

    /// Every Cancel Ingest and Stop button cancels the whole run, not just the source being ingested.
    func cancelIngest() async {
        cancelAll()
    }

    /// A scan, ingest, queued source scan or maintenance run is under way: what `cancelAll()` stops.
    var hasCancellableWork: Bool {
        isScanning || scanningSource != nil || isIngesting || isIngestingAll || isMaintenanceRunning
            || !sourcesAwaitingScan.isEmpty || !ingestQueue.isEmpty || queuedSourceScanTask != nil
    }

    /// Stops everything: empties the queues (the sources an ingest of every source has yet to reach, and
    /// the sources waiting for their own scan), then cancels the scan or ingest in progress, and the
    /// backfill when maintenance or the queued scans started it. `isCancellingAll` stays set until that
    /// work has ended, so no step after it starts.
    func cancelAll() {
        guard hasCancellableWork, !isCancellingAll else { return }
        isCancellingAll = true
        logger.info("Cancelling every queued and running scan and ingest.")
        pendingMaintenanceTask?.cancel()
        pendingMaintenanceTask = nil
        sourcesAwaitingScan.removeAll()
        ingestQueue.removeAll()
        ingestService.dropPendingSources()
        scanner.cancel()
        if isMaintenanceRunning || queuedSourceScanTask != nil {
            backfill.cancel()
        }
        if isUpdatingEverything {
            enrichFacts.cancel()
        }
        if ingestService.isRunning {
            let service = ingestService
            Task { _ = await service.cancel() }
        }
        Task { [weak self] in
            // Each cancelled step ends at its next progress step; poll rather than track every path.
            while self?.hasCancellableWork == true {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            self?.isCancellingAll = false
            self?.sourcesCancelledFromRun.removeAll()
        }
    }

    /// `slug` waits in a queue or is being scanned or ingested now: what its own Cancel stops. Unlike
    /// `isBusy(source:)`, a source an ingest of every source has already finished is not pending.
    func isPending(source slug: String) -> Bool {
        if ingestQueue.contains(slug) || sourcesAwaitingScan.contains(slug) { return true }
        if ingestService.isRunning, ingestService.currentSource == slug { return true }
        return scanningSource == slug || (scanningSource == "*" && scanningSlugs.contains(slug))
    }

    /// `slug` waits in a queue and has not started.
    func isQueued(source slug: String) -> Bool {
        ingestQueue.contains(slug) || sourcesAwaitingScan.contains(slug)
    }

    /// Cancels `slug` alone. It leaves the queues, and its scan or ingest stops when it is the one running;
    /// an ingest of every source goes on with the next source. A "*" scan walks every source in one server
    /// call and cannot skip one, so the ingest after that scan skips it instead.
    func cancel(source slug: String) async {
        sourcesAwaitingScan.removeAll { $0 == slug }
        ingestQueue.removeAll { $0 == slug }
        ingestService.dropSource(slug)
        if scanningSource == slug {
            scanner.cancel()
        } else if scanningSource == "*", scanningSlugs.contains(slug) {
            sourcesCancelledFromRun.insert(slug)
            scanningSlugs.remove(slug)
        }
        if ingestService.isRunning, ingestService.currentSource == slug {
            _ = await ingestService.cancel()
        }
    }

    /// Removes `slug`, cancelling whatever covers it first (`cancel(source:)`) and waiting for that to stop,
    /// so the removal never races a scan or ingest of it. A "*" scan stops as well: it holds the rows it has
    /// counted until it ends. The ingest after that scan still runs, for the other sources.
    @discardableResult
    func removeSource(slug: String) async -> Bool {
        guard !sourcesBeingRemoved.contains(slug) else { return false }
        sourcesBeingRemoved.insert(slug)
        defer { sourcesBeingRemoved.remove(slug) }
        let stopsScanOfAll = scanningSource == "*" && scanningSlugs.contains(slug)
        if stopsScanOfAll {
            scanStoppedForRemoval = true
            scanner.cancel()
        }
        await cancel(source: slug)
        var looks = 0
        while isBusy(source: slug) || (stopsScanOfAll && scanningSource != nil) {
            guard looks < Self.removalWaitLooks else {
                lastCommandSucceeded = false
                lastCommandOutput = "Could not remove \(slug): its scan or ingest has not stopped yet. Try again shortly."
                return false
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
            looks += 1
        }
        // Another removal, or any other operation, holds the general runner: wait for it rather than be
        // turned away with "A garage command is already running".
        while commandInProgress {
            guard looks < Self.removalWaitLooks else {
                lastCommandSucceeded = false
                lastCommandOutput = "Could not remove \(slug): another operation is still running. Try again shortly."
                return false
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
            looks += 1
        }
        return await runOperation { try await $0.removeSource(slug: slug).message }
    }

    /// A quarter second each: a minute for a cancelled scan or ingest to reach its next progress step.
    static let removalWaitLooks = 240

    private func runScheduledMaintenance() async {
        // The assistant registers sources and then models, one operation at a time. A scan
        // started by the first source added would hold `runOperation` for as long as it
        // takes to walk the folder, and every later add would fail with "A garage command is
        // already running." Indexing also belongs after the models are chosen, so the backfill
        // runs with them: hold it until the assistant closes.
        if firstRun.isActive {
            isMaintenanceDeferredForFirstRun = true
            return
        }
        // A running scan would turn this one away and leave the ingest below racing the ingest that
        // follows it; a source added meanwhile waits in `sourcesAwaitingScan` instead.
        guard postgres.status == .running, !isScanning, !ingestService.isRunning, !backfill.isRunning,
              !isMaintenanceRunning else { return }
        isMaintenanceRunning = true
        defer { isMaintenanceRunning = false }
        await runPipeline(gleansFacts: false)
    }

    /// The whole pipeline once, now, whatever the automatic-updates setting: scan, ingest, embed with
    /// every model, then glean facts from the documents no enabled prompt has distilled yet. The
    /// Sources page's "Update Everything" button. Stop (`cancelAll`) ends it at the current step.
    func updateEverything() async {
        guard postgres.status == .running, !hasCancellableWork, !backfill.isRunning, !enrichFacts.isRunning,
              !isUpdatingEverything else { return }
        isUpdatingEverything = true
        isMaintenanceRunning = true
        defer {
            isMaintenanceRunning = false
            isUpdatingEverything = false
        }
        await runPipeline(gleansFacts: true)
    }

    /// Scan, then ingest every source, then embed, then (for "Update Everything") glean facts, each
    /// step skipped once Stop was pressed. `lastCommandSucceeded` reports the run as a whole.
    private func runPipeline(gleansFacts: Bool) async {
        _ = await scanSources(followedByIngest: true)
        guard !isCancellingAll else { return }
        let ingestSucceeded = await ingestAllSources(mode: .xpcService)
        guard !isCancellingAll else { return }
        let backfillSucceeded = await runBackfill()
        var factsSucceeded = true
        if gleansFacts, !isCancellingAll {
            factsSucceeded = await runEnrichFacts(staleOnly: true)
        }
        await fetchCorpusStats()
        lastCommandSucceeded = ingestSucceeded && backfillSucceeded && factsSucceeded
    }

    /// The "also run when Garage starts" option: once per launch, after every system is go: the
    /// database is up, the gRPC backend the scan goes through is listening, and the helpers have
    /// taken the database URL and the backend's address (`startBackend`), since a run kicked off
    /// before that fails in the ingest helper. The setup assistant, when it is open, holds the run
    /// until it closes (`runScheduledMaintenance`). Debounced, so a source the assistant or
    /// garage.json registers right after start shares the run rather than starting its own.
    func runMaintenanceAtLaunchIfEnabled() {
        guard maintenanceAtLaunchPending, postgres.status == .running else { return }
        maintenanceAtLaunchPending = false
        guard scheduledMaintenanceEnabled, maintenanceRunsAtLaunch else { return }
        let configured = helperConfigurationTask
        Task { [weak self] in
            await configured?.value
            guard let self, self.postgres.status == .running, self.grpc.status == .running else { return }
            self.scheduleDebouncedMaintenanceTrigger()
        }
    }

    /// Kicks off ingest + embedding backfill for all sources when the user has enabled
    /// automatic maintenance, e.g. right after a new source or model is registered.
    func triggerMaintenanceIfEnabled() async {
        guard scheduledMaintenanceEnabled else { return }
        await runScheduledMaintenance()
    }

    /// Runs the maintenance the setup assistant held back (see `runScheduledMaintenance`), once
    /// it has closed. A no-op when nothing came due.
    func resumeMaintenanceAfterFirstRun() {
        guard isMaintenanceDeferredForFirstRun else { return }
        isMaintenanceDeferredForFirstRun = false
        scheduleDebouncedMaintenanceTrigger()
    }

    /// Debounces `triggerMaintenanceIfEnabled()` so a rapid burst of add-source/
    /// register-model calls (e.g. "Add All") coalesces into a single run that
    /// starts once the burst settles, rather than each add racing `runOperation`'s
    /// `commandInProgress` guard against the scan/ingest the previous add kicked off.
    private func scheduleDebouncedMaintenanceTrigger() {
        pendingMaintenanceTask?.cancel()
        pendingMaintenanceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.triggerMaintenanceIfEnabled()
        }
    }

    @discardableResult
    private func performDatabaseOperation(_ operation: () async throws -> Void) async -> Bool {
        do {
            try await operation()
            lastCommandSucceeded = true
            lastCommandOutput = "Completed successfully."
            return true
        } catch {
            lastCommandSucceeded = false
            lastCommandOutput = error.localizedDescription
            return false
        }
    }

    // MARK: - Combined Ingest Progress Tracking

    /// Total number of expected documents from prior scan across active / registered sources.
    var combinedIngestTotalExpected: Int {
        // If ingesting a single source and not in a batch run:
        if ingestService.runSources.count <= 1,
           let current = ingestService.currentSource,
           current != "*",
           let src = registeredSources.first(where: { $0.slug == current }) {
            if src.expectedElements > 0 {
                return src.expectedElements
            }
            if let latest = ingestService.latestProgress, latest.totalItems > 0 {
                return latest.totalItems
            }
            return 0
        }

        // Multi-source / all sources batch run:
        let totalFromScan = corpusStats.totalExpectedElements > 0
            ? corpusStats.totalExpectedElements
            : registeredSources.reduce(0) { $0 + $1.expectedElements }
        if totalFromScan > 0 {
            return totalFromScan
        }

        // If no prior scan total, sum totalItems from known progress updates
        let totalFromUpdates = registeredSources.reduce(0) { sum, source in
            if let prog = ingestService.progressBySource[source.slug] {
                return sum + prog.totalItems
            }
            return sum
        }
        if totalFromUpdates > 0 {
            return totalFromUpdates
        }

        return ingestService.latestProgress?.totalItems ?? 0
    }

    /// Total number of documents processed (seen / scanned) so far in the current ingestion run.
    var combinedIngestProcessedCount: Int {
        // If single source:
        if ingestService.runSources.count <= 1,
           let current = ingestService.currentSource,
           current != "*",
           let src = registeredSources.first(where: { $0.slug == current }) {
            let seen = ingestService.latestProgress?.seen ?? 0
            if src.expectedElements > 0 {
                return min(src.expectedElements, seen)
            }
            return seen
        }

        // Multi-source:
        let totalExpected = combinedIngestTotalExpected
        var totalProcessed = 0

        for source in registeredSources {
            if source.slug == ingestService.currentSource {
                let seen = ingestService.latestProgress?.seen ?? 0
                if source.expectedElements > 0 {
                    totalProcessed += min(source.expectedElements, seen)
                } else {
                    totalProcessed += seen
                }
            } else if let prog = ingestService.progressBySource[source.slug] {
                if source.expectedElements > 0 {
                    totalProcessed += source.expectedElements
                } else if prog.seen > 0 {
                    totalProcessed += prog.seen
                } else {
                    totalProcessed += prog.indexed
                }
            }
        }

        if totalExpected > 0 {
            return min(totalExpected, totalProcessed)
        }
        return totalProcessed
    }

    /// Combined progress fraction from 0.0 to 1.0 based on combined documents from prior scan.
    var combinedIngestProgressFraction: Double {
        let total = combinedIngestTotalExpected
        let processed = combinedIngestProcessedCount
        if total > 0 {
            return min(1.0, max(0.0, Double(processed) / Double(total)))
        }
        if let latest = ingestService.latestProgress {
            return latest.progress
        }
        return 0.0
    }

    /// Formatted percentage string for the combined ingest progress (e.g. "45%").
    var combinedIngestProgressPercent: String {
        let fraction = combinedIngestProgressFraction
        return "\(Int((fraction * 100.0).rounded()))%"
    }

    var combinedIngestIndexedCount: Int {
        var count = 0
        for source in registeredSources {
            if source.slug == ingestService.currentSource, let latest = ingestService.latestProgress {
                count += latest.indexed
            } else if let prog = ingestService.progressBySource[source.slug] {
                count += prog.indexed
            }
        }
        if count == 0, let latest = ingestService.latestProgress {
            return latest.indexed
        }
        return count
    }

    var combinedIngestSkippedCount: Int {
        var count = 0
        for source in registeredSources {
            if source.slug == ingestService.currentSource, let latest = ingestService.latestProgress {
                count += latest.skipped
            } else if let prog = ingestService.progressBySource[source.slug] {
                count += prog.skipped
            }
        }
        if count == 0, let latest = ingestService.latestProgress {
            return latest.skipped
        }
        return count
    }

    var combinedIngestFailedCount: Int {
        var count = 0
        for source in registeredSources {
            if source.slug == ingestService.currentSource, let latest = ingestService.latestProgress {
                count += latest.failed
            } else if let prog = ingestService.progressBySource[source.slug] {
                count += prog.failed
            }
        }
        if count == 0, let latest = ingestService.latestProgress {
            return latest.failed
        }
        return count
    }

    var combinedIngestPlaceholdersCount: Int {
        var count = 0
        for source in registeredSources {
            if source.slug == ingestService.currentSource, let latest = ingestService.latestProgress {
                count += latest.placeholders
            } else if let prog = ingestService.progressBySource[source.slug] {
                count += prog.placeholders
            }
        }
        if count == 0, let latest = ingestService.latestProgress {
            return latest.placeholders
        }
        return count
    }

    var combinedIngestChunksCount: Int {
        var count = 0
        for source in registeredSources {
            if source.slug == ingestService.currentSource, let latest = ingestService.latestProgress {
                count += latest.chunksWritten
            } else if let prog = ingestService.progressBySource[source.slug] {
                count += prog.chunksWritten
            }
        }
        if count == 0, let latest = ingestService.latestProgress {
            return latest.chunksWritten
        }
        return count
    }

    var combinedIngestItemType: String {
        ingestService.latestProgress?.itemType ?? "documents"
    }

    var combinedIngestTitle: String {
        if ingestService.runSources.count <= 1, let current = ingestService.currentSource, current != "*" {
            return current
        }
        if let current = ingestService.currentSource, !current.isEmpty, current != "*" {
            return "Ingesting \(current)"
        }
        return "Ingestion"
    }

    var combinedIngestStatusMessage: String {
        let total = combinedIngestTotalExpected
        let processed = combinedIngestProcessedCount
        let indexed = combinedIngestIndexedCount
        let skipped = combinedIngestSkippedCount
        let itemType = combinedIngestItemType
        if total > 0 {
            return "\(processed) of \(total) \(itemType) (\(indexed) indexed, \(skipped) skipped)"
        }
        if let msg = ingestService.latestProgress?.message, !msg.isEmpty {
            return msg
        }
        return "\(indexed) indexed, \(skipped) skipped"
    }

    var statusSummary: String {
        switch postgres.status {
        case .stopped: "Stopped"
        case .starting: "Starting…"
        case .running: "Running on port \(postgres.port)"
        case .stopping: "Stopping…"
        case .needsMigration: "Needs Migration"
        case .failed(let message): "Failed: \(message)"
        }
    }

    // MARK: - Single Source Ingest Progress Tracking

    /// Total number of expected documents for a specific source (from prior scan or progress updates).
    func sourceTotalExpected(for sourceSlug: String) -> Int {
        if let src = registeredSources.first(where: { $0.slug == sourceSlug }), src.expectedElements > 0 {
            return src.expectedElements
        }
        if let prog = ingestService.progressBySource[sourceSlug], prog.totalItems > 0 {
            return prog.totalItems
        }
        if ingestService.currentSource == sourceSlug, let latest = ingestService.latestProgress, latest.totalItems > 0 {
            return latest.totalItems
        }
        return 0
    }

    /// Number of documents processed (seen / scanned) for a specific source.
    func sourceProcessedCount(for sourceSlug: String) -> Int {
        if ingestService.currentSource == sourceSlug, let latest = ingestService.latestProgress {
            let total = sourceTotalExpected(for: sourceSlug)
            if total > 0 {
                return min(total, latest.seen)
            }
            return latest.seen
        }
        if let prog = ingestService.progressBySource[sourceSlug] {
            if let src = registeredSources.first(where: { $0.slug == sourceSlug }), src.expectedElements > 0 {
                return src.expectedElements
            }
            return prog.seen > 0 ? prog.seen : prog.indexed
        }
        if let src = registeredSources.first(where: { $0.slug == sourceSlug }) {
            return src.documentCount
        }
        return 0
    }

    /// Progress fraction from 0.0 to 1.0 for a specific single source based on its items.
    func sourceProgressFraction(for sourceSlug: String) -> Double {
        let total = sourceTotalExpected(for: sourceSlug)
        let processed = sourceProcessedCount(for: sourceSlug)
        if total > 0 {
            return min(1.0, max(0.0, Double(processed) / Double(total)))
        }
        if ingestService.currentSource == sourceSlug, let latest = ingestService.latestProgress {
            return latest.progress
        }
        if let prog = ingestService.progressBySource[sourceSlug] {
            return prog.progress
        }
        return 0.0
    }

    /// Formatted percentage string for a specific single source (e.g. "50%").
    func sourceProgressPercent(for sourceSlug: String) -> String {
        let fraction = sourceProgressFraction(for: sourceSlug)
        return "\(Int((fraction * 100.0).rounded()))%"
    }

    var statusColor: Color {
        switch postgres.status {
        case .running: .green
        case .starting, .stopping, .needsMigration: .yellow
        case .stopped: .secondary
        case .failed: .red
        }
    }
}

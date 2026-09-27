import Foundation
import Combine
import OSLog
import PythonXPCService

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag", category: "FirstRun")

// MARK: - Preferences

/// UserDefaults keys controlling the first-run setup assistant.
enum FirstRunPreferences {
    /// Set once the user finishes (or explicitly skips) the setup assistant.
    static let completedKey = "garage.firstRun.completed"
}

extension Notification.Name {
    /// Posted when the setup assistant is re-opened on demand (app menu, menu
    /// bar) so open windows dismiss their splash sheet; the assistant itself is
    /// started on `AppState.firstRun`, not by this notification.
    static let garageShowFirstRun = Notification.Name("me.rickmark.garage-rag.showFirstRun")
}

// MARK: - Steps

/// The pages of the setup assistant, in order.
enum FirstRunStep: Int, CaseIterable, Identifiable, Comparable {
    case settingUp = 0
    case selectData = 1
    case selectModels = 2
    case setupAgent = 3

    var id: Int { rawValue }

    static func < (lhs: FirstRunStep, rhs: FirstRunStep) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: String {
        switch self {
        case .settingUp: "Setting things up"
        case .selectData: "Select your data"
        case .selectModels: "Select your models"
        case .setupAgent: "Set up your assistant"
        }
    }

    var symbol: String {
        switch self {
        case .settingUp: "gearshape.2"
        case .selectData: "folder.badge.plus"
        case .selectModels: "cpu"
        case .setupAgent: "sparkles"
        }
    }

    var next: FirstRunStep? {
        FirstRunStep(rawValue: rawValue + 1)
    }

    var previous: FirstRunStep? {
        FirstRunStep(rawValue: rawValue - 1)
    }
}

// MARK: - Service readiness

/// A single row on the "Setting things up" page.
struct FirstRunServiceCheck: Identifiable, Equatable {
    enum State: Equatable {
        case pending
        case inProgress
        case ready
        case failed(String)

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }

        var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    let id: String
    let title: String
    let detail: String
    let state: State
}

/// Pure mapping from service statuses to the readiness checklist, kept free
/// of `AppState` so it can be unit-tested without spinning up services.
enum FirstRunReadiness {
    static func checks(
        postgres: PostgresStatus,
        pendingMigrations: [String],
        isApplyingMigrations: Bool,
        grpc: GarageGRPCStatus,
        mcp: GarageMCPStatus
    ) -> [FirstRunServiceCheck] {
        let database: FirstRunServiceCheck.State = switch postgres {
        case .stopped: .pending
        case .starting, .stopping: .inProgress
        case .running: .ready
        case .needsMigration: .inProgress
        case .failed(let message): .failed(message)
        }

        let schema: FirstRunServiceCheck.State
        switch postgres {
        case .running where pendingMigrations.isEmpty:
            schema = .ready
        case .running, .needsMigration:
            schema = isApplyingMigrations ? .inProgress : .pending
        case .failed(let message):
            schema = .failed(message)
        default:
            schema = .pending
        }

        let grpcState: FirstRunServiceCheck.State = switch grpc {
        case .stopped: database.isReady ? .inProgress : .pending
        case .starting, .stopping: .inProgress
        case .running: .ready
        case .failed(let message): .failed(message)
        }

        let mcpState: FirstRunServiceCheck.State = switch mcp {
        case .stopped: database.isReady ? .inProgress : .pending
        case .starting, .stopping: .inProgress
        case .running: .ready
        case .failed(let message): .failed(message)
        }

        return [
            FirstRunServiceCheck(
                id: "postgres",
                title: "Database",
                detail: "Starting the bundled PostgreSQL + pgvector instance",
                state: database
            ),
            FirstRunServiceCheck(
                id: "schema",
                title: "Schema",
                detail: pendingMigrations.isEmpty ? "Applying schema migrations" : "Applying \(pendingMigrations.count) pending migration\(pendingMigrations.count == 1 ? "" : "s")",
                state: schema
            ),
            FirstRunServiceCheck(
                id: "grpc",
                title: "Index Manager",
                detail: "Starting the service that runs ingest, search and models",
                state: grpcState
            ),
            FirstRunServiceCheck(
                id: "mcp",
                title: "MCP server",
                detail: "Starting the local MCP endpoint your assistants connect to",
                state: mcpState
            ),
        ]
    }

    /// Everything the rest of the assistant depends on is up. The MCP server
    /// is deliberately not required: its page can start it on demand, and a
    /// port clash must not trap the user on the first page.
    static func isReady(_ checks: [FirstRunServiceCheck]) -> Bool {
        checks.filter { requiredIDs.contains($0.id) }.allSatisfy { $0.state.isReady }
    }

    /// Any row failed, including the optional MCP server.
    static func hasFailure(_ checks: [FirstRunServiceCheck]) -> Bool {
        checks.contains { $0.state.isFailed }
    }

    /// A row the assistant cannot proceed without has failed.
    static func hasBlockingFailure(_ checks: [FirstRunServiceCheck]) -> Bool {
        checks.filter { requiredIDs.contains($0.id) }.contains { $0.state.isFailed }
    }

    private static let requiredIDs: Set<String> = ["postgres", "schema", "grpc"]
}

// MARK: - Source templates

/// A ready-made data source the user can pick on the "Select your data" page.
struct FirstRunSourceTemplate: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let slug: String
    let root: String
    let kind: String
    let corpusClass: String
    let trust: String
    /// Whether the template's root exists on this machine. Unavailable
    /// templates are still listed (so the user learns what Garage can index)
    /// but cannot be selected.
    let isAvailable: Bool
    /// True for the extra entries the user picked through the folder chooser.
    let isCustom: Bool
    /// Mail or Messages that macOS will not let Garage read: the folder is there but its contents
    /// are behind Full Disk Access. Such a template is unavailable, with its own badge.
    var needsFullDiskAccess = false

    var isCommunication: Bool { corpusClass == "communication" }

    /// The registration the AddSource RPC takes, matching what the Sources page sends.
    var spec: SourceSpec {
        SourceSpec(slug: slug, root: root, kind: kind, corpusClass: corpusClass, trust: trust)
    }

    /// A template root as a path on disk: `~` and `~/…` against `home`; an absolute root (the
    /// Dropbox folder `info.json` names may sit on another volume) stays as it is.
    static func resolvedPath(_ root: String, home: URL) -> String {
        if root == "~" { return home.path }
        if root.hasPrefix("~/") { return home.appendingPathComponent(String(root.dropFirst(2))).path }
        return root
    }

    /// The built-in templates, with availability resolved against the file
    /// system. `home`, `exists` and `readable` are injectable so tests can pin them.
    ///
    /// `home` is the account's real home folder, also in the sandbox, where
    /// `homeDirectoryForCurrentUser` is the app's container. Mail and Messages count
    /// as available only when their contents can be listed: macOS lets anyone see
    /// that `~/Library/Mail` exists but keeps what is inside behind Full Disk Access.
    /// `assumeAvailable` (the sandbox before any folder is granted, when nothing
    /// outside the container can be checked) marks every template available.
    static func builtIn(
        home: URL = URL(fileURLWithPath: GarageAppGroup.realHomeDirectory, isDirectory: true),
        assumeAvailable: Bool = false,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        readable: (String) -> Bool = FirstRunSourceTemplate.canListContents
    ) -> [FirstRunSourceTemplate] {
        /// Availability of a root, `~/…` resolved against `home`, an absolute path as it is.
        func available(_ root: String) -> Bool {
            exists(resolvedPath(root, home: home))
        }
        /// Wraps one of the shared `SourcePreset`s so the assistant can never
        /// disagree with the Sources/Status pages on a slug, root or class.
        func shared(_ preset: SourcePreset, subtitle: String, symbol: String) -> FirstRunSourceTemplate {
            if preset.spec.corpusClass == "communication", !assumeAvailable {
                let canRead = readable(resolvedPath(preset.spec.root, home: home))
                return FirstRunSourceTemplate(
                    id: preset.id,
                    title: preset.title,
                    subtitle: subtitle,
                    symbol: symbol,
                    slug: preset.spec.slug,
                    root: preset.spec.root,
                    kind: preset.spec.kind,
                    corpusClass: preset.spec.corpusClass,
                    trust: preset.spec.trust,
                    isAvailable: canRead,
                    isCustom: false,
                    // Whether the folder is there cannot be told apart from whether it is closed to
                    // Garage (Messages hides even that), so an unreadable one is put down to access.
                    needsFullDiskAccess: !canRead
                )
            }
            return FirstRunSourceTemplate(
                id: preset.id,
                title: preset.title,
                subtitle: subtitle,
                symbol: symbol,
                slug: preset.spec.slug,
                root: preset.spec.root,
                kind: preset.spec.kind,
                corpusClass: preset.spec.corpusClass,
                trust: preset.spec.trust,
                isAvailable: assumeAvailable || available(preset.spec.root),
                isCustom: false
            )
        }
        func extra(
            id: String,
            title: String,
            subtitle: String,
            symbol: String,
            root: String,
            kind: String = "filesystem",
            corpusClass: String = "document",
            trust: String = "authored"
        ) -> FirstRunSourceTemplate {
            FirstRunSourceTemplate(
                id: id,
                title: title,
                subtitle: subtitle,
                symbol: symbol,
                slug: id,
                root: root,
                kind: kind,
                corpusClass: corpusClass,
                trust: trust,
                isAvailable: assumeAvailable || available(root),
                isCustom: false
            )
        }

        return [
            shared(.documents, subtitle: "Your Documents folder", symbol: "doc.text"),
            shared(.desktop, subtitle: "Files kept on the Desktop", symbol: "menubar.dock.rectangle"),
            shared(.downloads, subtitle: "Received files and installers", symbol: "arrow.down.circle"),
            extra(id: "icloud-drive", title: "iCloud Drive", subtitle: "Documents synced through iCloud", symbol: "icloud", root: "~/Library/Mobile Documents/com~apple~CloudDocs"),
            shared(.dropbox, subtitle: "Your Dropbox folder", symbol: "shippingbox"),
            extra(id: "developer", title: "Developer", subtitle: "Code repositories under ~/Developer", symbol: "chevron.left.forwardslash.chevron.right", root: "~/Developer", kind: "git", corpusClass: "code"),
            shared(.messages, subtitle: "iMessage and SMS history (Garage never sends it off this Mac)", symbol: "message"),
            shared(.mail, subtitle: "Local mailboxes (Garage never sends them off this Mac)", symbol: "envelope"),
        ]
    }

    /// Whether the folder's contents can be listed, which for Mail and Messages is what Full Disk
    /// Access decides.
    static func canListContents(_ path: String) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil
    }

    /// Builds a template for a folder the user picked in the open panel.
    static func custom(folder: URL, existingSlugs: Set<String>) -> FirstRunSourceTemplate {
        let slug = uniqueSlug(base: slug(forFolderNamed: folder.lastPathComponent), taken: existingSlugs)
        let home = GarageAppGroup.realHomeDirectory
        let display = folder.path.hasPrefix(home + "/") ? "~" + String(folder.path.dropFirst(home.count)) : folder.path
        return FirstRunSourceTemplate(
            id: "custom:" + folder.path,
            title: folder.lastPathComponent,
            subtitle: display,
            symbol: "folder",
            slug: slug,
            root: folder.path,
            kind: "filesystem",
            corpusClass: "document",
            trust: "authored",
            isAvailable: true,
            isCustom: true
        )
    }

    /// Lower-cases a folder name, strips diacritics ("Résumé" → "resume"), and
    /// collapses everything else that isn't `[a-z0-9]` into single dashes, so
    /// "My Notes (2024)" becomes "my-notes-2024".
    static func slug(forFolderNamed name: String) -> String {
        var out = ""
        var pendingDash = false
        let allowed = CharacterSet.alphanumerics
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        for scalar in folded.unicodeScalars {
            if scalar.isASCII, allowed.contains(scalar) {
                if pendingDash, !out.isEmpty { out.append("-") }
                pendingDash = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        return out.isEmpty ? "folder" : out
    }

    static func uniqueSlug(base: String, taken: Set<String>) -> String {
        guard taken.contains(base) else { return base }
        var counter = 2
        while taken.contains("\(base)-\(counter)") { counter += 1 }
        return "\(base)-\(counter)"
    }
}

// MARK: - Model helpers

enum FirstRunModelPlan {
    /// The `facts.provider` value for a distillation preset (`llama_xpc` unless it says otherwise).
    static func factsProvider(for preset: ModelPresetEntry) -> String {
        let provider = preset.provider?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return provider.isEmpty ? GarageConfigLoader.defaultFactsProvider : provider
    }

    /// Featured presets first, then the rest alphabetically — the order the
    /// picker shows them in.
    static func ordered(_ presets: [ModelPresetEntry]) -> [ModelPresetEntry] {
        presets.sorted { lhs, rhs in
            if lhs.featured != rhs.featured {
                return lhs.featured && !rhs.featured
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// The pre-selected embedding model: the first featured preset, else the first preset.
    static func defaultSelection(from presets: [ModelPresetEntry]) -> Set<String> {
        guard let first = ordered(presets).first else { return [] }
        return [first.slug]
    }
}

// MARK: - Coordinator

/// Drives the first-run setup assistant: which page is showing, what the user
/// has picked so far, and the `garage` commands that turn those picks into a
/// working configuration. Owned by `AppState`.
@MainActor
final class FirstRunCoordinator: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var step: FirstRunStep = .settingUp
    @Published private(set) var isWorking = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var progressMessage: String?
    /// This run follows "Reset Database": page 1 creates the new database and
    /// registers garage.json's sources again before the user picks anything.
    @Published private(set) var isAfterDatabaseReset = false
    /// Page 1 has finished the reset (`AppState.finishDatabaseReset`). Until it
    /// has, skipping hands the rest of the reset to the background.
    private var hasFinishedDatabaseReset = false

    // Page 2 — data
    /// The App Store build: the data page leads with the home folder grant and Full Disk Access.
    let isSandboxed: Bool
    /// Whether Mail and Messages can be read (`VolumeAccessService.hasFullDiskAccess`). Checked while
    /// the data page shows, since the switch is turned on in System Settings.
    @Published private(set) var hasFullDiskAccess = true
    @Published private(set) var sourceTemplates: [FirstRunSourceTemplate] = []
    @Published var selectedSourceIDs: Set<String> = []

    // Page 3 — models
    @Published var selectedEmbeddingSlugs: Set<String> = []
    /// One slot, because `facts.model` in garage.json names a single model.
    @Published var selectedDistillationSlug: String?
    @Published var downloadSelectedModels = true

    // Page 4 — agent
    @Published var selectedClientIDs: Set<String> = []
    @Published private(set) var registrationSummary: String?

    private let defaults: UserDefaults
    /// Whether finishing records completion in `defaults`. On an overridden data folder (the UI
    /// tests' throwaway folders) it lasts for this launch only, the way that folder's database
    /// password and LM Studio token stay out of the Keychain: finishing or skipping there must not
    /// change what the real install shows at its next launch.
    private let persistsCompletion: Bool
    private var completedThisLaunch = false
    private weak var appState: AppState?
    private var readinessTask: Task<Void, Never>?

    /// Decides here, before the main window exists, whether it opens on the
    /// assistant: deciding in `AppState.launch()` let the window draw the main
    /// pages first and then swap to the assistant, which showed as a flash.
    /// `begin` still runs from launch to start the readiness loop.
    init(
        defaults: UserDefaults = .standard,
        arguments: [String] = CommandLine.arguments,
        persistsCompletion: Bool = GarageAppGroup.dataDirectoryOverride == nil,
        isSandboxed: Bool = GarageAppGroup.isSandboxed
    ) {
        self.defaults = defaults
        self.isSandboxed = isSandboxed
        self.persistsCompletion = persistsCompletion
        let afterDatabaseReset = arguments.contains(GarageAppLaunch.databaseResetArgument)
        isAfterDatabaseReset = afterDatabaseReset
        isActive = afterDatabaseReset || shouldPresentAtLaunch
    }

    func attach(to appState: AppState) {
        self.appState = appState
    }

    /// True until the user has finished or skipped the assistant once.
    var hasCompleted: Bool {
        completedThisLaunch || defaults.bool(forKey: FirstRunPreferences.completedKey)
    }

    /// Whether launch should open straight into the assistant.
    var shouldPresentAtLaunch: Bool {
        !hasCompleted && !isRunningInTestEnvironment
    }

    /// An install that already has sources declared in `~/.garage.json` was
    /// configured by hand (or by an earlier version) and should not be walked
    /// through the assistant again.
    nonisolated static func looksAlreadyConfigured(configSources: [RegisteredSource], registeredModels: [RegisteredModel]) -> Bool {
        !configSources.isEmpty || !registeredModels.isEmpty
    }

    // MARK: Lifecycle

    /// Opens the assistant on its first page. `force` re-runs it even when it
    /// has been completed before (the "Setup Assistant…" menu item).
    /// `afterDatabaseReset` is the relaunch after "Reset Database": it always
    /// runs, and never takes the "already configured" shortcut, since
    /// garage.json still lists the sources the empty database has lost.
    func begin(force: Bool = false, afterDatabaseReset: Bool = false) {
        guard force || afterDatabaseReset || !hasCompleted else { return }
        // A re-run requested while a page is still registering sources or models
        // would reset the picks that commit is iterating; the running assistant
        // already shows its progress, so just keep it.
        guard !(isActive && isWorking) else { return }
        isAfterDatabaseReset = afterDatabaseReset
        hasFinishedDatabaseReset = false
        errorMessage = nil
        progressMessage = nil
        registrationSummary = nil
        step = .settingUp
        isActive = true
        sourceTemplates = currentTemplates()
        selectedSourceIDs = []
        selectedEmbeddingSlugs = []
        selectedDistillationSlug = nil
        selectedClientIDs = []
        startReadinessLoop(skipIfConfigured: !force && !afterDatabaseReset)
    }

    /// Marks the assistant done and returns to the main window.
    func finish() {
        readinessTask?.cancel()
        readinessTask = nil
        if persistsCompletion {
            defaults.set(true, forKey: FirstRunPreferences.completedKey)
        } else {
            completedThisLaunch = true
        }
        isActive = false
        isWorking = false
        let resetStillPending = isAfterDatabaseReset && !hasFinishedDatabaseReset
        isAfterDatabaseReset = false
        guard let appState else { return }
        // Skipped before page 1 got through a reset: finish it without the
        // assistant, so the main window comes up on the new, unconfigured database.
        if resetStillPending {
            Task {
                await appState.finishDatabaseReset(startingPostgres: true)
                appState.resumeMaintenanceAfterFirstRun()
            }
            return
        }
        // Indexing held back while the assistant was open starts now, with the models it chose.
        appState.resumeMaintenanceAfterFirstRun()
        Task {
            await appState.fetchRegisteredSources()
            await appState.fetchRegisteredModels()
            await appState.fetchCorpusStats()
        }
    }

    /// "I'll decide later" on any page: remembers completion so the assistant
    /// stays out of the way, but leaves the pipeline untouched.
    func skip() {
        finish()
    }

    /// Debug/test helper that forgets the completed flag.
    func resetCompletion() {
        completedThisLaunch = false
        defaults.removeObject(forKey: FirstRunPreferences.completedKey)
    }

    func goBack() {
        guard let previous = step.previous, previous != .settingUp else { return }
        errorMessage = nil
        step = previous
    }

    // MARK: Page 1 — services

    var serviceChecks: [FirstRunServiceCheck] {
        guard let appState else { return [] }
        return FirstRunReadiness.checks(
            postgres: appState.postgres.status,
            pendingMigrations: appState.postgres.pendingMigrations,
            isApplyingMigrations: appState.isApplyingMigrations,
            grpc: appState.grpc.status,
            mcp: appState.mcp.status
        )
    }

    var servicesReady: Bool { FirstRunReadiness.isReady(serviceChecks) }
    /// A required service failed; the optional MCP server failing does not count.
    var servicesFailed: Bool { FirstRunReadiness.hasBlockingFailure(serviceChecks) }

    /// Re-attempts startup after a failure.
    func retryServices() {
        errorMessage = nil
        startReadinessLoop(skipIfConfigured: false)
    }

    private func startReadinessLoop(skipIfConfigured: Bool) {
        readinessTask?.cancel()
        readinessTask = Task { [weak self] in
            await self?.runReadinessLoop(skipIfConfigured: skipIfConfigured)
        }
    }

    private func runReadinessLoop(skipIfConfigured: Bool) async {
        guard let appState else { return }

        // `PostgresService.start()` accepts a failed cluster too, so Retry after an
        // initdb/Keychain/startup failure gets a real second attempt.
        if Self.needsStart(appState.postgres.status) {
            await appState.startPostgres()
        }
        if Task.isCancelled { return }

        if appState.postgres.status == .needsMigration || !appState.postgres.pendingMigrations.isEmpty {
            await appState.applyMigrations()
        }
        if Task.isCancelled { return }

        if appState.postgres.status == .running {
            if Self.needsStart(appState.grpc.status) { try? await appState.grpc.start() }
            if Self.needsStart(appState.mcp.status) { try? await appState.mcp.start() }
        }

        // Wait for the required services to settle, polling because each one
        // reports through its own @Published status rather than a single event.
        var attempts = 0
        while !Task.isCancelled, !servicesReady, !servicesFailed, attempts < 600 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            attempts += 1
        }
        if Task.isCancelled { return }

        guard servicesReady else {
            if !servicesFailed {
                errorMessage = "Services did not become ready in time. Check the Logs page for details, then retry."
            }
            return
        }

        if isAfterDatabaseReset, !hasFinishedDatabaseReset {
            isWorking = true
            progressMessage = "Registering the sources in garage.json again…"
            await appState.finishDatabaseReset()
            progressMessage = nil
            isWorking = false
            if Task.isCancelled { return }
            hasFinishedDatabaseReset = true
        }

        await appState.fetchRegisteredSources()
        await appState.fetchRegisteredModels()
        appState.fetchPresetModels()
        appState.fetchFactsSettings()

        if skipIfConfigured,
           Self.looksAlreadyConfigured(
               configSources: GarageConfigLoader.loadSourcesFromConfig(),
               registeredModels: appState.registeredModels
           ) {
            logger.info("Existing configuration detected; skipping the setup assistant.")
            finish()
            return
        }

        prepareDataPage()
        step = .selectData
    }

    private static func needsStart(_ status: PostgresStatus) -> Bool {
        if case .failed = status { return true }
        return status == .stopped
    }

    private static func needsStart(_ status: GarageGRPCStatus) -> Bool {
        if case .failed = status { return true }
        return status == .stopped
    }

    private static func needsStart(_ status: GarageMCPStatus) -> Bool {
        if case .failed = status { return true }
        return status == .stopped
    }

    // MARK: Page 2 — data

    /// The built-in templates as this process can read them now. In the sandbox nothing outside the
    /// container can be checked until a folder is granted, so they all count as available until then.
    private func currentTemplates() -> [FirstRunSourceTemplate] {
        let granted = appState?.volumeAccess.status.isGranted ?? false
        return FirstRunSourceTemplate.builtIn(assumeAvailable: isSandboxed && !granted)
    }

    /// Checks the folder grant and Full Disk Access again (the data page calls this every few seconds
    /// while it shows) and refreshes which locations can be picked, keeping the custom folders and
    /// every pick that can still be made.
    func refreshAccess() {
        guard let appState else { return }
        hasFullDiskAccess = appState.volumeAccess.hasFullDiskAccess()
        let custom = sourceTemplates.filter(\.isCustom)
        let refreshed = currentTemplates() + custom
        guard refreshed != sourceTemplates else { return }
        sourceTemplates = refreshed
        let pickable = Set(refreshed.filter(\.isAvailable).map(\.id))
        selectedSourceIDs.formIntersection(pickable)
    }

    private func prepareDataPage() {
        sourceTemplates = currentTemplates()
        hasFullDiskAccess = appState?.volumeAccess.hasFullDiskAccess() ?? true
        if selectedSourceIDs.isEmpty, let documents = sourceTemplates.first(where: { $0.id == "documents" }), documents.isAvailable {
            selectedSourceIDs = [documents.id]
        }
    }

    var selectedSources: [FirstRunSourceTemplate] {
        sourceTemplates.filter { selectedSourceIDs.contains($0.id) }
    }

    func toggleSource(_ template: FirstRunSourceTemplate) {
        guard template.isAvailable else { return }
        if selectedSourceIDs.contains(template.id) {
            selectedSourceIDs.remove(template.id)
        } else {
            selectedSourceIDs.insert(template.id)
        }
    }

    /// Adds a folder the user picked in the open panel as a selected custom
    /// source. The panel's grant only lasts for this process, so the folder's
    /// security-scoped bookmark is persisted (and handed to the ingest worker)
    /// here, the same way the Sources page's "Grant Folder Access…" does.
    func addCustomFolder(_ url: URL) {
        let taken = Set(sourceTemplates.map(\.slug)).union(appState?.registeredSources.map(\.slug) ?? [])
        let template = FirstRunSourceTemplate.custom(folder: url, existingSlugs: taken)

        if let appState {
            do {
                try appState.volumeAccess.grantSourceAccess(for: url, forSourcePath: url.path)
            } catch {
                errorMessage = "Could not keep access to \(url.lastPathComponent): \(error.localizedDescription) "
                    + "Garage may be unable to read it during ingest; grant it again from the Sources page."
            }
        }

        guard !sourceTemplates.contains(where: { $0.id == template.id }) else {
            selectedSourceIDs.insert(template.id)
            return
        }
        sourceTemplates.append(template)
        selectedSourceIDs.insert(template.id)
    }

    func removeCustomFolder(_ template: FirstRunSourceTemplate) {
        guard template.isCustom else { return }
        sourceTemplates.removeAll { $0.id == template.id }
        selectedSourceIDs.remove(template.id)
    }

    /// Registers the selected sources and moves to the models page.
    func commitSources() async {
        guard let appState else { return }
        let picks = selectedSources
        guard !picks.isEmpty else {
            step = .selectModels
            prepareModelsPage()
            return
        }

        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        var failures: [String] = []
        for template in picks {
            progressMessage = "Adding \(template.title)…"
            let ok = await appState.addSource(template.spec)
            if !ok {
                failures.append("\(template.slug): \(appState.lastCommandOutput.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        progressMessage = nil
        await appState.fetchRegisteredSources()
        _ = appState.testVolumeAccess()

        if !failures.isEmpty {
            errorMessage = "Some sources could not be added:\n" + failures.joined(separator: "\n")
            return
        }
        prepareModelsPage()
        step = .selectModels
    }

    // MARK: Page 3 — models

    var embeddingPresets: [ModelPresetEntry] {
        FirstRunModelPlan.ordered(appState?.presetModels ?? [])
    }

    var distillationPresets: [ModelPresetEntry] {
        FirstRunModelPlan.ordered(appState?.factDistilPresets ?? [])
    }

    private func prepareModelsPage() {
        appState?.fetchPresetModels()
        appState?.fetchFactsSettings()
        if selectedEmbeddingSlugs.isEmpty {
            let registered = Set(appState?.registeredModels.map(\.slug) ?? [])
            selectedEmbeddingSlugs = registered.isEmpty
                ? FirstRunModelPlan.defaultSelection(from: embeddingPresets)
                : registered.intersection(embeddingPresets.map(\.slug))
        }
        if selectedDistillationSlug == nil,
           let current = appState?.factsModel,
           distillationPresets.contains(where: { $0.slug == current }) {
            selectedDistillationSlug = current
        }
    }

    func toggleEmbedding(_ preset: ModelPresetEntry) {
        if selectedEmbeddingSlugs.contains(preset.slug) {
            selectedEmbeddingSlugs.remove(preset.slug)
        } else {
            selectedEmbeddingSlugs.insert(preset.slug)
        }
    }

    /// Picks (or, when already picked, clears) the single fact-distillation model.
    func toggleDistillation(_ preset: ModelPresetEntry) {
        selectedDistillationSlug = selectedDistillationSlug == preset.slug ? nil : preset.slug
    }

    /// Registers the selected embedding models, points `facts.model` at the
    /// chosen distillation model, kicks off GGUF downloads for anything local
    /// that isn't on disk yet, and moves to the agent page.
    func commitModels() async {
        guard let appState else { return }
        let embeddings = embeddingPresets.filter { selectedEmbeddingSlugs.contains($0.slug) }
        let distiller = distillationPresets.first { $0.slug == selectedDistillationSlug }

        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        let alreadyRegistered = Set(appState.registeredModels.map(\.slug))
        let hasDefault = appState.registeredModels.contains { $0.isDefault }
        var failures: [String] = []
        var madeDefault = hasDefault

        for preset in embeddings where !alreadyRegistered.contains(preset.slug) {
            progressMessage = "Registering \(preset.name)…"
            let ok = await appState.registerModel(preset: preset, makeDefault: !madeDefault)
            if ok {
                madeDefault = true
            } else {
                failures.append("\(preset.slug): \(appState.lastCommandOutput.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }

        if let distiller, appState.factsModel != distiller.slug {
            progressMessage = "Selecting \(distiller.name) for facts…"
            let ok = await appState.setFactsModel(distiller.slug, provider: FirstRunModelPlan.factsProvider(for: distiller))
            if !ok {
                failures.append("\(distiller.slug): \(appState.lastCommandOutput.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }

        if downloadSelectedModels {
            for preset in embeddings + (distiller.map { [$0] } ?? []) {
                await startDownloadIfNeeded(preset, appState: appState)
            }
        }

        progressMessage = nil
        await appState.fetchRegisteredModels()

        if !failures.isEmpty {
            errorMessage = "Some models could not be registered:\n" + failures.joined(separator: "\n")
            return
        }
        prepareAgentPage()
        step = .setupAgent
    }

    private func startDownloadIfNeeded(_ preset: ModelPresetEntry, appState: AppState) async {
        guard (preset.provider ?? "llama_xpc") == "llama_xpc",
              let url = preset.downloadURLString,
              let filename = preset.effectiveFilename else { return }
        let downloads = appState.modelDownload
        guard !downloads.isModelDownloaded(filename: filename), !downloads.isModelDownloading(url: url) else { return }
        progressMessage = "Starting download of \(preset.name)…"
        _ = await downloads.startDownload(url: url, filename: filename, modelId: preset.slug, sha256: preset.sha256)
    }

    // MARK: Page 4 — agent

    var detectedClients: [MCPClientConfig] {
        appState?.mcp.detectedClients ?? []
    }

    private func prepareAgentPage() {
        appState?.mcp.refreshDetectedClients()
        if selectedClientIDs.isEmpty {
            selectedClientIDs = Set(detectedClients.filter { $0.existsOnDisk && !$0.isRegistered && !$0.isProjectScoped }.map(\.id))
        }
    }

    func toggleClient(_ client: MCPClientConfig) {
        if selectedClientIDs.contains(client.id) {
            selectedClientIDs.remove(client.id)
        } else {
            selectedClientIDs.insert(client.id)
        }
    }

    /// Writes Garage into every selected client config.
    func registerSelectedClients() async {
        guard let appState else { return }
        let ids = detectedClients.filter { selectedClientIDs.contains($0.id) }.map(\.id)
        guard !ids.isEmpty else { return }

        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        var lines: [String] = []
        var failed = false
        for id in ids {
            progressMessage = "Registering \(id)…"
            let (ok, message) = await appState.mcp.registerTarget(id, force: true)
            if !ok { failed = true }
            lines.append("\(ok ? "✓" : "✗") \(id): \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        progressMessage = nil
        appState.mcp.refreshDetectedClients()
        registrationSummary = lines.joined(separator: "\n")
        if failed {
            errorMessage = "Some clients could not be configured. See the summary below."
        }
    }

    func registerCustomConfigFile(_ url: URL) async {
        guard let appState else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        let (ok, message) = await appState.mcp.registerCustomConfigFile(at: url, force: true)
        appState.mcp.refreshDetectedClients()
        registrationSummary = "\(ok ? "✓" : "✗") \(url.path): \(message.trimmingCharacters(in: .whitespacesAndNewlines))"
        if !ok {
            errorMessage = "Could not write \(url.lastPathComponent)."
        }
    }

    func startMCPServer() async {
        guard let appState else { return }
        isWorking = true
        defer { isWorking = false }
        if appState.postgres.status != .running {
            await appState.startPostgres()
        } else {
            try? await appState.mcp.start()
        }
    }

    #if DEBUG
    func setStepForTesting(_ step: FirstRunStep, active: Bool = true) {
        self.step = step
        self.isActive = active
    }

    func setSourceTemplatesForTesting(_ templates: [FirstRunSourceTemplate]) {
        self.sourceTemplates = templates
    }
    #endif
}

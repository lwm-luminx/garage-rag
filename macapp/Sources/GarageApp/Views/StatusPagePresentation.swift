import SwiftUI
import PythonXPCService

// What the Status page says, worked out from plain values so it can be tested without a view;
// each type's `init(appState:)` reads them from the live one. Three questions, three types:
// is anything wrong (`StatusHealth`), how far along is the index (`IndexingPresentation`), and
// is each helper process alive (`ServiceRowPresentation`).

// MARK: - Health

/// The problems the page lists, worst first, each with the button that fixes it. Nothing is
/// listed while everything works: the box then shows one "All systems go" row.
struct StatusHealth: Equatable {
    enum Severity: Int, Comparable {
        case critical = 0
        case warning = 1

        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// What the fix button does; the view maps each one onto an `AppState` call.
    enum Fix: Equatable {
        case startDatabase
        case applyMigrations
        case startMCP
        case testMCP
        case chooseDisk
        case grantFolder(slug: String, path: String)
        case openPrivacySettings
        case checkSourceAccess
        case refreshLlama

        var label: String {
            switch self {
            case .startDatabase: "Start"
            case .applyMigrations: "Apply Updates"
            case .startMCP: "Start"
            case .testMCP: "Test Again"
            case .chooseDisk: "Choose Disk…"
            case .grantFolder: "Grant Access…"
            case .openPrivacySettings: "Open Privacy Settings…"
            case .checkSourceAccess: "Check Again"
            case .refreshLlama: "Try Again"
            }
        }
    }

    struct Problem: Identifiable, Equatable {
        /// Stable across refreshes, so a row keeps its identity while its text changes.
        let id: String
        let severity: Severity
        let title: String
        /// The reason, under the title. Errors are shown in red.
        let detail: String?
        let detailIsError: Bool
        /// The page that owns the problem, for the "Open" button.
        let section: AppSection
        let fix: Fix?
        /// "Try Again" reads differently from "Start"; the fix keeps the same action.
        let fixLabel: String?

        init(
            id: String,
            severity: Severity,
            title: String,
            detail: String? = nil,
            detailIsError: Bool = false,
            section: AppSection,
            fix: Fix? = nil,
            fixLabel: String? = nil
        ) {
            self.id = id
            self.severity = severity
            self.title = title
            self.detail = detail
            self.detailIsError = detailIsError
            self.section = section
            self.fix = fix
            self.fixLabel = fixLabel ?? fix?.label
        }
    }

    /// A source folder macOS protects or the app cannot read.
    struct SourceAccess: Equatable {
        var slug: String
        var name: String
        var path: String
        var needsPermission: Bool
        /// Mail or Messages, which only Full Disk Access opens.
        var needsFullDiskAccess: Bool = false
    }

    enum DiskAccess: Equatable {
        case granted
        case notConfigured
        case stale(path: String)
        case denied(reason: String)
    }

    var database: MenuBarStatus.Database
    var mcp: MenuBarStatus.Server
    var mcpCheckFailure: String?
    var diskAccess: DiskAccess
    var sourceAccess: [SourceAccess]
    var sourceAccessMessage: String?
    var sourceCount: Int
    var embeddingModelCount: Int
    var llamaError: String?
    var lastIngestError: String?
    var isPipelineBusy: Bool
    var launcherPath: String?

    init(
        database: MenuBarStatus.Database,
        mcp: MenuBarStatus.Server = .stopped,
        mcpCheckFailure: String? = nil,
        diskAccess: DiskAccess = .granted,
        sourceAccess: [SourceAccess] = [],
        sourceAccessMessage: String? = nil,
        sourceCount: Int = 0,
        embeddingModelCount: Int = 0,
        llamaError: String? = nil,
        lastIngestError: String? = nil,
        isPipelineBusy: Bool = false,
        launcherPath: String? = nil
    ) {
        self.database = database
        self.mcp = mcp
        self.mcpCheckFailure = mcpCheckFailure
        self.diskAccess = diskAccess
        self.sourceAccess = sourceAccess
        self.sourceAccessMessage = sourceAccessMessage
        self.sourceCount = sourceCount
        self.embeddingModelCount = embeddingModelCount
        self.llamaError = llamaError
        self.lastIngestError = lastIngestError
        self.isPipelineBusy = isPipelineBusy
        self.launcherPath = launcherPath
    }

    @MainActor
    init(appState: AppState) {
        let menuBar = MenuBarStatus(appState: appState)

        let diskAccess: DiskAccess = switch appState.volumeAccess.status {
        case .accessGranted: .granted
        case .notConfigured: .notConfigured
        case .staleBookmark(let url): .stale(path: url.path)
        case .accessDenied(let reason): .denied(reason: reason)
        }

        var sourceAccess: [SourceAccess] = []
        var sourceAccessMessage: String?
        if case .accessGranted = appState.volumeAccess.status,
           let test = appState.volumeAccess.lastTestResult, !test.isAccessible {
            for result in test.sourcePathResults where !result.isAccessible {
                let protected = result.requiresTCCPermission || result.tccCategory != nil
                sourceAccess.append(SourceAccess(
                    slug: result.slug,
                    name: result.tccCategory?.displayName ?? result.slug,
                    path: result.rawPath,
                    needsPermission: protected,
                    needsFullDiskAccess: result.tccCategory?.needsFullDiskAccess ?? false
                ))
            }
            if sourceAccess.isEmpty {
                sourceAccessMessage = test.message
            }
        }

        let llamaError = appState.llama.isConnected ? nil : appState.llama.lastError
        let launcher = Paths.garageMCP.path
        self.init(
            database: menuBar.database,
            mcp: menuBar.mcp,
            mcpCheckFailure: appState.mcp.lastTestResult.flatMap { $0.isSuccess ? nil : ($0.errorMessage ?? "The server did not answer.") },
            diskAccess: diskAccess,
            sourceAccess: sourceAccess,
            sourceAccessMessage: sourceAccessMessage,
            sourceCount: appState.registeredSources.count,
            embeddingModelCount: appState.registeredModels.count,
            llamaError: llamaError,
            lastIngestError: menuBar.lastIngestError,
            isPipelineBusy: menuBar.isBusy,
            launcherPath: FileManager.default.isExecutableFile(atPath: launcher) ? nil : launcher
        )
    }

    /// Critical first, then warnings; within a severity, the order the pipeline needs them fixed.
    var problems: [Problem] {
        var list: [Problem] = []

        switch database {
        case .failed(let message):
            list.append(Problem(
                id: "database", severity: .critical, title: "Database couldn't start",
                detail: MenuBarStatus.firstLine(message) ?? "Postgres exited before it was ready.", detailIsError: true,
                section: .database, fix: .startDatabase, fixLabel: "Try Again"
            ))
        case .stopped:
            list.append(Problem(
                id: "database", severity: .warning, title: "Database stopped",
                detail: "Search, ingest and the MCP server need it running.",
                section: .database, fix: .startDatabase
            ))
        case .needsMigration:
            list.append(Problem(
                id: "database", severity: .warning, title: "Database needs a schema update",
                detail: "This version of Garage expects schema changes the database does not have yet. Your data is kept.",
                section: .database, fix: .applyMigrations
            ))
        case .running, .starting, .stopping:
            break
        }

        // An MCP failure while the database is down is a consequence, not a second problem.
        if database == .running {
            switch mcp {
            case .failed(let message):
                list.append(Problem(
                    id: "mcp", severity: .critical, title: "MCP server failed",
                    detail: MenuBarStatus.firstLine(message) ?? "The server exited.", detailIsError: true,
                    section: .mcp, fix: .startMCP, fixLabel: "Try Again"
                ))
            case .stopped:
                list.append(Problem(
                    id: "mcp", severity: .warning, title: "MCP server not running",
                    detail: "Claude can't reach your corpus until it runs.",
                    section: .mcp, fix: .startMCP
                ))
            case .running:
                if let mcpCheckFailure {
                    list.append(Problem(
                        id: "mcp", severity: .warning, title: "MCP server isn't answering",
                        detail: MenuBarStatus.firstLine(mcpCheckFailure), detailIsError: true,
                        section: .mcp, fix: .testMCP
                    ))
                }
            case .starting, .stopping:
                break
            }
        }

        switch diskAccess {
        case .denied(let reason):
            list.append(Problem(
                id: "disk", severity: .critical, title: "Garage can't read your disk",
                detail: reason, detailIsError: true,
                section: .sources, fix: .chooseDisk
            ))
        case .notConfigured:
            list.append(Problem(
                id: "disk", severity: .warning, title: "Garage has no disk access yet",
                detail: "Choose the disk your sources are on so the sandbox lets Garage read them.",
                section: .sources, fix: .chooseDisk
            ))
        case .stale(let path):
            list.append(Problem(
                id: "disk", severity: .warning, title: "Disk access needs renewing",
                detail: "The saved permission for \(MenuBarStatus.abbreviatedPath(path)) no longer works.",
                section: .sources, fix: .chooseDisk
            ))
        case .granted:
            break
        }

        for source in sourceAccess {
            if source.needsFullDiskAccess {
                list.append(Problem(
                    id: "source.\(source.slug)", severity: .warning, title: "\(source.name) needs Full Disk Access",
                    detail: "Garage can't index \(source.name) until it has Full Disk Access. Turn it on in Privacy & Security, then quit and reopen Garage.",
                    section: .sources, fix: .openPrivacySettings
                ))
            } else if source.needsPermission {
                list.append(Problem(
                    id: "source.\(source.slug)", severity: .warning, title: "\(source.name) needs permission",
                    detail: "macOS protects \(MenuBarStatus.abbreviatedPath(source.path)). Grant Garage access to index it.",
                    section: .sources, fix: .grantFolder(slug: source.slug, path: source.path)
                ))
            } else {
                list.append(Problem(
                    id: "source.\(source.slug)", severity: .warning, title: "\(source.name) can't be read",
                    detail: MenuBarStatus.abbreviatedPath(source.path),
                    section: .sources, fix: .checkSourceAccess
                ))
            }
        }
        if let sourceAccessMessage, !sourceAccessMessage.isEmpty {
            list.append(Problem(
                id: "source.access", severity: .warning, title: "A source can't be read",
                detail: sourceAccessMessage, detailIsError: true,
                section: .sources, fix: .checkSourceAccess
            ))
        }

        if let llamaError, !llamaError.isEmpty {
            list.append(Problem(
                id: "llama", severity: .critical, title: "Built-in engine can't be reached",
                detail: MenuBarStatus.firstLine(llamaError), detailIsError: true,
                section: .models, fix: .refreshLlama
            ))
        }

        if database == .running {
            if sourceCount == 0 {
                list.append(Problem(
                    id: "sources", severity: .warning, title: "No sources yet",
                    detail: "Add a folder on the Sources page to start indexing.",
                    section: .sources
                ))
            }
            if embeddingModelCount == 0 {
                list.append(Problem(
                    id: "models", severity: .warning, title: "No embedding model",
                    detail: "Search needs one. Add a recommended model on the Models page.",
                    section: .models
                ))
            }
        }

        if !isPipelineBusy, let lastIngestError, !lastIngestError.isEmpty {
            list.append(Problem(
                id: "ingest", severity: .warning, title: "Last ingest failed",
                detail: MenuBarStatus.firstLine(lastIngestError), detailIsError: true,
                section: .sources
            ))
        }

        if let launcherPath {
            list.append(Problem(
                id: "launcher", severity: .warning, title: "Command-line tools missing",
                detail: "garage-mcp was not found at \(launcherPath); assistants that start Garage themselves can't.",
                section: .logs
            ))
        }

        return list.enumerated().sorted { lhs, rhs in
            if lhs.element.severity != rhs.element.severity { return lhs.element.severity < rhs.element.severity }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    var isHealthy: Bool { problems.isEmpty }

    /// The one row shown while nothing is wrong, or while the services are on their way up.
    var summary: MenuBarStatus.Summary {
        MenuBarStatus(database: database, mcp: mcp).summary
    }
}

// MARK: - Indexing

/// The Library box: what the pipeline is doing, or how much of the corpus is left to index,
/// with one bar over ingest, embedding and distillation together.
struct IndexingPresentation: Equatable {
    /// One ingest's progress, as the Sources page reports it.
    struct Ingest: Equatable {
        var subject: String?
        var processed: Int
        var total: Int
        var indexed: Int
        var skipped: Int
        var failed: Int
        var itemType: String
        var currentItem: String?
        /// The ingest's own fraction, for the bar until the scan's total is known.
        var reportedFraction: Double?

        init(
            subject: String? = nil,
            processed: Int = 0,
            total: Int = 0,
            indexed: Int = 0,
            skipped: Int = 0,
            failed: Int = 0,
            itemType: String = "documents",
            currentItem: String? = nil,
            reportedFraction: Double? = nil
        ) {
            self.subject = subject
            self.processed = processed
            self.total = total
            self.indexed = indexed
            self.skipped = skipped
            self.failed = failed
            self.itemType = itemType
            self.currentItem = currentItem
            self.reportedFraction = reportedFraction
        }
    }

    enum Activity: Equatable {
        case idle
        case scanning(source: String, itemsSoFar: Int)
        case ingesting(Ingest)
        /// `total` is 0 until the backfill reports the model's count.
        case embedding(model: String?, embedded: Int, total: Int)
        case distilling(index: Int, total: Int, document: String?)
        case waiting(queued: [String])
    }

    enum Action: Equatable {
        case addSource
        case updateEverything(enabled: Bool)
        case stop(isStopping: Bool)
    }

    struct Figure: Identifiable, Equatable {
        let label: String
        let value: String
        var note: String? = nil
        var noteIsWarning = false

        var id: String { label }
    }

    var stats: CorpusStats
    var sourceCount: Int
    var modelCount: Int
    var distillsFacts: Bool
    var activity: Activity
    var isStopping: Bool
    var lastRunError: String?
    var databaseIsRunning: Bool

    init(
        stats: CorpusStats,
        sourceCount: Int,
        modelCount: Int,
        distillsFacts: Bool,
        activity: Activity = .idle,
        isStopping: Bool = false,
        lastRunError: String? = nil,
        databaseIsRunning: Bool = true
    ) {
        self.stats = stats
        self.sourceCount = sourceCount
        self.modelCount = modelCount
        self.distillsFacts = distillsFacts
        self.activity = activity
        self.isStopping = isStopping
        self.lastRunError = lastRunError
        self.databaseIsRunning = databaseIsRunning
    }

    @MainActor
    init(appState: AppState) {
        let ingest = appState.ingestService
        let activity: Activity
        if appState.isScanning {
            let scan = appState.scanProgress
            activity = .scanning(source: scan?.source ?? "*", itemsSoFar: scan?.totalItems ?? 0)
        } else if ingest.isRunning || appState.isIngestingAll {
            let single = ingest.runSources.count <= 1 && ingest.currentSource != "*" ? ingest.currentSource : nil
            let latest = ingest.latestProgress
            activity = .ingesting(Ingest(
                subject: single,
                processed: appState.combinedIngestProcessedCount,
                total: appState.combinedIngestTotalExpected,
                indexed: appState.combinedIngestIndexedCount,
                skipped: appState.combinedIngestSkippedCount,
                failed: appState.combinedIngestFailedCount,
                itemType: appState.combinedIngestItemType,
                currentItem: latest?.currentItem,
                reportedFraction: latest.map(\.progress)
            ))
        } else if appState.backfill.isRunning {
            let progress = appState.backfillProgress
            activity = .embedding(
                model: progress.map(\.model).flatMap { $0.isEmpty ? nil : $0 },
                embedded: progress?.embedded ?? 0,
                total: progress?.total ?? 0
            )
        } else if appState.enrichFacts.isRunning {
            let progress = appState.enrichFactsProgress
            activity = .distilling(index: progress?.index ?? 0, total: progress?.total ?? 0, document: progress?.documentURI)
        } else if !appState.sourcesAwaitingScan.isEmpty || !appState.ingestQueue.isEmpty {
            activity = .waiting(queued: appState.sourcesAwaitingScan + appState.ingestQueue)
        } else {
            activity = .idle
        }

        let facts = appState.factsModel.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(
            stats: appState.corpusStats,
            sourceCount: max(appState.registeredSources.count, appState.corpusStats.sourcesCount),
            modelCount: max(appState.registeredModels.count, appState.corpusStats.modelStats.count),
            distillsFacts: !facts.isEmpty,
            activity: activity,
            isStopping: appState.isCancellingAll || ingest.isCancelling,
            lastRunError: appState.lastIngestAllFailure ?? ingest.lastError,
            databaseIsRunning: appState.postgres.status == .running
        )
    }

    // MARK: Stages

    /// What each stage still has to do. A stage that does not apply (no model registered, no facts
    /// model configured, nothing scanned yet) is left out of the bar and the line.
    struct Remaining: Equatable {
        var documentsToIngest: Int?
        var embeddingsToGo: Int?
        var documentsToDistill: Int?

        var total: Int {
            (documentsToIngest ?? 0) + (embeddingsToGo ?? 0) + (documentsToDistill ?? 0)
        }
    }

    var remaining: Remaining {
        var remaining = Remaining()
        if stats.totalExpectedElements > 0 || stats.totalSeenFiles > 0 || stats.documentsCount > 0 {
            remaining.documentsToIngest = stats.uningestedElements
        }
        if modelCount > 0, stats.totalChunks > 0 {
            remaining.embeddingsToGo = stats.unembeddedChunks
        }
        if distillsFacts, stats.documentsCount > 0 {
            remaining.documentsToDistill = max(0, stats.documentsCount - stats.documentsDistilledCount)
        }
        return remaining
    }

    /// 0...1 over the stages that apply, each weighted the same; nil before anything is known.
    var fraction: Double? {
        var fractions: [Double] = []
        if remaining.documentsToIngest != nil {
            fractions.append(stats.ingestionProgressFraction)
        }
        if remaining.embeddingsToGo != nil {
            fractions.append(stats.embeddingProgressFraction)
        }
        if remaining.documentsToDistill != nil, stats.documentsCount > 0 {
            fractions.append(min(1, Double(stats.documentsDistilledCount) / Double(stats.documentsCount)))
        }
        guard !fractions.isEmpty else { return nil }
        return fractions.reduce(0, +) / Double(fractions.count)
    }

    /// "24 documents to read · 880 chunks to index · 300 documents to glean".
    var remainingLine: String? {
        var parts: [String] = []
        if let n = remaining.documentsToIngest, n > 0 {
            parts.append("\(n.formatted()) \(Self.plural("document", n)) to read")
        }
        if let n = remaining.embeddingsToGo, n > 0 {
            parts.append("\(n.formatted()) \(Self.plural("chunk", n)) to index")
        }
        if let n = remaining.documentsToDistill, n > 0 {
            parts.append("\(n.formatted()) \(Self.plural("document", n)) to glean")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "1,234 documents in 3 sources · indexed with 2 models · facts gleaned".
    var corpusLine: String {
        var parts = ["\(stats.documentsCount.formatted()) \(Self.plural("document", stats.documentsCount)) in \(sourceCount.formatted()) \(Self.plural("source", sourceCount))"]
        if remaining.embeddingsToGo != nil {
            parts.append("indexed with \(modelCount.formatted()) \(Self.plural("model", modelCount))")
        }
        if remaining.documentsToDistill != nil {
            parts.append("facts gleaned")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Headline

    struct Headline: Equatable {
        var symbol: String
        var tint: Color
        var isActive: Bool
        var title: String
        var percent: String?
        var detail: String?
        var detailIsError = false
        var currentItem: String?
        /// Nil hides the bar; `isIndeterminate` moves it without a fraction.
        var progress: Double?
        var isIndeterminate = false
        var stage: MenuBarStatus.Stage?
    }

    var isRunning: Bool {
        activity != .idle
    }

    var headline: Headline {
        switch activity {
        case .scanning(let source, let itemsSoFar):
            let what = source == "*" || source.isEmpty ? "all sources" : source
            return Headline(
                symbol: "magnifyingglass", tint: .blue, isActive: true,
                title: isStopping ? "Stopping…" : "Scanning \(what)…",
                detail: itemsSoFar > 0 ? "\(itemsSoFar.formatted()) items so far" : "Counting what there is to index.",
                isIndeterminate: true, stage: .scan
            )
        case .ingesting(let ingest):
            let title: String
            if let subject = ingest.subject, !subject.isEmpty {
                title = "Reading \(subject)"
            } else {
                title = "Reading all sources"
            }
            let fraction: Double? = ingest.total > 0
                ? min(1, max(0, Double(ingest.processed) / Double(ingest.total)))
                : ingest.reportedFraction.map { min(1, max(0, $0)) }
            let counts = SourceRowPresentation.runCounts(
                seen: ingest.processed, total: ingest.total, indexed: ingest.indexed,
                skipped: ingest.skipped, failed: ingest.failed, itemType: ingest.itemType
            )
            return Headline(
                symbol: "square.and.arrow.down", tint: .blue, isActive: true,
                title: isStopping ? "Stopping…" : title,
                percent: fraction.map(MenuBarStatus.percent),
                detail: counts,
                currentItem: ingest.currentItem.map { MenuBarStatus.abbreviatedPath($0) },
                progress: fraction, isIndeterminate: fraction == nil, stage: .ingest
            )
        case .embedding(let model, let embedded, let total):
            let fraction: Double? = total > 0 ? min(1, Double(embedded) / Double(total)) : nil
            return Headline(
                symbol: "point.3.connected.trianglepath.dotted", tint: .blue, isActive: true,
                title: isStopping ? "Stopping…" : (model.map { "Indexing with \($0)" } ?? "Indexing new chunks"),
                percent: fraction.map(MenuBarStatus.percent),
                detail: total > 0 ? "\(embedded.formatted()) of \(total.formatted()) chunks" : "Vectors for every registered model.",
                progress: fraction, isIndeterminate: fraction == nil, stage: .embed
            )
        case .distilling(let index, let total, let document):
            let fraction: Double? = total > 0 ? min(1, Double(index) / Double(total)) : nil
            return Headline(
                symbol: "sparkles", tint: .blue, isActive: true,
                title: isStopping ? "Stopping…" : "Gleaning facts",
                percent: fraction.map(MenuBarStatus.percent),
                detail: total > 0 ? "\(index.formatted()) of \(total.formatted()) documents" : "Facts for each document no prompt has distilled yet.",
                currentItem: document.map { MenuBarStatus.abbreviatedPath($0) },
                progress: fraction, isIndeterminate: fraction == nil, stage: .distill
            )
        case .waiting(let queued):
            let names = queued.prefix(3).joined(separator: ", ")
            let more = queued.count > 3 ? " and \(queued.count - 3) more" : ""
            return Headline(
                symbol: "clock", tint: .gray, isActive: true,
                title: "Waiting to scan \(names)\(more)",
                detail: "Each source gets its own scan and read once the current run ends.",
                isIndeterminate: true
            )
        case .idle:
            break
        }

        guard databaseIsRunning else {
            return Headline(
                symbol: "pause.fill", tint: .secondary, isActive: false,
                title: "Database stopped", detail: "Your library updates once the database runs."
            )
        }
        if sourceCount == 0 {
            return Headline(
                symbol: "tray", tint: .secondary, isActive: false,
                title: "Nothing to index yet", detail: "Add a folder on the Sources page and Garage indexes it."
            )
        }
        let error = lastRunError.flatMap(MenuBarStatus.firstLine)
        if stats.documentsCount == 0, stats.totalExpectedElements == 0, stats.totalSeenFiles == 0 {
            return Headline(
                symbol: "tray", tint: .orange, isActive: false,
                title: "Not indexed yet",
                detail: error ?? "\(sourceCount.formatted()) \(Self.plural("source", sourceCount)) · Update Everything scans, reads, indexes and gleans them.",
                detailIsError: error != nil
            )
        }
        let left = remaining
        if left.total > 0, let line = remainingLine {
            return Headline(
                symbol: "circle.dotted", tint: .orange, isActive: false,
                title: "\(left.total.formatted()) \(Self.plural("item", left.total)) to index",
                percent: fraction.map(MenuBarStatus.percent),
                detail: error ?? line,
                detailIsError: error != nil,
                progress: fraction
            )
        }
        return Headline(
            symbol: "checkmark", tint: .green, isActive: true,
            title: "Up to date",
            detail: error ?? corpusLine,
            detailIsError: error != nil
        )
    }

    /// The stages the trail under the bar shows: all four, as the menu bar does.
    var stageTrail: [MenuBarStatus.Stage] {
        MenuBarStatus.Stage.allCases
    }

    var action: Action {
        if isRunning {
            return .stop(isStopping: isStopping)
        }
        if databaseIsRunning, sourceCount == 0 {
            return .addSource
        }
        return .updateEverything(enabled: databaseIsRunning && sourceCount > 0)
    }

    // MARK: Figures

    var figures: [Figure] {
        var figures: [Figure] = [
            Figure(label: "Sources", value: sourceCount.formatted()),
            Figure(
                label: "Documents", value: stats.documentsCount.formatted(),
                note: stats.documentsFailedCount > 0 ? "\(stats.documentsFailedCount.formatted()) failed" : nil,
                noteIsWarning: true
            ),
            Figure(label: "Chunks", value: stats.totalChunks.formatted()),
        ]
        if modelCount > 0 {
            let value = stats.totalChunks > 0 ? MenuBarStatus.percent(stats.embeddingProgressFraction) : "–"
            figures.append(Figure(
                label: "Indexed", value: value,
                note: "\(modelCount.formatted()) \(Self.plural("model", modelCount))"
            ))
        } else {
            figures.append(Figure(label: "Indexed", value: "–", note: "no model", noteIsWarning: true))
        }
        if distillsFacts || stats.factsCount > 0 {
            let distilled = stats.documentsDistilledCount
            figures.append(Figure(
                label: "Facts", value: stats.factsCount.formatted(),
                note: distilled > 0 ? "from \(distilled.formatted()) \(Self.plural("document", distilled))" : nil
            ))
        }
        return figures
    }

    static func plural(_ noun: String, _ count: Int) -> String {
        count == 1 ? noun : noun + "s"
    }
}

// MARK: - Helper services

/// One row of the Index Manager or Helper Services box: the gRPC backend or an XPC helper.
struct ServiceRowPresentation: Equatable, Identifiable {
    enum State: Equatable {
        case running
        case checking
        case restarting
        case stopped
        case unreachable
        case unknown
    }

    let id: String
    let name: String
    let state: State
    /// "Running · 12 ms · 12 of 12 self tests passed", or the error.
    let detail: String
    let detailIsError: Bool

    var symbol: String {
        switch state {
        case .running: "checkmark"
        case .checking, .restarting: "ellipsis"
        case .stopped: "pause.fill"
        case .unreachable: "exclamationmark"
        case .unknown: "questionmark"
        }
    }

    var tint: Color {
        switch state {
        case .running: .green
        case .checking, .restarting: .yellow
        case .stopped: .secondary
        case .unreachable: .red
        case .unknown: .secondary
        }
    }

    var isActive: Bool {
        state == .running || state == .unreachable
    }

    /// The state in a word, for a row whose box already names the service.
    var stateTitle: String {
        switch state {
        case .running: "Running"
        case .checking: "Checking…"
        case .restarting: "Restarting…"
        case .stopped: "Stopped"
        case .unreachable: "Can't be reached"
        case .unknown: "Not checked yet"
        }
    }

    var isBusy: Bool {
        state == .checking || state == .restarting
    }

    /// Short names for the rows; the roster's names are what the helpers report about themselves.
    static func name(forServiceId id: String) -> String {
        switch id {
        case "ingest-xpc": "Ingest"
        case "embed-xpc": "Embeddings"
        case "llama-xpc": "Built-in Engine"
        case "model-download-xpc": "Model Downloads"
        case "image-embed-xpc": "Image Embeddings"
        case "mcp-server-xpc": "MCP Server"
        case "garage-xpc": "Garage Backend"
        default: id
        }
    }

    static func grpc(status: GarageGRPCStatus, address: String, lastTest: (isSuccess: Bool, summary: String)?) -> ServiceRowPresentation {
        let state: State
        var detail: String
        var isError = false
        let role = "runs every scan, read, index and glean for the app"
        switch status {
        case .running:
            state = .running
            detail = "On \(address) · \(role)"
        case .starting:
            state = .checking
            detail = "Starting with the database…"
        case .stopping:
            state = .checking
            detail = "Stopping…"
        case .stopped:
            state = .stopped
            detail = "Starts with the database. It \(role)."
        case .failed(let message):
            state = .unreachable
            detail = MenuBarStatus.firstLine(message) ?? "Failed"
            isError = true
        }
        if let lastTest, state == .running {
            if lastTest.isSuccess {
                detail = "On \(address) · test passed"
            } else {
                detail = MenuBarStatus.firstLine(lastTest.summary) ?? "The test failed"
                isError = true
            }
        }
        return ServiceRowPresentation(id: "grpc", name: "Index Manager", state: state, detail: detail, detailIsError: isError)
    }

    static func xpc(_ service: XPCServiceInfo, report: GarageXPCStatusReport?, test: ServiceDiagnosticTestResult?) -> ServiceRowPresentation {
        let state: State
        var parts: [String] = []
        var isError = false
        switch service.state {
        case .running(_, let latency, _):
            state = .running
            parts.append("Running")
            parts.append(String(format: "%.0f ms", latency))
        case .checking:
            state = .checking
            parts.append("Checking…")
        case .restarting:
            state = .restarting
            parts.append("Restarting…")
        case .unreachable(let error):
            state = .unreachable
            parts.append("Can't be reached: \(MenuBarStatus.firstLine(error) ?? "no reply")")
            isError = true
        case .unknown:
            state = .unknown
            parts.append("Not checked yet")
        }
        if state == .running {
            if let test, !test.isSuccess {
                parts = [MenuBarStatus.firstLine(test.summary) ?? "The test failed"]
                isError = true
            } else if let report, !report.tests.isEmpty {
                parts.append(selfTestSummary(report.tests))
                if !report.failedTests.isEmpty { isError = true }
            } else if let test, test.isSuccess {
                parts.append("test passed")
            }
        }
        return ServiceRowPresentation(
            id: service.id,
            name: name(forServiceId: service.id),
            state: state,
            detail: parts.joined(separator: " · "),
            detailIsError: isError
        )
    }

    /// "10 passed, 1 skipped (Model File)": a skipped test (one with nothing to check yet, such as
    /// the model file of an engine with no model loaded) is neither a pass nor a failure, so
    /// "10 of 12 passed" would read as two failures. The skipped tests are named, so a row that
    /// says "2 skipped" says which two, and the helper's own detail says why.
    static func selfTestSummary(_ tests: [GarageXPCTestResult]) -> String {
        let passed = tests.filter { $0.status == .passed }.count
        let failed = tests.filter { $0.status == .failed }.count
        let skipped = tests.filter { $0.status == .skipped }
        var parts = ["\(passed) passed"]
        if failed > 0 { parts.append("\(failed) failed") }
        if !skipped.isEmpty { parts.append("\(skipped.count) skipped (\(skipped.map(\.name).joined(separator: ", ")))") }
        return parts.joined(separator: ", ")
    }
}

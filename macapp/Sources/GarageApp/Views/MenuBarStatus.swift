import SwiftUI

/// Everything the menu bar item and its popover say about the app, worked out from plain values so
/// it can be tested without an `AppState`; `init(appState:)` reads them from the live one.
///
/// Two services matter to someone glancing at the menu bar - the database, and the MCP server that
/// Claude reaches the corpus through - plus whatever the pipeline is doing right now. Each gets its
/// own value here, and the icon, the headline and the popover's rows are all derived from them.
struct MenuBarStatus: Equatable {
    enum Database: Equatable {
        case stopped
        case starting
        case stopping
        case running
        case needsMigration
        case failed(String)
    }

    /// The MCP server. `clients` is how many detected client configs (Claude Desktop, Claude Code,
    /// ...) carry a registration for it.
    enum Server: Equatable {
        case stopped
        case starting
        case running(clients: Int)
        case stopping
        case failed(String)
        /// The HTTP server is off by choice: assistants run `garage-mcp` over stdio, so nothing is wrong.
        case stdio(clients: Int)
    }

    /// A running ingest, as the popover reports it.
    struct IngestProgress: Equatable {
        var source: String
        var processed: Int
        var total: Int
        var itemType: String
        var currentItem: String?
        /// What the ingest itself reports, for the bar until the scan's totals are known.
        var reportedFraction: Double?

        init(
            source: String,
            processed: Int = 0,
            total: Int = 0,
            itemType: String = "documents",
            currentItem: String? = nil,
            reportedFraction: Double? = nil
        ) {
            self.source = source
            self.processed = processed
            self.total = total
            self.itemType = itemType
            self.currentItem = currentItem
            self.reportedFraction = reportedFraction
        }

        /// 0...1 when anything is known about how far along the ingest is, nil before that.
        var fraction: Double? {
            if total > 0 {
                return min(1, max(0, Double(processed) / Double(total)))
            }
            return reportedFraction.map { min(1, max(0, $0)) }
        }
    }

    enum Activity: Equatable {
        case idle
        /// `itemsSoFar` is nil until the scan reports anything.
        case scanning(itemsSoFar: Int?)
        case ingesting(IngestProgress)
        case embedding
        case distilling
    }

    /// The pipeline's stages, in the order maintenance runs them; the popover shows the trail so a
    /// long run reads as "this is step 2 of 3", not an ingest that never ends.
    enum Stage: Int, CaseIterable, Equatable {
        case scan
        case ingest
        case embed
        case distill

        var title: String {
            switch self {
            case .scan: "Scan"
            case .ingest: "Read"
            case .embed: "Index"
            case .distill: "Glean"
            }
        }
    }

    /// Something the user has to act on or at least know about, in the order the popover lists them.
    enum Attention: Equatable {
        case databaseFailed(String)
        case databaseNeedsMigration
        case mcpFailed(String)
        case ingestFailed(String)
    }

    var database: Database
    var mcp: Server
    var activity: Activity
    /// The last ingest's error, kept until the next run starts.
    var lastIngestError: String?
    var sourceCount: Int
    var documentCount: Int
    var isCancellingIngest: Bool

    init(
        database: Database,
        mcp: Server = .stopped,
        activity: Activity = .idle,
        lastIngestError: String? = nil,
        sourceCount: Int = 0,
        documentCount: Int = 0,
        isCancellingIngest: Bool = false
    ) {
        self.database = database
        self.mcp = mcp
        self.activity = activity
        self.lastIngestError = lastIngestError
        self.sourceCount = sourceCount
        self.documentCount = documentCount
        self.isCancellingIngest = isCancellingIngest
    }

    @MainActor
    init(appState: AppState) {
        let database: Database = switch appState.postgres.status {
        case .stopped: .stopped
        case .starting: .starting
        case .stopping: .stopping
        case .running: .running
        case .needsMigration: .needsMigration
        case .failed(let message): .failed(message)
        }

        let clients = appState.mcp.detectedClients.filter(\.isRegistered).count
        let mcp: Server = switch appState.mcp.status {
        case .stopped: appState.mcp.httpEnabled ? .stopped : .stdio(clients: clients)
        case .starting: .starting
        case .running: .running(clients: clients)
        case .stopping: .stopping
        case .failed(let message): .failed(message)
        }

        let ingest = appState.ingestService
        let activity: Activity
        // An ingest of every source is still running between two sources, while IngestService is idle.
        if ingest.isRunning || appState.isIngestingAll {
            let latest = ingest.latestProgress
            let current = ingest.currentSource ?? ""
            activity = .ingesting(IngestProgress(
                source: latest?.source ?? (current == "*" ? "" : current),
                processed: appState.combinedIngestProcessedCount,
                total: appState.combinedIngestTotalExpected,
                itemType: appState.combinedIngestItemType,
                currentItem: latest?.currentItem,
                reportedFraction: latest.map(\.progress)
            ))
        } else if appState.isScanning {
            activity = .scanning(itemsSoFar: appState.scanProgress?.totalItems)
        } else if appState.backfill.isRunning {
            activity = .embedding
        } else if appState.enrichFacts.isRunning {
            activity = .distilling
        } else {
            activity = .idle
        }

        self.init(
            database: database,
            mcp: mcp,
            activity: activity,
            lastIngestError: appState.lastIngestAllFailure ?? ingest.lastError,
            sourceCount: appState.registeredSources.count,
            documentCount: appState.corpusStats.documentsCount,
            isCancellingIngest: appState.isCancellingAll
        )
    }

    // MARK: - Derived state

    var isBusy: Bool { activity != .idle }

    var isDatabaseTransitioning: Bool {
        database == .starting || database == .stopping
    }

    var isMCPTransitioning: Bool {
        mcp == .starting || mcp == .stopping
    }

    /// The stage the pipeline is on, or nil when idle.
    var stage: Stage? {
        switch activity {
        case .idle: nil
        case .scanning: .scan
        case .ingesting: .ingest
        case .embedding: .embed
        case .distilling: .distill
        }
    }

    /// The stages the trail under the progress bar shows: all four, so a run that stops at Embed
    /// still reads as "three of four".
    var stageTrail: [Stage] {
        Stage.allCases
    }

    /// What needs the user, worst first. An MCP failure while the database is down is a consequence,
    /// not a second problem, so it is listed only when the database runs.
    var attentions: [Attention] {
        var list: [Attention] = []
        switch database {
        case .failed(let message): list.append(.databaseFailed(message))
        case .needsMigration: list.append(.databaseNeedsMigration)
        default: break
        }
        if database == .running, case .failed(let message) = mcp {
            list.append(.mcpFailed(message))
        }
        if !isBusy, let lastIngestError, !lastIngestError.isEmpty {
            list.append(.ingestFailed(lastIngestError))
        }
        return list
    }

    /// Whether the icon swaps to a warning: only for what blocks the app outright, so an ingest that
    /// failed on one file does not shout from the menu bar for the rest of the day.
    var needsAttention: Bool {
        attentions.contains {
            switch $0 {
            case .databaseFailed, .databaseNeedsMigration, .mcpFailed: true
            case .ingestFailed: false
            }
        }
    }

    /// The database runs and the MCP server serves: the popover folds both service rows into one
    /// green "All systems go" row, and spells them out again only when one of them is not fine.
    var allSystemsGo: Bool {
        guard database == .running else { return false }
        switch mcp {
        case .running, .stdio: return true
        case .stopped, .starting, .stopping, .failed: return false
        }
    }

    /// The line under "All systems go": what is up, and how many clients reach it.
    var allSystemsGoDetail: String {
        if case .stdio(let clients) = mcp {
            switch clients {
            case 0: return "Database running · no assistants connected"
            case 1: return "Database running · 1 assistant connected"
            default: return "Database running · \(clients) assistants connected"
            }
        }
        guard case .running(let clients) = mcp else { return "Database and MCP running" }
        switch clients {
        case 0: return "Database and MCP running · no assistants connected"
        case 1: return "Database and MCP running · 1 assistant connected"
        default: return "Database and MCP running · \(clients) assistants connected"
        }
    }

    /// The popover's one services row: "All systems go", or the worst problem in a few words. It
    /// never carries a control of its own; clicking it opens the Status page, where the fixes are.
    struct Summary: Equatable {
        var symbol: String
        var title: String
        var detail: String
        var tint: Color
    }

    var summary: Summary {
        let fix = "Open Status to fix it."
        switch database {
        case .failed(let message):
            return Summary(symbol: "exclamationmark", title: "Database failed to start", detail: Self.firstLine(message) ?? fix, tint: .red)
        case .needsMigration:
            return Summary(symbol: "exclamationmark", title: "Database needs a schema update", detail: "Open Status to apply it.", tint: .orange)
        case .stopped:
            return Summary(symbol: "pause.fill", title: "Database stopped", detail: "Open Status to start it.", tint: .gray)
        case .starting:
            return Summary(symbol: "ellipsis", title: "Starting up…", detail: "Database, MCP and search come up together.", tint: .yellow)
        case .stopping:
            return Summary(symbol: "ellipsis", title: "Shutting down…", detail: "Waiting for connections to close.", tint: .yellow)
        case .running:
            break
        }
        switch mcp {
        case .running, .stdio:
            return Summary(symbol: "checkmark", title: "All systems go", detail: allSystemsGoDetail, tint: .green)
        case .failed(let message):
            return Summary(symbol: "exclamationmark", title: "MCP server failed", detail: Self.firstLine(message) ?? fix, tint: .red)
        case .stopped:
            return Summary(symbol: "exclamationmark", title: "MCP server not running", detail: "Claude can't reach your corpus. \(fix)", tint: .orange)
        case .starting, .stopping:
            return Summary(symbol: "ellipsis", title: "MCP server restarting…", detail: "Database is running.", tint: .yellow)
        }
    }

    /// An error's first line, trimmed, or nil when there is nothing to show.
    static func firstLine(_ message: String) -> String? {
        let line = message.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return line.isEmpty ? nil : line
    }

    /// Whether the activity module's title carries a status dot. Idle on a running database is the
    /// "All systems go" row's news already, so the module then leads with the corpus instead.
    var showsActivityDot: Bool {
        !(activity == .idle && database == .running)
    }

    /// "Ingest Now" is offered when it could actually do something.
    var canIngest: Bool {
        database == .running && !isBusy && sourceCount > 0
    }

    /// Quick search needs the database; the gRPC bridge starts with it.
    var canSearch: Bool {
        database == .running
    }

    /// "Ask Garage" runs `rag_agent` on the MCP server, so it needs the server up as well as the
    /// database. The local model loads on demand, so it is not a condition.
    var canAsk: Bool {
        guard canSearch, case .running = mcp else { return false }
        return true
    }

    // MARK: - Menu bar item

    /// The menu bar icon: a garage door, closed while the database is down and open while it
    /// serves, which is also the app icon's setting. A warning replaces it only when something
    /// blocks the app, because a badge on a 16 pt template glyph is not legible.
    var symbol: String {
        if needsAttention { return "exclamationmark.triangle" }
        switch database {
        case .running, .needsMigration: return "door.garage.open"
        case .stopped, .starting, .stopping, .failed: return "door.garage.closed"
        }
    }

    /// Whether the icon breathes: the pipeline is running, or the database is on its way up. Nothing
    /// animates while stopped or in trouble, so motion means "working" and only that.
    var isPulsing: Bool {
        if needsAttention { return false }
        return database == .starting || (database == .running && isBusy)
    }

    /// The accessibility label for the icon, which otherwise reads as a bare symbol name.
    var accessibilityLabel: String {
        "Garage, \(headline)"
    }

    // MARK: - Popover copy

    /// The one-line summary: the activity module's title, and what VoiceOver reads on the icon.
    var headline: String {
        switch database {
        case .stopped: return "Database stopped"
        case .starting: return "Starting…"
        case .stopping: return "Stopping…"
        case .needsMigration: return "Schema update needed"
        case .failed: return "Database failed"
        case .running: break
        }
        switch activity {
        case .idle: return "Ready"
        case .scanning: return "Scanning sources"
        case .ingesting(let progress): return progress.source.isEmpty ? "Reading" : "Reading \(progress.source)"
        case .embedding: return "Indexing chunks"
        case .distilling: return "Gleaning facts"
        }
    }

    /// The line under the headline while idle: what is in the corpus.
    var corpusLine: String {
        if sourceCount == 0 { return "No sources yet" }
        if documentCount == 0 { return "No documents yet" }
        let documents = "\(documentCount.formatted()) \(documentCount == 1 ? "document" : "documents")"
        return "\(documents) in \(sourceCount) \(sourceCount == 1 ? "source" : "sources")"
    }

    /// The counts under the progress bar while busy, or nil when there is nothing to count yet.
    var activityDetail: String? {
        switch activity {
        case .idle:
            return nil
        case .scanning(let itemsSoFar):
            guard let itemsSoFar else { return nil }
            return "\(itemsSoFar.formatted()) items found so far"
        case .ingesting(let progress):
            return Self.progressLine(processed: progress.processed, total: progress.total, itemType: progress.itemType)
        case .embedding:
            return "Vectors for every registered model"
        case .distilling:
            return "Facts for each new document"
        }
    }

    var ingestFraction: Double? {
        if case .ingesting(let progress) = activity { return progress.fraction }
        return nil
    }

    var currentItem: String? {
        if case .ingesting(let progress) = activity, let item = progress.currentItem, !item.isEmpty { return item }
        return nil
    }

    var databaseDetail: String {
        switch database {
        case .stopped: "Stopped"
        case .starting: "Starting…"
        case .stopping: "Stopping…"
        case .running: "Running"
        case .needsMigration: "Schema update needed"
        case .failed(let message): message
        }
    }

    var databaseTint: Color {
        switch database {
        case .running: .green
        case .starting, .stopping: .yellow
        case .needsMigration: .orange
        case .failed: .red
        case .stopped: .secondary
        }
    }

    var mcpDetail: String {
        switch mcp {
        case .stopped:
            return database == .running ? "Not running" : "Waits for the database"
        case .starting:
            return "Starting…"
        case .running(let clients):
            if clients == 0 { return "Serving · no assistants connected" }
            if clients == 1 { return "Serving · 1 assistant connected" }
            return "Serving · \(clients) assistants connected"
        case .stdio(let clients):
            if clients == 0 { return "Over stdio · no assistants connected" }
            if clients == 1 { return "Over stdio · 1 assistant connected" }
            return "Over stdio · \(clients) assistants connected"
        case .stopping:
            return "Stopping…"
        case .failed(let message):
            return message
        }
    }

    var mcpTint: Color {
        switch mcp {
        case .running, .stdio: .green
        case .starting, .stopping: .yellow
        case .failed: database == .running ? .red : .secondary
        case .stopped: .secondary
        }
    }

    /// The popover's overall tint, for the dot beside the headline.
    var tint: Color {
        switch database {
        case .running: isBusy ? .blue : .green
        case .starting, .stopping: .yellow
        case .needsMigration: .orange
        case .failed: .red
        case .stopped: .secondary
        }
    }

    // MARK: - Formatting

    static func percent(_ fraction: Double) -> String {
        "\(Int((min(1, max(0, fraction)) * 100).rounded()))%"
    }

    /// "1,204 of 2,860 documents", or just the processed count until a scan has sized the run.
    static func progressLine(processed: Int, total: Int, itemType: String) -> String {
        let noun = itemType.isEmpty ? "documents" : itemType
        if total > 0 {
            return "\(processed.formatted()) of \(total.formatted()) \(noun)"
        }
        return "\(processed.formatted()) \(noun)"
    }

    /// A path shortened the way Finder's title bar does: the home folder as "~", then the tail.
    static func abbreviatedPath(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard !home.isEmpty, path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}

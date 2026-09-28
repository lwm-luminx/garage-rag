import SwiftUI
import AppKit

// The Database page: is Postgres up and how do I reach it, is the schema current, what does the
// database hold, and backups (with the reset beside them). Postgres's own output is folded away at
// the bottom. The wording of every row is in DatabasePresentation.swift.

@MainActor
struct DatabaseView: View {
    @EnvironmentObject var appState: AppState
    @State private var showResetConfirmation = false
    @State private var showServerDetails = false
    @State private var serverDetails: DatabaseServerDetails?
    @State private var busy: BusyAction?
    @State private var pendingRestore: URL?
    /// The result of this page's last backup, restore or schema run, shown under the box it came from.
    @State private var result: ActionResult?
    @AppStorage("garage.database.showPostgresOutput") private var showPostgresOutput = false
    @AppStorage(DatabaseBackupRecord.dateKey) private var lastBackupAt: Double = 0
    @AppStorage(DatabaseBackupRecord.pathKey) private var lastBackupPath = ""

    private enum BusyAction: Equatable {
        case restarting, reapplyingSchema, backingUp, restoring
    }

    private struct ActionResult: Equatable {
        enum Box { case schema, backups }
        let box: Box
        let succeeded: Bool
        let message: String
    }

    private var isPostgresActive: Bool {
        appState.postgres.status == .running || appState.postgres.status == .needsMigration
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                serverSection
                schemaSection
                contentsSection
                backupsSection
                postgresOutputSection
            }
            .padding(20)
        }
        .navigationTitle("Database")
        .onAppear {
            appState.checkPendingMigrations()
            refreshContents()
        }
        .onChange(of: appState.postgres.status) { _, status in
            switch status {
            case .running:
                refreshContents()
            case .failed:
                // The reason is in Postgres's own output more often than in the one-line error.
                showPostgresOutput = true
                serverDetails = nil
            default:
                serverDetails = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .garageWillQuit)) { _ in
            showResetConfirmation = false
        }
        .sheet(isPresented: $showResetConfirmation) {
            DatabaseResetSheet()
                .environmentObject(appState)
        }
        .confirmationDialog(
            "Replace the database with this backup?",
            isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
            presenting: pendingRestore
        ) { source in
            Button("Replace Database", role: .destructive) { restore(from: source) }
                .accessibilityIdentifier("database.restore.confirm")
            Button("Cancel", role: .cancel) {}
        } message: { source in
            Text("Everything Garage has indexed now is replaced by the contents of \(source.lastPathComponent). Your original files are not touched.")
        }
    }

    // MARK: - Server

    private var headline: DatabaseHeadline {
        DatabaseHeadline(
            status: appState.postgres.status,
            port: appState.postgres.port,
            pendingMigrations: appState.postgres.pendingMigrations.count,
            isResetting: appState.isResettingDatabase,
            documents: appState.corpusStats.lastUpdated == nil ? nil : appState.corpusStats.documentsCount,
            sizeBytes: serverDetails?.databaseSizeBytes
        )
    }

    private var serverSection: some View {
        let headline = self.headline
        return GroupBox("Postgres") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    MenuBarSymbolCircle(symbol: headline.symbol, tint: headline.tint, isActive: headline.isActive)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(headline.title)
                            .font(.system(size: 13, weight: .semibold))
                        Text(headline.detail)
                            .font(.caption)
                            .foregroundStyle(headline.detailIsError ? AnyShapeStyle(Color.red) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 8)

                    if appState.postgres.status == .starting || appState.postgres.status == .stopping || busy == .restarting {
                        ProgressView().controlSize(.small)
                    }
                    serverActions
                }

                HStack(spacing: 6) {
                    connectionLine
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showServerDetails.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Details")
                                .font(.caption)
                            DisclosureChevron(isExpanded: showServerDetails)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("database.details.toggle")
                }
                .padding(.leading, 36)

                if showServerDetails {
                    serverDetailsGrid
                        .padding(.leading, 36)
                }
            }
            .padding(10)
        }
    }

    /// Start while stopped; Restart and Stop while it runs; nothing while it is on its way.
    @ViewBuilder
    private var serverActions: some View {
        let status = appState.postgres.status
        if appState.isResettingDatabase || busy == .restarting {
            EmptyView()
        } else if status == .running || status == .needsMigration {
            Button("Restart") { restartPostgres() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(busy != nil)
                .help("Stop Postgres and start it again, with the MCP server and Index Manager")
                .accessibilityIdentifier("database.restart")
            Button("Stop") { Task { await appState.stopPostgres() } }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(busy != nil)
                .help("Stop Postgres. Search, ingest and the MCP server stop with it.")
                .accessibilityIdentifier("database.stop")
        } else if status == .stopped || isFailed(status) {
            Button(status == .stopped ? "Start" : "Try Again") { Task { await appState.startPostgres() } }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier("database.start")
        }
    }

    /// The connection URL with its password hidden, and the two ways to use it.
    @ViewBuilder
    private var connectionLine: some View {
        if let url = try? appState.postgres.standardConnectionURL() {
            Text(PostgresService.redactedConnectionString(url))
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Button {
                appState.copyDatabaseURLToClipboard()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Copy the connection URL, password included")
            .accessibilityLabel("Copy Connection URL")
            .accessibilityIdentifier("database.copyURL")
            Button {
                appState.openDatabaseInHandler()
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Open the database in the app registered for postgresql:// links")
            .accessibilityLabel("Open in Database App")
            .accessibilityIdentifier("database.openURL")
        } else {
            Text("Connection URL unavailable")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var serverDetailsGrid: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                detailLabel("Data folder")
                HStack(spacing: 8) {
                    detailValue(Paths.displayPath(of: Paths.pgDataDir), monospaced: true)
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Paths.pgDataDir])
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
            GridRow {
                detailLabel("Database")
                detailValue("\(appState.postgres.databaseName) on port \(appState.postgres.port)", monospaced: true)
            }
            GridRow {
                detailLabel("Server")
                detailValue(serverLine)
            }
            if let extensions = serverDetails?.extensions, !extensions.isEmpty {
                GridRow {
                    detailLabel("Extensions")
                    detailValue(extensions.map { "\($0.name) \($0.version)" }.joined(separator: ", "), monospaced: true)
                }
            }
        }
    }

    private var serverLine: String {
        let build = Paths.isPackaged ? "bundled with Garage" : "Homebrew install (development build)"
        guard let version = serverDetails?.serverVersion, !version.isEmpty else { return "PostgreSQL, \(build)" }
        return "PostgreSQL \(version), \(build)"
    }

    private func detailLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    private func detailValue(_ text: String, monospaced: Bool = false) -> some View {
        Text(text)
            .font(monospaced ? .system(.caption, design: .monospaced) : .caption)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Schema

    private var schemaSection: some View {
        let schema = DatabaseSchemaPresentation(
            status: appState.postgres.status,
            pendingMigrations: appState.postgres.pendingMigrations,
            isApplying: appState.isApplyingMigrations || busy == .reapplyingSchema
        )
        return GroupBox("Schema") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    MenuBarSymbolCircle(symbol: schema.symbol, tint: schema.tint, isActive: schema.isActive)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(schema.title)
                            .font(.system(size: 13, weight: .semibold))
                        Text(schema.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)

                    if schema.action == .hidden, appState.isApplyingMigrations || busy == .reapplyingSchema {
                        ProgressView().controlSize(.small)
                    }
                    switch schema.action {
                    case .apply:
                        Button("Apply Updates") { applyMigrations() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(busy != nil)
                            .accessibilityIdentifier("database.applyMigrations")
                    case .check:
                        Button("Check Again") { appState.checkPendingMigrations() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityIdentifier("database.checkMigrations")
                    case .hidden:
                        EmptyView()
                    }
                    Menu {
                        Button("Check for Schema Updates") { appState.checkPendingMigrations() }
                        Button("Re-apply the Whole Schema") { reapplySchema() }
                            .help("Run every schema file again. They are written to be re-applied, so nothing is lost.")
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(appState.postgres.status != .running || busy != nil || appState.isApplyingMigrations)
                    .accessibilityLabel("More Schema Actions")
                    .accessibilityIdentifier("database.schema.more")
                }

                if !appState.postgres.pendingMigrations.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(appState.postgres.pendingMigrations, id: \.self) { migration in
                            Text(migration)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.leading, 36)
                }

                resultLine(for: .schema)
                    .padding(.leading, 36)
            }
            .padding(10)
        }
    }

    // MARK: - Contents

    /// Titled with `GroupBox("Contents")`, with Refresh beside the figures rather than in a custom
    /// label: on macOS a GroupBox's custom label is not in the accessibility tree, so neither the
    /// title nor the button could be reached there.
    private var contentsSection: some View {
        let contents = DatabaseContentsPresentation(stats: appState.corpusStats, sizeBytes: serverDetails?.databaseSizeBytes)
        return GroupBox("Contents") {
            HStack(alignment: .top, spacing: 8) {
                if appState.postgres.status != .running {
                    Text("Shown once the database is running.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(contents.figures) { figure in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(figure.label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(figure.value)
                                    .font(.system(.title3, design: .rounded).weight(.semibold))
                                    .monospacedDigit()
                                if let note = figure.note {
                                    Text(note)
                                        .font(.caption2)
                                        .foregroundStyle(figure.noteIsWarning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                if appState.isFetchingStats {
                    ProgressView().controlSize(.mini)
                }
                Button {
                    refreshContents()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(appState.postgres.status != .running || appState.isFetchingStats)
                .help("Count again")
                .accessibilityLabel("Refresh Contents")
                .accessibilityIdentifier("database.contents.refresh")
            }
            .padding(10)
        }
    }

    // MARK: - Backups

    private var backupsSection: some View {
        let record = DatabaseBackupRecord(timestamp: lastBackupAt, path: lastBackupPath)
        return GroupBox("Backups") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    MenuBarSymbolCircle(symbol: "externaldrive", tint: .blue, isActive: record != nil)
                    VStack(alignment: .leading, spacing: 2) {
                        if let record {
                            Text("Last backup \(record.date, style: .relative) ago")
                                .font(.system(size: 13, weight: .semibold))
                            HStack(spacing: 6) {
                                Text(record.url.lastPathComponent)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(record.url.path)
                                if record.fileExists {
                                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([record.url]) }
                                        .buttonStyle(.link)
                                        .font(.caption)
                                } else {
                                    Text("moved or deleted")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }
                        } else {
                            Text("No backup yet")
                                .font(.system(size: 13, weight: .semibold))
                            Text("A backup is one file in PostgreSQL's portable format, with everything Garage has indexed.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)

                    if busy == .backingUp || busy == .restoring {
                        ProgressView().controlSize(.small)
                    }
                    Button("Back Up…") { backUp() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!isPostgresActive || busy != nil)
                        .accessibilityIdentifier("database.backup")
                    Button("Restore…") { chooseBackupSource() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!isPostgresActive || busy != nil)
                        .help("Replace the database with a backup")
                        .accessibilityIdentifier("database.restore")
                }

                resultLine(for: .backups)
                    .padding(.leading, 36)

                Divider()

                HStack(alignment: .center, spacing: 10) {
                    MenuBarSymbolCircle(symbol: "trash", tint: .red, isActive: false)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Start Over")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Deletes the database and builds a new, empty one. Your original files are not touched.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if appState.isResettingDatabase {
                        ProgressView().controlSize(.small)
                    }
                    Button("Reset Database…") { showResetConfirmation = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.red)
                        .accessibilityIdentifier("database.reset")
                        .disabled(
                            appState.isResettingDatabase
                                || busy != nil
                                || appState.postgres.status == .starting
                                || appState.postgres.status == .stopping
                        )
                }

                // After a reset, the relaunched instance says what it is still doing, then what it
                // rebuilt, or what went wrong.
                if appState.isFinishingDatabaseReset, appState.databaseResetOutcome == nil {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                            .accessibilityHidden(true)
                        Text(AppState.databaseResetInProgressMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("database.resetProgress")
                    }
                    .font(.caption)
                    .padding(.leading, 36)
                }
                if let outcome = appState.databaseResetOutcome {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: outcome.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(outcome.succeeded ? Color.green : Color.red)
                            .accessibilityHidden(true)
                        Text(outcome.message)
                            .font(.caption)
                            .foregroundStyle(outcome.succeeded ? AnyShapeStyle(HierarchicalShapeStyle.secondary) : AnyShapeStyle(Color.red))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("database.resetOutcome")
                    }
                    .font(.caption)
                    .padding(.leading, 36)
                }
            }
            .padding(10)
        }
    }

    // MARK: - Postgres output

    /// Postgres's own log, folded away: it is for looking into a failure, not for glancing at. It
    /// opens by itself when Postgres fails to start.
    @ViewBuilder
    private var postgresOutputSection: some View {
        let lines = appState.postgres.logs
        if !lines.isEmpty {
            GroupBox {
                if showPostgresOutput {
                    LogTableView(lines: lines, sourceName: "Postgres") {
                        appState.clearLogs(for: "Postgres")
                    }
                    .frame(minHeight: 200, maxHeight: 350)
                }
            } label: {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showPostgresOutput.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        DisclosureChevron(isExpanded: showPostgresOutput)
                        Text("Postgres Output")
                        Text(DatabasePagePresentation.count(lines.count, "line"))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("database.postgresOutput.toggle")
            }
        }
    }

    // MARK: - Results

    @ViewBuilder
    private func resultLine(for box: ActionResult.Box) -> some View {
        if let result, result.box == box {
            Label {
                Text(result.message)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: result.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(result.succeeded ? Color.green : Color.red)
            }
            .foregroundStyle(result.succeeded ? AnyShapeStyle(HierarchicalShapeStyle.secondary) : AnyShapeStyle(Color.red))
        }
    }

    // MARK: - Actions

    private func isFailed(_ status: PostgresStatus) -> Bool {
        if case .failed = status { return true }
        return false
    }

    private func refreshContents() {
        guard appState.postgres.status == .running else { return }
        Task {
            await appState.fetchCorpusStats()
            serverDetails = try? await appState.postgres.fetchServerDetails()
        }
    }

    private func restartPostgres() {
        busy = .restarting
        Task {
            await appState.stopPostgres()
            await appState.startPostgres()
            busy = nil
        }
    }

    private func applyMigrations() {
        Task {
            await appState.applyMigrations()
            result = ActionResult(box: .schema, succeeded: appState.lastCommandSucceeded == true, message: appState.lastCommandOutput)
            refreshContents()
        }
    }

    private func reapplySchema() {
        busy = .reapplyingSchema
        Task {
            let succeeded = await appState.runOperation {
                try await $0.initDatabase(schemaDir: Paths.schemaDir.path).message
            }
            await appState.postgres.refreshPendingMigrations()
            let output = appState.lastCommandOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            result = ActionResult(
                box: .schema,
                succeeded: succeeded,
                message: output.isEmpty ? (succeeded ? "Re-applied the schema." : "Re-applying the schema failed.") : output
            )
            busy = nil
        }
    }

    private func backUp() {
        guard let destination = DatabaseBackupPanel.chooseDestination() else { return }
        busy = .backingUp
        Task {
            let succeeded = await appState.backupDatabase(to: destination)
            result = ActionResult(
                box: .backups,
                succeeded: succeeded,
                message: succeeded ? "Saved \(destination.lastPathComponent)." : appState.lastCommandOutput
            )
            busy = nil
        }
    }

    private func chooseBackupSource() {
        let panel = NSOpenPanel()
        panel.title = "Restore Garage Database"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK, let source = panel.url else { return }
        pendingRestore = source
    }

    private func restore(from source: URL) {
        pendingRestore = nil
        busy = .restoring
        Task {
            let succeeded = await appState.restoreDatabase(from: source)
            result = ActionResult(
                box: .backups,
                succeeded: succeeded,
                message: succeeded ? "Restored from \(source.lastPathComponent)." : appState.lastCommandOutput
            )
            busy = nil
            refreshContents()
        }
    }
}

/// The save panel for a database backup, shared by Back Up… and the reset sheet's Back Up First….
@MainActor
enum DatabaseBackupPanel {
    static func chooseDestination() -> URL? {
        let panel = NSSavePanel()
        panel.title = "Back Up Garage Database"
        panel.nameFieldStringValue = "garage-rag-\(timestamp()).dump"
        panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

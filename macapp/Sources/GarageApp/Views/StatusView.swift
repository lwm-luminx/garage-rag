import SwiftUI
import AppKit
import Combine
import PythonXPCService

// The Status page: is anything wrong and what fixes it, what the pipeline is doing and how much of
// the corpus is indexed, and whether each helper process is alive. The helpers' output is folded
// away at the bottom. The wording of every row is in StatusPagePresentation.swift.

@MainActor
struct StatusView: View {
    @EnvironmentObject var appState: AppState
    @Binding var selection: AppSection?

    init(selection: Binding<AppSection?> = .constant(.status)) {
        self._selection = selection
    }

    @State var refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    @State var expandedServiceIds: Set<String> = []
    @State var grpcTestResult: (isSuccess: Bool, summary: String, details: String, durationMs: Double)? = nil
    @State var isTestingGrpc: Bool = false
    @State var copiedServiceId: String? = nil
    @AppStorage("garage.status.showServiceOutput") private var showServiceOutput = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                healthSection
                indexingSection
                automaticUpdatesSection
                indexManagerSection
                servicesSection
                serviceOutputSection
            }
            .padding(20)
        }
        .navigationTitle("Status")
        .onAppear {
            Task {
                await appState.fetchRegisteredSources()
                await appState.fetchCorpusStats()
                await appState.xpcServices.refreshAll()
                if appState.xpcServices.statusReports.isEmpty {
                    await appState.xpcServices.refreshAllStatusReports()
                }
            }
        }
        .onReceive(refreshTimer) { _ in
            Task {
                await appState.fetchCorpusStats()
                await appState.xpcServices.refreshAll()
            }
        }
    }

    // MARK: - Health

    private var healthSection: some View {
        let health = StatusHealth(appState: appState)
        return GroupBox("Health") {
            VStack(alignment: .leading, spacing: 10) {
                if health.isHealthy {
                    let summary = health.summary
                    HStack(alignment: .center, spacing: 10) {
                        MenuBarSymbolCircle(symbol: summary.symbol, tint: summary.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(summary.title)
                                .font(.system(size: 13, weight: .semibold))
                            Text(summary.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if health.database == .starting || health.database == .stopping {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("status.health.summary")
                } else {
                    ForEach(Array(health.problems.enumerated()), id: \.element.id) { index, problem in
                        if index > 0 {
                            Divider()
                        }
                        problemRow(problem)
                    }
                }
            }
            .padding(10)
        }
    }

    private func problemRow(_ problem: StatusHealth.Problem) -> some View {
        HStack(alignment: .center, spacing: 10) {
            MenuBarSymbolCircle(symbol: "exclamationmark", tint: problem.severity == .critical ? .red : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(problem.title)
                    .font(.system(size: 13, weight: .semibold))
                if let detail = problem.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(problem.detailIsError ? AnyShapeStyle(Color.red) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)

            if let fix = problem.fix {
                Button(problem.fixLabel ?? fix.label) {
                    perform(fix)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isFixRunning(fix))
                .accessibilityIdentifier("status.health.\(problem.id).fix")
            }
            Button {
                selection = problem.section
            } label: {
                HStack(spacing: 4) {
                    Text(problem.section.rawValue)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Open \(problem.section.rawValue)")
            .accessibilityIdentifier("status.health.\(problem.id).open")
        }
        // A container of its own: an identifier on a plain HStack is handed down to every child,
        // replacing the fix and Open buttons' own identifiers.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("status.health.\(problem.id)")
    }

    private func isFixRunning(_ fix: StatusHealth.Fix) -> Bool {
        switch fix {
        case .startDatabase: appState.postgres.status == .starting
        case .applyMigrations: appState.isApplyingMigrations
        case .startMCP: appState.mcp.status == .starting
        case .testMCP: false
        case .chooseDisk, .grantFolder, .openPrivacySettings, .checkSourceAccess: false
        case .refreshLlama: appState.llama.isBusy
        }
    }

    private func perform(_ fix: StatusHealth.Fix) {
        switch fix {
        case .startDatabase:
            Task { await appState.startPostgres() }
        case .applyMigrations:
            Task { await appState.applyMigrations() }
        case .startMCP:
            appState.mcp.setHTTPEnabled(true)
            Task { try? await appState.mcp.start() }
        case .testMCP:
            Task { await appState.mcp.testServerConnection() }
        case .chooseDisk:
            _ = appState.promptAndSelectRootVolume()
        case .grantFolder(let slug, let path):
            _ = appState.promptAndSelectSourceDirectory(slug: slug, suggestedPath: path)
        case .openPrivacySettings:
            appState.openPrivacySettings(for: .fullDiskAccess)
        case .checkSourceAccess:
            _ = appState.testVolumeAccess()
        case .refreshLlama:
            Task { await appState.llama.refreshStatus() }
        }
    }

    // MARK: - Library

    private var indexingSection: some View {
        let indexing = IndexingPresentation(appState: appState)
        let headline = indexing.headline
        return GroupBox("Library") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    MenuBarSymbolCircle(symbol: headline.symbol, tint: headline.tint, isActive: headline.isActive)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(headline.title)
                                .font(.system(size: 15, weight: .semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .accessibilityIdentifier("status.library.title")
                            if let percent = headline.percent {
                                Text(percent)
                                    .font(.system(size: 13))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if headline.isIndeterminate {
                            ProgressView()
                                .progressViewStyle(.linear)
                                .controlSize(.small)
                        } else if let progress = headline.progress {
                            ProgressView(value: progress)
                                .progressViewStyle(.linear)
                                .controlSize(.small)
                        }
                        if let detail = headline.detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(headline.detailIsError ? AnyShapeStyle(Color.red) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                                .monospacedDigit()
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                                .accessibilityIdentifier("status.library.detail")
                        }
                        if let item = headline.currentItem {
                            Text(item)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if indexing.isRunning, let stage = headline.stage {
                            MenuBarStageTrail(stages: indexing.stageTrail, current: stage)
                                .padding(.top, 2)
                        }
                    }

                    Spacer(minLength: 12)

                    HStack(spacing: 8) {
                        if indexing.isRunning || appState.isFetchingStats {
                            ProgressView().controlSize(.small)
                        }
                        indexingAction(indexing.action)
                    }
                }

                if appState.postgres.status == .running, appState.corpusStats.lastUpdated != nil {
                    Divider()
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(indexing.figures) { figure in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(figure.label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(figure.value)
                                    .font(.system(.title3, design: .rounded).weight(.semibold))
                                    .monospacedDigit()
                                    .accessibilityIdentifier("status.figure.\(figure.label.lowercased())")
                                if let note = figure.note {
                                    Text(note)
                                        .font(.caption2)
                                        .foregroundStyle(figure.noteIsWarning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.leading, 36)
                }
            }
            .padding(10)
        }
    }

    @ViewBuilder
    private func indexingAction(_ action: IndexingPresentation.Action) -> some View {
        switch action {
        case .addSource:
            Button("Add a Source…") {
                selection = .sources
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityIdentifier("status.addSource")
        case .updateEverything(let enabled):
            // Icon buttons, as the service rows have: the box's title and detail already say
            // what the library is, so the actions only need their symbols and a tooltip.
            Button {
                Task { await appState.updateEverything() }
            } label: {
                Label("Update Everything", systemImage: "arrow.triangle.2.circlepath")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!enabled)
            .help("Update Everything: scan and read every source, index the new chunks with every model, then glean facts from the new documents")
            .accessibilityIdentifier("status.updateEverything")
        case .stop(let isStopping):
            Button {
                // cancelAll stops a backfill or distillation only when a whole-pipeline run started
                // it; one started from Models has its own runner to cancel.
                appState.cancelAll()
                appState.backfill.cancel()
                appState.enrichFacts.cancel()
            } label: {
                if isStopping {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Stop", systemImage: "stop.fill")
                        .labelStyle(.iconOnly)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.red)
            .disabled(isStopping)
            .help(isStopping ? "Stopping…" : "Stop the run after its current step")
            .accessibilityLabel(isStopping ? "Stopping" : "Stop")
            .accessibilityIdentifier("status.stop")
        }
    }

    // MARK: - Automatic updates

    /// Under Library, since a scheduled run is the same scan, read and index that Update Everything
    /// starts by hand, and the models and facts it covers are not the Sources page's alone.
    private var automaticUpdatesSection: some View {
        GroupBox("Automatic Updates") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 16) {
                    Toggle("Keep every source up to date", isOn: $appState.scheduledMaintenanceEnabled)
                    Picker("Every", selection: $appState.scheduledMaintenanceInterval) {
                        Text("15 minutes").tag(TimeInterval(15 * 60))
                        Text("hour").tag(TimeInterval(60 * 60))
                        Text("6 hours").tag(TimeInterval(6 * 60 * 60))
                        Text("24 hours").tag(TimeInterval(24 * 60 * 60))
                    }
                    .fixedSize()
                    .disabled(!appState.scheduledMaintenanceEnabled)
                }
                Toggle("Also run when Garage starts", isOn: $appState.maintenanceRunsAtLaunch)
                    .disabled(!appState.scheduledMaintenanceEnabled)
                    .help("Run once as soon as the database is up after launch, instead of waiting a whole interval for the first run.")
                    .accessibilityIdentifier("status.maintenance.atLaunch")
                Text("Each run scans and ingests every source, then embeds the new chunks with every registered model. Otherwise the first run starts after the chosen interval; a source added meanwhile is scanned as soon as the current run ends.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    // MARK: - Service output

    /// The XPC manager's log, folded away: it is for looking into a helper that stopped answering,
    /// not for glancing at.
    @ViewBuilder
    private var serviceOutputSection: some View {
        let lines = appState.xpcServices.logs
        if !lines.isEmpty {
            GroupBox {
                if showServiceOutput {
                    LogTableView(lines: lines, sourceName: "XPC Services") {
                        appState.clearLogs(for: "XPC Services")
                    }
                    .frame(minHeight: 200, maxHeight: 350)
                }
            } label: {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showServiceOutput.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        DisclosureChevron(isExpanded: showServiceOutput)
                        Text("Service Output")
                        Text("\(lines.count.formatted()) \(IndexingPresentation.plural("line", lines.count))")
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("status.serviceOutput.toggle")
            }
        }
    }
}

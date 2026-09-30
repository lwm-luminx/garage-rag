import SwiftUI
import AppKit
import Combine
import IngestClient
import PythonXPCService

// The Sources page: what needs fixing at the top, what the pipeline is doing now, then one row per
// source with its state and the one action that applies to it, and a form to add another. The
// logic behind every row and the attention list is in SourcesPresentation.swift.

@MainActor
struct SourcesView: View {
    @EnvironmentObject var appState: AppState

    @State private var refreshTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()
    @State private var slug = ""
    @State private var root = ""
    @State private var kind = "filesystem"
    @State private var corpusClass = "document"
    @State private var trust = "authored"

    @State private var busy = false
    @State private var ingestAutoDismissTask: Task<Void, Never>?
    @AppStorage("garage.sources.showIngestOutput") private var showIngestOutput = false

    /// The common locations, resolved against the disk once per visit rather than on every draw.
    @State private var templates: [FirstRunSourceTemplate] = []
    @State private var addingTemplateID: String? = nil
    @State private var addFolderError: String? = nil
    /// Why the last Remove Source failed; shown above the list until the next removal.
    @State private var removeError: String? = nil
    /// The custom-source form is folded away until "Custom Source…" or a row's "Edit…" opens it.
    @State private var showCustomForm = false
    /// The last name the form filled in by itself. While the field still holds it (or nothing),
    /// a new folder or kind fills in a new one; a name the person typed is kept.
    @State private var suggestedSlug = ""

    private let kinds = ["filesystem", "git", "sqlite", "maildir", "feed"]
    private let classes = ["document", "code", "communication"]
    private let trusts = ["authored", "reference", "received"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                attentionSection
                activitySection
                sourcesSection
                addSourceSection
                ingestOutputSection
            }
            .padding(20)
        }
        .navigationTitle("Sources")
        .onAppear {
            templates = FirstRunSourceTemplate.builtIn(
                assumeAvailable: GarageAppGroup.isSandboxed && !appState.volumeAccess.status.isGranted
            )
            refreshSourcesAndTestDisk()
        }
        .onChange(of: root) { _, _ in suggestSlugIfUnedited() }
        .onChange(of: kind) { _, _ in suggestSlugIfUnedited() }
        .onDisappear {
            ingestAutoDismissTask?.cancel()
            ingestAutoDismissTask = nil
        }
        .onReceive(refreshTimer) { _ in
            if appState.ingestService.isRunning || appState.isScanning {
                Task {
                    await appState.fetchRegisteredSources()
                    await appState.fetchCorpusStats()
                }
            }
        }
        .onChange(of: appState.ingestService.isRunning) { _, isRunning in
            ingestAutoDismissTask?.cancel()
            guard !isRunning else { return }
            ingestAutoDismissTask = Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard !Task.isCancelled else { return }
                appState.ingestService.clearTransientMessages()
            }
        }
    }

    // MARK: - Attention

    private var attentions: [SourcesAttention] {
        SourcesAttention.attentions(
            volumeStatus: appState.volumeAccess.status,
            testResult: appState.volumeAccess.lastTestResult,
            sources: appState.registeredSources
        )
    }

    /// One row per problem, each with the action that fixes it. Nothing at all while every source reads.
    @ViewBuilder
    private var attentionSection: some View {
        let items = attentions
        if !items.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().padding(.vertical, 6) }
                        HStack(alignment: .top, spacing: 12) {
                            MenuBarSymbolCircle(symbol: item.symbol, tint: item.tint)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title)
                                    .font(.headline)
                                Text(item.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 12)
                            HStack(spacing: 8) {
                                ForEach(item.secondary, id: \.title) { command in
                                    Button(command.title) { perform(command.action) }
                                        .controlSize(.small)
                                }
                                Button(item.primary.title) { perform(item.primary.action) }
                                    .controlSize(.small)
                                    .buttonStyle(.borderedProminent)
                            }
                            .fixedSize()
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding(8)
            }
            .accessibilityIdentifier("sources.attention")
        }
    }

    private func perform(_ action: SourcesAttention.Action) {
        switch action {
        case .selectHomeFolder:
            _ = appState.promptAndSelectHomeFolder()
            _ = appState.testVolumeAccess()
        case .selectDisk:
            _ = appState.promptAndSelectRootVolume()
            _ = appState.testVolumeAccess()
        case .grantFolder(let slug, let path):
            _ = appState.promptAndSelectSourceDirectory(slug: slug, suggestedPath: path)
        case .tccPrompt(let category, let slug, let path):
            _ = appState.promptTCCPermission(category: category, sourceSlug: slug, sourcePath: path)
        case .openPrivacySettings(let category):
            appState.openPrivacySettings(for: category)
        case .recheck:
            _ = appState.testVolumeAccess()
        }
    }

    // MARK: - Activity

    /// What the pipeline is doing, or what the last run left behind (kept for a few seconds).
    private var activity: SourcesActivityPresentation? {
        let service = appState.ingestService
        if appState.isScanning {
            let scan = appState.scanProgress
            return .scanning(source: scan?.source ?? "*", itemsSoFar: scan?.totalItems ?? 0)
        }
        if service.isRunning {
            let single = service.runSources.count <= 1 && service.currentSource != "*" ? service.currentSource : nil
            let total = appState.combinedIngestTotalExpected
            let counts = SourceRowPresentation.runCounts(
                seen: appState.combinedIngestProcessedCount,
                total: total,
                indexed: appState.combinedIngestIndexedCount,
                skipped: appState.combinedIngestSkippedCount,
                failed: appState.combinedIngestFailedCount,
                itemType: appState.combinedIngestItemType
            )
            return .ingesting(
                subject: single,
                current: service.currentSource,
                fraction: appState.combinedIngestProgressFraction,
                hasTotal: total > 0,
                percent: appState.combinedIngestProgressPercent,
                counts: counts,
                currentItem: service.latestProgress?.currentItem,
                isCancelling: service.isCancelling || appState.isCancellingAll
            )
        }
        if appState.backfill.isRunning, appState.isMaintenanceRunning {
            return .embedding()
        }
        if appState.enrichFacts.isRunning, appState.isUpdatingEverything {
            return .distilling()
        }
        if !appState.sourcesAwaitingScan.isEmpty || !appState.ingestQueue.isEmpty {
            return .waiting(queued: appState.sourcesAwaitingScan + appState.ingestQueue)
        }
        if let last = service.latestProgress {
            let single = last.source.isEmpty || last.source == "*" ? nil : last.source
            let counts = SourceRowPresentation.runCounts(
                seen: last.seen, total: last.totalItems, indexed: last.indexed,
                skipped: last.skipped, failed: last.failed, itemType: last.itemType
            )
            return .ended(subject: single, counts: counts, wasCancelled: last.isCancelled, error: last.error ?? service.lastError)
        }
        return nil
    }

    @ViewBuilder
    private var activitySection: some View {
        if let activity {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 12) {
                        MenuBarSymbolCircle(symbol: activity.symbol, tint: activity.tint)
                        Text(activity.title)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .accessibilityIdentifier("sources.activity.title")
                        if let percent = activity.percent {
                            Text(percent)
                                .font(.headline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if activity.isRunning {
                            Button(appState.isCancellingAll ? "Stopping…" : "Stop") {
                                appState.cancelAll()
                            }
                            .controlSize(.small)
                            .tint(.red)
                            .disabled(appState.isCancellingAll)
                            .help("Stop this run and everything queued after it.")
                            .accessibilityIdentifier("sources.cancelAll")
                        }
                    }

                    if activity.isIndeterminate {
                        ProgressView()
                            .progressViewStyle(.linear)
                    } else if let progress = activity.progress {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                    }

                    if let detail = activity.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let item = activity.currentItem {
                        Text(item)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let error = activity.error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // A whole-pipeline run reads as "step 2 of 4", not an ingest that never ends.
                    if appState.isUpdatingEverything, let stage = activity.stage {
                        MenuBarStageTrail(stages: MenuBarStatus.Stage.allCases, current: stage)
                            .padding(.top, 2)
                    }
                }
                .padding(8)
            }
            .accessibilityIdentifier("sources.activity")
        }
    }

    // MARK: - Sources

    /// Titled with the summary line, with the list's buttons on the box's first row rather than in a
    /// custom label: on macOS a GroupBox's custom label is not in the accessibility tree, so Update
    /// Everything, Scan & Ingest All and Sync could not be reached there.
    private var sourcesSection: some View {
        GroupBox(SourcesSummary.line(sources: appState.registeredSources.count, documents: appState.corpusStats.documentsCount)) {
            VStack(alignment: .leading, spacing: 0) {
                sourcesToolbar
                    .padding(.bottom, 12)

                if let removeError {
                    Text(removeError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 10)
                        .accessibilityIdentifier("sources.removeError")
                }

                if appState.registeredSources.isEmpty {
                    emptyState
                } else {
                    ForEach(Array(appState.registeredSources.enumerated()), id: \.element.id) { index, source in
                        if index > 0 { Divider().padding(.vertical, 10) }
                        sourceRow(for: source)
                    }
                }

                Divider().padding(.top, 14).padding(.bottom, 8)
                diskAccessFooter
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
    }

    private var sourcesToolbar: some View {
        HStack(spacing: 8) {
            Spacer()

            Button("Update Everything") {
                Task { await appState.updateEverything() }
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .disabled(appState.registeredSources.isEmpty || notReady || appState.hasCancellableWork
                      || appState.backfill.isRunning || appState.enrichFacts.isRunning)
            .help("Scan and ingest every source, embed the new chunks with every model, then glean facts from what has not been distilled yet.")
            .accessibilityIdentifier("sources.updateEverything")

            Button {
                scanAndIngest(slug: "*")
            } label: {
                Label("Scan & Ingest All", systemImage: "square.and.arrow.down.on.square")
            }
            .controlSize(.small)
            .disabled(appState.registeredSources.isEmpty || notReady || appState.hasCancellableWork)
            .help("Count what every source holds, then index what is new or changed. Use Update Everything to also embed and glean facts.")
            .accessibilityIdentifier("sources.scanIngestAll")

            Button {
                syncSources()
            } label: {
                Label("Sync", systemImage: "arrow.triangle.2.circlepath")
            }
            .controlSize(.small)
            .help("Keep garage.json and the database listing the same sources: sources added here are written to the file, and sources declared in the file are applied.")
            .accessibilityLabel("Sync sources")
            .accessibilityIdentifier("sources.sync")
            .disabled(notReady)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .center, spacing: 8) {
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No sources configured yet.")
                .font(.headline)
            Text("Pick a location below, add a folder of your own, or declare sources in garage.json and click Sync.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var diskAccessIsFine: Bool {
        appState.volumeAccess.status.isGranted && appState.volumeAccess.lastTestResult?.isAccessible != false
    }

    /// Only access the person granted by picking a disk can be revoked or moved to another disk.
    private var diskAccessIsSecurityScoped: Bool {
        if case .accessGranted(_, let isSecurityScoped) = appState.volumeAccess.status {
            return isSecurityScoped
        }
        return false
    }

    /// One line on disk access at the foot of the list. It only repeats the attention list while
    /// something is wrong; the rest of the time it is the one place that says access is fine.
    private var diskAccessFooter: some View {
        let symbol = diskAccessIsFine ? "checkmark.seal" : appState.volumeAccess.status.symbol
        let color = diskAccessIsFine ? Color.green : appState.volumeAccess.status.color
        return HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .font(.caption)
            Text(diskAccessSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Re-check") {
                _ = appState.testVolumeAccess()
            }
            .controlSize(.small)
            .buttonStyle(.borderless)
            .help("Check again that every source folder can be read.")
            .accessibilityLabel("Re-check disk access")
            .accessibilityIdentifier("sources.diskAccess.refresh")

            Menu {
                Button("Open Privacy Settings…") {
                    appState.openPrivacySettings(for: .fullDiskAccess)
                }
                if diskAccessIsSecurityScoped {
                    Button("Choose Another Disk…") {
                        _ = appState.promptAndSelectRootVolume()
                        _ = appState.testVolumeAccess()
                    }
                    Divider()
                    Button("Revoke Disk Access", role: .destructive) {
                        appState.revokeVolumeAccess()
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24)
            .accessibilityLabel("Disk access options")
        }
    }

    private var diskAccessSummary: String {
        switch appState.volumeAccess.status {
        case .accessGranted(let url, let isSecurityScoped):
            if let result = appState.volumeAccess.lastTestResult, !result.isAccessible {
                return "Some source folders can't be read. See the top of the page."
            }
            let where_ = isSecurityScoped ? "Reads \(url.path) with the access you granted." : "Reads the whole disk (no sandbox)."
            if let result = appState.volumeAccess.lastTestResult, !result.sourcePathResults.isEmpty {
                return "Every source folder can be read. \(where_)"
            }
            return where_
        case .notConfigured:
            return "No disk selected yet: only folders you grant one by one can be read."
        case .accessDenied(let reason):
            return "Disk access denied: \(reason)"
        case .staleBookmark(let url):
            return "The saved access to \(url.path) needs re-granting."
        }
    }

    // MARK: - Source rows

    private func activity(for source: RegisteredSource) -> SourceActivity {
        let service = appState.ingestService
        if appState.sourcesBeingRemoved.contains(source.slug) {
            return .removing
        }
        if service.isRunning, service.currentSource == source.slug, let progress = service.latestProgress {
            let total = appState.sourceTotalExpected(for: source.slug)
            let hasTotal = total > 0 || progress.totalItems > 0
            return .ingesting(SourceIngestSnapshot(
                phase: progress.phase,
                fraction: hasTotal ? appState.sourceProgressFraction(for: source.slug) : nil,
                percent: hasTotal ? appState.sourceProgressPercent(for: source.slug) : progress.formattedPercent,
                seen: progress.seen,
                total: total > 0 ? total : progress.totalItems,
                indexed: progress.indexed,
                skipped: progress.skipped,
                failed: progress.failed,
                itemType: progress.itemType,
                currentItem: progress.currentItem,
                message: progress.message,
                isCancelling: service.isCancelling
            ))
        }
        if let scanning = appState.scanningSource, scanning == source.slug || (scanning == "*" && appState.scanningSlugs.contains(source.slug)) {
            return .scanning
        }
        if appState.isQueued(source: source.slug) || appState.isPending(source: source.slug) {
            return .queued
        }
        return .idle
    }

    private func lastRun(for source: RegisteredSource) -> SourceLastRun? {
        guard let progress = appState.ingestService.progressBySource[source.slug] else { return nil }
        return SourceLastRun(
            indexed: progress.indexed,
            skipped: progress.skipped,
            failed: progress.failed,
            error: progress.error,
            wasCancelled: progress.isCancelled
        )
    }

    private func accessResult(for source: RegisteredSource) -> SourcePathAccessResult? {
        appState.volumeAccess.lastTestResult?.sourcePathResults.first {
            $0.slug == source.slug || $0.rawPath == source.root
        }
    }

    private func sourceRow(for source: RegisteredSource) -> some View {
        let access = accessResult(for: source)
        let row = SourceRowPresentation.make(
            source: source,
            access: access,
            activity: activity(for: source),
            lastRun: lastRun(for: source),
            isCancellingAll: appState.isCancellingAll
        )
        let isRemoving = appState.sourcesBeingRemoved.contains(source.slug)

        return HStack(alignment: .top, spacing: 12) {
            MenuBarSymbolCircle(symbol: row.symbol, tint: row.tint)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .center, spacing: 8) {
                    Text(row.title)
                        .font(.headline)
                        .lineLimit(1)
                        .layoutPriority(1)
                        .accessibilityIdentifier("sources.row.\(source.slug)")

                    // Each badge is one token; the title truncates before a badge wraps.
                    HStack(spacing: 6) {
                        CorpusClassBadge(corpusClass: source.corpusClass)
                        TrustTierBadge(tier: source.trust)
                        ForEach(row.badges) { badge in
                            StatusBadge(badge.text, tint: badge.tone.color)
                        }
                    }
                    .fixedSize()

                    Spacer(minLength: 8)

                    HStack(spacing: 8) {
                        if row.showsCancel {
                            Button(row.cancelTitle) {
                                Task { await appState.cancel(source: source.slug) }
                            }
                            .controlSize(.small)
                            .tint(.red)
                            .disabled(row.cancelDisabled)
                            .help("Take this source out of the run; the others go on.")
                            .accessibilityIdentifier("sources.row.\(source.slug).cancel")
                        } else {
                            Button {
                                scanAndIngest(slug: source.slug, includeCode: source.includeCode)
                            } label: {
                                Label("Scan & Ingest", systemImage: "square.and.arrow.down.on.square")
                            }
                            .controlSize(.small)
                            .disabled(notReady || jobRunning)
                            .help("Count what the source holds, then index what is new or changed.")
                            .accessibilityIdentifier("sources.row.\(source.slug).scanIngest")
                        }

                        sourceMenu(for: source, access: access, isRemoving: isRemoving)
                    }
                    .fixedSize()
                }

                HStack(spacing: 6) {
                    Text(row.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Text(source.kind)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                // Every row carries a bar (full and green when up to date), so the rows line up.
                if row.isIndeterminate {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                } else {
                    ProgressView(value: row.progress ?? 0)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .tint(row.statusTone == .active ? .blue : row.statusTone.color)
                }

                HStack(spacing: 8) {
                    Text(row.status)
                        .font(.caption)
                        .foregroundStyle(row.statusTone.color)
                        .accessibilityIdentifier("sources.row.\(source.slug).status")
                    Spacer()
                    if let counts = row.counts {
                        Text(counts)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                if let item = row.currentItem {
                    Text(item)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if let error = row.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("sources.row.\(source.slug).error")
                }
            }
        }
        .padding(.vertical, 6)
    }

    /// Everything else a source can do, behind one button: the rarer ingests, facts, reconciling,
    /// editing, and removing.
    private func sourceMenu(for source: RegisteredSource, access: SourcePathAccessResult?, isRemoving: Bool) -> some View {
        Menu {
            // Scan is the magnifying glass, ingest the Import glyph, and the two together the stacked
            // Import glyph, here and on the buttons.
            Button {
                scanSource(slug: source.slug, includeCode: source.includeCode)
            } label: {
                Label("Scan Only", systemImage: "magnifyingglass")
            }
            .disabled(notReady || jobRunning)

            Button {
                ingestSource(slug: source.slug, includeCode: true)
            } label: {
                Label("Ingest Including Code", systemImage: "square.and.arrow.down")
            }
            .disabled(notReady || jobRunning)

            Button {
                ingestSource(slug: source.slug, includeCode: source.includeCode, force: true)
            } label: {
                Label("Re-index Everything", systemImage: "arrow.counterclockwise")
            }
            .disabled(notReady || jobRunning)

            Button {
                enrichFacts(source: source.slug)
            } label: {
                Label("Glean Facts", systemImage: "sparkles")
            }
            .disabled(notReady || appState.enrichFacts.isRunning)

            Divider()

            Button {
                run { try await $0.reconcile(source: source.slug, apply: false).message }
            } label: {
                Label("Check for Deleted Files", systemImage: "doc.questionmark")
            }
            .disabled(notReady || appState.isBusy(source: source.slug))

            Button(role: .destructive) {
                run { try await $0.reconcile(source: source.slug, apply: true).message }
            } label: {
                Label("Forget Deleted Files", systemImage: "trash")
            }
            .disabled(notReady || appState.isBusy(source: source.slug))

            Divider()

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([source.expandedRootURL])
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }

            Button {
                populateForm(from: source)
            } label: {
                Label("Edit…", systemImage: "pencil")
            }

            if let access, !access.isAccessible {
                Divider()
                Button {
                    _ = appState.promptAndSelectSourceDirectory(slug: source.slug, suggestedPath: source.root)
                } label: {
                    Label("Grant Folder Access…", systemImage: "lock.open")
                }
                if let category = access.tccCategory {
                    Button {
                        appState.openPrivacySettings(for: category)
                    } label: {
                        Label("Open Privacy Settings…", systemImage: "gear")
                    }
                }
            }

            Divider()

            // Allowed while the source is queued, scanned or ingested: removing cancels that first.
            Button(role: .destructive) {
                removeSource(slug: source.slug)
            } label: {
                Label("Remove Source", systemImage: "minus.circle")
            }
            .disabled(notReady || isRemoving)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Source actions")
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 24)
    }

    // MARK: - Add a source

    private var trimmedSlug: String {
        slug.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedRoot: String {
        root.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The form names a source that is already registered, so submitting updates it.
    private var formEditsExistingSource: Bool {
        appState.registeredSources.contains { $0.slug == trimmedSlug }
    }

    private var registeredSlugs: Set<String> {
        Set(appState.registeredSources.map(\.slug))
    }

    /// Two to four cards a row, as the setup assistant lays them out.
    private let templateColumns = [GridItem(.adaptive(minimum: 200, maximum: 320), spacing: 10, alignment: .top)]

    /// The setup assistant's data page, for a running app: the common locations as cards that add
    /// with one click, a folder chooser that also grants access, and the custom form behind a button.
    private var addSourceSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if !templates.isEmpty {
                    LazyVGrid(columns: templateColumns, alignment: .leading, spacing: 10) {
                        ForEach(templates) { template in
                            templateCard(template)
                        }
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        chooseFoldersToAdd()
                    } label: {
                        Label("Add Folder…", systemImage: "folder.badge.plus")
                    }
                    .disabled(notReady)
                    .help("Choose any folder. Choosing it here also grants Garage permission to read it.")
                    .accessibilityIdentifier("sources.addFolder")

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showCustomForm.toggle() }
                    } label: {
                        Label(showCustomForm ? "Hide Custom Source" : "Custom Source…", systemImage: "slider.horizontal.3")
                    }
                    .help("A source of another kind (a git repository, a Messages database, mailboxes, a feed), or one with its own class and trust.")
                    .accessibilityIdentifier("sources.form.show")

                    Spacer()
                    if busy || addingTemplateID != nil { ProgressView().controlSize(.small) }
                }

                if let addFolderError {
                    Text(addFolderError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if showCustomForm {
                    Divider()
                    customSourceForm
                }
            }
            .padding(8)
        } label: {
            Text("Add a Source")
        }
    }

    private func templateCard(_ template: FirstRunSourceTemplate) -> some View {
        let registered = registeredSlugs.contains(template.slug)
        let isAdding = addingTemplateID == template.id
        let isCode = !template.isCommunication && template.corpusClass == "code"

        return Button {
            addTemplate(template)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                MenuBarSymbolCircle(
                    symbol: template.symbol,
                    tint: SourceRowPresentation.tint(forCorpusClass: template.corpusClass),
                    isActive: template.isAvailable && !registered
                )
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(template.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                        if isAdding {
                            ProgressView().controlSize(.small)
                        } else if registered {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else if template.isAvailable {
                            Image(systemName: "plus.circle")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.subheadline)
                    .frame(height: 18)
                    // A LazyVGrid sizes each card to its content rather than stretching it to the row,
                    // so every line has a fixed height whatever it shows: the title row is 18 points
                    // with or without its trailing icon or spinner, the badge row is there on every
                    // card, badges or not, and the subtitle always takes two lines. Badges get their
                    // own row so a three-column title never hyphenates.
                    HStack(spacing: 4) {
                        if template.isCommunication {
                            StatusBadge("PRIVATE", tint: .purple)
                        } else if isCode {
                            StatusBadge("CODE", tint: .indigo)
                        }
                        if registered {
                            StatusBadge("ADDED", tint: .green)
                        } else if template.needsFullDiskAccess {
                            StatusBadge("NEEDS FULL DISK ACCESS", tint: .orange)
                        } else if !template.isAvailable {
                            StatusBadge("NOT FOUND", tint: .secondary)
                        }
                    }
                    .fixedSize()
                    .frame(height: 16, alignment: .leading)
                    Text(template.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2, reservesSpace: true)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(template.root)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(FirstRunStyle.cardBackground(selected: false))
            .opacity(template.isAvailable ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: FirstRunStyle.cardCorner))
        }
        .buttonStyle(.plain)
        .disabled(!template.isAvailable || registered || notReady || addingTemplateID != nil)
        .help(registered
            ? "Already one of your sources."
            : template.needsFullDiskAccess
                ? "Turn on Full Disk Access for Garage in System Settings → Privacy & Security, then quit and reopen Garage."
                : "Add \(template.title) as a source.")
        .accessibilityLabel(registered ? "\(template.title), added" : "Add \(template.title)")
        .accessibilityIdentifier("sources.template.\(template.id)")
    }

    private var customSourceForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(formEditsExistingSource ? "Editing \(trimmedSlug)" : "Custom source")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("Start from a preset")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Menu("Choose preset…") {
                    ForEach(SourcePreset.all) { preset in
                        Button(preset.title) {
                            applyPreset(preset)
                        }
                    }
                }
                .controlSize(.small)
                .fixedSize()
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Folder")
                        .gridColumnAlignment(.trailing)
                    HStack(spacing: 8) {
                        TextField("~/Notes", text: $root)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("sources.form.root")
                        Button("Choose…") { chooseRoot() }
                    }
                }
                GridRow {
                    Text("Name")
                    HStack(spacing: 8) {
                        TextField("notes", text: $slug)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 260)
                            .help("How the CLI, MCP tools and this page refer to the source. Filled in from the folder until you change it.")
                            .accessibilityIdentifier("sources.form.slug")
                        if !suggestedSlug.isEmpty, trimmedSlug == suggestedSlug {
                            Text("from the folder")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                GridRow {
                    Text("Contents")
                    HStack(spacing: 12) {
                        Picker("Kind", selection: $kind) {
                            ForEach(kinds, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Picker("Class", selection: $corpusClass) {
                            ForEach(classes, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Picker("Trust", selection: $trust) {
                            ForEach(trusts, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Text(contentsHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            HStack(spacing: 8) {
                Button(formEditsExistingSource ? "Update Source" : "Add Source") {
                    addOrUpdateSource()
                }
                .buttonStyle(.borderedProminent)
                .disabled(trimmedSlug.isEmpty || trimmedRoot.isEmpty || notReady || formSourceIsBusy)
                .accessibilityIdentifier("sources.form.submit")

                Button("Remove Source", role: .destructive) {
                    removeSource(slug: slug)
                }
                .disabled(trimmedSlug.isEmpty || !formEditsExistingSource || notReady || formSourceIsBeingRemoved)
                .accessibilityIdentifier("sources.form.remove")

                Button("Clear") {
                    clearForm()
                }
                .disabled(slug.isEmpty && root.isEmpty)
            }
        }
    }

    /// One line on what the three pickers mean, in the order they appear.
    private var contentsHint: String {
        let what: String
        switch kind {
        case "git": what = "a git repository"
        case "sqlite": what = "a SQLite database (Messages)"
        case "maildir": what = "mailboxes"
        case "feed": what = "a feed"
        default: what = "files in a folder"
        }
        let who: String
        switch trust {
        case "authored": who = "you wrote"
        case "reference": who = "you keep for reference"
        default: who = "you received"
        }
        let privacy = corpusClass == "communication" ? ", never sent off this Mac" : ""
        return "\(what), indexed as \(corpusClass) \(who)\(privacy)."
    }

    /// Fills in the name from the folder and kind unless the person typed one.
    private func suggestSlugIfUnedited() {
        guard trimmedSlug.isEmpty || trimmedSlug == suggestedSlug else { return }
        let suggestion = SourceSlugSuggestion.suggest(root: root, kind: kind, taken: registeredSlugs)
        slug = suggestion
        suggestedSlug = suggestion
    }

    private func addTemplate(_ template: FirstRunSourceTemplate) {
        guard addingTemplateID == nil else { return }
        addingTemplateID = template.id
        addFolderError = nil
        Task {
            await appState.addSource(template.spec)
            await appState.fetchRegisteredSources()
            await appState.fetchCorpusStats()
            _ = appState.testVolumeAccess()
            addingTemplateID = nil
        }
    }

    /// The setup assistant's "Add custom folder…": each chosen folder becomes a document source
    /// named after it, and the panel's grant is kept so the sandboxed app can read it later.
    private func chooseFoldersToAdd() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder for Garage to index"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        addFolderError = nil
        busy = true
        Task {
            var taken = registeredSlugs
            var problems: [String] = []
            for url in urls {
                do {
                    try appState.volumeAccess.grantSourceAccess(for: url, forSourcePath: url.path)
                } catch {
                    problems.append("Could not keep access to \(url.lastPathComponent): \(error.localizedDescription)")
                }
                let name = SourceSlugSuggestion.suggest(root: url.path, kind: "filesystem", taken: taken)
                taken.insert(name)
                let spec = SourceSpec(slug: name, root: url.path, kind: "filesystem", corpusClass: "document", trust: "authored")
                let added = await appState.addSource(spec)
                if !added {
                    problems.append("\(url.lastPathComponent): \(appState.lastCommandOutput.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
            }
            await appState.fetchRegisteredSources()
            await appState.fetchCorpusStats()
            _ = appState.testVolumeAccess()
            addFolderError = problems.isEmpty ? nil : problems.joined(separator: "\n")
            busy = false
        }
    }

    // MARK: - Ingest output

    /// The log of every ingest, folded away: it is for looking into a failure, not for glancing at.
    @ViewBuilder
    private var ingestOutputSection: some View {
        let combinedLogs = appState.combinedIngestLogs
        if !combinedLogs.isEmpty {
            GroupBox {
                if showIngestOutput {
                    LogTableView(
                        lines: combinedLogs,
                        sourceName: "Ingest",
                        onClear: {
                            appState.clearLogs(for: "Ingest")
                        }
                    )
                    .frame(minHeight: 200, maxHeight: 350)
                }
            } label: {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showIngestOutput.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        DisclosureChevron(isExpanded: showIngestOutput)
                        Text("Ingest Output")
                        Text("\(combinedLogs.count.formatted()) \(SourceRowPresentation.plural("line", combinedLogs.count))")
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sources.ingestOutput.toggle")
            }
        }
    }

    // MARK: - Helpers

    /// Postgres is down, or one of this page's quick operations (add, remove, sync, …) is in flight.
    /// A scan or ingest does not count: it runs on its own runner, and only what would conflict with
    /// it (`jobRunning`, `AppState.isBusy(source:)`) waits for it.
    private var notReady: Bool {
        appState.postgres.status != .running || busy
    }

    /// Only one scan and one ingest run at a time, so starting another waits for them.
    /// A queued source counts: a Scan & Ingest of one source keeps it queued between its scan and ingest.
    private var jobRunning: Bool {
        appState.isIngesting || appState.isIngestingAll || appState.isScanning || !appState.ingestQueue.isEmpty
    }

    /// The form's source is being scanned or ingested, so it cannot be updated yet. It can be removed:
    /// that cancels the scan or ingest first.
    private var formSourceIsBusy: Bool {
        appState.isBusy(source: trimmedSlug)
    }

    private var formSourceIsBeingRemoved: Bool {
        appState.sourcesBeingRemoved.contains(trimmedSlug)
    }

    /// The form's Choose…: the panel's grant is kept, as "Add Folder…" keeps its own, so the sandboxed
    /// app can still read a folder outside the home grant after a relaunch.
    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            root = url.path
            do {
                try appState.volumeAccess.grantSourceAccess(for: url, forSourcePath: url.path)
            } catch {
                addFolderError = "Could not keep access to \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    /// A preset's slug is the one every page agrees on, so it is kept even if the folder changes
    /// (a fixture standing in for Messages stays "apple-sms").
    private func applyPreset(_ preset: SourcePreset) {
        suggestedSlug = ""
        slug = preset.spec.slug
        root = preset.spec.root
        kind = preset.spec.kind
        corpusClass = preset.spec.corpusClass
        trust = preset.spec.trust
    }

    private func populateForm(from source: RegisteredSource) {
        suggestedSlug = ""
        slug = source.slug
        root = source.root
        kind = source.kind
        corpusClass = source.corpusClass
        trust = source.trust
        withAnimation(.easeInOut(duration: 0.2)) { showCustomForm = true }
    }

    private func clearForm() {
        suggestedSlug = ""
        slug = ""
        root = ""
        kind = "filesystem"
        corpusClass = "document"
        trust = "authored"
    }

    private func refreshSourcesAndTestDisk() {
        Task {
            await appState.fetchRegisteredSources()
            await appState.fetchCorpusStats()
            _ = appState.testVolumeAccess()
        }
    }

    private func scanSource(slug: String, includeCode: Bool = false) {
        guard !jobRunning else { return }
        Task {
            await appState.scanSources(source: slug, includeCode: includeCode)
        }
    }

    /// Scans first so the expected-element counts are current, then ingests; a failed or
    /// cancelled scan stops there.
    /// Leaves `busy` alone: the scan and the ingest show their own progress and disable only what
    /// would conflict with them, so the rest of the page stays usable while they run.
    private func scanAndIngest(slug: String, includeCode: Bool = false) {
        guard !jobRunning else { return }
        Task {
            let options = IngestOptions(includeCode: includeCode)
            if slug != "*" {
                _ = await appState.scanAndIngestSource(slug: slug, options: options)
            } else if await appState.scanSources(source: slug, includeCode: includeCode, followedByIngest: true) {
                _ = await appState.ingestSource(slug: slug, options: options)
            }
        }
    }

    /// Import adds only the sources the config file lacks, then sync applies the file (declared
    /// sources win), so the two end up listing the same sources without either discarding one.
    private func syncSources() {
        run { grpc in
            let imported = try await grpc.importSourcesToConfig().message
            let synced = try await grpc.syncSources().message
            return [imported, synced].filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }

    private func ingestSource(slug: String, includeCode: Bool = false, force: Bool = false) {
        guard !jobRunning else { return }
        Task {
            let options = IngestOptions(includeCode: includeCode, force: force)
            _ = await appState.ingestSource(slug: slug, options: options)
        }
    }

    private func addOrUpdateSource() {
        busy = true
        let spec = SourceSpec(
            slug: trimmedSlug,
            root: trimmedRoot,
            kind: kind,
            corpusClass: corpusClass,
            trust: trust
        )
        Task {
            await appState.addSource(spec)
            await appState.fetchRegisteredSources()
            await appState.fetchCorpusStats()
            _ = appState.testVolumeAccess()
            busy = false
        }
    }

    /// Leaves `busy` alone: waiting for a cancelled scan or ingest to stop can take a while, and only
    /// this source's row needs to show it (REMOVING).
    private func removeSource(slug toRemove: String) {
        let trimmed = toRemove.trimmingCharacters(in: .whitespacesAndNewlines)
        removeError = nil
        Task {
            let removed = await appState.removeSource(slug: trimmed)
            if !removed {
                let reason = appState.lastCommandOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                removeError = "Could not remove \(trimmed)" + (reason.isEmpty ? "." : ": \(reason)")
            }
            await appState.fetchRegisteredSources()
            await appState.fetchCorpusStats()
            _ = appState.testVolumeAccess()
        }
    }

    private func run(_ operation: @escaping @MainActor (GarageGRPCService) async throws -> String) {
        busy = true
        Task {
            await appState.runOperation(operation)
            await appState.fetchRegisteredSources()
            _ = appState.testVolumeAccess()
            busy = false
        }
    }

    private func enrichFacts(source: String) {
        Task {
            await appState.runEnrichFacts(source: source)
        }
    }
}

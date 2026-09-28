import SwiftUI
import AppKit

public struct SearchView: View {
    @EnvironmentObject var appState: AppState

    @State private var query = ""
    @State private var model = ""
    @State private var mode = "hybrid"
    @State private var limit = 10
    @State private var selectedCorpusClass = "all"
    @State private var selectedTrustTier = "all"
    @State private var selectedSource = "all"
    @State private var showAdvancedFilters = false

    @State private var results: [SearchResultItem] = []
    @State private var selectedResultID: String?
    @State private var sortOrder = [KeyPathComparator(\SearchResultItem.rank)]
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var hasSearched = false
    @State private var lastSearchLatencyMs: Double?
    @State private var lastSearchedQuery = ""

    private let modes = [
        ("hybrid", "Hybrid"),
        ("vector", "Vector"),
        ("fts", "Full-Text (FTS)")
    ]

    private let corpusClasses = CorpusTaxonomy.withAllSentinel(CorpusTaxonomy.corpusClasses)
    private let trustTiers = CorpusTaxonomy.withAllSentinel(CorpusTaxonomy.trustTiers)

    public init() {}

    private var sortedResults: [SearchResultItem] {
        results.sorted(using: sortOrder)
    }

    private var selectedResult: SearchResultItem? {
        guard let selectedResultID else { return nil }
        return results.first { $0.id == selectedResultID }
    }

    public var body: some View {
        VStack(spacing: 0) {
            searchControlsHeader
            Divider()

            if showAdvancedFilters {
                advancedFiltersBar
                Divider()
            }

            mainContentArea

            Divider()
            statusBarFooter
        }
        .navigationTitle("Search")
        .onAppear(perform: runPendingMenuBarQuery)
        .onReceive(NotificationCenter.default.publisher(for: .garageShowSection)) { notification in
            guard notification.object as? AppSection == .search else { return }
            runPendingMenuBarQuery()
        }
    }

    /// Runs the query typed into the menu bar's search field, when "See all results" brought the
    /// user here.
    private func runPendingMenuBarQuery() {
        guard let pending = MenuBarNavigation.takePendingSearchQuery() else { return }
        query = pending
        runSearch()
    }

    // MARK: - Search Controls Header

    private var searchControlsHeader: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search corpus (e.g., 'system architecture', 'API design')…", text: $query)
                        .accessibilityIdentifier("search.query")
                        .textFieldStyle(.plain)
                        .onSubmit { runSearch() }
                    if !query.isEmpty {
                        Button(action: { query = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("Clear search")
                        .buttonStyle(.plain)
                    }
                }
                .padding(7)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2), lineWidth: 1))

                Picker("Mode", selection: $mode) {
                    ForEach(modes, id: \.0) { m in
                        Text(m.1).tag(m.0)
                    }
                }
                .frame(width: 130)

                Menu {
                    Button("Default Model") { model = "" }
                    Divider()
                    ForEach(appState.presetModels) { preset in
                        Button(preset.slug) { model = preset.slug }
                    }
                    if !appState.registeredModels.isEmpty {
                        Divider()
                        ForEach(appState.registeredModels) { reg in
                            Button(reg.slug) { model = reg.slug }
                        }
                    }
                } label: {
                    Text(model.isEmpty ? "Model: Default" : "Model: \(model)")
                        .lineLimit(1)
                }
                .frame(width: 140)

                Stepper("Limit: \(limit)", value: $limit, in: 1...100)
                    .frame(width: 110)

                Button(action: { showAdvancedFilters.toggle() }) {
                    Image(systemName: showAdvancedFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("Advanced filters")
                .help("Toggle Advanced Filters")

                Button(action: { runSearch() }) {
                    if isSearching {
                        ProgressView().controlSize(.small)
                            .frame(width: 48)
                    } else {
                        Text("Search")
                            .frame(width: 48)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching || appState.postgres.status != .running)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Advanced Filters Bar

    private var advancedFiltersBar: some View {
        HStack(spacing: 16) {
            Picker("Class:", selection: $selectedCorpusClass) {
                ForEach(corpusClasses, id: \.self) { c in
                    Text(c.capitalized).tag(c)
                }
            }
            .frame(maxWidth: 160)

            Picker("Trust:", selection: $selectedTrustTier) {
                ForEach(trustTiers, id: \.self) { t in
                    Text(t.capitalized).tag(t)
                }
            }
            .frame(maxWidth: 160)

            Picker("Source:", selection: $selectedSource) {
                Text("All Sources").tag("all")
                ForEach(appState.registeredSources) { src in
                    Text(src.slug).tag(src.slug)
                }
            }
            .frame(maxWidth: 200)

            Spacer()

            if selectedCorpusClass != "all" || selectedTrustTier != "all" || selectedSource != "all" {
                Button("Reset Filters") {
                    selectedCorpusClass = "all"
                    selectedTrustTier = "all"
                    selectedSource = "all"
                }
                .controlSize(.small)
            }
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.02))
    }

    // MARK: - Main Content Area

    @ViewBuilder
    private var mainContentArea: some View {
        if isSearching && results.isEmpty {
            VStack(spacing: 12) {
                Spacer()
                ProgressView("Searching…")
                    .controlSize(.regular)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.orange)
                Text("Search Failed")
                    .font(.headline)
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .accessibilityIdentifier("search.error")
                Button("Retry") { runSearch() }
                    .controlSize(.small)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.isEmpty {
            if hasSearched {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No Results Found")
                        .font(.headline)
                    Text("No documents matched '\(lastSearchedQuery)'. Try adjusting the search terms, mode, or filters.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 400)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("Search Knowledge Base")
                        .font(.title3.bold())
                    Text("Enter a search query to retrieve relevant document chunks using hybrid semantic and keyword search.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 450)
                    if appState.postgres.status != .running {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.circle")
                            Text("Database is offline. Start the database to perform searches.")
                        }
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.top, 8)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            resultsSplitView
        }
    }

    // MARK: - Table & Detail Split View

    private var resultsSplitView: some View {
        HSplitView {
            resultsTableView
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)

            if let item = selectedResult {
                // Rebuilt for each hit: kept across hits, the inspector's selectable text went on
                // reporting the first hit to accessibility after another was clicked, and its scroll
                // position carried over.
                resultDetailInspector(for: item)
                    .id(item.id)
                    .frame(minWidth: 280, idealWidth: 360, maxWidth: 500, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Results Table View

    private var resultsTableView: some View {
        Table(sortedResults, selection: $selectedResultID, sortOrder: $sortOrder) {
            TableColumn("Rank", value: \.rank) { item in
                Text("#\(item.rank)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 40, ideal: 50, max: 60)

            TableColumn("Score", value: \.score) { item in
                Text(String(format: "%.3f", item.score))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.blue)
            }
            .width(min: 50, ideal: 60, max: 75)

            TableColumn("Document", value: \.displayTitle) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayTitle)
                        .font(.system(.body, weight: .medium))
                        .lineLimit(1)
                        .accessibilityIdentifier("search.result.\(item.rank).title")
                    if !item.headingPath.isEmpty {
                        Text(item.headingPath)
                            .font(.system(.caption2))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if !item.uri.isEmpty {
                        Text(item.uri)
                            .font(.system(.caption2))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .width(min: 150, ideal: 220)

            TableColumn("Class", value: \.corpusClass) { item in
                CorpusClassBadge(corpusClass: item.corpusClass)
            }
            .width(min: 75, ideal: 90, max: 110)

            TableColumn("Trust", value: \.trustTier) { item in
                TrustTierBadge(tier: item.trustTier)
            }
            .width(min: 75, ideal: 85, max: 100)

            TableColumn("Matched By", value: \.matchedBy) { item in
                Text(item.matchedBy)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(min: 75, ideal: 85, max: 100)

            TableColumn("Snippet", value: \.snippet) { item in
                Text(item.snippet)
                    .font(.system(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .width(min: 200, ideal: 350)
        }
        .contextMenu(forSelectionType: String.self) { selectedIDs in
            if let firstID = selectedIDs.first, let item = results.first(where: { $0.id == firstID }) {
                Button("Copy Title") {
                    NSPasteboard.general.copy(item.displayTitle)
                }
                Button("Copy URI") {
                    NSPasteboard.general.copy(item.uri)
                }
                Button("Copy Snippet") {
                    NSPasteboard.general.copy(item.snippet)
                }
                Button("Copy Text") {
                    NSPasteboard.general.copy(item.text)
                }
                Divider()
                if let url = URL(string: item.uri), url.isFileURL {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }
        }
    }

    // MARK: - Detail Inspector View

    private func resultDetailInspector(for item: SearchResultItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.displayTitle)
                            .font(.headline)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("search.detail.title")
                        HStack(spacing: 6) {
                            Text("Rank #\(item.rank)")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            Text("•")
                                .foregroundStyle(.secondary)
                            Text("Score: \(String(format: "%.4f", item.score))")
                                .font(.caption.bold())
                                .foregroundStyle(.blue)
                        }
                    }
                    Spacer()
                    Button(action: { selectedResultID = nil }) {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close result details")
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    CorpusClassBadge(corpusClass: item.corpusClass)
                    TrustTierBadge(tier: item.trustTier)
                    TagBadge("Matched: \(item.matchedBy)")
                }

                if !item.headingPath.isEmpty {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Heading")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(item.headingPath)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                }

                if !item.authorsList.isEmpty {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Authors")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(item.authorsList)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                }

                if !item.uri.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("URI")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            Text(item.uri)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button("Copy") {
                                NSPasteboard.general.copy(item.uri)
                            }
                            .controlSize(.mini)
                            if let url = URL(string: item.uri), url.isFileURL {
                                Button("Reveal") {
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                }
                                .controlSize(.mini)
                            }
                        }
                    }
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.02))

            Divider()

            // Content Tabs / Scrollable Text
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !item.snippet.isEmpty && item.snippet != item.text {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Snippet Preview")
                                    .font(.caption.bold())
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Copy") { NSPasteboard.general.copy(item.snippet) }
                                    .controlSize(.mini)
                            }
                            Text(item.snippet)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.primary.opacity(0.04))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Full Content")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Copy All") { NSPasteboard.general.copy(item.text) }
                                .controlSize(.mini)
                        }
                        Text(item.text.isEmpty ? item.snippet : item.text)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .accessibilityIdentifier("search.detail.text")
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
                .padding(12)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Status Bar Footer

    private var statusBarFooter: some View {
        HStack {
            if isSearching {
                ProgressView().controlSize(.small)
                Text("Searching…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if hasSearched {
                Text("\(results.count) results for '\(lastSearchedQuery)'")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("search.status")
                if let latency = lastSearchLatencyMs {
                    Text("•")
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.1f ms", latency))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Ready")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if selectedResult != nil {
                Text("1 item selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.02))
    }

    // MARK: - Search Execution

    private func runSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isSearching = true
        errorMessage = nil
        let startTime = CFAbsoluteTimeGetCurrent()

        let corpusClassesFilter = selectedCorpusClass == "all" ? [] : [selectedCorpusClass]
        let trustTiersFilter = selectedTrustTier == "all" ? [] : [selectedTrustTier]
        let sourcesFilter = selectedSource == "all" ? [] : [selectedSource]

        Task {
            do {
                let hits = try await appState.search(
                    query: trimmed,
                    mode: mode,
                    model: model.isEmpty ? nil : model,
                    limit: limit,
                    corpusClasses: corpusClassesFilter,
                    trustTiers: trustTiersFilter,
                    sources: sourcesFilter,
                    full: true
                )
                let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
                await MainActor.run {
                    self.results = hits
                    self.hasSearched = true
                    self.lastSearchedQuery = trimmed
                    self.lastSearchLatencyMs = elapsedMs
                    self.isSearching = false
                    self.selectedResultID = nil
                    // Open the first hit once the table has taken the new rows. Selected in this same
                    // update, the table dropped it as a row it did not have yet, so only the first
                    // search of a visit opened its hit in the inspector.
                    if let first = hits.first {
                        DispatchQueue.main.async {
                            guard self.selectedResultID == nil, self.results.first?.id == first.id else { return }
                            self.selectedResultID = first.id
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isSearching = false
                    self.hasSearched = true
                    self.lastSearchedQuery = trimmed
                }
            }
        }
    }
}

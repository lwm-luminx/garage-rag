import SwiftUI
import AppKit

/// Browses the facts `enrich-facts` distilled out of every document: search them,
/// filter by source, class and corpus class, and read each one in the passage it
/// was grounded to. "Distill Facts" (`garage cluster-facts`) groups the facts that
/// restate one claim; "Group Restatements" then lists each claim once.
public struct FactsView: View {
    @EnvironmentObject var appState: AppState

    /// Shows a fact's document on the Documents page.
    private let openDocument: (DocumentFocus) -> Void
    /// Centers the Graph page on a fact.
    private let openGraph: (GraphFocus) -> Void

    @State private var facts: [FactListItem] = []
    @State private var totalCount = 0
    @State private var classes: [FactClassCount] = []
    @State private var selectedFactID: Int64?

    @State private var searchText = ""
    @State private var selectedSource = CorpusTaxonomy.allSentinel
    @State private var selectedFactClass = CorpusTaxonomy.allSentinel
    @State private var selectedCorpusClass = CorpusTaxonomy.allSentinel
    /// Narrows the list to one document's facts, from "Facts from This Document".
    @State private var documentFilter: (id: Int64, title: String)?
    /// Lists the facts that restate one claim once, as the claim's representative.
    @State private var groupRestatements = false
    /// Narrows the list to the restatements of one claim, from "Show All Statements".
    @State private var distilledFilter: (id: Int64, statement: String)?

    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var hasLoaded = false
    /// Counts refreshes; a response is applied only if no newer refresh started
    /// after its request, so a slow answer for old filters never lands.
    @State private var generation = 0

    private static let pageSize = 200
    private let corpusClasses = CorpusTaxonomy.withAllSentinel(CorpusTaxonomy.corpusClasses)

    public init(
        openDocument: @escaping (DocumentFocus) -> Void = { _ in },
        openGraph: @escaping (GraphFocus) -> Void = { _ in }
    ) {
        self.openDocument = openDocument
        self.openGraph = openGraph
    }

    public var body: some View {
        VStack(spacing: 0) {
            filterHeader
            if let documentFilter {
                documentFilterBar(documentFilter.title)
            }
            if let distilledFilter {
                distilledFilterBar(distilledFilter.statement)
            }
            Divider()
            mainContentArea
        }
        .navigationTitle("Facts")
        .onAppear {
            if !hasLoaded {
                hasLoaded = true
                refreshFacts()
            }
        }
    }

    private var selectedFact: FactListItem? {
        guard let selectedFactID else { return nil }
        return facts.first { $0.id == selectedFactID }
    }

    // MARK: - Filter Header

    private var filterHeader: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search facts…", text: $searchText)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("facts.search")
                    .onSubmit { refreshFacts() }
                if !searchText.isEmpty {
                    Button(action: { searchText = ""; refreshFacts() }) {
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

            Picker("Source", selection: $selectedSource) {
                Text("All Sources").tag(CorpusTaxonomy.allSentinel)
                ForEach(appState.registeredSources) { src in
                    Text(src.slug).tag(src.slug)
                }
            }
            .frame(width: 160)
            .onChange(of: selectedSource) { _, _ in refreshFacts() }
            .accessibilityIdentifier("facts.source")

            Picker("Kind", selection: $selectedFactClass) {
                Text("All Kinds").tag(CorpusTaxonomy.allSentinel)
                ForEach(classOptions) { option in
                    Text("\(option.factClass.capitalized) (\(option.count))").tag(option.factClass)
                }
            }
            .frame(width: 170)
            .onChange(of: selectedFactClass) { _, _ in refreshFacts() }
            .accessibilityIdentifier("facts.kind")

            Picker("Class", selection: $selectedCorpusClass) {
                ForEach(corpusClasses, id: \.self) { c in
                    Text(c.capitalized).tag(c)
                }
            }
            .frame(width: 130)
            .onChange(of: selectedCorpusClass) { _, _ in refreshFacts() }
            .accessibilityIdentifier("facts.class")

            Toggle("Group Restatements", isOn: $groupRestatements)
                .toggleStyle(.checkbox)
                .onChange(of: groupRestatements) { _, _ in refreshFacts() }
                .accessibilityIdentifier("facts.group")
                .help("List facts that state the same claim once")

            Button(action: { distillFacts() }) {
                if appState.enrichFacts.isRunning {
                    ProgressView().controlSize(.small)
                        .frame(width: 20)
                } else {
                    Image(systemName: "wand.and.stars")
                        .frame(width: 20)
                }
            }
            .accessibilityLabel("Distill facts")
            .accessibilityIdentifier("facts.distill")
            .disabled(appState.enrichFacts.isRunning || appState.postgres.status != .running)
            .help("Group the facts that restate one claim, and have the local model state each claim once")
            .contextMenu {
                Button("Regroup All Facts") { distillFacts(full: true) }
                    .disabled(appState.enrichFacts.isRunning || appState.postgres.status != .running)
            }

            Button(action: refreshFacts) {
                if isLoading {
                    ProgressView().controlSize(.small)
                        .frame(width: 20)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 20)
                }
            }
            .accessibilityLabel("Refresh facts")
            .accessibilityIdentifier("facts.refresh")
            .disabled(isLoading || appState.postgres.status != .running)
            .help("Refresh facts")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// The classes the current search finds, plus the selected one when it finds
    /// none of it, so the picker never loses its selection.
    private var classOptions: [FactClassCount] {
        if selectedFactClass == CorpusTaxonomy.allSentinel || classes.contains(where: { $0.factClass == selectedFactClass }) {
            return classes
        }
        return classes + [FactClassCount(factClass: selectedFactClass, count: 0)]
    }

    private func documentFilterBar(_ title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
            Text("Facts from \(title)")
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                documentFilter = nil
                refreshFacts()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show facts from every document")
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func distilledFilterBar(_ statement: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "square.stack.3d.up")
                .foregroundStyle(.secondary)
            Text("Statements of “\(statement)”")
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
            Button {
                distilledFilter = nil
                refreshFacts()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show every fact")
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Main Content Area

    @ViewBuilder
    private var mainContentArea: some View {
        if isLoading && facts.isEmpty {
            VStack(spacing: 12) {
                Spacer()
                ProgressView("Loading facts…")
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.orange)
                Text("Failed to Load Facts")
                    .font(.headline)
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Button("Retry") { refreshFacts() }
                    .controlSize(.small)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if facts.isEmpty {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "lightbulb")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("No Facts Found")
                    .font(.title3.bold())
                Text(emptyMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 450)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProportionalSplitView(initialFraction: 0.4, minLeadingWidth: 280, minTrailingWidth: 340) {
                factListView
                    .frame(maxHeight: .infinity)
            } trailing: {
                factDetailView
                    .frame(maxHeight: .infinity)
            }
        }
    }

    private var emptyMessage: String {
        if appState.postgres.status != .running {
            return "Database is offline. Start the database to browse facts."
        }
        if isFiltered {
            return "No facts matched the current search and filters."
        }
        return "Nothing has been gleaned yet. Choose Glean Facts on a document, or on the Models page's Distillation tab."
    }

    private var isFiltered: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || selectedSource != CorpusTaxonomy.allSentinel
            || selectedFactClass != CorpusTaxonomy.allSentinel
            || selectedCorpusClass != CorpusTaxonomy.allSentinel
            || documentFilter != nil
            || distilledFilter != nil
    }

    // MARK: - Fact List (Left)

    private var factListView: some View {
        VStack(spacing: 0) {
            List(selection: $selectedFactID) {
                ForEach(facts) { fact in
                    factRow(fact)
                        .tag(fact.id)
                }
                if facts.count < totalCount {
                    HStack {
                        Spacer()
                        Button(action: loadMore) {
                            if isLoadingMore {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Load More")
                            }
                        }
                        .controlSize(.small)
                        .disabled(isLoadingMore)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.inset)

            Divider()
            HStack {
                Text("\(facts.count) of \(totalCount) fact\(totalCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("facts.count")
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.02))
        }
    }

    private func factRow(_ fact: FactListItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(fact.fact)
                .font(.callout)
                .lineLimit(3)
                .accessibilityIdentifier("facts.row.fact")

            HStack(spacing: 6) {
                StatusBadge(fact.factClass.capitalized, tint: .orange)
                CorpusClassBadge(corpusClass: fact.corpusClass)
                if fact.hasRestatements {
                    StatusBadge("×\(fact.distilledSize)", tint: .purple, symbol: "square.stack.3d.up")
                        .help("Stated \(fact.distilledSize) times")
                        .accessibilityIdentifier("facts.row.restatements")
                }
                if fact.restatesWithinDocument {
                    StatusBadge("Repeated", tint: .gray, symbol: "arrow.turn.up.left")
                        .help("Restates another fact of the same document")
                        .accessibilityIdentifier("facts.row.repeated")
                }
                Text(fact.documentDisplayTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Fact Detail (Right)

    @ViewBuilder
    private var factDetailView: some View {
        if let fact = selectedFact {
            factDetailContent(fact)
        } else {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "lightbulb")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text("Select a fact to see where it came from")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private func factDetailContent(_ fact: FactListItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        StatusBadge(fact.factClass.capitalized, tint: .orange, symbol: "lightbulb.fill")
                        CorpusClassBadge(corpusClass: fact.corpusClass)
                        TagBadge(fact.sourceSlug)
                        Spacer()
                        Button("Copy") { NSPasteboard.general.copy(fact.fact) }
                            .controlSize(.small)
                    }
                    Text(fact.fact)
                        .font(.title3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("facts.detail.fact")
                }

                Divider()

                if fact.hasRestatements {
                    distilledSection(fact)
                }

                sourceSection(fact)

                if let grounded = fact.groundedExcerpt {
                    groundingSection(grounded, fact: fact)
                }

                let attributes = fact.attributes
                if !attributes.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        sectionTitle("Attributes")
                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                            ForEach(attributes) { attribute in
                                GridRow {
                                    Text(attribute.key)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                    Text(attribute.value)
                                        .font(.caption)
                                        .textSelection(.enabled)
                                        .accessibilityIdentifier("facts.detail.attribute.\(attribute.key)")
                                }
                            }
                        }
                    }
                }

                HStack(spacing: 12) {
                    if !fact.extractor.isEmpty { metaField("Extractor", fact.extractor) }
                    if !fact.extractorModel.isEmpty { metaField("Model", fact.extractorModel) }
                    if let created = Self.formattedDate(fact.createdAt) { metaField("Distilled", created) }
                    Spacer()
                }
            }
            .padding(14)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func sourceSection(_ fact: FactListItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("From")
            Text(fact.documentDisplayTitle)
                .font(.headline)
                .textSelection(.enabled)
                .accessibilityIdentifier("facts.detail.document")
            Text(fact.documentURI)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 6) {
                Button("Open Document") {
                    openDocument(DocumentFocus(id: fact.documentID, uri: fact.documentURI))
                }
                Button("Facts from This Document") {
                    documentFilter = (fact.documentID, fact.documentDisplayTitle)
                    refreshFacts()
                }
                .disabled(documentFilter?.id == fact.documentID)
                if let url = URL(string: fact.documentURI), url.isFileURL {
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Button("Show in Graph") {
                    openGraph(GraphFocus(label: "PotentialFact", key: fact.id))
                }
                .accessibilityIdentifier("facts.detail.graph")
                .help("Center the Graph page on this fact: its document, and the claim it supports")
            }
            .controlSize(.small)
        }
    }

    private func distilledSection(_ fact: FactListItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Stated \(fact.distilledSize) Times")
            Text(fact.distilledStatement)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("facts.detail.distilled")
                .padding(10)
                .background(Color.purple.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            if fact.distilledGenerated {
                Text("Written by the local model from the statements below; not a quotation.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let agreement = fact.agreementPercent {
                Text("The statements agree \(agreement)% (how close their meanings are).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("facts.detail.agreement")
            }
            if let id = fact.distilledFactID {
                Button("Show All Statements") {
                    distilledFilter = (id, fact.distilledStatement)
                    refreshFacts()
                }
                .controlSize(.small)
                .disabled(distilledFilter?.id == id)
            }
        }
    }

    private func groundingSection(_ grounded: (before: String, span: String, after: String), fact: FactListItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Grounded In")
            Text(Self.groundedText(grounded, fact: fact))
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("facts.detail.grounded")
                .padding(10)
                .background(Color.orange.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    /// Characters of the document the server sends either side of a span
    /// (`EXCERPT_CONTEXT` in garage_rag.ops.facts).
    private static let excerptContext = 200

    /// The excerpt with the span in bold and its context dimmed, marked with an
    /// ellipsis where it was cut out of a longer document.
    static func groundedText(_ grounded: (before: String, span: String, after: String), fact: FactListItem) -> AttributedString {
        var before = AttributedString((fact.excerptStart > 0 ? "…" : "") + grounded.before)
        before.foregroundColor = .secondary
        var span = AttributedString(grounded.span)
        span.inlinePresentationIntent = .stronglyEmphasized
        let cut = grounded.after.unicodeScalars.count >= excerptContext
        var after = AttributedString(grounded.after + (cut ? "…" : ""))
        after.foregroundColor = .secondary
        return before + span + after
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.bold())
            .foregroundStyle(.secondary)
    }

    private func metaField(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
        }
    }

    private static func formattedDate(_ iso: String) -> String? {
        guard !iso.isEmpty else { return nil }
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = precise.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return iso }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: - Data Loading

    private func distillFacts(full: Bool = false) {
        Task {
            await appState.runClusterFacts(full: full)
            refreshFacts()
        }
    }

    private func refreshFacts() {
        // Every refresh supersedes whatever is in flight, a Load More included.
        generation += 1
        let request = generation
        guard appState.postgres.status == .running else {
            facts = []
            totalCount = 0
            classes = []
            isLoading = false
            isLoadingMore = false
            return
        }
        isLoading = true
        isLoadingMore = false
        errorMessage = nil

        Task {
            do {
                let page = try await fetch(offset: 0)
                await MainActor.run {
                    guard request == self.generation else { return }
                    self.facts = page.items
                    self.totalCount = page.totalCount
                    self.classes = page.classes
                    self.isLoading = false
                    if let selectedFactID, !page.items.contains(where: { $0.id == selectedFactID }) {
                        self.selectedFactID = nil
                    }
                }
            } catch {
                await MainActor.run {
                    guard request == self.generation else { return }
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    private func loadMore() {
        let request = generation
        isLoadingMore = true
        Task {
            do {
                let page = try await fetch(offset: facts.count)
                await MainActor.run {
                    guard request == self.generation else { return }
                    let known = Set(self.facts.map(\.id))
                    self.facts += page.items.filter { !known.contains($0.id) }
                    self.totalCount = page.totalCount
                    self.isLoadingMore = false
                }
            } catch {
                await MainActor.run {
                    guard request == self.generation else { return }
                    self.errorMessage = error.localizedDescription
                    self.isLoadingMore = false
                }
            }
        }
    }

    private func fetch(offset: Int) async throws -> FactListPage {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await appState.listFacts(
            query: query.isEmpty ? nil : query,
            source: selectedSource == CorpusTaxonomy.allSentinel ? nil : selectedSource,
            factClass: selectedFactClass == CorpusTaxonomy.allSentinel ? nil : selectedFactClass,
            corpusClass: selectedCorpusClass == CorpusTaxonomy.allSentinel ? nil : selectedCorpusClass,
            documentID: documentFilter?.id,
            limit: Self.pageSize,
            offset: offset,
            collapse: groupRestatements && distilledFilter == nil,
            distilledFactID: distilledFilter?.id
        )
    }
}

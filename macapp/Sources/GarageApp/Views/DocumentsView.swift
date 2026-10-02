import SwiftUI
import AppKit

/// A document another page asks the Documents page to open.
public struct DocumentFocus: Equatable, Sendable {
    public let id: Int64
    public let uri: String

    public init(id: Int64, uri: String) {
        self.id = id
        self.uri = uri
    }
}

public struct DocumentsView: View {
    @EnvironmentObject var appState: AppState
    /// Consumed on appear: the list is filtered down to this document and it is selected.
    @Binding private var focus: DocumentFocus?

    @State private var documents: [DocumentListItem] = []
    @State private var totalCount = 0
    @State private var selectedDocumentID: Int64?
    @State private var selectedDetail: DocumentDetailItem?

    @State private var searchText = ""
    @State private var selectedSource = "all"
    @State private var selectedCorpusClass = "all"
    @State private var selectedTrustTier = "all"

    @State private var isLoadingList = false
    @State private var isLoadingDetail = false
    @State private var listErrorMessage: String?
    @State private var detailErrorMessage: String?
    @State private var hasLoaded = false
    @State private var isGleaningFacts = false
    /// Text by default; Linked lists what the graph links to the document; Chunks only when turned on.
    @State private var detailMode: DocumentDetailMode = .text
    /// Chunks are how text is cut up for embedding, an implementation detail: an advanced option.
    @AppStorage(DocumentsPresentation.showChunksKey) private var showChunks = false
    @State private var links: GraphNeighborhood?
    @State private var linksDocumentID: Int64?
    @State private var isLoadingLinks = false
    @State private var linksErrorMessage: String?
    /// Keeps the arrow keys on the document list once a document is chosen. Without it the sidebar
    /// kept keyboard focus, so Down moved to the next page instead of the next document.
    @FocusState private var isListFocused: Bool

    private let corpusClasses = CorpusTaxonomy.withAllSentinel(CorpusTaxonomy.corpusClasses)
    private let trustTiers = CorpusTaxonomy.withAllSentinel(CorpusTaxonomy.trustTiers)

    /// Centers the Graph page on a document.
    private let openGraph: (GraphFocus) -> Void

    public init(focus: Binding<DocumentFocus?> = .constant(nil), openGraph: @escaping (GraphFocus) -> Void = { _ in }) {
        self._focus = focus
        self.openGraph = openGraph
    }

    public var body: some View {
        VStack(spacing: 0) {
            filterHeader
            Divider()
            mainContentArea
        }
        .navigationTitle("Documents")
        .onAppear {
            if let focus {
                show(focus)
            } else if !hasLoaded {
                hasLoaded = true
                refreshDocuments()
            }
        }
        .onChange(of: focus) { _, newValue in
            if let newValue { show(newValue) }
        }
    }

    /// Filters the list by the document's URI, which finds it however far down
    /// the unfiltered list it sits, and selects it.
    private func show(_ target: DocumentFocus) {
        focus = nil
        hasLoaded = true
        searchText = target.uri
        selectedSource = "all"
        selectedCorpusClass = "all"
        selectedTrustTier = "all"
        selectedDocumentID = target.id
        loadDetail(documentID: target.id)
        refreshDocuments()
    }

    // MARK: - Filter Header

    private var filterHeader: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter by title or URI…", text: $searchText)
                    .textFieldStyle(.plain)
                    .onSubmit { refreshDocuments() }
                    .accessibilityIdentifier("documents.filter")
                if !searchText.isEmpty {
                    Button(action: { searchText = ""; refreshDocuments() }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Clear search")
                    .accessibilityIdentifier("documents.filter.clear")
                    .buttonStyle(.plain)
                }
            }
            .padding(7)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2), lineWidth: 1))

            Picker("Source", selection: $selectedSource) {
                Text("All Sources").tag("all")
                ForEach(appState.registeredSources) { src in
                    Text(src.slug).tag(src.slug)
                }
            }
            .frame(width: 160)
            .onChange(of: selectedSource) { _, _ in refreshDocuments() }

            Picker("Class", selection: $selectedCorpusClass) {
                ForEach(corpusClasses, id: \.self) { c in
                    Text(c.capitalized).tag(c)
                }
            }
            .frame(width: 130)
            .onChange(of: selectedCorpusClass) { _, _ in refreshDocuments() }
            .accessibilityIdentifier("documents.class")

            Picker("Trust", selection: $selectedTrustTier) {
                ForEach(trustTiers, id: \.self) { t in
                    Text(t.capitalized).tag(t)
                }
            }
            .frame(width: 130)
            .onChange(of: selectedTrustTier) { _, _ in refreshDocuments() }
            .accessibilityIdentifier("documents.trust")

            Button(action: refreshDocuments) {
                if isLoadingList {
                    ProgressView().controlSize(.small)
                        .frame(width: 20)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 20)
                }
            }
            .accessibilityLabel("Refresh document list")
            .accessibilityIdentifier("documents.refresh")
            .disabled(isLoadingList || appState.postgres.status != .running)
            .help("Refresh document list")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Main Content Area

    @ViewBuilder
    private var mainContentArea: some View {
        if isLoadingList && documents.isEmpty {
            VStack(spacing: 12) {
                Spacer()
                ProgressView("Loading documents…")
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let listErrorMessage {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.orange)
                Text("Failed to Load Documents")
                    .font(.headline)
                Text(listErrorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Button("Retry") { refreshDocuments() }
                    .controlSize(.small)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if documents.isEmpty {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("No Documents Found")
                    .font(.title3.bold())
                Text(appState.postgres.status != .running
                     ? "Database is offline. Start the database to browse documents."
                     : "No documents matched the current filters, or nothing has been ingested yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 450)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            documentsSplitView
        }
    }

    // MARK: - Split View

    private var documentsSplitView: some View {
        // A third for the listing, two thirds for the document, held as the
        // window is resized.
        ProportionalSplitView(initialFraction: 1.0 / 3.0, minLeadingWidth: 260, minTrailingWidth: 340) {
            documentListView
                .frame(maxHeight: .infinity)
        } trailing: {
            documentDetailView
                .frame(maxHeight: .infinity)
        }
    }

    // MARK: - Document List (Left)

    private var documentListView: some View {
        VStack(spacing: 0) {
            List(documents, selection: $selectedDocumentID) { doc in
                documentRow(doc)
                    .tag(doc.id)
            }
            .listStyle(.inset)
            .focused($isListFocused)
            .onChange(of: selectedDocumentID) { _, newValue in
                if let newValue {
                    isListFocused = true
                    loadDetail(documentID: newValue)
                }
            }

            Divider()
            HStack {
                Text("\(documents.count) of \(totalCount) document\(totalCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("documents.count")
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.02))
        }
    }

    private func documentRow(_ doc: DocumentListItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(doc.displayTitle)
                .font(.system(.body, weight: .medium))
                .lineLimit(1)

            Text(doc.uri)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 6) {
                CorpusClassBadge(corpusClass: doc.corpusClass)
                TrustTierBadge(tier: doc.trustTier)
                TagBadge(doc.sourceSlug)
                Spacer()
                if doc.factCount > 0 {
                    Text("\(doc.factCount) fact\(doc.factCount == 1 ? "" : "s")")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Text(DocumentsPresentation.when(doc.occurredAt))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .help("When it happened: a thread's last message, a mail's date, else the file's modification time")
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Document Detail (Right)

    @ViewBuilder
    private var documentDetailView: some View {
        if isLoadingDetail && selectedDetail == nil {
            VStack {
                Spacer()
                ProgressView("Loading document…")
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        } else if let detailErrorMessage {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Failed to Load Document")
                    .font(.headline)
                Text(detailErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        } else if let detail = selectedDetail {
            documentDetailContent(detail)
                // A new identity per document: reused, the selectable title kept the previous
                // document's accessibility value, so UI tests read a stale title.
                .id(detail.id)
        } else {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "doc.text")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text(DocumentsPresentation.emptyDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private func documentDetailContent(_ detail: DocumentDetailItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(detail.displayTitle)
                    .font(.headline)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("documents.detail.title")

                HStack(spacing: 6) {
                    CorpusClassBadge(corpusClass: detail.corpusClass)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("documents.detail.class")
                    TrustTierBadge(tier: detail.trustTier)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("documents.detail.trust")
                    TagBadge(detail.sourceSlug)
                    if !detail.state.isEmpty {
                        StatusBadge(detail.state.uppercased(), tint: detail.state == "ok" ? .green : .red)
                    }
                }

                HStack(spacing: 4) {
                    Text(detail.uri)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Copy URI") { NSPasteboard.general.copy(detail.uri) }
                        .controlSize(.mini)
                    if let url = URL(string: detail.uri), url.isFileURL {
                        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            .controlSize(.mini)
                    }
                }

                HStack(spacing: 12) {
                    metaField("Date", DocumentsPresentation.when(detail.occurredAt))
                    metaField("Size", detail.formattedByteSize)
                    if !detail.lang.isEmpty { metaField("Lang", detail.lang) }
                    if !detail.mime.isEmpty { metaField("MIME", detail.mime) }
                    if !detail.facts.isEmpty { metaField("Facts", "\(detail.facts.count)") }
                    if showChunks {
                        if !detail.chunker.isEmpty { metaField("Chunker", detail.chunker) }
                        metaField("Chunks", "\(detail.chunks.count)", identifier: "documents.detail.chunkCount")
                    }
                    Spacer()
                    Button("Show in Graph") {
                        openGraph(GraphFocus(label: "Document", key: detail.id))
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("documents.detail.graph")
                    .help("Center the Graph page on this document: its messages, authors, links and facts")
                    Button {
                        glean(detail)
                    } label: {
                        if isGleaningFacts {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(detail.facts.isEmpty ? "Glean Facts" : "Re-glean Facts")
                        }
                    }
                    .controlSize(.small)
                    .disabled(isGleaningFacts || appState.postgres.status != .running)
                }

                if !detail.authors.isEmpty {
                    Text("Authors: " + detail.authors.map { $0.name }.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !detail.error.isEmpty {
                    Text("Error: \(detail.error)")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.02))

            Divider()

            HStack(spacing: 8) {
                Picker("View", selection: $detailMode) {
                    ForEach(DocumentDetailMode.available(showChunks: showChunks)) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("documents.detail.mode")
                Spacer()
                Toggle("Show Chunks", isOn: $showChunks)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("Advanced: how the text was cut into chunks for embedding")
                    .accessibilityIdentifier("documents.detail.showChunks")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .onChange(of: showChunks) { _, on in
                if !on, detailMode == .chunks { detailMode = .text }
            }
            .onChange(of: detailMode) { _, mode in
                if mode == .linked { loadLinks(documentID: detail.id) }
            }

            Divider()

            switch detailMode {
            case .text: textView(detail)
            case .linked: linkedView(detail)
            case .chunks: chunksView(detail)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Text

    private func textView(_ detail: DocumentDetailItem) -> some View {
        let shown = DocumentsPresentation.displayText(
            content: detail.content, hasContent: detail.hasContent, chunks: detail.chunks.map(\.text)
        )
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if !detail.facts.isEmpty {
                    Text("Facts")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    ForEach(detail.facts) { fact in
                        factCard(fact)
                    }
                    Divider()
                        .padding(.vertical, 4)
                }
                HStack {
                    Text("Text")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy Text") {
                        NSPasteboard.general.copy(detail.hasContent ? detail.content : detail.chunks.map(\.text).joined(separator: "\n\n"))
                    }
                    .controlSize(.mini)
                }
                if !detail.hasContent {
                    Text(DocumentsPresentation.noContent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(shown.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("documents.text")
                if shown.total > shown.text.count {
                    Text(DocumentsPresentation.truncatedNote(shown: shown.text.count, total: shown.total))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
        }
    }

    // MARK: - Linked

    @ViewBuilder
    private func linkedView(_ detail: DocumentDetailItem) -> some View {
        if isLoadingLinks && links == nil {
            VStack { Spacer(); ProgressView("Loading links…"); Spacer() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let linksErrorMessage {
            VStack(spacing: 8) {
                Spacer()
                Text(linksErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
                Button("Retry") { loadLinks(documentID: detail.id, force: true) }
                    .controlSize(.small)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let links {
            let groups = DocumentsPresentation.linkedGroups(links)
            if groups.isEmpty {
                VStack {
                    Spacer()
                    Text(DocumentsPresentation.linkedEmpty(available: links.available))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("documents.linked.empty")
            } else {
                List {
                    ForEach(["read", "derived"], id: \.self) { origin in
                        let shown = groups.filter { $0.origin == origin }
                        if !shown.isEmpty {
                            Section(DocumentsPresentation.originHeading(origin)) {
                                ForEach(shown) { group in
                                    linkedGroup(group)
                                }
                            }
                        }
                    }
                    if links.truncated {
                        Text("More is linked than is listed here; Show in Graph walks the rest.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .listStyle(.inset)
                .accessibilityIdentifier("documents.linked")
            }
        }
    }

    @ViewBuilder
    private func linkedGroup(_ group: LinkedGroup) -> some View {
        let style = GraphLabelStyle.vertex(group.label)
        DisclosureGroup {
            ForEach(group.rows) { row in
                linkedRow(row, style: style)
            }
        } label: {
            Label("\(style.name) (\(group.rows.count))", systemImage: style.symbol ?? "circle")
                .foregroundStyle(style.tint)
                .font(.callout.bold())
        }
        .accessibilityIdentifier("documents.linked.\(group.label)")
    }

    private func linkedRow(_ row: LinkedRow, style: GraphLabelStyle) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.vertex.title)
                    .font(.callout)
                    .lineLimit(3)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    if !row.relations.isEmpty {
                        Text(row.relations.joined(separator: " · "))
                    }
                    if let at = row.vertex.occurredAt {
                        Text(DocumentsPresentation.when(at))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if let href = row.vertex.href, let url = URL(string: href), url.scheme != nil {
                Button("Open") { NSWorkspace.shared.open(url) }
                    .controlSize(.mini)
            }
            if let key = row.vertex.key {
                Button("Show in Graph") { openGraph(GraphFocus(label: row.vertex.label, key: key)) }
                    .controlSize(.mini)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Chunks (advanced)

    private func chunksView(_ detail: DocumentDetailItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(detail.chunks) { chunk in
                    chunkCard(chunk)
                }
            }
            .padding(12)
        }
    }

    private func metaField(_ label: String, _ value: String, identifier: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let identifier {
                Text(value)
                    .font(.caption)
                    .accessibilityIdentifier(identifier)
            } else {
                Text(value)
                    .font(.caption)
            }
        }
    }

    private func factCard(_ fact: DocumentFactItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "lightbulb.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                Text(fact.factClass.capitalized)
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
                Spacer()
                if !fact.extractor.isEmpty {
                    Text(fact.extractor)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Button("Copy") { NSPasteboard.general.copy(fact.fact) }
                    .controlSize(.mini)
            }
            Text(fact.fact)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func chunkCard(_ chunk: DocumentChunkItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("#\(chunk.ord)")
                    .font(.caption.bold())
                    .foregroundStyle(.blue)
                if !chunk.headingPath.isEmpty {
                    Text(chunk.headingPath)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if chunk.tokenCount > 0 {
                    Text("\(chunk.tokenCount) tok")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Button("Copy") { NSPasteboard.general.copy(chunk.text) }
                    .controlSize(.mini)
            }
            Text(chunk.text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("documents.chunk.\(chunk.ord)")
        }
        .padding(8)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Data Loading

    private func refreshDocuments() {
        guard appState.postgres.status == .running else {
            documents = []
            totalCount = 0
            return
        }
        isLoadingList = true
        listErrorMessage = nil
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            do {
                let result = try await appState.listDocuments(
                    source: selectedSource == "all" ? nil : selectedSource,
                    corpusClass: selectedCorpusClass == "all" ? nil : selectedCorpusClass,
                    trustTier: selectedTrustTier == "all" ? nil : selectedTrustTier,
                    query: trimmedQuery.isEmpty ? nil : trimmedQuery
                )
                await MainActor.run {
                    self.documents = result.items
                    self.totalCount = result.totalCount
                    self.isLoadingList = false
                    if let selectedDocumentID, !result.items.contains(where: { $0.id == selectedDocumentID }) {
                        self.selectedDocumentID = nil
                        self.selectedDetail = nil
                    }
                }
            } catch {
                await MainActor.run {
                    self.listErrorMessage = error.localizedDescription
                    self.isLoadingList = false
                }
            }
        }
    }

    /// Loads what the graph links to the document, once per document unless `force`.
    private func loadLinks(documentID: Int64, force: Bool = false) {
        guard force || linksDocumentID != documentID || links == nil else { return }
        linksDocumentID = documentID
        isLoadingLinks = true
        linksErrorMessage = nil
        Task {
            do {
                let loaded = try await appState.documentLinks(documentID: documentID)
                await MainActor.run {
                    guard self.linksDocumentID == documentID else { return }
                    self.links = loaded
                    self.isLoadingLinks = false
                }
            } catch {
                await MainActor.run {
                    guard self.linksDocumentID == documentID else { return }
                    self.linksErrorMessage = error.localizedDescription
                    self.isLoadingLinks = false
                }
            }
        }
    }

    private func loadDetail(documentID: Int64) {
        isLoadingDetail = true
        detailErrorMessage = nil
        links = nil
        linksDocumentID = nil
        linksErrorMessage = nil
        if detailMode == .linked {
            loadLinks(documentID: documentID)
        }
        Task {
            do {
                let detail = try await appState.getDocument(documentID: documentID)
                await MainActor.run {
                    self.selectedDetail = detail
                    self.isLoadingDetail = false
                }
            } catch {
                await MainActor.run {
                    self.detailErrorMessage = error.localizedDescription
                    self.isLoadingDetail = false
                }
            }
        }
    }

    private func glean(_ detail: DocumentDetailItem) {
        isGleaningFacts = true
        Task {
            await appState.runEnrichFacts(documentID: detail.id)
            if selectedDocumentID == detail.id {
                let refreshed = try? await appState.getDocument(documentID: detail.id)
                await MainActor.run {
                    if let refreshed { self.selectedDetail = refreshed }
                    self.isGleaningFacts = false
                }
            } else {
                await MainActor.run { self.isGleaningFacts = false }
            }
        }
    }
}

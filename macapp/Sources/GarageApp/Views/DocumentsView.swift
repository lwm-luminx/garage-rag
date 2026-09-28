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

    private let corpusClasses = CorpusTaxonomy.withAllSentinel(CorpusTaxonomy.corpusClasses)
    private let trustTiers = CorpusTaxonomy.withAllSentinel(CorpusTaxonomy.trustTiers)

    public init(focus: Binding<DocumentFocus?> = .constant(nil)) {
        self._focus = focus
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
            .onChange(of: selectedDocumentID) { _, newValue in
                if let newValue {
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
                Text("\(doc.chunkCount) chunk\(doc.chunkCount == 1 ? "" : "s")")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
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
        } else {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "doc.text")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text("Select a document to view its chunks")
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
                    TrustTierBadge(tier: detail.trustTier)
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
                    metaField("Size", detail.formattedByteSize)
                    if !detail.lang.isEmpty { metaField("Lang", detail.lang) }
                    if !detail.mime.isEmpty { metaField("MIME", detail.mime) }
                    if !detail.chunker.isEmpty { metaField("Chunker", detail.chunker) }
                    metaField("Chunks", "\(detail.chunks.count)", identifier: "documents.detail.chunkCount")
                    if !detail.facts.isEmpty { metaField("Facts", "\(detail.facts.count)") }
                    Spacer()
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

            ScrollView {
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

                        Text("Chunks")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                    }

                    ForEach(detail.chunks) { chunk in
                        chunkCard(chunk)
                    }
                }
                .padding(12)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
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

    private func loadDetail(documentID: Int64) {
        isLoadingDetail = true
        detailErrorMessage = nil
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

import SwiftUI
import AppKit

/// Browses the `garage` graph Apache AGE holds: pick a document, author, fact or statement, and
/// see what it is connected to, a few hops out, with each kind of vertex and edge switchable.
///
/// The picture is a radial layout (`GraphLayout`): the chosen vertex in the middle, one ring per
/// hop. Click a vertex to inspect it, double-click to make it the center. The vertex and edge
/// filters come from the graph itself (`GetGraphLabels`), so a label added later shows up here.
public struct GraphView: View {
    @EnvironmentObject var appState: AppState

    /// Consumed on appear: the page centers on this vertex.
    @Binding private var focus: GraphFocus?
    /// Shows a vertex's document on the Documents page.
    private let openDocument: (DocumentFocus) -> Void

    /// The graph's labels; nil until the first load answers.
    @State private var labels: GraphLabels?
    @State private var enabledVertexLabels: Set<String> = []
    @State private var enabledEdgeLabels: Set<String> = []

    @State private var searchText = ""
    @State private var searchLabel = CorpusTaxonomy.allSentinel
    @State private var results: [GraphVertexItem] = []
    @State private var hasSearched = false
    @State private var isSearching = false

    /// The graph id of the vertex in the middle; nil before one is chosen.
    @State private var centerID: Int64?
    @State private var neighborhood: GraphNeighborhood?
    @State private var depth = GraphPagePresentation.defaultDepth
    @State private var selectedVertexID: Int64?
    @State private var hoveredVertexID: Int64?

    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var hasLoaded = false
    /// Counts loads; an answer lands only if no newer load started after its request.
    @State private var generation = 0

    private static let vertexLimit = 150
    private static let maxDepth = 4

    public init(focus: Binding<GraphFocus?> = .constant(nil), openDocument: @escaping (DocumentFocus) -> Void = { _ in }) {
        self._focus = focus
        self.openDocument = openDocument
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            if let labels, labels.available {
                filterBar(labels)
            }
            Divider()
            content
        }
        .navigationTitle(GraphPagePresentation.title)
        .onAppear {
            if !hasLoaded {
                hasLoaded = true
                loadLabels()
            }
            if let focus {
                show(focus)
            }
        }
        .onChange(of: focus) { _, newValue in
            if let newValue { show(newValue) }
        }
        .onChange(of: appState.postgres.status) { _, status in
            if status == .running, labels == nil || labels?.available == false {
                loadLabels()
            }
        }
    }

    private var databaseRunning: Bool { appState.postgres.status == .running }

    private var selectedVertex: GraphVertexItem? {
        guard let neighborhood else { return nil }
        if let selectedVertexID, let vertex = neighborhood.vertex(selectedVertexID) {
            return vertex
        }
        return neighborhood.center
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(GraphPagePresentation.searchPlaceholder, text: $searchText)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("graph.search")
                    .onSubmit { search() }
                if !searchText.isEmpty {
                    Button(action: { searchText = ""; results = []; hasSearched = false }) {
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

            Picker("Kind", selection: $searchLabel) {
                Text("Any Kind").tag(CorpusTaxonomy.allSentinel)
                ForEach(labels?.vertexLabels ?? []) { option in
                    Text(GraphLabelStyle.vertex(option.label).name).tag(option.label)
                }
            }
            .frame(width: 150)
            .onChange(of: searchLabel) { _, _ in
                if hasSearched { search() }
            }
            .accessibilityIdentifier("graph.kind")

            Stepper(value: $depth, in: 1...Self.maxDepth) {
                Text(depth == 1 ? "1 hop" : "\(depth) hops")
                    .font(.callout)
                    .monospacedDigit()
                    .frame(width: 48, alignment: .leading)
            }
            .onChange(of: depth) { _, _ in loadNeighborhood() }
            .accessibilityIdentifier("graph.depth")
            .help("How far out from the chosen vertex to look")

            Button(action: refresh) {
                if isLoading {
                    ProgressView().controlSize(.small)
                        .frame(width: 20)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 20)
                }
            }
            .accessibilityLabel("Refresh graph")
            .accessibilityIdentifier("graph.refresh")
            .disabled(isLoading || !databaseRunning)
            .help("Reload the graph")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func filterBar(_ labels: GraphLabels) -> some View {
        WrappingHStack(spacing: 6, lineSpacing: 6) {
            Text("Show")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(labels.vertexLabels) { option in
                labelChip(option, style: GraphLabelStyle.vertex(option.label), enabled: $enabledVertexLabels)
                    .accessibilityIdentifier("graph.vertex.\(option.label)")
            }
            Text("linked by")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
            ForEach(labels.edgeLabels) { option in
                labelChip(option, style: GraphLabelStyle.edge(option.label), enabled: $enabledEdgeLabels)
                    .accessibilityIdentifier("graph.edge.\(option.label)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    /// One filter: a tinted chip that dims when its label is off.
    private func labelChip(_ option: GraphLabelCount, style: GraphLabelStyle, enabled: Binding<Set<String>>) -> some View {
        let isOn = enabled.wrappedValue.contains(option.label)
        return Button {
            if isOn {
                enabled.wrappedValue.remove(option.label)
            } else {
                enabled.wrappedValue.insert(option.label)
            }
            loadNeighborhood()
        } label: {
            HStack(spacing: 4) {
                if let symbol = style.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 9, weight: .bold))
                } else {
                    Rectangle()
                        .frame(width: 10, height: 2)
                }
                Text(style.name)
                    .font(.system(size: 11, weight: .medium))
                Text(option.count.formatted())
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(isOn ? style.tint.opacity(0.15) : Color.secondary.opacity(0.08))
            .foregroundStyle(isOn ? style.tint : .secondary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(isOn ? "Hide \(style.name.lowercased()) " + (style.symbol == nil ? "edges" : "vertices") : "Show \(style.name.lowercased()) " + (style.symbol == nil ? "edges" : "vertices"))
        .accessibilityValue(isOn ? "on" : "off")
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let errorMessage {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.orange)
                Text("Failed to Load the Graph")
                    .font(.headline)
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Button("Retry") { refresh() }
                    .controlSize(.small)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if labels == nil, isLoading {
            VStack {
                Spacer()
                ProgressView("Loading the graph…")
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !databaseRunning || labels?.available != true {
            emptyState(GraphPagePresentation.empty(databaseRunning: databaseRunning, available: labels?.available ?? false, hasSelection: false, searched: false))
        } else {
            ProportionalSplitView(initialFraction: 0.25, minLeadingWidth: 220, minTrailingWidth: 480) {
                resultsColumn
            } trailing: {
                ProportionalSplitView(initialFraction: 0.68, minLeadingWidth: 300, minTrailingWidth: 220) {
                    picture
                } trailing: {
                    inspector
                }
            }
        }
    }

    private func emptyState(_ empty: GraphPagePresentation.Empty) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: empty.symbol)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(empty.title)
                .font(.title3.bold())
                .accessibilityIdentifier("graph.empty.title")
            Text(empty.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 450)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Results (left)

    private var resultsColumn: some View {
        VStack(spacing: 0) {
            if results.isEmpty {
                let empty = GraphPagePresentation.empty(databaseRunning: true, available: true, hasSelection: false, searched: hasSearched)
                VStack(spacing: 8) {
                    Spacer()
                    if isSearching {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: empty.symbol)
                            .font(.system(size: 24))
                            .foregroundStyle(.secondary)
                        Text(empty.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: Binding(
                    get: { centerID },
                    set: { id in if let id { center(on: id) } }
                )) {
                    ForEach(results) { vertex in
                        vertexRow(vertex)
                            .tag(vertex.id)
                    }
                }
                .listStyle(.inset)
                .accessibilityIdentifier("graph.results")
            }
            Divider()
            HStack {
                Text(results.isEmpty ? "No matches" : "\(results.count) \(results.count == 1 ? "match" : "matches")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("graph.results.count")
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.02))
        }
    }

    private func vertexRow(_ vertex: GraphVertexItem) -> some View {
        let style = GraphLabelStyle.vertex(vertex.label)
        return VStack(alignment: .leading, spacing: 3) {
            Text(vertex.title)
                .font(.callout)
                .lineLimit(2)
            HStack(spacing: 6) {
                StatusBadge(style.name, tint: style.tint, symbol: style.symbol)
                if let key = vertex.key {
                    Text("#\(key)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: - Picture (middle)

    @ViewBuilder
    private var picture: some View {
        if let neighborhood, neighborhood.center != nil {
            VStack(spacing: 0) {
                GeometryReader { geometry in
                    let layout = GraphLayout(neighborhood: neighborhood, size: geometry.size)
                    let nodeRadius = Self.nodeRadius(for: neighborhood.vertices.count)
                    GraphCanvas(
                        neighborhood: neighborhood,
                        layout: layout,
                        nodeRadius: nodeRadius,
                        selectedID: selectedVertexID,
                        hoveredID: hoveredVertexID
                    )
                    .contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture(count: 2)
                            .onEnded { tap in
                                if let id = layout.vertex(at: tap.location, radius: nodeRadius + 6) {
                                    center(on: id)
                                }
                            }
                            .exclusively(before: SpatialTapGesture()
                                .onEnded { tap in
                                    selectedVertexID = layout.vertex(at: tap.location, radius: nodeRadius + 6) ?? selectedVertexID
                                })
                    )
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            hoveredVertexID = layout.vertex(at: location, radius: nodeRadius + 6)
                        case .ended:
                            hoveredVertexID = nil
                        }
                    }
                }
                .background(Color(nsColor: .textBackgroundColor))
                .accessibilityIdentifier("graph.canvas")
                .accessibilityLabel("Graph of \(neighborhood.center?.title ?? "")")
                .overlay(alignment: .center) {
                    if isLoading {
                        ProgressView().controlSize(.small)
                            .padding(8)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                Divider()
                HStack {
                    Text(GraphPagePresentation.summary(
                        vertices: neighborhood.vertices.count,
                        edges: neighborhood.edges.count,
                        depth: depth,
                        truncated: neighborhood.truncated
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("graph.summary")
                    Spacer()
                    Text("Click a vertex to inspect it, double-click to center on it")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.02))
            }
        } else if isLoading {
            VStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            emptyState(GraphPagePresentation.empty(databaseRunning: true, available: true, hasSelection: centerID != nil, searched: false))
        }
    }

    /// Smaller circles as the picture fills up.
    static func nodeRadius(for vertexCount: Int) -> CGFloat {
        switch vertexCount {
        case ..<25: 11
        case ..<60: 8
        default: 5.5
        }
    }

    // MARK: - Inspector (right)

    @ViewBuilder
    private var inspector: some View {
        if let vertex = selectedVertex, let neighborhood {
            inspectorContent(vertex, in: neighborhood)
        } else {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "sidebar.right")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text("Select a vertex to see its properties and connections")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private func inspectorContent(_ vertex: GraphVertexItem, in neighborhood: GraphNeighborhood) -> some View {
        let style = GraphLabelStyle.vertex(vertex.label)
        let connections = neighborhood.connections(of: vertex.id)
        let grouped = Dictionary(grouping: connections) { $0.edge.label }
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        StatusBadge(style.name, tint: style.tint, symbol: style.symbol)
                        if let key = vertex.key {
                            TagBadge("#\(key)")
                        }
                        if vertex.id == neighborhood.center?.id {
                            StatusBadge("Center", tint: .accentColor, symbol: "scope")
                        }
                        Spacer()
                        Button("Copy") { NSPasteboard.general.copy(vertex.title) }
                            .controlSize(.small)
                    }
                    Text(vertex.title)
                        .font(.title3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("graph.detail.title")
                }

                HStack(spacing: 6) {
                    if vertex.id != neighborhood.center?.id {
                        Button("Center Here") { center(on: vertex.id) }
                            .accessibilityIdentifier("graph.detail.center")
                    }
                    if let documentID = vertex.documentID {
                        Button(vertex.label == "Document" ? "Open Document" : "Open Its Document") {
                            openDocument(DocumentFocus(id: documentID, uri: vertex.documentURI))
                        }
                        .accessibilityIdentifier("graph.detail.openDocument")
                    }
                }
                .controlSize(.small)

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    sectionTitle(connections.isEmpty ? "No Connections Shown" : "Connections")
                    ForEach(grouped.keys.sorted(), id: \.self) { edgeLabel in
                        let edgeStyle = GraphLabelStyle.edge(edgeLabel)
                        let members = grouped[edgeLabel] ?? []
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 4) {
                                Rectangle()
                                    .fill(edgeStyle.tint)
                                    .frame(width: 10, height: 2)
                                Text("\(edgeStyle.name) · \(members.count)")
                                    .font(.caption.bold())
                                    .foregroundStyle(edgeStyle.tint)
                            }
                            ForEach(members.sorted { $0.other.title < $1.other.title }) { connection in
                                connectionRow(connection.edge, other: connection.other, from: vertex)
                            }
                        }
                    }
                }

                let properties = vertex.properties
                if !properties.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        sectionTitle("Properties")
                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                            ForEach(properties) { property in
                                GridRow {
                                    Text(property.key)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                    Text(property.value)
                                        .font(.caption)
                                        .textSelection(.enabled)
                                        .lineLimit(4)
                                        .accessibilityIdentifier("graph.detail.property.\(property.key)")
                                }
                            }
                        }
                    }
                }
            }
            .padding(14)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func connectionRow(_ edge: GraphEdgeItem, other: GraphVertexItem, from vertex: GraphVertexItem) -> some View {
        let style = GraphLabelStyle.vertex(other.label)
        let outgoing = edge.sourceID == vertex.id
        return Button {
            selectedVertexID = other.id
        } label: {
            HStack(spacing: 5) {
                Image(systemName: outgoing ? "arrow.right" : "arrow.left")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                if let symbol = style.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 10))
                        .foregroundStyle(style.tint)
                }
                Text(other.title)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(outgoing ? "→" : "←") \(GraphLabelStyle.edge(edge.label).name): \(other.title)")
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.bold())
            .foregroundStyle(.secondary)
    }

    // MARK: - Data Loading

    /// Centers on the vertex another page asked for, once the labels are known.
    private func show(_ target: GraphFocus) {
        focus = nil
        centerID = nil
        selectedVertexID = nil
        depth = GraphPagePresentation.startingDepth(for: target.label)
        loadNeighborhood(focus: target)
    }

    private func refresh() {
        loadLabels()
        loadNeighborhood()
        if hasSearched { search() }
    }

    private func loadLabels() {
        guard databaseRunning else {
            labels = nil
            return
        }
        isLoading = true
        errorMessage = nil
        Task {
            do {
                let loaded = try await appState.graphLabels()
                await MainActor.run {
                    // A label new to the page starts switched on; switches the user set stay as set.
                    let knownVertices = Set(labels?.vertexLabels.map(\.label) ?? [])
                    let knownEdges = Set(labels?.edgeLabels.map(\.label) ?? [])
                    for option in loaded.vertexLabels where !knownVertices.contains(option.label) {
                        enabledVertexLabels.insert(option.label)
                    }
                    for option in loaded.edgeLabels where !knownEdges.contains(option.label) {
                        enabledEdgeLabels.insert(option.label)
                    }
                    labels = loaded
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    private func search() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard databaseRunning else { return }
        hasSearched = true
        isSearching = true
        Task {
            do {
                let found = try await appState.findGraphVertices(
                    query: query,
                    label: searchLabel == CorpusTaxonomy.allSentinel ? nil : searchLabel,
                    limit: 50
                )
                await MainActor.run {
                    results = found
                    isSearching = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSearching = false
                }
            }
        }
    }

    private func center(on id: Int64) {
        centerID = id
        selectedVertexID = id
        loadNeighborhood()
    }

    /// The labels to ask for: nil when every label is on, so a label the page has not seen yet
    /// (a fresh rebuild adding one) still comes through.
    private func requested(_ enabled: Set<String>, of options: [GraphLabelCount]) -> [String]? {
        let all = Set(options.map(\.label))
        return all.isSubset(of: enabled) ? nil : enabled.intersection(all).sorted()
    }

    private func loadNeighborhood(focus target: GraphFocus? = nil) {
        guard databaseRunning, target != nil || centerID != nil else { return }
        generation += 1
        let request = generation
        isLoading = true
        errorMessage = nil
        let vertexLabels = requested(enabledVertexLabels, of: labels?.vertexLabels ?? [])
        let edgeLabels = requested(enabledEdgeLabels, of: labels?.edgeLabels ?? [])
        Task {
            do {
                let loaded = try await appState.graphNeighborhood(
                    vertexID: target == nil ? centerID : nil,
                    focus: target,
                    depth: depth,
                    vertexLabels: vertexLabels,
                    edgeLabels: edgeLabels,
                    limit: Self.vertexLimit
                )
                await MainActor.run {
                    guard request == self.generation else { return }
                    self.neighborhood = loaded
                    self.centerID = loaded.center?.id
                    if let selectedVertexID, loaded.vertex(selectedVertexID) == nil {
                        self.selectedVertexID = loaded.center?.id
                    } else if selectedVertexID == nil {
                        self.selectedVertexID = loaded.center?.id
                    }
                    if !loaded.available {
                        self.labels = GraphLabels(available: false)
                    }
                    self.isLoading = false
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
}

/// The drawing itself: edges as arrows, vertices as tinted circles, titles under them while the
/// picture is sparse enough to read, and always for the hovered and selected vertex.
struct GraphCanvas: View {
    let neighborhood: GraphNeighborhood
    let layout: GraphLayout
    let nodeRadius: CGFloat
    let selectedID: Int64?
    let hoveredID: Int64?

    /// Titles are drawn under every vertex up to this many; beyond it only the center, the hovered
    /// and the selected vertex are titled.
    static let titledVertexLimit = 40
    static let titleLength = 28

    var body: some View {
        Canvas { context, _ in
            let highlighted: Set<Int64> = Set([selectedID, hoveredID].compactMap { $0 })

            for edge in neighborhood.edges {
                guard let from = layout.positions[edge.sourceID], let to = layout.positions[edge.targetID] else { continue }
                let style = GraphLabelStyle.edge(edge.label)
                let touchesHighlight = highlighted.contains(edge.sourceID) || highlighted.contains(edge.targetID)
                let tint = style.tint.opacity(touchesHighlight ? 0.95 : 0.45)
                var line = Path()
                line.move(to: from)
                line.addLine(to: to)
                context.stroke(line, with: .color(tint), lineWidth: touchesHighlight ? 2 : 1.2)
                context.fill(Self.arrowhead(from: from, to: to, clearance: nodeRadius + 1), with: .color(tint))
            }

            for vertex in neighborhood.vertices {
                guard let position = layout.positions[vertex.id] else { continue }
                let style = GraphLabelStyle.vertex(vertex.label)
                let isCenter = vertex.id == neighborhood.center?.id
                let radius = isCenter ? nodeRadius * 1.35 : nodeRadius
                let rect = CGRect(x: position.x - radius, y: position.y - radius, width: 2 * radius, height: 2 * radius)
                if highlighted.contains(vertex.id) {
                    let halo = rect.insetBy(dx: -4, dy: -4)
                    context.stroke(Path(ellipseIn: halo), with: .color(.accentColor), lineWidth: 2)
                }
                context.fill(Path(ellipseIn: rect), with: .color(style.tint))
                context.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.9)), lineWidth: isCenter ? 2 : 1)
                if isCenter, let symbol = style.symbol {
                    context.draw(
                        Text(Image(systemName: symbol)).font(.system(size: radius, weight: .bold)).foregroundColor(.white),
                        at: position
                    )
                }
            }

            let titleAll = neighborhood.vertices.count <= Self.titledVertexLimit
            for vertex in neighborhood.vertices {
                guard let position = layout.positions[vertex.id] else { continue }
                let isCenter = vertex.id == neighborhood.center?.id
                let isHighlighted = highlighted.contains(vertex.id)
                guard titleAll || isCenter || isHighlighted else { continue }
                let radius = isCenter ? nodeRadius * 1.35 : nodeRadius
                let text = Text(Self.shortTitle(vertex.title))
                    .font(isCenter || isHighlighted ? .caption.bold() : .caption2)
                    .foregroundColor(isHighlighted ? .primary : .secondary)
                context.draw(text, at: CGPoint(x: position.x, y: position.y + radius + 9), anchor: .center)
            }
        }
    }

    /// A small triangle pointing along the edge, stopped short of the target's circle.
    static func arrowhead(from: CGPoint, to: CGPoint, clearance: CGFloat, size: CGFloat = 6) -> Path {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = hypot(dx, dy)
        guard length > clearance + size else { return Path() }
        let ux = dx / length
        let uy = dy / length
        let tip = CGPoint(x: to.x - ux * clearance, y: to.y - uy * clearance)
        let base = CGPoint(x: tip.x - ux * size, y: tip.y - uy * size)
        var path = Path()
        path.move(to: tip)
        path.addLine(to: CGPoint(x: base.x - uy * size / 2, y: base.y + ux * size / 2))
        path.addLine(to: CGPoint(x: base.x + uy * size / 2, y: base.y - ux * size / 2))
        path.closeSubpath()
        return path
    }

    /// A title cut to fit under a circle, on a word boundary where one is near.
    static func shortTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > titleLength else { return trimmed }
        let cut = String(trimmed.prefix(titleLength))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > titleLength / 2 {
            return String(cut[..<space]) + "…"
        }
        return cut + "…"
    }
}

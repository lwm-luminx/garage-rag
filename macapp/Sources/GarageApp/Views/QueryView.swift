import SwiftUI
import AppKit

/// The Query page's wording and examples as plain values, so they can be tested without a window.
enum QueryPresentation {
    static let title = "Query"

    /// The setting that keeps the last query across launches.
    static let lastQueryKey = "garage.query.last"

    /// A fact is stated by its document, or by the message in it the fact came from, and dated by
    /// its most recent restatement, whose document it names.
    static let defaultQuery = """
        MATCH (c:Fact)
        MATCH (d:Document) WHERE d.document_id = c.latest_document_id
        RETURN c.statement AS fact, d.title AS latest_in, c.at AS latest
        ORDER BY latest DESC
        LIMIT 25
        """

    /// Starting points for the editor's Examples menu.
    static let examples: [(name: String, query: String)] = [
        ("Facts, newest first, and where each was last stated", defaultQuery),
        ("What an author wrote, newest first", """
            MATCH (a:Author)-[:WROTE]->(d:Document)
            RETURN a.display_name AS author, d.title AS document, d.at AS at
            ORDER BY at DESC
            LIMIT 50
            """),
        ("Messages a thread holds", """
            MATCH (d:Document)-[:HAS_MESSAGE]->(m:Message)
            RETURN d.title AS thread, m.sender AS sender, m.text AS message, m.at AS at
            ORDER BY at DESC
            LIMIT 50
            """),
        ("Most linked-to links", """
            MATCH (x)-[:LINKS_TO]->(l:Link)
            RETURN l.href AS href, l.text AS text, count(x) AS uses
            ORDER BY uses DESC
            LIMIT 50
            """),
        ("Facts stated in more than one document", """
            MATCH (d:Document)-[:STATES]->(c:Fact)
            WITH c, count(DISTINCT d) AS documents
            WHERE documents > 1
            RETURN c.statement AS fact, documents
            ORDER BY documents DESC
            LIMIT 50
            """),
        ("Every label, with counts", """
            MATCH (n)
            RETURN label(n) AS label, count(n) AS vertices
            ORDER BY vertices DESC
            """),
    ]

    static let help = "openCypher, run read-only on the garage graph. End with RETURN and name what it returns; RETURN * is not supported. ⌘↩ runs it."

    /// The line under the results.
    static func summary(rows: Int, truncated: Bool, milliseconds: Double) -> String {
        let count = "\(rows.formatted()) \(rows == 1 ? "row" : "rows")"
        let time = milliseconds < 1000 ? "\(Int(milliseconds.rounded())) ms" : String(format: "%.1f s", milliseconds / 1000)
        return truncated ? "\(count) (more past the limit) in \(time)" : "\(count) in \(time)"
    }

    static let unavailable = "No graph yet. It is built when facts are gleaned or distilled, and needs Garage's own database (Apache AGE)."
}

/// A raw openCypher editor over the `garage` graph, and its results as a table.
struct QueryView: View {
    @EnvironmentObject var appState: AppState

    @AppStorage(QueryPresentation.lastQueryKey) private var query = QueryPresentation.defaultQuery
    @State private var result: GraphQueryResult?
    @State private var errorMessage: String?
    @State private var isRunning = false
    @State private var limit = 500

    /// Centers the Graph page on a vertex in the results.
    private let openGraph: (GraphFocus) -> Void

    init(openGraph: @escaping (GraphFocus) -> Void = { _ in }) {
        self.openGraph = openGraph
    }

    var body: some View {
        VSplitView {
            editor
                .frame(minHeight: 140, idealHeight: 200)
            results
                .frame(minHeight: 160)
        }
        .navigationTitle(QueryPresentation.title)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $query)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                .accessibilityIdentifier("query.editor")
            HStack(spacing: 8) {
                Menu("Examples") {
                    ForEach(QueryPresentation.examples, id: \.name) { example in
                        Button(example.name) { query = example.query }
                    }
                }
                .fixedSize()
                Picker("Limit", selection: $limit) {
                    ForEach([100, 500, 2000, 10000], id: \.self) { n in
                        Text("\(n.formatted()) rows").tag(n)
                    }
                }
                .fixedSize()
                Text(QueryPresentation.help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button {
                    run()
                } label: {
                    if isRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Run", systemImage: "play.fill")
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(isRunning || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || appState.postgres.status != .running)
                .accessibilityIdentifier("query.run")
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var results: some View {
        if let errorMessage {
            ScrollView {
                Text(errorMessage)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .accessibilityIdentifier("query.error")
            }
        } else if let result {
            if !result.available {
                placeholder(QueryPresentation.unavailable)
            } else {
                VStack(spacing: 0) {
                    resultTable(result)
                    Divider()
                    HStack {
                        Text(QueryPresentation.summary(
                            rows: result.rows.count, truncated: result.truncated, milliseconds: result.elapsedMilliseconds
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("query.summary")
                        Spacer()
                        Button("Copy as TSV") { NSPasteboard.general.copy(tsv(result)) }
                            .controlSize(.small)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
            }
        } else {
            placeholder("Write a query and choose Run.")
        }
    }

    private func placeholder(_ message: String) -> some View {
        VStack {
            Spacer()
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resultTable(_ result: GraphQueryResult) -> some View {
        ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(result.columns.enumerated()), id: \.offset) { _, column in
                        Text(column)
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                    }
                }
                Divider()
                ForEach(result.rows) { row in
                    GridRow {
                        ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
                            cellView(cell)
                        }
                    }
                }
            }
            .padding(12)
        }
        .accessibilityIdentifier("query.results")
    }

    @ViewBuilder
    private func cellView(_ cell: GraphQueryCell) -> some View {
        if let vertex = cell.vertex {
            let style = GraphLabelStyle.vertex(vertex.label)
            HStack(spacing: 4) {
                Image(systemName: style.symbol ?? "circle")
                    .foregroundStyle(style.tint)
                Text(cell.display)
                    .lineLimit(3)
                    .textSelection(.enabled)
                if let key = vertex.key {
                    Button("Show") { openGraph(GraphFocus(label: vertex.label, key: key)) }
                        .controlSize(.mini)
                        .help("Center the Graph page on this \(style.name.lowercased())")
                }
            }
            .frame(maxWidth: 420, alignment: .leading)
            .help(cell.text)
        } else {
            Text(cell.display)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(4)
                .textSelection(.enabled)
                .frame(maxWidth: 420, alignment: .leading)
        }
    }

    private func tsv(_ result: GraphQueryResult) -> String {
        let clean = { (value: String) in value.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
        let lines = [result.columns.map(clean).joined(separator: "\t")]
            + result.rows.map { $0.cells.map { clean($0.display) }.joined(separator: "\t") }
        return lines.joined(separator: "\n")
    }

    private func run() {
        let text = query
        isRunning = true
        errorMessage = nil
        Task {
            do {
                let loaded = try await appState.runGraphQuery(text, limit: limit)
                await MainActor.run {
                    result = loaded
                    isRunning = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isRunning = false
                }
            }
        }
    }
}

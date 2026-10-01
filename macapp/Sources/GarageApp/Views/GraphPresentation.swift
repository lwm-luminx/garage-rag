import SwiftUI

// The Graph page's wording and colours as plain values, so they can be tested without a window:
// how each label is named and coloured, and what the page says when there is nothing to draw.

/// How a vertex or edge label reads and looks.
struct GraphLabelStyle: Equatable {
    /// The label as a heading: "Potential fact", "Supports".
    let name: String
    let tint: Color
    /// The SF Symbol for the label's vertices; edges have none.
    let symbol: String?

    /// The style for a vertex label; one the app does not know gets a neutral style and its own name.
    static func vertex(_ label: String) -> GraphLabelStyle {
        switch label {
        case "Document": GraphLabelStyle(name: "Document", tint: .blue, symbol: "doc.text")
        case "Chunk": GraphLabelStyle(name: "Chunk", tint: .teal, symbol: "text.alignleft")
        case "Author": GraphLabelStyle(name: "Author", tint: .green, symbol: "person")
        case "PotentialFact": GraphLabelStyle(name: "Potential fact", tint: .orange, symbol: "lightbulb")
        case "Fact": GraphLabelStyle(name: "Fact", tint: .purple, symbol: "lightbulb.fill")
        default: GraphLabelStyle(name: humanize(label), tint: configuredTint(label), symbol: "circle")
        }
    }

    /// The style for an edge label.
    static func edge(_ label: String) -> GraphLabelStyle {
        switch label {
        case "HAS_CHUNK": GraphLabelStyle(name: "Has chunk", tint: .teal, symbol: nil)
        case "WROTE": GraphLabelStyle(name: "Wrote", tint: .green, symbol: nil)
        case "RECEIVED": GraphLabelStyle(name: "Received", tint: .mint, symbol: nil)
        case "STATES": GraphLabelStyle(name: "States", tint: .orange, symbol: nil)
        case "SUPPORTS": GraphLabelStyle(name: "Supports", tint: .purple, symbol: nil)
        case "RESTATES": GraphLabelStyle(name: "Restates", tint: .pink, symbol: nil)
        default: GraphLabelStyle(name: humanize(label), tint: configuredTint(label), symbol: nil)
        }
    }

    /// Tints for labels a fact prompt's `graph` block adds, none of them a built-in label's.
    static let configuredPalette: [Color] = [.indigo, .cyan, .brown, .red, .yellow, .gray]

    /// A configured label's tint: picked from its name, so it keeps its colour across launches
    /// (Swift's `hashValue` is seeded per process, so it is not used).
    static func configuredTint(_ label: String) -> Color {
        var hash: UInt32 = 2_166_136_261
        for byte in label.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return configuredPalette[Int(hash % UInt32(configuredPalette.count))]
    }

    /// `HAS_CHUNK` -> "Has chunk", `PotentialFact` -> "Potential fact".
    static func humanize(_ label: String) -> String {
        var words: [String] = []
        for part in label.split(separator: "_") {
            var word = ""
            for (index, scalar) in part.unicodeScalars.enumerated() {
                if index > 0, CharacterSet.uppercaseLetters.contains(scalar),
                   let last = word.unicodeScalars.last, CharacterSet.lowercaseLetters.contains(last) {
                    words.append(word)
                    word = ""
                }
                word.unicodeScalars.append(scalar)
            }
            words.append(word)
        }
        let lowered = words.filter { !$0.isEmpty }.map { $0.lowercased() }
        guard let first = lowered.first else { return label }
        return ([first.prefix(1).uppercased() + String(first.dropFirst())] + Array(lowered.dropFirst())).joined(separator: " ")
    }
}

/// What the Graph page says when it cannot draw.
enum GraphPagePresentation {
    static let title = "Graph"
    static let searchPlaceholder = "Find a document, author, fact or statement…"

    /// The labels a page opened with nothing chosen starts from, best first: a distilled fact ties
    /// statements to their documents, a document ties them to its authors.
    static let startingLabels = ["Fact", "Document", "PotentialFact", "Author"]

    /// Where the page centers when it opens with nothing chosen, so there is a picture before any
    /// search: the owner's own Author vertex, else the first vertex of the best starting label,
    /// else the first of any.
    static func startingVertex(_ vertices: [GraphVertexItem]) -> GraphVertexItem? {
        if let owner = vertices.first(where: isSelfAuthor) {
            return owner
        }
        for label in startingLabels {
            if let vertex = vertices.first(where: { $0.label == label }) {
                return vertex
            }
        }
        return vertices.first
    }

    /// Whether `vertex` is the owner's own Author vertex (`is_self` among its properties).
    static func isSelfAuthor(_ vertex: GraphVertexItem) -> Bool {
        guard vertex.label == "Author",
              let data = vertex.propertiesJSON.data(using: .utf8),
              let properties = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return properties["is_self"] as? Bool == true
    }

    /// The page's depth before anything is chosen.
    static let defaultDepth = 2

    /// How many hops out the page starts when it centers on a new starting vertex of `label` (from
    /// another page, a search result, or the vertex it opens on).
    /// From a claim, three hops reach the other documents that state it (the fact, its
    /// distilled fact, that fact's other statements, their documents); from a document, an author
    /// or a chunk, two hops already fan out wide.
    static func startingDepth(for label: String) -> Int {
        ["Document", "Author", "Chunk"].contains(label) ? defaultDepth : 3
    }

    /// The page's empty state, from what it knows.
    struct Empty: Equatable {
        let symbol: String
        let title: String
        let message: String
    }

    static func empty(databaseRunning: Bool, available: Bool, hasSelection: Bool, searched: Bool) -> Empty {
        if !databaseRunning {
            return Empty(
                symbol: "point.3.connected.trianglepath.dotted",
                title: "Database Offline",
                message: "Start the database to browse the graph."
            )
        }
        if !available {
            return Empty(
                symbol: "point.3.connected.trianglepath.dotted",
                title: "No Graph Yet",
                message: "The graph is built when facts are gleaned or distilled: choose Glean Facts or Distill Facts on the Facts page. It needs the Apache AGE extension, which Garage's own database has."
            )
        }
        if searched {
            return Empty(
                symbol: "magnifyingglass",
                title: "Nothing Found",
                message: "No document, author, fact or statement matched. Titles and statements are searched; a number finds a record by id."
            )
        }
        if !hasSelection {
            return Empty(
                symbol: "point.3.connected.trianglepath.dotted",
                title: "Pick a Starting Point",
                message: "Search for a document, author, fact or statement, then choose one to see what it is connected to."
            )
        }
        return Empty(
            symbol: "point.3.filled.connected.trianglepath.dotted",
            title: "Nothing Connected",
            message: "Nothing within reach passes the current filters. Turn more vertex or edge types on, or look further out."
        )
    }

    /// The footer under the picture: what is drawn, and whether the limit cut it.
    static func summary(vertices: Int, edges: Int, depth: Int, truncated: Bool) -> String {
        let hops = depth == 1 ? "1 hop" : "\(depth) hops"
        let counts = "\(vertices) \(vertices == 1 ? "vertex" : "vertices"), \(edges) \(edges == 1 ? "edge" : "edges") within \(hops)"
        return truncated ? counts + " (some connections left out; filter or look nearer)" : counts
    }
}

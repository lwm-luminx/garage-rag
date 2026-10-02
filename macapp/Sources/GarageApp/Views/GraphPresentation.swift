import SwiftUI

// The Graph page's wording and colours as plain values, so they can be tested without a window:
// how each label is named and coloured, and what the page says when there is nothing to draw.

/// How a vertex or edge label reads and looks.
struct GraphLabelStyle: Equatable {
    /// The label as a heading: "Fact", "Has message".
    let name: String
    let tint: Color
    /// The SF Symbol for the label's vertices; edges have none.
    let symbol: String?

    /// The style for a vertex label; one the app does not know gets a neutral style and its own name.
    static func vertex(_ label: String) -> GraphLabelStyle {
        switch label {
        case "Document": GraphLabelStyle(name: "Document", tint: .blue, symbol: "doc.text")
        case "Message": GraphLabelStyle(name: "Message", tint: .teal, symbol: "bubble.left")
        case "Author": GraphLabelStyle(name: "Author", tint: .green, symbol: "person")
        case "Link": GraphLabelStyle(name: "Link", tint: .cyan, symbol: "link")
        case "Fact": GraphLabelStyle(name: "Fact", tint: .purple, symbol: "lightbulb.fill")
        default: GraphLabelStyle(name: humanize(label), tint: configuredTint(label), symbol: "circle")
        }
    }

    /// The style for an edge label.
    static func edge(_ label: String) -> GraphLabelStyle {
        switch label {
        case "HAS_MESSAGE": GraphLabelStyle(name: "Has message", tint: .teal, symbol: nil)
        case "WROTE": GraphLabelStyle(name: "Wrote", tint: .green, symbol: nil)
        case "RECEIVED": GraphLabelStyle(name: "Received", tint: .mint, symbol: nil)
        case "SENT": GraphLabelStyle(name: "Sent", tint: .green, symbol: nil)
        case "LINKS_TO": GraphLabelStyle(name: "Links to", tint: .cyan, symbol: nil)
        case "REFERS_TO": GraphLabelStyle(name: "Refers to", tint: .blue, symbol: nil)
        case "STATES": GraphLabelStyle(name: "States", tint: .purple, symbol: nil)
        default: GraphLabelStyle(name: humanize(label), tint: configuredTint(label), symbol: nil)
        }
    }

    /// Tints for labels a fact prompt's `graph` block adds, none of them a built-in label's.
    static let configuredPalette: [Color] = [.indigo, .brown, .red, .yellow, .gray]

    /// A configured label's tint: picked from its name, so it keeps its colour across launches
    /// (Swift's `hashValue` is seeded per process, so it is not used).
    static func configuredTint(_ label: String) -> Color {
        var hash: UInt32 = 2_166_136_261
        for byte in label.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return configuredPalette[Int(hash % UInt32(configuredPalette.count))]
    }

    /// `HAS_MESSAGE` -> "Has message", `TeamMember` -> "Team member".
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
    static let searchPlaceholder = "Find a document, author or fact…"

    /// The labels a page opened with nothing chosen starts from, best first: a fact ties the
    /// documents that state it together, a document ties them to its authors.
    static let startingLabels = ["Fact", "Document", "Author"]

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

    /// The dropdown under the search field: how many matches, after how many characters, and how
    /// long typing must pause before the lookup runs.
    static let suggestionLimit = 8
    static let suggestionMinimumLength = 2
    static let suggestionDelayNanoseconds: UInt64 = 250_000_000

    /// The highlighted suggestion after an arrow key: down from nothing takes the first, up from
    /// nothing the last, and each end wraps to the other.
    static func movedHighlight(_ current: Int?, by step: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return step > 0 ? 0 : count - 1 }
        return ((current + step) % count + count) % count
    }

    /// The page's depth before anything is chosen.
    static let defaultDepth = 2

    /// How many hops out the page starts when it centers on a new starting vertex of `label` (from
    /// another page, a search result, or the vertex it opens on).
    /// From a fact, three hops reach its documents, their authors and the other facts those
    /// documents state; from a document, an author, a message or a link, two hops already fan out wide.
    static func startingDepth(for label: String) -> Int {
        ["Document", "Author", "Message", "Link"].contains(label) ? defaultDepth : 3
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
                message: "No document, author or fact matched. Titles and facts are searched; a number finds a record by id."
            )
        }
        if !hasSelection {
            return Empty(
                symbol: "point.3.connected.trianglepath.dotted",
                title: "Pick a Starting Point",
                message: "Search for a document, author or fact, then choose one to see what it is connected to."
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

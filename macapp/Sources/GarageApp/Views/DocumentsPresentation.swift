import Foundation

// The Documents page's wording and grouping as plain values, so they can be tested without a window.

/// How a document is shown: its text (the default), what is linked to it, or how it was cut into
/// chunks for embedding, which only appears when chunks are turned on as an advanced option.
enum DocumentDetailMode: String, CaseIterable, Identifiable {
    case text = "Text"
    case linked = "Linked"
    case chunks = "Chunks"

    var id: String { rawValue }

    /// The modes the picker offers.
    static func available(showChunks: Bool) -> [DocumentDetailMode] {
        showChunks ? [.text, .linked, .chunks] : [.text, .linked]
    }
}

/// One group of the Linked view: what was read, or what was derived, under one label.
struct LinkedGroup: Identifiable, Equatable {
    var id: String { "\(origin):\(label)" }
    let origin: String
    let label: String
    let rows: [LinkedRow]
}

/// One vertex linked to the document, with how it is linked.
struct LinkedRow: Identifiable, Equatable {
    var id: Int64 { vertex.id }
    let vertex: GraphVertexItem
    /// The edge labels joining it to the rest of the picture, humanized: "Wrote", "States".
    let relations: [String]
}

enum DocumentsPresentation {
    /// The setting that turns the Chunks view on.
    static let showChunksKey = "garage.documents.showChunks"

    /// The most text the Text view lays out at once; a longer document shows its start and says so.
    static let textDisplayLimit = 200_000

    static let emptyDetail = "Select a document to read it"

    /// What the Text view says above a document that keeps no text of its own.
    static let noContent = "This document keeps no text of its own; what was embedded is shown instead."

    /// The note under a document cut at `textDisplayLimit`.
    static func truncatedNote(shown: Int, total: Int) -> String {
        "Showing the first \(shown.formatted()) of \(total.formatted()) characters. Copy Text copies all of it."
    }

    /// The text the Text view shows: the document's own, else its chunks' joined, with where it was cut.
    static func displayText(content: String, hasContent: Bool, chunks: [String]) -> (text: String, total: Int) {
        let whole = hasContent ? content : chunks.joined(separator: "\n\n")
        guard whole.count > textDisplayLimit else { return (whole, whole.count) }
        return (String(whole.prefix(textDisplayLimit)), whole.count)
    }

    /// An ISO 8601 timestamp (with or without fractional seconds) as a date, or nil.
    static func date(_ iso: String) -> Date? {
        guard !iso.isEmpty else { return nil }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: iso) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: iso)
    }

    /// When an element happened, for a list row: the date and time, or the raw text when it does not parse.
    static func when(_ iso: String) -> String {
        guard let date = date(iso) else { return iso }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// The Linked view's groups: read before derived, labels in a fixed order (configured ones after,
    /// by name), each group's vertices in the order the server gave them, which is newest first.
    static func linkedGroups(_ neighborhood: GraphNeighborhood) -> [LinkedGroup] {
        guard let center = neighborhood.center else { return [] }
        let order = ["Message", "Author", "Link", "Document", "Fact"]
        var byLabel: [String: [LinkedRow]] = [:]
        for vertex in neighborhood.vertices where vertex.id != center.id {
            var seen = Set<String>()
            let relations = neighborhood.connections(of: vertex.id)
                .map { GraphLabelStyle.edge($0.edge.label).name }
                .filter { seen.insert($0).inserted }
            byLabel[vertex.label, default: []].append(LinkedRow(vertex: vertex, relations: relations))
        }
        let labels = byLabel.keys.sorted { a, b in
            let ia = order.firstIndex(of: a) ?? order.count
            let ib = order.firstIndex(of: b) ?? order.count
            return ia == ib ? a < b : ia < ib
        }
        let groups = labels.map { label in
            LinkedGroup(origin: GraphVertexItem.origin(of: label), label: label, rows: byLabel[label] ?? [])
        }
        return groups.filter { $0.origin == "read" } + groups.filter { $0.origin != "read" }
    }

    /// The heading over each half of the Linked view.
    static func originHeading(_ origin: String) -> String {
        origin == "read" ? "Read from sources" : "Derived by Garage"
    }

    /// The Linked view's empty state.
    static func linkedEmpty(available: Bool) -> String {
        available
            ? "Nothing is linked to this document yet. Glean Facts finds what it states."
            : "The graph is built when facts are gleaned or distilled, and needs Garage's own database (Apache AGE). Choose Distill Facts on the Facts page."
    }
}

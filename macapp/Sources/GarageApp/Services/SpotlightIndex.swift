import CoreSpotlight
import Foundation
import UniformTypeIdentifiers
import proto_garage_proto_swift

// Garage in the Mac's own Spotlight: each document's title and path, and each distinct fact, as Core
// Spotlight items in the app's own index, so a Spotlight search finds them and opening one shows it on
// the Documents page. The index lives on this Mac, in the app's container; Garage sends it no
// document text, and communications (mail, Messages) are never added: their own apps index them.

/// One item Garage puts in Spotlight, before it becomes a `CSSearchableItem`. Plain values, so the
/// rules (what goes in, under which identifier, worded how) are unit-tested without Core Spotlight.
public struct SpotlightEntry: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case document
        case fact
    }

    public let kind: Kind
    /// `garage.document.<id>` or `garage.fact.<id>.<document id>`.
    public let identifier: String
    public let title: String
    public let summary: String
    /// The document's file, when its URI is a path.
    public let fileURL: URL?
    public let keywords: [String]

    /// Core Spotlight's domain, which `removeAll` and a rebuild work by.
    public var domain: String { "garage.\(kind.rawValue)" }
}

/// What Garage puts in Spotlight, and how an opened item finds its way back.
public enum SpotlightEntries {
    /// Never in Spotlight: Mail and Messages index their own, and Garage's copy is not to widen that.
    static let excludedClass = "communication"
    static let documentPrefix = "garage.document."
    static let factPrefix = "garage.fact."
    /// A fact's summary line is cut here; Spotlight shows two lines or so.
    static let summaryLimit = 300

    public static func document(_ item: DocumentListItem) -> SpotlightEntry? {
        guard item.corpusClass != excludedClass else { return nil }
        let fileURL = Self.fileURL(item.uri)
        let place = fileURL?.deletingLastPathComponent().path ?? item.uri
        return SpotlightEntry(
            kind: .document,
            identifier: "\(documentPrefix)\(item.id)",
            title: item.displayTitle,
            summary: "\(item.sourceSlug) · \(place)",
            fileURL: fileURL,
            keywords: ["Garage", item.sourceSlug, item.corpusClass].filter { !$0.isEmpty }
        )
    }

    public static func fact(_ item: FactListItem) -> SpotlightEntry? {
        guard item.corpusClass != excludedClass else { return nil }
        let statement = item.distilledStatement.isEmpty ? item.fact : item.distilledStatement
        let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let title = item.documentDisplayTitle
        return SpotlightEntry(
            kind: .fact,
            identifier: "\(factPrefix)\(item.id).\(item.documentID)",
            title: trimmed.count > summaryLimit ? String(trimmed.prefix(summaryLimit)) + "…" : trimmed,
            summary: "Fact from \(title)",
            fileURL: nil,
            keywords: ["Garage", "fact", item.factClass, item.sourceSlug].filter { !$0.isEmpty }
        )
    }

    /// The document an opened item stands for: the document itself, or the one a fact came from.
    public static func documentID(forIdentifier identifier: String) -> Int64? {
        if identifier.hasPrefix(documentPrefix) {
            return Int64(identifier.dropFirst(documentPrefix.count))
        }
        if identifier.hasPrefix(factPrefix) {
            let parts = identifier.dropFirst(factPrefix.count).split(separator: ".")
            guard parts.count == 2, Int64(parts[0]) != nil else { return nil }
            return Int64(parts[1])
        }
        return nil
    }

    /// A file URL for a document URI that is an absolute path (or a `file:` URL); nil otherwise.
    static func fileURL(_ uri: String) -> URL? {
        if uri.hasPrefix("/") {
            return URL(fileURLWithPath: uri)
        }
        if let url = URL(string: uri), url.isFileURL {
            return url
        }
        return nil
    }
}

/// Keeps Garage's Core Spotlight index in step with the corpus: rebuilt after each pipeline run and
/// on demand, emptied when the setting is turned off or the database is reset.
@MainActor
final class SpotlightIndexer: ObservableObject {
    static let enabledKey = "garage.spotlight.enabled"
    /// How many of each Garage reads per page, and the most it adds, so a huge corpus cannot make a
    /// rebuild run for minutes.
    static let pageSize = 500
    static let maxDocuments = 50_000
    static let maxFacts = 50_000

    @Published private(set) var isRebuilding = false
    @Published private(set) var lastCount: Int?
    @Published private(set) var lastError: String?

    private let index = CSSearchableIndex(name: "Garage")

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    /// Replaces the index with the corpus as GarageService lists it now. A no-op when the setting
    /// is off, Spotlight indexing is unavailable, or a rebuild is already running.
    func rebuild(using grpc: GarageGRPCService) async {
        guard isEnabled, CSSearchableIndex.isIndexingAvailable(), !isRebuilding else { return }
        isRebuilding = true
        defer { isRebuilding = false }
        do {
            var entries: [SpotlightEntry] = []
            var offset = 0
            while offset < Self.maxDocuments {
                let page = try await grpc.listDocuments(limit: Self.pageSize, offset: offset)
                entries += page.documents.compactMap { SpotlightEntries.document(DocumentListItem(summary: $0)) }
                offset += page.documents.count
                if page.documents.count < Self.pageSize { break }
            }
            offset = 0
            while offset < Self.maxFacts {
                // One row per distilled fact, so restatements do not crowd the results.
                let page = try await grpc.listFacts(limit: Self.pageSize, offset: offset, collapse: true)
                entries += page.facts.compactMap { SpotlightEntries.fact(FactListItem(summary: $0)) }
                offset += page.facts.count
                if page.facts.count < Self.pageSize { break }
            }
            try await index.deleteAllSearchableItems()
            for batch in stride(from: 0, to: entries.count, by: Self.pageSize) {
                let items = entries[batch ..< min(batch + Self.pageSize, entries.count)].map(Self.searchableItem)
                try await index.indexSearchableItems(items)
            }
            lastCount = entries.count
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Takes every Garage item out of Spotlight.
    func removeAll() async {
        do {
            try await index.deleteAllSearchableItems()
            lastCount = 0
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private static func searchableItem(_ entry: SpotlightEntry) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: entry.kind == .fact ? .text : .content)
        attributes.title = entry.title
        attributes.displayName = entry.title
        attributes.contentDescription = entry.summary
        attributes.keywords = entry.keywords
        if let fileURL = entry.fileURL {
            attributes.contentURL = fileURL
            attributes.path = fileURL.path
        }
        return CSSearchableItem(uniqueIdentifier: entry.identifier, domainIdentifier: entry.domain, attributeSet: attributes)
    }
}

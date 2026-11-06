import Foundation
import proto_garage_proto_swift

/// One fact with the document it was distilled from, as returned by the gRPC ListFacts endpoint.
public struct FactListItem: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let documentID: Int64
    public let ord: Int
    public let fact: String
    public let factClass: String
    public let attributesJSON: String
    /// Span of the document's content the fact was grounded to.
    public let charStart: Int?
    public let charEnd: Int?
    public let extractor: String
    public let extractorModel: String
    public let createdAt: String
    public let documentTitle: String
    public let documentURI: String
    public let sourceSlug: String
    public let corpusClass: String
    /// The grounded span with some of the document either side; empty when there is none.
    public let excerpt: String
    /// Where `excerpt` starts in the document's content.
    public let excerptStart: Int
    /// The distilled fact this potential fact backs (`garage cluster-facts`), nil before one ran.
    public let distilledFactID: Int64?
    /// How many potential facts back that distilled fact; more than one means restatements.
    public let distilledSize: Int
    /// The distilled fact's statement: the local model's sentence, or one member's own text.
    public let distilledStatement: String
    /// Whether the local model wrote `distilledStatement` (it is then not a quotation).
    public let distilledGenerated: Bool
    /// How varied the facts behind the distilled fact are: their mean cosine distance to its
    /// centroid (0 for identical facts and for a fact alone).
    public let distilledSpread: Double
    /// The fact of the same document this one restates, nil when it stands for itself.
    public let restatesFactID: Int64?

    public init(summary: Garage_FactSummary) {
        self.id = summary.id
        self.documentID = summary.documentID
        self.ord = Int(summary.ord)
        self.fact = summary.fact
        self.factClass = summary.factClass
        self.attributesJSON = summary.attributesJson
        self.charStart = summary.hasCharStart ? Int(summary.charStart) : nil
        self.charEnd = summary.hasCharEnd ? Int(summary.charEnd) : nil
        self.extractor = summary.extractor
        self.extractorModel = summary.extractorModel
        self.createdAt = summary.createdAt
        self.documentTitle = summary.documentTitle
        self.documentURI = summary.documentUri
        self.sourceSlug = summary.sourceSlug
        self.corpusClass = summary.corpusClass
        self.excerpt = summary.excerpt
        self.excerptStart = Int(summary.excerptStart)
        self.distilledFactID = summary.distilledFactID == 0 ? nil : summary.distilledFactID
        self.distilledSize = Int(summary.distilledSize)
        self.distilledStatement = summary.distilledStatement
        self.distilledGenerated = summary.distilledGenerated
        self.distilledSpread = summary.distilledSpread
        self.restatesFactID = summary.restatesFactID == 0 ? nil : summary.restatesFactID
    }

    /// Whether other potential facts state the same claim as this one.
    public var hasRestatements: Bool { distilledSize > 1 }

    /// Whether this fact restates another fact of its own document.
    public var restatesWithinDocument: Bool { restatesFactID != nil }

    /// How closely the facts behind the distilled fact agree, as a whole percentage
    /// (100 for identical ones); nil for a fact alone.
    public var agreementPercent: Int? {
        guard hasRestatements else { return nil }
        return Int(((1 - distilledSpread) * 100).rounded(.down))
    }

    public var documentDisplayTitle: String {
        if !documentTitle.isEmpty {
            return documentTitle
        }
        if !documentURI.isEmpty {
            return (documentURI as NSString).lastPathComponent
        }
        return "(untitled)"
    }

    /// The excerpt split around the grounded span, or nil when the fact has none
    /// or the span does not fall inside the excerpt.
    ///
    /// Offsets count Unicode scalars: Python's string indices, which the extractor
    /// recorded, and Postgres's `substr`, which cut the excerpt, both do.
    public var groundedExcerpt: (before: String, span: String, after: String)? {
        guard !excerpt.isEmpty, let charStart, let charEnd, charEnd >= charStart else { return nil }
        let scalars = excerpt.unicodeScalars
        let lower = charStart - excerptStart
        let upper = charEnd - excerptStart
        guard lower >= 0, upper <= scalars.count else { return nil }
        let lowerIndex = scalars.index(scalars.startIndex, offsetBy: lower)
        let upperIndex = scalars.index(scalars.startIndex, offsetBy: upper)
        return (
            String(scalars[scalars.startIndex..<lowerIndex]),
            String(scalars[lowerIndex..<upperIndex]),
            String(scalars[upperIndex..<scalars.endIndex])
        )
    }

    /// The extractor's attributes, sorted by key, values rendered as text.
    public var attributes: [FactAttribute] {
        guard !attributesJSON.isEmpty,
              let data = attributesJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return object.keys.sorted().map { key in
            FactAttribute(key: key, value: Self.render(object[key]))
        }
    }

    private static func render(_ value: Any?) -> String {
        if let string = value as? String {
            return string
        }
        if let value, JSONSerialization.isValidJSONObject(value),
           let encoded = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let text = String(data: encoded, encoding: .utf8) {
            return text
        }
        if let value, !(value is NSNull) {
            return "\(value)"
        }
        return ""
    }
}

/// One of a fact's extractor attributes.
public struct FactAttribute: Identifiable, Hashable, Sendable {
    public var id: String { key }
    public let key: String
    public let value: String
}

/// A fact class and how many facts carry it, for the Facts page's class picker.
public struct FactClassCount: Identifiable, Hashable, Sendable {
    public var id: String { factClass }
    public let factClass: String
    public let count: Int

    public init(factClass: String, count: Int) {
        self.factClass = factClass
        self.count = count
    }

    public init(proto: Garage_FactClassCount) {
        self.init(factClass: proto.factClass, count: Int(proto.count))
    }
}

/// One page of facts, with the total that matched and the classes on offer.
public struct FactListPage: Sendable {
    public let items: [FactListItem]
    public let totalCount: Int
    public let classes: [FactClassCount]

    public init(response: Garage_ListFactsResponse) {
        self.items = response.facts.map { FactListItem(summary: $0) }
        self.totalCount = Int(response.totalCount)
        self.classes = response.classes.map { FactClassCount(proto: $0) }
    }
}

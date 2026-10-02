import Foundation
import proto_garage_proto_swift

/// Summary row for a single document, as returned by the gRPC ListDocuments endpoint.
public struct DocumentListItem: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let uri: String
    public let title: String
    public let sourceSlug: String
    public let corpusClass: String
    public let trustTier: String
    public let mime: String
    public let lang: String
    public let byteSize: Int64
    public let chunkCount: Int
    public let factCount: Int
    public let state: String
    public let ingestedAt: String
    /// When the element happened (a thread's last message, a mail's date, the file's modification
    /// time), which the listing is sorted by, newest first.
    public let occurredAt: String

    public init(summary: Garage_DocumentSummary) {
        self.id = summary.id
        self.uri = summary.uri
        self.title = summary.title
        self.sourceSlug = summary.sourceSlug
        self.corpusClass = summary.corpusClass
        self.trustTier = summary.trustTier
        self.mime = summary.mime
        self.lang = summary.lang
        self.byteSize = summary.byteSize
        self.chunkCount = Int(summary.chunkCount)
        self.factCount = Int(summary.factCount)
        self.state = summary.state
        self.ingestedAt = summary.ingestedAt
        self.occurredAt = summary.occurredAt.isEmpty ? summary.ingestedAt : summary.occurredAt
    }

    public var displayTitle: String {
        if !title.isEmpty {
            return title
        }
        if !uri.isEmpty {
            return (uri as NSString).lastPathComponent
        }
        return "(untitled)"
    }

    public var formattedByteSize: String {
        ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }
}

/// A single chunk belonging to a document, as returned by the gRPC GetDocument endpoint.
public struct DocumentChunkItem: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let ord: Int
    public let text: String
    public let tokenCount: Int
    /// Span of the document's content; nil when the chunk is not a verbatim slice of it.
    public let charStart: Int?
    public let charEnd: Int?
    public let headingPath: String

    public init(chunk: Garage_DocumentChunkInfo) {
        self.id = chunk.id
        self.ord = Int(chunk.ord)
        self.text = chunk.text
        self.tokenCount = Int(chunk.tokenCount)
        self.charStart = chunk.hasCharStart ? Int(chunk.charStart) : nil
        self.charEnd = chunk.hasCharEnd ? Int(chunk.charEnd) : nil
        self.headingPath = chunk.headingPath
    }
}

/// A single fact extracted from a document, as returned by the gRPC GetDocument endpoint.
public struct DocumentFactItem: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let ord: Int
    public let fact: String
    public let factClass: String
    public let attributesJSON: String
    public let charStart: Int?
    public let charEnd: Int?
    public let extractor: String

    public init(fact: Garage_DocumentFactInfo) {
        self.id = fact.id
        self.ord = Int(fact.ord)
        self.fact = fact.fact
        self.factClass = fact.factClass
        self.attributesJSON = fact.attributesJson
        self.charStart = fact.hasCharStart ? Int(fact.charStart) : nil
        self.charEnd = fact.hasCharEnd ? Int(fact.charEnd) : nil
        self.extractor = fact.extractor
    }
}

/// Author attribution for a document.
public struct DocumentAuthorItem: Identifiable, Hashable, Sendable {
    public var id: String { "\(name)_\(role)" }
    public let name: String
    public let role: String
    public let confidence: Float

    public init(author: Garage_DocumentAuthorInfo) {
        self.name = author.name
        self.role = author.role
        self.confidence = author.confidence
    }
}

/// Full document detail plus its ordered chunks, as returned by the gRPC GetDocument endpoint.
public struct DocumentDetailItem: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let uri: String
    public let title: String
    public let sourceSlug: String
    public let corpusClass: String
    public let trustTier: String
    public let mime: String
    public let lang: String
    public let byteSize: Int64
    public let extractor: String
    public let extractorVersion: String
    public let chunker: String
    public let metaJSON: String
    public let state: String
    public let error: String
    public let ingestedAt: String
    public let authors: [DocumentAuthorItem]
    /// The extracted text, which the page shows; `hasContent` is false when the document keeps none.
    public let content: String
    public let hasContent: Bool
    public let occurredAt: String
    /// How the text was cut up for embedding: an implementation detail, shown only on request.
    public let chunks: [DocumentChunkItem]
    public let facts: [DocumentFactItem]

    public init(response: Garage_GetDocumentResponse) {
        let document = response.document
        self.id = document.id
        self.uri = document.uri
        self.title = document.title
        self.sourceSlug = document.sourceSlug
        self.corpusClass = document.corpusClass
        self.trustTier = document.trustTier
        self.mime = document.mime
        self.lang = document.lang
        self.byteSize = document.byteSize
        self.extractor = document.extractor
        self.extractorVersion = document.extractorVersion
        self.chunker = document.chunker
        self.metaJSON = document.metaJson
        self.state = document.state
        self.error = document.error
        self.ingestedAt = document.ingestedAt
        self.authors = document.authors.map { DocumentAuthorItem(author: $0) }
        self.content = document.content
        self.hasContent = document.hasContent_p
        self.occurredAt = document.occurredAt.isEmpty ? document.ingestedAt : document.occurredAt
        self.chunks = response.chunks.map { DocumentChunkItem(chunk: $0) }
        self.facts = response.facts.map { DocumentFactItem(fact: $0) }
    }

    public var displayTitle: String {
        if !title.isEmpty {
            return title
        }
        if !uri.isEmpty {
            return (uri as NSString).lastPathComponent
        }
        return "(untitled)"
    }

    public var formattedByteSize: String {
        ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }
}

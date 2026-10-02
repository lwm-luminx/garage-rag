import Foundation
import proto_garage_proto_swift

/// One vertex of the `garage` graph, as the GetGraphNeighborhood and FindGraphVertices RPCs return it.
public struct GraphVertexItem: Identifiable, Hashable, Sendable {
    /// The graph id: unique across labels, and what edges refer to.
    public let id: Int64
    /// Document, Chunk, Author, Fact, ...
    public let label: String
    /// The relational id (documents.id, distilled_facts.id, ...); nil for a label without one.
    public let key: Int64?
    /// What to call it: the title, name or statement.
    public let title: String
    public let propertiesJSON: String

    public init(id: Int64, label: String, key: Int64?, title: String, propertiesJSON: String = "") {
        self.id = id
        self.label = label
        self.key = key
        self.title = title
        self.propertiesJSON = propertiesJSON
    }

    public init(proto: Garage_GraphVertex) {
        self.init(
            id: proto.id,
            label: proto.label,
            key: proto.key == 0 ? nil : proto.key,
            title: proto.title,
            propertiesJSON: proto.propertiesJson
        )
    }

    /// The properties, sorted by key, values rendered as text.
    public var properties: [GraphProperty] {
        GraphProperty.parse(propertiesJSON)
    }

    /// The document behind this vertex: itself for a Document, the containing document for a
    /// Chunk (it carries `document_id`), nothing otherwise.
    public var documentID: Int64? {
        if label == "Document" {
            return key
        }
        guard let value = properties.first(where: { $0.key == "document_id" })?.value, let id = Int64(value) else {
            return nil
        }
        return id
    }

    /// The document's URI, which a Document vertex carries.
    public var documentURI: String {
        properties.first { $0.key == "uri" }?.value ?? ""
    }
}

/// One edge between two vertices' graph ids.
public struct GraphEdgeItem: Identifiable, Hashable, Sendable {
    public let id: Int64
    /// HAS_CHUNK, WROTE, RECEIVED, STATES, ...
    public let label: String
    public let sourceID: Int64
    public let targetID: Int64
    public let propertiesJSON: String

    public init(id: Int64, label: String, sourceID: Int64, targetID: Int64, propertiesJSON: String = "") {
        self.id = id
        self.label = label
        self.sourceID = sourceID
        self.targetID = targetID
        self.propertiesJSON = propertiesJSON
    }

    public init(proto: Garage_GraphEdge) {
        self.init(
            id: proto.id,
            label: proto.label,
            sourceID: proto.sourceID,
            targetID: proto.targetID,
            propertiesJSON: proto.propertiesJson
        )
    }

    public var properties: [GraphProperty] {
        GraphProperty.parse(propertiesJSON)
    }

    /// The vertex at the other end of this edge from `vertexID`, or nil when the edge does not touch it.
    public func otherEnd(from vertexID: Int64) -> Int64? {
        if sourceID == vertexID { return targetID }
        if targetID == vertexID { return sourceID }
        return nil
    }
}

/// One property of a vertex or edge, rendered as text.
public struct GraphProperty: Identifiable, Hashable, Sendable {
    public var id: String { key }
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }

    /// The properties in a JSON object, sorted by key; anything unparseable is no properties.
    public static func parse(_ json: String) -> [GraphProperty] {
        guard !json.isEmpty,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return object.keys.sorted().map { key in
            GraphProperty(key: key, value: render(object[key]))
        }
    }

    private static func render(_ value: Any?) -> String {
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            // JSONSerialization hands booleans over as NSNumber too.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
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

/// A label and how many vertices or edges carry it, for the Graph page's filters.
public struct GraphLabelCount: Identifiable, Hashable, Sendable {
    public var id: String { label }
    public let label: String
    public let count: Int

    public init(label: String, count: Int) {
        self.label = label
        self.count = count
    }

    public init(proto: Garage_GraphLabelCount) {
        self.init(label: proto.label, count: Int(proto.count))
    }
}

/// The graph's labels, or `available == false` where the server has no AGE or no graph yet.
public struct GraphLabels: Equatable, Sendable {
    public let available: Bool
    public let vertexLabels: [GraphLabelCount]
    public let edgeLabels: [GraphLabelCount]

    public init(available: Bool, vertexLabels: [GraphLabelCount] = [], edgeLabels: [GraphLabelCount] = []) {
        self.available = available
        self.vertexLabels = vertexLabels
        self.edgeLabels = edgeLabels
    }

    public init(response: Garage_GraphLabelsResponse) {
        self.init(
            available: response.available,
            vertexLabels: response.vertexLabels.map { GraphLabelCount(proto: $0) },
            edgeLabels: response.edgeLabels.map { GraphLabelCount(proto: $0) }
        )
    }
}

/// A vertex and everything within a few hops of it.
public struct GraphNeighborhood: Equatable, Sendable {
    public let available: Bool
    public let center: GraphVertexItem?
    /// The center included.
    public let vertices: [GraphVertexItem]
    /// Both ends of every edge are in `vertices`.
    public let edges: [GraphEdgeItem]
    /// The vertex limit cut the walk short.
    public let truncated: Bool

    public init(
        available: Bool,
        center: GraphVertexItem? = nil,
        vertices: [GraphVertexItem] = [],
        edges: [GraphEdgeItem] = [],
        truncated: Bool = false
    ) {
        self.available = available
        self.center = center
        self.vertices = vertices
        self.edges = edges
        self.truncated = truncated
    }

    public init(response: Garage_GraphNeighborhoodResponse) {
        self.init(
            available: response.available,
            center: response.hasCenter ? GraphVertexItem(proto: response.center) : nil,
            vertices: response.vertices.map { GraphVertexItem(proto: $0) },
            edges: response.edges.map { GraphEdgeItem(proto: $0) },
            truncated: response.truncated
        )
    }

    public func vertex(_ id: Int64) -> GraphVertexItem? {
        vertices.first { $0.id == id }
    }

    /// The edges touching a vertex, with the vertex at each one's other end.
    public func connections(of vertexID: Int64) -> [GraphConnection] {
        edges.compactMap { edge in
            guard let otherID = edge.otherEnd(from: vertexID), let other = vertex(otherID) else { return nil }
            return GraphConnection(edge: edge, other: other)
        }
    }
}

/// One edge at a vertex, with the vertex at its other end.
public struct GraphConnection: Identifiable, Hashable, Sendable {
    public var id: Int64 { edge.id }
    public let edge: GraphEdgeItem
    public let other: GraphVertexItem

    public init(edge: GraphEdgeItem, other: GraphVertexItem) {
        self.edge = edge
        self.other = other
    }
}

/// A vertex another page asks the Graph page to center on, by label and relational id.
public struct GraphFocus: Equatable, Sendable {
    public let label: String
    public let key: Int64

    public init(label: String, key: Int64) {
        self.label = label
        self.key = key
    }
}

import XCTest
@testable import GarageApp

final class DocumentsPresentationTests: XCTestCase {

    func testChunksAreAViewOnlyWhenTurnedOn() {
        XCTAssertEqual(DocumentDetailMode.available(showChunks: false), [.text, .linked])
        XCTAssertEqual(DocumentDetailMode.available(showChunks: true), [.text, .linked, .chunks])
    }

    func testTheTextIsTheDocumentsOwnElseItsChunks() {
        XCTAssertEqual(DocumentsPresentation.displayText(content: "whole", hasContent: true, chunks: ["a", "b"]).text, "whole")
        XCTAssertEqual(DocumentsPresentation.displayText(content: "", hasContent: false, chunks: ["a", "b"]).text, "a\n\nb")
        let long = String(repeating: "x", count: DocumentsPresentation.textDisplayLimit + 10)
        let shown = DocumentsPresentation.displayText(content: long, hasContent: true, chunks: [])
        XCTAssertEqual(shown.text.count, DocumentsPresentation.textDisplayLimit)
        XCTAssertEqual(shown.total, long.count)
    }

    func testTimestampsParseWithAndWithoutFractions() {
        XCTAssertNotNil(DocumentsPresentation.date("2026-09-24T18:03:00Z"))
        XCTAssertNotNil(DocumentsPresentation.date("2026-09-24T18:03:00+00:00"))
        XCTAssertNotNil(DocumentsPresentation.date("2026-09-24T18:03:00.123456+00:00"))
        XCTAssertNil(DocumentsPresentation.date(""))
        XCTAssertEqual(DocumentsPresentation.when("not a date"), "not a date")
    }

    func testLinkedGroupsPutWhatWasReadBeforeWhatWasDerived() {
        func vertex(_ id: Int64, _ label: String) -> GraphVertexItem {
            GraphVertexItem(id: id, label: label, key: id, title: "v\(id)")
        }
        let center = vertex(1, "Document")
        let neighborhood = GraphNeighborhood(
            available: true,
            center: center,
            vertices: [center, vertex(5, "Fact"), vertex(4, "Message"), vertex(3, "Link"), vertex(2, "Author"),
                       vertex(6, "Person")],
            edges: [
                GraphEdgeItem(id: 10, label: "WROTE", sourceID: 2, targetID: 1),
                GraphEdgeItem(id: 11, label: "LINKS_TO", sourceID: 1, targetID: 3),
                GraphEdgeItem(id: 12, label: "HAS_MESSAGE", sourceID: 1, targetID: 4),
                GraphEdgeItem(id: 13, label: "STATES", sourceID: 4, targetID: 5),
            ]
        )
        let groups = DocumentsPresentation.linkedGroups(neighborhood)
        XCTAssertEqual(groups.map(\.label), ["Message", "Author", "Link", "Fact", "Person"])
        XCTAssertEqual(groups.map(\.origin), ["read", "read", "read", "derived", "derived"])
        XCTAssertEqual(groups.first { $0.label == "Message" }?.rows.first?.relations, ["Has message", "States"])
        XCTAssertEqual(DocumentsPresentation.linkedGroups(GraphNeighborhood(available: false)), [])
    }

    func testAVertexKnowsWhetherItWasReadOrDerived() {
        XCTAssertTrue(GraphVertexItem(id: 1, label: "Message", key: 1, title: "").isRead)
        XCTAssertFalse(GraphVertexItem(id: 1, label: "Fact", key: 1, title: "").isRead)
        XCTAssertEqual(GraphVertexItem(id: 1, label: "Person", key: 1, title: "", origin: "derived").origin, "derived")
        let link = GraphVertexItem(id: 1, label: "Link", key: -3, title: "Docs",
                                   propertiesJSON: #"{"href": "https://docs.example.com", "at": ""}"#)
        XCTAssertEqual(link.href, "https://docs.example.com")
        XCTAssertNil(link.occurredAt)
    }

    func testQueryCellsReadAsPlainValues() {
        XCTAssertEqual(GraphQueryCell(text: #""Ada""#).display, "Ada")
        XCTAssertEqual(GraphQueryCell(text: "42").display, "42")
        let vertex = GraphVertexItem(id: 9, label: "Document", key: 3, title: "notes.md")
        XCTAssertEqual(GraphQueryCell(text: "{...}::vertex", vertex: vertex).display, "notes.md")
        XCTAssertEqual(QueryPresentation.summary(rows: 1, truncated: false, milliseconds: 12.4), "1 row in 12 ms")
        XCTAssertEqual(QueryPresentation.summary(rows: 500, truncated: true, milliseconds: 2300), "500 rows (more past the limit) in 2.3 s")
    }
}

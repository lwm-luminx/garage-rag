import XCTest
import SwiftUI
@testable import GarageApp

final class GraphPresentationTests: XCTestCase {

    func testTheDepthStartsFurtherOutFromAClaim() {
        XCTAssertEqual(GraphPagePresentation.defaultDepth, 2)
        XCTAssertEqual(GraphPagePresentation.startingDepth(for: "PotentialFact"), 3)
        XCTAssertEqual(GraphPagePresentation.startingDepth(for: "Fact"), 3)
        XCTAssertEqual(GraphPagePresentation.startingDepth(for: "Person"), 3)
        XCTAssertEqual(GraphPagePresentation.startingDepth(for: "Document"), 2)
        XCTAssertEqual(GraphPagePresentation.startingDepth(for: "Author"), 2)
    }

    func testLabelsReadAsWords() {
        XCTAssertEqual(GraphLabelStyle.humanize("HAS_CHUNK"), "Has chunk")
        XCTAssertEqual(GraphLabelStyle.humanize("PotentialFact"), "Potential fact")
        XCTAssertEqual(GraphLabelStyle.humanize("RESTATES"), "Restates")
        XCTAssertEqual(GraphLabelStyle.humanize("Fact"), "Fact")
        XCTAssertEqual(GraphLabelStyle.humanize("URLRef"), "Urlref")
    }

    func testKnownLabelsHaveTheirOwnStyleAndUnknownOnesANeutralOne() {
        XCTAssertEqual(GraphLabelStyle.vertex("PotentialFact"), GraphLabelStyle(name: "Potential fact", tint: .orange, symbol: "lightbulb"))
        XCTAssertEqual(GraphLabelStyle.vertex("Fact").tint, .purple)
        XCTAssertEqual(GraphLabelStyle.edge("SUPPORTS"), GraphLabelStyle(name: "Supports", tint: .purple, symbol: nil))
        XCTAssertEqual(GraphLabelStyle.edge("RESTATES").name, "Restates")
        XCTAssertEqual(GraphLabelStyle.vertex("Entity"), GraphLabelStyle(name: "Entity", tint: GraphLabelStyle.configuredTint("Entity"), symbol: "circle"))
        XCTAssertEqual(GraphLabelStyle.edge("MENTIONS"), GraphLabelStyle(name: "Mentions", tint: GraphLabelStyle.configuredTint("MENTIONS"), symbol: nil))
    }

    func testConfiguredLabelsKeepAColourOfTheirOwn() {
        XCTAssertEqual(GraphLabelStyle.configuredTint("Person"), GraphLabelStyle.configuredTint("Person"))
        XCTAssertTrue(GraphLabelStyle.configuredPalette.contains(GraphLabelStyle.configuredTint("WORKS_AT")))
        // Different labels spread over the palette rather than all landing on one colour.
        let tints = ["Person", "Organization", "Place", "Project", "WORKS_AT", "MEMBER_OF", "RELATED_TO"]
            .map(GraphLabelStyle.configuredTint)
        XCTAssertGreaterThan(Set(tints.map { "\($0)" }).count, 1)
    }

    func testThePageStartsFromAFactThenADocument() {
        let author = GraphVertexItem(id: 1, label: "Author", key: 3, title: "Ada")
        let document = GraphVertexItem(id: 2, label: "Document", key: 7, title: "notes.md")
        let fact = GraphVertexItem(id: 3, label: "Fact", key: 9, title: "Ada wrote the notes.")
        let person = GraphVertexItem(id: 4, label: "Person", key: 11, title: "Ada")
        XCTAssertEqual(GraphPagePresentation.startingVertex([author, document, fact]), fact)
        XCTAssertEqual(GraphPagePresentation.startingVertex([author, document]), document)
        XCTAssertEqual(GraphPagePresentation.startingVertex([person]), person)
        XCTAssertNil(GraphPagePresentation.startingVertex([]))
    }

    func testTheEmptyStateNamesWhatIsMissing() {
        XCTAssertEqual(GraphPagePresentation.empty(databaseRunning: false, available: false, hasSelection: false, searched: false).title, "Database Offline")
        let noGraph = GraphPagePresentation.empty(databaseRunning: true, available: false, hasSelection: false, searched: false)
        XCTAssertEqual(noGraph.title, "No Graph Yet")
        XCTAssertTrue(noGraph.message.contains("Distill Facts"))
        XCTAssertEqual(GraphPagePresentation.empty(databaseRunning: true, available: true, hasSelection: false, searched: true).title, "Nothing Found")
        XCTAssertEqual(GraphPagePresentation.empty(databaseRunning: true, available: true, hasSelection: false, searched: false).title, "Pick a Starting Point")
        XCTAssertEqual(GraphPagePresentation.empty(databaseRunning: true, available: true, hasSelection: true, searched: false).title, "Nothing Connected")
    }

    func testTheSummaryCountsAndSaysWhenItWasCut() {
        XCTAssertEqual(GraphPagePresentation.summary(vertices: 1, edges: 0, depth: 1, truncated: false), "1 vertex, 0 edges within 1 hop")
        XCTAssertEqual(GraphPagePresentation.summary(vertices: 12, edges: 11, depth: 2, truncated: false), "12 vertices, 11 edges within 2 hops")
        XCTAssertTrue(GraphPagePresentation.summary(vertices: 150, edges: 200, depth: 3, truncated: true).hasSuffix("(some connections left out; filter or look nearer)"))
    }

    func testTitlesUnderVerticesAreCutOnAWordWhereOneIsNear() {
        XCTAssertEqual(GraphCanvas.shortTitle("The roof is slate."), "The roof is slate.")
        XCTAssertEqual(GraphCanvas.shortTitle("The heat pump was installed in March 2024 by the previous owner"), "The heat pump was installed…")
        XCTAssertEqual(GraphCanvas.shortTitle(String(repeating: "x", count: 40)), String(repeating: "x", count: 28) + "…")
    }

    func testArrowheadsNeedRoomBetweenTheCircles() {
        XCTAssertTrue(GraphCanvas.arrowhead(from: .zero, to: CGPoint(x: 10, y: 0), clearance: 8).isEmpty)
        let arrow = GraphCanvas.arrowhead(from: .zero, to: CGPoint(x: 100, y: 0), clearance: 10)
        XCTAssertFalse(arrow.isEmpty)
        // The tip stops at the clearance, short of the target.
        XCTAssertEqual(arrow.boundingRect.maxX, 90, accuracy: 0.001)
    }

    func testCirclesShrinkAsThePictureFills() {
        XCTAssertEqual(GraphView.nodeRadius(for: 5), 11)
        XCTAssertEqual(GraphView.nodeRadius(for: 30), 8)
        XCTAssertEqual(GraphView.nodeRadius(for: 150), 5.5)
    }

    func testThePageStartsFromTheOwnersOwnAuthorVertex() {
        let fact = GraphVertexItem(id: 1, label: "Fact", key: 1, title: "A claim")
        let other = GraphVertexItem(id: 2, label: "Author", key: 2, title: "Ada", propertiesJSON: #"{"is_self": false}"#)
        let owner = GraphVertexItem(id: 3, label: "Author", key: 3, title: "Rick", propertiesJSON: #"{"author_id": 3, "is_self": true}"#)

        XCTAssertTrue(GraphPagePresentation.isSelfAuthor(owner))
        XCTAssertFalse(GraphPagePresentation.isSelfAuthor(other))
        XCTAssertFalse(GraphPagePresentation.isSelfAuthor(fact))
        XCTAssertEqual(GraphPagePresentation.startingVertex([fact, other, owner])?.id, 3)
        XCTAssertEqual(GraphPagePresentation.startingVertex([other, fact])?.id, 1, "no owner: the best starting label")
    }

    func testArrowKeysWalkTheSuggestionsAndWrap() {
        XCTAssertEqual(GraphPagePresentation.movedHighlight(nil, by: 1, count: 3), 0)
        XCTAssertEqual(GraphPagePresentation.movedHighlight(nil, by: -1, count: 3), 2)
        XCTAssertEqual(GraphPagePresentation.movedHighlight(2, by: 1, count: 3), 0)
        XCTAssertEqual(GraphPagePresentation.movedHighlight(0, by: -1, count: 3), 2)
        XCTAssertNil(GraphPagePresentation.movedHighlight(0, by: 1, count: 0))
    }
}

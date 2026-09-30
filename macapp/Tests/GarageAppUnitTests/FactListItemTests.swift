import XCTest
import SwiftUI
import AppKit
import proto_garage_proto_swift
@testable import GarageApp

final class FactListItemTests: XCTestCase {

    private func summary(
        excerpt: String = "",
        excerptStart: Int32 = 0,
        span: (Int32, Int32)? = nil,
        attributes: String = ""
    ) -> Garage_FactSummary {
        var summary = Garage_FactSummary()
        summary.id = 7
        summary.documentID = 3
        summary.fact = "The heat pump was installed in March 2024."
        summary.factClass = "event"
        summary.documentUri = "/notes/house.md"
        summary.sourceSlug = "notes"
        summary.corpusClass = "document"
        summary.excerpt = excerpt
        summary.excerptStart = excerptStart
        summary.attributesJson = attributes
        if let span {
            summary.charStart = span.0
            summary.charEnd = span.1
        }
        return summary
    }

    func testMapsTheSummaryAndFallsBackToTheFileNameForTitle() {
        let item = FactListItem(summary: summary())
        XCTAssertEqual(item.id, 7)
        XCTAssertEqual(item.documentID, 3)
        XCTAssertEqual(item.factClass, "event")
        XCTAssertNil(item.charStart)
        XCTAssertEqual(item.documentDisplayTitle, "house.md")
    }

    func testMapsTheDistilledFactsVariabilityAndRestatement() {
        var proto = summary()
        XCTAssertNil(FactListItem(summary: proto).restatesFactID)
        XCTAssertNil(FactListItem(summary: proto).agreementPercent)

        proto.distilledFactID = 11
        proto.distilledSize = 3
        proto.distilledSpread = 0.0125
        proto.restatesFactID = 5
        let item = FactListItem(summary: proto)
        XCTAssertEqual(item.restatesFactID, 5)
        XCTAssertTrue(item.restatesWithinDocument)
        XCTAssertEqual(item.agreementPercent, 98)
    }

    func testGroundedExcerptSplitsAroundTheSpan() throws {
        // The excerpt starts 100 characters into the document; the span is "heat pump".
        let item = FactListItem(summary: summary(excerpt: "Our heat pump works.", excerptStart: 100, span: (104, 113)))
        let grounded = try XCTUnwrap(item.groundedExcerpt)
        XCTAssertEqual(grounded.before, "Our ")
        XCTAssertEqual(grounded.span, "heat pump")
        XCTAssertEqual(grounded.after, " works.")
    }

    func testGroundedExcerptCountsUnicodeScalarsLikePython() throws {
        // "é" written as e + combining accent is one Character but two scalars (and two Python indices).
        let item = FactListItem(summary: summary(excerpt: "Cafe\u{301} opens at 8.", excerptStart: 0, span: (6, 11)))
        let grounded = try XCTUnwrap(item.groundedExcerpt)
        XCTAssertEqual(grounded.span, "opens")
    }

    func testNoGroundedExcerptWithoutASpanOrOutsideTheExcerpt() {
        XCTAssertNil(FactListItem(summary: summary(excerpt: "text")).groundedExcerpt)
        XCTAssertNil(FactListItem(summary: summary(span: (0, 4))).groundedExcerpt)
        XCTAssertNil(FactListItem(summary: summary(excerpt: "short", excerptStart: 10, span: (12, 40))).groundedExcerpt)
    }

    func testAttributesAreSortedAndRenderedAsText() {
        let item = FactListItem(summary: summary(attributes: #"{"when": "2024-03", "cost": 12000, "parts": ["pump", "valve"]}"#))
        XCTAssertEqual(item.attributes.map(\.key), ["cost", "parts", "when"])
        XCTAssertEqual(item.attributes.map(\.value), ["12000", #"["pump","valve"]"#, "2024-03"])
        XCTAssertTrue(FactListItem(summary: summary(attributes: "not json")).attributes.isEmpty)
    }

    @MainActor
    func testFactsViewRenders() {
        let appState = AppState()
        let controller = NSHostingController(rootView: FactsView().environmentObject(appState))
        XCTAssertNotNil(controller.view)
    }
}

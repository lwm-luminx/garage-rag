import XCTest
import proto_garage_proto_swift
@testable import GarageApp

final class SpotlightEntriesTests: XCTestCase {

    private func document(id: Int64 = 42, uri: String = "/Users/me/Notes/house.rtf", corpusClass: String = "document") -> DocumentListItem {
        var summary = Garage_DocumentSummary()
        summary.id = id
        summary.uri = uri
        summary.title = "House"
        summary.sourceSlug = "notes"
        summary.corpusClass = corpusClass
        return DocumentListItem(summary: summary)
    }

    private func fact(statement: String = "", corpusClass: String = "document") -> FactListItem {
        var summary = Garage_FactSummary()
        summary.id = 7
        summary.documentID = 3
        summary.fact = "  The heat pump was installed in March 2024.  "
        summary.factClass = "event"
        summary.documentUri = "/notes/house.md"
        summary.sourceSlug = "notes"
        summary.corpusClass = corpusClass
        summary.distilledStatement = statement
        return FactListItem(summary: summary)
    }

    func testADocumentIsItsTitleSourceAndFolder() throws {
        let entry = try XCTUnwrap(SpotlightEntries.document(document()))
        XCTAssertEqual(entry.kind, .document)
        XCTAssertEqual(entry.identifier, "garage.document.42")
        XCTAssertEqual(entry.domain, "garage.document")
        XCTAssertEqual(entry.title, "House")
        XCTAssertEqual(entry.summary, "notes · /Users/me/Notes")
        XCTAssertEqual(entry.fileURL, URL(fileURLWithPath: "/Users/me/Notes/house.rtf"))
        XCTAssertEqual(entry.keywords, ["Garage", "notes", "document"])
    }

    func testADocumentThatIsNotAFileHasNoURL() throws {
        let entry = try XCTUnwrap(SpotlightEntries.document(document(uri: "messages://chat/12")))
        XCTAssertNil(entry.fileURL)
        XCTAssertEqual(entry.summary, "notes · messages://chat/12")
    }

    func testCommunicationsNeverGoToSpotlight() {
        XCTAssertNil(SpotlightEntries.document(document(corpusClass: "communication")))
        XCTAssertNil(SpotlightEntries.fact(fact(corpusClass: "communication")))
    }

    func testAFactIsItsStatementTrimmed() throws {
        let entry = try XCTUnwrap(SpotlightEntries.fact(fact()))
        XCTAssertEqual(entry.kind, .fact)
        XCTAssertEqual(entry.identifier, "garage.fact.7.3")
        XCTAssertEqual(entry.title, "The heat pump was installed in March 2024.")
        XCTAssertEqual(entry.summary, "Fact from house.md")
        XCTAssertNil(entry.fileURL)
    }

    func testAFactPrefersItsDistilledStatement() throws {
        let entry = try XCTUnwrap(SpotlightEntries.fact(fact(statement: "Heat pump installed March 2024.")))
        XCTAssertEqual(entry.title, "Heat pump installed March 2024.")
    }

    func testALongFactIsCut() throws {
        let entry = try XCTUnwrap(SpotlightEntries.fact(fact(statement: String(repeating: "a", count: 400))))
        XCTAssertEqual(entry.title.count, SpotlightEntries.summaryLimit + 1)
        XCTAssertTrue(entry.title.hasSuffix("…"))
    }

    func testAnOpenedItemLeadsToItsDocument() {
        XCTAssertEqual(SpotlightEntries.documentID(forIdentifier: "garage.document.42"), 42)
        XCTAssertEqual(SpotlightEntries.documentID(forIdentifier: "garage.fact.7.3"), 3)
        XCTAssertNil(SpotlightEntries.documentID(forIdentifier: "garage.fact.7"))
        XCTAssertNil(SpotlightEntries.documentID(forIdentifier: "garage.document.x"))
        XCTAssertNil(SpotlightEntries.documentID(forIdentifier: "other.document.42"))
    }
}

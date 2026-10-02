import XCTest

/// The Graph page over the fixture corpus once its facts are gleaned, embedded and distilled
/// (`ModelUITestCase.ingestGleanEmbedAndDistill`), which rebuilds the Apache AGE graph the app's
/// Postgres carries: finding vertices by kind and title, a document's neighborhood and its filters,
/// and the Facts and Documents pages' Show in Graph.
///
/// What the counts rest on is in `FixtureCorpus` and `garage_rag/db/graph.py`: a `Document` per
/// file and a `Fact` per distilled fact, `STATES`-linked from each document that states it (a thread's
/// from its message; the corpus has none). Chunks are not in the graph.
final class GraphUITests: ModelUITestCase {

    private var inspectorTitle: XCUIElement { element(identifier: "graph.detail.title") }
    private var summary: XCUIElement { element(identifier: "graph.summary") }

    /// Picks the Kind picker's item named `kind` and searches for `query` (empty lists every vertex of
    /// that kind), then waits for the results footer to read `expected`.
    private func find(_ query: String, kind: String, expecting expected: String,
                      file: StaticString = #filePath, line: UInt = #line) {
        // The query first: a change of kind searches again with whatever the field holds, so the
        // field must already hold this query when the kind changes.
        submit(query, in: "graph.search", file: file, line: line)
        choose(kind, in: "graph.kind", file: file, line: line)
        let count = element(identifier: "graph.results.count")
        XCTAssertTrue(
            waitUntil(timeout: 30) { count.exists && self.shownText(of: count) == expected },
            "finding \"\(query)\" among \(kind) vertices: the footer does not say \"\(expected)\" (\(count.exists ? shownText(of: count) : "no footer"))",
            file: file,
            line: line
        )
    }

    /// Waits until the inspector shows the vertex titled `title`.
    private func waitForInspector(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            waitUntil(timeout: 30) { self.inspectorTitle.exists && self.shownText(of: self.inspectorTitle) == title },
            "the inspector does not show \"\(title)\" (\(inspectorTitle.exists ? shownText(of: inspectorTitle) : "no inspector"))",
            file: file,
            line: line
        )
    }

    /// The inspector's heading for the connections of one edge label: "States · 5".
    private func connections(_ edge: String, _ count: Int) -> XCUIElement {
        element(text: "\(edge) · \(count)")
    }

    /// How many vertices the footer under the picture says are drawn.
    private func drawnVertices() -> Int? {
        guard summary.exists else { return nil }
        return Int(shownText(of: summary).prefix { $0.isNumber })
    }

    /// The depth stepper's up arrow.
    private func increaseDepth(file: StaticString = #filePath, line: UInt = #line) {
        let stepper = element(identifier: "graph.depth")
        XCTAssertTrue(stepper.waitForExistence(timeout: 10), "no depth stepper", file: file, line: line)
        // The identifier may land on the stepper's label rather than its arrows; the page has one stepper.
        let own = stepper.descendants(matching: .incrementArrow).firstMatch
        let up = own.exists ? own : app.incrementArrows.firstMatch
        XCTAssertTrue(up.exists, "the depth stepper has no up arrow", file: file, line: line)
        up.click()
    }

    // MARK: - Tests

    /// Every kind of vertex is there in the numbers the corpus makes; a document found by title opens
    /// its neighborhood, whose connections, vertex filter and depth behave, and Open Document shows it
    /// on the Documents page.
    func testDistilledCorpusIsBrowsableOnTheGraphPage() throws {
        try ingestGleanEmbedAndDistill()
        open(section: "graph")

        for label in ["Document", "Fact"] {
            let chip = element(identifier: "graph.vertex.\(label)")
            XCTAssertTrue(chip.waitForExistence(timeout: 30), "the filter bar has no \(label) vertices")
            XCTAssertEqual(chip.value as? String, "on", "\(label) vertices start switched off")
        }
        for label in ["STATES"] {
            XCTAssertTrue(element(identifier: "graph.edge.\(label)").exists, "the filter bar has no \(label) edges")
        }
        XCTAssertFalse(element(identifier: "graph.vertex.Chunk").exists, "chunks are in the graph")

        find("", kind: "Document", expecting: "\(FixtureCorpus.indexedWithoutCode.count) matches")
        find(FixtureCorpus.quillonBridge.token, kind: "Fact", expecting: "1 match")
        find("quillon", kind: "Document", expecting: "1 match")

        let results = element(identifier: "graph.results")
        let row = results.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR value == %@", FixtureCorpus.quillonBridge.title, FixtureCorpus.quillonBridge.title))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the results do not list the Markdown note")
        row.click()
        waitForInspector(FixtureCorpus.quillonBridge.title)
        XCTAssertTrue(element(identifier: "graph.canvas").exists, "no picture of the neighborhood")

        // The page starts two hops out; the note's own connections are the five facts it states.
        let states = connections("States", FixtureCorpus.quillonBridgeFacts)
        XCTAssertTrue(states.waitForExistence(timeout: 30), "the inspector does not list the note's five facts")
        XCTAssertTrue(shownText(of: summary).hasSuffix("within 2 hops"), "the footer: \(shownText(of: summary))")
        let twoHops = try XCTUnwrap(waitUntilValue(timeout: 10) { self.drawnVertices() }, "the footer counts no vertices")
        XCTAssertGreaterThanOrEqual(twoHops, 1 + FixtureCorpus.quillonBridgeFacts)

        // Facts switched off: they leave the inspector, and the documents reached only through them
        // leave the picture too.
        let factChip = element(identifier: "graph.vertex.Fact")
        click(factChip)
        XCTAssertTrue(waitUntil(timeout: 10) { (factChip.value as? String) == "off" }, "the Fact filter did not switch off")
        XCTAssertTrue(waitUntil(timeout: 30) { !states.exists }, "the facts stayed in the inspector with Fact off")
        XCTAssertTrue(
            waitUntil(timeout: 30) { (self.drawnVertices() ?? twoHops) <= twoHops - FixtureCorpus.quillonBridgeFacts },
            "with Fact off the footer should count fewer vertices (\(shownText(of: summary)))"
        )
        click(factChip)
        XCTAssertTrue(states.waitForExistence(timeout: 30), "the facts did not come back with Fact on")

        // Three hops reach the other documents stating the same facts.
        increaseDepth()
        XCTAssertTrue(
            waitUntil(timeout: 30) { self.summary.exists && self.shownText(of: self.summary).hasSuffix("within 3 hops") },
            "the footer does not say three hops (\(shownText(of: summary)))"
        )
        XCTAssertTrue(waitUntil(timeout: 30) { (self.drawnVertices() ?? 0) > twoHops }, "three hops drew no more than two")

        let openDocument = element(identifier: "graph.detail.openDocument")
        XCTAssertTrue(openDocument.exists, "a document vertex has no Open Document")
        click(openDocument)
        let documentTitle = element(identifier: "documents.detail.title")
        XCTAssertTrue(
            waitUntil(timeout: 30) { documentTitle.exists && self.shownText(of: documentTitle) == FixtureCorpus.quillonBridge.title },
            "Open Document did not show the note on the Documents page"
        )
    }

    /// The Facts page's Show in Graph centers the Graph page on the fact; from there its document is
    /// one click away and can be made the center. The Documents page's Show in Graph centers on a
    /// document.
    func testShowInGraphFromTheFactsAndDocumentsPages() throws {
        try ingestGleanEmbedAndDistill()

        // Distill Facts leaves the Facts page open; find the one fact that carries the note's token.
        submit(FixtureCorpus.quillonBridge.token, in: "facts.search")
        let count = element(identifier: "facts.count")
        XCTAssertTrue(waitUntil(timeout: 30) { count.exists && self.shownText(of: count) == "1 of 1 fact" },
                      "searching \(FixtureCorpus.quillonBridge.token) did not find its one fact (\(count.exists ? shownText(of: count) : "no count"))")
        let row = element(identifier: "facts.row.fact")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no fact row")
        row.click()
        let showInGraph = element(identifier: "facts.detail.graph")
        XCTAssertTrue(showInGraph.waitForExistence(timeout: 10), "the fact's detail has no Show in Graph")
        click(showInGraph)

        waitForInspector(FixtureCorpus.zorvexineFact)
        XCTAssertTrue(
            waitUntil(timeout: 30) { self.summary.exists && self.shownText(of: self.summary).hasSuffix("within 3 hops") },
            "a fact does not open three hops out (\(shownText(of: summary)))"
        )
        XCTAssertTrue(connections("States", 1).waitForExistence(timeout: 30), "the fact is not linked to the document that states it")

        // Its document, from the inspector's connections, then made the center.
        let documentLink = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", FixtureCorpus.quillonBridge.title)).firstMatch
        XCTAssertTrue(documentLink.waitForExistence(timeout: 10), "the fact's connections do not name its document")
        documentLink.click()
        waitForInspector(FixtureCorpus.quillonBridge.title)
        let center = element(identifier: "graph.detail.center")
        XCTAssertTrue(center.exists, "a vertex that is not the center has no Center Here")
        click(center)
        XCTAssertTrue(connections("States", FixtureCorpus.quillonBridgeFacts).waitForExistence(timeout: 30),
                      "centering on the note did not reach its facts")
        XCTAssertTrue(waitUntil(timeout: 10) { !self.element(identifier: "graph.detail.center").exists },
                      "the center still offers Center Here")

        // The Documents page's Linked view lists what the graph links to the lighthouse: the facts it
        // states (derived).
        open(section: "documents")
        let lighthouse = element(text: FixtureCorpus.lighthouse.title)
        XCTAssertTrue(lighthouse.waitForExistence(timeout: 30), "Documents does not list the lighthouse")
        lighthouse.click()
        let linkedSegment = app.radioButtons["Linked"].exists ? app.radioButtons["Linked"] : app.buttons["Linked"]
        XCTAssertTrue(linkedSegment.waitForExistence(timeout: 30), "the document's detail has no Linked view")
        linkedSegment.click()
        XCTAssertTrue(element(identifier: "documents.linked").waitForExistence(timeout: 30), "the Linked view lists nothing")
        XCTAssertTrue(element(identifier: "documents.linked.Fact").exists, "the Linked view lists no facts")
        XCTAssertTrue(element(textContaining: "Derived by Garage").exists, "the Linked view does not set derived apart")
        let documentGraph = element(identifier: "documents.detail.graph")
        XCTAssertTrue(documentGraph.waitForExistence(timeout: 30), "the document's detail has no Show in Graph")
        click(documentGraph)
        waitForInspector(FixtureCorpus.lighthouse.title)
        XCTAssertTrue(shownText(of: summary).hasSuffix("within 2 hops"), "a document does not open two hops out: \(shownText(of: summary))")
        XCTAssertTrue(element(textContaining: "States · ").waitForExistence(timeout: 30), "the lighthouse states no facts")
    }
}

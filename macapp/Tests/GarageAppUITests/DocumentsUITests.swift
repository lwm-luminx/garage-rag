import XCTest

/// The Documents page on the ingested fixture corpus (`macapp/Tests/Fixtures`): the list, a
/// document's detail with its chunks, and the title and class filters. No model is needed.
final class DocumentsUITests: GarageUITestCase {

    private var count: XCUIElement { element(identifier: "documents.count") }

    /// Types `text` into the filter field and submits it. The plain-style field takes focus only when
    /// the click lands on its text area, so the click goes near its leading edge.
    private func filter(by text: String, file: StaticString = #filePath, line: UInt = #line) {
        let field = element(identifier: "documents.filter")
        XCTAssertTrue(field.waitForExistence(timeout: 15), "no filter field", file: file, line: line)
        let focused = waitUntil(timeout: 15) {
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).click()
            return waitUntil(timeout: 1) { (field.value(forKey: "hasKeyboardFocus") as? Bool) == true }
        }
        XCTAssertTrue(focused, "the filter field never took keyboard focus", file: file, line: line)
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text + "\n")
    }

    private func assertCount(_ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            waitUntil(timeout: 30) { self.count.exists && self.shownText(of: self.count) == expected },
            "the list does not say \"\(expected)\" (\(count.exists ? shownText(of: count) : "no count"))",
            file: file,
            line: line
        )
    }

    /// Every indexed file is listed by its title, and the Rust file (code is off for a source added
    /// on the Sources page) is not.
    func testListShowsTheIngestedCorpus() throws {
        try launchApp()
        waitForBackend()
        try ingestFixtureCorpus()

        open(section: "documents")
        let total = FixtureCorpus.indexedWithoutCode.count
        assertCount("\(total) of \(total) documents")
        for document in FixtureCorpus.indexedWithoutCode {
            XCTAssertTrue(element(text: document.title).exists, "Documents does not list \(document.file) as \"\(document.title)\"")
        }
        XCTAssertFalse(element(text: FixtureCorpus.tideTables.title).exists, "a source with code off listed the Rust file")
        XCTAssertTrue(element(text: "Select a document to view its chunks").exists, "the detail pane is not empty before a selection")
    }

    /// Selecting the Markdown note shows its title, its chunk count and both chunks' text.
    func testOpeningADocumentShowsItsChunks() throws {
        try launchApp()
        waitForBackend()
        try ingestFixtureCorpus()

        open(section: "documents")
        let row = element(text: FixtureCorpus.quillonBridge.title)
        XCTAssertTrue(row.waitForExistence(timeout: 30), "Documents does not list the Markdown note")
        row.click()

        let title = element(identifier: "documents.detail.title")
        XCTAssertTrue(
            waitUntil(timeout: 30) { title.exists && self.shownText(of: title) == FixtureCorpus.quillonBridge.title },
            "selecting the note did not open its detail (\(title.exists ? shownText(of: title) : "no title"))"
        )
        let chunkCount = element(identifier: "documents.detail.chunkCount")
        XCTAssertTrue(chunkCount.exists, "the detail does not count the chunks")
        XCTAssertEqual(shownText(of: chunkCount), String(FixtureCorpus.quillonBridgeChunks))

        let chunks = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "documents.chunk."))
        XCTAssertTrue(waitUntil(timeout: 10) { chunks.count == FixtureCorpus.quillonBridgeChunks }, "the detail shows \(chunks.count) chunks")
        XCTAssertTrue(element(textContaining: "The Quillon Bridge opened in 1893").exists, "the first chunk's text is not shown")
        XCTAssertTrue(element(textContaining: "closed for repairs in 1958").exists, "the second chunk's text is not shown")
        XCTAssertTrue(element(textContaining: FixtureCorpus.quillonBridge.token).exists, "the note's token is not in its chunks")
    }

    /// The title filter narrows the list to what matches, and clearing it brings every document back;
    /// the class picker narrows it to the one communication.
    func testFiltersNarrowTheList() throws {
        try launchApp()
        waitForBackend()
        try ingestFixtureCorpus()

        open(section: "documents")
        let total = FixtureCorpus.indexedWithoutCode.count
        assertCount("\(total) of \(total) documents")

        filter(by: "quillon")
        assertCount("1 of 1 document")
        XCTAssertTrue(element(text: FixtureCorpus.quillonBridge.title).exists, "filtering by \"quillon\" hid the note it names")
        XCTAssertFalse(element(text: FixtureCorpus.lanternFestival.title).exists, "filtering by \"quillon\" kept the mail")

        let clear = element(identifier: "documents.filter.clear")
        XCTAssertTrue(clear.exists, "a filled filter has no clear button")
        clear.click()
        assertCount("\(total) of \(total) documents")

        let classPicker = element(identifier: "documents.class")
        XCTAssertTrue(classPicker.exists, "no class picker")
        classPicker.click()
        let communication = app.menuItems["Communication"]
        XCTAssertTrue(communication.waitForExistence(timeout: 10), "the class picker offers no Communication")
        communication.click()
        assertCount("1 of 1 document")
        XCTAssertTrue(element(text: FixtureCorpus.lanternFestival.title).exists, "the Communication class hid the mail")
        XCTAssertFalse(element(text: FixtureCorpus.quillonBridge.title).exists, "the Communication class kept the Markdown note")
    }
}

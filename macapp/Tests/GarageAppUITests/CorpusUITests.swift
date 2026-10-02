import XCTest

/// The fixture corpus (`macapp/Tests/Fixtures`) end to end without a model: what each file is
/// indexed as, the trust filter, ingesting the code file on request, and a second ingest after the
/// folder changes. `DocumentsUITests` covers the list, a document's chunks and the title and class
/// filters.
final class CorpusUITests: GarageUITestCase {

    private var count: XCUIElement { element(identifier: "documents.count") }

    private func assertCount(_ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            waitUntil(timeout: 30) { self.count.exists && self.shownText(of: self.count) == expected },
            "the list does not say \"\(expected)\" (\(count.exists ? shownText(of: count) : "no count"))",
            file: file,
            line: line
        )
    }

    private func documentsCount(_ shown: Int) -> String {
        "\(shown) of \(shown) document\(shown == 1 ? "" : "s")"
    }

    /// Picks `item` from one of the Documents page's pickers.
    private func choose(_ item: String, in identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        let picker = element(identifier: identifier)
        XCTAssertTrue(picker.waitForExistence(timeout: 15), "no picker \(identifier)", file: file, line: line)
        picker.click()
        let menuItem = app.menuItems[item]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 10), "\(identifier) offers no \(item)", file: file, line: line)
        menuItem.click()
    }

    /// Selects `document` in the Documents list and waits for its detail.
    private func select(_ document: FixtureCorpus.Document, file: StaticString = #filePath, line: UInt = #line) {
        let row = element(text: document.title)
        XCTAssertTrue(row.waitForExistence(timeout: 30), "Documents does not list \(document.file)", file: file, line: line)
        row.click()
        let title = element(identifier: "documents.detail.title")
        XCTAssertTrue(
            waitUntil(timeout: 30) { title.exists && self.shownText(of: title) == document.title },
            "selecting \(document.file) did not open its detail (\(title.exists ? shownText(of: title) : "no title"))",
            file: file,
            line: line
        )
    }

    private func waitForStatusFigure(_ name: String, toRead expected: Int, file: StaticString = #filePath, line: UInt = #line) {
        let figure = element(identifier: "status.figure.\(name)")
        XCTAssertTrue(
            waitUntil(timeout: 240) { figure.exists && self.shownText(of: figure) == String(expected) },
            "the Status page's \(name) figure never read \(expected) (\(figure.exists ? shownText(of: figure) : "missing"))",
            file: file,
            line: line
        )
    }

    /// Runs the fixture source's Scan & Ingest again and waits for it to end.
    private func scanAndIngestAgain(file: StaticString = #filePath, line: UInt = #line) {
        open(section: "sources", file: file, line: line)
        let scanIngest = element(identifier: "sources.row.fixture.scanIngest")
        XCTAssertTrue(waitForEnabled(scanIngest), "Scan & Ingest stayed disabled", file: file, line: line)
        click(scanIngest)
        // Disabled (or replaced by Cancel) while it runs; a small change may be done before the first look.
        _ = waitUntil(timeout: 10) { !scanIngest.exists || !scanIngest.isEnabled }
        XCTAssertTrue(waitForEnabled(scanIngest, timeout: 240), "the second Scan & Ingest did not finish", file: file, line: line)
    }

    // MARK: - Tests

    /// Each file's detail shows the corpus class and trust tier the README promises: metadata naming
    /// someone else makes the PDF and the Word file reference, the mail from Oren Pask is received,
    /// and the rest take the source's default, authored. Each detail counts the file's chunks.
    func testEachDocumentShowsItsClassAndTrust() throws {
        try launchApp()
        waitForBackend()
        try ingestFixtureCorpus()

        open(section: "documents")
        for document in FixtureCorpus.indexedWithoutCode {
            select(document)
            let corpusClass = element(identifier: "documents.detail.class")
            let trust = element(identifier: "documents.detail.trust")
            XCTAssertTrue(corpusClass.exists, "\(document.file) shows no class badge")
            XCTAssertTrue(trust.exists, "\(document.file) shows no trust badge")
            XCTAssertEqual(shownText(of: corpusClass), document.corpusClass, "\(document.file)'s class")
            XCTAssertEqual(shownText(of: trust), document.trustTier, "\(document.file)'s trust tier")
            XCTAssertTrue(element(identifier: "documents.text").exists, "\(document.file) shows no text")
        }
    }

    /// The trust picker lists each tier's documents: two authored, two reference, one received.
    func testTrustFilterSortsTheCorpusByTier() throws {
        try launchApp()
        waitForBackend()
        try ingestFixtureCorpus()

        open(section: "documents")
        let total = FixtureCorpus.indexedWithoutCode.count
        assertCount(documentsCount(total))
        for tier in ["Authored", "Reference", "Received"] {
            choose(tier, in: "documents.trust")
            let expected = FixtureCorpus.indexedWithoutCode.filter { $0.trustTier == tier }
            assertCount(documentsCount(expected.count))
            for document in FixtureCorpus.indexedWithoutCode {
                let listed = element(text: document.title)
                if document.trustTier == tier {
                    XCTAssertTrue(listed.waitForExistence(timeout: 10), "\(tier) hid \(document.file)")
                } else {
                    XCTAssertFalse(listed.exists, "\(tier) listed \(document.file), which is \(document.trustTier)")
                }
            }
        }
        choose("All", in: "documents.trust")
        assertCount(documentsCount(total))
    }

    /// A source added on the Sources page skips code; the source menu's Ingest Including Code adds the
    /// Rust file, as a code document with its own chunk, and the class picker finds it.
    func testIngestIncludingCodeAddsTheRustFile() throws {
        try launchApp()
        waitForBackend()
        try ingestFixtureCorpus()

        open(section: "sources")
        let menu = element(identifier: "sources.row.fixture.menu")
        XCTAssertTrue(menu.waitForExistence(timeout: 15), "the source row has no actions menu")
        click(menu)
        let ingestCode = app.menuItems["Ingest Including Code"]
        XCTAssertTrue(ingestCode.waitForExistence(timeout: 10), "the actions menu offers no Ingest Including Code")
        XCTAssertTrue(waitForEnabled(ingestCode), "Ingest Including Code stayed disabled")
        ingestCode.click()

        open(section: "status")
        waitForStatusFigure("documents", toRead: FixtureCorpus.indexedWithCode.count)
        waitForStatusFigure("chunks", toRead: FixtureCorpus.chunksWithCode)

        open(section: "documents")
        assertCount(documentsCount(FixtureCorpus.indexedWithCode.count))
        choose("Code", in: "documents.class")
        assertCount(documentsCount(1))
        select(FixtureCorpus.tideTables)
        XCTAssertEqual(shownText(of: element(identifier: "documents.detail.class")), FixtureCorpus.tideTables.corpusClass)
        XCTAssertTrue(element(textContaining: FixtureCorpus.tideTables.token).exists, "the Rust file's chunk does not hold its token")
    }

    /// A second Scan & Ingest after the folder changed indexes the new note and the edited file's new
    /// text, and leaves everything else as it was: one more document and one more chunk.
    func testSecondIngestPicksUpChanges() throws {
        try launchApp()
        waitForBackend()
        let corpus = try ingestFixtureCorpus()

        let added = "An invented word, quorblint, names the ferry that crosses to Marrowgate at dawn."
        try Data("# The Marrowgate Ferry\n\n\(added)\n".utf8)
            .write(to: corpus.appendingPathComponent("marrowgate-ferry.md"))
        let lighthouse = corpus.appendingPathComponent(FixtureCorpus.lighthouse.file)
        let appended = "The lamp was converted to electricity in 1931."
        var text = try String(contentsOf: lighthouse, encoding: .utf8)
        text += "\n\(appended)\n"
        try text.write(to: lighthouse, atomically: true, encoding: .utf8)

        scanAndIngestAgain()

        open(section: "status")
        waitForStatusFigure("documents", toRead: FixtureCorpus.indexedWithoutCode.count + 1)
        waitForStatusFigure("chunks", toRead: FixtureCorpus.chunksWithoutCode + 1)

        open(section: "documents")
        assertCount(documentsCount(FixtureCorpus.indexedWithoutCode.count + 1))
        XCTAssertTrue(element(text: "The Marrowgate Ferry").exists, "Documents does not list the new note")
        select(FixtureCorpus.lighthouse)
        XCTAssertTrue(element(textContaining: "converted to electricity in 1931").waitForExistence(timeout: 10),
                      "the lighthouse's chunk does not show the sentence added to it")
        XCTAssertTrue(element(textContaining: FixtureCorpus.lighthouse.token).exists, "the lighthouse lost its original text")
    }
}

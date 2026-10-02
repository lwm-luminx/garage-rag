import XCTest

/// The paths that need a model, end to end: embedding the ingested fixture corpus and watching the
/// Status page count it, a search that finds each file by its token and opens the hit, fact
/// distillation and the Facts page, the MCP Server page's Try It, and the menu bar's Ask Garage.
///
/// The host is `GarageApp_uitest`, whose engine and model `ModelUITestCase` describes.
final class ModelUITests: ModelUITestCase {

    // MARK: - Embedding and search

    /// What the Search page shows in place of the expected first hit, for a failure message.
    private func firstHitDescription() -> String {
        let first = element(identifier: "search.result.1.title")
        if first.exists {
            return "first hit: \(shownText(of: first))"
        }
        let error = element(identifier: "search.error")
        return error.exists ? "error: \(shownText(of: error))" : "no results"
    }

    /// Embed All moves the Status page's Indexed figure from 0% to 100%; then a search for each
    /// file's token ranks that file first, and clicking another hit opens it in the inspector.
    func testEmbedAllThenSearchFindsEachFileByItsToken() throws {
        try ingestAndEmbed()
        open(section: "search")

        let first = element(identifier: "search.result.1.title")
        let detail = element(identifier: "search.detail.title")
        for document in FixtureCorpus.indexedWithoutCode {
            submit(document.token, in: "search.query")
            XCTAssertTrue(
                waitUntil(timeout: 60) { first.exists && self.shownText(of: first) == document.title },
                "searching \(document.token) did not rank \(document.file) first (\(firstHitDescription()))"
            )
            // The first hit opens by itself; the inspector shows it with the chunk holding the token.
            XCTAssertTrue(waitUntil(timeout: 10) { detail.exists && self.shownText(of: detail) == document.title },
                          "the inspector does not show the first hit for \(document.token)")
            let text = element(identifier: "search.detail.text")
            XCTAssertTrue(text.exists && shownText(of: text).contains(document.token),
                          "the inspector's content for \(document.token) does not contain it")
        }

        // Every chunk is embedded, so a hybrid search lists every chunk, not just the one keyword
        // match; clicking a hit from another file opens that one instead.
        submit(FixtureCorpus.quillonBridge.token, in: "search.query")
        XCTAssertTrue(waitUntil(timeout: 60) { first.exists && self.shownText(of: first) == FixtureCorpus.quillonBridge.title },
                      "searching \(FixtureCorpus.quillonBridge.token) again did not rank the Markdown note first")
        let status = element(identifier: "search.status")
        let expectedStatus = "\(FixtureCorpus.chunksWithoutCode) results for '\(FixtureCorpus.quillonBridge.token)'"
        XCTAssertTrue(waitUntil(timeout: 10) { status.exists && self.shownText(of: status) == expectedStatus },
                      "the footer does not say \"\(expectedStatus)\" (\(status.exists ? shownText(of: status) : "missing"))")
        let other = (2...FixtureCorpus.chunksWithoutCode)
            .map { element(identifier: "search.result.\($0).title") }
            .first { $0.exists && shownText(of: $0) != FixtureCorpus.quillonBridge.title }
        let hit = try XCTUnwrap(other, "no hit from another file among the results")
        let otherTitle = shownText(of: hit)
        hit.click()
        XCTAssertTrue(waitUntil(timeout: 10) { self.shownText(of: detail) == otherTitle },
                      "clicking the hit for \(otherTitle) did not open it (the inspector shows \(shownText(of: detail)))")
    }

    // MARK: - Facts

    /// Glean Facts distills every document; the Facts page lists what it produced, searches it, and
    /// filters it by kind and by corpus class, and a fact's detail shows the passage it came from.
    func testGleanFactsThenBrowseThemOnTheFactsPage() throws {
        try launchApp()
        waitForBackend()
        try ingestFixtureCorpus()
        gleanFacts()

        open(section: "facts")
        let count = element(identifier: "facts.count")
        // The engine's facts and the mail's sender, recipient and subject, read from its headers.
        let total = FixtureCorpus.gleanedFacts
        func assertCount(_ shown: Int, of all: Int, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
            let expected = "\(shown) of \(all) fact\(all == 1 ? "" : "s")"
            XCTAssertTrue(
                waitUntil(timeout: 30) { count.exists && self.shownText(of: count) == expected },
                "\(what): the Facts page does not say \"\(expected)\" (\(count.exists ? shownText(of: count) : "no count"))",
                file: file,
                line: line
            )
        }
        // The page may have loaded before the run ended; Refresh reads the facts again.
        let refresh = element(identifier: "facts.refresh")
        XCTAssertTrue(refresh.waitForExistence(timeout: 15), "no Refresh button")
        click(refresh)
        assertCount(total, of: total, "after Glean Facts")

        // The one fact that carries the Markdown note's token, grounded in the note's text.
        submit(FixtureCorpus.quillonBridge.token, in: "facts.search")
        assertCount(1, of: 1, "searching \(FixtureCorpus.quillonBridge.token)")
        let row = element(identifier: "facts.row.fact")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no fact row")
        XCTAssertEqual(shownText(of: row), FixtureCorpus.zorvexineFact)
        row.click()
        let detail = element(identifier: "facts.detail.fact")
        XCTAssertTrue(detail.waitForExistence(timeout: 10), "selecting the fact showed no detail")
        XCTAssertEqual(shownText(of: detail), FixtureCorpus.zorvexineFact)
        XCTAssertEqual(shownText(of: element(identifier: "facts.detail.document")), FixtureCorpus.quillonBridge.title,
                       "the detail does not name the fact's document")
        let grounded = element(identifier: "facts.detail.grounded")
        XCTAssertTrue(grounded.exists, "the fact has no grounded excerpt")
        let excerpt = shownText(of: grounded)
        XCTAssertTrue(excerpt.contains(FixtureCorpus.zorvexineFact), "the excerpt does not hold the fact: \(excerpt)")
        XCTAssertTrue(excerpt.contains("Adela Morcombe"), "the excerpt shows none of the text before the fact: \(excerpt)")

        // Clearing the search and picking a kind lists only that kind; events carry their year.
        submit("", in: "facts.search")
        assertCount(total, of: total, "with the search cleared")
        choose("Event", in: "facts.kind")
        assertCount(FixtureCorpus.distilledEvents, of: FixtureCorpus.distilledEvents, "with Kind Event")
        // (Rows scrolled out of view need not be in the accessibility tree, so the footer counts.)
        let rows = app.descendants(matching: .any).matching(identifier: "facts.row.fact")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10), "Kind Event lists no rows")
        rows.firstMatch.click()
        let year = element(identifier: "facts.detail.attribute.year")
        XCTAssertTrue(year.waitForExistence(timeout: 10), "an event shows no year attribute")
        XCTAssertTrue(shownText(of: detail).contains(shownText(of: year)), "the event's year is not in its text")

        // Back to every kind, then only communications: the mail's facts.
        choose("All Kinds", in: "facts.kind")
        assertCount(total, of: total, "with every kind again")
        choose("Communication", in: "facts.class")
        assertCount(FixtureCorpus.gleanedFromMail, of: FixtureCorpus.gleanedFromMail, "with Class Communication")
        rows.firstMatch.click()
        XCTAssertTrue(
            waitUntil(timeout: 10) { self.shownText(of: element(identifier: "facts.detail.document")) == FixtureCorpus.lanternFestival.title },
            "a communication's fact does not come from the mail"
        )
    }

    // MARK: - MCP Try It

    /// Try It's Ask the Corpus runs rag_ask on the running MCP server: retrieval finds the Markdown
    /// note, the model's answer names it, and the note is the first source. Prompt the Model runs
    /// rag_generate and shows the completion.
    func testTryItAnswersFromTheCorpus() throws {
        try ingestAndEmbed()
        open(section: "mcp")

        let run = element(identifier: "mcp.try.run")
        XCTAssertTrue(run.waitForExistence(timeout: 15), "the MCP Server page has no Try It")
        replaceText(in: element(identifier: "mcp.try.prompt"), with: "When did the \(FixtureCorpus.quillonBridge.token) arch open?")
        XCTAssertTrue(waitForEnabled(run, timeout: 60), "Run stayed disabled (is the MCP server running?)")
        click(run)

        let answer = element(identifier: "mcp.try.answer")
        let error = element(identifier: "mcp.try.error")
        XCTAssertTrue(
            waitUntil(timeout: 120) { answer.exists || error.exists },
            "Ask the Corpus produced neither an answer nor an error"
        )
        XCTAssertFalse(error.exists, "rag_ask failed: \(error.exists ? shownText(of: error) : "")")
        XCTAssertTrue(shownText(of: answer).contains(FixtureCorpus.quillonBridge.title),
                      "the answer does not name the Markdown note: \(shownText(of: answer))")
        let citation = element(identifier: "mcp.try.citation.1.title")
        XCTAssertTrue(citation.exists, "the answer lists no sources")
        XCTAssertEqual(shownText(of: citation), FixtureCorpus.quillonBridge.title, "the first source is not the Markdown note")

        let mode = element(identifier: "mcp.try.mode").radioButtons
            .matching(NSPredicate(format: "label == %@ OR title == %@", "Prompt the Model", "Prompt the Model")).firstMatch
        XCTAssertTrue(mode.waitForExistence(timeout: 10), "no Prompt the Model segment")
        mode.click()
        XCTAssertTrue(waitUntil(timeout: 10) { !answer.exists }, "switching modes kept the old answer")
        replaceText(in: element(identifier: "mcp.try.prompt"), with: "Say something about lanterns.")
        XCTAssertTrue(waitForEnabled(run), "Run stayed disabled for a prompt")
        click(run)
        XCTAssertTrue(waitUntil(timeout: 120) { answer.exists || error.exists }, "Prompt the Model produced nothing")
        XCTAssertFalse(error.exists, "rag_generate failed: \(error.exists ? shownText(of: error) : "")")
        XCTAssertTrue(shownText(of: answer).contains("lanterns"), "the completion does not echo the prompt: \(shownText(of: answer))")
    }

    // MARK: - Menu bar Ask Garage

    /// Ask Garage runs rag_agent on the MCP server: it searches the corpus before the model's first
    /// reply, so the Markdown note is among the documents the answer rests on, and the footnote says
    /// it searched and names the model.
    func testMenuBarAskAnswersFromTheCorpus() throws {
        try ingestAndEmbed()
        openPopover()
        XCTAssertTrue(element(identifier: "menubar.allSystemsGo").waitForExistence(timeout: 60), "the popover never said all systems go")

        typeInPopoverField("When did the \(FixtureCorpus.quillonBridge.token) arch open?")
        let ask = element(identifier: "menubar.ask")
        XCTAssertTrue(ask.waitForExistence(timeout: 15), "typing did not offer Ask Garage")
        ask.click()

        let answer = element(identifier: "menubar.ask.answer")
        let error = element(identifier: "menubar.ask.error")
        XCTAssertTrue(waitUntil(timeout: 180) { answer.exists || error.exists }, "Ask Garage produced neither an answer nor an error")
        XCTAssertFalse(error.exists, "rag_agent failed: \(error.exists ? shownText(of: error) : "")")
        XCTAssertFalse(shownText(of: answer).isEmpty, "the answer is empty")

        let citations = app.descendants(matching: .any).matching(identifier: "menubar.ask.citation")
        XCTAssertTrue(waitUntil(timeout: 10) { citations.count > 0 }, "the answer rests on no documents")
        let note = citations.matching(NSPredicate(format: "label CONTAINS %@", FixtureCorpus.quillonBridge.title)).firstMatch
        XCTAssertTrue(note.exists, "the Markdown note is not among the documents the answer rests on")

        let footnote = element(identifier: "menubar.ask.footnote")
        XCTAssertTrue(footnote.exists, "the answer has no footnote")
        XCTAssertTrue(shownText(of: footnote).hasPrefix("Searched"), "the footnote does not say it searched: \(shownText(of: footnote))")
        XCTAssertTrue(shownText(of: footnote).contains(Self.model), "the footnote does not name the model: \(shownText(of: footnote))")
        XCTAssertTrue(button(label: "Copy the answer").exists, "the answer has no Copy button")
    }
}

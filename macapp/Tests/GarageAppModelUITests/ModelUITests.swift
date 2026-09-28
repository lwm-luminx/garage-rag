import XCTest

/// The paths that need a model, end to end: embedding the ingested fixture corpus and watching the
/// Status page count it, a search that finds each file by its token and opens the hit, fact
/// distillation and the Facts page, the MCP Server page's Try It, and the menu bar's Ask Garage.
///
/// The host is `GarageApp_uitest`, whose LlamaXPCService runs `DeterministicLlamaEngine`
/// (`macapp/Tests/LlamaTestSupport`): hashed bag-of-words embeddings, so a query ranks the chunk
/// that shares its word first, and one grounded fact per sentence. The test registers a Llama XPC
/// model of the engine's width through the Models page, with a placeholder GGUF in the models
/// folder for the app's model resolver to find (the engine never reads it), and names the same
/// model as the facts model in the data folder's garage.json.
final class ModelUITests: GarageUITestCase {

    /// The one model: default embedding model and facts model at once, so it loads once.
    static let model = "uitest-deterministic"
    /// `DeterministicLlamaEngine.defaultDimensions`: the registered width must match what the
    /// engine returns, since a prefix of these vectors can be all zeros.
    static let dimensions = 1024

    override func setUpWithError() throws {
        try super.setUpWithError()
        let config: [String: Any] = ["facts": ["model": Self.model, "provider": "llama_xpc"]]
        try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted]).write(to: configFile)

        let models = dataDirectory.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try Data("placeholder: DeterministicLlamaEngine never reads the model file\n".utf8)
            .write(to: models.appendingPathComponent("\(Self.model).gguf"))
    }

    // MARK: - Steps

    /// Picks a tab of the Models page's segmented control (radio buttons titled by segment).
    private func selectModelsTab(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let segment = element(identifier: "models.tab").radioButtons
            .matching(NSPredicate(format: "label == %@ OR title == %@", name, name)).firstMatch
        XCTAssertTrue(segment.waitForExistence(timeout: 10), "no \(name) segment", file: file, line: line)
        segment.click()
    }

    /// Registers the test's Llama XPC model as the default through the custom-model form.
    private func registerModel(file: StaticString = #filePath, line: UInt = #line) {
        open(section: "models", file: file, line: line)
        let manage = element(identifier: "models.overall.manageEmbedding")
        XCTAssertTrue(manage.waitForExistence(timeout: 15), "no Manage button on the Embedding card", file: file, line: line)
        click(manage)
        click(element(identifier: "models.addCustom"))
        let slug = element(identifier: "models.custom.slug")
        XCTAssertTrue(slug.waitForExistence(timeout: 10), "Custom model… did not open the form", file: file, line: line)
        replaceText(in: slug, with: Self.model, file: file, line: line)

        click(element(identifier: "models.custom.provider"))
        // Llama XPC, shown as the built-in engine (`ModelProvider.displayName`).
        let llama = app.menuItems["Built-in engine"]
        XCTAssertTrue(llama.waitForExistence(timeout: 10), "the provider picker offers no built-in engine", file: file, line: line)
        llama.click()

        replaceText(in: element(identifier: "models.custom.dims"), with: String(Self.dimensions), file: file, line: line)
        let makeDefault = element(identifier: "models.custom.makeDefault")
        let isOn = (makeDefault.value as? NSNumber)?.boolValue ?? ((makeDefault.value as? String) == "1")
        if !isOn {
            click(makeDefault)
        }

        let register = element(identifier: "models.custom.register")
        XCTAssertTrue(waitForEnabled(register), "Register stayed disabled", file: file, line: line)
        click(register)
        XCTAssertTrue(
            element(identifier: "models.row.\(Self.model)").waitForExistence(timeout: 30),
            "the model was not listed after Register",
            file: file,
            line: line
        )
    }

    private func waitForStatusFigure(_ name: String, toRead expected: String, timeout: TimeInterval,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let figure = element(identifier: "status.figure.\(name)")
        XCTAssertTrue(
            waitUntil(timeout: timeout) { figure.exists && self.shownText(of: figure) == expected },
            "the Status page's \(name) figure never read \(expected) (\(figure.exists ? shownText(of: figure) : "missing"))",
            file: file,
            line: line
        )
    }

    /// Ingests the corpus, registers the model, and embeds every chunk with Embed All, checking the
    /// Status page's Indexed figure before (0%) and after (100%).
    private func ingestAndEmbed(file: StaticString = #filePath, line: UInt = #line) throws {
        try launchApp()
        waitForBackend(file: file, line: line)
        try ingestFixtureCorpus(file: file, line: line)
        XCTAssertEqual(shownText(of: element(identifier: "status.figure.chunks")), String(FixtureCorpus.chunksWithoutCode),
                       "the Status page does not count the corpus's chunks", file: file, line: line)

        registerModel(file: file, line: line)
        open(section: "status", file: file, line: line)
        waitForStatusFigure("indexed", toRead: "0%", timeout: 30, file: file, line: line)

        open(section: "models", file: file, line: line)
        selectModelsTab("Overall", file: file, line: line)
        let embedAll = element(identifier: "models.embedAll")
        XCTAssertTrue(waitForEnabled(embedAll), "Embed All stayed disabled with a model registered", file: file, line: line)
        click(embedAll)

        open(section: "status", file: file, line: line)
        waitForStatusFigure("indexed", toRead: "100%", timeout: 180, file: file, line: line)
    }

    /// Replaces a plain-style field's text with `text` (empty clears it) and presses Return. Such a
    /// field takes focus only when the click lands on its text area, so the click goes near its
    /// leading edge.
    private func submit(_ text: String, in identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        let field = element(identifier: identifier)
        XCTAssertTrue(field.waitForExistence(timeout: 15), "no field \(identifier)", file: file, line: line)
        let focused = waitUntil(timeout: 15) {
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).click()
            return waitUntil(timeout: 1) { (field.value(forKey: "hasKeyboardFocus") as? Bool) == true }
        }
        XCTAssertTrue(focused, "\(identifier) never took keyboard focus", file: file, line: line)
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(.delete, modifierFlags: [])
        field.typeText(text + "\n")
    }

    /// Picks the item of a pop-up button whose title begins with `prefix` (the Kind picker's items
    /// carry a count, "Event (11)").
    private func choose(_ prefix: String, in identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        let picker = element(identifier: identifier)
        XCTAssertTrue(picker.waitForExistence(timeout: 15), "no picker \(identifier)", file: file, line: line)
        click(picker)
        let item = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", prefix)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10), "\(identifier) offers nothing starting \"\(prefix)\"", file: file, line: line)
        item.click()
    }

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

        open(section: "models")
        selectModelsTab("Overall")
        let glean = element(identifier: "models.gleanFacts")
        XCTAssertTrue(waitForEnabled(glean), "Glean Facts stayed disabled")
        click(glean)
        // Disabled while the run lasts; it may be over before the first look.
        _ = waitUntil(timeout: 10) { !glean.isEnabled }
        XCTAssertTrue(waitForEnabled(glean, timeout: 300), "the distillation run did not finish")

        open(section: "facts")
        let count = element(identifier: "facts.count")
        let total = FixtureCorpus.distilledFacts
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
        assertCount(FixtureCorpus.distilledFromMail, of: FixtureCorpus.distilledFromMail, "with Class Communication")
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

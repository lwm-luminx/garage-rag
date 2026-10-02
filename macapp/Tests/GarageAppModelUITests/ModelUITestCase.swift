import XCTest

/// Base of the model UI tests: every test gets a Llama XPC model registered through the Models page
/// on demand, served by `GarageApp_uitest`'s `DeterministicLlamaEngine`
/// (`macapp/Tests/LlamaTestSupport`): hashed bag-of-words embeddings, so a query ranks the chunk
/// that shares its word first, and one grounded fact per sentence. A placeholder GGUF in the models
/// folder lets the app's model resolver find the model (the engine never reads it), and the data
/// folder's garage.json names the same model as the facts model.
class ModelUITestCase: GarageUITestCase {

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
    func selectModelsTab(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let segment = element(identifier: "models.tab").radioButtons
            .matching(NSPredicate(format: "label == %@ OR title == %@", name, name)).firstMatch
        XCTAssertTrue(segment.waitForExistence(timeout: 10), "no \(name) segment", file: file, line: line)
        segment.click()
    }

    /// Registers the test's Llama XPC model as the default through the custom-model form.
    func registerModel(file: StaticString = #filePath, line: UInt = #line) {
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

    func waitForStatusFigure(_ name: String, toRead expected: String, timeout: TimeInterval,
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
    func ingestAndEmbed(file: StaticString = #filePath, line: UInt = #line) throws {
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
    func submit(_ text: String, in identifier: String, file: StaticString = #filePath, line: UInt = #line) {
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
    func choose(_ prefix: String, in identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        let picker = element(identifier: identifier)
        XCTAssertTrue(picker.waitForExistence(timeout: 15), "no picker \(identifier)", file: file, line: line)
        click(picker)
        let item = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", prefix)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10), "\(identifier) offers nothing starting \"\(prefix)\"", file: file, line: line)
        item.click()
    }

    /// Runs Glean Facts from the Models page and waits for the run to end.
    func gleanFacts(file: StaticString = #filePath, line: UInt = #line) {
        open(section: "models", file: file, line: line)
        selectModelsTab("Overall", file: file, line: line)
        let glean = element(identifier: "models.gleanFacts")
        XCTAssertTrue(waitForEnabled(glean), "Glean Facts stayed disabled", file: file, line: line)
        click(glean)
        // Disabled while the run lasts; it may be over before the first look.
        _ = waitUntil(timeout: 10) { !glean.isEnabled }
        XCTAssertTrue(waitForEnabled(glean, timeout: 300), "the distillation run did not finish", file: file, line: line)
    }

    /// Ingests the corpus, gleans its facts, registers the model and embeds every chunk, the facts'
    /// own included, then runs the Facts page's Distill Facts, which groups the facts and rebuilds
    /// the graph. Leaves the Facts page open.
    func ingestGleanEmbedAndDistill(file: StaticString = #filePath, line: UInt = #line) throws {
        try launchApp()
        waitForBackend(file: file, line: line)
        try ingestFixtureCorpus(file: file, line: line)
        gleanFacts(file: file, line: line)

        registerModel(file: file, line: line)
        open(section: "models", file: file, line: line)
        selectModelsTab("Overall", file: file, line: line)
        let embedAll = element(identifier: "models.embedAll")
        XCTAssertTrue(waitForEnabled(embedAll), "Embed All stayed disabled with a model registered", file: file, line: line)
        click(embedAll)
        // Disabled while the backfill runs, the facts' chunks included, which Distill Facts compares.
        _ = waitUntil(timeout: 10) { !embedAll.isEnabled }
        XCTAssertTrue(waitForEnabled(embedAll, timeout: 300), "Embed All did not finish", file: file, line: line)
        open(section: "status", file: file, line: line)
        waitForStatusFigure("indexed", toRead: "100%", timeout: 60, file: file, line: line)

        open(section: "facts", file: file, line: line)
        let distill = element(identifier: "facts.distill")
        XCTAssertTrue(waitForEnabled(distill), "Distill Facts stayed disabled", file: file, line: line)
        click(distill)
        _ = waitUntil(timeout: 10) { !distill.isEnabled }
        XCTAssertTrue(waitForEnabled(distill, timeout: 300), "Distill Facts did not finish", file: file, line: line)
    }
}

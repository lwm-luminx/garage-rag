import XCTest

/// The Models page's tabs on an empty registry. Nothing is registered, downloaded or loaded: the
/// preset Add buttons and Embed All are left alone. The Inference tab's choice is written to this
/// test's own garage.json.
final class ModelsUITests: GarageUITestCase {

    /// Picks a tab in the segmented control, which macOS exposes as radio buttons titled by segment.
    private func selectTab(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let segment = element(identifier: "models.tab").radioButtons
            .matching(NSPredicate(format: "label == %@ OR title == %@", name, name)).firstMatch
        XCTAssertTrue(segment.waitForExistence(timeout: 10), "no \(name) segment", file: file, line: line)
        segment.click()
    }

    func testOverallShowsEachKindOfModel() throws {
        try launchApp()
        waitForBackend()
        open(section: "models")

        XCTAssertTrue(element(identifier: "models.tab").waitForExistence(timeout: 15), "no tab control")
        for heading in ["Embedding", "Fact Distillation", "Providers"] {
            XCTAssertTrue(element(text: heading).waitForExistence(timeout: 15), "Overall does not show \"\(heading)\"")
        }
        XCTAssertTrue(element(text: "No embedding model").waitForExistence(timeout: 30), "an empty registry does not say there is no embedding model")
        // An empty garage.json still names a facts model, the default gemma2-2b preset, whose file a new
        // data folder does not have: the card names the model and says it is not downloaded.
        XCTAssertTrue(element(text: "Gemma 2 2B Instruct").exists, "the Fact Distillation card does not name the default facts model")
        XCTAssertTrue(
            element(text: "Not downloaded · via Built-in engine.").exists,
            "the Fact Distillation card does not say the default facts model is not downloaded"
        )
        XCTAssertFalse(element(text: "No distillation model").exists, "the card says there is no facts model although one is named")
        XCTAssertTrue(element(text: "Built-in engine").exists, "Providers does not list the built-in engine")
        XCTAssertTrue(element(identifier: "models.overall.manageEmbedding").exists, "the Embedding card has no Manage button")
        XCTAssertTrue(element(identifier: "models.overall.manageDistillation").exists, "the Fact Distillation card has no Manage button")
        // Tab contents stay on their tabs.
        XCTAssertFalse(element(text: "Text Embedding Models").exists, "Overall shows the Embedding tab's list")
        XCTAssertFalse(element(text: "Fact Prompts").exists, "Overall shows the Distillation tab's prompts")
    }

    func testManageButtonsAndTheSegmentsSwitchTabs() throws {
        try launchApp()
        waitForBackend()
        open(section: "models")

        let manageEmbedding = element(identifier: "models.overall.manageEmbedding")
        XCTAssertTrue(manageEmbedding.waitForExistence(timeout: 15), "no Manage button on the Embedding card")
        click(manageEmbedding)
        XCTAssertTrue(element(text: "Text Embedding Models").waitForExistence(timeout: 10), "Manage did not open the Embedding tab")
        XCTAssertTrue(element(text: "No embedding model yet").waitForExistence(timeout: 30), "the Embedding tab does not say the registry is empty")
        XCTAssertTrue(element(identifier: "models.addCustom").exists, "the Embedding tab offers no custom model")
        XCTAssertFalse(element(identifier: "models.overall.manageEmbedding").exists, "the Overall cards stayed on the Embedding tab")

        // The custom-model form is folded away until asked for.
        XCTAssertFalse(element(identifier: "models.custom.slug").exists, "the custom model form is open before anyone asked for it")
        click(element(identifier: "models.addCustom"))
        XCTAssertTrue(element(identifier: "models.custom.slug").waitForExistence(timeout: 10), "Custom model… did not open the form")
        let register = element(identifier: "models.custom.register")
        XCTAssertTrue(register.exists, "the custom model form has no Register button")
        XCTAssertFalse(register.isEnabled, "Register is enabled with an empty form")

        selectTab("Overall")
        XCTAssertTrue(element(identifier: "models.overall.manageDistillation").waitForExistence(timeout: 10), "the Overall segment did not go back")
        click(element(identifier: "models.overall.manageDistillation"))
        XCTAssertTrue(element(text: "Fact Distillation Model").waitForExistence(timeout: 10), "Manage did not open the Distillation tab")
        XCTAssertTrue(element(text: "Fact Prompts").waitForExistence(timeout: 10), "the Distillation tab does not list the prompts")
        XCTAssertFalse(element(text: "Text Embedding Models").exists, "the Embedding list stayed on the Distillation tab")

        selectTab("Embedding")
        XCTAssertTrue(element(text: "Text Embedding Models").waitForExistence(timeout: 10), "the Embedding segment did not switch tabs")
        XCTAssertFalse(element(text: "Fact Prompts").exists, "the prompts stayed on the Embedding tab")
    }

    // MARK: - Inference

    /// A badge (TOOLS, IN USE, CHAT ONLY) in a model's row.
    private func badge(_ text: String, inRow slug: String) -> XCUIElement {
        element(identifier: "models.row.\(slug)").descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR value == %@", text, text)).firstMatch
    }

    /// `inference.model` in this test's garage.json, or "" when it is unset.
    private func configuredInferenceModel() -> String {
        guard let data = try? Data(contentsOf: configFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inference = object["inference"] as? [String: Any] else { return "" }
        return inference["model"] as? String ?? ""
    }

    /// With no inference model chosen, the distillation model answers chat. Use for Inference names
    /// a model in garage.json and marks its row, and Follow Distillation clears it again.
    func testInferenceTabChoosesAModelAndFollowsDistillationAgain() throws {
        try launchApp()
        waitForBackend()
        open(section: "models")
        XCTAssertFalse(element(text: "Inference Model").exists, "Overall shows the Inference tab's list")

        selectTab("Inference")
        XCTAssertTrue(element(text: "Inference Model").waitForExistence(timeout: 10), "the Inference segment did not switch tabs")
        XCTAssertFalse(element(text: "Fact Prompts").exists, "the Distillation tab's prompts stayed on the Inference tab")
        XCTAssertTrue(
            element(textContaining: "None is chosen, so the distillation model (gemma2-2b) answers.").waitForExistence(timeout: 15),
            "the Inference tab does not say the distillation model answers"
        )
        let follow = element(identifier: "models.inference.followDistillation")
        XCTAssertTrue(follow.exists, "the Inference tab has no Follow Distillation")
        XCTAssertFalse(follow.isEnabled, "Follow Distillation is enabled with nothing chosen")

        // An inference-only preset is listed here, and tool-calling models carry TOOLS.
        let chosen = "llama-3.2-1b-instruct"
        XCTAssertTrue(element(identifier: "models.row.gpt-oss-20b").waitForExistence(timeout: 15), "the Inference tab does not list gpt-oss-20b")
        XCTAssertTrue(element(identifier: "models.row.\(chosen)").exists, "the Inference tab does not list \(chosen)")
        XCTAssertTrue(badge("TOOLS", inRow: chosen).exists, "\(chosen) has no TOOLS badge")
        XCTAssertFalse(badge("TOOLS", inRow: "gemma2-2b").exists, "gemma2-2b, which calls no tools, has a TOOLS badge")
        XCTAssertFalse(badge("IN USE", inRow: chosen).exists, "\(chosen) is in use before it was chosen")
        // Nothing chosen: the distillation model's row is the one in use.
        XCTAssertTrue(badge("IN USE", inRow: "gemma2-2b").exists, "the distillation model is not marked IN USE for chat")

        let use = element(identifier: "models.row.\(chosen)").buttons
            .matching(NSPredicate(format: "label == %@ OR title == %@", "Use for Inference", "Use for Inference")).firstMatch
        XCTAssertTrue(waitForEnabled(use), "Use for Inference stayed disabled")
        click(use)
        XCTAssertTrue(
            element(textContaining: "In use: \(chosen).").waitForExistence(timeout: 30),
            "the summary does not name the chosen model"
        )
        XCTAssertTrue(waitUntil(timeout: 10) { self.badge("IN USE", inRow: chosen).exists }, "the chosen row is not marked IN USE")
        XCTAssertEqual(configuredInferenceModel(), chosen, "garage.json does not name the inference model")
        XCTAssertFalse(badge("IN USE", inRow: "gemma2-2b").exists, "the distillation model stayed IN USE beside the chosen one")
        XCTAssertFalse(use.isEnabled, "Use for Inference stayed enabled on the model in use")

        XCTAssertTrue(waitForEnabled(follow), "Follow Distillation stayed disabled with a model chosen")
        click(follow)
        XCTAssertTrue(
            element(textContaining: "None is chosen, so the distillation model (gemma2-2b) answers.").waitForExistence(timeout: 30),
            "Follow Distillation did not hand chat back to the distillation model"
        )
        XCTAssertTrue(waitUntil(timeout: 10) { self.configuredInferenceModel().isEmpty }, "garage.json still names \(configuredInferenceModel())")
    }

    /// The Distillation tab lists the inference-only presets last, marked CHAT ONLY.
    func testDistillationTabMarksChatOnlyModels() throws {
        try launchApp()
        waitForBackend()
        open(section: "models")
        selectTab("Distillation")

        XCTAssertTrue(element(identifier: "models.row.gpt-oss-20b").waitForExistence(timeout: 15), "the Distillation tab does not list gpt-oss-20b")
        XCTAssertTrue(badge("CHAT ONLY", inRow: "gpt-oss-20b").exists, "an inference-only model is not marked CHAT ONLY")
        XCTAssertFalse(badge("CHAT ONLY", inRow: "gemma2-2b").exists, "a distillation model is marked CHAT ONLY")
        XCTAssertTrue(badge("IN USE", inRow: "gemma2-2b").exists, "the default facts model is not marked IN USE")
    }
}

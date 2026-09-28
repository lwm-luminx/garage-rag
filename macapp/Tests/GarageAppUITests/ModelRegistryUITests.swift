import XCTest

/// Registering custom embedding models, moving the default between them and removing one. The
/// models are Ollama entries with explicit dimensions: registering one only writes the throwaway
/// database (no catalog lookup, no download, no model server), and the app loads nothing for a
/// provider other than Llama XPC.
final class ModelRegistryUITests: GarageUITestCase {

    private func row(_ slug: String) -> XCUIElement { element(identifier: "models.row.\(slug)") }

    /// Whether `slug`'s row carries the DEFAULT tag.
    private func isDefault(_ slug: String) -> Bool {
        row(slug).descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR value == %@", "DEFAULT", "DEFAULT"))
            .firstMatch.exists
    }

    /// Fills the custom-model form (already open) and registers an Ollama model of `dims` dimensions.
    private func registerOllamaModel(_ slug: String, dims: Int, makeDefault: Bool, file: StaticString = #filePath, line: UInt = #line) {
        replaceText(in: element(identifier: "models.custom.slug"), with: slug, file: file, line: line)

        let provider = element(identifier: "models.custom.provider")
        XCTAssertTrue(provider.exists, "the form has no provider picker", file: file, line: line)
        click(provider)
        let ollama = app.menuItems["Ollama"]
        XCTAssertTrue(ollama.waitForExistence(timeout: 10), "the provider picker offers no Ollama", file: file, line: line)
        ollama.click()

        replaceText(in: element(identifier: "models.custom.dims"), with: String(dims), file: file, line: line)

        let checkbox = element(identifier: "models.custom.makeDefault")
        XCTAssertTrue(checkbox.exists, "the form has no default checkbox", file: file, line: line)
        let isOn = (checkbox.value as? NSNumber)?.boolValue ?? ((checkbox.value as? String) == "1")
        if isOn != makeDefault {
            click(checkbox)
        }

        let register = element(identifier: "models.custom.register")
        XCTAssertTrue(waitForEnabled(register), "Register stayed disabled", file: file, line: line)
        click(register)
        XCTAssertTrue(row(slug).waitForExistence(timeout: 30), "the model \(slug) was not listed after Register", file: file, line: line)
    }

    /// Picks `title` in the row's actions menu.
    private func chooseFromMenu(of slug: String, _ title: String, file: StaticString = #filePath, line: UInt = #line) {
        let menu = element(identifier: "models.row.\(slug).menu")
        XCTAssertTrue(menu.exists, "the \(slug) row has no actions menu", file: file, line: line)
        click(menu)
        let item = app.menuItems[title]
        XCTAssertTrue(item.waitForExistence(timeout: 10), "the \(slug) menu has no \"\(title)\"", file: file, line: line)
        XCTAssertTrue(item.isEnabled, "\"\(title)\" is disabled for \(slug)", file: file, line: line)
        item.click()
    }

    func testRegisterSetDefaultAndRemoveCustomModels() throws {
        try launchApp()
        waitForBackend()
        open(section: "models")

        let manage = element(identifier: "models.overall.manageEmbedding")
        XCTAssertTrue(manage.waitForExistence(timeout: 15), "no Manage button on the Embedding card")
        click(manage)
        XCTAssertTrue(element(text: "No embedding model yet").waitForExistence(timeout: 30), "the registry is not empty to begin with")
        click(element(identifier: "models.addCustom"))
        XCTAssertTrue(element(identifier: "models.custom.slug").waitForExistence(timeout: 10), "Custom model… did not open the form")

        registerOllamaModel("uitest-first", dims: 8, makeDefault: true)
        XCTAssertTrue(waitUntil(timeout: 15) { self.isDefault("uitest-first") }, "the model registered as default is not tagged DEFAULT")
        XCTAssertFalse(element(text: "No embedding model yet").exists, "the empty state stayed after registering a model")

        registerOllamaModel("uitest-second", dims: 16, makeDefault: false)
        XCTAssertFalse(isDefault("uitest-second"), "a model registered without the checkbox is tagged DEFAULT")
        XCTAssertTrue(isDefault("uitest-first"), "registering a second model moved the default")

        chooseFromMenu(of: "uitest-second", "Set as Default")
        XCTAssertTrue(waitUntil(timeout: 30) { self.isDefault("uitest-second") }, "Set as Default did not tag the second model")
        XCTAssertTrue(waitUntil(timeout: 10) { !self.isDefault("uitest-first") }, "the first model kept its DEFAULT tag")

        chooseFromMenu(of: "uitest-first", "Remove from Database")
        XCTAssertTrue(waitUntil(timeout: 30) { !self.row("uitest-first").exists }, "Remove from Database left the first model listed")
        XCTAssertTrue(row("uitest-second").exists, "removing one model removed the other")
        XCTAssertTrue(isDefault("uitest-second"), "removing another model moved the default")
    }
}

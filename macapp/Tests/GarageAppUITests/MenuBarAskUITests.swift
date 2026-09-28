import XCTest

/// "Ask Garage" in the menu bar popover: the row under the search field that sends the text to
/// `rag_agent` on the MCP server. No model is set up here (a new data folder names the default facts
/// model, whose file it does not have), so an ask ends in an error the popover shows; the answer
/// itself, with its citations, is ModelUITests' `testMenuBarAskAnswersFromTheCorpus`.
final class MenuBarAskUITests: GarageUITestCase {

    /// With the HTTP server up, the field invites a question and typing offers Ask Garage first.
    func testTypingOffersAskGarage() throws {
        try launchApp()
        waitForBackend()
        openPopover()
        XCTAssertTrue(element(identifier: "menubar.allSystemsGo").waitForExistence(timeout: 60), "the popover never said all systems go")

        let field = element(identifier: "menubar.search.field")
        XCTAssertTrue(waitForEnabled(field), "the popover's search field stayed disabled with the database up")
        XCTAssertTrue(
            waitUntil(timeout: 30) { field.placeholderValue == "Search or ask your corpus" },
            "the field's placeholder is \"\(field.placeholderValue ?? "nil")\" with the MCP server up"
        )
        XCTAssertFalse(element(identifier: "menubar.ask").exists, "Ask Garage shows before anything is typed")

        typeInPopoverField("where is the lantern festival")
        let ask = element(identifier: "menubar.ask")
        XCTAssertTrue(ask.waitForExistence(timeout: 15), "typing did not offer Ask Garage")
        XCTAssertTrue(shownText(of: ask).contains("Ask Garage"), "the ask row reads \"\(shownText(of: ask))\"")
        XCTAssertFalse(element(identifier: "menubar.ask.result").exists, "an answer shows before anyone asked")

        // Clearing the field takes the row away again.
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(waitUntil(timeout: 10) { !ask.exists }, "Ask Garage stayed with an empty field")
    }

    /// Clicking Ask Garage shows the question with its outcome under the field (an error here, with
    /// no model file), and Dismiss takes it away while the query stays.
    func testAskShowsItsOutcomeAndDismissClearsIt() throws {
        try launchApp()
        waitForBackend()
        openPopover()
        XCTAssertTrue(element(identifier: "menubar.allSystemsGo").waitForExistence(timeout: 60), "the popover never said all systems go")

        let question = "what did the quillon bridge replace"
        typeInPopoverField(question)
        let ask = element(identifier: "menubar.ask")
        XCTAssertTrue(ask.waitForExistence(timeout: 15), "typing did not offer Ask Garage")
        ask.click()

        let result = element(identifier: "menubar.ask.result")
        XCTAssertTrue(result.waitForExistence(timeout: 10), "Ask Garage showed nothing")
        let heading = result.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR value == %@", question, question)).firstMatch
        XCTAssertTrue(heading.exists, "the answer box does not repeat the question")

        let answer = element(identifier: "menubar.ask.answer")
        let error = element(identifier: "menubar.ask.error")
        XCTAssertTrue(
            waitUntil(timeout: 240) { answer.exists || error.exists },
            "the ask never ended in an answer or an error"
        )
        if error.exists {
            XCTAssertFalse(shownText(of: error).isEmpty, "the ask failed with an empty message")
        }
        XCTAssertFalse(element(identifier: "menubar.ask.stop").exists, "Stop stayed after the ask ended")

        let dismiss = button(label: "Dismiss the answer")
        XCTAssertTrue(dismiss.waitForExistence(timeout: 10), "the finished answer has no Dismiss button")
        dismiss.click()
        XCTAssertTrue(waitUntil(timeout: 10) { !result.exists }, "Dismiss left the answer up")
        XCTAssertEqual(element(identifier: "menubar.search.field").value as? String, question, "Dismiss cleared the query too")
    }

    /// Shift-Return asks, where Return alone opens the Search page (MenuBarUITests).
    func testShiftReturnAsksInsteadOfSearching() throws {
        try launchApp()
        waitForBackend()
        open(section: "status")
        openPopover()
        XCTAssertTrue(element(identifier: "menubar.allSystemsGo").waitForExistence(timeout: 60), "the popover never said all systems go")

        typeInPopoverField("lanterns")
        XCTAssertTrue(element(identifier: "menubar.ask").waitForExistence(timeout: 15), "typing did not offer Ask Garage")
        element(identifier: "menubar.search.field").typeKey(.return, modifierFlags: .shift)

        XCTAssertTrue(element(identifier: "menubar.ask.result").waitForExistence(timeout: 10), "Shift-Return did not ask")
        XCTAssertFalse(element(identifier: "search.query").exists, "Shift-Return opened the Search page")
    }
}

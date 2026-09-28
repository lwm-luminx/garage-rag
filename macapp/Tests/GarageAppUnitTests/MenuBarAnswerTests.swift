import XCTest
@testable import GarageApp

final class MenuBarAnswerTests: XCTestCase {

    private let sample = """
    {
      "answer": "Widgets ship on Tuesdays, per the User Guide.",
      "model": "gemma2-2b",
      "provider": "llama_xpc",
      "question": "when do widgets ship?",
      "steps": [
        {"n": 1, "tool": "rag_search", "arguments": {"query": "widgets"}, "summary": "Searched for “widgets”: 3 hits", "ok": true},
        {"n": 2, "tool": "rag_get_document", "arguments": {"document_id": 10}, "summary": "Read User Guide", "ok": true},
        {"n": 3, "tool": "rag_get_document", "arguments": {"document_id": 99}, "summary": "rag_get_document failed", "ok": false}
      ],
      "citations": [
        {"n": 1, "document_id": 10, "title": "User Guide", "location": "~/docs/guide.md", "snippet": "Widgets ship…", "corpus_class": "document"},
        {"n": 2, "document_id": 11, "title": null, "location": "~/code/ship.py", "snippet": "", "corpus_class": "code"}
      ],
      "prompt_tokens": 900,
      "completion_tokens": 40
    }
    """

    func testParsesTheToolResult() throws {
        let answer = try XCTUnwrap(MenuBarAnswer.parse(sample))
        XCTAssertEqual(answer.answer, "Widgets ship on Tuesdays, per the User Guide.")
        XCTAssertEqual(answer.model, "gemma2-2b")
        XCTAssertEqual(answer.question, "when do widgets ship?")
        XCTAssertEqual(answer.steps.map(\.tool), ["rag_search", "rag_get_document", "rag_get_document"])
        XCTAssertEqual(answer.steps.map(\.ok), [true, true, false])
        XCTAssertEqual(answer.citations.map(\.documentId), [10, 11])
        XCTAssertEqual(answer.citations[1].title, nil)
    }

    func testParseRejectsWhatIsNotAnAnswer() {
        XCTAssertNil(MenuBarAnswer.parse("Tool call failed: local model is not available"))
        XCTAssertNil(MenuBarAnswer.parse("{\"text\": \"pong\"}"))
        XCTAssertNil(MenuBarAnswer.parse("{\"answer\": \"   \"}"))
        XCTAssertNil(MenuBarAnswer.parse(""))
    }

    func testMissingOptionalFieldsHaveDefaults() throws {
        let answer = try XCTUnwrap(MenuBarAnswer.parse("{\"answer\": \"Nothing in the corpus says.\"}"))
        XCTAssertEqual(answer.model, "")
        XCTAssertEqual(answer.steps, [])
        XCTAssertEqual(answer.citations, [])
        XCTAssertEqual(answer.footnote, "Answered without searching")
    }

    func testFootnoteCountsTheStepsThatWorked() throws {
        let answer = try XCTUnwrap(MenuBarAnswer.parse(sample))
        // The failed read is not counted.
        XCTAssertEqual(answer.footnote, "Searched once and read 1 document · gemma2-2b")

        let steps = [
            MenuBarAnswer.Step(n: 1, tool: "rag_search", summary: ""),
            MenuBarAnswer.Step(n: 2, tool: "rag_search", summary: ""),
            MenuBarAnswer.Step(n: 3, tool: "rag_stats", summary: ""),
            MenuBarAnswer.Step(n: 4, tool: "rag_get_document", summary: ""),
            MenuBarAnswer.Step(n: 5, tool: "rag_get_document", summary: ""),
            MenuBarAnswer.Step(n: 6, tool: "rag_get_document", summary: ""),
        ]
        let busy = MenuBarAnswer(answer: "a", model: "m", provider: "p", question: "q", steps: steps)
        XCTAssertEqual(busy.footnote, "Searched twice, read 3 documents and looked up the corpus once · m")

        let searches = MenuBarAnswer(answer: "a", model: "", provider: "p", question: "q", steps: Array(steps[0...1]))
        XCTAssertEqual(searches.footnote, "Searched twice")
    }

    func testCitationTitleFallsBackToTheFileName() {
        let titled = MenuBarAnswer.Citation(n: 1, documentId: 1, title: "User Guide", location: "~/docs/guide.md", snippet: "", corpusClass: "document")
        XCTAssertEqual(titled.displayTitle, "User Guide")
        let untitled = MenuBarAnswer.Citation(n: 2, documentId: 2, title: nil, location: "~/code/ship.py", snippet: "", corpusClass: "code")
        XCTAssertEqual(untitled.displayTitle, "ship.py")
        let blank = MenuBarAnswer.Citation(n: 3, documentId: 3, title: "  ", location: "", snippet: "", corpusClass: "document")
        XCTAssertEqual(blank.displayTitle, "Untitled")
    }

    func testCitationFileURLExpandsTheHomeFolder() {
        let citation = MenuBarAnswer.Citation(n: 1, documentId: 1, title: nil, location: "~/docs/guide.md", snippet: "", corpusClass: "document")
        XCTAssertEqual(citation.fileURL?.path, NSHomeDirectory() + "/docs/guide.md")
        let message = MenuBarAnswer.Citation(n: 2, documentId: 2, title: nil, location: "imessage:chat123", snippet: "", corpusClass: "communication")
        XCTAssertNil(message.fileURL)
    }
}

import GarageAppExtensionKit
import MCPServerClient
import XCTest
@testable import GarageApp

final class ChatPresentationTests: XCTestCase {
    private let local = ChatPresentation.localBackend(model: "gemma-3-4b", displayName: "Gemma 3 4B", provider: "llama_xpc", databaseRunning: true)
    private let cloud = GarageChatBackend(id: "key:openai", title: "OpenAI", detail: "With your key", symbol: "key", leavesThisMac: true)

    private func answered(_ question: String, _ answer: String, by backend: GarageChatBackend) -> ChatExchange {
        ChatExchange(question: question, backend: backend, state: .answered(GarageChatReply(answer: answer, model: "m", provider: "p")))
    }

    func testThisMacsModelIsListedByItsNameAndNeedsTheDatabase() {
        XCTAssertEqual(local.id, ChatPresentation.localBackendID)
        XCTAssertEqual(local.title, "Gemma 3 4B")
        XCTAssertFalse(local.leavesThisMac)
        XCTAssertNil(local.unavailableReason)
        let stopped = ChatPresentation.localBackend(model: "gemma-3-4b", displayName: nil, provider: "ollama", databaseRunning: false)
        XCTAssertEqual(stopped.title, "gemma-3-4b")
        XCTAssertNotNil(stopped.unavailableReason)
        XCTAssertTrue(stopped.detail.contains("Ollama"))
    }

    func testThePickedAnswererHoldsWhileItIsOffered() {
        XCTAssertEqual(ChatPresentation.resolvedBackendID("key:openai", among: [local, cloud]), "key:openai")
        XCTAssertEqual(ChatPresentation.resolvedBackendID("key:openai", among: [local]), "local")
        XCTAssertEqual(ChatPresentation.resolvedBackendID(nil, among: [local, cloud]), "local")
    }

    /// Every answered question goes along; an answer only to the answerer that gave it, since an answer from this
    /// Mac's model may rest on a message.
    func testAnAnswererSeesEveryQuestionButOnlyItsOwnAnswers() {
        let exchanges = [
            answered("Who wrote the lease?", "Dana did.", by: local),
            answered("When was it signed?", "In March.", by: cloud),
            ChatExchange(question: "Never answered", backend: local, state: .failed("no model")),
            ChatExchange(question: "Stopped", backend: local, state: .stopped),
        ]
        XCTAssertEqual(ChatPresentation.history(for: "local", in: exchanges), [
            GarageChatTurn(role: .user, text: "Who wrote the lease?"),
            GarageChatTurn(role: .assistant, text: "Dana did."),
            GarageChatTurn(role: .user, text: "When was it signed?"),
        ])
        XCTAssertEqual(ChatPresentation.history(for: "key:openai", in: exchanges), [
            GarageChatTurn(role: .user, text: "Who wrote the lease?"),
            GarageChatTurn(role: .user, text: "When was it signed?"),
            GarageChatTurn(role: .assistant, text: "In March."),
        ])
        XCTAssertEqual(
            ChatPresentation.ragAgentHistory([GarageChatTurn(role: .user, text: "q")]),
            [["role": "user", "content": "q"]]
        )
    }

    func testARagAgentResultReadsAsAReply() throws {
        let json = """
        {"answer": "Dana signed it in March [1].", "model": "gemma-3-4b", "provider": "llama_xpc", "question": "q",
         "steps": [{"n": 1, "tool": "rag_search", "summary": "Searched for “lease”: 6 hits", "ok": true},
                   {"n": 2, "tool": "rag_get_document", "summary": "Read Lease.pdf", "ok": true},
                   {"n": 3, "tool": "rag_nope", "summary": "No such tool: rag_nope", "ok": false}],
         "citations": [{"n": 1, "document_id": 42, "title": null, "location": "~/Documents/Lease.pdf",
                        "snippet": "This lease", "corpus_class": "document"}]}
        """
        let reply = try XCTUnwrap(ChatPresentation.reply(fromRagAgent: Data(json.utf8)))
        XCTAssertEqual(reply.answer, "Dana signed it in March [1].")
        XCTAssertEqual(reply.steps, ["Searched for “lease”: 6 hits", "Read Lease.pdf"])
        XCTAssertEqual(reply.citations.first?.documentID, 42)
        XCTAssertEqual(ChatPresentation.title(of: try XCTUnwrap(reply.citations.first)), "Lease.pdf")
        XCTAssertEqual(ChatPresentation.footnote(reply), "Searched once and read 1 document · gemma-3-4b on this Mac")
        XCTAssertNil(ChatPresentation.reply(fromRagAgent: Data("Error: no model".utf8)))
        XCTAssertNil(ChatPresentation.reply(fromRagAgent: Data(#"{"answer": "  "}"#.utf8)))
    }

    func testAToolResultPrefersItsTypedRecord() throws {
        let result = GarageMCPToolCaller.toolResult([
            "content": [["type": "text", "text": "{\"answer\": \"x\"}"]],
            "structuredContent": ["answer": "x"],
        ])
        XCTAssertFalse(result.isError)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: result.json) as? [String: String], ["answer": "x"])
        let failed = GarageMCPToolCaller.toolResult(["content": [["type": "text", "text": "no model"]], "isError": true])
        XCTAssertTrue(failed.isError)
        XCTAssertEqual(failed.text, "no model")
        XCTAssertEqual(GarageMCPToolCaller.jsonRPC("event: message\ndata: {\"id\": 3}\n\n")["id"] as? Int, 3)
    }
}

import XCTest
import LlamaClient
import LlamaTestSupport

/// The engine behind the model UI tests' MockLlamaXPCService: what Garage's Python side depends on
/// (embedding width and similarity, LangExtract's answer shape, grounded text) holds here, before a
/// UI test finds out on a Mac.
final class DeterministicLlamaEngineTests: XCTestCase {
    private var engine: DeterministicLlamaEngine!
    private var modelFile: URL!

    override func setUpWithError() throws {
        engine = DeterministicLlamaEngine()
        modelFile = FileManager.default.temporaryDirectory.appendingPathComponent("deterministic-\(UUID().uuidString).gguf")
        try Data("placeholder".utf8).write(to: modelFile)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: modelFile)
    }

    private func route(_ method: String, _ path: String, _ body: [String: Any]? = nil) throws -> (Int, [String: Any]) {
        let json = body.map { LlamaJSON.serialize($0) }
        let result = engine.handleRoute(endpoint: path, method: method, jsonBody: json)
        let data = try XCTUnwrap(result.responseBody.data(using: .utf8))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (result.statusCode, object)
    }

    private func cosine(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    // MARK: - Models

    func testModelsLoadFromExistingFilesOnly() throws {
        XCTAssertEqual(engine.handleHealth()["status"] as? String, "no_model_loaded")
        XCTAssertFalse(engine.loadModel(path: "/nonexistent/model.gguf", alias: "missing", configJson: nil).success)

        XCTAssertTrue(engine.ensureModel(path: modelFile.path, alias: "embedder", configJson: nil).success)
        XCTAssertEqual(engine.ensureModel(path: modelFile.path, alias: "embedder", configJson: nil).message, "embedder is already loaded")
        XCTAssertTrue(engine.loadModel(path: modelFile.path, alias: "distiller", configJson: nil).success)
        XCTAssertEqual(engine.loadedAliases, ["embedder", "distiller"])
        XCTAssertEqual(engine.handleHealth()["status"] as? String, "ok")

        let (status, models) = try route("GET", "/v1/models")
        XCTAssertEqual(status, 200)
        let ids = (models["data"] as? [[String: Any]])?.compactMap { $0["id"] as? String }
        XCTAssertEqual(ids, ["embedder", "distiller"])

        let (unloaded, _) = try route("POST", "/models/unload", ["model": "embedder"])
        XCTAssertEqual(unloaded, 200)
        XCTAssertEqual(engine.loadedAliases, ["distiller"])
        XCTAssertTrue(engine.unloadModel())
        XCTAssertNil(engine.currentModelPath)
    }

    // MARK: - Embeddings

    func testEmbeddingsAreUnitVectorsOfTheEngineWidth() throws {
        let (status, reply) = try route("POST", "/v1/embeddings", ["input": ["The Quillon Bridge opened in 1893.", ""], "model": "anything"])
        XCTAssertEqual(status, 200)
        let data = try XCTUnwrap(reply["data"] as? [[String: Any]])
        XCTAssertEqual(data.count, 2)
        for item in data {
            let vector = try XCTUnwrap(item["embedding"] as? [Double])
            XCTAssertEqual(vector.count, DeterministicLlamaEngine.defaultDimensions)
            XCTAssertEqual(vector.reduce(0) { $0 + $1 * $1 }, 1, accuracy: 1e-4)
        }
        XCTAssertEqual(reply["model"] as? String, "anything")
    }

    func testAQueryRanksTheTextThatSharesItsWordFirst() {
        let bridge = engine.embedding(for: "Townspeople call the middle arch the zorvexine arch.")
        let lighthouse = engine.embedding(for: "Her logbook records the plimbrate storm of 1927.")
        let query = engine.embedding(for: "zorvexine")
        XCTAssertEqual(engine.embedding(for: "zorvexine"), query, "the same text embedded twice differs")
        XCTAssertGreaterThan(cosine(query, bridge), cosine(query, lighthouse))
        XCTAssertGreaterThan(cosine(query, bridge), 0)
    }

    // MARK: - Chat

    /// A LangExtract prompt as `garage_rag.enrich.langextract.prompting` renders it: description,
    /// examples, then the document as the last question and an empty answer.
    private let langExtractPrompt = """
        Extract every standalone fact stated in this document.

        Examples
        Q: Acme Corp was founded in 1998 by Jane Doe. The company has 42 employees.
        A: ```json
        {"extractions": [{"fact": "Acme Corp was founded in 1998 by Jane Doe."}]}
        ```

        Q: # The Quillon Bridge

        The Quillon Bridge opened in 1893 and crosses the river Senn at the town of Harrowby.
        Its engineer, Adela Morcombe, built it from pale limestone quarried at Fenwick Edge.
        Hello,
        A: \("")
        """

    func testALangExtractPromptGetsOneGroundedExtractionPerSentence() throws {
        let answer = engine.reply(to: langExtractPrompt)
        XCTAssertTrue(answer.hasPrefix("```json\n"), answer)
        XCTAssertTrue(answer.hasSuffix("\n```"), answer)
        let json = answer.dropFirst("```json\n".count).dropLast("\n```".count)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let extractions = try XCTUnwrap(object["extractions"] as? [[String: Any]])
        XCTAssertEqual(extractions.count, 2, "the heading, the greeting or the example was extracted: \(extractions)")
        XCTAssertEqual(extractions[0]["event"] as? String,
                       "The Quillon Bridge opened in 1893 and crosses the river Senn at the town of Harrowby.")
        XCTAssertEqual((extractions[0]["event_attributes"] as? [String: String])?["year"], "1893")
        XCTAssertEqual(extractions[1]["fact"] as? String,
                       "Its engineer, Adela Morcombe, built it from pale limestone quarried at Fenwick Edge.")
        XCTAssertNil(extractions[1]["fact_attributes"])
    }

    func testARagAskPromptIsAnsweredFromItsFirstExcerpt() {
        let prompt = """
            Excerpts:

            [1] The Quillon Bridge \u{2014} /tmp/corpus/quillon-bridge.md
            The Quillon Bridge opened in 1893.

            [2] Marrowgate Lighthouse \u{2014} /tmp/corpus/marrowgate-lighthouse.txt
            Idra Voss kept the lighthouse.

            Question: When did the bridge open?
            """
        XCTAssertEqual(engine.reply(to: prompt), "According to The Quillon Bridge [1], the excerpts answer the question.")
    }

    func testChatCompletionsCarryTheReplyInOpenAIShape() throws {
        let (status, reply) = try route("POST", "/v1/chat/completions", [
            "model": "distiller",
            "messages": [["role": "system", "content": "Be brief."], ["role": "user", "content": "Say something about lanterns."]],
        ])
        XCTAssertEqual(status, 200)
        let choices = try XCTUnwrap(reply["choices"] as? [[String: Any]])
        let content = (choices.first?["message"] as? [String: Any])?["content"] as? String
        XCTAssertEqual(content, "Deterministic completion for: Say something about lanterns.")
        XCTAssertEqual(reply["model"] as? String, "distiller")
    }
}

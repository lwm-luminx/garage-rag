import XCTest
import LlamaEngine

/// The same known-answer comparison LlamaXPCService's "Embedding Known Answers" self-test runs,
/// here on the CPU through LlamaCppEngine directly. A llama.cpp bump that changes tokenization,
/// the forward pass, pooling or normalization fails `testBundledModelMatchesKnownAnswers`; then
/// regenerate the reference with tools/llama/gen_known_answers.sh and review the change.
///
/// Until ext/nomic_embed/known_answers.json is committed (see ext/nomic_embed/BUILD.bazel) the
/// bundle has no reference and every test here skips.
final class LlamaKnownAnswersTests: XCTestCase {
    private func resource(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext),
                      "\(name).\(ext) is missing from the test bundle (//ext/nomic_embed)")
    }

    private func knownAnswers() throws -> LlamaKnownAnswers {
        guard let url = Bundle(for: Self.self).url(forResource: LlamaKnownAnswers.resourceName, withExtension: "json") else {
            throw XCTSkip("ext/nomic_embed/known_answers.json is not committed yet")
        }
        return try LlamaKnownAnswers.load(from: url)
    }

    private func referenceVectors(_ known: LlamaKnownAnswers) -> [String: [Float]] {
        Dictionary(uniqueKeysWithValues: known.inputs.map { ($0.id, $0.embedding) })
    }

    func testBundledModelMatchesKnownAnswers() throws {
        let known = try knownAnswers()
        let model = try resource(LlamaKnownAnswers.modelResourceName, "gguf")
        let engine = LlamaCppEngine()
        // CPU, as the reference was made; the self-test covers Metal on a real Mac.
        let report = try engine.runKnownAnswers(known, modelPath: model.path, configJson: #"{"n_gpu_layers": 0}"#)
        print(report.details)
        XCTAssertTrue(report.passed, report.details)
        XCTAssertEqual(report.results.count, known.inputs.count)
        XCTAssertGreaterThanOrEqual(report.worstCosine, known.tolerance.minCosine, report.details)
        XCTAssertTrue(report.results.allSatisfy { $0.dimensions == 768 }, report.details)
        XCTAssertFalse(engine.loadedAliases.contains(LlamaCppEngine.knownAnswersAlias),
                       "the known-answer model should be unloaded after the run")
    }

    func testReferenceIsSelfConsistent() throws {
        let known = try knownAnswers()
        XCTAssertEqual(known.dimensions, 768)
        XCTAssertEqual(known.model.file, "nomic-embed-text-v1.5.Q2_K.gguf")
        let report = known.evaluate(referenceVectors(known))
        XCTAssertTrue(report.passed, report.details)
        XCTAssertEqual(report.worstCosine, 1, accuracy: 1e-6)
    }

    func testEvaluateFailsOnSwappedVectors() throws {
        let known = try knownAnswers()
        var produced = referenceVectors(known)
        produced["cat_a"] = produced["unrelated"]
        let report = known.evaluate(produced)
        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.failures.contains { $0.hasPrefix("cat_a: cosine") }, report.details)
    }

    func testEvaluateFailsOnWrongDimensionsAndNorm() throws {
        let known = try knownAnswers()
        var produced = referenceVectors(known)
        produced["query"] = Array(try XCTUnwrap(produced["query"]).prefix(512))
        produced["document"] = try XCTUnwrap(produced["document"]).map { $0 * 2 }
        let report = known.evaluate(produced)
        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.failures.contains { $0.hasPrefix("query: 512 dimensions") }, report.details)
        XCTAssertTrue(report.failures.contains { $0.hasPrefix("document: norm") }, report.details)
    }
}

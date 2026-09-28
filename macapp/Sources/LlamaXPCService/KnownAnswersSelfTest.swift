import Foundation
import LlamaEngine
import PythonXPCService

/// "Embedding Known Answers": loads the bundled nomic-embed-text Q2_K, embeds known inputs through
/// llama.cpp, compares them with llama.cpp's reference vectors, then unloads it. Only LlamaCppEngine
/// can pass it, so the shipped service hands it to the front end (`engineSelfTests`) and the UI
/// tests' mock service, on its deterministic engine, does not.
///
/// The model and the reference (`//ext/nomic_embed`) live in this service's Resources. The run goes
/// straight through the engine, as an NSXPC `embeddings` call does, on Metal; the reference was made
/// on the CPU, and the file's tolerance covers the difference.
func embeddingKnownAnswersSelfTest(engine: LlamaCppEngine) -> GarageXPCSelfTest {
    GarageXPCSelfTest(
        name: "Embedding Known Answers",
        description: "Loads the bundled nomic-embed-text Q2_K, embeds known inputs through llama.cpp, compares them with reference vectors, then unloads it.",
        requiresPython: false
    ) {
        guard let answers = Bundle.main.url(forResource: LlamaKnownAnswers.resourceName, withExtension: "json") else {
            // Until ext/nomic_embed/known_answers.json is committed the service ships without it.
            throw GarageXPCSelfTestSkipped("No reference vectors in this build")
        }
        guard let model = Bundle.main.url(forResource: LlamaKnownAnswers.modelResourceName, withExtension: "gguf") else {
            throw GarageXPCSelfTestFailure("The known-answer model is missing from LlamaXPCService's Resources")
        }
        let known = try LlamaKnownAnswers.load(from: answers)
        let report = try engine.runKnownAnswers(known, modelPath: model.path)
        guard report.passed else {
            throw GarageXPCSelfTestFailure(report.headline, details: report.details)
        }
        return report.details
    }
}

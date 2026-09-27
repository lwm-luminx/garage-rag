import Foundation

/// Reference embeddings for fixed inputs, from `//ext/nomic_embed:known_answers.json`.
///
/// llama.cpp's own `llama-embedding` produced them (on the Apple silicon CPU, from the source
/// `//ext/llama_cpp` pins and the GGUF `//ext/nomic_embed` pins; `tools/llama/gen_known_answers.sh`
/// regenerates them). Matching them shows the whole embedding path works: the model loads, the
/// tokenizer adds and parses special tokens, the forward pass runs, and pooling and L2
/// normalization happen the way llama.cpp does them. LlamaXPCService's "Embedding Known Answers"
/// self-test and LlamaEngineTests both run `LlamaCppEngine.runKnownAnswers`.
public struct LlamaKnownAnswers: Decodable, Sendable {
    /// The reference and the model as bundle resources (`//ext/nomic_embed:known_answers` and
    /// `:selftest_model` flatten to these names).
    public static let resourceName = "known_answers"
    public static let modelResourceName = "nomic-embed-text-v1.5.Q2_K"

    public struct Model: Decodable, Sendable {
        public let file: String
        public let sha256: String
    }

    public struct LlamaCpp: Decodable, Sendable {
        public let version: String
    }

    public struct Tolerance: Decodable, Sendable {
        /// Cosine every produced vector must reach against its reference. Not 1: Metal and the CPU
        /// round differently (see the file's `tolerance.why`).
        public let minCosine: Double
        /// How far a produced vector's L2 norm may be from 1.
        public let maxNormError: Double
    }

    /// `cosine(higher)` must exceed `cosine(lower)`, each a pair of input ids.
    public struct Ordering: Decodable, Sendable {
        public let higher: [String]
        public let lower: [String]
    }

    public struct Input: Decodable, Sendable {
        public let id: String
        public let text: String
        public let norm: Double
        public let first8: [Float]
        public let embedding: [Float]
    }

    public let model: Model
    public let llamaCpp: LlamaCpp
    public let dimensions: Int
    public let tolerance: Tolerance
    public let orderings: [Ordering]
    public let inputs: [Input]

    public static func load(from url: URL) throws -> LlamaKnownAnswers {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(LlamaKnownAnswers.self, from: Data(contentsOf: url))
    }

    /// Compares produced vectors (by input id) with the references. Pure, so the checks themselves
    /// are testable without a model.
    public func evaluate(_ produced: [String: [Float]]) -> LlamaKnownAnswerReport {
        var results: [LlamaKnownAnswerReport.InputResult] = []
        var failures: [String] = []
        for input in inputs {
            guard let vector = produced[input.id] else {
                failures.append("\(input.id): no embedding produced")
                continue
            }
            let norm = LlamaKnownAnswers.norm(vector)
            let cosine = vector.count == input.embedding.count ? LlamaKnownAnswers.cosine(vector, input.embedding) : -1
            results.append(.init(id: input.id, cosine: cosine, norm: norm, dimensions: vector.count,
                                 first8: Array(vector.prefix(8)), expectedFirst8: input.first8, expectedNorm: input.norm))
            if vector.count != dimensions {
                failures.append("\(input.id): \(vector.count) dimensions, expected \(dimensions)")
                continue
            }
            if abs(norm - 1) > tolerance.maxNormError {
                failures.append("\(input.id): norm \(LlamaKnownAnswers.format(norm)), expected 1 ± \(tolerance.maxNormError)")
            }
            if cosine < tolerance.minCosine {
                failures.append("\(input.id): cosine \(LlamaKnownAnswers.format(cosine)) to the reference, below \(tolerance.minCosine)")
            }
        }

        var orderingResults: [LlamaKnownAnswerReport.OrderingResult] = []
        for ordering in orderings {
            guard ordering.higher.count == 2, ordering.lower.count == 2,
                  let h0 = produced[ordering.higher[0]], let h1 = produced[ordering.higher[1]],
                  let l0 = produced[ordering.lower[0]], let l1 = produced[ordering.lower[1]],
                  h0.count == h1.count, l0.count == l1.count else {
                failures.append("ordering \(ordering.higher) > \(ordering.lower): inputs missing")
                continue
            }
            let result = LlamaKnownAnswerReport.OrderingResult(
                higher: ordering.higher, lower: ordering.lower,
                higherCosine: LlamaKnownAnswers.cosine(h0, h1), lowerCosine: LlamaKnownAnswers.cosine(l0, l1))
            orderingResults.append(result)
            if !result.holds {
                failures.append("\(result.description) does not hold")
            }
        }
        return LlamaKnownAnswerReport(results: results, orderings: orderingResults, failures: failures,
                                      minCosine: tolerance.minCosine)
    }

    static func norm(_ v: [Float]) -> Double {
        v.reduce(0) { $0 + Double($1) * Double($1) }.squareRoot()
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        var dot = 0.0
        for i in 0..<min(a.count, b.count) {
            dot += Double(a[i]) * Double(b[i])
        }
        let denominator = norm(a) * norm(b)
        return denominator > 0 ? dot / denominator : 0
    }

    static func format(_ value: Double, digits: Int = 6) -> String {
        String(format: "%.\(digits)f", value)
    }
}

/// Outcome of a known-answer run, with enough detail (first values and norms) to read a failure.
public struct LlamaKnownAnswerReport: Sendable {
    public struct InputResult: Sendable {
        public let id: String
        public let cosine: Double
        public let norm: Double
        public let dimensions: Int
        public let first8: [Float]
        public let expectedFirst8: [Float]
        public let expectedNorm: Double
    }

    public struct OrderingResult: Sendable {
        public let higher: [String]
        public let lower: [String]
        public let higherCosine: Double
        public let lowerCosine: Double

        public var holds: Bool { higherCosine > lowerCosine }

        public var description: String {
            "cos(\(higher.joined(separator: ", "))) \(LlamaKnownAnswers.format(higherCosine, digits: 4)) > "
                + "cos(\(lower.joined(separator: ", "))) \(LlamaKnownAnswers.format(lowerCosine, digits: 4))"
        }
    }

    public let results: [InputResult]
    public let orderings: [OrderingResult]
    public let failures: [String]
    public let minCosine: Double

    public var passed: Bool { failures.isEmpty }

    /// The lowest cosine to a reference, and whose it was.
    public var worst: InputResult? { results.min { $0.cosine < $1.cosine } }
    public var worstCosine: Double { worst?.cosine ?? 0 }

    public var headline: String {
        let worstText = worst.map { "worst cosine \(LlamaKnownAnswers.format($0.cosine)) (\($0.id))" } ?? "no vectors"
        if passed {
            return "Known answers match: \(results.count) inputs, \(worstText), tolerance \(minCosine)"
        }
        return "Known answers do not match: \(failures.first ?? "")"
    }

    /// Multi-line report: headline, failures, then each input and each ordering.
    public var details: String {
        var lines = [headline]
        if failures.count > 0 {
            lines.append("Failures:")
            lines.append(contentsOf: failures.map { "  \($0)" })
        }
        lines.append("Inputs:")
        for r in results {
            lines.append("  \(r.id): cosine \(LlamaKnownAnswers.format(r.cosine)) norm \(LlamaKnownAnswers.format(r.norm)) dims \(r.dimensions)")
            if r.cosine < minCosine {
                lines.append("    got      \(LlamaKnownAnswerReport.list(r.first8)) norm \(LlamaKnownAnswers.format(r.norm))")
                lines.append("    expected \(LlamaKnownAnswerReport.list(r.expectedFirst8)) norm \(LlamaKnownAnswers.format(r.expectedNorm))")
            }
        }
        lines.append("Orderings:")
        lines.append(contentsOf: orderings.map { "  \($0.description)\($0.holds ? "" : "  FAILED")" })
        return lines.joined(separator: "\n")
    }

    private static func list(_ values: [Float]) -> String {
        "[" + values.map { String(format: "%.5f", $0) }.joined(separator: ", ") + "]"
    }
}

public enum LlamaKnownAnswersError: Error, LocalizedError {
    case load(String)
    case response(String)

    public var errorDescription: String? {
        switch self {
        case .load(let message): return "Could not load the known-answer model: \(message)"
        case .response(let message): return "Unexpected embeddings response: \(message)"
        }
    }
}

extension LlamaCppEngine {
    /// Alias the known-answer model loads under. Reserved: nothing else should load a model by it.
    public static let knownAnswersAlias = "garage-selftest-nomic"

    /// Loads `modelPath` under `alias`, embeds every known input through the same route an XPC
    /// `embeddings` call takes (`handleEmbeddings`, naming the alias so no other resident model
    /// answers), unloads it again, and compares. The model is resident only for the run.
    ///
    /// While it is loaded it is the engine's default model, so a request that names no model
    /// in that window (the run takes well under a second on a Mac) reaches it.
    public func runKnownAnswers(_ known: LlamaKnownAnswers, modelPath: String,
                                alias: String = LlamaCppEngine.knownAnswersAlias,
                                configJson: String? = nil) throws -> LlamaKnownAnswerReport {
        let loaded = loadModel(path: modelPath, alias: alias, configJson: configJson)
        guard loaded.success else {
            throw LlamaKnownAnswersError.load(loaded.message)
        }
        defer { _ = unloadModel(alias: alias) }

        let request: [String: Any] = ["model": alias, "input": known.inputs.map(\.text)]
        let body = try JSONSerialization.data(withJSONObject: request)
        let response = try handleEmbeddings(jsonString: String(decoding: body, as: UTF8.self))
        guard let data = response["data"] as? [[String: Any]], data.count == known.inputs.count else {
            throw LlamaKnownAnswersError.response("expected \(known.inputs.count) embeddings")
        }
        var produced: [String: [Float]] = [:]
        for item in data {
            guard let index = item["index"] as? Int, known.inputs.indices.contains(index),
                  let vector = item["embedding"] as? [Float] else {
                throw LlamaKnownAnswersError.response("an item has no index or embedding")
            }
            produced[known.inputs[index].id] = vector
        }
        return known.evaluate(produced)
    }
}

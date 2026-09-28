import Foundation
import LlamaClient

/// `LlamaInferenceEngine` for the UI tests that need a model (`MockLlamaXPCService`): answers
/// that are deterministic but meaningful enough for Garage's pipeline to work end to end.
///
/// - **Models** load and unload like `LlamaCppEngine`'s: several aliases at once, a missing file
///   refused, `/v1/models` listing what is resident. Nothing is read from the file, so a test's
///   placeholder `.gguf` is enough. Inference answers whatever `model` a request names, loaded or
///   not, so a test does not depend on the on-demand loading of the process that asked.
/// - **Embeddings** are a hashed bag of words (`dimensions` wide, L2-normalised): texts that share
///   words point the same way, so a query for a word only one document holds finds that document.
/// - **Chat** recognises the two prompts Garage sends. A LangExtract prompt (fact distillation,
///   ending in `Q: <text>` / `A: `) gets a fenced JSON answer in LangExtract's shape with one
///   extraction per sentence of the text, quoted exactly so every fact is grounded: class `event`
///   with a `year` attribute when the sentence holds a four-digit year, `fact` otherwise. A
///   `rag_ask` prompt (`Excerpts:` ... `Question:`) gets an answer naming its first excerpt as [1].
///   Anything else gets a fixed completion.
/// - Everything else (completion, tokenizer, rerank, slots) is `MockLlamaServerEngine`'s.
public final class DeterministicLlamaEngine: LlamaInferenceEngine, @unchecked Sendable {
    /// Width of every embedding: register the UI tests' model with exactly this many dimensions.
    public static let defaultDimensions = 1024

    public let dimensions: Int
    private let lock = NSLock()
    private var models: [String: String] = [:]
    private var order: [String] = []
    private let base = MockLlamaServerEngine(modelPath: nil, modelAlias: "deterministic")

    public init(dimensions: Int = DeterministicLlamaEngine.defaultDimensions) {
        self.dimensions = max(1, dimensions)
    }

    // MARK: - Model management

    public var currentModelPath: String? {
        lock.lock()
        defer { lock.unlock() }
        return order.last.flatMap { models[$0] }
    }

    public var loadedAliases: [String] {
        lock.lock()
        defer { lock.unlock() }
        return order
    }

    public func loadModel(path: String, alias: String?, configJson: String?) -> (success: Bool, message: String) {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked(path: path, alias: alias)
    }

    public func ensureModel(path: String, alias: String, configJson: String?) -> (success: Bool, message: String) {
        lock.lock()
        defer { lock.unlock() }
        if models[alias] != nil {
            return (true, "\(alias) is already loaded")
        }
        return loadLocked(path: path, alias: alias)
    }

    private func loadLocked(path: String, alias: String?) -> (success: Bool, message: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            return (false, "model file not found: \(path)")
        }
        let resolved = (alias?.isEmpty == false) ? alias! : URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        models[resolved] = path
        order.removeAll { $0 == resolved }
        order.append(resolved)
        return (true, "Model loaded successfully from \(path) (\(resolved): deterministic test engine, n_embd=\(dimensions))")
    }

    public func unloadModel() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        models.removeAll()
        order.removeAll()
        return true
    }

    private func unloadModel(alias: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let key = models[alias] != nil ? alias : models.first(where: { $0.value == alias })?.key else {
            return false
        }
        models.removeValue(forKey: key)
        order.removeAll { $0 == key }
        return true
    }

    public func handleModelLoad(jsonString: String) throws -> [String: Any] {
        let dict = try LlamaJSON.parseObject(jsonString, what: "model load")
        guard let path = (dict["path"] as? String) ?? (dict["model"] as? String), !path.isEmpty else {
            throw LlamaEngineError.badRequest("\"path\" (or \"model\") is required")
        }
        let result = loadModel(path: path, alias: dict["alias"] as? String, configJson: nil)
        guard result.success else {
            throw LlamaEngineError(500, result.message)
        }
        return ["success": true, "message": result.message, "models": loadedAliases]
    }

    public func handleModelUnload(jsonString: String) throws -> [String: Any] {
        let dict = try LlamaJSON.parseObject(jsonString, what: "model unload")
        guard let name = dict["model"] as? String, !name.isEmpty else {
            throw LlamaEngineError.badRequest("\"model\" is required")
        }
        guard unloadModel(alias: name) else {
            throw LlamaEngineError(404, "model \(name) is not loaded (loaded: \(loadedAliases.joined(separator: ", ")))")
        }
        return ["success": true, "message": "unloaded \(name)", "models": loadedAliases]
    }

    // MARK: - Status routes

    public func handleHealth() -> [String: Any] {
        let count = loadedAliases.count
        return [
            "status": count > 0 ? "ok" : "no_model_loaded",
            "slots_idle": 1,
            "slots_processing": 0,
            "models_loaded": count,
        ]
    }

    public func handleProps() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        let alias = order.last
        return [
            "total_slots": 1,
            "model_alias": alias ?? "none",
            "model_path": alias.flatMap { models[$0] } as Any,
            "modal_capabilities": ["completion", "chat", "embeddings", "tokenize", "detokenize"],
            "models": order,
            "engine": "deterministic",
            "n_ctx": 8192,
            "n_embd": dimensions,
            "model_description": "Deterministic test engine (hashed bag-of-words embeddings, sentence facts)",
        ]
    }

    public func handleModels() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        let created = Int64(Date().timeIntervalSince1970)
        let data: [[String: Any]] = order.map { alias in
            [
                "id": alias,
                "object": "model",
                "created": created,
                "owned_by": "garage",
                "meta": [
                    "path": models[alias] ?? "",
                    "n_ctx": 8192,
                    "n_embd": dimensions,
                    "architecture": "deterministic",
                    "capabilities": ["embeddings", "completion", "chat"],
                    "default": alias == order.last,
                ],
            ]
        }
        return ["object": "list", "data": data]
    }

    private func modelName(_ requested: Any?) -> String {
        if let name = (requested as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            return name
        }
        return loadedAliases.last ?? "deterministic"
    }

    // MARK: - Inference

    public func handleEmbeddings(jsonString: String) throws -> [String: Any] {
        let dict = try LlamaJSON.parseObject(jsonString, what: "embeddings")
        let inputs: [String]
        if let text = dict["input"] as? String {
            inputs = [text]
        } else if let texts = dict["input"] as? [String] {
            inputs = texts
        } else {
            throw LlamaEngineError.badRequest("\"input\" must be a string or an array of strings")
        }
        var data: [[String: Any]] = []
        var totalTokens = 0
        for (index, text) in inputs.enumerated() {
            data.append(["object": "embedding", "embedding": embedding(for: text), "index": index])
            totalTokens += Self.words(in: text).count
        }
        return [
            "object": "list",
            "data": data,
            "model": modelName(dict["model"]),
            "usage": ["prompt_tokens": totalTokens, "total_tokens": totalTokens],
        ]
    }

    public func handleChatCompletion(jsonString: String) throws -> [String: Any] {
        let dict = try LlamaJSON.parseObject(jsonString, what: "chat completion")
        guard let messages = dict["messages"] as? [[String: Any]], !messages.isEmpty else {
            throw LlamaEngineError.badRequest("\"messages\" must be a non-empty array")
        }
        let lastUser = messages.last(where: { ($0["role"] as? String) == "user" })
        let prompt = (lastUser?["content"] as? String) ?? ""
        let content = reply(to: prompt)
        let promptTokens = messages.reduce(0) { $0 + Self.words(in: ($1["content"] as? String) ?? "").count }
        let completionTokens = Self.words(in: content).count
        return [
            "id": "chatcmpl-deterministic",
            "object": "chat.completion",
            "created": Int64(Date().timeIntervalSince1970),
            "model": modelName(dict["model"]),
            "choices": [
                ["index": 0, "message": ["role": "assistant", "content": content], "finish_reason": "stop"],
            ],
            "usage": [
                "prompt_tokens": promptTokens,
                "completion_tokens": completionTokens,
                "total_tokens": promptTokens + completionTokens,
            ],
        ]
    }

    public func handleCompletion(jsonString: String) throws -> [String: Any] {
        try base.handleCompletion(jsonString: jsonString)
    }

    public func handleTokenize(jsonString: String) throws -> [String: Any] {
        try base.handleTokenize(jsonString: jsonString)
    }

    public func handleDetokenize(jsonString: String) throws -> [String: Any] {
        try base.handleDetokenize(jsonString: jsonString)
    }

    public func handleRerank(jsonString: String) throws -> [String: Any] {
        try base.handleRerank(jsonString: jsonString)
    }

    public func handleInfill(jsonString: String) throws -> [String: Any] {
        try base.handleInfill(jsonString: jsonString)
    }

    public func handleSlots() -> [String: Any] {
        base.handleSlots()
    }

    public func handleSlotAction(slotId: Int, action: String, jsonString: String) throws -> [String: Any] {
        try base.handleSlotAction(slotId: slotId, action: action, jsonString: jsonString)
    }

    // MARK: - Embeddings

    /// Lowercased runs of letters and digits.
    static func words(in text: String) -> [String] {
        text.lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
    }

    /// 64-bit FNV-1a: stable across processes and launches, unlike `Hasher`.
    static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    /// The hashed bag of words of `text`, L2-normalised; a text with no words gets a fixed unit
    /// vector, since a zero vector has no cosine distance.
    public func embedding(for text: String) -> [Float] {
        var vector = [Float](repeating: 0, count: dimensions)
        let words = Self.words(in: text)
        guard !words.isEmpty else {
            vector[0] = 1
            return vector
        }
        for word in words {
            vector[Int(Self.fnv1a(word) % UInt64(dimensions))] += 1
        }
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return vector.map { $0 / norm }
    }

    // MARK: - Chat

    /// The assistant's answer to the last user message.
    public func reply(to prompt: String) -> String {
        if let text = Self.langExtractQuestion(in: prompt) {
            return Self.extractionAnswer(for: text)
        }
        if prompt.contains("Excerpts:"), prompt.contains("Question:") {
            return Self.askAnswer(for: prompt)
        }
        return "Deterministic completion for: \(prompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))"
    }

    /// The text of a LangExtract prompt's final question: what follows the last `Q: ` line, when
    /// the prompt ends with the bare `A: ` LangExtract leaves for the answer.
    static func langExtractQuestion(in prompt: String) -> String? {
        var body = prompt
        while let last = body.last, last.isWhitespace {
            body.removeLast()
        }
        guard body.hasSuffix("\nA:") else { return nil }
        body.removeLast(3)
        if let question = body.range(of: "\nQ: ", options: .backwards) {
            return String(body[question.upperBound...])
        }
        if body.hasPrefix("Q: ") {
            return String(body.dropFirst(3))
        }
        return nil
    }

    /// Sentences of `text` worth a fact: runs ending in `.`, `!` or `?` within one line, trimmed,
    /// of at least five words (so headings, greetings and mail headers are left out).
    static func sentences(in text: String) -> [String] {
        var found: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var current = ""
            for character in line {
                current.append(character)
                if character == "." || character == "!" || character == "?" {
                    let sentence = current.trimmingCharacters(in: .whitespaces)
                    if sentence.split(separator: " ").count >= 5 {
                        found.append(sentence)
                    }
                    current = ""
                }
            }
        }
        return found
    }

    /// The first four-digit number in `sentence` that stands alone, such as a year.
    static func year(in sentence: String) -> String? {
        sentence.split { !$0.isNumber }.first { $0.count == 4 }.map(String.init)
    }

    /// LangExtract's answer format: a fenced JSON object whose `extractions` list holds one object
    /// per extraction, `{<class>: <exact text>, <class>_attributes: {...}}`.
    static func extractionAnswer(for text: String) -> String {
        let extractions: [[String: Any]] = sentences(in: text).map { sentence in
            if let year = year(in: sentence) {
                return ["event": sentence, "event_attributes": ["year": year]]
            }
            return ["fact": sentence]
        }
        let object: [String: Any] = ["extractions": extractions]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8) else {
            return "```json\n{\"extractions\": []}\n```"
        }
        return "```json\n\(json)\n```"
    }

    /// Names the first excerpt of a `rag_ask` prompt, whose header reads `[1] <title> — <location>`.
    static func askAnswer(for prompt: String) -> String {
        for line in prompt.split(separator: "\n") where line.hasPrefix("[1] ") {
            var title = String(line.dropFirst(4))
            if let dash = title.range(of: " \u{2014} ") {
                title = String(title[..<dash.lowerBound])
            }
            return "According to \(title) [1], the excerpts answer the question."
        }
        return "The excerpts do not answer the question."
    }
}

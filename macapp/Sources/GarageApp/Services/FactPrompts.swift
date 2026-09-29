import Foundation
import proto_garage_proto_swift

/// One effective fact-extraction prompt, as `ListFactPrompts` reports it: the
/// built-in `default` (possibly overridden in garage.json) or a configured one.
struct FactPromptItem: Identifiable, Equatable {
    var name: String
    var description: String
    /// The few-shot examples as a JSON array, LangExtract's shape:
    /// `[{"text": ..., "extractions": [{"class": ..., "text": ..., "attributes": {...}}]}]`.
    var examplesJSON: String
    var corpusClasses: [String]
    var sources: [String]
    var enabled: Bool
    var builtin: Bool
    var customized: Bool
    var sha256: String

    var id: String { name }

    init(
        name: String,
        description: String,
        examplesJSON: String,
        corpusClasses: [String] = [],
        sources: [String] = [],
        enabled: Bool = true,
        builtin: Bool = false,
        customized: Bool = false,
        sha256: String = ""
    ) {
        self.name = name
        self.description = description
        self.examplesJSON = examplesJSON
        self.corpusClasses = corpusClasses
        self.sources = sources
        self.enabled = enabled
        self.builtin = builtin
        self.customized = customized
        self.sha256 = sha256
    }

    init(_ proto: Garage_FactPrompt) {
        self.init(
            name: proto.name,
            description: proto.description_p,
            examplesJSON: proto.examplesJson,
            corpusClasses: proto.corpusClasses,
            sources: proto.sources,
            enabled: proto.enabled,
            builtin: proto.builtin,
            customized: proto.customized,
            sha256: proto.sha256
        )
    }

    /// "all documents", or the classes and sources the prompt is limited to.
    var scopeSummary: String {
        let parts = corpusClasses + sources.map { "source \($0)" }
        return parts.isEmpty ? "all documents" : parts.joined(separator: ", ")
    }

    /// A starting point for a new prompt.
    static func blank(existingNames: Set<String>) -> FactPromptItem {
        var name = "prompt"
        var suffix = 2
        while existingNames.contains(name) {
            name = "prompt-\(suffix)"
            suffix += 1
        }
        return FactPromptItem(
            name: name,
            description: "",
            examplesJSON: FactPromptConfig.prettyJSON([
                [
                    "text": "Jane Doe joined Acme Corp in 2019 as its CFO.",
                    "extractions": [["class": "fact", "text": "Jane Doe joined Acme Corp in 2019 as its CFO."]],
                ] as [String: Any],
            ])
        )
    }
}

enum FactPromptConfigError: LocalizedError, Equatable {
    case invalidName(String)
    case duplicateName(String)
    case emptyDescription
    case invalidExamples(String)

    var errorDescription: String? {
        switch self {
        case .invalidName(let name):
            "\"\(name)\" is not a valid prompt name: use letters, digits, '.', '_' or '-', starting with a letter or digit."
        case .duplicateName(let name):
            "A prompt named \"\(name)\" already exists."
        case .emptyDescription:
            "The instructions must not be empty."
        case .invalidExamples(let reason):
            "Examples must be a non-empty JSON array of {\"text\", \"extractions\"} objects: \(reason)"
        }
    }
}

/// Edits `facts.prompts` as garage.json holds it: a JSON array of entries, which
/// the app writes back whole through `SetSetting facts.prompts`. An entry named
/// after a built-in overrides it field by field; any other entry adds a prompt.
/// Entries are kept as JSON objects so keys the app does not edit survive.
enum FactPromptConfig {
    static let corpusClasses = ["document", "code", "communication"]

    static func parse(_ configuredJSON: String) -> [[String: Any]] {
        guard let data = configuredJSON.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array
    }

    static func serialize(_ entries: [[String: Any]]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }

    static func prettyJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }

    /// The examples text re-indented for editing; returned unchanged when it is not JSON.
    static func prettyExamples(_ examplesJSON: String) -> String {
        guard let data = examplesJSON.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else {
            return examplesJSON
        }
        return prettyJSON(value)
    }

    static func isValidName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#, options: .regularExpression) != nil
    }

    /// The examples text as JSON, checked for the shape LangExtract needs; the
    /// server validates every field again before anything is written.
    static func parseExamples(_ text: String) throws -> [[String: Any]] {
        guard let data = text.data(using: .utf8) else {
            throw FactPromptConfigError.invalidExamples("not UTF-8")
        }
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw FactPromptConfigError.invalidExamples("not valid JSON")
        }
        guard let examples = value as? [[String: Any]], !examples.isEmpty else {
            throw FactPromptConfigError.invalidExamples("expected a non-empty array of objects")
        }
        for example in examples {
            guard example["text"] is String else {
                throw FactPromptConfigError.invalidExamples("every example needs a \"text\" string")
            }
            if let extractions = example["extractions"], !(extractions is [[String: Any]]) {
                throw FactPromptConfigError.invalidExamples("\"extractions\" must be an array of objects")
            }
        }
        return examples
    }

    /// Writes `prompt` in full, replacing the entry named `originalName` (a rename)
    /// or `prompt.name`, else appending it.
    static func saving(
        _ prompt: FactPromptItem,
        replacing originalName: String? = nil,
        in configuredJSON: String,
        existingNames: Set<String>
    ) throws -> String {
        guard isValidName(prompt.name) else {
            throw FactPromptConfigError.invalidName(prompt.name)
        }
        if prompt.name != originalName, existingNames.contains(prompt.name) {
            throw FactPromptConfigError.duplicateName(prompt.name)
        }
        guard !prompt.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FactPromptConfigError.emptyDescription
        }
        let examples = try parseExamples(prompt.examplesJSON)
        var entries = parse(configuredJSON)
        let target = originalName ?? prompt.name
        var entry: [String: Any] = [
            "name": prompt.name,
            "description": prompt.description,
            "examples": examples,
            "corpus_classes": prompt.corpusClasses,
            "sources": prompt.sources,
            "enabled": prompt.enabled,
        ]
        if let index = entries.firstIndex(where: { ($0["name"] as? String) == target }) {
            // Keys this editor does not show (the prompt's graph block) stay as they were.
            for (key, value) in entries[index] where entry[key] == nil {
                entry[key] = value
            }
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        return serialize(entries)
    }

    /// Turns `name` on or off, keeping the rest of its entry; a built-in with no
    /// entry gets one carrying just its name and the flag.
    static func settingEnabled(_ enabled: Bool, for name: String, in configuredJSON: String) -> String {
        var entries = parse(configuredJSON)
        if let index = entries.firstIndex(where: { ($0["name"] as? String) == name }) {
            entries[index]["enabled"] = enabled
        } else {
            entries.append(["name": name, "enabled": enabled])
        }
        return serialize(entries)
    }

    /// Drops `name`'s entry: deletes a configured prompt, or restores a built-in.
    static func removing(_ name: String, from configuredJSON: String) -> String {
        serialize(parse(configuredJSON).filter { ($0["name"] as? String) != name })
    }
}

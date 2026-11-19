import Foundation

/// What `rag_agent` returns: the local model's answer, the tools it called on the way and the
/// documents it saw. Decoded from the MCP tool result the menu bar's "Ask Garage" gets back.
struct MenuBarAnswer: Decodable, Equatable {
    struct Step: Decodable, Equatable {
        let n: Int
        let tool: String
        let summary: String
        var ok: Bool = true

        private enum CodingKeys: String, CodingKey { case n, tool, summary, ok }

        init(n: Int, tool: String, summary: String, ok: Bool = true) {
            self.n = n
            self.tool = tool
            self.summary = summary
            self.ok = ok
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            n = try container.decode(Int.self, forKey: .n)
            tool = try container.decode(String.self, forKey: .tool)
            summary = try container.decode(String.self, forKey: .summary)
            ok = try container.decodeIfPresent(Bool.self, forKey: .ok) ?? true
        }
    }

    struct Citation: Decodable, Equatable, Identifiable {
        let n: Int
        let documentId: Int
        let title: String?
        let location: String
        let snippet: String
        let corpusClass: String

        var id: Int { documentId }

        private enum CodingKeys: String, CodingKey {
            case n, title, location, snippet
            case documentId = "document_id"
            case corpusClass = "corpus_class"
        }

        init(n: Int, documentId: Int, title: String?, location: String, snippet: String, corpusClass: String) {
            self.n = n
            self.documentId = documentId
            self.title = title
            self.location = location
            self.snippet = snippet
            self.corpusClass = corpusClass
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            n = try container.decode(Int.self, forKey: .n)
            documentId = try container.decode(Int.self, forKey: .documentId)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            location = try container.decodeIfPresent(String.self, forKey: .location) ?? ""
            snippet = try container.decodeIfPresent(String.self, forKey: .snippet) ?? ""
            corpusClass = try container.decodeIfPresent(String.self, forKey: .corpusClass) ?? "document"
        }

        /// The title, or the file name when the document has none.
        var displayTitle: String {
            if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty {
                return title
            }
            let name = (location as NSString).lastPathComponent
            return name.isEmpty ? "Untitled" : name
        }

        /// The file behind the citation, when it is one. `rag_agent` folds the home folder to `~`.
        var fileURL: URL? {
            MenuBarQuickSearch.fileURL(forURI: (location as NSString).expandingTildeInPath)
        }
    }

    let answer: String
    let model: String
    let provider: String
    let question: String
    var steps: [Step] = []
    var citations: [Citation] = []

    private enum CodingKeys: String, CodingKey { case answer, model, provider, question, steps, citations }

    init(answer: String, model: String, provider: String, question: String, steps: [Step] = [], citations: [Citation] = []) {
        self.answer = answer
        self.model = model
        self.provider = provider
        self.question = question
        self.steps = steps
        self.citations = citations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        answer = Self.prose(try container.decode(String.self, forKey: .answer))
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? ""
        question = try container.decodeIfPresent(String.self, forKey: .question) ?? ""
        steps = try container.decodeIfPresent([Step].self, forKey: .steps) ?? []
        citations = try container.decodeIfPresent([Citation].self, forKey: .citations) ?? []
    }

    /// Decodes the text a `tools/call` returned; `nil` when it is not an answer (an error string,
    /// or a result with no text).
    static func parse(_ toolOutput: String) -> MenuBarAnswer? {
        guard let data = toolOutput.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(MenuBarAnswer.self, from: data),
              !parsed.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return parsed
    }

    /// The keys a small model puts its answer under when it answers in JSON.
    static let answerKeys = ["answer", "final_answer", "response", "content", "text", "message"]

    /// The answer as prose: only the model's last turn. A small model often answers in JSON
    /// (`{"answer": "..."}`, a fenced object, a quoted string), or writes out its tool calls and their
    /// made-up results before the answer; this keeps the prose after the last written-out tool call or
    /// result (or the text of an answer object at the end), drops a reasoning model's `<think>` block
    /// and a leading "Final answer:" label. JSON quoted inside prose stays. `rag_agent` does the same
    /// (`agent::answer_text`); this keeps an answer from an older server readable too.
    static func prose(_ raw: String) -> String {
        let text = raw.replacingOccurrences(
            of: "(?s)<think>.*?</think>", with: "", options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = jsonValue(unfenced(text)) {
            return answer(in: value) ?? text
        }
        let objects = jsonObjects(in: text)
        if let last = objects.last {
            let transcript = text.contains("Result of ") || objects.contains { object in
                guard let dictionary = object.value as? [String: Any] else { return false }
                return (dictionary["tool"] ?? dictionary["name"]) is String
            }
            let rest = text[last.end...].drop(while: { $0 == "`" || $0.isWhitespace })
            let tail = withoutLabel(String(rest))
            if transcript, !tail.isEmpty {
                return tail
            }
            if tail.isEmpty, let inner = answer(in: last.value) {
                return inner
            }
        }
        return withoutLabel(text)
    }

    /// The text inside a code fence that is the whole text, or the text itself.
    private static func unfenced(_ text: String) -> String {
        guard text.hasPrefix("```"), text.hasSuffix("```"), text.count >= 6 else { return text }
        var inner = text.dropFirst(3).dropLast(3)
        if let newline = inner.firstIndex(of: "\n"), inner[..<newline].allSatisfy({ $0.isLetter }) {
            inner = inner[inner.index(after: newline)...]
        }
        return inner.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func jsonValue(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    }

    /// The non-empty string under one of `answerKeys`, or a JSON string itself.
    private static func answer(in value: Any) -> String? {
        var candidates: [String] = []
        if let string = value as? String {
            candidates = [string]
        } else if let object = value as? [String: Any] {
            candidates = answerKeys.compactMap { object[$0] as? String }
        }
        return candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    /// The text after the last "Final answer:" or "Answer:" label that starts a line, or all of it.
    private static func withoutLabel(_ text: String) -> String {
        let pattern = #"(?im)^[ \t*#]*(?:final answer|answer)\s*:\**[ \t]*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.matches(in: text, range: range).last,
              let end = Range(match.range, in: text)?.upperBound
        else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return String(text[end...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Each top-level `{...}` in the text that parses as JSON: where it ends, and its value.
    private static func jsonObjects(in text: String) -> [(end: String.Index, value: Any)] {
        var found: [(end: String.Index, value: Any)] = []
        var depth = 0
        var start = text.startIndex
        var inString = false
        var escaped = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"", depth > 0 {
                inString = true
            } else if character == "{" {
                if depth == 0 { start = index }
                depth += 1
            } else if character == "}", depth > 0 {
                depth -= 1
                let end = text.index(after: index)
                if depth == 0, let value = jsonValue(String(text[start..<end])), value is [String: Any] {
                    found.append((end: end, value: value))
                }
            }
            index = text.index(after: index)
        }
        return found
    }

    /// The answer with its Markdown (bold, italics, code, links) rendered rather than shown as
    /// asterisks and backticks; line breaks are kept. Plain text when it is not Markdown.
    var formattedAnswer: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: answer, options: options)) ?? AttributedString(answer)
    }

    /// What to show when the tool's output is not an answer: its text when it is a message (an
    /// error from the server), and a sentence, never the raw JSON, when it is a result with no answer.
    static func failureText(forOutput output: String) -> String {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return "The local model returned nothing. Try asking again."
        }
        if let data = text.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return "The local model did not give an answer. Try rephrasing the question."
        }
        return MenuBarQuickSearch.oneLine(text)
    }

    /// The caption under the answer: how the model got there, and which model it was.
    /// "Searched twice and read 1 document · gemma2-2b".
    var footnote: String {
        var parts: [String] = []
        let searches = steps.filter { $0.ok && $0.tool == "rag_search" }.count
        let reads = steps.filter { $0.ok && $0.tool == "rag_get_document" }.count
        let other = steps.filter { $0.ok && $0.tool != "rag_search" && $0.tool != "rag_get_document" }.count
        if searches > 0 { parts.append("Searched \(Self.times(searches))") }
        if reads > 0 { parts.append("read \(reads) \(reads == 1 ? "document" : "documents")") }
        if other > 0 { parts.append("looked up the corpus \(Self.times(other))") }
        var text: String
        if let last = parts.last {
            let first = parts.dropLast()
            text = first.isEmpty ? last : first.joined(separator: ", ") + " and " + last
        } else {
            text = "Answered without searching"
        }
        if !text.isEmpty {
            text = text.prefix(1).uppercased() + text.dropFirst()
        }
        if !model.isEmpty {
            text += " · \(model)"
        }
        return text
    }

    private static func times(_ count: Int) -> String {
        switch count {
        case 1: "once"
        case 2: "twice"
        default: "\(count) times"
        }
    }
}

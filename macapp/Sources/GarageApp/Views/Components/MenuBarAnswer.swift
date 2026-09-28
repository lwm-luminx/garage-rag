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
        answer = try container.decode(String.self, forKey: .answer)
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

import Foundation
import GarageAppExtensionKit

/// One question on the Chat page and what became of it.
struct ChatExchange: Identifiable, Equatable {
    enum State: Equatable {
        case answering
        case answered(GarageChatReply)
        case failed(String)
        /// The person pressed Stop.
        case stopped
    }

    let id: UUID
    let question: String
    /// Who was asked, as the page listed it then.
    let backend: GarageChatBackend
    var state: State

    init(id: UUID = UUID(), question: String, backend: GarageChatBackend, state: State = .answering) {
        self.id = id
        self.question = question
        self.backend = backend
        self.state = state
    }

    var reply: GarageChatReply? {
        if case .answered(let reply) = state { return reply }
        return nil
    }
}

/// The Chat page's rules, as plain values: who answers, what each answerer is shown of the conversation, and how a
/// `rag_agent` result reads.
enum ChatPresentation {
    /// This Mac's own model: `rag_agent` on the MCP service.
    static let localBackendID = "local"
    /// The answerer picked last, kept across launches.
    static let selectedBackendDefaultsKey = "garage.chat.backend"

    static let emptyTitle = "Ask your Garage"
    static let emptyMessage = "Questions go to the model you pick above. It searches and reads your documents, code and "
        + "messages, answers, and shows what it read. Follow-up questions keep the conversation going."
    static let suggestions = [
        "What was I working on last week?",
        "Summarize what my notes say about the budget",
        "Who did I last talk to about the lease?",
    ]

    /// This Mac's model, as the answerer list shows it.
    static func localBackend(model: String, displayName: String?, provider: String, databaseRunning: Bool) -> GarageChatBackend {
        let name = displayName?.trimmingCharacters(in: .whitespaces).isEmpty == false ? displayName! : model
        let detail = switch provider {
        case "ollama": "Through Ollama. A host other than this Mac never sees your messages."
        case "lmstudio": "Through LM Studio. A host other than this Mac never sees your messages."
        default: "On this Mac. Nothing leaves it."
        }
        return GarageChatBackend(
            id: localBackendID,
            title: name.isEmpty ? "This Mac's model" : name,
            detail: detail,
            symbol: provider == "llama_xpc" ? "desktopcomputer" : "server.rack",
            leavesThisMac: false,
            unavailableReason: databaseRunning ? nil : "Chat needs the database. Start it on the Status page."
        )
    }

    /// The answerer to use: the one picked, while it is still offered, else this Mac's.
    static func resolvedBackendID(_ picked: String?, among backends: [GarageChatBackend]) -> String {
        if let picked, backends.contains(where: { $0.id == picked }) {
            return picked
        }
        return backends.first?.id ?? localBackendID
    }

    /// What `backendID` is shown of the conversation before its next question: every question that was answered,
    /// and only the answers that same answerer gave. An answer from this Mac's model may rest on a communication,
    /// which never goes to another answerer; and the person's own questions are theirs to send.
    static func history(for backendID: String, in exchanges: [ChatExchange]) -> [GarageChatTurn] {
        var turns: [GarageChatTurn] = []
        for exchange in exchanges {
            guard let reply = exchange.reply else { continue }
            turns.append(GarageChatTurn(role: .user, text: exchange.question))
            if exchange.backend.id == backendID {
                turns.append(GarageChatTurn(role: .assistant, text: reply.answer))
            }
        }
        return turns
    }

    /// `history` as `rag_agent` takes it.
    static func ragAgentHistory(_ turns: [GarageChatTurn]) -> [[String: String]] {
        turns.map { ["role": $0.role.rawValue, "content": $0.text] }
    }

    /// A `rag_agent` result (its typed record, or the JSON text of one) as a reply; nil when it is not an answer.
    static func reply(fromRagAgent data: Data) -> GarageChatReply? {
        guard let parsed = try? JSONDecoder().decode(MenuBarAnswer.self, from: data),
              !parsed.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return GarageChatReply(
            answer: parsed.answer,
            model: parsed.model,
            provider: parsed.provider,
            steps: parsed.steps.filter(\.ok).map(\.summary),
            citations: parsed.citations.map {
                GarageChatCitation(
                    n: $0.n,
                    documentID: $0.documentId,
                    title: $0.title,
                    location: $0.location,
                    snippet: $0.snippet,
                    corpusClass: $0.corpusClass
                )
            }
        )
    }

    /// The caption under an answer: "Searched twice and read 1 document · gemma-3-4b".
    static func footnote(_ reply: GarageChatReply) -> String {
        let searches = reply.steps.filter { $0.hasPrefix("Searched") }.count
        let reads = reply.steps.filter { $0.hasPrefix("Read ") }.count
        var parts: [String] = []
        if searches > 0 { parts.append("searched \(times(searches))") }
        if reads > 0 { parts.append("read \(reads) \(reads == 1 ? "document" : "documents")") }
        var text = parts.isEmpty ? "answered without searching" : parts.joined(separator: " and ")
        text = text.prefix(1).uppercased() + text.dropFirst()
        let who = [reply.model, providerName(reply.provider)].filter { !$0.isEmpty }
        if !who.isEmpty {
            text += " · " + who.joined(separator: " on ")
        }
        return text
    }

    /// A provider id as people know it.
    static func providerName(_ provider: String) -> String {
        switch provider {
        case "llama_xpc": "this Mac"
        case "ollama": "Ollama"
        case "lmstudio": "LM Studio"
        default: provider
        }
    }

    /// The title a citation shows: its own, else the file's name.
    static func title(of citation: GarageChatCitation) -> String {
        if let title = citation.title, !title.trimmingCharacters(in: .whitespaces).isEmpty {
            return title
        }
        let name = (citation.location as NSString).lastPathComponent
        return name.isEmpty ? "Untitled" : name
    }

    /// The answer as styled text: Markdown's inline marks (bold, italics, code, links), its line breaks kept.
    static func attributedAnswer(_ answer: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: answer, options: options)) ?? AttributedString(answer)
    }

    private static func times(_ count: Int) -> String {
        switch count {
        case 1: "once"
        case 2: "twice"
        default: "\(count) times"
        }
    }
}

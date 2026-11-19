import Foundation

/// One earlier turn of a Chat conversation, as an answerer gets it: what the person asked, or what was answered.
public struct GarageChatTurn: Sendable, Equatable {
    public enum Role: String, Sendable {
        case user, assistant
    }

    public var role: Role
    public var text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}

/// A document an answer rests on.
public struct GarageChatCitation: Sendable, Equatable, Identifiable {
    public var n: Int
    /// The corpus's document id, when the answer came from this Mac's corpus.
    public var documentID: Int?
    public var title: String?
    /// A path (home folded to `~`) or another URI.
    public var location: String
    public var snippet: String
    /// `document`, `code` or `communication`.
    public var corpusClass: String

    public var id: String { documentID.map(String.init) ?? "\(n):\(location)" }

    public init(
        n: Int,
        documentID: Int? = nil,
        title: String? = nil,
        location: String = "",
        snippet: String = "",
        corpusClass: String = "document"
    ) {
        self.n = n
        self.documentID = documentID
        self.title = title
        self.location = location
        self.snippet = snippet
        self.corpusClass = corpusClass
    }
}

/// What an answerer replied.
public struct GarageChatReply: Sendable, Equatable {
    public var answer: String
    /// The model that answered, as its provider names it.
    public var model: String
    /// Who ran it: `llama_xpc`, `ollama`, `openai`, a linked Garage's name, ...
    public var provider: String
    /// One line per step the answerer took ("Searched for “lease”: 6 hits").
    public var steps: [String]
    public var citations: [GarageChatCitation]

    public init(answer: String, model: String, provider: String, steps: [String] = [], citations: [GarageChatCitation] = []) {
        self.answer = answer
        self.model = model
        self.provider = provider
        self.steps = steps
        self.citations = citations
    }
}

/// Someone who can answer on the Chat page, as the page lists it.
public struct GarageChatBackend: Sendable, Equatable, Identifiable, Hashable {
    /// Stable across launches, so the page can remember the last one picked; unique across providers.
    public var id: String
    /// "Gemma 3 4B", "OpenAI", "Rick's M4".
    public var title: String
    /// One line on where the question goes: "On this Mac", "OpenAI, with your key: documents and code only".
    public var detail: String
    public var symbol: String
    /// Whether the question (and what is retrieved for it) leaves this Mac.
    public var leavesThisMac: Bool
    /// Why it cannot answer now, or nil when it can.
    public var unavailableReason: String?

    public init(
        id: String,
        title: String,
        detail: String,
        symbol: String,
        leavesThisMac: Bool,
        unavailableReason: String? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.leavesThisMac = leavesThisMac
        self.unavailableReason = unavailableReason
    }
}

/// Answerers an extension adds to the Chat page, beside this Mac's own model: a model reached with the person's
/// own provider key, another Garage of theirs, ...
///
/// The page hands each answerer only the turns it may see (`history`): every question the person asked, and only
/// the answers that same answerer gave, since an answer from this Mac's model may rest on a communication.
/// Whatever an answerer retrieves from the corpus and sends on is its own to keep to Garage's rules
/// (communications never go to a host that is not this Mac).
@MainActor
public protocol GarageChatProvider {
    /// Stable and unique among the providers a build links in.
    var id: String { get }

    /// The answerers it offers now; asked each time the Chat page appears and after each answer.
    func backends() async -> [GarageChatBackend]

    /// Answers `question` with the answerer `backendID` (one of `backends()`), given the earlier turns it may see.
    func answer(_ question: String, history: [GarageChatTurn], backendID: String) async throws -> GarageChatReply
}

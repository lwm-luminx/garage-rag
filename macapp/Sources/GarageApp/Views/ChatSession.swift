import Foundation
import GarageAppExtensionKit
import GarageAppExtensions
import MCPServerClient

/// The Chat page's conversation, kept while the main window is open: the exchanges so far, who can answer, and the
/// question being answered. One question at a time; a new conversation forgets the old one, which is never saved.
@MainActor
final class ChatSession: ObservableObject {
    @Published private(set) var exchanges: [ChatExchange] = []
    @Published private(set) var backends: [GarageChatBackend] = []
    /// The exchange being answered.
    @Published private(set) var answeringID: UUID?
    @Published var selectedBackendID: String {
        didSet { defaults.set(selectedBackendID, forKey: ChatPresentation.selectedBackendDefaultsKey) }
    }

    private let providers: [any GarageChatProvider]
    private let tools: GarageMCPToolCaller
    private let defaults: UserDefaults
    private var task: Task<Void, Never>?
    /// Which provider offered each answerer the page lists.
    private var owners: [String: any GarageChatProvider] = [:]

    init(
        providers: [any GarageChatProvider] = GarageAppExtensions.installed.chatProviders,
        tools: GarageMCPToolCaller = GarageMCPToolCaller(clientName: "Garage Chat"),
        defaults: UserDefaults = .standard
    ) {
        self.providers = providers
        self.tools = tools
        self.defaults = defaults
        selectedBackendID = defaults.string(forKey: ChatPresentation.selectedBackendDefaultsKey)
            ?? ChatPresentation.localBackendID
    }

    var isAnswering: Bool { answeringID != nil }

    var selectedBackend: GarageChatBackend? {
        backends.first { $0.id == selectedBackendID }
    }

    /// Lists this Mac's model and what the build's providers offer now.
    func refreshBackends(local: GarageChatBackend) async {
        var listed = [local]
        var owners: [String: any GarageChatProvider] = [:]
        for provider in providers {
            for backend in await provider.backends() where backend.id != local.id && owners[backend.id] == nil {
                listed.append(backend)
                owners[backend.id] = provider
            }
        }
        backends = listed
        self.owners = owners
        let resolved = ChatPresentation.resolvedBackendID(selectedBackendID, among: listed)
        if resolved != selectedBackendID {
            selectedBackendID = resolved
        }
    }

    /// Asks the picked answerer `question`, with what it may see of the conversation.
    func send(_ question: String) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, answeringID == nil, let backend = selectedBackend, backend.unavailableReason == nil else { return }
        let history = ChatPresentation.history(for: backend.id, in: exchanges)
        let exchange = ChatExchange(question: question, backend: backend)
        exchanges.append(exchange)
        answeringID = exchange.id
        task = Task { [weak self] in
            guard let self else { return }
            let state: ChatExchange.State
            do {
                state = .answered(try await self.answer(question, history: history, backend: backend))
            } catch is CancellationError {
                state = .stopped
            } catch {
                state = Task.isCancelled ? .stopped : .failed(error.localizedDescription)
            }
            self.finish(exchange.id, state: Task.isCancelled ? .stopped : state)
        }
    }

    /// Stops the answer in progress; the model may still finish it, but the page no longer waits.
    func stop() {
        guard let answeringID else { return }
        task?.cancel()
        finish(answeringID, state: .stopped)
    }

    /// Forgets the conversation.
    func startOver() {
        task?.cancel()
        task = nil
        answeringID = nil
        exchanges = []
    }

    private func finish(_ id: UUID, state: ChatExchange.State) {
        if let index = exchanges.firstIndex(where: { $0.id == id }), case .answering = exchanges[index].state {
            exchanges[index].state = state
        }
        if answeringID == id {
            answeringID = nil
            task = nil
        }
    }

    private func answer(_ question: String, history: [GarageChatTurn], backend: GarageChatBackend) async throws -> GarageChatReply {
        if backend.id != ChatPresentation.localBackendID {
            guard let owner = owners[backend.id] else {
                throw GarageMCPToolCallError("\(backend.title) is no longer offered.")
            }
            return try await owner.answer(question, history: history, backendID: backend.id)
        }
        var arguments: [String: Any] = ["question": question]
        if !history.isEmpty {
            arguments["history"] = ChatPresentation.ragAgentHistory(history)
        }
        let result = try await tools.call("rag_agent", arguments: arguments)
        try Task.checkCancellation()
        if result.isError {
            throw GarageMCPToolCallError(result.text.isEmpty ? "The model could not answer." : result.text)
        }
        guard let reply = ChatPresentation.reply(fromRagAgent: result.json) else {
            throw GarageMCPToolCallError(result.text.isEmpty ? "The model gave no answer." : result.text)
        }
        return reply
    }
}

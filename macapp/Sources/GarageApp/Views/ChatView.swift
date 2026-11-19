import AppKit
import GarageAppExtensionKit
import SwiftUI

/// The Chat page: a conversation with a model that searches and reads the corpus. This Mac's own model answers
/// through `rag_agent` on the MCP service (over XPC, so the HTTP server need not be on); a build's extensions may
/// add answerers that run elsewhere. The page's wording and rules are in `ChatPresentation`.
struct ChatView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var session: ChatSession
    /// Shows a cited document that is not a file on the Documents page.
    var openDocument: (DocumentFocus) -> Void = { _ in }

    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    private var localBackend: GarageChatBackend {
        let model = appState.effectiveInferenceModel
        return ChatPresentation.localBackend(
            model: model,
            displayName: appState.inferencePresets.first { $0.slug == model }?.name,
            provider: appState.inferenceProvider ?? appState.factsProvider,
            databaseRunning: appState.postgres.status == .running
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            composer
        }
        .navigationTitle("Chat")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { backendPicker }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    session.startOver()
                    composerFocused = true
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
                .help("Start a new conversation")
                .disabled(session.exchanges.isEmpty)
                .accessibilityIdentifier("chat.new")
            }
        }
        .task(id: localBackend) {
            await session.refreshBackends(local: localBackend)
        }
        .onAppear { composerFocused = true }
    }

    // MARK: - Who answers

    private var backendPicker: some View {
        Menu {
            Picker("Answer with", selection: $session.selectedBackendID) {
                ForEach(session.backends) { backend in
                    Label {
                        Text(backend.title)
                    } icon: {
                        Image(systemName: backend.symbol)
                    }
                    .tag(backend.id)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(session.selectedBackend?.title ?? "Model", systemImage: session.selectedBackend?.symbol ?? "cpu")
        }
        .help(session.selectedBackend?.detail ?? "Who answers")
        .disabled(session.isAnswering)
        .accessibilityIdentifier("chat.backend")
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if session.exchanges.isEmpty {
                        emptyState
                    }
                    ForEach(session.exchanges) { exchange in
                        exchangeView(exchange)
                            .id(exchange.id)
                    }
                }
                .padding(20)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: session.exchanges) { _, exchanges in
                guard let last = exchanges.last else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.indigo)
                .accessibilityHidden(true)
            Text(ChatPresentation.emptyTitle)
                .font(.title2.weight(.semibold))
            Text(ChatPresentation.emptyMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            if let backend = session.selectedBackend {
                Label(backend.detail, systemImage: backend.leavesThisMac ? "network" : "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 6) {
                ForEach(ChatPresentation.suggestions, id: \.self) { suggestion in
                    Button(suggestion) { ask(suggestion) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!canSend)
                }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
        .accessibilityIdentifier("chat.empty")
    }

    private func exchangeView(_ exchange: ChatExchange) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer(minLength: 80)
                Text(exchange.question)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityIdentifier("chat.question")
            }
            answerView(exchange)
        }
    }

    @ViewBuilder
    private func answerView(_ exchange: ChatExchange) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: exchange.backend.symbol)
                    .foregroundStyle(.indigo)
                    .accessibilityHidden(true)
                Text(exchange.backend.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if exchange.backend.leavesThisMac {
                    Image(systemName: "network")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help(exchange.backend.detail)
                        .accessibilityLabel("Answered off this Mac")
                }
            }
            switch exchange.state {
            case .answering:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Searching your corpus and answering\u{2026}")
                        .foregroundStyle(.secondary)
                    Button("Stop", role: .destructive) { session.stop() }
                        .controlSize(.small)
                        .accessibilityIdentifier("chat.stop")
                }
            case .stopped:
                Text("Stopped.")
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("chat.error")
            case .answered(let reply):
                replyView(reply)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func replyView(_ reply: GarageChatReply) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ChatPresentation.attributedAnswer(reply.answer))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("chat.answer")
            if !reply.citations.isEmpty {
                Text("Based on")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                WrappingHStack(spacing: 6) {
                    ForEach(reply.citations) { citation in
                        citationButton(citation)
                    }
                }
            }
            HStack(spacing: 8) {
                Text(ChatPresentation.footnote(reply))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help(reply.steps.joined(separator: "\n"))
                    .accessibilityIdentifier("chat.footnote")
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(reply.answer, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy the answer")
                .accessibilityLabel("Copy the answer")
            }
        }
    }

    private func citationButton(_ citation: GarageChatCitation) -> some View {
        Button {
            open(citation)
        } label: {
            Label(ChatPresentation.title(of: citation), systemImage: MenuBarQuickSearch.symbol(forCorpusClass: citation.corpusClass))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 240)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(citation.snippet.isEmpty ? citation.location : citation.snippet)
        .accessibilityIdentifier("chat.citation")
    }

    /// A file opens in its own app; anything else (a message, a document without a path) on the Documents page.
    private func open(_ citation: GarageChatCitation) {
        let path = (citation.location as NSString).expandingTildeInPath
        if let url = MenuBarQuickSearch.fileURL(forURI: path), FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else if let id = citation.documentID {
            openDocument(DocumentFocus(id: Int64(id), uri: path))
        }
    }

    // MARK: - Composer

    private var canSend: Bool {
        !session.isAnswering && session.selectedBackend?.unavailableReason == nil && session.selectedBackend != nil
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let reason = session.selectedBackend?.unavailableReason {
                Label(reason, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(placeholder, text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($composerFocused)
                    .onSubmit { ask(draft) }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityIdentifier("chat.composer")
                Button {
                    ask(draft)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Send (\u{2318}\u{21A9})")
                .accessibilityLabel("Send")
                .accessibilityIdentifier("chat.send")
            }
        }
        .padding(12)
    }

    private var placeholder: String {
        if let backend = session.selectedBackend {
            return session.exchanges.isEmpty ? "Ask \(backend.title) about your files" : "Ask a follow-up"
        }
        return "Ask about your files"
    }

    private func ask(_ text: String) {
        guard canSend, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        session.send(text)
        draft = ""
        composerFocused = true
    }
}

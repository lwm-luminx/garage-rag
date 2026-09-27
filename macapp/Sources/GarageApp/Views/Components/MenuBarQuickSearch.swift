import AppKit
import SwiftUI

/// The search field at the top of the menu bar popover: the first five hybrid-search hits for
/// whatever is typed, a quarter of a second after typing stops. A hit opens the file it came from;
/// Return, or "See all results", hands the query to the Search page.
///
/// The same field asks: "Ask Garage" (the first row under the field, or Shift-Return) sends the
/// text as a question to `rag_agent` on the MCP server, where the local model searches and reads
/// the corpus with Garage's own tools and answers. The answer shows under the field with the
/// documents it rests on and the steps the model took.
struct MenuBarQuickSearch: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    /// Off while the database is down, when there is nothing to search.
    let isEnabled: Bool
    /// Whether "Ask Garage" is offered: the MCP server has to be up to run `rag_agent`.
    var canAsk: Bool = false

    @State private var query = ""
    @State private var results: [SearchResultItem] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var askTask: Task<Void, Never>?
    @State private var isAsking = false
    /// The question the answer (or the running ask) is for; the field may have moved on.
    @State private var askedQuestion: String?
    @State private var answer: MenuBarAnswer?
    @State private var askError: String?
    @FocusState private var isFieldFocused: Bool
    /// The popover's window, so the field can take focus each time it opens: the menu bar extra
    /// keeps its view alive between openings, so `onAppear` alone only fires the first time.
    @State private var popoverWindow: NSWindow?

    static let resultLimit = 5
    static let citationLimit = 4
    static let debounce: Duration = .milliseconds(250)

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var showsAskRow: Bool {
        canAsk && isEnabled && !trimmedQuery.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            field

            if isAsking || answer != nil || askError != nil {
                answerModule
            }

            if !results.isEmpty || showsAskRow {
                MenuBarModule {
                    if showsAskRow {
                        askRow
                    }
                    ForEach(results) { hit in
                        resultRow(hit)
                    }
                    if !results.isEmpty {
                        seeAllRow
                    }
                }
                .accessibilityIdentifier("menubar.search.results")
            }
            if results.isEmpty {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.horizontal, 4)
                } else if !trimmedQuery.isEmpty, !isSearching {
                    Text("No matches")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
            }
        }
        .onChange(of: query) { _, _ in
            schedule()
        }
        .onChange(of: isEnabled) { _, enabled in
            if enabled { focusField() } else { clear() }
        }
        .onChange(of: canAsk) { _, can in
            if !can { clearAnswer() }
        }
        .background(WindowReader { popoverWindow = $0 })
        .onAppear(perform: focusField)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow, window === popoverWindow else { return }
            focusField()
        }
    }

    /// Puts the cursor in the field, so typing right after clicking the menu bar item searches.
    private func focusField() {
        guard isEnabled else { return }
        // The window has to be key before a field in it can take focus.
        DispatchQueue.main.async {
            isFieldFocused = true
        }
    }

    private var field: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(placeholder, text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isFieldFocused)
                .onSubmit(submit)
                .disabled(!isEnabled)
                .accessibilityIdentifier("menubar.search.field")
            if isSearching {
                ProgressView()
                    .controlSize(.small)
            } else if !query.isEmpty {
                Button {
                    clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var placeholder: String {
        guard isEnabled else { return "Search needs the database" }
        return canAsk ? "Search or ask your corpus" : "Search your corpus"
    }

    /// Return searches in the window; Shift-Return asks, like the row.
    private func submit() {
        if showsAskRow, NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            ask()
        } else {
            showAll()
        }
    }

    // MARK: - Ask Garage

    /// The first row under the field: hands the text to the local model as a question.
    private var askRow: some View {
        MenuBarRow(
            symbol: "sparkles",
            tint: .indigo,
            title: "Ask Garage",
            detail: isAsking ? "Answering\u{2026}" : "Have the local model search and read your corpus (\u{21E7}\u{21A9})",
            showsChevron: false,
            action: ask
        )
        .disabled(isAsking)
        .accessibilityIdentifier("menubar.ask")
    }

    /// The answer, the documents it rests on, and how the model got there.
    private var answerModule: some View {
        MenuBarModule {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.indigo)
                        .accessibilityHidden(true)
                    Text(askedQuestion ?? "")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    if isAsking {
                        ProgressView()
                            .controlSize(.small)
                        MenuBarActionButton(title: "Stop", isDestructive: true, action: clearAnswer)
                            .accessibilityIdentifier("menubar.ask.stop")
                    } else {
                        if let answer {
                            Button {
                                NSPasteboard.general.copy(answer.answer)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Copy the answer")
                            .accessibilityLabel("Copy the answer")
                        }
                        Button(action: clearAnswer) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss the answer")
                    }
                }

                if isAsking {
                    Text("The local model is searching your corpus\u{2026}")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if let askError {
                    Text(askError)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("menubar.ask.error")
                } else if let answer {
                    Text(answer.answer)
                        .font(.system(size: 12))
                        .lineLimit(14)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("menubar.ask.answer")

                    if !answer.citations.isEmpty {
                        Text("Based on")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 2)
                        ForEach(answer.citations.prefix(Self.citationLimit)) { citation in
                            citationRow(citation)
                        }
                    }

                    Text(answer.footnote)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .padding(.top, 2)
                        .accessibilityIdentifier("menubar.ask.footnote")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
        }
        .accessibilityIdentifier("menubar.ask.result")
    }

    private func citationRow(_ citation: MenuBarAnswer.Citation) -> some View {
        Button {
            open(location: citation.fileURL)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: Self.symbol(forCorpusClass: citation.corpusClass))
                    .font(.system(size: 10))
                    .foregroundStyle(Self.tint(forCorpusClass: citation.corpusClass))
                    .frame(width: 14)
                    .accessibilityHidden(true)
                Text(citation.displayTitle)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Text(citation.location)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuBarRowButtonStyle())
        .accessibilityIdentifier("menubar.ask.citation")
    }

    private func resultRow(_ hit: SearchResultItem) -> some View {
        MenuBarRow(
            symbol: Self.symbol(forCorpusClass: hit.corpusClass),
            tint: Self.tint(forCorpusClass: hit.corpusClass),
            title: hit.displayTitle,
            detail: Self.oneLine(hit.snippet.isEmpty ? hit.text : hit.snippet),
            showsChevron: false,
            action: { open(hit) }
        )
        .accessibilityIdentifier("menubar.search.result")
    }

    private var seeAllRow: some View {
        Button(action: showAll) {
            HStack {
                Text("See all results in Garage")
                    .font(.system(size: 12))
                Spacer()
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuBarRowButtonStyle())
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .accessibilityIdentifier("menubar.search.all")
    }

    // MARK: - Behaviour

    private func schedule() {
        searchTask?.cancel()
        errorMessage = nil
        let text = trimmedQuery
        guard isEnabled, !text.isEmpty else {
            results = []
            isSearching = false
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            isSearching = true
            defer { isSearching = false }
            do {
                let hits = try await appState.search(query: text, limit: Self.resultLimit)
                guard !Task.isCancelled else { return }
                results = hits
            } catch {
                guard !Task.isCancelled else { return }
                results = []
                errorMessage = error.localizedDescription
            }
        }
    }

    private func clear() {
        searchTask?.cancel()
        query = ""
        results = []
        errorMessage = nil
        isSearching = false
        clearAnswer()
    }

    /// Sends the field's text to `rag_agent` and shows what comes back. One ask at a time: a new
    /// one replaces a running one.
    private func ask() {
        let question = trimmedQuery
        guard showsAskRow, !question.isEmpty else { return }
        askTask?.cancel()
        askedQuestion = question
        answer = nil
        askError = nil
        isAsking = true
        askTask = Task {
            defer { if !Task.isCancelled { isAsking = false } }
            do {
                let output = try await appState.mcp.executeToolCall(
                    toolName: "rag_agent",
                    arguments: ["question": question],
                    timeout: GarageMCPService.generationTimeout
                )
                guard !Task.isCancelled else { return }
                if let parsed = MenuBarAnswer.parse(output) {
                    answer = parsed
                } else {
                    askError = Self.oneLine(output)
                }
            } catch {
                guard !Task.isCancelled else { return }
                askError = error.localizedDescription
            }
        }
    }

    private func clearAnswer() {
        askTask?.cancel()
        askTask = nil
        isAsking = false
        askedQuestion = nil
        answer = nil
        askError = nil
    }

    /// A file hit opens in its own app; anything else (a message, a document without a path) goes
    /// to the Search page, where the full text is.
    private func open(_ hit: SearchResultItem) {
        open(location: Self.fileURL(forURI: hit.uri))
    }

    private func open(location url: URL?) {
        if let url, FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
            return
        }
        showAll()
    }

    /// Ingested files store a plain absolute path as their URI; a few carry a `file://` URL. Anything
    /// else (a message id, another scheme) is not a file to open.
    nonisolated static func fileURL(forURI uri: String) -> URL? {
        if uri.hasPrefix("/") {
            return URL(fileURLWithPath: uri)
        }
        if let url = URL(string: uri), url.isFileURL {
            return url
        }
        return nil
    }

    private func showAll() {
        let text = trimmedQuery
        guard !text.isEmpty else { return }
        MenuBarNavigation.show(.search, query: text, openWindow: openWindow)
    }

    // MARK: - Presentation

    static func symbol(forCorpusClass corpusClass: String) -> String {
        switch corpusClass.lowercased() {
        case "code": "chevron.left.forwardslash.chevron.right"
        case "communication": "bubble.left.and.bubble.right"
        default: "doc.text"
        }
    }

    static func tint(forCorpusClass corpusClass: String) -> Color {
        switch corpusClass.lowercased() {
        case "code": .purple
        case "communication": .green
        default: .blue
        }
    }

    /// Collapses a snippet's whitespace so it fits one row.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

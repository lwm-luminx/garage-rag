import SwiftUI
import AppKit

// The Try It panel: one place to call the running server the way an assistant would. Ask the
// corpus runs rag_ask (retrieve, then answer with citations), Prompt the model runs rag_generate
// on the raw prompt, and Call a tool runs any tool the server lists with its arguments.

extension MCPServerView {
    enum TryItMode: String, CaseIterable, Identifiable {
        case ask = "Ask the Corpus"
        case prompt = "Prompt the Model"
        case tool = "Call a Tool"

        var id: Self { self }
        var defaultMaxTokens: Int { self == .ask ? 512 : 256 }
        var defaultTemperature: Double { self == .ask ? 0.2 : 0.7 }
    }

    /// The tools offered when the server has not been checked yet: the ones that need at most one
    /// argument, which is what the panel was built around.
    static let fallbackToolNames = ["rag_search", "rag_stats", "rag_list_sources", "rag_list_authors", "rag_get_document"]

    /// The tools the server listed at its last check, or the fallback list before one.
    var availableTools: [MCPToolInfo] {
        if let tools = appState.mcp.lastTestResult?.tools, !tools.isEmpty {
            return tools
        }
        return Self.fallbackToolNames.map { MCPToolInfo(name: $0, description: "") }
    }

    var selectedTool: MCPToolInfo? {
        availableTools.first { $0.name == selectedToolName }
    }

    var tryItSection: some View {
        GroupBox("Try It") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Picker("Mode", selection: $tryMode) {
                        ForEach(TryItMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 420)
                    .accessibilityIdentifier("mcp.try.mode")
                    .onChange(of: tryMode) { _, mode in
                        tryMaxTokens = mode.defaultMaxTokens
                        tryTemperature = mode.defaultTemperature
                        tryError = nil
                        tryAnswer = nil
                        tryRawOutput = nil
                    }
                    Spacer()
                }

                Text(modeExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                switch tryMode {
                case .ask, .prompt:
                    promptInput
                case .tool:
                    toolInput
                }

                if !isRunning {
                    Label("Start the server to try it.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let error = tryError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("mcp.try.error")
                }

                if let answer = tryAnswer {
                    answerView(answer)
                } else if let raw = tryRawOutput, !raw.isEmpty {
                    outputBox(title: tryMode == .tool ? "Response" : "Output", text: raw)
                }
            }
            .padding(10)
        }
    }

    private var modeExplanation: String {
        switch tryMode {
        case .ask:
            "Searches your corpus and answers with citations, as rag_ask does for an assistant. Runs on \(factsModelDescription)."
        case .prompt:
            "Sends the prompt as it is to \(factsModelDescription) through rag_generate, with nothing retrieved."
        case .tool:
            "Calls one of the server's tools and shows exactly what an assistant would receive."
        }
    }

    private var factsModelDescription: String {
        let model = appState.factsModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return "the distillation model (pick one on the Models page)" }
        return "\(model) via \(appState.factsProvider)"
    }

    private var isPromptEmpty: Bool {
        tryPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var promptInput: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $tryPrompt)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .frame(minHeight: 72, maxHeight: 160)
                    .accessibilityIdentifier("mcp.try.prompt")
                if tryPrompt.isEmpty {
                    Text(tryMode == .ask ? "What did I decide about the secure boot chain?" : "Write a haiku about a garage.")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .allowsHitTesting(false)
                }
            }
            .background(Color.primary.opacity(0.03))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 16) {
                Stepper("Up to \(tryMaxTokens) tokens", value: $tryMaxTokens, in: 16...4096, step: 16)
                    .font(.caption)
                    .fixedSize()
                HStack(spacing: 6) {
                    Text("Temperature")
                        .font(.caption)
                    Slider(value: $tryTemperature, in: 0...1.5, step: 0.05)
                        .frame(width: 120)
                    Text(String(format: "%.2f", tryTemperature))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .leading)
                }
                Spacer()
                runButton(disabled: isPromptEmpty)
            }
        }
    }

    private var toolInput: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Picker("Tool", selection: $selectedToolName) {
                    ForEach(availableTools) { tool in
                        Text(tool.name).tag(tool.name)
                    }
                }
                .frame(width: 240)
                .accessibilityIdentifier("mcp.try.tool")

                switch toolArgumentKind {
                case .query:
                    TextField("Search for…", text: $toolQuery)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                case .documentId:
                    TextField("Document ID", text: $toolDocumentId)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                case .noArguments, .json:
                    EmptyView()
                }
                Spacer()
                runButton(disabled: !isToolInputValid)
            }

            if let description = selectedTool?.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            if toolArgumentKind == .json {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Arguments (JSON)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $toolArgumentsJSON)
                        .font(.system(.caption, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .frame(minHeight: 48, maxHeight: 120)
                        .background(Color.primary.opacity(0.03))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    if parsedToolArguments == nil {
                        Text("Not a JSON object.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    private func runButton(disabled: Bool) -> some View {
        HStack(spacing: 8) {
            if isRunningTry {
                ProgressView().controlSize(.small)
            }
            Button {
                runTry()
            } label: {
                Label("Run", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!isRunning || isRunningTry || disabled)
            .help("Run (⌘↩)")
            .accessibilityIdentifier("mcp.try.run")
        }
    }

    // MARK: Tool arguments

    enum ToolArgumentKind {
        case noArguments, query, documentId, json
    }

    /// The input the selected tool needs: one field for the two tools that take one argument, none
    /// for a tool whose schema lists no properties, a JSON object for anything else.
    var toolArgumentKind: ToolArgumentKind {
        switch selectedToolName {
        case "rag_search": return .query
        case "rag_get_document": return .documentId
        case "rag_stats", "rag_list_sources", "rag_list_authors": return .noArguments
        default:
            guard let schema = selectedTool?.inputSchemaJson,
                  let data = schema.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .json
            }
            let properties = (object["properties"] as? [String: Any]) ?? [:]
            return properties.isEmpty ? .noArguments : .json
        }
    }

    private var parsedDocumentId: Int? {
        Int(toolDocumentId.trimmingCharacters(in: .whitespaces))
    }

    private var parsedToolArguments: [String: Any]? {
        let text = toolArgumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return [:] }
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private var isToolInputValid: Bool {
        switch toolArgumentKind {
        case .noArguments: true
        case .query: !toolQuery.trimmingCharacters(in: .whitespaces).isEmpty
        case .documentId: parsedDocumentId != nil
        case .json: parsedToolArguments != nil
        }
    }

    private var toolArguments: [String: Any] {
        switch toolArgumentKind {
        case .noArguments:
            return [:]
        case .query:
            return ["query": toolQuery]
        case .documentId:
            guard let documentId = parsedDocumentId else { return [:] }
            return ["document_id": documentId]
        case .json:
            return parsedToolArguments ?? [:]
        }
    }

    // MARK: Output

    private func answerView(_ answer: PlaygroundAnswer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(tryMode == .ask ? "Answer" : "Completion")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                if let model = answer.model, !model.isEmpty {
                    Text(answer.provider.map { "\(model) via \($0)" } ?? model)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.copy(answer.displayText)
                }
                .controlSize(.small)
            }

            ScrollView {
                Text(answer.displayText)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("mcp.try.answer")
            }
            .frame(maxHeight: 220)
            .padding(8)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            if let citations = answer.citations, !citations.isEmpty {
                Text("Sources")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                MenuBarModule {
                    ForEach(citations) { citation in
                        if citation.id != citations.first?.id {
                            Divider().padding(.leading, 40)
                        }
                        citationRow(citation)
                    }
                }
            }
        }
    }

    private func citationRow(_ citation: PlaygroundCitation) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(citation.n)")
                .font(.system(.caption, design: .monospaced).bold())
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(citation.title ?? "Untitled")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .accessibilityIdentifier("mcp.try.citation.\(citation.n).title")
                    Spacer(minLength: 4)
                    if let score = citation.score {
                        Text(String(format: "%.3f", score))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .help("Retrieval score")
                    }
                }
                if let location = citation.location, !location.isEmpty {
                    Text(location)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let snippet = citation.snippet, !snippet.isEmpty {
                    Text(snippet)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func outputBox(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.copy(text)
                }
                .controlSize(.small)
            }
            MonospaceOutputBox(text, maxHeight: 240)
        }
    }

    // MARK: Running

    /// Sends the request as an MCP `tools/call` to the running garage-mcp server, the path an
    /// assistant takes, so what comes back is exactly what it would see.
    func runTry() {
        let mode = tryMode
        let toolName: String
        var args: [String: Any]
        switch mode {
        case .ask, .prompt:
            let prompt = tryPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else { return }
            args = ["max_tokens": tryMaxTokens, "temperature": tryTemperature]
            if mode == .ask {
                toolName = "rag_ask"
                args["question"] = prompt
                args["limit"] = 6
            } else {
                toolName = "rag_generate"
                args["prompt"] = prompt
            }
        case .tool:
            guard isToolInputValid else { return }
            toolName = selectedToolName
            args = toolArguments
        }

        isRunningTry = true
        tryError = nil
        tryAnswer = nil
        tryRawOutput = nil
        Task {
            defer { isRunningTry = false }
            do {
                let output = try await appState.mcp.executeToolCall(toolName: toolName, arguments: args)
                if mode != .tool,
                   let data = output.data(using: .utf8),
                   let parsed = try? JSONDecoder().decode(PlaygroundAnswer.self, from: data),
                   parsed.hasText {
                    tryAnswer = parsed
                } else {
                    tryRawOutput = output
                }
            } catch {
                tryError = error.localizedDescription
            }
        }
    }
}

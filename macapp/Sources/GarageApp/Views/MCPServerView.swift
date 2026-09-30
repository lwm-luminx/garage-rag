import SwiftUI
import AppKit
import PythonXPCService

/// One citation in a `rag_ask` result.
struct PlaygroundCitation: Decodable, Identifiable {
    let n: Int
    let documentId: Int?
    let title: String?
    let location: String?
    let snippet: String?
    let score: Double?

    var id: Int { n }

    enum CodingKeys: String, CodingKey {
        case n, title, location, snippet, score
        case documentId = "document_id"
    }
}

/// The JSON a `rag_ask` (`answer` + `citations`) or `rag_generate` (`text`) tool call returns.
struct PlaygroundAnswer: Decodable {
    let answer: String?
    let text: String?
    let model: String?
    let provider: String?
    let citations: [PlaygroundCitation]?

    var displayText: String { answer ?? text ?? "" }
    var hasText: Bool { answer != nil || text != nil }
}

/// The MCP Server page: is the server up and answering, which assistants reach Garage through it,
/// and a place to try it the way an assistant would.
///
/// The server is one row with its state in words and the one action that applies; the port, path
/// and tool list sit behind Details. Each assistant is one row saying whether it is connected, with
/// Connect or Update when it is not. Trying the server is one panel with three modes (ask the
/// corpus, prompt the model, call a tool) in place of the old tester and playground boxes.
@MainActor
struct MCPServerView: View {
    @EnvironmentObject var appState: AppState

    /// A start, stop, restart or registration from this page is in flight.
    @State var busy = false
    @State var showServerDetails = false
    @State var showMissingClients = false
    /// What the last Connect, Update, Disconnect or check said, shown under the assistant list.
    @State var registrationMessage: String?
    @State var registrationSucceeded = true
    @AppStorage("garage.mcp.showServerOutput") var showServerOutput = false

    // Try It
    @State var tryMode: TryItMode = .ask
    @State var tryPrompt = ""
    @State var tryMaxTokens: Int = TryItMode.ask.defaultMaxTokens
    @State var tryTemperature: Double = TryItMode.ask.defaultTemperature
    @State var selectedToolName = "rag_search"
    @State var toolQuery = "secure boot"
    @State var toolDocumentId = "1"
    @State var toolArgumentsJSON = "{}"
    @State var isRunningTry = false
    @State var tryError: String?
    @State var tryAnswer: PlaygroundAnswer?
    @State var tryRawOutput: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                serverSection
                assistantsSection
                tryItSection
                serverOutputSection
            }
            .padding(20)
        }
        .navigationTitle("MCP Server")
        .onAppear {
            appState.mcp.refreshDetectedClients()
            appState.fetchFactsSettings()
            if appState.mcp.status == .running && appState.mcp.lastTestResult == nil {
                checkServer()
            }
        }
        .onChange(of: appState.mcp.status) { _, status in
            // A fresh start answers "does it answer" without a click.
            if status == .running {
                checkServer()
            }
        }
    }

    // MARK: - Server

    var isRunning: Bool { appState.mcp.status == .running }

    /// A detected assistant with what its row says.
    struct ClientItem: Identifiable {
        let client: MCPClientConfig
        let row: MCPClientRowPresentation
        var id: String { client.id }
    }

    private var clientRows: [ClientItem] {
        appState.mcp.detectedClients.map { ClientItem(client: $0, row: MCPClientRowPresentation(client: $0, endpoint: appState.mcp.registrationEndpoint)) }
    }

    private var headline: MCPServerHeadline {
        MCPServerHeadline(
            status: appState.mcp.status,
            test: appState.mcp.lastTestResult,
            isTesting: appState.mcp.isTesting,
            isDatabaseRunning: appState.postgres.status == .running,
            connectedCount: appState.mcp.detectedClients.filter(\.isRegistered).count,
            httpEnabled: appState.mcp.httpEnabled
        )
    }

    private var serverSection: some View {
        let headline = self.headline
        return GroupBox("Server") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    MenuBarSymbolCircle(symbol: headline.symbol, tint: headline.tint, isActive: headline.isActive)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(headline.title)
                            .font(.system(size: 13, weight: .semibold))
                        Text(headline.detail)
                            .font(.caption)
                            .foregroundStyle(headline.detailIsError ? AnyShapeStyle(Color.red) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 8)

                    if appState.mcp.status.isTransitioning || busy || appState.mcp.isTesting {
                        ProgressView().controlSize(.small)
                    }
                    serverActions
                }

                HStack(spacing: 6) {
                    Text(appState.mcp.endpoint.absoluteString)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Button {
                        NSPasteboard.general.copy(appState.mcp.endpoint.absoluteString)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Copy the server's address")
                    .accessibilityLabel("Copy Address")
                    .accessibilityIdentifier("mcp.copyEndpoint")

                    Spacer()

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showServerDetails.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Details")
                                .font(.caption)
                            DisclosureChevron(isExpanded: showServerDetails)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("mcp.details.toggle")
                }
                .padding(.leading, 36)

                if showServerDetails {
                    serverDetails
                        .padding(.leading, 36)
                }
            }
            .padding(10)
        }
    }

    /// Start while stopped; Test, Restart and Stop while it runs. Never all four at once.
    @ViewBuilder
    private var serverActions: some View {
        switch appState.mcp.status {
        case .running:
            Button("Test", action: checkServer)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(appState.mcp.isTesting || busy)
                .help("Check that the server answers and list its tools")
                .accessibilityIdentifier("mcp.test")
            Button("Restart", action: restartServer)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(busy)
                .accessibilityIdentifier("mcp.restart")
            Button("Stop", action: stopServer)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(busy)
                .accessibilityIdentifier("mcp.stop")
        case .starting, .stopping:
            EmptyView()
        case .stopped, .failed:
            Button(appState.mcp.status == .stopped ? "Start" : "Try Again", action: startServer)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(busy)
                .accessibilityIdentifier("mcp.start")
        }
    }

    private var serverDetails: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                detailLabel("Port")
                HStack(spacing: 8) {
                    TextField(
                        "Port",
                        value: Binding(
                            get: { appState.mcp.port },
                            set: { newPort in
                                if (1...65535).contains(newPort) {
                                    appState.mcp.port = newPort
                                }
                            }
                        ),
                        format: .number.grouping(.never)
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .disabled(portLocked)
                    .accessibilityIdentifier("mcp.port")

                    Button("Random") {
                        appState.mcp.selectRandomPort()
                    }
                    .controlSize(.small)
                    .disabled(portLocked)

                    Text(portLocked ? "Stop the server to change it." : "Connected assistants need Update after a change.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            GridRow {
                detailLabel("Path")
                detailValue(appState.mcp.path)
            }
            GridRow {
                detailLabel("Transport")
                detailValue("HTTP on \(appState.mcp.host), reachable from this Mac only")
            }
            GridRow {
                detailLabel("Database")
                detailValue(appState.postgres.status == .running ? "Running on port \(appState.postgres.port)" : "Stopped")
            }
            if let test = appState.mcp.lastTestResult, test.isSuccess {
                GridRow {
                    detailLabel("Last check")
                    detailValue("Answered in \(String(format: "%.0f", test.latencyMs)) ms, \(test.timestamp.formatted(date: .omitted, time: .shortened))")
                }
                if !test.tools.isEmpty {
                    GridRow(alignment: .top) {
                        detailLabel("Tools")
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(test.tools) { tool in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(tool.name)
                                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                                    if !tool.description.isEmpty {
                                        Text(tool.description)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                            .help(tool.description)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var portLocked: Bool {
        appState.mcp.status == .running || appState.mcp.status == .starting || busy
    }

    private func detailLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    private func detailValue(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
    }

    // MARK: - Assistants

    private var assistantsSection: some View {
        let rows = clientRows
        let installed = rows.filter { $0.row.state != .notInstalled }
        let missing = rows.filter { $0.row.state == .notInstalled }
        let canConnectAll = MCPPagePresentation.canConnectAll(rows.map(\.row))

        return GroupBox("Connected Assistants") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(MCPPagePresentation.clientSummary(rows.map(\.row)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if appState.mcp.isRegistering {
                        ProgressView().controlSize(.small)
                    }
                    connectAllButton(prominent: canConnectAll)
                        .disabled(busy || appState.mcp.isRegistering || !canConnectAll)
                    Button {
                        appState.mcp.refreshDetectedClients()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Look for assistants again")
                    .accessibilityLabel("Look for Assistants Again")
                    .accessibilityIdentifier("mcp.rescan")
                    .disabled(busy || appState.mcp.isRegistering)
                    Menu {
                        Button("Connect a Config File…", action: chooseCustomConfigFile)
                        Button("Check Registrations", action: checkRegistrations)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(busy || appState.mcp.isRegistering)
                    .accessibilityLabel("More")
                    .accessibilityIdentifier("mcp.assistants.more")
                }

                if installed.isEmpty {
                    Text("None of the assistants Garage knows about has a configuration file on this Mac. Connect one below to create it, or connect a config file of your own from the ⋯ menu.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    MenuBarModule {
                        ForEach(installed) { item in
                            if item.id != installed.first?.id {
                                Divider().padding(.leading, 46)
                            }
                            clientRow(item.client, item.row)
                        }
                    }
                }

                if !missing.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showMissingClients.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            DisclosureChevron(isExpanded: showMissingClients)
                            Text("Not found on this Mac")
                            Text("\(missing.count)")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("mcp.missingClients.toggle")

                    if showMissingClients {
                        MenuBarModule {
                            ForEach(missing) { item in
                                if item.id != missing.first?.id {
                                    Divider().padding(.leading, 46)
                                }
                                clientRow(item.client, item.row)
                            }
                        }
                    }
                }

                if let message = registrationMessage, !message.isEmpty {
                    registrationResult(message)
                }

                Text("A connected assistant receives the excerpts its searches return, not your whole index, and may send them to its own cloud model, including excerpts from Messages and Mail if you index them. What happens to them then is up to that assistant's privacy terms, not Garage's.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("mcp.agentPrivacy")
            }
            .padding(10)
        }
    }

    @ViewBuilder
    private func connectAllButton(prominent: Bool) -> some View {
        if prominent {
            Button("Connect All", action: connectAll)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Add Garage to every assistant found on this Mac, and update the ones pointing at an old address")
                .accessibilityIdentifier("mcp.connectAll")
        } else {
            Button("Connect All", action: connectAll)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Every assistant found on this Mac is already connected")
                .accessibilityIdentifier("mcp.connectAll")
        }
    }

    private func clientRow(_ client: MCPClientConfig, _ row: MCPClientRowPresentation) -> some View {
        let home = GarageAppGroup.clientHomeDirectory

        return HStack(alignment: .center, spacing: 10) {
            MenuBarSymbolCircle(symbol: row.symbol, tint: row.tint, isActive: row.isActive)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(client.label)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if client.isProjectScoped {
                        StatusBadge("PROJECT", tint: .orange)
                            .help("Kept in the project folder and shared with anyone who has it")
                    }
                }
                Text(row.status)
                    .font(.caption)
                    .foregroundStyle(row.isOutdated ? AnyShapeStyle(Color.orange) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                    .lineLimit(2)
                Text(client.path.path.replacingOccurrences(of: home, with: "~"))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(client.note.isEmpty ? client.path.path : "\(client.path.path)\n\(client.note)")
            }
            Spacer(minLength: 8)

            if let action = row.actionTitle {
                Button(action) {
                    registerClient(client.id)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(busy || appState.mcp.isRegistering)
                .accessibilityIdentifier("mcp.client.\(client.id).connect")
            }

            Menu {
                if client.isRegistered {
                    Button("Connect Again") { registerClient(client.id) }
                }
                if client.existsOnDisk {
                    Button("Open Config File") { NSWorkspace.shared.open(client.path) }
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([client.path]) }
                }
                Button("Copy Path") { NSPasteboard.general.copy(client.path.path) }
                if client.isRegistered {
                    Divider()
                    Button("Disconnect", role: .destructive) { unregisterClient(client.id) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(busy || appState.mcp.isRegistering)
            .accessibilityLabel("More for \(client.label)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mcp.client.\(client.id)")
    }

    private func registrationResult(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: registrationSucceeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(registrationSucceeded ? .green : .red)
            Text(message)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button {
                registrationMessage = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .accessibilityLabel("Dismiss")
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((registrationSucceeded ? Color.primary : Color.red).opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Server output

    @ViewBuilder
    private var serverOutputSection: some View {
        if !appState.mcp.logs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showServerOutput.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        DisclosureChevron(isExpanded: showServerOutput)
                        Text("Server Output")
                        Text("\(appState.mcp.logs.count.formatted()) \(MCPPagePresentation.plural("line", appState.mcp.logs.count))")
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("mcp.serverOutput.toggle")

                if showServerOutput {
                    LogTableView(lines: appState.mcp.logs, sourceName: "garage-mcp") {
                        appState.mcp.clearLogs()
                    }
                    .frame(height: 280)
                }
            }
        }
    }

    // MARK: - Actions

    /// Starting the server turns HTTP on for later launches too; stopping it turns HTTP off.
    private func startServer() {
        busy = true
        appState.mcp.setHTTPEnabled(true)
        Task {
            if appState.postgres.status != .running {
                await appState.startPostgres()
            } else {
                try? await appState.mcp.start()
            }
            busy = false
        }
    }

    private func stopServer() {
        busy = true
        appState.mcp.setHTTPEnabled(false)
        Task {
            await appState.mcp.stop()
            busy = false
        }
    }

    private func restartServer() {
        busy = true
        Task {
            await appState.mcp.stop()
            if appState.postgres.status != .running {
                await appState.startPostgres()
            } else {
                try? await appState.mcp.start()
            }
            busy = false
        }
    }

    /// Initializes a session and lists the tools, without calling one: the headline then says
    /// whether the server answers and how many tools it offers.
    func checkServer() {
        guard !appState.mcp.isTesting else { return }
        Task {
            await appState.mcp.testServerConnection(sampleTool: "")
        }
    }

    private func report(_ result: (success: Bool, message: String)) {
        registrationSucceeded = result.success
        registrationMessage = result.message
    }

    private func connectAll() {
        busy = true
        Task {
            report(await appState.mcp.registerInAllFoundConfigs(force: true))
            busy = false
        }
    }

    private func registerClient(_ clientId: String) {
        busy = true
        Task {
            report(await appState.mcp.registerTarget(clientId, force: true))
            busy = false
        }
    }

    private func unregisterClient(_ clientId: String) {
        busy = true
        Task {
            report(await appState.mcp.unregisterTarget(clientId))
            busy = false
        }
    }

    private func chooseCustomConfigFile() {
        let panel = NSOpenPanel()
        panel.title = "Select MCP Client Configuration File"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true
        Task {
            report(await appState.mcp.registerCustomConfigFile(at: url, force: true))
            busy = false
        }
    }

    private func checkRegistrations() {
        busy = true
        Task {
            let succeeded = await appState.runOperation { try await $0.mcpStatus().summary }
            appState.mcp.refreshDetectedClients()
            report((succeeded, appState.lastCommandOutput))
            busy = false
        }
    }
}

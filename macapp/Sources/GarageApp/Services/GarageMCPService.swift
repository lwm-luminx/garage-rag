import Foundation
import MCPServerClient
import PythonXPCService

enum GarageMCPStatus: Equatable {
    case stopped
    case starting
    case running
    case stopping
    case failed(String)
}

enum GarageMCPError: LocalizedError, Equatable {
    case databaseNotOnline
    case cliNotFound
    case startupTimeout
    case launchFailed(String)
    case serverNotRunning
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .databaseNotOnline:
            "Database is not online. MCP server requires an online database."
        case .cliNotFound:
            "garage CLI not found at \(Paths.garageCLI.path)"
        case .startupTimeout:
            "garage-mcp did not become ready within 10 seconds"
        case .launchFailed(let message):
            "failed to launch garage-mcp: \(message)"
        case .serverNotRunning:
            "MCP server is not running."
        case .invalidResponse(let message):
            "Invalid MCP server response: \(message)"
        }
    }
}

public struct MCPClientConfig: Identifiable, Equatable {
    public var id: String
    public var label: String
    public var path: URL
    public var existsOnDisk: Bool
    public var isRegistered: Bool
    /// The URL the registered entry points at, when it is an HTTP entry. A stdio entry, or no
    /// entry at all, has none.
    public var registeredURL: String?
    /// A config that lives in the current project (e.g. `.mcp.json`), shared with
    /// collaborators, as opposed to a per-user client config.
    public var isProjectScoped: Bool
    public var note: String

    public init(
        id: String,
        label: String,
        path: URL,
        existsOnDisk: Bool,
        isRegistered: Bool,
        isProjectScoped: Bool = false,
        note: String = "",
        registeredURL: String? = nil
    ) {
        self.id = id
        self.label = label
        self.path = path
        self.existsOnDisk = existsOnDisk
        self.isRegistered = isRegistered
        self.registeredURL = registeredURL
        self.isProjectScoped = isProjectScoped
        self.note = note
    }
}

public struct MCPToolInfo: Identifiable, Equatable, Hashable {
    public var id: String { name }
    public var name: String
    public var description: String
    public var inputSchemaJson: String?

    public init(name: String, description: String, inputSchemaJson: String? = nil) {
        self.name = name
        self.description = description
        self.inputSchemaJson = inputSchemaJson
    }
}

public struct MCPTestResult: Equatable {
    public var isSuccess: Bool
    public var timestamp: Date
    public var latencyMs: Double
    public var httpStatusCode: Int?
    public var tools: [MCPToolInfo]
    public var testedToolName: String?
    public var toolOutput: String?
    public var errorMessage: String?

    public init(
        isSuccess: Bool,
        timestamp: Date = Date(),
        latencyMs: Double = 0,
        httpStatusCode: Int? = nil,
        tools: [MCPToolInfo] = [],
        testedToolName: String? = nil,
        toolOutput: String? = nil,
        errorMessage: String? = nil
    ) {
        self.isSuccess = isSuccess
        self.timestamp = timestamp
        self.latencyMs = latencyMs
        self.httpStatusCode = httpStatusCode
        self.tools = tools
        self.testedToolName = testedToolName
        self.toolOutput = toolOutput
        self.errorMessage = errorMessage
    }
}

/// Owns the app-managed, loopback-only HTTP `garage-mcp` server.
///
/// The HTTP server is opt-in (`httpEnabled`). Off, the app opens no TCP port for MCP: assistants are
/// registered with the bundled `garage-mcp` launcher, which they run themselves over stdio.
@MainActor
final class GarageMCPService: ObservableObject {
    nonisolated static let defaultPort = 8787
    nonisolated static let portDefaultsKey = "garage.mcp.port"
    nonisolated static let httpEnabledDefaultsKey = "garage.mcp.httpEnabled"

    @Published private(set) var status: GarageMCPStatus = .stopped
    /// Whether the app serves MCP over HTTP on `endpoint`. Turned on by starting the server, off by
    /// stopping it; saved across launches.
    @Published private(set) var httpEnabled = false
    @Published private(set) var logs: [LogLine] = []
    @Published var port: Int {
        didSet {
            defaults.set(port, forKey: Self.portDefaultsKey)
        }
    }
    @Published private(set) var detectedClients: [MCPClientConfig] = []
    @Published private(set) var lastTestResult: MCPTestResult?
    @Published private(set) var isTesting: Bool = false
    @Published private(set) var isRegistering: Bool = false
    @Published private(set) var sessionId: String?

    let host = "127.0.0.1"
    let path = "/mcp"

    /// Client registration goes through the McpInstall RPC; AppState wires this up.
    weak var grpc: GarageGRPCService?

    /// Hands a config file chosen in an open panel to GarageXPCService, which runs McpInstall and,
    /// in the sandboxed build, can write nothing it was not granted. The known client configs are
    /// under the home folder, which reaches that service with the root grant (VolumeAccessService).
    /// AppState wires this up.
    var folderAccess: FolderAccessRelaying?

    private let postgres: PostgresService
    private let client: GarageMCPServerClient
    private let defaults: UserDefaults
    private let maxLogLines = 4000
    private var logPollTask: Task<Void, Never>?

    init(
        postgres: PostgresService,
        port: Int? = nil,
        client: GarageMCPServerClient = GarageMCPServerClient(),
        defaults: UserDefaults = .standard
    ) {
        self.postgres = postgres
        self.client = client
        self.defaults = defaults
        if let port {
            self.port = port
        } else {
            let savedPort = defaults.integer(forKey: Self.portDefaultsKey)
            self.port = (1...65535).contains(savedPort) ? savedPort : Self.defaultPort
        }
        refreshDetectedClients()
        if defaults.object(forKey: Self.httpEnabledDefaultsKey) != nil {
            httpEnabled = defaults.bool(forKey: Self.httpEnabledDefaultsKey)
        } else {
            // First launch of a build with the opt-in: keep HTTP on for someone whose assistants are
            // registered at its address, so they keep working; everyone else starts on stdio.
            httpEnabled = Self.hasHTTPRegistration(detectedClients)
            defaults.set(httpEnabled, forKey: Self.httpEnabledDefaultsKey)
        }
    }

    /// Whether any assistant is registered at an HTTP address rather than as a stdio command.
    nonisolated static func hasHTTPRegistration(_ clients: [MCPClientConfig]) -> Bool {
        clients.contains { $0.isRegistered && $0.registeredURL != nil }
    }

    /// Turns the HTTP server on or off for this and later launches. It does not start or stop it.
    func setHTTPEnabled(_ enabled: Bool) {
        httpEnabled = enabled
        defaults.set(enabled, forKey: Self.httpEnabledDefaultsKey)
    }

    /// Starts the HTTP server when it is turned on; the app's own start points call this, so an
    /// install that never opted in opens no MCP port.
    func startIfEnabled() async throws {
        guard httpEnabled else { return }
        try await start()
    }

    /// The address assistants are registered at, or nil when HTTP is off and they run `garage-mcp`.
    var registrationEndpoint: URL? {
        httpEnabled ? endpoint : nil
    }

    deinit {
        logPollTask?.cancel()
    }

    var endpoint: URL {
        URL(string: "http://\(host):\(port)\(path)")!
    }

    nonisolated static func randomPort(excluding: Set<Int> = []) -> Int {
        var candidate: Int
        repeat {
            candidate = Int.random(in: 1024...65535)
        } while excluding.contains(candidate)
        return candidate
    }

    @discardableResult
    func selectRandomPort() -> Int {
        let newPort = Self.randomPort(excluding: [port])
        self.port = newPort
        return newPort
    }

    // MARK: - Client Configuration Detection

    func refreshDetectedClients() {
        self.detectedClients = detectClientConfigs()
    }

    /// The client configs Garage knows, as `mcp_server/install.py`'s table lists them. The home folder
    /// is the account's: in the sandbox `homeDirectoryForCurrentUser` is the app's container.
    func detectClientConfigs() -> [MCPClientConfig] {
        let home = URL(fileURLWithPath: GarageAppGroup.realHomeDirectory, isDirectory: true)
        let project = Paths.garageWorkingDirectory
        let appSupport = home.appendingPathComponent("Library/Application Support")

        let standardTargets: [(id: String, label: String, path: URL, projectScoped: Bool, note: String)] = [
            (
                id: "project",
                label: "Claude Code (project config)",
                path: project.appendingPathComponent(".mcp.json"),
                projectScoped: true,
                note: "Shared with collaborators in the repository"
            ),
            (
                id: "claude-desktop",
                label: "Claude Desktop",
                path: appSupport.appendingPathComponent("Claude/claude_desktop_config.json"),
                projectScoped: false,
                note: "Official Claude Desktop macOS app"
            ),
            (
                id: "claude-code-user",
                label: "Claude Code (user config)",
                path: home.appendingPathComponent(".claude.json"),
                projectScoped: false,
                note: "Global Claude Code user configuration"
            ),
            (
                id: "lmstudio",
                label: "LM Studio",
                path: home.appendingPathComponent(".lmstudio/mcp.json"),
                projectScoped: false,
                note: "LM Studio local AI assistant"
            ),
            (
                id: "cursor",
                label: "Cursor",
                path: home.appendingPathComponent(".cursor/mcp.json"),
                projectScoped: false,
                note: "Cursor AI editor configuration"
            ),
            (
                id: "cursor-global",
                label: "Cursor (extension global)",
                path: appSupport.appendingPathComponent("Cursor/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json"),
                projectScoped: false,
                note: "Cursor Cline/Roo-Code extension settings"
            ),
            (
                id: "vscode",
                label: "VS Code (project)",
                path: project.appendingPathComponent(".vscode/mcp.json"),
                projectScoped: true,
                note: "Workspace-specific VS Code MCP config"
            ),
            (
                id: "vscode-global",
                label: "VS Code (extension global)",
                path: appSupport.appendingPathComponent("Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json"),
                projectScoped: false,
                note: "VS Code Cline/Roo-Code extension settings"
            ),
            (
                id: "windsurf",
                label: "Windsurf",
                path: home.appendingPathComponent(".codeium/windsurf/mcp_config.json"),
                projectScoped: false,
                note: "Codeium Windsurf AI IDE"
            ),
            (
                id: "zed",
                label: "Zed",
                path: home.appendingPathComponent(".config/zed/settings.json"),
                projectScoped: false,
                note: "Zed editor settings"
            ),
        ]

        return standardTargets.map { target in
            let exists = FileManager.default.fileExists(atPath: target.path.path)
            let entry = registeredEntry(at: target.path)
            return MCPClientConfig(
                id: target.id,
                label: target.label,
                path: target.path,
                existsOnDisk: exists,
                isRegistered: entry != nil,
                isProjectScoped: target.projectScoped,
                note: target.note,
                registeredURL: entry?["url"] as? String
            )
        }
    }

    /// This server's entry in a client config, or `nil` when the file has none.
    private func registeredEntry(at url: URL, serverName: String = "garage-rag") -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = json["mcpServers"] as? [String: Any],
              let entry = servers[serverName] else {
            return nil
        }
        return (entry as? [String: Any]) ?? [:]
    }

    // MARK: - Client Registration Actions

    /// Writes this server's entry into client configs through the McpInstall RPC.
    private func install(_ scope: GarageGRPCService.McpInstallScope, force: Bool) async -> (success: Bool, message: String) {
        guard let grpc else {
            let message = "gRPC service unavailable; cannot register MCP clients."
            appendLog(LogLine(stream: .stderr, text: message, source: "garage-mcp"))
            return (false, message)
        }
        do {
            let response = try await grpc.mcpInstall(scope: scope, host: host, port: port, stdio: !httpEnabled, force: force)
            for line in response.message.split(separator: "\n") {
                appendLog(LogLine(stream: .stdout, text: String(line), source: "garage-mcp"))
            }
            return (true, response.message.isEmpty ? "Registered." : response.message)
        } catch {
            var message = "MCP registration failed: \(error.localizedDescription)"
            if GarageAppGroup.isSandboxed {
                message += " " + Self.sandboxedRegistrationHint
            }
            appendLog(LogLine(stream: .stderr, text: message, source: "garage-mcp"))
            return (false, message)
        }
    }

    /// What a failed registration adds in the sandboxed build, where Garage writes a client's config
    /// only inside a folder the user granted.
    nonisolated static let sandboxedRegistrationHint =
        "Garage can change a client's settings only in a folder you gave it: grant disk access to your home folder or startup disk on the Sources page, or pick the file with Connect a Config File…"

    @discardableResult
    func registerInAllFoundConfigs(force: Bool = true) async -> (success: Bool, message: String) {
        isRegistering = true
        defer {
            isRegistering = false
            refreshDetectedClients()
        }
        return await install(.all, force: force)
    }

    @discardableResult
    func registerTarget(_ targetId: String, force: Bool = true) async -> (success: Bool, message: String) {
        isRegistering = true
        defer {
            isRegistering = false
            refreshDetectedClients()
        }
        return await install(.target(targetId), force: force)
    }

    @discardableResult
    func registerCustomConfigFile(at url: URL, force: Bool = true) async -> (success: Bool, message: String) {
        isRegistering = true
        defer {
            isRegistering = false
            refreshDetectedClients()
        }
        // The open panel gave this process access to the file; the service writing it needs its own.
        if let folderAccess {
            await folderAccess.grant(url, key: GarageFolderAccessKey.file(url.path))
        }
        return await install(.path(url.path), force: force)
    }

    /// Removes this server's entry from one client's config through the McpUninstall RPC.
    @discardableResult
    func unregisterTarget(_ targetId: String) async -> (success: Bool, message: String) {
        isRegistering = true
        defer {
            isRegistering = false
            refreshDetectedClients()
        }
        guard let grpc else {
            let message = "gRPC service unavailable; cannot disconnect MCP clients."
            appendLog(LogLine(stream: .stderr, text: message, source: "garage-mcp"))
            return (false, message)
        }
        do {
            let response = try await grpc.mcpUninstall(target: targetId)
            appendLog(LogLine(stream: .stdout, text: response.message, source: "garage-mcp"))
            return (true, response.message)
        } catch {
            let message = "MCP disconnect failed: \(error.localizedDescription)"
            appendLog(LogLine(stream: .stderr, text: message, source: "garage-mcp"))
            return (false, message)
        }
    }

    // MARK: - Testing & Diagnostics

    func initializeSession() async throws {
        self.sessionId = nil
        let initPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2024-11-05",
                "capabilities": [String: Any](),
                "clientInfo": [
                    "name": "GarageAppDiagnostic",
                    "version": "1.0.0"
                ]
            ]
        ]
        _ = try await sendJSONRPC(initPayload)

        let initNotification: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
            "params": [String: Any]()
        ]
        _ = try? await sendJSONRPC(initNotification)
    }

    @discardableResult
    func testServerConnection(sampleTool: String? = "rag_stats", query: String? = nil) async -> MCPTestResult {
        isTesting = true
        defer { isTesting = false }

        let startTime = CFAbsoluteTimeGetCurrent()
        guard status == .running else {
            let res = MCPTestResult(
                isSuccess: false,
                latencyMs: 0,
                tools: [],
                errorMessage: "MCP server is not running (status: \(status))"
            )
            self.lastTestResult = res
            return res
        }

        do {
            // 1. Initialize session
            try await initializeSession()

            // 2. Query tools/list
            let listToolsPayload: [String: Any] = [
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/list",
                "params": [String: Any]()
            ]
            let listResp = try await sendJSONRPC(listToolsPayload)

            var parsedTools: [MCPToolInfo] = []
            if let result = listResp["result"] as? [String: Any],
               let toolsArray = result["tools"] as? [[String: Any]] {
                for t in toolsArray {
                    let name = t["name"] as? String ?? "unknown"
                    let desc = t["description"] as? String ?? ""
                    let schema = t["inputSchema"] as? [String: Any]
                    let schemaStr = schema != nil ? (try? String(data: JSONSerialization.data(withJSONObject: schema!, options: .prettyPrinted), encoding: .utf8)) : nil
                    parsedTools.append(MCPToolInfo(name: name, description: desc, inputSchemaJson: schemaStr))
                }
            }

            // 3. Test sample tool invocation if requested
            var toolOutputText: String?
            let toolToTest = sampleTool ?? (parsedTools.first?.name ?? "rag_stats")
            if !toolToTest.isEmpty {
                var toolArgs: [String: Any] = [:]
                if toolToTest == "rag_search" {
                    toolArgs["query"] = query ?? "test search"
                }
                toolOutputText = try? await executeToolCall(toolName: toolToTest, arguments: toolArgs)
            }

            let latency = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            let testResult = MCPTestResult(
                isSuccess: true,
                latencyMs: latency,
                httpStatusCode: 200,
                tools: parsedTools,
                testedToolName: toolToTest,
                toolOutput: toolOutputText,
                errorMessage: nil
            )
            self.lastTestResult = testResult
            return testResult
        } catch {
            let latency = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            let testResult = MCPTestResult(
                isSuccess: false,
                latencyMs: latency,
                tools: [],
                errorMessage: error.localizedDescription
            )
            self.lastTestResult = testResult
            return testResult
        }
    }

    /// How long a `tools/call` may take. Reading the corpus answers in well under a second; a
    /// generating tool (`rag_ask`, `rag_agent`) runs the local model, whose first token can be tens
    /// of seconds away while it loads, so callers of those pass a longer allowance.
    static let toolCallTimeout: TimeInterval = 10
    static let generationTimeout: TimeInterval = 300

    func executeToolCall(
        toolName: String,
        arguments: [String: Any] = [:],
        timeout: TimeInterval = GarageMCPService.toolCallTimeout
    ) async throws -> String {
        if sessionId == nil {
            try await initializeSession()
        }

        let callPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": Int.random(in: 100...9999),
            "method": "tools/call",
            "params": [
                "name": toolName,
                "arguments": arguments
            ]
        ]

        let resp: [String: Any]
        do {
            resp = try await sendJSONRPC(callPayload, timeout: timeout)
        } catch {
            if let mcpError = error as? GarageMCPError,
               case .invalidResponse(let msg) = mcpError,
               msg.localizedCaseInsensitiveContains("session") {
                try await initializeSession()
                resp = try await sendJSONRPC(callPayload, timeout: timeout)
            } else {
                throw error
            }
        }

        if let errorObj = resp["error"] as? [String: Any] {
            let message = errorObj["message"] as? String ?? "Unknown error"
            throw GarageMCPError.invalidResponse("Tool call failed: \(message)")
        }

        if let result = resp["result"] as? [String: Any] {
            if let content = result["content"] as? [[String: Any]] {
                let texts = content.compactMap { $0["text"] as? String }
                if !texts.isEmpty {
                    return texts.joined(separator: "\n")
                }
            }
            if let data = try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
        }

        return "Tool executed successfully (empty response)."
    }

    private func sendJSONRPC(
        _ payload: [String: Any],
        timeout: TimeInterval = GarageMCPService.toolCallTimeout
    ) async throws -> [String: Any] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sid = self.sessionId, !sid.isEmpty {
            request.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id")
        }
        request.timeoutInterval = timeout
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResp = response as? HTTPURLResponse else {
            throw GarageMCPError.invalidResponse("No HTTP response received")
        }

        if let newSessionId = httpResp.value(forHTTPHeaderField: "mcp-session-id") ?? httpResp.value(forHTTPHeaderField: "Mcp-Session-Id"),
           !newSessionId.isEmpty {
            self.sessionId = newSessionId
        }

        guard (200...299).contains(httpResp.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            if (httpResp.statusCode == 400 || httpResp.statusCode == 404) && bodyStr.localizedCaseInsensitiveContains("session") {
                self.sessionId = nil
            }
            throw GarageMCPError.invalidResponse("HTTP \(httpResp.statusCode): \(bodyStr)")
        }

        if data.isEmpty {
            return [:]
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }

        if let text = String(data: data, encoding: .utf8) {
            for line in text.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("data:") {
                    let jsonPart = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    if let jsonData = jsonPart.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                        return json
                    }
                }
            }
        }

        return [:]
    }

    // MARK: - Server Lifecycle

    private func startLogPolling() {
        logPollTask?.cancel()
        logPollTask = Task { [weak self, client] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let (stdout, stderr) = try? await client.fetchBufferedOutput(clearBuffer: true) else {
                    continue
                }
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    if let stdout = stdout, !stdout.isEmpty {
                        for line in stdout.split(separator: "\n", omittingEmptySubsequences: false) {
                            let text = String(line)
                            if !text.isEmpty {
                                self.appendLog(LogLine(stream: .stdout, text: text, source: "garage-mcp"))
                            }
                        }
                    }
                    if let stderr = stderr, !stderr.isEmpty {
                        for line in stderr.split(separator: "\n", omittingEmptySubsequences: false) {
                            let text = String(line)
                            if !text.isEmpty {
                                self.appendLog(LogLine(stream: .stderr, text: text, source: "garage-mcp"))
                            }
                        }
                    }
                }
            }
        }
    }

    private func stopLogPolling() {
        logPollTask?.cancel()
        logPollTask = nil
    }

    func start(maxAttempts: Int = 3, readyTimeout: TimeInterval = 10) async throws {
        guard status == .stopped || isFailed else { return }
        guard postgres.status == .running else {
            let errorMsg = "Database is not online (status: \(postgres.status)). MCP server requires an online database."
            status = .failed(errorMsg)
            appendLog(LogLine(stream: .stderr, text: errorMsg, source: "garage-mcp"))
            throw GarageMCPError.databaseNotOnline
        }

        var attemptsLeft = max(1, maxAttempts)
        var triedPorts: Set<Int> = []

        while attemptsLeft > 0 {
            let currentPort = port
            triedPorts.insert(currentPort)
            status = .starting
            sessionId = nil

            do {
                // Reads the token off the main actor the first time, so a Keychain prompt never
                // blocks the window; environment() then gets it from the store's cache.
                try await LMStudioTokenStore.loadOffMainActor()
                let options = try environment()
                let result = try await client.startServer(host: host, port: currentPort, path: path, options: options)
                if !result.success {
                    let launchError = GarageMCPError.launchFailed(result.message ?? "XPC service failed to start MCP server")
                    status = .failed(launchError.localizedDescription)
                    throw launchError
                }
                startLogPolling()
            } catch let error as GarageMCPError {
                status = .failed(error.localizedDescription)
                throw error
            } catch {
                let launchError = GarageMCPError.launchFailed(error.localizedDescription)
                status = .failed(launchError.localizedDescription)
                throw launchError
            }

            let ready = await waitUntilReady(timeout: readyTimeout)
            if ready {
                status = .running
                refreshDetectedClients()
                return
            }

            // Startup / loading failed on currentPort
            attemptsLeft -= 1
            _ = try? await client.stopServer()

            if attemptsLeft > 0 {
                let newPort = Self.randomPort(excluding: triedPorts)
                appendLog(LogLine(
                    stream: .stderr,
                    text: "Failed to load garage-mcp on port \(currentPort); selecting random port \(newPort)…",
                    source: "garage-mcp"
                ))
                self.port = newPort
            } else {
                status = .failed(GarageMCPError.startupTimeout.localizedDescription)
                throw GarageMCPError.startupTimeout
            }
        }
    }

    func stop() async {
        guard status == .running || status == .starting else { return }
        status = .stopping
        sessionId = nil
        stopLogPolling()
        _ = try? await client.stopServer()
        status = .stopped
    }

    func terminateImmediately() {
        status = .stopping
        sessionId = nil
        stopLogPolling()
        Task { [client] in
            _ = try? await client.stopServer()
        }
    }

    private var isFailed: Bool {
        if case .failed = status {
            return true
        }
        return false
    }

    private func appendLog(_ line: LogLine) {
        logs.append(line)
        if logs.count > maxLogLines {
            logs.removeFirst(LogLine.trimCount(count: logs.count, limit: maxLogLines))
        }
    }

    func clearLogs() {
        logs.removeAll()
        Task { [client] in
            _ = try? await client.clearLogs()
        }
    }

    private func environment() throws -> [String: String] {
        var env: [String: String] = [:]
        env["GARAGE_DATABASE_URL"] = try postgres.connectionURL()
        if let lmStudioToken = try LMStudioTokenStore.load() {
            env["GARAGE_LMSTUDIO_API_TOKEN"] = lmStudioToken
        }
        return env
    }

    private func waitUntilReady(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var request = URLRequest(url: endpoint)
            request.timeoutInterval = 1
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if response is HTTPURLResponse {
                    return true
                }
            } catch {
                // The server may still be starting; retry until the timeout.
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }
}

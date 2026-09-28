import XCTest
import PythonXPCService
@testable import GarageApp

final class GarageMCPServiceTests: XCTestCase {

    @MainActor
    func testInitialStateAndDefaults() {
        let suiteName = "GarageMCPServiceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let postgres = PostgresService()
        let mcp = GarageMCPService(postgres: postgres, defaults: defaults)

        XCTAssertEqual(mcp.status, .stopped)
        XCTAssertEqual(mcp.host, "127.0.0.1")
        XCTAssertEqual(mcp.port, 8787)
        XCTAssertEqual(mcp.path, "/mcp")
        XCTAssertEqual(mcp.endpoint.absoluteString, "http://127.0.0.1:8787/mcp")
        XCTAssertTrue(mcp.logs.isEmpty)
        XCTAssertNil(mcp.sessionId)
    }

    @MainActor
    func testCustomPortAndUserDefaultsPersistence() {
        let suiteName = "GarageMCPServiceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let postgres = PostgresService()

        let mcp1 = GarageMCPService(postgres: postgres, port: 9000, defaults: defaults)
        XCTAssertEqual(mcp1.port, 9000)
        XCTAssertEqual(mcp1.endpoint.absoluteString, "http://127.0.0.1:9000/mcp")

        mcp1.port = 9001
        XCTAssertEqual(mcp1.port, 9001)
        XCTAssertEqual(mcp1.endpoint.absoluteString, "http://127.0.0.1:9001/mcp")
        XCTAssertEqual(defaults.integer(forKey: GarageMCPService.portDefaultsKey), 9001)

        let mcp2 = GarageMCPService(postgres: postgres, defaults: defaults)
        XCTAssertEqual(mcp2.port, 9001)
        XCTAssertEqual(mcp2.endpoint.absoluteString, "http://127.0.0.1:9001/mcp")
    }

    @MainActor
    func testSelectRandomPort() {
        let suiteName = "GarageMCPServiceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let postgres = PostgresService()
        let mcp = GarageMCPService(postgres: postgres, port: 8787, defaults: defaults)

        let initialPort = mcp.port
        let newPort = mcp.selectRandomPort()

        XCTAssertNotEqual(newPort, initialPort)
        XCTAssertEqual(mcp.port, newPort)
        XCTAssertTrue((1024...65535).contains(newPort))
        XCTAssertEqual(mcp.endpoint.absoluteString, "http://127.0.0.1:\(newPort)/mcp")
        XCTAssertEqual(defaults.integer(forKey: GarageMCPService.portDefaultsKey), newPort)
    }

    func testRandomPortExclusion() {
        let excluded: Set<Int> = [1024, 8787, 9000]
        for _ in 0..<100 {
            let port = GarageMCPService.randomPort(excluding: excluded)
            XCTAssertFalse(excluded.contains(port))
            XCTAssertTrue((1024...65535).contains(port))
        }
    }

    func testGarageMCPStatusEquality() {
        XCTAssertEqual(GarageMCPStatus.stopped, GarageMCPStatus.stopped)
        XCTAssertEqual(GarageMCPStatus.starting, GarageMCPStatus.starting)
        XCTAssertEqual(GarageMCPStatus.running, GarageMCPStatus.running)
        XCTAssertEqual(GarageMCPStatus.stopping, GarageMCPStatus.stopping)
        XCTAssertEqual(GarageMCPStatus.failed("error"), GarageMCPStatus.failed("error"))
        XCTAssertNotEqual(GarageMCPStatus.failed("a"), GarageMCPStatus.failed("b"))
        XCTAssertNotEqual(GarageMCPStatus.stopped, GarageMCPStatus.running)
    }

    func testGarageMCPErrorDescriptions() {
        let cliError = GarageMCPError.cliNotFound
        XCTAssertTrue(cliError.localizedDescription.contains("garage CLI not found"))

        let timeoutError = GarageMCPError.startupTimeout
        XCTAssertTrue(timeoutError.localizedDescription.contains("did not become ready"))

        let launchError = GarageMCPError.launchFailed("permission denied")
        XCTAssertTrue(launchError.localizedDescription.contains("permission denied"))

        let notRunningError = GarageMCPError.serverNotRunning
        XCTAssertTrue(notRunningError.localizedDescription.contains("MCP server is not running"))

        let invalidResp = GarageMCPError.invalidResponse("malformed json")
        XCTAssertTrue(invalidResp.localizedDescription.contains("malformed json"))
    }

    @MainActor
    func testDetectClientConfigs() {
        let postgres = PostgresService()
        let mcp = GarageMCPService(postgres: postgres)

        let configs = mcp.detectClientConfigs()
        XCTAssertFalse(configs.isEmpty)
        let ids = configs.map(\.id)
        XCTAssertTrue(ids.contains("project"))
        XCTAssertTrue(ids.contains("claude-desktop"))
        XCTAssertTrue(ids.contains("lmstudio"))
        XCTAssertTrue(ids.contains("cursor"))
        XCTAssertTrue(ids.contains("vscode"))
        XCTAssertTrue(ids.contains("windsurf"))
        XCTAssertTrue(ids.contains("zed"))
    }

    /// In the sandbox `homeDirectoryForCurrentUser` is the app's container, where no client keeps
    /// its config; detection looks in the account's home folder, as install.py does.
    @MainActor
    func testDetectClientConfigsUsesTheAccountHome() {
        let mcp = GarageMCPService(postgres: PostgresService())
        let home = URL(fileURLWithPath: GarageAppGroup.realHomeDirectory, isDirectory: true)
        let byId = Dictionary(uniqueKeysWithValues: mcp.detectClientConfigs().map { ($0.id, $0.path) })

        XCTAssertEqual(byId["claude-desktop"]?.path, home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json").path)
        XCTAssertEqual(byId["claude-code-user"]?.path, home.appendingPathComponent(".claude.json").path)
    }

    /// A config file chosen in the open panel is handed to the service that writes it before the
    /// McpInstall call, since that service is sandboxed on its own.
    @MainActor
    func testCustomConfigFileIsGrantedBeforeRegistering() async {
        let mcp = GarageMCPService(postgres: PostgresService())
        let relay = RecordingFolderAccessRelay()
        mcp.folderAccess = relay
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("client-\(UUID().uuidString).json")

        // No gRPC service in the test: the registration itself fails, after the grant.
        let result = await mcp.registerCustomConfigFile(at: file)
        XCTAssertFalse(result.success)
        XCTAssertEqual(relay.grants.map { $0.key }, [GarageFolderAccessKey.file(file.path)])
        XCTAssertEqual(relay.grants.first?.path, file.path)
    }

    @MainActor
    func testMCPToolInfoAndTestResultModels() {
        let tool = MCPToolInfo(name: "rag_stats", description: "Corpus stats", inputSchemaJson: "{}")
        XCTAssertEqual(tool.id, "rag_stats")
        XCTAssertEqual(tool.name, "rag_stats")
        XCTAssertEqual(tool.description, "Corpus stats")
        XCTAssertEqual(tool.inputSchemaJson, "{}")

        let result = MCPTestResult(
            isSuccess: true,
            latencyMs: 15.5,
            httpStatusCode: 200,
            tools: [tool],
            testedToolName: "rag_stats",
            toolOutput: "42 docs",
            errorMessage: nil
        )
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.latencyMs, 15.5)
        XCTAssertEqual(result.httpStatusCode, 200)
        XCTAssertEqual(result.tools.count, 1)
        XCTAssertEqual(result.testedToolName, "rag_stats")
        XCTAssertEqual(result.toolOutput, "42 docs")
        XCTAssertNil(result.errorMessage)
    }

    @MainActor
    func testServerConnectionWhenStopped() async {
        let postgres = PostgresService()
        let mcp = GarageMCPService(postgres: postgres)

        XCTAssertEqual(mcp.status, .stopped)
        let result = await mcp.testServerConnection()
        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(result.errorMessage?.contains("not running") == true)
        XCTAssertEqual(mcp.lastTestResult, result)
        XCTAssertNil(mcp.sessionId)
    }

    @MainActor
    func testSessionIdClearedOnStop() async {
        let postgres = PostgresService()
        let mcp = GarageMCPService(postgres: postgres)

        XCTAssertNil(mcp.sessionId)
        await mcp.stop()
        XCTAssertNil(mcp.sessionId)

        mcp.terminateImmediately()
        XCTAssertNil(mcp.sessionId)
    }

    @MainActor
    func testStartRefusedWhenDatabaseOffline() async {
        let postgres = PostgresService()
        XCTAssertEqual(postgres.status, .stopped)
        let mcp = GarageMCPService(postgres: postgres)

        do {
            try await mcp.start()
            XCTFail("Expected start to throw databaseNotOnline")
        } catch let error as GarageMCPError {
            XCTAssertEqual(error, .databaseNotOnline)
        } catch {
            XCTFail("Unexpected error thrown: \(error)")
        }

        if case .failed(let message) = mcp.status {
            XCTAssertTrue(message.contains("Database is not online"))
        } else {
            XCTFail("Expected status to be .failed, but got \(mcp.status)")
        }
    }

    @MainActor
    func testHTTPIsOffByDefaultAndTheChoicePersists() {
        let suiteName = "GarageMCPServiceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let postgres = PostgresService()

        let mcp = GarageMCPService(postgres: postgres, defaults: defaults)
        if !GarageMCPService.hasHTTPRegistration(mcp.detectedClients) {
            XCTAssertFalse(mcp.httpEnabled)
            XCTAssertNil(mcp.registrationEndpoint)
        }

        mcp.setHTTPEnabled(true)
        XCTAssertTrue(defaults.bool(forKey: GarageMCPService.httpEnabledDefaultsKey))
        XCTAssertEqual(mcp.registrationEndpoint, mcp.endpoint)
        XCTAssertTrue(GarageMCPService(postgres: postgres, defaults: defaults).httpEnabled)

        mcp.setHTTPEnabled(false)
        XCTAssertFalse(GarageMCPService(postgres: postgres, defaults: defaults).httpEnabled)
    }

    @MainActor
    func testStartIfEnabledLeavesTheServerStoppedWhenHTTPIsOff() async throws {
        let suiteName = "GarageMCPServiceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: GarageMCPService.httpEnabledDefaultsKey)
        let mcp = GarageMCPService(postgres: PostgresService(), defaults: defaults)
        try await mcp.startIfEnabled()
        XCTAssertEqual(mcp.status, .stopped)
    }

    func testAnHTTPRegistrationKeepsHTTPOnForAnUpgrade() {
        func client(registered: Bool, url: String?) -> MCPClientConfig {
            MCPClientConfig(id: "c", label: "c", path: URL(fileURLWithPath: "/tmp/c.json"), existsOnDisk: true, isRegistered: registered, registeredURL: url)
        }
        XCTAssertFalse(GarageMCPService.hasHTTPRegistration([]))
        XCTAssertFalse(GarageMCPService.hasHTTPRegistration([client(registered: true, url: nil)]))
        XCTAssertFalse(GarageMCPService.hasHTTPRegistration([client(registered: false, url: "http://127.0.0.1:8787/mcp")]))
        XCTAssertTrue(GarageMCPService.hasHTTPRegistration([client(registered: true, url: nil), client(registered: true, url: "http://127.0.0.1:8787/mcp")]))
    }
}

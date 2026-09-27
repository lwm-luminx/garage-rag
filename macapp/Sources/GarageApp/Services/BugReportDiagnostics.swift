import Foundation

/// Gathers the environment facts a maintainer needs to reproduce a bug.
///
/// Everything collected here is either about the machine (OS, architecture),
/// the build (version), or the shape of the corpus (counts, model slugs,
/// service states). Deliberately absent: source roots, document titles,
/// search queries, and anything else derived from the user's content —
/// the corpus is personal, and a bug report is a public artifact.
@MainActor
enum BugReportDiagnosticsCollector {

    static func collect(
        appState: AppState,
        version: AppVersionInfo = AppVersionInfo(),
        processInfo: ProcessInfo = .processInfo
    ) -> [DiagnosticSection] {
        [
            application(version: version, processInfo: processInfo),
            database(appState: appState),
            corpus(appState: appState),
            models(appState: appState),
            services(appState: appState),
        ]
        .filter { !$0.fields.isEmpty }
    }

    // MARK: Sections

    private static func application(version: AppVersionInfo, processInfo: ProcessInfo) -> DiagnosticSection {
        DiagnosticSection("Application", [
            DiagnosticField("Garage", version.displayString),
            DiagnosticField("macOS", processInfo.operatingSystemVersionString),
            DiagnosticField("Architecture", architecture),
            DiagnosticField("Memory", "\(processInfo.physicalMemory / 1_073_741_824) GB"),
            DiagnosticField("Bundle", Bundle.main.bundleIdentifier ?? "unknown"),
        ])
    }

    private static func database(appState: AppState) -> DiagnosticSection {
        var fields = [
            DiagnosticField("Postgres", appState.statusSummary),
            DiagnosticField("Port", String(appState.postgres.port)),
        ]
        let pending = appState.postgres.pendingMigrations
        if !pending.isEmpty {
            fields.append(DiagnosticField("Pending migrations", pending.joined(separator: ", ")))
        }
        return DiagnosticSection("Database", fields)
    }

    private static func corpus(appState: AppState) -> DiagnosticSection {
        let stats = appState.corpusStats
        // Counts only — slugs and roots name the user's folders and accounts.
        return DiagnosticSection("Corpus", [
            DiagnosticField("Sources", String(appState.registeredSources.count)),
            DiagnosticField("Documents", "\(stats.documentsCount) (\(stats.documentsOkCount) ok, \(stats.documentsFailedCount) failed)"),
            DiagnosticField("Chunks", "\(stats.totalChunks) (\(stats.embeddedChunks) embedded)"),
            DiagnosticField("Corpus classes", classBreakdown(appState.registeredSources)),
        ])
    }

    private static func models(appState: AppState) -> DiagnosticSection {
        let models = appState.registeredModels
        guard !models.isEmpty else {
            return DiagnosticSection("Models", [DiagnosticField("Registered", "none")])
        }
        let fields = models.map { model in
            DiagnosticField(
                model.slug + (model.isDefault ? " (default)" : ""),
                "\(model.provider), \(model.dims) dims, \(model.storageKind)/\(model.indexKind)"
            )
        }
        return DiagnosticSection("Models", fields)
    }

    private static func services(appState: AppState) -> DiagnosticSection {
        var fields = [
            DiagnosticField("MCP server", describe(appState.mcp.status, port: appState.mcp.port)),
            DiagnosticField("gRPC server", describe(appState.grpc.status, address: appState.grpc.shortAddress)),
        ]
        for service in appState.xpcServices.services {
            var state = service.state.title
            if let latency = service.latencyMs {
                state += String(format: " (%.0f ms)", latency)
            }
            if let error = service.errorMessage {
                state += ": \(error)"
            }
            fields.append(DiagnosticField(service.name, state))
        }
        return DiagnosticSection("Helper services", fields)
    }

    // MARK: Helpers

    /// e.g. "document: 3, code: 1" — how the corpus is split, without naming
    /// any individual source.
    private static func classBreakdown(_ sources: [RegisteredSource]) -> String {
        guard !sources.isEmpty else { return "none" }
        let counts = Dictionary(grouping: sources, by: \.corpusClass).mapValues(\.count)
        return counts.keys.sorted()
            .map { "\($0): \(counts[$0] ?? 0)" }
            .joined(separator: ", ")
    }

    private static func describe(_ status: GarageMCPStatus, port: Int) -> String {
        switch status {
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .running: "Running on port \(port)"
        case .stopping: "Stopping"
        case .failed(let message): "Failed: \(message)"
        }
    }

    private static func describe(_ status: GarageGRPCStatus, address: String) -> String {
        switch status {
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .running: "Running on \(address)"
        case .stopping: "Stopping"
        case .failed(let message): "Failed: \(message)"
        }
    }

    private static var architecture: String {
        #if arch(arm64)
        return "arm64 (Apple silicon)"
        #else
        return "unknown"
        #endif
    }
}

import Foundation
import GRPC
import NIO
import proto_garage_proto_swift

/// The operations the app used to run as `garage <subcommand>` processes, now RPCs
/// on the same GarageService its views read through. Each wraps one
/// garage_rag.ops function on the Python side; failures arrive as
/// `GarageGRPCError.rpcFailed` carrying the server's message.
extension GarageGRPCService {
    /// Starts the service if needed, then runs `body` against a client. Unary calls
    /// get `timeout`; streaming calls pass nil and run until the server finishes.
    private func call<T>(
        timeout: TimeAmount? = .seconds(120),
        _ body: @MainActor (Garage_GarageServiceAsyncClient, CallOptions) async throws -> T
    ) async throws -> T {
        if status != .running {
            try await start()
        }
        let client = Garage_GarageServiceAsyncClient(channel: getOrCreateChannel(), defaultCallOptions: GarageGRPCAuth.callOptions())
        var options = GarageGRPCAuth.callOptions()
        if let timeout {
            options.timeLimit = .timeout(timeout)
        }
        do {
            return try await body(client, options)
        } catch {
            // A cancelled task surfaces from grpc-swift as a CANCELLED status; keep it a cancellation.
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            throw GarageGRPCError.rpcFailed(Self.describe(error))
        }
    }

    // MARK: - Sources

    func addSource(_ spec: SourceSpec) async throws -> Garage_AddSourceResponse {
        var request = Garage_AddSourceRequest()
        request.slug = spec.slug
        request.root = spec.root
        request.kind = spec.kind
        request.corpusClass = spec.corpusClass
        request.trust = spec.trust
        return try await call { try await $0.addSource(request, callOptions: $1) }
    }

    func removeSource(slug: String) async throws -> Garage_RemoveSourceResponse {
        var request = Garage_RemoveSourceRequest()
        request.slug = slug
        // The delete cascades through every document, chunk and vector of the source, which on a
        // large source takes far longer than the default two minutes.
        return try await call(timeout: .minutes(30)) { try await $0.removeSource(request, callOptions: $1) }
    }

    /// Counts items per source, handing each status (the running count while a source is
    /// walked, then its result) to `onStatus`; returns the summary the stream ends with.
    func scan(
        source: String,
        includeCode: Bool,
        onStatus: @MainActor (Garage_ScanStatus) -> Void = { _ in }
    ) async throws -> Garage_ScanResponse {
        var request = Garage_ScanRequest()
        request.source = source
        request.includeCode = includeCode
        return try await call(timeout: .minutes(10)) { client, options in
            var summary = Garage_ScanResponse()
            for try await status in client.scan(request, callOptions: options) {
                onStatus(status)
                if status.phase == "finished" {
                    summary = status.summary
                }
            }
            return summary
        }
    }

    func syncSources(dryRun: Bool = false) async throws -> Garage_SyncSourcesResponse {
        var request = Garage_SyncSourcesRequest()
        request.dryRun = dryRun
        return try await call { try await $0.syncSources(request, callOptions: $1) }
    }

    func importSourcesToConfig() async throws -> Garage_ImportSourcesToConfigResponse {
        try await call { try await $0.importSourcesToConfig(Garage_ImportSourcesToConfigRequest(), callOptions: $1) }
    }

    func reconcile(source: String, apply: Bool) async throws -> Garage_ReconcileResponse {
        var request = Garage_ReconcileRequest()
        request.source = source
        request.apply = apply
        return try await call(timeout: .minutes(10)) { try await $0.reconcile(request, callOptions: $1) }
    }

    // MARK: - Models

    func registerModel(
        slug: String,
        dims: Int? = nil,
        modelRef: String? = nil,
        provider: String? = nil,
        modelID: String? = nil,
        distance: String? = nil,
        modality: String? = nil,
        makeDefault: Bool = false
    ) async throws -> Garage_RegisterModelResponse {
        var request = Garage_RegisterModelRequest()
        request.slug = slug
        request.dims = Int32(dims ?? 0)
        request.modelRef = modelRef ?? ""
        request.provider = provider ?? ""
        request.modelID = modelID ?? ""
        // Empty: models.json's metric for a catalogued model, cosine otherwise.
        request.distance = distance ?? ""
        // Empty: the catalog's section for a catalogued model, text otherwise.
        request.modality = modality ?? ""
        request.makeDefault = makeDefault
        return try await call { try await $0.registerModel(request, callOptions: $1) }
    }

    func setDefaultModel(slug: String) async throws -> Garage_SetDefaultModelResponse {
        var request = Garage_SetDefaultModelRequest()
        request.slug = slug
        return try await call { try await $0.setDefaultModel(request, callOptions: $1) }
    }

    func dropModel(slug: String) async throws -> Garage_DropModelResponse {
        var request = Garage_DropModelRequest()
        request.slug = slug
        return try await call { try await $0.dropModel(request, callOptions: $1) }
    }

    /// Embeds pending chunks for `model` (nil or "*" = every model), handing each
    /// progress event to `onStatus` as it arrives. Returns the per-model outcomes.
    func backfill(
        model: String?,
        onStatus: @MainActor (Garage_BackfillStatus) -> Void
    ) async throws -> [Garage_BackfillStatus] {
        var request = Garage_BackfillRequest()
        request.model = model ?? ""
        return try await call(timeout: nil) { client, options in
            var outcomes: [Garage_BackfillStatus] = []
            for try await status in client.backfill(request, callOptions: options) {
                onStatus(status)
                if ["complete", "skipped", "finished"].contains(status.phase) {
                    outcomes.append(status)
                }
            }
            return outcomes
        }
    }

    // MARK: - Facts

    /// Distills documents into facts, handing each status to `onStatus`; returns the
    /// final `finished` status (nil if the stream ended without one).
    /// `prompts` empty runs every enabled prompt that applies; otherwise exactly those.
    func enrichFacts(
        source: String = "*",
        documentID: Int64? = nil,
        prompts: [String] = [],
        staleOnly: Bool = false,
        onStatus: @MainActor (Garage_EnrichFactsStatus) -> Void
    ) async throws -> Garage_EnrichFactsStatus? {
        var request = Garage_EnrichFactsRequest()
        request.source = source
        request.documentID = documentID ?? 0
        request.prompts = prompts
        request.staleOnly = staleOnly
        return try await call(timeout: nil) { client, options in
            var finished: Garage_EnrichFactsStatus?
            for try await status in client.enrichFacts(request, callOptions: options) {
                onStatus(status)
                if status.phase == "finished" {
                    finished = status
                }
            }
            return finished
        }
    }

    /// The effective fact prompts, and `facts.prompts` as configured (what `setSetting` takes back).
    func listFactPrompts() async throws -> Garage_ListFactPromptsResponse {
        try await call { try await $0.listFactPrompts(Garage_ListFactPromptsRequest(), callOptions: $1) }
    }

    // MARK: - Schema, stats & settings

    func initDatabase(schemaDir: String = "") async throws -> Garage_InitDbResponse {
        var request = Garage_InitDbRequest()
        request.schemaDir = schemaDir
        return try await call { try await $0.initDb(request, callOptions: $1) }
    }

    func stats() async throws -> Garage_StatsResponse {
        try await call { try await $0.getStats(Garage_StatsRequest(), callOptions: $1) }
    }

    func listModels() async throws -> Garage_ListModelsResponse {
        try await call { try await $0.listModels(Garage_ListModelsRequest(), callOptions: $1) }
    }

    func setSetting(_ name: String, to value: String) async throws -> Garage_SetSettingResponse {
        var request = Garage_SetSettingRequest()
        request.name = name
        request.value = value
        return try await call { try await $0.setSetting(request, callOptions: $1) }
    }

    // MARK: - MCP client registration

    enum McpInstallScope {
        case target(String)
        case path(String)
        case all
    }

    /// With `stdio`, the entry runs the bundled `garage-mcp` launcher; otherwise it is the HTTP address.
    func mcpInstall(scope: McpInstallScope, host: String, port: Int, stdio: Bool = false, force: Bool = false) async throws -> Garage_McpInstallResponse {
        var request = Garage_McpInstallRequest()
        switch scope {
        case .target(let key): request.target = key
        case .path(let path): request.path = path
        case .all: request.all = true
        }
        request.stdio = stdio
        if !stdio {
            request.host = host
            request.port = Int32(port)
        }
        request.force = force
        return try await call { try await $0.mcpInstall(request, callOptions: $1) }
    }

    func mcpUninstall(target: String) async throws -> Garage_McpUninstallResponse {
        var request = Garage_McpUninstallRequest()
        request.target = target
        return try await call { try await $0.mcpUninstall(request, callOptions: $1) }
    }

    func mcpStatus() async throws -> Garage_McpStatusResponse {
        try await call { try await $0.mcpStatus(Garage_McpStatusRequest(), callOptions: $1) }
    }
}

// MARK: - Display text for responses without a server-written message

extension Garage_SetSettingResponse {
    var summary: String { "\(name) = \(valueJson)  (wrote \(path))" }
}

extension Garage_StatsResponse {
    var summary: String {
        var lines = [
            "documents: \(documents.formatted())",
            "chunks: \(chunks.formatted())",
            "sources: \(sources.formatted())",
            "models: \(models.formatted())",
        ]
        for (model, count) in chunksByModel.sorted(by: { $0.key < $1.key }) {
            lines.append("  \(model): \(count.formatted()) vectors")
        }
        for (source, count) in documentsBySource.sorted(by: { $0.key < $1.key }) {
            lines.append("  \(source): \(count.formatted()) documents")
        }
        return lines.joined(separator: "\n")
    }
}

extension Garage_ListModelsResponse {
    var summary: String {
        guard !models.isEmpty else { return "no models registered" }
        return models.map { model in
            var line = "\(model.slug)\(model.isDefault ? " (default)" : ""): \(model.provider) \(model.modelRef)"
            line += ", \(model.dims) dims → \(model.storageKind)(\(model.storedDims)), \(model.indexKind)/\(model.distance) on \(model.tableName)"
            return line
        }.joined(separator: "\n")
    }
}

extension Garage_McpStatusResponse {
    var summary: String {
        var lines = ["server command: \(serverCommand)"]
        for client in clients {
            let state = client.registered ? "registered" : (client.configExists ? "not registered" : "no config")
            lines.append("\(client.label) [\(client.key)]: \(state) — \(client.path)")
        }
        return lines.joined(separator: "\n")
    }
}

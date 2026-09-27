import SwiftUI
import AppKit
import LlamaClient
import LlamaModelLoader
import ModelDownloadClient

/// The Models page: the embedding models the corpus is indexed with, the model that distills
/// facts, and the local providers that serve them.
///
/// Each model is one row that answers what a person comes here for: is it on disk, is it loaded,
/// is the corpus embedded with it. Files, hashes and table names sit behind a chevron on the row;
/// adding a model and testing one are folded away until asked for.
struct ModelsView: View {
    @EnvironmentObject var appState: AppState

    // MARK: - State

    /// The custom-model form, shown under the presets when "Custom model…" is open.
    @State var showCustomForm: Bool = false
    @State var slug: String = ""
    @State var dims: String = ""
    @State var modelRef: String = ""
    @State var provider: ModelProvider = .llamaXPC
    @State var makeDefault: Bool = false
    @State var busy: Bool = false
    @State var lmStudioToken: String = ""

    /// Alias the pending "Unload" confirmation applies to; `nil` unloads every model.
    @State var showUnloadConfirmation: Bool = false
    @State var pendingUnloadAlias: String? = nil
    @State var settingFactsModelSlug: String? = nil
    /// The slug "Use for Inference" is setting, or "" while Follow Distillation clears it.
    @State var settingInferenceModelSlug: String? = nil
    @State var registeringPresetSlug: String? = nil
    /// The model an Embed started from this page runs for, or "*" for Embed All; nil while no
    /// run was started here (a run started elsewhere, such as Update Everything, covers every model).
    @State var backfillTarget: String? = nil
    @State var searchText: String = ""
    /// Rows whose details (file, hashes, table) are open.
    @State var expandedSlugs: Set<String> = []

    // Embedding test
    @State var showEmbeddingTest: Bool = false
    @State var selectedTestModelSlug: String = ""
    @State var testPrompt: String = "Garage provides local retrieval-augmented generation for personal archives."
    @State var testEmbeddingDimensions: String = ""

    var llama: LlamaService {
        appState.llama
    }

    var modelDownload: ModelDownloadService {
        appState.modelDownload
    }

    // MARK: - Model Providers

    public enum ModelProvider: String, CaseIterable, Identifiable, Codable {
        case llamaXPC = "Llama XPC"
        case ollama = "Ollama"
        case lmStudio = "LM Studio"

        public var id: Self { self }

        /// The name on screen. `rawValue` stays as it was: it is the enum's coded form.
        public var displayName: String {
            switch self {
            case .llamaXPC: "Built-in engine"
            case .ollama, .lmStudio: rawValue
            }
        }

        public var cliValue: String {
            switch self {
            case .llamaXPC: "llama_xpc"
            case .ollama: "ollama"
            case .lmStudio: "lmstudio"
            }
        }

        public static func from(string: String?) -> ModelProvider {
            guard let str = string?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
                return .llamaXPC
            }
            if str.contains("ollama") { return .ollama }
            if str.contains("lmstudio") || str.contains("lm_studio") || str.contains("lm studio") { return .lmStudio }
            return .llamaXPC
        }
    }

    // MARK: - Body

    /// The page's tabs: a glance at everything, then one page per kind of model.
    enum Page: String, CaseIterable, Identifiable {
        case overall = "Overall"
        case embedding = "Embedding"
        case distillation = "Distillation"
        case inference = "Inference"

        var id: Self { self }
    }

    @State var selectedTab: Page = .overall

    var body: some View {
        VStack(spacing: 0) {
            // The segmented control sits centered, as a view switcher does in a macOS toolbar;
            // Refresh keeps to the trailing edge.
            ZStack {
                Picker("Page", selection: $selectedTab) {
                    ForEach(Page.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 440)
                .accessibilityIdentifier("models.tab")

                HStack(spacing: 8) {
                    Spacer()
                    if appState.isFetchingModels || busy {
                        ProgressView().controlSize(.small)
                    }
                    Button {
                        refreshAll()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh models")
                    .accessibilityLabel("Refresh models")
                    .accessibilityIdentifier("models.refresh")
                    .disabled(busy || appState.isFetchingModels)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                // Each section is type-erased: together their concrete types make one view value large enough that an
                // unoptimized (Debug) build overflows the main thread's stack copying it.
                VStack(alignment: .leading, spacing: 20) {
                    switch selectedTab {
                    case .overall:
                        AnyView(overallEmbeddingSection)
                        AnyView(overallDistillationSection)
                        AnyView(providersSection)
                        AnyView(activitySection)
                    case .embedding:
                        AnyView(embeddingModelsSection)
                        AnyView(embeddingTestSection)
                        if !appState.backfill.logs.isEmpty {
                            AnyView(backfillOutputBox)
                        }
                    case .distillation:
                        AnyView(distillationSection)
                        FactPromptsSection()
                        if !appState.enrichFacts.logs.isEmpty {
                            AnyView(enrichFactsOutputBox)
                        }
                    case .inference:
                        AnyView(inferenceSection)
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle("Models")
        .task {
            appState.fetchPresetModels()
            await appState.fetchRegisteredModels()
            await appState.fetchCorpusStats()
            await modelDownload.refresh()
            if !llama.isConnected {
                await llama.refreshStatus()
            }
        }
        .alert(pendingUnloadAlias.map { "Unload '\($0)'?" } ?? "Unload all models?", isPresented: $showUnloadConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Unload", role: .destructive) {
                let alias = pendingUnloadAlias
                pendingUnloadAlias = nil
                Task {
                    if let alias = alias {
                        await llama.unloadModel(alias: alias)
                    } else {
                        await llama.unloadModel()
                    }
                }
            }
        } message: {
            Text("This frees the model's memory in the built-in engine. Embedding and fact distillation load it again when they need it.")
        }
    }

    // MARK: - Text embedding models

    var embeddingModelsSection: some View {
        GroupBox("Text Embedding Models") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 8) {
                    Text(embeddingSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()

                    if unifiedModels.count > 3 {
                        TextField("Filter", text: $searchText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                    }

                    Button("Embed All") {
                        backfillAllModels()
                    }
                    .disabled(appState.registeredModels.isEmpty || notReady || appState.backfill.isRunning)
                    .help("Embed every chunk that is missing a vector, under every registered model")
                }

                if unifiedModels.isEmpty {
                    emptyState(
                        symbol: "circle.hexagongrid",
                        title: "No embedding model yet",
                        detail: "Search needs at least one. Add a recommended model below; the first one becomes the default."
                    )
                } else if filteredModels.isEmpty {
                    emptyState(symbol: "magnifyingglass", title: "No model matches \"\(searchText)\"", detail: nil)
                } else {
                    VStack(spacing: 8) {
                        ForEach(filteredModels) { item in
                            modelRow(role: .embedding, item: item)
                        }
                    }
                }

                Divider()
                    .padding(.vertical, 2)

                addModelSection
            }
            .padding(8)
        }
    }

    /// "2 models · 9,120 of 10,000 chunks embedded", or what is missing for that to be true.
    var embeddingSummary: String {
        let (required, missing) = embeddingsRequiredAndMissing
        return ModelsPresentation.embeddingSummary(
            modelCount: unifiedModels.count,
            totalChunks: appState.corpusStats.totalChunks,
            required: required,
            missing: missing
        )
    }

    /// Embeddings the registered models need and how many are missing, counted over the models
    /// registered now rather than the stats' model list, which lags a registration until the next
    /// stats fetch.
    var embeddingsRequiredAndMissing: (required: Int, missing: Int) {
        ModelsPresentation.embeddingsRequiredAndMissing(
            modelSlugs: unifiedModels.map(\.slug),
            stats: appState.corpusStats
        )
    }

    func emptyState(symbol: String, title: String, detail: String?) -> some View {
        VStack(alignment: .center, spacing: 6) {
            Image(systemName: symbol)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Fact distillation

    /// The `inference_models` presets, those tagged for distillation first, wrapped so the
    /// download/load helpers written for embedding rows apply unchanged.
    var distillationModelItems: [UnifiedModelItem] {
        let presets = appState.inferencePresets
        return (presets.filter(\.isForDistillation) + presets.filter { !$0.isForDistillation })
            .map { UnifiedModelItem(preset: $0) }
    }

    /// The facts model garage.json names, when it is not one of the presets on the page.
    var unlistedFactsModel: String? {
        let slug = appState.factsModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !slug.isEmpty, !appState.inferencePresets.contains(where: { $0.slug == slug }) else { return nil }
        return slug
    }

    var distillationSection: some View {
        GroupBox("Fact Distillation Model") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 8) {
                    Text("A small instruction-tuned model that gleans atomic facts from each document. It also answers rag_ask over MCP unless the Inference tab names another model. One model is in use at a time.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()

                    if appState.enrichFacts.isRunning {
                        ProgressView().controlSize(.small)
                    }
                    Button("Glean Facts") {
                        enrichAllFacts()
                    }
                    .disabled(notReady || appState.enrichFacts.isRunning)
                    .help("Run every enabled prompt over every document that has no facts from it yet")
                }

                if let unlisted = unlistedFactsModel {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                        Text("garage.json names \(unlisted) via \(appState.factsProvider), which is not one of the presets below.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if distillationModelItems.isEmpty {
                    emptyState(
                        symbol: "text.quote",
                        title: "No distillation presets",
                        detail: "models.json lists no inference models. Facts and rag_ask stay off until one is configured."
                    )
                } else {
                    VStack(spacing: 8) {
                        ForEach(distillationModelItems) { item in
                            modelRow(role: .distillation, item: item)
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    func useForFacts(item: UnifiedModelItem) {
        settingFactsModelSlug = item.slug
        Task {
            await appState.setFactsModel(item.slug, provider: item.provider.cliValue)
            settingFactsModelSlug = nil
        }
    }

    // MARK: - Inference

    /// The `inference_models` presets tagged for inference, those that call tools first.
    var inferenceModelItems: [UnifiedModelItem] {
        let presets = appState.inferencePresets.filter(\.isForInference)
        return (presets.filter(\.toolCalling) + presets.filter { !$0.toolCalling })
            .map { UnifiedModelItem(preset: $0) }
    }

    /// The inference model garage.json names, when it is not one of the presets on the page.
    var unlistedInferenceModel: String? {
        guard let slug = appState.inferenceModel,
              !appState.inferencePresets.contains(where: { $0.slug == slug }) else { return nil }
        return slug
    }

    var inferenceSection: some View {
        GroupBox("Inference Model") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 8) {
                    Text(inferenceSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()

                    Button {
                        useForInference(slug: nil, provider: nil)
                    } label: {
                        if settingInferenceModelSlug == "" {
                            ProgressView().controlSize(.mini)
                        } else {
                            Text("Follow Distillation")
                        }
                    }
                    .disabled(appState.inferenceModel == nil || settingInferenceModelSlug != nil || notReady)
                    .help("Clears inference.model in garage.json so rag_ask uses the distillation model")
                    .accessibilityIdentifier("models.inference.followDistillation")
                }

                if let unlisted = unlistedInferenceModel {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                        Text("garage.json names \(unlisted) via \(appState.inferenceProvider ?? appState.factsProvider), which is not one of the presets below.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if inferenceModelItems.isEmpty {
                    emptyState(
                        symbol: "bubble.left.and.text.bubble.right",
                        title: "No inference presets",
                        detail: "models.json lists no models tagged for inference. rag_ask uses the distillation model."
                    )
                } else {
                    VStack(spacing: 8) {
                        ForEach(inferenceModelItems) { item in
                            modelRow(role: .inference, item: item)
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    /// Says which model answers chat, and whether it is the distillation model.
    var inferenceSummary: String {
        let lead = "The model that answers rag_ask and rag_generate over MCP. Models marked TOOLS can call Garage's tools."
        if let chosen = appState.inferenceModel {
            return "\(lead) In use: \(chosen)."
        }
        return "\(lead) None is chosen, so the distillation model (\(appState.factsModel)) answers."
    }

    /// Sets `inference.*` to a model, or with a nil slug clears it to follow the distillation model.
    func useForInference(slug: String?, provider: String?) {
        settingInferenceModelSlug = slug ?? ""
        Task {
            if let slug {
                await appState.setInferenceModel(slug, provider: provider ?? GarageConfigLoader.defaultFactsProvider)
            } else {
                await appState.setInferenceModel(nil)
            }
            settingInferenceModelSlug = nil
        }
    }

    // MARK: - Providers

    /// LM Studio gets a row once something on the page uses it, or a token is stored.
    var showsLMStudio: Bool {
        appState.lmStudioTokenConfigured
            || provider == .lmStudio
            || unifiedModels.contains { $0.provider == .lmStudio }
            || ModelProvider.from(string: appState.factsProvider) == .lmStudio
    }

    var providersSection: some View {
        GroupBox("Providers") {
            VStack(alignment: .leading, spacing: 10) {
                llamaProviderRow
                if showsLMStudio {
                    Divider()
                    lmStudioProviderRow
                }
            }
            .padding(8)
        }
    }

    var llamaProviderRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                ModelSymbolCircle(symbol: "cpu", tint: llama.statusColor, isActive: llama.isConnected)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Built-in engine")
                        .font(.system(size: 13, weight: .medium))
                    Text(llamaDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                if llama.isBusy {
                    ProgressView().controlSize(.small)
                }
                if !llama.models.isEmpty {
                    Button("Unload All") {
                        pendingUnloadAlias = nil
                        showUnloadConfirmation = true
                    }
                    .controlSize(.small)
                    .disabled(llama.isBusy)
                }
                Button("Refresh") {
                    Task { await llama.refreshStatus() }
                }
                .controlSize(.small)
                .disabled(llama.isBusy)
            }

            if let err = llama.lastError {
                Text(err)
                    .font(.caption.monospaced())
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(.leading, 38)
            }

            if llama.isConnected, !llama.models.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(llama.models, id: \.id) { model in
                        residentModelRow(alias: model.id)
                    }
                }
                .padding(.leading, 38)
                .padding(.top, 2)
            }
        }
    }

    /// One model LlamaXPCService holds in memory: what it is for, and Unload.
    func residentModelRow(alias: String) -> some View {
        let known = unifiedModels.first { $0.slug == alias || $0.effectiveFilename == alias }
            ?? distillationModelItems.first { $0.slug == alias || $0.effectiveFilename == alias }
        let isEmbeddingModel = known?.registeredModel != nil
        let detail = ModelsPresentation.residentModelDetail(
            isEmbeddingModel: isEmbeddingModel,
            isDefaultEmbeddingModel: isEmbeddingModel && known?.isDefault == true,
            isFactsModel: appState.factsModel == alias,
            answersUnnamedRequests: llama.activeModelId == alias
        )

        return HStack(spacing: 8) {
            Circle()
                .fill(Color.purple)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(known?.name ?? alias)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if let known, known.name != alias {
                        Text(alias)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Unload") {
                pendingUnloadAlias = alias
                showUnloadConfirmation = true
            }
            .controlSize(.small)
            .disabled(llama.isBusy)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityIdentifier("models.llama.resident.\(alias)")
    }

    /// "Running · 2 models loaded · 3 slots idle", from the service's own status line.
    var llamaDetail: String {
        ModelsPresentation.llamaDetail(
            statusMessage: llama.statusMessage,
            isConnected: llama.isConnected,
            loadedCount: llama.loadedModelIds.count,
            slotsIdle: llama.health?.slotsIdle,
            slotsProcessing: llama.health?.slotsProcessing
        )
    }

    var lmStudioProviderRow: some View {
        HStack(alignment: .top, spacing: 10) {
            ModelSymbolCircle(symbol: "key", tint: .teal, isActive: appState.lmStudioTokenConfigured)

            VStack(alignment: .leading, spacing: 2) {
                Text("LM Studio")
                    .font(.system(size: 13, weight: .medium))
                Text(
                    appState.lmStudioTokenConfigured
                        ? "API token stored in the Keychain and sent with every request."
                        : "No API token. Only needed when LM Studio's server requires authentication."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            SecureField("API token", text: $lmStudioToken)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
            Button(appState.lmStudioTokenConfigured ? "Replace" : "Save") {
                if appState.saveLMStudioToken(lmStudioToken) {
                    lmStudioToken = ""
                }
            }
            .controlSize(.small)
            .disabled(lmStudioToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if appState.lmStudioTokenConfigured {
                Button("Remove", role: .destructive) {
                    appState.removeLMStudioToken()
                    lmStudioToken = ""
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: - Activity

    var activitySection: some View {
        Group {
            if !appState.backfill.logs.isEmpty {
                backfillOutputBox
            }
            if !appState.enrichFacts.logs.isEmpty {
                enrichFactsOutputBox
            }
        }
    }

    var backfillOutputBox: some View {
        GroupBox("Embedding Output") {
            LogTableView(
                lines: appState.backfill.logs,
                sourceName: "Embed",
                onClear: { appState.backfill.clearLogs() }
            )
            .frame(minHeight: 180, maxHeight: 300)
        }
    }

    var enrichFactsOutputBox: some View {
        GroupBox("Fact Distillation Output") {
            LogTableView(
                lines: appState.enrichFacts.logs,
                sourceName: "Glean Facts",
                onClear: { appState.enrichFacts.clearLogs() }
            )
            .frame(minHeight: 180, maxHeight: 300)
        }
    }

    // MARK: - Helpers

    var notReady: Bool {
        appState.postgres.status != .running || busy
    }

    func refreshAll() {
        Task {
            appState.fetchPresetModels()
            await appState.fetchRegisteredModels()
            await appState.fetchCorpusStats()
            await modelDownload.refresh()
            await llama.refreshStatus()
        }
    }

    func toggleExpanded(_ slug: String) {
        if expandedSlugs.contains(slug) {
            expandedSlugs.remove(slug)
        } else {
            expandedSlugs.insert(slug)
        }
    }

    func isModelFileDownloaded(item: UnifiedModelItem) -> Bool {
        if let filename = item.effectiveFilename {
            return modelDownload.isModelDownloaded(filename: filename)
        }
        return false
    }

    func getDownloadedInfo(item: UnifiedModelItem) -> DownloadedModelInfo? {
        if let filename = item.effectiveFilename {
            return modelDownload.downloadedModel(for: filename)
        }
        return nil
    }

    func isModelDownloading(item: UnifiedModelItem) -> Bool {
        if isModelFileDownloaded(item: item) {
            return false
        }
        if let url = item.effectiveDownloadURL {
            return modelDownload.isModelDownloading(url: url)
        }
        if let filename = item.effectiveFilename {
            return modelDownload.isModelDownloading(url: filename)
        }
        return false
    }

    func getActiveDownloadTask(item: UnifiedModelItem) -> DownloadTaskInfo? {
        if isModelFileDownloaded(item: item) {
            return nil
        }
        return modelDownload.activeDownloads.first {
            ($0.status == .downloading || $0.status == .queued) &&
            ($0.modelId == item.slug ||
            $0.filename == item.effectiveFilename ||
            URL(fileURLWithPath: $0.filename).lastPathComponent == item.effectiveFilename ||
            (item.effectiveFilename != nil && URL(fileURLWithPath: item.effectiveFilename!).lastPathComponent == URL(fileURLWithPath: $0.filename).lastPathComponent) ||
            $0.url == item.effectiveDownloadURL)
        }
    }

    func isModelActiveInLlama(item: UnifiedModelItem) -> Bool {
        guard let activeId = llama.activeModelId, llama.health?.status != "no_model_loaded" else {
            return false
        }
        return activeId == item.slug ||
            activeId == item.effectiveFilename ||
            llama.models.contains(where: { $0.id == item.slug || $0.id == item.effectiveFilename })
    }

    func downloadModelToLlamaXPC(item: UnifiedModelItem) {
        guard let url = item.effectiveDownloadURL else { return }
        Task {
            await modelDownload.startDownload(
                url: url,
                filename: item.effectiveFilename,
                modelId: item.slug,
                sha256: item.effectiveSha256
            )
        }
    }

    func loadDownloadedModel(item: UnifiedModelItem, dlInfo: DownloadedModelInfo?) {
        guard let dl = dlInfo ?? getDownloadedInfo(item: item) else { return }
        // The same settings an on-demand load (LlamaModelLoader) uses, so the model behaves alike
        // whichever loaded it.
        let plan = LlamaModelLoadPlan(
            alias: item.slug,
            displayName: item.name,
            path: dl.path,
            contextSize: item.contextSize ?? LlamaModelLoadDefaults.contextSize,
            gpuLayers: LlamaModelLoadDefaults.gpuLayers
        )
        Task {
            await llama.loadModel(path: plan.path, alias: plan.alias, config: plan.config)
        }
    }

    func selectForTesting(item: UnifiedModelItem) {
        selectedTestModelSlug = item.slug
        if let dimsVal = item.dims {
            testEmbeddingDimensions = "\(dimsVal)"
        }
        selectedTab = .embedding
        showEmbeddingTest = true
    }

    func run(
        triggersMaintenance: Bool = false,
        _ operation: @escaping @MainActor (GarageGRPCService) async throws -> String
    ) {
        busy = true
        Task {
            await appState.runOperation(triggersMaintenance: triggersMaintenance, operation)
            await appState.fetchRegisteredModels()
            // A registry change moves the per-model stats the rows and headline read.
            await appState.fetchCorpusStats()
            busy = false
        }
    }

    func backfillModel(slug: String) {
        busy = true
        backfillTarget = slug
        Task {
            await appState.runBackfill(model: slug)
            await appState.fetchCorpusStats()
            await appState.fetchRegisteredModels()
            backfillTarget = nil
            busy = false
        }
    }

    func backfillAllModels() {
        busy = true
        backfillTarget = "*"
        Task {
            await appState.runBackfill()
            await appState.fetchCorpusStats()
            await appState.fetchRegisteredModels()
            backfillTarget = nil
            busy = false
        }
    }

    /// Whether the running backfill, if any, embeds under `slug`.
    func isEmbedding(slug: String) -> Bool {
        ModelsPresentation.isEmbedding(slug: slug, backfillRunning: appState.backfill.isRunning, target: backfillTarget)
    }

    func enrichAllFacts() {
        Task {
            await appState.runEnrichFacts()
        }
    }

    func copyVectorToClipboard(vector: [Float]) {
        if let data = try? JSONSerialization.data(withJSONObject: vector, options: []),
           let jsonStr = String(data: data, encoding: .utf8) {
            NSPasteboard.general.copy(jsonStr)
        }
    }

    func copyCSVToClipboard(vector: [Float]) {
        let formatted = vector.map { String(format: "%.8f", $0) }.joined(separator: ", ")
        NSPasteboard.general.copy(formatted)
    }
}

/// The tinted circle a model or provider row starts with, in the shape of the menu bar's
/// Control Center-style rows: filled in the row's color while the thing is live, faint otherwise.
struct ModelSymbolCircle: View {
    let symbol: String
    let tint: Color
    var isActive: Bool = true

    var body: some View {
        ZStack {
            Circle()
                .fill(isActive ? AnyShapeStyle(tint) : AnyShapeStyle(HierarchicalShapeStyle.quaternary))
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isActive ? AnyShapeStyle(Color.white) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }
}

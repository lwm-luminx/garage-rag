import AppKit
import SwiftUI
import LlamaClient
import ModelDownloadClient

// One row per model. The row leads with the model's name and one line that says where it stands
// (downloading, not downloaded, embedded, chunks left to embed, loaded), the actions that follow
// from that state sit on the right, and a chevron opens the file, hash and table details.

extension ModelsView {
    /// Whether a row is an embedding model (registered in the database, with a vector table) or a
    /// fact-distillation preset (loaded on demand, one in use at a time).
    enum ModelRowRole {
        case embedding
        case distillation
    }

    /// The one line a row says about its model, and how it is drawn.
    struct ModelRowState {
        let symbol: String
        let tint: Color
        /// The circle is filled in `tint` while the model is live (loaded, embedding, downloading,
        /// fully embedded) and faint while something is still to be done.
        let isActive: Bool
        let text: String
        var progress: Double? = nil
        /// A download in flight, for the Cancel button under the progress bar.
        var downloadTask: DownloadTaskInfo? = nil
    }

    /// What an embedding model row says. The file comes first, because without it nothing else
    /// can happen for a Llama XPC model; then the corpus.
    func embeddingRowState(for item: UnifiedModelItem) -> ModelRowState {
        if let fileState = fileRowState(for: item) {
            return fileState
        }

        let stats = appState.corpusStats.modelStats.first { $0.slug == item.slug }
        let totalChunks = appState.corpusStats.totalChunks
        let embedded = stats?.embeddedCount ?? 0
        let remaining = max(0, totalChunks - embedded)
        let fraction = totalChunks > 0 ? min(1.0, max(0.0, Double(embedded) / Double(totalChunks))) : 0.0

        if totalChunks == 0 {
            return ModelRowState(symbol: "circle.hexagongrid", tint: .secondary, isActive: false, text: "No chunks to embed yet")
        }
        if remaining == 0 {
            return ModelRowState(
                symbol: "checkmark",
                tint: .green,
                isActive: true,
                text: "Embedded · \(totalChunks.formatted()) chunk\(totalChunks == 1 ? "" : "s")"
            )
        }
        if isEmbedding(slug: item.slug) {
            return ModelRowState(
                symbol: "circle.hexagongrid.fill",
                tint: .blue,
                isActive: true,
                text: "Embedding · \(embedded.formatted()) of \(totalChunks.formatted()) chunks",
                progress: fraction
            )
        }
        return ModelRowState(
            symbol: "circle.hexagongrid",
            tint: .orange,
            isActive: false,
            text: "\(remaining.formatted()) chunk\(remaining == 1 ? "" : "s") to embed · \(embedded.formatted()) of \(totalChunks.formatted()) done",
            progress: fraction
        )
    }

    /// What a distillation preset row says: the file, then whether Llama XPC has it loaded.
    func distillationRowState(for item: UnifiedModelItem) -> ModelRowState {
        if let fileState = fileRowState(for: item) {
            return fileState
        }
        switch item.provider {
        case .llamaXPC:
            if llama.isModelLoaded(alias: item.slug) {
                return ModelRowState(symbol: "bolt.fill", tint: .purple, isActive: true, text: "Loaded in the built-in engine")
            }
            return ModelRowState(symbol: "internaldrive", tint: .secondary, isActive: false, text: "On disk · loads when facts are gleaned")
        case .ollama, .lmStudio:
            return ModelRowState(symbol: "network", tint: .secondary, isActive: false, text: "Served by \(item.provider.displayName)")
        }
    }

    /// The download side of a Llama XPC model: in flight, or not on disk. `nil` once the file is
    /// there, or when the provider serves the model itself.
    func fileRowState(for item: UnifiedModelItem) -> ModelRowState? {
        guard item.provider == .llamaXPC, !isModelFileDownloaded(item: item) else { return nil }
        if let task = getActiveDownloadTask(item: item) {
            var parts = ["Downloading", task.formattedProgress]
            if !task.formattedSpeed.isEmpty { parts.append(task.formattedSpeed) }
            if !task.formattedETA.isEmpty { parts.append("\(task.formattedETA) left") }
            return ModelRowState(
                symbol: "arrow.down",
                tint: .blue,
                isActive: true,
                text: parts.joined(separator: " · "),
                progress: task.fractionCompleted,
                downloadTask: task
            )
        }
        if item.effectiveDownloadURL != nil {
            return ModelRowState(symbol: "arrow.down", tint: .orange, isActive: false, text: "Not downloaded")
        }
        return ModelRowState(symbol: "questionmark", tint: .orange, isActive: false, text: "No model file on disk and nowhere to download it from")
    }

    // MARK: - The row

    func modelRow(role: ModelRowRole, item: UnifiedModelItem) -> some View {
        let state = role == .embedding ? embeddingRowState(for: item) : distillationRowState(for: item)
        let isExpanded = expandedSlugs.contains(item.slug)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                ModelSymbolCircle(symbol: state.symbol, tint: state.tint, isActive: state.isActive)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(item.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        rowTags(role: role, item: item)
                        Spacer(minLength: 8)
                        rowActions(role: role, item: item)
                        Button {
                            toggleExpanded(item.slug)
                        } label: {
                            DisclosureChevron(isExpanded: isExpanded)
                        }
                        .buttonStyle(.plain)
                        .help(isExpanded ? "Hide details" : "Show file, hash and table details")
                        .accessibilityLabel(isExpanded ? "Hide details" : "Show details")
                    }

                    Text(state.text)
                        .font(.caption)
                        .foregroundStyle(state.isActive || state.tint == .secondary ? AnyShapeStyle(HierarchicalShapeStyle.secondary) : AnyShapeStyle(state.tint))
                        .lineLimit(2)

                    if let progress = state.progress {
                        HStack(spacing: 8) {
                            ProgressView(value: progress)
                                .progressViewStyle(.linear)
                            if let task = state.downloadTask {
                                Button("Cancel") {
                                    Task { await modelDownload.cancelDownload(taskId: task.id) }
                                }
                                .controlSize(.mini)
                            }
                        }
                    }
                }
            }

            if isExpanded {
                rowDetails(role: role, item: item)
                    .padding(.leading, 38)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        // A container, so the identifier names the row instead of replacing its controls' own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("models.row.\(item.slug)")
    }

    /// At most three tags: what the model is for the app (default, in use), who serves it, and
    /// whether Llama XPC holds it right now.
    @ViewBuilder
    func rowTags(role: ModelRowRole, item: UnifiedModelItem) -> some View {
        if role == .embedding, item.isDefault {
            StatusBadge("DEFAULT", tint: .green)
        }
        if role == .distillation, appState.factsModel == item.slug {
            StatusBadge("IN USE", tint: .green)
        }
        if role == .distillation, let preset = item.presetEntry, !preset.isForDistillation {
            StatusBadge("CHAT ONLY", tint: .orange)
                .help("Tagged for inference (chat, rag_ask) but not for distilling facts")
        }
        if item.provider != .llamaXPC {
            StatusBadge(item.provider.displayName.uppercased(), tint: item.provider == .ollama ? .orange : .teal)
        }
        if role == .embedding, item.provider == .llamaXPC, isModelActiveInLlama(item: item) {
            StatusBadge("LOADED", tint: .purple)
        }
    }

    @ViewBuilder
    func rowActions(role: ModelRowRole, item: UnifiedModelItem) -> some View {
        let isDownloaded = isModelFileDownloaded(item: item)
        let downloadedInfo = getDownloadedInfo(item: item)
        let isDownloading = isModelDownloading(item: item)
        let isLoaded = role == .embedding ? isModelActiveInLlama(item: item) : llama.isModelLoaded(alias: item.slug)

        if item.provider == .llamaXPC && !isDownloaded && !isDownloading && item.effectiveDownloadURL != nil {
            Button("Download") {
                downloadModelToLlamaXPC(item: item)
            }
            .controlSize(.small)
            .disabled(modelDownload.isBusy)
            .help("Download the model file to the models folder and verify its SHA-256")
        }

        if isDownloaded, let dl = downloadedInfo {
            if isLoaded {
                Button("Unload") {
                    pendingUnloadAlias = item.slug
                    showUnloadConfirmation = true
                }
                .controlSize(.small)
                .disabled(llama.isBusy)
            } else {
                Button("Load") {
                    loadDownloadedModel(item: item, dlInfo: dl)
                }
                .controlSize(.small)
                .disabled(llama.isBusy)
                .help("Load the model into the built-in engine now rather than on first use")
            }
        }

        switch role {
        case .embedding:
            Button("Embed") {
                backfillModel(slug: item.slug)
            }
            .controlSize(.small)
            .disabled(notReady || appState.backfill.isRunning)
            .help("Embed every chunk that has no vector under this model")
        case .distillation:
            let isFactsModel = appState.factsModel == item.slug
            let isSetting = settingFactsModelSlug == item.slug
            Button {
                useForFacts(item: item)
            } label: {
                if isSetting {
                    ProgressView().controlSize(.mini)
                } else {
                    Text("Use for Facts")
                }
            }
            .controlSize(.small)
            .disabled(isFactsModel || settingFactsModelSlug != nil || notReady)
            .help("Sets facts.model to \(item.slug) and facts.provider to \(item.provider.cliValue) in garage.json")
        }

        rowMenu(role: role, item: item, downloadedInfo: downloadedInfo)
    }

    func rowMenu(role: ModelRowRole, item: UnifiedModelItem, downloadedInfo: DownloadedModelInfo?) -> some View {
        Menu {
            if role == .embedding {
                Button("Set as Default") {
                    run { try await $0.setDefaultModel(slug: item.slug).message }
                }
                .disabled(item.isDefault || notReady)

                Button("Test an Embedding…") {
                    selectForTesting(item: item)
                }
            }

            if let modelCard = item.presetEntry?.modelCardURL {
                Button("Model Card and License") {
                    NSWorkspace.shared.open(modelCard)
                }
            }

            if let expectedSha = item.effectiveSha256 {
                Button("Copy Expected SHA-256") {
                    modelDownload.copyToClipboard(text: expectedSha)
                }
            }

            if let dl = downloadedInfo {
                Divider()
                Button("Verify File") {
                    Task { await modelDownload.verifyModelFile(path: dl.path, expectedSha256: item.effectiveSha256) }
                }
                .disabled(modelDownload.isVerifying(path: dl.path))
                Button("Reveal in Finder") {
                    modelDownload.revealInFinder(path: dl.path)
                }
                Button("Delete Model File", role: .destructive) {
                    Task { await modelDownload.deleteDownloadedModel(dl) }
                }
            }

            if role == .embedding {
                Divider()
                Button("Remove from Database", role: .destructive) {
                    run { try await $0.dropModel(slug: item.slug).message }
                }
                .disabled(notReady)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Model actions")
        .accessibilityIdentifier("models.row.\(item.slug).menu")
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 20)
    }

    // MARK: - Details

    /// The identifiers, file and hash a person needs when something is off, or when they want to
    /// check that the file is the one published: a label-and-value grid under the row.
    func rowDetails(role: ModelRowRole, item: UnifiedModelItem) -> some View {
        let downloadedInfo = getDownloadedInfo(item: item)

        return Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
            detailRow("Slug", item.slug)
            if item.modelRef != item.slug {
                detailRow("Model ref", item.modelRef)
            }
            detailRow("Provider", item.provider.displayName, monospaced: false)
            if let dims = item.dims {
                detailRow("Dimensions", dimensionsDetail(item: item, dims: dims), monospaced: false)
            }
            if let ctx = item.contextSize {
                detailRow("Context", "\(ctx.formatted()) tokens", monospaced: false)
            }
            if let reg = item.registeredModel {
                detailRow("Table", reg.tableName)
            }
            if let dl = downloadedInfo {
                detailRow("File", "\(dl.filename) · \(dl.formattedSize)")
            } else if let filename = item.effectiveFilename {
                detailRow("File", "\(filename) · not downloaded")
            }
            if item.effectiveSha256 != nil || downloadedInfo != nil {
                GridRow {
                    detailLabel("SHA-256")
                    hashDetail(item: item, downloadedInfo: downloadedInfo)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// "1024 · stored as 1024 halfvec, HNSW" from the registration, or just the count.
    func dimensionsDetail(item: UnifiedModelItem, dims: Int) -> String {
        guard let reg = item.registeredModel else { return "\(dims)" }
        var stored: [String] = []
        if reg.storedDims > 0, reg.storedDims != dims {
            stored.append("stored as \(reg.storedDims)")
        }
        if !reg.storageKind.isEmpty {
            stored.append(reg.storageKind)
        }
        if !reg.indexKind.isEmpty {
            stored.append(reg.indexKind.uppercased())
        }
        return stored.isEmpty ? "\(dims)" : "\(dims) · \(stored.joined(separator: " "))"
    }

    func detailRow(_ label: String, _ value: String, monospaced: Bool = true) -> some View {
        GridRow {
            detailLabel(label)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .caption)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func detailLabel(_ label: String) -> some View {
        Text(label)
            .font(.caption)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    /// The expected hash from models.json, and what a verification of the file found. A match
    /// replaces the expected hash rather than repeating it.
    @ViewBuilder
    func hashDetail(item: UnifiedModelItem, downloadedInfo: DownloadedModelInfo?) -> some View {
        let verification = downloadedInfo.flatMap { modelDownload.verificationResult(for: $0.path) }
        let isVerifying = downloadedInfo.map { modelDownload.isVerifying(path: $0.path) } ?? false
        let expected = item.effectiveSha256

        VStack(alignment: .leading, spacing: 3) {
            if let v = verification {
                HStack(spacing: 4) {
                    Image(systemName: v.isValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(v.isValid ? Color.green : Color.red)
                    Text(v.isValid ? (expected == nil ? "Computed" : "Verified") : "Mismatch, computed")
                        .font(.caption)
                        .foregroundStyle(v.isValid ? Color.green : Color.red)
                    hashText(v.computedSha256)
                }
                if !v.isValid, let expected {
                    HStack(spacing: 4) {
                        Text("Expected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        hashText(expected)
                    }
                }
            } else if let expected {
                HStack(spacing: 4) {
                    Text(isVerifying ? "Verifying against" : (downloadedInfo == nil ? "Expected" : "Unverified, expected"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    hashText(expected)
                    if isVerifying {
                        ProgressView().controlSize(.mini)
                    } else if let dl = downloadedInfo {
                        Button("Verify") {
                            Task { await modelDownload.verifyModelFile(path: dl.path, expectedSha256: expected) }
                        }
                        .controlSize(.mini)
                    }
                }
            } else if let dl = downloadedInfo {
                HStack(spacing: 4) {
                    Text("No published hash to check against")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if isVerifying {
                        ProgressView().controlSize(.mini)
                    } else {
                        Button("Compute") {
                            Task { await modelDownload.verifyModelFile(path: dl.path, expectedSha256: nil) }
                        }
                        .controlSize(.mini)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func hashText(_ hash: String) -> some View {
        HStack(spacing: 3) {
            Text(hash)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                modelDownload.copyToClipboard(text: hash)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .help("Copy SHA-256")
            .accessibilityLabel("Copy SHA-256")
        }
    }
}

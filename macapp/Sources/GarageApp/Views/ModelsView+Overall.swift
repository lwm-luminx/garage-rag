import SwiftUI

// The Overall tab: one card per kind of model that answers "is it working" at a glance, with the
// one action each has (Embed All, Glean Facts) and a way into its own tab. The rows here are
// one line each; the tabs carry the actions and details.

extension ModelsView {
    /// The headline the Embedding card leads with, in the Status page's style.
    struct OverallHeadline {
        let symbol: String
        let tint: Color
        let isActive: Bool
        let title: String
        let detail: String
        var progress: Double? = nil
    }

    var embeddingHeadline: OverallHeadline {
        let stats = appState.corpusStats
        let count = unifiedModels.count
        let models = "\(count) model\(count == 1 ? "" : "s")"
        let missingFiles = unifiedModels.filter { $0.provider == .llamaXPC && !isModelFileDownloaded(item: $0) && getActiveDownloadTask(item: $0) == nil }
        let (required, missing) = embeddingsRequiredAndMissing
        let fraction = required > 0 ? Double(max(0, required - missing)) / Double(required) : 0
        let kind = ModelsPresentation.embeddingHeadlineKind(
            modelCount: count,
            missingFileNames: missingFiles.map(\.name),
            totalChunks: stats.totalChunks,
            missing: missing,
            backfillRunning: appState.backfill.isRunning
        )
        switch kind {
        case .noModel:
            return OverallHeadline(
                symbol: "circle.hexagongrid",
                tint: .orange,
                isActive: false,
                title: "No embedding model",
                detail: "Search needs one. Add a recommended model on the Embedding tab."
            )
        case .filesMissing(let names):
            return OverallHeadline(
                symbol: "arrow.down",
                tint: .orange,
                isActive: false,
                title: "Model file missing",
                detail: "\(names.joined(separator: ", ")) \(names.count == 1 ? "is" : "are") not downloaded, so nothing can be embedded with \(names.count == 1 ? "it" : "them")."
            )
        case .waitingForIngest:
            return OverallHeadline(
                symbol: "circle.hexagongrid",
                tint: .secondary,
                isActive: false,
                title: "Waiting for ingest",
                detail: "\(models) registered; there are no chunks to embed until a source is ingested."
            )
        case .ready:
            return OverallHeadline(
                symbol: "checkmark",
                tint: .green,
                isActive: true,
                title: "Search ready",
                detail: "\(stats.totalChunks.formatted()) chunks embedded under \(models)."
            )
        case .embedding:
            return OverallHeadline(
                symbol: "circle.hexagongrid.fill",
                tint: .blue,
                isActive: true,
                title: "Embedding…",
                detail: "\(missing.formatted()) of \(required.formatted()) embeddings to go across \(models).",
                progress: fraction
            )
        case .toGo:
            return OverallHeadline(
                symbol: "circle.hexagongrid",
                tint: .orange,
                isActive: false,
                title: "\(missing.formatted()) embedding\(missing == 1 ? "" : "s") to go",
                detail: "Search finds only embedded chunks. Embed All picks up where the last run stopped.",
                progress: fraction
            )
        }
    }

    var distillationHeadline: OverallHeadline {
        let slug = appState.factsModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !slug.isEmpty else {
            return OverallHeadline(
                symbol: "text.quote",
                tint: .secondary,
                isActive: false,
                title: "No distillation model",
                detail: "Facts and rag_ask stay off until one is picked on the Distillation tab."
            )
        }
        let item = distillationModelItems.first { $0.slug == slug }
        let name = item?.name ?? slug
        let provider = ModelProvider.from(string: appState.factsProvider)
        if let item {
            let state = distillationRowState(for: item)
            if appState.enrichFacts.isRunning {
                return OverallHeadline(symbol: "text.quote", tint: .blue, isActive: true, title: "Gleaning facts…", detail: "\(name) via \(provider.displayName).")
            }
            return OverallHeadline(symbol: state.symbol, tint: state.tint, isActive: state.isActive, title: name, detail: "\(state.text) · via \(provider.displayName).")
        }
        return OverallHeadline(
            symbol: "text.quote",
            tint: .secondary,
            isActive: false,
            title: name,
            detail: "Named in garage.json via \(provider.displayName); not one of the presets in models.json."
        )
    }

    var overallEmbeddingSection: some View {
        let headline = embeddingHeadline
        return GroupBox("Embedding") {
            VStack(alignment: .leading, spacing: 10) {
                headlineRow(headline) {
                    Button("Embed All") {
                        backfillAllModels()
                    }
                    .disabled(appState.registeredModels.isEmpty || notReady || appState.backfill.isRunning)
                    .help("Embed every chunk that is missing a vector, under every registered model")
                    .accessibilityIdentifier("models.embedAll")

                    Button("Manage…") {
                        selectedTab = .embedding
                    }
                    .accessibilityIdentifier("models.overall.manageEmbedding")
                }

                if !unifiedModels.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(unifiedModels) { item in
                            summaryLine(item: item, state: embeddingRowState(for: item), tag: item.isDefault ? "DEFAULT" : nil)
                        }
                    }
                    .padding(.leading, 38)
                }
            }
            .padding(8)
        }
    }

    var overallDistillationSection: some View {
        let headline = distillationHeadline
        return GroupBox("Fact Distillation") {
            VStack(alignment: .leading, spacing: 10) {
                headlineRow(headline) {
                    if appState.enrichFacts.isRunning {
                        ProgressView().controlSize(.small)
                    }
                    Button("Glean Facts") {
                        enrichAllFacts()
                    }
                    .disabled(notReady || appState.enrichFacts.isRunning)
                    .help("Run every enabled prompt over every document that has no facts from it yet")
                    .accessibilityIdentifier("models.gleanFacts")

                    Button("Manage…") {
                        selectedTab = .distillation
                    }
                    .accessibilityIdentifier("models.overall.manageDistillation")
                }

                let others = distillationModelItems.filter { $0.slug != appState.factsModel }
                if !others.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(others) { item in
                            summaryLine(item: item, state: distillationRowState(for: item), tag: nil)
                        }
                    }
                    .padding(.leading, 38)
                }
            }
            .padding(8)
        }
    }

    /// The card's first row: the tinted circle, a bold title, a detail line, an optional bar, and
    /// the card's actions on the right.
    func headlineRow<Actions: View>(_ headline: OverallHeadline, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ModelSymbolCircle(symbol: headline.symbol, tint: headline.tint, isActive: headline.isActive)

            VStack(alignment: .leading, spacing: 3) {
                Text(headline.title)
                    .font(.system(size: 15, weight: .semibold))
                Text(headline.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let progress = headline.progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                actions()
            }
        }
    }

    /// "BGE-M3  DEFAULT   Embedded · 10,000 chunks": one model, one line, no actions.
    func summaryLine(item: UnifiedModelItem, state: ModelRowState, tag: String?) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(state.isActive ? state.tint : Color.clear)
                .overlay(Circle().strokeBorder(state.tint, lineWidth: state.isActive ? 0 : 1.5))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(item.name)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            if let tag {
                StatusBadge(tag, tint: .green)
            }
            Text(state.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
    }
}

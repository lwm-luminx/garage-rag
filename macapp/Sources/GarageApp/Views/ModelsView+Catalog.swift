import SwiftUI

// The Distillation and Inference tabs, laid out as the Embedding tab is: the models that are
// installed, as full rows, then the rest of the catalog under "Download a Model" as compact rows
// with one Download button each.

extension ModelsView {
    /// On disk for the built-in engine, or served by another program (Ollama, LM Studio).
    func isInstalled(_ item: UnifiedModelItem) -> Bool {
        !item.provider.downloadsFiles || isModelFileDownloaded(item: item)
    }

    /// Whether the tab's setting names `item`: the facts model, or the model chat uses. Such a row
    /// stays with the installed ones even before its file is on disk, so its state is in view.
    func isChosen(role: ModelRowRole, item: UnifiedModelItem) -> Bool {
        switch role {
        case .distillation: appState.factsModel == item.slug
        case .inference: selectedInferenceSlug == item.slug
        case .embedding: false
        }
    }

    @ViewBuilder
    func installedAndDownloadable(role: ModelRowRole, items: [UnifiedModelItem], emptyDetail: String) -> some View {
        let installed = items.filter { isInstalled($0) || isChosen(role: role, item: $0) }
        let installedSlugs = Set(installed.map(\.slug))
        let available = items.filter { !installedSlugs.contains($0.slug) }

        if installed.isEmpty {
            emptyState(symbol: "internaldrive", title: "No model installed yet", detail: emptyDetail)
        } else {
            VStack(spacing: 8) {
                ForEach(installed) { item in
                    modelRow(role: role, item: item)
                }
            }
        }

        Divider()
            .padding(.vertical, 2)

        VStack(alignment: .leading, spacing: 8) {
            Text("Download a Model")
                .font(.subheadline.bold())
            if available.isEmpty {
                Text("Every model in the catalog is installed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(available) { item in
                        downloadableRow(role: role, item: item)
                    }
                }
            }
        }
    }

    /// A catalog model that is not on disk, drawn as the Embedding tab's "Add a model" rows are.
    func downloadableRow(role: ModelRowRole, item: UnifiedModelItem) -> some View {
        let preset = item.presetEntry
        let task = getActiveDownloadTask(item: item)
        let hasDownload = item.effectiveDownloadURL != nil || !item.downloadFileTargets.isEmpty

        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 13, weight: .semibold))
                    if preset?.featured == true {
                        StatusBadge("RECOMMENDED", tint: .green)
                    }
                    if preset?.toolCalling == true {
                        StatusBadge("TOOLS", tint: .purple)
                            .help("Calls tools, such as Garage's MCP tools")
                    }
                    if role == .distillation, let preset, !preset.isForDistillation {
                        StatusBadge("CHAT ONLY", tint: .orange)
                            .help("Tagged for inference (chat, rag_ask) but not for distilling facts")
                    }
                    if let region = preset?.originRegion, let preset {
                        StatusBadge(region, tint: .secondary)
                            .help("Made by \(preset.originSummary)")
                            .accessibilityLabel("Origin \(preset.originSummary)")
                    }
                }

                if let description = preset?.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let useCases = preset?.useCases, !useCases.isEmpty {
                    Text(useCases.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let modelCard = preset?.modelCardURL {
                    Link("Model card and license", destination: modelCard)
                        .font(.caption2)
                        .help(modelCard.absoluteString)
                }
                if let task {
                    HStack(spacing: 8) {
                        ProgressView(value: task.fractionCompleted)
                            .progressViewStyle(.linear)
                        Text(task.formattedProgress)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                }
            }

            Spacer()

            if let task {
                Button {
                    Task { await modelDownload.cancelDownload(taskId: task.id) }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help("Cancel the download")
                .accessibilityLabel("Cancel download of \(item.slug)")
                .accessibilityIdentifier("models.row.\(item.slug).cancelDownload")
            } else {
                Button {
                    downloadModelToLlamaXPC(item: item)
                } label: {
                    Image(systemName: "arrow.down")
                }
                .controlSize(.small)
                .disabled(!hasDownload || modelDownload.isBusy)
                .help(hasDownload
                    ? "Download \(item.slug) to the models folder and verify its SHA-256"
                    : "models.json gives no file to download for \(item.slug)")
                .accessibilityLabel("Download \(item.slug)")
                .accessibilityIdentifier("models.row.\(item.slug).download")
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("models.row.\(item.slug)")
    }
}

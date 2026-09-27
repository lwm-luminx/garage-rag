import SwiftUI

// Adding an embedding model: the presets from models.json that are not registered yet, each with
// one Add button, and a custom-model form folded under them for a model models.json does not know.

extension ModelsView {
    var addModelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add a model")
                .font(.subheadline.bold())

            if unregisteredPresetModels.isEmpty {
                Text(appState.presetModels.isEmpty ? "No presets were found in models.json." : "Every preset is registered.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(unregisteredPresetModels) { preset in
                        presetRow(preset)
                    }
                }
            }

            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showCustomForm.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    DisclosureChevron(isExpanded: showCustomForm)
                    Text("Custom model…")
                        .font(.subheadline)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("models.addCustom")

            if showCustomForm {
                customModelForm
                    .padding(.leading, 26)
            }
        }
    }

    func presetRow(_ preset: ModelPresetEntry) -> some View {
        let isRegistering = registeringPresetSlug == preset.slug

        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(preset.name)
                        .font(.system(size: 13, weight: .semibold))
                    if preset.featured {
                        StatusBadge("RECOMMENDED", tint: .green)
                    }
                    if preset.effectiveDims > 0 {
                        StatusBadge("\(preset.effectiveDims) DIMS", tint: .blue)
                    }
                    if preset.toolCalling {
                        StatusBadge("TOOLS", tint: .purple)
                            .help("Trained to call tools, so it can use Garage's MCP tools")
                    }
                    if let origin = preset.origin, let region = origin.region {
                        StatusBadge(region, tint: .secondary)
                            .help("Made by \(origin.summary)")
                            .accessibilityLabel("Origin \(origin.summary)")
                    }
                    let presetProvider = ModelProvider.from(string: preset.provider)
                    if presetProvider != .llamaXPC {
                        StatusBadge(presetProvider.displayName.uppercased(), tint: presetProvider == .ollama ? .orange : .teal)
                    }
                }

                if let description = preset.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let useCases = preset.useCases, !useCases.isEmpty {
                    Text(useCases.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if let modelCard = preset.modelCardURL {
                    Link("Model card and license", destination: modelCard)
                        .font(.caption2)
                        .help(modelCard.absoluteString)
                        .accessibilityIdentifier("models.license.\(preset.slug)")
                }
            }

            Spacer()

            Button {
                registerPreset(preset)
            } label: {
                if isRegistering {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "plus")
                }
            }
            .controlSize(.small)
            .accessibilityLabel("Add \(preset.slug)")
            .disabled(registeringPresetSlug != nil || notReady)
            .help("Register \(preset.slug) in the database; the first embedding model becomes the default")
            .accessibilityIdentifier("models.add.\(preset.slug)")
        }
        .padding(10)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    func registerPreset(_ preset: ModelPresetEntry) {
        registeringPresetSlug = preset.slug
        Task {
            await appState.registerModel(preset: preset)
            await appState.fetchRegisteredModels()
            await appState.fetchCorpusStats()
            registeringPresetSlug = nil
        }
    }

    // MARK: - Custom model

    var trimmedSlug: String {
        slug.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var customModelForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("A model models.json does not list. Ollama and LM Studio serve it from their own library; the built-in engine needs its GGUF file in the models folder under this slug.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    formLabel("Slug")
                    TextField("e.g. bge-m3", text: $slug)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("models.custom.slug")
                }
                GridRow {
                    formLabel("Provider")
                    Picker("Provider", selection: $provider) {
                        ForEach(ModelProvider.allCases) { prov in
                            Text(prov.displayName).tag(prov)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 200, alignment: .leading)
                    .accessibilityIdentifier("models.custom.provider")
                }
                GridRow {
                    formLabel("Dimensions")
                    TextField("e.g. 1024", text: $dims)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 120, alignment: .leading)
                        .accessibilityIdentifier("models.custom.dims")
                }
                GridRow {
                    formLabel("Model ref")
                    TextField("Provider-side name when it differs from the slug, e.g. BAAI/bge-m3", text: $modelRef)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Color.clear.frame(width: 0, height: 0)
                    Toggle("Use for search and embedding by default", isOn: $makeDefault)
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("models.custom.makeDefault")
                }
            }

            HStack(spacing: 8) {
                Button("Register") {
                    registerCustomModel()
                }
                .buttonStyle(.borderedProminent)
                .disabled(trimmedSlug.isEmpty || notReady)
                .accessibilityIdentifier("models.custom.register")

                if busy {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    func formLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    func registerCustomModel() {
        // Snapshot the form for the async operation.
        let slugValue = trimmedSlug
        let dimsText = dims.trimmingCharacters(in: .whitespacesAndNewlines)
        let refValue = modelRef.trimmingCharacters(in: .whitespacesAndNewlines)
        let providerValue = provider.cliValue
        let defaultValue = makeDefault
        run(triggersMaintenance: true) { grpc in
            var dimsValue: Int?
            if !dimsText.isEmpty {
                guard let parsed = Int(dimsText), parsed > 0 else {
                    throw GarageGRPCError.rpcFailed("Dimensions must be a positive whole number, not '\(dimsText)'.")
                }
                dimsValue = parsed
            }
            return try await grpc.registerModel(
                slug: slugValue,
                dims: dimsValue,
                modelRef: refValue.isEmpty ? nil : refValue,
                provider: providerValue,
                makeDefault: defaultValue
            ).message
        }
    }
}

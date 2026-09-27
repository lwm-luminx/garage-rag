import SwiftUI
import LlamaClient

extension ModelsView {
    // MARK: - Unified Model Item
    struct UnifiedModelItem: Identifiable, Hashable {
        var id: String { slug }
        let name: String
        let slug: String
        let provider: ModelProvider
        let modelRef: String
        let dims: Int?
        let storedDims: Int?
        let contextSize: Int?
        let isDefault: Bool
        let downloadModelId: String?
        let downloadFile: String?
        let sha256: String?
        let registeredModel: RegisteredModel?
        let presetEntry: ModelPresetEntry?

        static func == (lhs: UnifiedModelItem, rhs: UnifiedModelItem) -> Bool {
            lhs.slug == rhs.slug &&
            lhs.isDefault == rhs.isDefault &&
            lhs.dims == rhs.dims &&
            lhs.provider == rhs.provider
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(slug)
            hasher.combine(isDefault)
        }

        var effectiveDownloadURL: String? {
            if let downloadModelId = downloadModelId, let downloadFile = downloadFile,
               !downloadModelId.isEmpty, !downloadFile.isEmpty {
                return "https://huggingface.co/\(downloadModelId)/resolve/main/\(downloadFile)"
            }
            return nil
        }

        var effectiveFilename: String? {
            if let downloadFile = downloadFile, !downloadFile.isEmpty {
                return downloadFile
            }
            return nil
        }

        var effectiveSha256: String? {
            sha256 ?? presetEntry?.sha256
        }
    }

    var unifiedModels: [UnifiedModelItem] {
        var items: [UnifiedModelItem] = []

        // The list is built from the database's registered models only; presets that
        // are not registered yet are listed separately in `unregisteredPresetModels`.
        for reg in appState.registeredModels {
            let prov = ModelProvider.from(string: reg.provider)
            let preset = appState.presetModels.first { $0.slug == reg.slug || $0.modelId == reg.modelRef }
            items.append(
                UnifiedModelItem(
                    name: preset?.name ?? reg.slug,
                    slug: reg.slug,
                    provider: prov,
                    modelRef: reg.modelRef,
                    dims: reg.dims > 0 ? reg.dims : preset?.effectiveDims,
                    storedDims: reg.storedDims > 0 ? reg.storedDims : nil,
                    contextSize: preset?.contextSize ?? 8192,
                    isDefault: reg.isDefault,
                    downloadModelId: preset?.downloadModelId,
                    downloadFile: preset?.downloadFile,
                    sha256: preset?.sha256,
                    registeredModel: reg,
                    presetEntry: preset
                )
            )
        }

        return items.sorted {
            if $0.isDefault != $1.isDefault {
                return $0.isDefault && !$1.isDefault
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var filteredModels: [UnifiedModelItem] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty {
            return unifiedModels
        }
        return unifiedModels.filter {
            $0.name.lowercased().contains(trimmed) ||
            $0.slug.lowercased().contains(trimmed) ||
            $0.provider.displayName.lowercased().contains(trimmed) ||
            $0.provider.rawValue.lowercased().contains(trimmed) ||
            $0.modelRef.lowercased().contains(trimmed)
        }
    }

    /// Presets from `models.json` that aren't registered yet, with featured presets surfaced first.
    var unregisteredPresetModels: [ModelPresetEntry] {
        let registeredSlugs = Set(appState.registeredModels.map(\.slug))
        return appState.presetModels
            .filter { !registeredSlugs.contains($0.slug) }
            .sorted { lhs, rhs in
                if lhs.featured != rhs.featured {
                    return lhs.featured && !rhs.featured
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }
}

// MARK: - UnifiedModelItem from a preset
extension ModelsView.UnifiedModelItem {
    /// Wraps a `models.json` preset that has no database registration (e.g. a
    /// `fact_distil` entry) so the download / load helpers can treat it like a row.
    /// Declared in an extension to keep the struct's memberwise initializer.
    init(preset: ModelPresetEntry) {
        self.init(
            name: preset.name,
            slug: preset.slug,
            provider: ModelsView.ModelProvider.from(string: preset.provider),
            modelRef: preset.modelRef ?? preset.slug,
            dims: preset.effectiveDims > 0 ? preset.effectiveDims : nil,
            storedDims: nil,
            contextSize: preset.contextSize ?? 8192,
            isDefault: false,
            downloadModelId: preset.downloadModelId,
            downloadFile: preset.downloadFile,
            sha256: preset.sha256,
            registeredModel: nil,
            presetEntry: preset
        )
    }
}

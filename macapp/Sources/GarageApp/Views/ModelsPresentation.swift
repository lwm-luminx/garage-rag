import Foundation

// The Models page's figures and wording as plain values: how many embeddings the registered models
// still need, what the headline and the Llama XPC rows say, and which rows an Embed covers. Kept out
// of the view, which reads them from `AppState`, so they can be tested without a window.

enum ModelsPresentation {
    /// Embeddings the models named by `modelSlugs` need and how many are missing, counted over the
    /// models registered now rather than `stats.modelStats`, which lags a registration until the
    /// next stats fetch. A model the stats do not list yet has embedded nothing.
    static func embeddingsRequiredAndMissing(modelSlugs: [String], stats: CorpusStats) -> (required: Int, missing: Int) {
        let required = modelSlugs.count * stats.totalChunks
        let missing = modelSlugs.reduce(0) { sum, slug in
            let embedded = stats.modelStats.first { $0.slug == slug }?.embeddedCount ?? 0
            return sum + max(0, stats.totalChunks - embedded)
        }
        return (required, missing)
    }

    /// The line under the Text Embedding Models heading: "2 models · 9,120 of 10,000 embeddings
    /// done", or what is missing for that to be true.
    static func embeddingSummary(modelCount: Int, totalChunks: Int, required: Int, missing: Int) -> String {
        if modelCount == 0 {
            return "Text embedding models turn each chunk into a vector for semantic search. Each keeps its own vector table; search uses the default one."
        }
        let models = "\(modelCount) model\(modelCount == 1 ? "" : "s")"
        if totalChunks == 0 {
            return "\(models) · no chunks to embed until a source is ingested"
        }
        if missing == 0 {
            return "\(models) · every chunk embedded"
        }
        let done = max(0, required - missing)
        return "\(models) · \(done.formatted()) of \(required.formatted()) embeddings done"
    }

    /// Whether the running backfill, if any, embeds under `slug`. `target` is the model an Embed
    /// started on this page runs for, "*" for Embed All, or nil for a run started elsewhere (such
    /// as Update Everything), which covers every model.
    static func isEmbedding(slug: String, backfillRunning: Bool, target: String?) -> Bool {
        guard backfillRunning else { return false }
        guard let target else { return true }
        return target == "*" || target == slug
    }

    /// Where the Overall tab's Embedding card stands, in the order the card checks: a model at all,
    /// its file on disk, chunks to embed, then how far embedding has come.
    enum EmbeddingHeadlineKind: Equatable {
        case noModel
        case filesMissing(names: [String])
        case waitingForIngest
        case ready
        case embedding
        case toGo
    }

    static func embeddingHeadlineKind(
        modelCount: Int,
        missingFileNames: [String],
        totalChunks: Int,
        missing: Int,
        backfillRunning: Bool
    ) -> EmbeddingHeadlineKind {
        if modelCount == 0 { return .noModel }
        if !missingFileNames.isEmpty { return .filesMissing(names: missingFileNames) }
        if totalChunks == 0 { return .waitingForIngest }
        if missing == 0 { return .ready }
        if backfillRunning { return .embedding }
        return .toGo
    }

    /// The line under a model Llama XPC holds in memory: "Loaded", then what it is there for.
    /// A catalog `capabilities` entry as a badge: its label and what it means.
    struct CapabilityTag: Equatable, Identifiable {
        let label: String
        let help: String
        var id: String { label }
    }

    /// The badges for a preset's `capabilities`, in catalog order. An entry this build does not know
    /// is still shown, spelled out from its key.
    static func capabilityTags(_ capabilities: [String]?) -> [CapabilityTag] {
        (capabilities ?? []).map { key in
            switch key {
            case "text_to_image":
                CapabilityTag(label: "TEXT → IMAGE", help: "A search phrase finds pictures: the text and image towers share one space")
            case "image_to_image":
                CapabilityTag(label: "SIMILAR IMAGES", help: "Pictures embed near pictures that look alike")
            case "multilingual":
                CapabilityTag(label: "MULTILINGUAL", help: "Its text tower was trained on many languages, so queries need not be English")
            case "neural_engine":
                CapabilityTag(label: "NEURAL ENGINE", help: "Runs on the Apple Neural Engine through Core ML")
            case "document_pages":
                CapabilityTag(label: "DOCUMENT PAGES", help: "Embeds a page of a document as an image, text and layout together, with no OCR")
            default:
                CapabilityTag(label: key.replacingOccurrences(of: "_", with: " ").uppercased(), help: key)
            }
        }
    }

    /// The model the Inference list shows as chosen: `inference.model` when set; while it is empty,
    /// the distillation model when its preset is tagged for inference and calls tools (it answers
    /// chat then, and can use Garage's tools); otherwise none.
    static func selectedInferenceSlug(
        inferenceModel: String?,
        factsModel: String,
        presets: [ModelPresetEntry]
    ) -> String? {
        if let inferenceModel, !inferenceModel.isEmpty { return inferenceModel }
        guard let facts = presets.first(where: { $0.slug == factsModel }),
              facts.isForInference, facts.toolCalling else { return nil }
        return facts.slug
    }

    /// The Gemma 4 model to name as `inference.model` once it is on disk: only while nothing is
    /// chosen for inference and the distillation model (which answers until then) calls no tools.
    /// When the distillation model is itself Gemma 4, or any tool-calling inference model, chat
    /// already follows it and nothing is written. The catalog's preferred Gemma 4 wins, then the
    /// first in catalog order.
    static func gemma4ToAdoptForInference(
        inferenceModel: String?,
        factsModel: String,
        presets: [ModelPresetEntry],
        isDownloaded: (ModelPresetEntry) -> Bool
    ) -> ModelPresetEntry? {
        guard inferenceModel?.isEmpty ?? true,
              selectedInferenceSlug(inferenceModel: nil, factsModel: factsModel, presets: presets) == nil else { return nil }
        let candidates = presets.filter {
            $0.slug.hasPrefix("gemma-4") && $0.isForInference && $0.toolCalling && isDownloaded($0)
        }
        return candidates.first(where: \.preferred) ?? candidates.first
    }

    static func residentModelDetail(
        isEmbeddingModel: Bool,
        isDefaultEmbeddingModel: Bool,
        isFactsModel: Bool,
        answersUnnamedRequests: Bool
    ) -> String {
        var roles: [String] = []
        if isEmbeddingModel {
            roles.append(isDefaultEmbeddingModel ? "default embedding model" : "embedding model")
        }
        if isFactsModel {
            roles.append("facts model")
        }
        if answersUnnamedRequests {
            roles.append("answers requests that name no model")
        }
        return roles.isEmpty ? "Loaded" : "Loaded · \(roles.joined(separator: " · "))"
    }

    /// The Llama XPC provider row's line: "Running · 2 models loaded · 3 slots idle, 0 processing",
    /// from the service's own status line.
    static func llamaDetail(
        statusMessage: String,
        isConnected: Bool,
        loadedCount: Int,
        slotsIdle: Int?,
        slotsProcessing: Int?
    ) -> String {
        var parts: [String] = [statusMessage]
        if isConnected {
            parts.append(loadedCount == 0 ? "no model loaded" : "\(loadedCount) model\(loadedCount == 1 ? "" : "s") loaded")
            if let idle = slotsIdle, let processing = slotsProcessing {
                parts.append("\(idle) slot\(idle == 1 ? "" : "s") idle, \(processing) processing")
            }
        }
        return parts.joined(separator: " · ")
    }
}

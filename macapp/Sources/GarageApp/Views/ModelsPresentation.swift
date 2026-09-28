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

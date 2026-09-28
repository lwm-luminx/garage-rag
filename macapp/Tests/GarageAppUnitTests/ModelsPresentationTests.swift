import XCTest
@testable import GarageApp

final class ModelsPresentationTests: XCTestCase {

    private func stats(totalChunks: Int, embedded: [String: Int]) -> CorpusStats {
        CorpusStats(
            totalChunks: totalChunks,
            modelStats: embedded.keys.sorted().map { slug in
                CorpusStats.ModelEmbeddingStats(slug: slug, tableName: "emb_\(slug)", isDefault: false, embeddedCount: embedded[slug] ?? 0)
            }
        )
    }

    // MARK: - Embeddings required and missing

    func testRequiredAndMissingCountEveryRegisteredModel() {
        let figures = ModelsPresentation.embeddingsRequiredAndMissing(
            modelSlugs: ["bge-m3", "nomic"],
            stats: stats(totalChunks: 1000, embedded: ["bge-m3": 1000, "nomic": 400])
        )
        XCTAssertEqual(figures.required, 2000)
        XCTAssertEqual(figures.missing, 600)
    }

    /// A model registered since the last stats fetch has no row in the stats yet: all of its
    /// embeddings are still to do, so the headline cannot say Search ready.
    func testAModelTheStatsDoNotListYetIsWhollyUnembedded() {
        let figures = ModelsPresentation.embeddingsRequiredAndMissing(
            modelSlugs: ["bge-m3", "just-added"],
            stats: stats(totalChunks: 500, embedded: ["bge-m3": 500])
        )
        XCTAssertEqual(figures.required, 1000)
        XCTAssertEqual(figures.missing, 500)
    }

    /// A model dropped since the last stats fetch still has a row in the stats; it no longer counts.
    func testAModelNoLongerRegisteredIsNotCounted() {
        let figures = ModelsPresentation.embeddingsRequiredAndMissing(
            modelSlugs: ["bge-m3"],
            stats: stats(totalChunks: 500, embedded: ["bge-m3": 500, "dropped": 0])
        )
        XCTAssertEqual(figures.required, 500)
        XCTAssertEqual(figures.missing, 0)
    }

    func testMoreVectorsThanChunksNeverCountsBelowZero() {
        let figures = ModelsPresentation.embeddingsRequiredAndMissing(
            modelSlugs: ["bge-m3"],
            stats: stats(totalChunks: 100, embedded: ["bge-m3": 120])
        )
        XCTAssertEqual(figures.missing, 0)
    }

    // MARK: - Summary line

    func testSummaryWithoutModelsExplainsWhatTheyAreFor() {
        let summary = ModelsPresentation.embeddingSummary(modelCount: 0, totalChunks: 1000, required: 0, missing: 0)
        XCTAssertTrue(summary.hasPrefix("Text embedding models turn each chunk into a vector"), summary)
    }

    func testSummaryBeforeAnyIngest() {
        XCTAssertEqual(
            ModelsPresentation.embeddingSummary(modelCount: 1, totalChunks: 0, required: 0, missing: 0),
            "1 model · no chunks to embed until a source is ingested"
        )
    }

    func testSummaryWhenEverythingIsEmbedded() {
        XCTAssertEqual(
            ModelsPresentation.embeddingSummary(modelCount: 2, totalChunks: 500, required: 1000, missing: 0),
            "2 models · every chunk embedded"
        )
    }

    func testSummaryCountsEmbeddingsDone() {
        XCTAssertEqual(
            ModelsPresentation.embeddingSummary(modelCount: 2, totalChunks: 5000, required: 10000, missing: 880),
            "2 models · 9,120 of 10,000 embeddings done"
        )
    }

    // MARK: - Which rows say Embedding

    func testNothingIsEmbeddingWhileNoBackfillRuns() {
        XCTAssertFalse(ModelsPresentation.isEmbedding(slug: "bge-m3", backfillRunning: false, target: nil))
        XCTAssertFalse(ModelsPresentation.isEmbedding(slug: "bge-m3", backfillRunning: false, target: "bge-m3"))
        XCTAssertFalse(ModelsPresentation.isEmbedding(slug: "bge-m3", backfillRunning: false, target: "*"))
    }

    /// Embed on one row used to set every incomplete row to Embedding.
    func testAnEmbedForOneModelCoversOnlyThatModel() {
        XCTAssertTrue(ModelsPresentation.isEmbedding(slug: "bge-m3", backfillRunning: true, target: "bge-m3"))
        XCTAssertFalse(ModelsPresentation.isEmbedding(slug: "nomic", backfillRunning: true, target: "bge-m3"))
    }

    func testEmbedAllCoversEveryModel() {
        XCTAssertTrue(ModelsPresentation.isEmbedding(slug: "bge-m3", backfillRunning: true, target: "*"))
        XCTAssertTrue(ModelsPresentation.isEmbedding(slug: "nomic", backfillRunning: true, target: "*"))
    }

    /// A run the page did not start (Update Everything, automatic updates) embeds with every model.
    func testARunStartedElsewhereCoversEveryModel() {
        XCTAssertTrue(ModelsPresentation.isEmbedding(slug: "nomic", backfillRunning: true, target: nil))
    }

    // MARK: - Overall headline

    func testHeadlineWithoutAModel() {
        XCTAssertEqual(
            ModelsPresentation.embeddingHeadlineKind(modelCount: 0, missingFileNames: [], totalChunks: 100, missing: 0, backfillRunning: false),
            .noModel
        )
    }

    func testAMissingModelFileComesBeforeTheCorpus() {
        XCTAssertEqual(
            ModelsPresentation.embeddingHeadlineKind(modelCount: 2, missingFileNames: ["BGE-M3"], totalChunks: 0, missing: 0, backfillRunning: true),
            .filesMissing(names: ["BGE-M3"])
        )
    }

    func testHeadlineBeforeAnyIngest() {
        XCTAssertEqual(
            ModelsPresentation.embeddingHeadlineKind(modelCount: 1, missingFileNames: [], totalChunks: 0, missing: 0, backfillRunning: false),
            .waitingForIngest
        )
    }

    func testHeadlineWhenEveryChunkIsEmbedded() {
        XCTAssertEqual(
            ModelsPresentation.embeddingHeadlineKind(modelCount: 1, missingFileNames: [], totalChunks: 100, missing: 0, backfillRunning: true),
            .ready
        )
    }

    func testHeadlineWhileEmbeddingAndWithWorkLeft() {
        XCTAssertEqual(
            ModelsPresentation.embeddingHeadlineKind(modelCount: 1, missingFileNames: [], totalChunks: 100, missing: 40, backfillRunning: true),
            .embedding
        )
        XCTAssertEqual(
            ModelsPresentation.embeddingHeadlineKind(modelCount: 1, missingFileNames: [], totalChunks: 100, missing: 40, backfillRunning: false),
            .toGo
        )
    }

    // MARK: - Llama XPC rows

    func testAResidentModelWithNoRoleSaysLoaded() {
        XCTAssertEqual(
            ModelsPresentation.residentModelDetail(isEmbeddingModel: false, isDefaultEmbeddingModel: false, isFactsModel: false, answersUnnamedRequests: false),
            "Loaded"
        )
    }

    func testAResidentModelNamesEachOfItsRoles() {
        XCTAssertEqual(
            ModelsPresentation.residentModelDetail(isEmbeddingModel: true, isDefaultEmbeddingModel: true, isFactsModel: false, answersUnnamedRequests: true),
            "Loaded · default embedding model · answers requests that name no model"
        )
        XCTAssertEqual(
            ModelsPresentation.residentModelDetail(isEmbeddingModel: true, isDefaultEmbeddingModel: false, isFactsModel: false, answersUnnamedRequests: false),
            "Loaded · embedding model"
        )
        XCTAssertEqual(
            ModelsPresentation.residentModelDetail(isEmbeddingModel: false, isDefaultEmbeddingModel: false, isFactsModel: true, answersUnnamedRequests: false),
            "Loaded · facts model"
        )
    }

    func testLlamaDetailWhileDisconnectedIsTheStatusAlone() {
        XCTAssertEqual(
            ModelsPresentation.llamaDetail(statusMessage: "Not connected", isConnected: false, loadedCount: 2, slotsIdle: 1, slotsProcessing: 0),
            "Not connected"
        )
    }

    func testLlamaDetailCountsLoadedModelsAndSlots() {
        XCTAssertEqual(
            ModelsPresentation.llamaDetail(statusMessage: "Running", isConnected: true, loadedCount: 0, slotsIdle: nil, slotsProcessing: nil),
            "Running · no model loaded"
        )
        XCTAssertEqual(
            ModelsPresentation.llamaDetail(statusMessage: "Running", isConnected: true, loadedCount: 1, slotsIdle: 1, slotsProcessing: 0),
            "Running · 1 model loaded · 1 slot idle, 0 processing"
        )
        XCTAssertEqual(
            ModelsPresentation.llamaDetail(statusMessage: "Running", isConnected: true, loadedCount: 2, slotsIdle: 3, slotsProcessing: 1),
            "Running · 2 models loaded · 3 slots idle, 1 processing"
        )
    }

    // MARK: - Tabs

    func testTheTabsAreOverallEmbeddingDistillationInferenceInOrder() {
        XCTAssertEqual(ModelsView.Page.allCases.map(\.rawValue), ["Overall", "Embedding", "Distillation", "Inference"])
    }

    func testProviderFromTheConfigString() {
        XCTAssertEqual(ModelsView.ModelProvider.from(string: "llama_xpc"), .llamaXPC)
        XCTAssertEqual(ModelsView.ModelProvider.from(string: " Ollama "), .ollama)
        XCTAssertEqual(ModelsView.ModelProvider.from(string: "lmstudio"), .lmStudio)
        XCTAssertEqual(ModelsView.ModelProvider.from(string: "LM Studio"), .lmStudio)
        XCTAssertEqual(ModelsView.ModelProvider.from(string: nil), .llamaXPC)
        XCTAssertEqual(ModelsView.ModelProvider.lmStudio.cliValue, "lmstudio")
        XCTAssertEqual(ModelsView.ModelProvider.llamaXPC.cliValue, "llama_xpc")
    }
}

import XCTest
import CryptoKit
import ModelDownloadClient
import PythonXPCService
@testable import GarageApp

final class GarageConfigLoaderTests: XCTestCase {

    func testRegisteredSourceProperties() {
        let source = RegisteredSource(
            slug: "dropbox",
            kind: "filesystem",
            root: "~/Dropbox",
            corpusClass: "document",
            trust: "authored",
            enabled: true,
            includeCode: false,
            origin: .config,
            documentCount: 42
        )

        XCTAssertEqual(source.id, "dropbox")
        XCTAssertEqual(source.slug, "dropbox")
        XCTAssertEqual(source.kind, "filesystem")
        XCTAssertEqual(source.root, "~/Dropbox")
        XCTAssertEqual(source.corpusClass, "document")
        XCTAssertEqual(source.trust, "authored")
        XCTAssertTrue(source.enabled)
        XCTAssertFalse(source.includeCode)
        XCTAssertEqual(source.origin, .config)
        XCTAssertEqual(source.documentCount, 42)
        XCTAssertFalse(source.expandedRootPath.hasPrefix("~"))
        XCTAssertEqual(source.expandedRootURL.path, GarageAppGroup.realHomeDirectory + "/Dropbox")
    }

    func testLoadSourcesFromConfigJSON() throws {
        // allow_cloud_enrichment is a retired key: a config that still carries it must load.
        let json = """
        {
            "$schema": "https://garagerag.app/.data/garage.schema.json",
            "database": {
                "url": "postgresql+psycopg:///rag"
            },
            "sources": [
                {
                    "slug": "dropbox",
                    "root": "~/Dropbox",
                    "kind": "filesystem",
                    "class": "document",
                    "trust": "authored",
                    "include_code": false,
                    "allow_cloud_enrichment": true,
                    "enabled": true
                },
                {
                    "slug": "developer",
                    "root": "~/Developer",
                    "kind": "git",
                    "class": "code",
                    "trust": "authored",
                    "include_code": true,
                    "allow_cloud_enrichment": false,
                    "enabled": true
                }
            ]
        }
        """

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_garage_\(UUID().uuidString).json")
        try json.data(using: .utf8)!.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let sources = GarageConfigLoader.loadSourcesFromConfig(fileURL: tempURL)
        XCTAssertEqual(sources.count, 2)

        let dropbox = sources[0]
        XCTAssertEqual(dropbox.slug, "dropbox")
        XCTAssertEqual(dropbox.root, "~/Dropbox")
        XCTAssertEqual(dropbox.kind, "filesystem")
        XCTAssertEqual(dropbox.corpusClass, "document")
        XCTAssertEqual(dropbox.trust, "authored")
        XCTAssertFalse(dropbox.includeCode)
        XCTAssertEqual(dropbox.origin, .config)

        let dev = sources[1]
        XCTAssertEqual(dev.slug, "developer")
        XCTAssertEqual(dev.root, "~/Developer")
        XCTAssertEqual(dev.kind, "git")
        XCTAssertEqual(dev.corpusClass, "code")
        XCTAssertEqual(dev.trust, "authored")
        XCTAssertTrue(dev.includeCode)
        XCTAssertEqual(dev.origin, .config)
    }

    func testLoadSourcesFromNonExistentFile() {
        let fakeURL = URL(fileURLWithPath: "/tmp/non_existent_file_\(UUID().uuidString).json")
        let sources = GarageConfigLoader.loadSourcesFromConfig(fileURL: fakeURL)
        XCTAssertTrue(sources.isEmpty)
    }

    func testLoadSourcesFromMalformedJSON() throws {
        let malformed = "{ this is not valid json }"
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("malformed_\(UUID().uuidString).json")
        try malformed.data(using: .utf8)!.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let sources = GarageConfigLoader.loadSourcesFromConfig(fileURL: tempURL)
        XCTAssertTrue(sources.isEmpty)
    }

    func testModelPresetEntryProperties() {
        let preset = ModelPresetEntry(
            name: "BGE-M3 (Embeddings)",
            modelId: "BAAI/bge-m3",
            slug: "bge-m3",
            modelRef: "bge-m3",
            provider: "llama_xpc",
            nativeDims: 1024,
            defaultDims: 1024,
            contextSize: 8192,
            downloadModelId: "gpustack/bge-m3-GGUF",
            downloadFile: "bge-m3-Q8_0.gguf",
            sha256: "950f4a8e5e19477a6d3c26d2f162233c20002c601f75e4b002e3239997821167"
        )

        XCTAssertEqual(preset.id, "bge-m3")
        XCTAssertEqual(preset.slug, "bge-m3")
        XCTAssertEqual(preset.effectiveDims, 1024)
        XCTAssertTrue(preset.isEmbeddingModel)
        XCTAssertEqual(preset.downloadFile, "bge-m3-Q8_0.gguf")
        XCTAssertEqual(preset.sha256, "950f4a8e5e19477a6d3c26d2f162233c20002c601f75e4b002e3239997821167")
        XCTAssertEqual(preset.downloadURLString, "https://huggingface.co/gpustack/bge-m3-GGUF/resolve/main/bge-m3-Q8_0.gguf")
    }

    func testModelCardLinkComesFromTheCatalogOrTheRepositoryId() throws {
        let json = Data("""
        {"name": "Gemma", "slug": "embeddinggemma", "model_id": "google/embeddinggemma-2b",
         "model_card_url": "https://huggingface.co/google/embeddinggemma-300m"}
        """.utf8)
        let named = try JSONDecoder().decode(ModelPresetEntry.self, from: json)
        XCTAssertEqual(named.modelCardURL?.absoluteString, "https://huggingface.co/google/embeddinggemma-300m")

        let derived = ModelPresetEntry(name: "BGE-M3", modelId: "BAAI/bge-m3", slug: "bge-m3")
        XCTAssertEqual(derived.modelCardURL?.absoluteString, "https://huggingface.co/BAAI/bge-m3")

        XCTAssertNil(ModelPresetEntry(name: "Local", modelId: "nomic-embed-text", slug: "local").modelCardURL)
        XCTAssertNil(ModelPresetEntry(name: "Plain", modelCardURLString: "http://example.com", slug: "plain").modelCardURL)
    }

    func testLoadModelPresetsFromJSONWithSha256() throws {
        let json = """
        [
            {
                "name": "BGE-M3 (Embeddings)",
                "model_id": "BAAI/bge-m3",
                "slug": "bge-m3",
                "model_ref": "bge-m3",
                "provider": "llama_xpc",
                "native_dims": 1024,
                "default_dims": 1024,
                "context_size": 8192,
                "download_model_id": "gpustack/bge-m3-GGUF",
                "download_file": "bge-m3-Q8_0.gguf",
                "sha256": "950f4a8e5e19477a6d3c26d2f162233c20002c601f75e4b002e3239997821167"
            },
            {
                "name": "Nomic Embed Text",
                "model_id": "nomic-ai/nomic-embed-text-v1.5",
                "slug": "nomic-embed-text",
                "model_ref": "nomic-embed-text",
                "provider": "llama_xpc",
                "native_dims": 768,
                "default_dims": 768,
                "context_size": 8192,
                "download_model_id": "nomic-ai/nomic-embed-text-v1.5-GGUF",
                "download_file": "nomic-embed-text-v1.5.Q8_0.gguf",
                "sha256": "3e24342164b3d94991ba9692fdc0dd08e3fd7362e0aacc396a9a5c54a544c3b7"
            }
        ]
        """

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_models_\(UUID().uuidString).json")
        try json.data(using: .utf8)!.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let presets = GarageConfigLoader.loadModelPresets(fileURL: tempURL)
        XCTAssertEqual(presets.count, 2)
        XCTAssertEqual(presets[0].slug, "bge-m3")
        XCTAssertEqual(presets[0].sha256, "950f4a8e5e19477a6d3c26d2f162233c20002c601f75e4b002e3239997821167")
        XCTAssertEqual(presets[1].slug, "nomic-embed-text")
        XCTAssertEqual(presets[1].sha256, "3e24342164b3d94991ba9692fdc0dd08e3fd7362e0aacc396a9a5c54a544c3b7")
    }

    func testModelDownloaderEngineComputeAndVerifySHA256() throws {
        let engine = ModelDownloaderEngine()
        let tempFile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_verify_\(UUID().uuidString).bin")
        let testData = "Hello Garage Model Verification".data(using: .utf8)!
        try testData.write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let expectedHash = "4fb397ad3a219e785b1e9c197787c2a4c96d4a998478467718a253c875be8018"
        let computed = try engine.computeSHA256(of: tempFile)
        XCTAssertEqual(computed.lowercased(), expectedHash)

        // Matching expected hash
        let validResult = try engine.verifyModelFile(filePath: tempFile.path, expectedSha256: expectedHash)
        XCTAssertTrue(validResult.isValid)
        XCTAssertEqual(validResult.computedSha256, expectedHash)

        // Mismatched expected hash
        let invalidResult = try engine.verifyModelFile(filePath: tempFile.path, expectedSha256: "0000000000000000000000000000000000000000000000000000000000000000")
        XCTAssertFalse(invalidResult.isValid)
        XCTAssertEqual(invalidResult.computedSha256, expectedHash)

        // Nil expected hash returns computed hash
        let noExpectedResult = try engine.verifyModelFile(filePath: tempFile.path, expectedSha256: nil)
        XCTAssertTrue(noExpectedResult.isValid)
        XCTAssertEqual(noExpectedResult.computedSha256, expectedHash)
    }

    func testLoadModelPresetsFromJSON() throws {
        let json = """
        [
            {
                "name": "BGE-M3 (Embeddings)",
                "model_id": "BAAI/bge-m3",
                "slug": "bge-m3",
                "model_ref": "bge-m3",
                "provider": "llama_xpc",
                "native_dims": 1024,
                "default_dims": 1024,
                "context_size": 8192,
                "download_model_id": "CompendiumLabs/bge-m3-GGUF",
                "download_file": "bge-m3-Q8_0.gguf"
            },
            {
                "name": "Nomic Embed Text",
                "model_id": "nomic-ai/nomic-embed-text-v1.5",
                "slug": "nomic-embed-text",
                "model_ref": "nomic-embed-text",
                "provider": "llama_xpc",
                "native_dims": 768,
                "default_dims": 768,
                "context_size": 8192,
                "download_model_id": "nomic-ai/nomic-embed-text-v1.5-GGUF",
                "download_file": "nomic-embed-text-v1.5.Q8_0.gguf"
            }
        ]
        """

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_models_\(UUID().uuidString).json")
        try json.data(using: .utf8)!.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let presets = GarageConfigLoader.loadModelPresets(fileURL: tempURL)
        XCTAssertEqual(presets.count, 2)
        XCTAssertEqual(presets[0].slug, "bge-m3")
        XCTAssertEqual(presets[0].effectiveDims, 1024)
        XCTAssertEqual(presets[1].slug, "nomic-embed-text")
        XCTAssertEqual(presets[1].effectiveDims, 768)
    }

    func testLoadModelPresetsFromJSONWithFeaturedMetadata() throws {
        let json = """
        [
            {
                "name": "BGE-M3 (Embeddings)",
                "model_id": "BAAI/bge-m3",
                "slug": "bge-m3",
                "model_ref": "bge-m3",
                "provider": "llama_xpc",
                "native_dims": 1024,
                "default_dims": 1024,
                "context_size": 8192,
                "description": "Strong general-purpose embedding model.",
                "use_cases": ["Semantic search", "Hybrid retrieval"],
                "featured": true
            },
            {
                "name": "Nomic Embed Text",
                "model_id": "nomic-ai/nomic-embed-text-v1.5",
                "slug": "nomic-embed-text",
                "model_ref": "nomic-embed-text",
                "provider": "llama_xpc",
                "native_dims": 768,
                "default_dims": 768,
                "context_size": 8192
            }
        ]
        """

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_models_featured_\(UUID().uuidString).json")
        try json.data(using: .utf8)!.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let presets = GarageConfigLoader.loadModelPresets(fileURL: tempURL)
        XCTAssertEqual(presets.count, 2)

        let bge = presets[0]
        XCTAssertTrue(bge.featured)
        XCTAssertEqual(bge.description, "Strong general-purpose embedding model.")
        XCTAssertEqual(bge.useCases, ["Semantic search", "Hybrid retrieval"])

        // Entries without the new fields decode with safe defaults.
        let nomic = presets[1]
        XCTAssertFalse(nomic.featured)
        XCTAssertNil(nomic.description)
        XCTAssertNil(nomic.useCases)
    }

    func testLoadModelPresetsFromGroupedManifest() throws {
        let json = """
        {
            "text_embedding": [
                {
                    "name": "BGE-M3 (Embeddings)",
                    "model_id": "BAAI/bge-m3",
                    "slug": "bge-m3",
                    "model_ref": "bge-m3",
                    "provider": "llama_xpc",
                    "native_dims": 1024,
                    "default_dims": 1024,
                    "context_size": 8192
                }
            ],
            "fact_distil": [
                {
                    "name": "Gemma 2 2B Instruct",
                    "model_id": "google/gemma-2-2b-it",
                    "slug": "gemma2-2b",
                    "model_ref": "gemma2-2b",
                    "provider": "llama_xpc",
                    "context_size": 8192,
                    "featured": true
                }
            ]
        }
        """

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_models_grouped_\(UUID().uuidString).json")
        try json.data(using: .utf8)!.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let embeddingPresets = GarageConfigLoader.loadModelPresets(fileURL: tempURL)
        XCTAssertEqual(embeddingPresets.count, 1)
        XCTAssertEqual(embeddingPresets[0].slug, "bge-m3")

        let factDistilPresets = GarageConfigLoader.loadFactDistilPresets(fileURL: tempURL)
        XCTAssertEqual(factDistilPresets.count, 1)
        XCTAssertEqual(factDistilPresets[0].slug, "gemma2-2b")
        XCTAssertTrue(factDistilPresets[0].featured)

        // The embedding list must never leak fact_distil entries or vice versa.
        XCTAssertFalse(embeddingPresets.contains { $0.slug == "gemma2-2b" })
        XCTAssertFalse(factDistilPresets.contains { $0.slug == "bge-m3" })
    }

    func testInferenceModelsAreTaggedForDistillation() throws {
        let json = """
        {
            "text_embedding": [{"name": "BGE-M3", "slug": "bge-m3", "native_dims": 1024}],
            "inference_models": [
                {"name": "Both", "slug": "both", "tags": ["inference", "distillation"]},
                {"name": "Chat", "slug": "chat", "tags": ["inference"]}
            ]
        }
        """
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_models_tags_\(UUID().uuidString).json")
        try json.data(using: .utf8)!.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        XCTAssertEqual(GarageConfigLoader.loadInferencePresets(fileURL: tempURL).map(\.slug), ["both", "chat"])
        XCTAssertEqual(GarageConfigLoader.loadFactDistilPresets(fileURL: tempURL).map(\.slug), ["both"])
        // An untagged entry (the older fact_distil list) counts as a distillation model.
        XCTAssertTrue(ModelPresetEntry(name: "Legacy", slug: "legacy").isForDistillation)
    }

    func testPresetsCarryOriginAndToolCalling() throws {
        let json = """
        {
            "text_embedding": [
                {"name": "BGE-M3", "slug": "bge-m3", "native_dims": 1024, "maker": "BAAI", "country_of_origin": "CN"}
            ],
            "inference_models": [
                {"name": "Granite", "slug": "granite-4.1-8b", "tool_calling": true, "maker": "IBM", "country_of_origin": "US"},
                {"name": "Mistral", "slug": "mistral-small", "maker": "Mistral AI", "country_of_origin": "fr"},
                {"name": "Legacy", "slug": "legacy"}
            ]
        }
        """
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_models_origin_\(UUID().uuidString).json")
        try json.data(using: .utf8)!.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        XCTAssertEqual(GarageConfigLoader.loadModelPresets(fileURL: tempURL).first?.originRegion, "CN")
        let facts = Dictionary(uniqueKeysWithValues: GarageConfigLoader.loadInferencePresets(fileURL: tempURL).map { ($0.slug, $0) })
        XCTAssertEqual(facts["granite-4.1-8b"]?.originRegion, "US")
        XCTAssertEqual(facts["granite-4.1-8b"]?.originSummary, "IBM, US")
        XCTAssertTrue(facts["granite-4.1-8b"]?.toolCalling ?? false)
        // An EU member state is grouped as EU, whatever the case of its code.
        XCTAssertEqual(facts["mistral-small"]?.originRegion, "EU")
        XCTAssertFalse(facts["mistral-small"]?.toolCalling ?? true)
        // An entry from before the fields existed still decodes, with neither badge.
        XCTAssertNil(facts["legacy"]?.maker)
        XCTAssertNil(facts["legacy"]?.originRegion)
        XCTAssertFalse(facts["legacy"]?.toolCalling ?? true)
        XCTAssertEqual(ModelOriginRegion.region(for: "GB"), "GB")
        // A stated origin zone wins over the one derived from the country.
        XCTAssertEqual(ModelPresetEntry(name: "M", countryOfOrigin: "GB", originZone: "uk", slug: "m").originRegion, "UK")
    }

    func testLoadFactDistilPresetsFromLegacyFlatArrayIsEmpty() throws {
        // A pre-grouping models.json (flat array) has no fact_distil section at all, and there is
        // no built-in list to fall back on: models.json is the one catalog.
        let json = """
        [
            {
                "name": "BGE-M3 (Embeddings)",
                "model_id": "BAAI/bge-m3",
                "slug": "bge-m3",
                "model_ref": "bge-m3",
                "provider": "llama_xpc",
                "native_dims": 1024,
                "default_dims": 1024,
                "context_size": 8192
            }
        ]
        """

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_models_legacy_\(UUID().uuidString).json")
        try json.data(using: .utf8)!.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let embeddingPresets = GarageConfigLoader.loadModelPresets(fileURL: tempURL)
        XCTAssertEqual(embeddingPresets.count, 1)
        XCTAssertEqual(embeddingPresets[0].slug, "bge-m3")

        let factDistilPresets = GarageConfigLoader.loadFactDistilPresets(fileURL: tempURL)
        XCTAssertTrue(factDistilPresets.isEmpty)
    }

    func testLoadFactsSettingsDefaultsWhenSectionAbsent() throws {
        let json = """
        {
            "database": { "url": "postgresql+psycopg:///rag" },
            "sources": []
        }
        """

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_facts_absent_\(UUID().uuidString).json")
        try json.data(using: .utf8)!.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let facts = GarageConfigLoader.loadFactsSettings(fileURL: tempURL)
        XCTAssertEqual(facts.model, GarageConfigLoader.defaultFactsModel)
        XCTAssertEqual(facts.provider, GarageConfigLoader.defaultFactsProvider)
        XCTAssertEqual(facts.model, "gemma2-2b")
        XCTAssertEqual(facts.provider, "llama_xpc")

        // A missing file also yields the defaults.
        let fakeURL = URL(fileURLWithPath: "/tmp/non_existent_facts_\(UUID().uuidString).json")
        let missing = GarageConfigLoader.loadFactsSettings(fileURL: fakeURL)
        XCTAssertEqual(missing.model, "gemma2-2b")
        XCTAssertEqual(missing.provider, "llama_xpc")
    }

    func testLoadFactsSettingsFromConfigJSON() throws {
        let json = """
        {
            "database": { "url": "postgresql+psycopg:///rag" },
            "facts": {
                "model": "llama-3.2-3b-instruct",
                "provider": "ollama"
            }
        }
        """

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_facts_present_\(UUID().uuidString).json")
        try json.data(using: .utf8)!.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let facts = GarageConfigLoader.loadFactsSettings(fileURL: tempURL)
        XCTAssertEqual(facts.model, "llama-3.2-3b-instruct")
        XCTAssertEqual(facts.provider, "ollama")
    }

    func testLoadFactsSettingsPartialSectionFillsDefaults() throws {
        let json = """
        {
            "facts": { "model": "qwen-2.5-coder-7b" }
        }
        """

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_facts_partial_\(UUID().uuidString).json")
        try json.data(using: .utf8)!.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let facts = GarageConfigLoader.loadFactsSettings(fileURL: tempURL)
        XCTAssertEqual(facts.model, "qwen-2.5-coder-7b")
        XCTAssertEqual(facts.provider, "llama_xpc")
    }

    func testInferenceSettingsFollowDistillationUntilAModelIsNamed() throws {
        func load(_ json: String) throws -> (model: String?, provider: String?) {
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_inference_\(UUID().uuidString).json")
            try json.data(using: .utf8)!.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            return GarageConfigLoader.loadInferenceSettings(fileURL: url)
        }

        // No section, an empty model, or a provider alone: chat follows the distillation model.
        XCTAssertNil(try load(#"{"facts": {"model": "granite-4.1-3b"}}"#).model)
        XCTAssertNil(try load(#"{"inference": {"model": "  ", "provider": "ollama"}}"#).model)
        XCTAssertNil(try load(#"{"inference": {"provider": "ollama"}}"#).provider)

        let named = try load(#"{"inference": {"model": "qwen3-4b-instruct-2507", "provider": "lmstudio"}}"#)
        XCTAssertEqual(named.model, "qwen3-4b-instruct-2507")
        XCTAssertEqual(named.provider, "lmstudio")
        XCTAssertNil(try load(#"{"inference": {"model": "gpt-oss-20b"}}"#).provider)
    }

    func testWithoutAManifestThereAreNoPresets() {
        // No hand-written list stands in for models.json: when none of the candidate files exists,
        // the loader offers nothing rather than a copy that could disagree with the catalog.
        let fakeURL = URL(fileURLWithPath: "/tmp/non_existent_models_\(UUID().uuidString).json")
        let manifest = GarageConfigLoader.loadModelManifest(candidates: [fakeURL])
        XCTAssertNil(manifest.textEmbedding)
        XCTAssertNil(manifest.inference)
    }

    func testTheBundledCatalogIsTheFallback() {
        // The app's fallback is the models.json in its bundle (Paths.modelsJSON), read right after
        // the caller's file and before any garage.json.
        let explicit = URL(fileURLWithPath: "/tmp/explicit_models.json")
        let candidates = GarageConfigLoader.modelManifestCandidates(fileURL: explicit)
        XCTAssertEqual(candidates.first, explicit)
        XCTAssertEqual(candidates.dropFirst().first, Paths.modelsJSON)
        XCTAssertEqual(Array(candidates.dropFirst(2)), GarageConfigLoader.candidateConfigFiles)
    }

    func testTheCommittedCatalogCarriesThePresetsTheAppOnceHardCoded() throws {
        // The models the Swift fallback used to list by hand are in data/models/models.json, so
        // dropping the list lost none of them.
        let presets = GarageConfigLoader.loadModelPresets(fileURL: try committedCatalogURL())
        XCTAssertTrue(presets.contains { $0.slug == "bge-m3" })
        XCTAssertTrue(presets.contains { $0.slug == "nomic-embed-text" })
        XCTAssertTrue(presets.contains { $0.slug == "mxbai-embed-xsmall" })
        if let mxbai = presets.first(where: { $0.slug == "mxbai-embed-xsmall" }) {
            XCTAssertEqual(mxbai.effectiveDims, 384)
            XCTAssertEqual(mxbai.sha256, "21f9f06af9e4e895fcdcbf6c0d57ca1996fe22da54ecb6cc5f7733d785412d44")
            XCTAssertTrue(mxbai.featured)
        }
        let featuredSlugs = Set(presets.filter { $0.featured }.map(\.slug))
        XCTAssertEqual(featuredSlugs, ["bge-m3", "nomic-embed-text", "mxbai-embed-xsmall"])

        let factDistil = GarageConfigLoader.loadFactDistilPresets(fileURL: try committedCatalogURL())
        XCTAssertTrue(factDistil.contains { $0.slug == "gemma2-2b" })
        // gpt-oss is an inference model only: its reasoning text would land in the facts.
        let inference = GarageConfigLoader.loadInferencePresets(fileURL: try committedCatalogURL())
        XCTAssertTrue(inference.contains { $0.slug == "gpt-oss-20b" })
        XCTAssertFalse(factDistil.contains { $0.slug == "gpt-oss-20b" })
        // Chat models are no longer offered as embedding presets.
        XCTAssertFalse(presets.contains { $0.slug == "mistral-7b-instruct-v0.3" })
    }

    /// data/models/models.json, from the test bundle's resources or Bazel's runfiles.
    private func committedCatalogURL() throws -> URL {
        let candidates = [
            Bundle(for: Self.self).url(forResource: "models", withExtension: "json"),
            ProcessInfo.processInfo.environment["TEST_SRCDIR"].map {
                URL(fileURLWithPath: $0).appendingPathComponent("_main/data/models/models.json")
            },
        ].compactMap { $0 }
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw XCTSkip("data/models/models.json is not in this test's runfiles")
        }
        return url
    }

    func testEmbeddingVectorStatsCalculation() {
        let sampleVector: [Float] = [0.1, -0.2, 0.3, 0.4, -0.5]
        guard let stats = EmbeddingVectorStats(vector: sampleVector) else {
            XCTFail("Stats should not be nil for non-empty vector")
            return
        }

        XCTAssertEqual(stats.count, 5)
        XCTAssertEqual(stats.min, -0.5, accuracy: 0.0001)
        XCTAssertEqual(stats.max, 0.4, accuracy: 0.0001)
        XCTAssertEqual(stats.mean, 0.02, accuracy: 0.0001)
        XCTAssertGreaterThan(stats.l2Norm, 0)
    }
}

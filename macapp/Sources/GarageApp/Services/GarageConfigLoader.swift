import Foundation
import PythonXPCService

/// Represents a source registered in the configuration file or the Postgres database.
public struct RegisteredSource: Identifiable, Hashable, Sendable, Codable {
    public var id: String { slug }
    public let slug: String
    public let kind: String
    public let root: String
    public let corpusClass: String
    public let trust: String
    public let enabled: Bool
    public let includeCode: Bool
    public let origin: SourceOrigin
    public var documentCount: Int
    public var expectedElements: Int

    public enum SourceOrigin: String, Sendable, Codable {
        case config = "Config File"
        case database = "Database"
        case both = "Config & Database"
    }

    public init(
        slug: String,
        kind: String = "filesystem",
        root: String,
        corpusClass: String = "document",
        trust: String = "authored",
        enabled: Bool = true,
        includeCode: Bool = false,
        origin: SourceOrigin = .config,
        documentCount: Int = 0,
        expectedElements: Int = 0
    ) {
        self.slug = slug
        self.kind = kind
        self.root = root
        self.corpusClass = corpusClass
        self.trust = trust
        self.enabled = enabled
        self.includeCode = includeCode
        self.origin = origin
        self.documentCount = documentCount
        self.expectedElements = expectedElements
    }

    /// Expanded filesystem path, expanding '~' if present.
    public var expandedRootPath: String {
        GarageAppGroup.expandingTilde(in: root)
    }

    /// Expanded URL pointing to the source directory or file.
    public var expandedRootURL: URL {
        URL(fileURLWithPath: expandedRootPath)
    }
}

/// One file of a model that ships as several (a Core ML package's files and a tokenizer), with the
/// path under the model's download repository, which is also its path under `models/<slug>/`.
public struct ModelDownloadFile: Hashable, Sendable, Codable {
    public let path: String
    public let sha256: String?

    public init(path: String, sha256: String? = nil) {
        self.path = path
        self.sha256 = sha256
    }
}

/// Represents a model preset loaded from `models.json` (the fetched copy or the bundle's) or a configuration file.
public struct ModelPresetEntry: Identifiable, Hashable, Sendable, Codable {
    public var id: String { slug }
    public let name: String
    public let modelId: String?
    /// The model's page, where its license and model card can be read. The catalog names it;
    /// without that, a Hugging Face repository id in `modelId` points at its page there.
    public let modelCardURLString: String?
    /// Who made the model (`maker`, e.g. "IBM").
    public let maker: String?
    /// Where its maker is based, as an ISO 3166-1 alpha-2 code (`country_of_origin`, e.g. "US").
    public let countryOfOrigin: String?
    /// The zone its maker is based in, which the model is grouped under (`origin_zone`: US, EU, CN, UK,
    /// CH, OTHER). It says where the model comes from, not that it complies with any rules.
    public let originZone: String?
    public let slug: String
    public let modelRef: String?
    public let provider: String?
    public let nativeDims: Int?
    public let defaultDims: Int?
    public let contextSize: Int?
    /// The model was trained to call tools, so it can drive Garage's MCP tools.
    public let toolCalling: Bool
    /// What an `inference_models` entry is good for: "inference" (chat, rag_ask), "distillation"
    /// (gleaning facts), or both. Nil for an embedding model or a legacy `fact_distil` entry.
    public let tags: [String]?
    public let downloadModelId: String?
    public let downloadFile: String?
    public let sha256: String?
    /// The files of a model downloaded as several (`image_embedding` entries), each into
    /// `models/<slug>/<path>`; `downloadFile` is then nil.
    public let downloadFiles: [ModelDownloadFile]?
    /// `text` (the default) or `image`: which chunks the model embeds and which tower serves it.
    public let modality: String?
    /// Short human-readable summary of what this model is good for, shown in preset pickers.
    public let description: String?
    /// Example use cases surfaced alongside the description (e.g. "Semantic search", "Chat / Q&A").
    public let useCases: [String]?
    /// Marks this preset as one of the small set of recommended defaults offered when no model is registered yet.
    public let featured: Bool

    enum CodingKeys: String, CodingKey {
        case name
        case modelId = "model_id"
        case modelCardURLString = "model_card_url"
        case maker
        case countryOfOrigin = "country_of_origin"
        case originZone = "origin_zone"
        case slug
        case modelRef = "model_ref"
        case provider
        case nativeDims = "native_dims"
        case defaultDims = "default_dims"
        case contextSize = "context_size"
        case toolCalling = "tool_calling"
        case tags
        case downloadModelId = "download_model_id"
        case downloadFile = "download_file"
        case sha256
        case downloadFiles = "download_files"
        case modality
        case description
        case useCases = "use_cases"
        case featured
    }

    public init(
        name: String,
        modelId: String? = nil,
        modelCardURLString: String? = nil,
        maker: String? = nil,
        countryOfOrigin: String? = nil,
        originZone: String? = nil,
        slug: String,
        modelRef: String? = nil,
        provider: String? = "llama_xpc",
        nativeDims: Int? = nil,
        defaultDims: Int? = nil,
        contextSize: Int? = 8192,
        toolCalling: Bool = false,
        tags: [String]? = nil,
        downloadModelId: String? = nil,
        downloadFile: String? = nil,
        sha256: String? = nil,
        downloadFiles: [ModelDownloadFile]? = nil,
        modality: String? = nil,
        description: String? = nil,
        useCases: [String]? = nil,
        featured: Bool = false
    ) {
        self.name = name
        self.modelId = modelId
        self.modelCardURLString = modelCardURLString
        self.maker = maker
        self.countryOfOrigin = countryOfOrigin
        self.originZone = originZone
        self.slug = slug
        self.modelRef = modelRef ?? slug
        self.provider = provider
        self.nativeDims = nativeDims
        self.defaultDims = defaultDims
        self.contextSize = contextSize
        self.toolCalling = toolCalling
        self.tags = tags
        self.downloadModelId = downloadModelId
        self.downloadFile = downloadFile
        self.sha256 = sha256
        self.downloadFiles = downloadFiles
        self.modality = modality
        self.description = description
        self.useCases = useCases
        self.featured = featured
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        modelId = try container.decodeIfPresent(String.self, forKey: .modelId)
        modelCardURLString = try container.decodeIfPresent(String.self, forKey: .modelCardURLString)
        maker = try container.decodeIfPresent(String.self, forKey: .maker)
        countryOfOrigin = try container.decodeIfPresent(String.self, forKey: .countryOfOrigin)
        originZone = try container.decodeIfPresent(String.self, forKey: .originZone)
        slug = try container.decode(String.self, forKey: .slug)
        let decodedModelRef = try container.decodeIfPresent(String.self, forKey: .modelRef)
        modelRef = decodedModelRef ?? slug
        provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? "llama_xpc"
        nativeDims = try container.decodeIfPresent(Int.self, forKey: .nativeDims)
        defaultDims = try container.decodeIfPresent(Int.self, forKey: .defaultDims)
        contextSize = try container.decodeIfPresent(Int.self, forKey: .contextSize) ?? 8192
        toolCalling = try container.decodeIfPresent(Bool.self, forKey: .toolCalling) ?? false
        tags = try container.decodeIfPresent([String].self, forKey: .tags)
        downloadModelId = try container.decodeIfPresent(String.self, forKey: .downloadModelId)
        downloadFile = try container.decodeIfPresent(String.self, forKey: .downloadFile)
        sha256 = try container.decodeIfPresent(String.self, forKey: .sha256)
        downloadFiles = try container.decodeIfPresent([ModelDownloadFile].self, forKey: .downloadFiles)
        modality = try container.decodeIfPresent(String.self, forKey: .modality)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        useCases = try container.decodeIfPresent([String].self, forKey: .useCases)
        featured = try container.decodeIfPresent(Bool.self, forKey: .featured) ?? false
    }

    /// Where to read the model's license and model card, or nil when nothing names a page.
    public var modelCardURL: URL? {
        if let string = modelCardURLString, let url = URL(string: string), url.scheme == "https" {
            return url
        }
        guard let modelId, modelId.split(separator: "/").count == 2, !modelId.contains(" ") else { return nil }
        return URL(string: "https://huggingface.co/\(modelId)")
    }

    public var effectiveDims: Int {
        defaultDims ?? nativeDims ?? 0
    }

    public var downloadURLString: String? {
        if let downloadModelId = downloadModelId, let downloadFile = downloadFile, !downloadModelId.isEmpty, !downloadFile.isEmpty {
            return "https://huggingface.co/\(downloadModelId)/resolve/main/\(downloadFile)"
        }
        return nil
    }

    public var effectiveFilename: String? {
        if let downloadFile = downloadFile, !downloadFile.isEmpty {
            return downloadFile
        }
        return nil
    }

    /// Whether the model embeds images (an `image_embedding` entry, served by `image_xpc`).
    public var isImageModel: Bool {
        modality == "image" || provider == "image_xpc"
    }

    /// The files to download for a model that ships as several: each one's URL under the
    /// download repository, its path under `models/<slug>/`, and its expected digest.
    public var downloadFileTargets: [(url: String, filename: String, sha256: String?)] {
        guard let downloadModelId, !downloadModelId.isEmpty, let downloadFiles, !downloadFiles.isEmpty else { return [] }
        return downloadFiles.map { file in
            ("https://huggingface.co/\(downloadModelId)/resolve/main/\(file.path)", "\(slug)/\(file.path)", file.sha256)
        }
    }

    /// Whether the model is good for distilling facts: tagged "distillation", or untagged, as every
    /// entry of the older `fact_distil` list was a distillation model.
    public var isForDistillation: Bool {
        guard let tags else { return true }
        return tags.contains("distillation")
    }

    /// Whether the preset is tagged for inference (chat, `rag_ask`). Untagged presets, from a
    /// `fact_distil` list, count as both.
    public var isForInference: Bool {
        guard let tags else { return true }
        return tags.contains("inference")
    }

    /// The origin badge: the catalog's origin zone, else one derived from the country (US, EU,
    /// CN or the country code); nil when the catalog names neither.
    public var originRegion: String? {
        if let zone = originZone?.trimmingCharacters(in: .whitespaces).uppercased(), !zone.isEmpty {
            return zone
        }
        return ModelOriginRegion.region(for: countryOfOrigin)
    }

    /// "IBM, US" or "Mistral AI, FR", for the origin badge's tooltip.
    public var originSummary: String {
        [maker, countryOfOrigin].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    public var isEmbeddingModel: Bool {
        if let dims = defaultDims ?? nativeDims, dims > 0 {
            return true
        }
        let lower = (name + " " + slug).lowercased()
        return lower.contains("embed") || lower.contains("bge") || lower.contains("arctic")
    }
}

/// Groups a model's country of origin (an ISO 3166-1 alpha-2 code) for its badge when the catalog
/// gives no `origin_zone`.
public enum ModelOriginRegion {
    /// EU member states, grouped as one region.
    static let euCountries: Set<String> = [
        "AT", "BE", "BG", "HR", "CY", "CZ", "DK", "EE", "FI", "FR", "DE", "GR", "HU", "IE",
        "IT", "LV", "LT", "LU", "MT", "NL", "PL", "PT", "RO", "SK", "SI", "ES", "SE",
    ]

    /// US, EU, CN, or the country code itself for anywhere else; nil for no usable code.
    public static func region(for country: String?) -> String? {
        guard let code = country?.trimmingCharacters(in: .whitespaces).uppercased(), code.count == 2 else {
            return nil
        }
        return euCountries.contains(code) ? "EU" : code
    }
}

/// JSON representation of the configuration file.
public struct GarageConfigFile: Codable {
    public struct SourceEntry: Codable {
        public let slug: String
        public let root: String
        public let kind: String?
        public let corpusClass: String?
        public let trust: String?
        public let includeCode: Bool?
        public let enabled: Bool?

        enum CodingKeys: String, CodingKey {
            case slug
            case root
            case kind
            case corpusClass = "class"
            case trust
            case includeCode = "include_code"
            case enabled
        }
    }

    /// The `facts` section: which generative model (and provider) `garage enrich-facts`
    /// and the MCP `rag_ask` / `rag_generate` tools run on.
    public struct FactsEntry: Codable {
        public let model: String?
        public let provider: String?
    }

    /// The `embedding` section, reduced to the one key the app reads.
    public struct EmbeddingEntry: Codable {
        public let defaultModel: String?

        enum CodingKeys: String, CodingKey {
            case defaultModel = "default_model"
        }
    }

    public let sources: [SourceEntry]?
    public let models: [ModelPresetEntry]?
    public let facts: FactsEntry?
    /// The `inference` section: the chat model behind `rag_ask` / `rag_generate`. Same shape as
    /// `facts`; left empty, the distillation model answers.
    public let inference: FactsEntry?
    public let embedding: EmbeddingEntry?
}

/// The on-disk shape of `models.json`: presets grouped by what they're used for,
/// rather than one flat list. `text_embedding` feeds the embedding model picker;
/// `inference_models` holds the generative models, each tagged for inference, distillation or
/// both. `fact_distil` is the older name of that list, still read when `inference_models` is absent.
private struct ModelsManifest: Codable {
    let textEmbedding: [ModelPresetEntry]?
    let inferenceModels: [ModelPresetEntry]?
    let factDistil: [ModelPresetEntry]?
    let imageEmbedding: [ModelPresetEntry]?

    enum CodingKeys: String, CodingKey {
        case textEmbedding = "text_embedding"
        case inferenceModels = "inference_models"
        case factDistil = "fact_distil"
        case imageEmbedding = "image_embedding"
    }

    var inference: [ModelPresetEntry]? {
        inferenceModels ?? factDistil
    }
}

/// The preset groups of a catalog; nil for a group no source provided at all.
struct ModelPresetGroups {
    var textEmbedding: [ModelPresetEntry]?
    var inference: [ModelPresetEntry]?
    var imageEmbedding: [ModelPresetEntry]?
}

/// Utility for discovering and parsing Garage configuration files and model presets.
public enum GarageConfigLoader {
    /// Candidate file URLs where `garage.json` / `.garage.json` might reside.
    public static var candidateConfigFiles: [URL] {
        var paths: [URL] = []

        // 1. The garage working directory (Application Support) the app runs the CLI in
        let workDir = Paths.garageWorkingDirectory.appendingPathComponent("garage.json")
        paths.append(workDir)

        // 2. Project / process current working directory
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("garage.json")
        if cwd.path != workDir.path {
            paths.append(cwd)
        }

        // 3. User home directory ~/.garage.json (the Python side searches only ./garage.json and ~/.garage.json)
        let homeDotfile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".garage.json")
        paths.append(homeDotfile)

        return paths
    }

    /// Loads text-embedding model presets from `models.json`: `fileURL` when given, else the copy
    /// the app last fetched from the website, else the copy in the bundle, else a configuration
    /// file with a `models` array. There is no built-in list: `docs/.data/models.json` is the one
    /// catalog, and the bundle carries it (`//docs:model_manifest`), so an empty result means no
    /// file described any model.
    public static func loadModelPresets(fileURL: URL? = nil) -> [ModelPresetEntry] {
        loadModelManifest(fileURL: fileURL).textEmbedding ?? []
    }

    /// Loads every generative model preset (models.json's `inference_models`), from the same files.
    public static func loadInferencePresets(fileURL: URL? = nil) -> [ModelPresetEntry] {
        loadModelManifest(fileURL: fileURL).inference ?? []
    }

    /// Loads the inference presets tagged for fact distillation (gleaning facts out of documents).
    public static func loadFactDistilPresets(fileURL: URL? = nil) -> [ModelPresetEntry] {
        loadInferencePresets(fileURL: fileURL).filter(\.isForDistillation)
    }

    /// Loads image-embedding model presets (CLIP-style models the image embedding helper runs on
    /// Core ML) from models.json's `image_embedding` section, from the same files.
    public static func loadImageEmbeddingPresets(fileURL: URL? = nil) -> [ModelPresetEntry] {
        loadModelManifest(fileURL: fileURL).imageEmbedding ?? []
    }

    /// The files `loadModelPresets` reads, in order: `fileURL`, then `Paths.modelsJSON`
    /// (fetched copy, else the bundle's), then the configuration files.
    static func modelManifestCandidates(fileURL: URL?) -> [URL] {
        var candidates: [URL] = []
        if let explicit = fileURL {
            candidates.append(explicit)
        }
        candidates.append(Paths.modelsJSON)
        candidates.append(contentsOf: candidateConfigFiles)
        return candidates
    }

    /// Resolves models.json (or a candidate config file) into its preset groups. A group that no
    /// source provided at all is `nil`.
    private static func loadModelManifest(fileURL: URL?) -> ModelPresetGroups {
        loadModelManifest(candidates: modelManifestCandidates(fileURL: fileURL))
    }

    /// The first of `candidates` that exists and decodes as a catalog, or empty groups.
    static func loadModelManifest(candidates: [URL]) -> ModelPresetGroups {
        for url in candidates {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if let manifest = decodeModelManifest(from: url) {
                return manifest
            }
        }

        return ModelPresetGroups()
    }

    /// Whether `data` is a models.json worth using: the grouped shape, with at least one
    /// text embedding preset.
    static func isUsableModelCatalog(_ data: Data) -> Bool {
        guard let manifest = try? JSONDecoder().decode(ModelsManifest.self, from: data) else { return false }
        return !(manifest.textEmbedding ?? []).isEmpty
    }

    private static func decodeModelManifest(from url: URL) -> ModelPresetGroups? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()

        // 1. Current models.json shape: presets grouped by use (text_embedding / inference_models /
        //    image_embedding).
        if let manifest = try? decoder.decode(ModelsManifest.self, from: data),
           !(manifest.textEmbedding ?? []).isEmpty || !(manifest.inference ?? []).isEmpty || !(manifest.imageEmbedding ?? []).isEmpty {
            return ModelPresetGroups(textEmbedding: manifest.textEmbedding, inference: manifest.inference, imageEmbedding: manifest.imageEmbedding)
        }

        // 2. Legacy flat array of ModelPresetEntry (pre-grouping models.json).
        if let list = try? decoder.decode([ModelPresetEntry].self, from: data), !list.isEmpty {
            return ModelPresetGroups(textEmbedding: list)
        }

        // 3. garage.json with an embedded `models` array.
        if let config = try? decoder.decode(GarageConfigFile.self, from: data), let models = config.models, !models.isEmpty {
            return ModelPresetGroups(textEmbedding: models)
        }

        return nil
    }

    /// Defaults the Python side applies when garage.json has no `facts` section.
    public static let defaultFactsModel = "gemma2-2b"
    public static let defaultFactsProvider = "llama_xpc"

    /// Reads the `facts` section of garage.json (`{"facts": {"model": ..., "provider": ...}}`).
    /// The first candidate file that parses wins, because that is the file the CLI itself
    /// reads; a missing section or missing keys fall back to the Python defaults.
    public static func loadFactsSettings(fileURL: URL? = nil) -> (model: String, provider: String) {
        let targets = fileURL.map { [$0] } ?? candidateConfigFiles

        for url in targets {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let data = try? Data(contentsOf: url),
                  let config = try? JSONDecoder().decode(GarageConfigFile.self, from: data) else {
                continue
            }
            let model = config.facts?.model?.trimmingCharacters(in: .whitespacesAndNewlines)
            let provider = config.facts?.provider?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (
                (model?.isEmpty == false) ? model! : defaultFactsModel,
                (provider?.isEmpty == false) ? provider! : defaultFactsProvider
            )
        }

        return (defaultFactsModel, defaultFactsProvider)
    }

    /// Reads the `inference` section of garage.json. Unlike `facts` there is no default: a missing
    /// or empty `inference.model` means the distillation model (`facts.model`) answers chat too,
    /// so both values come back nil then. A provider without a model is ignored, as in Python.
    public static func loadInferenceSettings(fileURL: URL? = nil) -> (model: String?, provider: String?) {
        let targets = fileURL.map { [$0] } ?? candidateConfigFiles

        for url in targets {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let data = try? Data(contentsOf: url),
                  let config = try? JSONDecoder().decode(GarageConfigFile.self, from: data) else {
                continue
            }
            let model = config.inference?.model?.trimmingCharacters(in: .whitespacesAndNewlines)
            let provider = config.inference?.provider?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let model, !model.isEmpty else { return (nil, nil) }
            return (model, (provider?.isEmpty == false) ? provider : nil)
        }

        return (nil, nil)
    }

    /// Default the Python side applies when garage.json names no `embedding.default_model`.
    public static let defaultEmbeddingModel = "bge-m3"

    /// Reads `embedding.default_model` from garage.json: the model search uses when no registered
    /// model is flagged default. The first candidate file that parses wins, as for `facts`.
    public static func loadDefaultEmbeddingModel(fileURL: URL? = nil) -> String {
        let targets = fileURL.map { [$0] } ?? candidateConfigFiles

        for url in targets {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let data = try? Data(contentsOf: url),
                  let config = try? JSONDecoder().decode(GarageConfigFile.self, from: data) else {
                continue
            }
            let model = config.embedding?.defaultModel?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (model?.isEmpty == false) ? model! : defaultEmbeddingModel
        }

        return defaultEmbeddingModel
    }

    /// Parses sources declared in configuration files.
    public static func loadSourcesFromConfig(fileURL: URL? = nil) -> [RegisteredSource] {
        let targets = fileURL.map { [$0] } ?? candidateConfigFiles

        for url in targets {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                let data = try Data(contentsOf: url)
                let config = try JSONDecoder().decode(GarageConfigFile.self, from: data)
                if let sources = config.sources, !sources.isEmpty {
                    return sources.map { entry in
                        RegisteredSource(
                            slug: entry.slug,
                            kind: entry.kind ?? "filesystem",
                            root: entry.root,
                            corpusClass: entry.corpusClass ?? "document",
                            trust: entry.trust ?? "authored",
                            enabled: entry.enabled ?? true,
                            includeCode: entry.includeCode ?? false,
                            origin: .config
                        )
                    }
                }
            } catch {
                // Ignore parse errors or try next candidate
                continue
            }
        }

        return []
    }
}

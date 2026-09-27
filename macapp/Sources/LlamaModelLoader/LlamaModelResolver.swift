import Foundation
import PythonXPCService

/// The settings a llama.cpp model is loaded with when nobody chose others: the Models page's
/// Load button and every on-demand load use these, so a model loads the same way from either.
public enum LlamaModelLoadDefaults {
    /// `n_ctx` when the catalog gives no `context_size`.
    public static let contextSize = 8192
    public static let gpuLayers = 33
    public static let threads = 4
}

/// Everything `loadModel` / `ensureModel` needs for one model.
public struct LlamaModelLoadPlan: Equatable, Sendable {
    /// The alias the engine keeps the model under: the model's slug, which is also the `model`
    /// Python names in its requests (`model_ref`, equal to the slug for every catalog model).
    public let alias: String
    public let displayName: String
    /// Absolute path of the downloaded GGUF.
    public let path: String
    public let contextSize: Int
    public let gpuLayers: Int
    public let threads: Int

    public init(
        alias: String,
        displayName: String,
        path: String,
        contextSize: Int = LlamaModelLoadDefaults.contextSize,
        gpuLayers: Int = LlamaModelLoadDefaults.gpuLayers,
        threads: Int = LlamaModelLoadDefaults.threads
    ) {
        self.alias = alias
        self.displayName = displayName
        self.path = path
        self.contextSize = contextSize
        self.gpuLayers = gpuLayers
        self.threads = threads
    }

    /// The `configJson` object LlamaXPCService reads (llama-server flag names).
    public var config: [String: Any] {
        ["n_ctx": contextSize, "n_gpu_layers": gpuLayers, "threads": threads]
    }
}

public enum LlamaModelLoaderError: LocalizedError, Equatable {
    /// The catalog knows the model (or its file name), but the GGUF is not in the models folder.
    case notDownloaded(alias: String, name: String, file: String)
    /// Neither the catalog nor the models folder says which file the alias is.
    case unknownModel(alias: String)
    /// LlamaXPCService could not load the file, or could not be reached.
    case loadFailed(alias: String, message: String)
    case timedOut(alias: String, seconds: Int)
    /// This XPC service has not been handed LlamaXPCService's endpoint by the app yet (a sibling
    /// service cannot look LlamaXPCService up by name).
    case endpointNotHandedOver

    public var errorDescription: String? {
        switch self {
        case .notDownloaded(let alias, let name, let file):
            return "The model \(alias) (\(name)) is not downloaded: \(file) is not in the models folder. "
                + "Download \(name) on the Models page of the Garage app."
        case .unknownModel(let alias):
            return "No downloaded GGUF file is known for the model \(alias): it is not in the model catalog "
                + "and no file of that name is in the models folder. Download it on the Models page of the "
                + "Garage app, or load it there by hand."
        case .loadFailed(let alias, let message):
            return "LlamaXPCService could not load the model \(alias): \(message)"
        case .timedOut(let alias, let seconds):
            return "Loading the model \(alias) did not finish within \(seconds) seconds."
        case .endpointNotHandedOver:
            return "LlamaXPCService endpoint not handed over yet: this helper reaches LlamaXPCService only "
                + "through a connection the Garage app hands it after launch. Wait for the app to finish "
                + "starting its helpers, or quit and reopen Garage."
        }
    }
}

/// Finds the GGUF and load settings for a model alias (its slug), the way the Models page does:
/// the `models.json` catalog entry's `download_file` and `context_size`, else a file in the models
/// folder named after the alias.
public struct LlamaModelResolver: Sendable {
    /// One model of `models.json`, reduced to what a load needs.
    public struct CatalogEntry: Decodable, Equatable, Sendable {
        public let slug: String
        public let name: String?
        public let modelRef: String?
        /// The provider-side id (`BAAI/bge-m3`), which the add-model form suggests as a `model_ref`.
        public let modelID: String?
        public let downloadFile: String?
        public let contextSize: Int?

        enum CodingKeys: String, CodingKey {
            case slug
            case name
            case modelRef = "model_ref"
            case modelID = "model_id"
            case downloadFile = "download_file"
            case contextSize = "context_size"
        }
    }

    /// `models.json` candidates, first readable one wins.
    public let catalogURLs: [URL]
    /// The downloaded models folder (`<data folder>/models`).
    public let modelsDirectory: URL

    public init(catalogURLs: [URL], modelsDirectory: URL) {
        self.catalogURLs = catalogURLs
        self.modelsDirectory = modelsDirectory
    }

    /// The resolver for this process: the catalog the app last fetched, then the one Python was
    /// pointed at (`GARAGE_MODEL_MANIFEST`), then the app bundle's; the data folder's `models`.
    public static func standard(bundle: Bundle = .main) -> LlamaModelResolver {
        var urls: [URL] = [GarageAppGroup.fetchedModelCatalog]
        if let manifest = getenv("GARAGE_MODEL_MANIFEST").map({ String(cString: $0) }), !manifest.isEmpty {
            urls.append(URL(fileURLWithPath: (manifest as NSString).expandingTildeInPath))
        }
        if let appBundle = containingAppBundle(of: bundle.bundleURL) {
            urls.append(appBundle.appendingPathComponent("Contents/Resources/models.json"))
        }
        if let own = bundle.url(forResource: "models", withExtension: "json") {
            urls.append(own)
        }
        return LlamaModelResolver(
            catalogURLs: urls,
            modelsDirectory: GarageAppGroup.dataDirectory.appendingPathComponent("models", isDirectory: true)
        )
    }

    /// The outermost `.app` containing `url` (an XPC service or helper app sits inside Garage.app).
    static func containingAppBundle(of url: URL) -> URL? {
        var found: URL?
        var cursor = url.standardizedFileURL
        while cursor.path != "/" && !cursor.path.isEmpty {
            if cursor.pathExtension == "app" {
                found = cursor
            }
            cursor = cursor.deletingLastPathComponent()
        }
        return found
    }

    /// Every model entry of the first readable catalog (embedding and generative models alike).
    public func catalogEntries() -> [CatalogEntry] {
        for url in catalogURLs {
            guard let data = try? Data(contentsOf: url) else { continue }
            if let entries = Self.parseCatalog(data) {
                return entries
            }
        }
        return []
    }

    /// Parses `models.json`: an object of arrays (`text_embedding`, `fact_distil`, ...) or one array.
    static func parseCatalog(_ data: Data) -> [CatalogEntry]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var raw: [Any] = []
        if let dict = json as? [String: Any] {
            for key in dict.keys.sorted() {
                if let list = dict[key] as? [Any] {
                    raw.append(contentsOf: list)
                }
            }
        } else if let list = json as? [Any] {
            raw = list
        } else {
            return nil
        }
        let decoder = JSONDecoder()
        return raw.compactMap { item in
            guard JSONSerialization.isValidJSONObject(item),
                  let itemData = try? JSONSerialization.data(withJSONObject: item) else { return nil }
            return try? decoder.decode(CatalogEntry.self, from: itemData)
        }
    }

    /// The catalog entry for `alias`: by slug, else by `model_ref`, else by `model_id` (a
    /// registration may name the model the provider's way, as the add-model form suggests).
    public func entry(for alias: String) -> CatalogEntry? {
        let entries = catalogEntries()
        return entries.first { $0.slug == alias }
            ?? entries.first { $0.modelRef == alias }
            ?? entries.first { $0.modelID == alias }
    }

    /// The load plan for `alias`, or an error that says what to download.
    public func resolve(alias: String) throws -> LlamaModelLoadPlan {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LlamaModelLoaderError.unknownModel(alias: alias) }

        let entry = entry(for: trimmed)
        let name = entry?.name ?? trimmed
        let contextSize = entry?.contextSize ?? LlamaModelLoadDefaults.contextSize
        let gpuLayers = LlamaModelLoadDefaults.gpuLayers

        // The file the Models page would download for this model.
        if let expectedFile = nonEmpty(entry?.downloadFile) {
            if let path = downloadedPath(for: expectedFile) {
                return LlamaModelLoadPlan(alias: trimmed, displayName: name, path: path,
                                          contextSize: contextSize, gpuLayers: gpuLayers)
            }
            throw LlamaModelLoaderError.notDownloaded(alias: trimmed, name: name, file: expectedFile)
        }
        // A model outside the catalog: a GGUF named after it, as a hand-loaded file would be aliased.
        if let path = fileNamed(stem: trimmed) {
            return LlamaModelLoadPlan(alias: trimmed, displayName: name, path: path,
                                      contextSize: contextSize, gpuLayers: gpuLayers)
        }
        throw LlamaModelLoaderError.unknownModel(alias: trimmed)
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }

    /// Where `file` (a catalog `download_file`, possibly with a subfolder) was downloaded: at that
    /// relative path in the models folder, else any file with the same name (case-insensitive),
    /// the matching the Models page's download list uses.
    func downloadedPath(for file: String) -> String? {
        let direct = modelsDirectory.appendingPathComponent(file)
        if isRegularFile(direct) {
            return direct.path
        }
        let wanted = URL(fileURLWithPath: file).lastPathComponent.lowercased()
        return downloadedFiles().first { URL(fileURLWithPath: $0).lastPathComponent.lowercased() == wanted }
    }

    private func fileNamed(stem: String) -> String? {
        let wanted = stem.lowercased()
        return downloadedFiles().first {
            let url = URL(fileURLWithPath: $0)
            return url.pathExtension.lowercased() == "gguf" && url.deletingPathExtension().lastPathComponent.lowercased() == wanted
        }
    }

    /// Every regular file under the models folder (the downloader keeps a `download_file`'s
    /// subfolders, so this descends).
    private func downloadedFiles() -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: modelsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }
        // The enumerator reports resolved paths (/private/var for /var), so each file is named
        // under the models folder as given, the way the direct lookups name it.
        let base = modelsDirectory.resolvingSymlinksInPath().pathComponents
        var files: [String] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let components = url.resolvingSymlinksInPath().pathComponents
            if components.count > base.count, Array(components.prefix(base.count)) == base {
                files.append(components.dropFirst(base.count).reduce(modelsDirectory) { $0.appendingPathComponent($1) }.path)
            } else {
                files.append(url.path)
            }
        }
        return files.sorted()
    }

    private func isRegularFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }
}

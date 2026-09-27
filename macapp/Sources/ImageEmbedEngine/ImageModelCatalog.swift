import Foundation
import PythonXPCService

/// How an image embedding model is run: the two Core ML packages, the tokenizer of the text tower,
/// and the preprocessing both were trained with. Read from the `image_embedding` section of
/// `models.json`, whose fields are documented in docs/schema.md; anything the entry leaves out is
/// taken from the model itself (input and output shapes) or defaults to SigLIP's conventions.
public struct ImageModelSpec: Equatable, Sendable {
    public var slug: String
    public var name: String
    /// Relative to the model's folder (`<data folder>/models/<slug>`).
    public var imagePackage: String
    public var textPackage: String
    public var tokenizerFile: String
    /// Declared widths; nil means "whatever the model says".
    public var dims: Int?
    public var imageSize: Int?
    public var textLength: Int?
    /// Per-channel mean and standard deviation on [0, 1] pixels (SigLIP: 0.5 / 0.5; CLIP: its own).
    public var imageMean: [Float]
    public var imageStd: [Float]
    /// Whether the text tower was trained on lowercased text (SigLIP 2: yes).
    public var textLowercase: Bool

    public static let defaultImageMean: [Float] = [0.5, 0.5, 0.5]
    public static let defaultImageStd: [Float] = [0.5, 0.5, 0.5]

    public init(
        slug: String,
        name: String? = nil,
        imagePackage: String,
        textPackage: String,
        tokenizerFile: String = "tokenizer.json",
        dims: Int? = nil,
        imageSize: Int? = nil,
        textLength: Int? = nil,
        imageMean: [Float] = ImageModelSpec.defaultImageMean,
        imageStd: [Float] = ImageModelSpec.defaultImageStd,
        textLowercase: Bool = true
    ) {
        self.slug = slug
        self.name = name ?? slug
        self.imagePackage = imagePackage
        self.textPackage = textPackage
        self.tokenizerFile = tokenizerFile
        self.dims = dims
        self.imageSize = imageSize
        self.textLength = textLength
        self.imageMean = imageMean.count == 3 ? imageMean : ImageModelSpec.defaultImageMean
        self.imageStd = imageStd.count == 3 ? imageStd : ImageModelSpec.defaultImageStd
        self.textLowercase = textLowercase
    }

    /// One `image_embedding` entry of models.json; nil when it names no packages.
    init?(catalogEntry entry: [String: Any]) {
        guard let slug = entry["slug"] as? String, !slug.isEmpty,
              let imagePackage = entry["image_model"] as? String, !imagePackage.isEmpty,
              let textPackage = entry["text_model"] as? String, !textPackage.isEmpty else { return nil }
        func floats(_ key: String) -> [Float]? {
            (entry[key] as? [Any])?.compactMap { ($0 as? NSNumber)?.floatValue }
        }
        self.init(
            slug: slug,
            name: entry["name"] as? String,
            imagePackage: imagePackage,
            textPackage: textPackage,
            tokenizerFile: (entry["tokenizer"] as? String) ?? "tokenizer.json",
            dims: (entry["native_dims"] as? NSNumber)?.intValue,
            imageSize: (entry["image_size"] as? NSNumber)?.intValue,
            textLength: (entry["text_length"] as? NSNumber)?.intValue,
            imageMean: floats("image_mean") ?? ImageModelSpec.defaultImageMean,
            imageStd: floats("image_std") ?? ImageModelSpec.defaultImageStd,
            textLowercase: (entry["text_lowercase"] as? Bool) ?? true
        )
    }
}

public enum ImageModelResolverError: LocalizedError {
    case unknownModel(slug: String)
    case notDownloaded(slug: String, missing: [String], folder: String)

    public var errorDescription: String? {
        switch self {
        case .unknownModel(let slug):
            return "\(slug) is not an image embedding model in models.json, and its folder holds no Core ML packages"
        case .notDownloaded(let slug, let missing, let folder):
            return "\(slug) is not downloaded: missing \(missing.joined(separator: ", ")) in \(folder). Download it on the Models page."
        }
    }
}

/// Finds an image embedding model's spec and downloaded files.
///
/// The catalog is read the way `LlamaModelResolver` reads it: the copy the app last fetched, then
/// the one Python was pointed at (`GARAGE_MODEL_MANIFEST`), then the app bundle's. A folder under
/// `models/` that the catalog does not describe still works when it holds one `*image*.mlpackage`,
/// one `*text*.mlpackage` and a `tokenizer.json`: the widths then come from the model.
public struct ImageModelResolver: Sendable {
    public let catalogURLs: [URL]
    public let modelsDirectory: URL

    public init(catalogURLs: [URL], modelsDirectory: URL) {
        self.catalogURLs = catalogURLs
        self.modelsDirectory = modelsDirectory
    }

    public static func standard(bundle: Bundle = .main) -> ImageModelResolver {
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
        return ImageModelResolver(
            catalogURLs: urls,
            modelsDirectory: GarageAppGroup.dataDirectory.appendingPathComponent("models", isDirectory: true)
        )
    }

    /// The outermost `.app` containing `url` (an XPC service sits inside Garage.app).
    static func containingAppBundle(of url: URL) -> URL? {
        var found: URL?
        var cursor = url.standardizedFileURL
        while cursor.pathComponents.count > 1 {
            if cursor.pathExtension == "app" {
                found = cursor
            }
            cursor.deleteLastPathComponent()
        }
        return found
    }

    /// The folder a model's files were downloaded to.
    public func folder(for slug: String) -> URL {
        modelsDirectory.appendingPathComponent(slug, isDirectory: true)
    }

    /// Every image embedding model the first readable catalog lists.
    public func catalogSpecs() -> [ImageModelSpec] {
        for url in catalogURLs {
            guard let data = try? Data(contentsOf: url) else { continue }
            if let specs = Self.parseCatalog(data) {
                return specs
            }
        }
        return []
    }

    /// The `image_embedding` entries of a models.json; nil when `data` is not a catalog.
    public static func parseCatalog(_ data: Data) -> [ImageModelSpec]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let entries = object["image_embedding"] as? [[String: Any]] ?? []
        return entries.compactMap { ImageModelSpec(catalogEntry: $0) }
    }

    /// The spec for `slug`: from the catalog, else from the files in its folder.
    public func spec(for slug: String) throws -> ImageModelSpec {
        if let spec = catalogSpecs().first(where: { $0.slug == slug }) {
            return spec
        }
        let folder = folder(for: slug)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let packages = entries.filter { $0.hasSuffix(".mlpackage") || $0.hasSuffix(".mlmodelc") }
        guard let image = packages.first(where: { $0.lowercased().contains("image") }),
              let text = packages.first(where: { $0.lowercased().contains("text") }) else {
            throw ImageModelResolverError.unknownModel(slug: slug)
        }
        return ImageModelSpec(slug: slug, imagePackage: image, textPackage: text)
    }

    /// The files a spec needs, or which are missing.
    public func locate(_ spec: ImageModelSpec) throws -> (image: URL, text: URL, tokenizer: URL) {
        let folder = folder(for: spec.slug)
        let image = folder.appendingPathComponent(spec.imagePackage)
        let text = folder.appendingPathComponent(spec.textPackage)
        let tokenizer = folder.appendingPathComponent(spec.tokenizerFile)
        let missing = [image, text, tokenizer].filter { !FileManager.default.fileExists(atPath: $0.path) }
        if !missing.isEmpty {
            throw ImageModelResolverError.notDownloaded(
                slug: spec.slug, missing: missing.map(\.lastPathComponent), folder: folder.path
            )
        }
        return (image, text, tokenizer)
    }
}

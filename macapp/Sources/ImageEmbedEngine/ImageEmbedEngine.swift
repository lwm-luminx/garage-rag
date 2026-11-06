import Foundation
import ImageEmbedClient
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag", category: "ImageEmbedEngine")

/// The resident image embedding models, loaded on demand from the downloaded catalog models.
public final class ImageEmbedEngine: @unchecked Sendable {
    public let resolver: ImageModelResolver
    private let lock = NSLock()
    private var loaded: [String: CoreMLImageEmbedder] = [:]

    public init(resolver: ImageModelResolver = .standard()) {
        self.resolver = resolver
    }

    /// The model for `slug`, loading it when it is not resident. Slow the first time (Core ML
    /// compiles the packages once) and whenever the model was unloaded.
    public func model(_ slug: String) throws -> CoreMLImageEmbedder {
        let slug = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        if let resident = loaded[slug] {
            lock.unlock()
            return resident
        }
        lock.unlock()

        let spec = try resolver.spec(for: slug)
        let files = try resolver.locate(spec)
        let started = Date()
        let embedder = try CoreMLImageEmbedder(spec: spec, imagePackage: files.image, textPackage: files.text, tokenizer: files.tokenizer)
        logger.info("loaded \(slug, privacy: .public) in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s")

        lock.lock()
        defer { lock.unlock() }
        if let raced = loaded[slug] {
            return raced
        }
        loaded[slug] = embedder
        return embedder
    }

    @discardableResult
    public func load(_ slug: String) throws -> ImageEmbedModelInfo {
        try model(slug).info
    }

    public func unload(_ slug: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return loaded.removeValue(forKey: slug) != nil
    }

    public func residentModels() -> [ImageEmbedModelInfo] {
        lock.lock()
        defer { lock.unlock() }
        return loaded.values.map(\.info).sorted { $0.slug < $1.slug }
    }

    public func embedImages(_ images: [Data], model slug: String) throws -> [[Float]] {
        try model(slug).embedImages(images)
    }

    public func embedTexts(_ texts: [String], model slug: String) throws -> [[Float]] {
        try model(slug).embedTexts(texts)
    }
}

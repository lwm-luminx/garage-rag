import Foundation
import ImageEmbedClient
import ImageEmbedEngine
import OSLog
import PythonXPCService

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag.image-embed-xpc", category: "GarageImageEmbedXPCService")

/// The image embedding helper: Core ML image and text towers of CLIP-style models (SigLIP 2 in
/// the catalog), loaded on demand from `<data folder>/models/<slug>`.
///
/// It runs no Python and holds no folder grants: callers send image bytes and get vectors. The
/// app talks to it by name; garage-xpc, embed-xpc and mcp-server-xpc, whose Python embeds with
/// `image_xpc` models, connect through the anonymous listener endpoint the app hands them
/// (`GarageImageEmbedEndpointReceiverProtocol`), and their Python reaches this process through
/// the bridge their host installs (`ImageEmbedBridge`).
final class GarageImageEmbedXPCServiceDelegate: GarageXPCServiceBase, GarageImageEmbedXPCServiceProtocol {
    /// Model loads and batches take a while; keep them off the XPC listener thread.
    private static let workerQueue = DispatchQueue(label: "me.rickmark.garage.image-embed.worker", qos: .userInitiated)
    private let engine: ImageEmbedEngine
    private let encoder = JSONEncoder()

    init(engine: ImageEmbedEngine = ImageEmbedEngine()) {
        self.engine = engine
        super.init(
            serviceName: "GarageImageEmbedXPCService",
            logFileName: "image-embed-xpc.log",
            usesPython: false
        )
    }

    override var exportedInterface: NSXPCInterface {
        NSXPCInterface(with: GarageImageEmbedXPCServiceProtocol.self)
    }

    override func additionalSelfTests() -> [GarageXPCSelfTest] {
        let engine = self.engine
        return [
            GarageXPCSelfTest(
                name: "Image Model Catalog",
                description: "models.json lists image embedding models and names their Core ML packages.",
                requiresPython: false
            ) {
                let specs = engine.resolver.catalogSpecs()
                guard !specs.isEmpty else {
                    throw GarageXPCSelfTestFailure("No image_embedding entries in models.json (looked at \(engine.resolver.catalogURLs.map(\.path).joined(separator: ", ")))")
                }
                let downloaded = specs.filter { (try? engine.resolver.locate($0)) != nil }.map(\.slug)
                return "Catalog: \(specs.map(\.slug).joined(separator: ", "))\nDownloaded: \(downloaded.isEmpty ? "none" : downloaded.joined(separator: ", "))"
            },
            GarageXPCSelfTest(
                name: "Resident Image Models",
                description: "Reports the image embedding models loaded in this process.",
                requiresPython: false
            ) {
                let resident = engine.residentModels()
                guard !resident.isEmpty else {
                    throw GarageXPCSelfTestSkipped("No image model loaded yet: the first backfill or search with one loads it")
                }
                return resident.map { "\($0.slug): \($0.dims) dims, \($0.imageSize) px, \($0.textLength) tokens" }.joined(separator: "\n")
            },
        ]
    }

    private func infoJSON(_ info: ImageEmbedModelInfo) throws -> String {
        String(decoding: try encoder.encode(info), as: UTF8.self)
    }

    private func failure(_ error: Error, code: Int = 1) -> NSError {
        NSError(
            domain: "me.rickmark.garage-rag.image-embed-xpc",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: error.localizedDescription]
        )
    }

    // MARK: - GarageImageEmbedXPCServiceProtocol

    func loadModel(slug: String, with reply: @escaping (String?, Error?) -> Void) {
        logger.info("loadModel \(slug, privacy: .public)")
        Self.workerQueue.async { [self] in
            do {
                let info = try engine.load(slug)
                reply(try infoJSON(info), nil)
                rerunSelfTests(named: ["Resident Image Models"])
            } catch {
                logger.error("loadModel \(slug, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                GarageXPCOutputCapture.shared.log(level: "ERROR", message: "Could not load \(slug): \(error.localizedDescription)")
                reply(nil, failure(error))
            }
        }
    }

    func unloadModel(slug: String, with reply: @escaping (Bool, Error?) -> Void) {
        let unloaded = engine.unload(slug)
        logger.info("unloadModel \(slug, privacy: .public): \(unloaded ? "unloaded" : "was not loaded", privacy: .public)")
        reply(unloaded, nil)
    }

    func listModels(with reply: @escaping (String?, Error?) -> Void) {
        do {
            reply(String(decoding: try encoder.encode(engine.residentModels()), as: UTF8.self), nil)
        } catch {
            reply(nil, failure(error))
        }
    }

    func embedImages(_ images: [Data], model slug: String, with reply: @escaping (Data?, Error?) -> Void) {
        Self.workerQueue.async { [self] in
            do {
                let vectors = try engine.embedImages(images, model: slug)
                reply(ImageEmbedVectors.encode(vectors), nil)
            } catch {
                logger.error("embedImages (\(images.count, privacy: .public)) with \(slug, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                reply(nil, failure(error))
            }
        }
    }

    func embedTexts(_ texts: [String], model slug: String, with reply: @escaping (Data?, Error?) -> Void) {
        Self.workerQueue.async { [self] in
            do {
                let vectors = try engine.embedTexts(texts, model: slug)
                reply(ImageEmbedVectors.encode(vectors), nil)
            } catch {
                logger.error("embedTexts (\(texts.count, privacy: .public)) with \(slug, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                reply(nil, failure(error))
            }
        }
    }

    func getListenerEndpoint(with reply: @escaping (NSXPCListenerEndpoint?, Error?) -> Void) {
        reply(anonymousListenerEndpoint(), nil)
    }
}

// MARK: - Process Entry Point

let delegate = GarageImageEmbedXPCServiceDelegate()
delegate.bootstrap()
delegate.run()

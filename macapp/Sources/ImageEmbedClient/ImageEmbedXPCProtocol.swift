import Foundation
import PythonXPCService

/// The NSXPC interface of `GarageImageEmbedXPCService`, the helper that runs CLIP-style image
/// embedding models (a Core ML image tower and text tower sharing one space; SigLIP 2 in the
/// catalog) on the Neural Engine or GPU.
///
/// Vectors travel as raw little-endian Float32, `count * dims` values in input order, so a batch
/// of a hundred images does not become megabytes of JSON. Everything else is JSON strings, as the
/// other helpers do. The service holds no folder grants: callers send image bytes, never paths.
@objc(GarageImageEmbedXPCServiceProtocol)
public protocol GarageImageEmbedXPCServiceProtocol: GarageCommonXPCServiceProtocol {
    /// Loads the catalog model `slug` (from `<data folder>/models/<slug>`) when it is not resident
    /// and replies with its `ImageEmbedModelInfo` JSON.
    func loadModel(slug: String, with reply: @escaping (String?, Error?) -> Void)

    /// Frees a resident model. True when it was loaded.
    func unloadModel(slug: String, with reply: @escaping (Bool, Error?) -> Void)

    /// The resident models, as `ImageEmbedModelInfo` JSON array.
    func listModels(with reply: @escaping (String?, Error?) -> Void)

    /// Embeds encoded image files (JPEG, PNG, HEIC, ...) with the model's image tower.
    func embedImages(_ images: [Data], model slug: String, with reply: @escaping (Data?, Error?) -> Void)

    /// Embeds short texts (queries, captions) with the model's text tower.
    func embedTexts(_ texts: [String], model slug: String, with reply: @escaping (Data?, Error?) -> Void)

    /// The endpoint of an anonymous listener served by this same delegate, for the app to hand to
    /// XPC services whose Python embeds with `image_xpc` models (`GarageImageEmbedEndpointReceiverProtocol`).
    func getListenerEndpoint(with reply: @escaping (NSXPCListenerEndpoint?, Error?) -> Void)
}

public enum ImageEmbedXPCConstants {
    public static let serviceName = "me.rickmark.garage-rag.image-embed-xpc"
}

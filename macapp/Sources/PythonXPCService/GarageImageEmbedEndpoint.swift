import Foundation

/// Lets a helper XPC service receive a connection point to GarageImageEmbedXPCService.
///
/// Like LlamaXPCService (`GarageLlamaEndpointReceiverProtocol`), the image embedding service is
/// private to the app that bundles it: a sibling service cannot look
/// `me.rickmark.garage-rag.image-embed-xpc` up by name. So the app asks it for the endpoint of an
/// anonymous listener (`GarageImageEmbedXPCServiceProtocol.getListenerEndpoint`) and hands it to
/// every service whose Python embeds with `image_xpc` models (garage-xpc: backfill and search;
/// mcp-server-xpc: rag_search; embed-xpc: the embed worker), which then connect with
/// `NSXPCConnection(listenerEndpoint:)`. The app hands it over again whenever either side is relaunched.
@objc(GarageImageEmbedEndpointReceiverProtocol)
public protocol GarageImageEmbedEndpointReceiverProtocol: NSObjectProtocol {
    /// Stores the endpoint of GarageImageEmbedXPCService's anonymous listener for this process's clients.
    func setImageEmbedEndpoint(_ endpoint: NSXPCListenerEndpoint, with reply: @escaping (Bool, String?) -> Void)
}

/// The GarageImageEmbedXPCService endpoint this process was handed (`GarageImageEmbedEndpointReceiverProtocol`).
///
/// `generation` goes up with every hand-over, so a client cached for an older endpoint (one from a
/// service that has since been relaunched) knows to connect again.
public final class GarageImageEmbedEndpointStore: @unchecked Sendable {
    public static let shared = GarageImageEmbedEndpointStore()

    /// The self test that depends on the endpoint; a service re-runs it when an endpoint arrives.
    public static let dependentSelfTestName = "Image Embedding Bridge"

    private let lock = NSLock()
    private var _endpoint: NSXPCListenerEndpoint?
    private var _generation = 0

    public init() {}

    public var endpoint: NSXPCListenerEndpoint? {
        lock.lock()
        defer { lock.unlock() }
        return _endpoint
    }

    public var generation: Int {
        lock.lock()
        defer { lock.unlock() }
        return _generation
    }

    public func set(_ endpoint: NSXPCListenerEndpoint?) {
        lock.lock()
        _endpoint = endpoint
        _generation += 1
        lock.unlock()
    }
}

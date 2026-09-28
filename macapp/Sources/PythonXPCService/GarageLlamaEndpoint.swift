import Foundation

/// Lets a helper XPC service receive a connection point to LlamaXPCService.
///
/// An XPC service is private to the app that bundles it: Garage.app can look up
/// `me.rickmark.garage-rag.llama-xpc` by name, but a sibling XPC service cannot. So the app asks
/// LlamaXPCService for the endpoint of an anonymous listener (`LlamaXPCServiceProtocol.getListenerEndpoint`)
/// and hands it to every service that loads llama_xpc models on demand (garage-xpc, embed-xpc,
/// mcp-server-xpc), which then connect with `NSXPCConnection(listenerEndpoint:)`. The app hands it
/// over again whenever either side is relaunched.
@objc(GarageLlamaEndpointReceiverProtocol)
public protocol GarageLlamaEndpointReceiverProtocol: NSObjectProtocol {
    /// Stores the endpoint of LlamaXPCService's anonymous listener for this process's llama clients.
    func setLlamaEndpoint(_ endpoint: NSXPCListenerEndpoint, with reply: @escaping (Bool, String?) -> Void)
}

/// The LlamaXPCService endpoint this process was handed (`GarageLlamaEndpointReceiverProtocol`).
///
/// `generation` goes up with every hand-over, so a client cached for an older endpoint (one from a
/// LlamaXPCService that has since been relaunched) knows to connect again.
public final class GarageLlamaEndpointStore: @unchecked Sendable {
    public static let shared = GarageLlamaEndpointStore()

    /// The self test that depends on the endpoint; a service re-runs it when an endpoint arrives.
    public static let dependentSelfTestName = "Llama Loader"

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

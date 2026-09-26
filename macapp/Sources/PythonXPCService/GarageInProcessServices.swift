import Foundation

/// XPC services the app runs in its own process instead of as helpers.
///
/// In the App Store build the app and each XPC service are sandboxed separately, and a folder the
/// user granted in the app cannot be handed to a service: a URL sent over NSXPC arrives without the
/// sandbox extension, so the service's `startAccessingSecurityScopedResource()` fails and every read
/// is denied. The sandboxed app therefore hosts the services that read or write user files (the
/// ingest service and GarageXPCService, the gRPC host that runs Scan and McpInstall) itself, behind
/// anonymous listeners it registers here. `makeConnection(serviceName:)` reaches a registered service
/// through its endpoint and any other service by name, so callers need not know where it runs.
public enum GarageInProcessServices {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var endpoints: [String: NSXPCListenerEndpoint] = [:]

    /// Routes connections for `serviceName` to `endpoint`, an anonymous listener in this process.
    public static func register(_ endpoint: NSXPCListenerEndpoint, forServiceName serviceName: String) {
        lock.lock()
        defer { lock.unlock() }
        endpoints[serviceName] = endpoint
    }

    /// Drops every registration (tests).
    public static func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        endpoints.removeAll()
    }

    /// Whether `serviceName` runs in this process rather than as its own helper.
    public static func isInProcess(_ serviceName: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return endpoints[serviceName] != nil
    }

    /// A new, not yet resumed connection to `serviceName`: to its in-process listener when one is
    /// registered, otherwise to the bundled XPC service of that name.
    public static func makeConnection(serviceName: String) -> NSXPCConnection {
        lock.lock()
        let endpoint = endpoints[serviceName]
        lock.unlock()
        if let endpoint {
            return NSXPCConnection(listenerEndpoint: endpoint)
        }
        return NSXPCConnection(serviceName: serviceName)
    }
}

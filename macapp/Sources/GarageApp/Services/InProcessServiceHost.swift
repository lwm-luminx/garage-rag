import Foundation
import OSLog
import GarageIngestXPCServiceCore
import GarageXPCServiceCore
import IngestClient
import PythonXPCService

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag", category: "InProcessServiceHost")

/// Runs the services that read or write user files inside the sandboxed app (`GarageInProcessServices`).
///
/// A folder the user grants in the App Store build is readable only by the app: the grant cannot be
/// handed to a separately sandboxed XPC service. So when sandboxed, the app hosts the ingest service
/// (Scan & Ingest) and GarageXPCService (the gRPC host behind Scan, AddSource and McpInstall) itself,
/// in the same Python it links through PythonXPCService.framework, and every connection to them reaches
/// these copies. The embed, MCP, llama and download services still run as their own helpers; they
/// never touch user files. The Developer ID build is not sandboxed and keeps every service out of process.
enum InProcessServiceHost {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var delegates: [GarageXPCServiceBase] = []

    /// The services hosted in the app, with the factory each is made by.
    static var hostedServices: [(name: String, make: () -> GarageXPCServiceBase)] {
        [
            (IngestXPCConstants.serviceName, makeGarageIngestXPCServiceDelegate),
            (GarageXPCConstants.serviceName, makeGarageXPCServiceDelegate),
        ]
    }

    /// Starts the hosted services once, when the app is sandboxed. Call before anything connects to them.
    static func startIfSandboxed(isSandboxed: Bool = GarageAppGroup.isSandboxed) {
        guard isSandboxed, !isRunningInTestEnvironment else { return }
        lock.lock()
        defer { lock.unlock() }
        guard delegates.isEmpty else { return }
        for service in hostedServices {
            let delegate = service.make()
            let endpoint = delegate.bootstrapInProcess()
            GarageInProcessServices.register(endpoint, forServiceName: service.name)
            delegates.append(delegate)
            logger.info("Hosting \(service.name, privacy: .public) in the app process")
        }
    }
}

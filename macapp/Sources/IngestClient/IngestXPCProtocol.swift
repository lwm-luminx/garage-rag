import Foundation
import PythonXPCService

/// Objective-C protocol for receiving progress updates and log entries from GarageIngestXPCService across XPC.
@objc(GarageIngestProgressReceiverProtocol)
public protocol GarageIngestProgressReceiverProtocol: GarageXPCLogReceiverProtocol {
    /// Receive JSON-serialized progress update.
    func didUpdateProgress(progressJson: String)

    /// Receive streaming log message from the XPC ingestion process.
    func didReceiveLog(message: String, level: Int32)
}

/// Objective-C protocol exposed by GarageIngestXPCService over NSXPC.
@objc(GarageIngestXPCServiceProtocol)
public protocol GarageIngestXPCServiceProtocol: GarageCommonXPCServiceProtocol, GarageFolderAccessReceiverProtocol {
    /// Ingest a source by slug (or "*") with JSON-serialized options.
    func ingestSource(slug: String, optionsJson: String, with reply: @escaping (Bool, String?) -> Void)

    /// Set root volume security-scoped bookmark data so the sandboxed XPC service can access the filesystem.
    /// The app's bookmarks are app-scoped and resolve to no access in this service when sandboxed; the
    /// app grants folders with `grantFolderAccess` (`GarageFolderAccessReceiverProtocol`) instead.
    func setRootVolumeBookmark(_ bookmarkData: Data, with reply: @escaping (Bool, String?) -> Void)

    /// Set security-scoped bookmark data for a specific source directory.
    func setSourceBookmark(path: String, bookmarkData: Data, with reply: @escaping (Bool, String?) -> Void)

    /// Revoke all active security-scoped volume and source access.
    func revokeAccess(with reply: @escaping (Bool) -> Void)

    /// Cancel any active ingestion in progress.
    func cancelIngest(with reply: @escaping (Bool) -> Void)

    /// Run full volume and source access tests inside the sandboxed XPC process.
    func testVolumeAccess(requestJson: String, with reply: @escaping (String?, Error?) -> Void)

    /// Configure database URL and environment options for XPC ingestion.
    func configureEnvironment(databaseUrl: String?, lmStudioApiToken: String?, with reply: @escaping (Bool, String?) -> Void)

    /// Set database URL and optional LM Studio API token via XPC.
    func setDatabaseURL(_ databaseUrl: String, lmStudioApiToken: String?, with reply: @escaping (Bool, String?) -> Void)
}

/// Objective-C protocol for Embed XPC Service communication. It receives the LlamaXPCService
/// endpoint because embedding with a llama_xpc model loads it on demand.
@objc(GarageEmbedXPCServiceProtocol)
public protocol GarageEmbedXPCServiceProtocol: GarageCommonXPCServiceProtocol, GarageLlamaEndpointReceiverProtocol {
    func embedTexts(_ texts: [String], model: String?, with reply: @escaping (Bool, String?) -> Void)
}

public enum IngestXPCConstants {
    public static let serviceName = "me.rickmark.garage-rag.ingest-xpc"
}

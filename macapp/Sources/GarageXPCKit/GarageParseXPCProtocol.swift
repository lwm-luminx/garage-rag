import Foundation

/// GarageParseXPCService: Garage's file readers (`garage_ingest_parse`) in a process of their own,
/// with no access to any file. Ingest reads a file's bytes where it holds the person's grants and
/// hands them over, so a reader that crashes or hangs on a hostile or broken file costs that file,
/// never the app, its database or the run (docs/plans/parser-isolation.md).
@objc public protocol GarageParseXPCProtocol {
    /// Reads `bytes` as `request` (`{"path", "readers"}`) says; replies with the reader's answer as
    /// JSON, or nil and why.
    func parse(_ request: String, bytes: Data, withReply reply: @escaping (String?, String?) -> Void)
}

public enum GarageParseXPC {
    /// The service's bundle identifier, as embedded in the app.
    public static let serviceName = "me.rickmark.garage-rag.parse-xpc"
}

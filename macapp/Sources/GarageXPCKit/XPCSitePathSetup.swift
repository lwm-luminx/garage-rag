import Foundation

/// Small helpers shared by the XPC services for the Python environment they embed.
///
/// The interpreter itself is started through the PyConfig API with `home`, `stdlib`, `lib-dynload` and
/// `site-packages` set up front (see `GaragePythonRuntime`); nothing here touches `sys.path`.
public struct XPCSitePathSetup {
    /// Normalizes database URLs to ensure psycopg is used.
    public static func ensurePsycopgDatabaseURL(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        
        if trimmed.hasPrefix("postgresql+psycopg://") {
            return trimmed
        }
        if trimmed.hasPrefix("postgresql://") {
            let suffix = trimmed.dropFirst("postgresql://".count)
            return "postgresql+psycopg://\(suffix)"
        }
        if trimmed.hasPrefix("postgres://") {
            let suffix = trimmed.dropFirst("postgres://".count)
            return "postgresql+psycopg://\(suffix)"
        }
        return trimmed
    }
}

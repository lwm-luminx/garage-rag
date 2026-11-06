import AppKit

/// Single source of truth for the corpus taxonomy the Python side enforces
/// (`data/sql/001_core.sql`'s CHECK constraints, mirrored by rust/garage-service).
/// Views that offer an "all" sentinel prepend it via `withAllSentinel`.
enum CorpusTaxonomy {
    static let corpusClasses = ["document", "code", "communication"]
    static let trustTiers = ["authored", "reference", "received"]

    static let allSentinel = "all"

    static func withAllSentinel(_ values: [String]) -> [String] {
        [allSentinel] + values
    }
}

extension NSPasteboard {
    /// Replace the pasteboard contents with a single plain string.
    func copy(_ string: String) {
        clearContents()
        setString(string, forType: .string)
    }
}

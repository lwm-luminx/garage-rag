import SwiftUI

// The Database page's rows as plain values: what the server row says, where the schema stands, the
// counts in the Contents box and the last backup. Kept out of the view so the wording can be tested
// without a window.

enum DatabasePagePresentation {
    static func plural(_ word: String, _ count: Int) -> String {
        count == 1 ? word : word + "s"
    }

    static func count(_ value: Int, _ word: String) -> String {
        "\(value.formatted()) \(plural(word, value))"
    }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

/// The server row: a tinted circle, a title and one line under it.
struct DatabaseHeadline: Equatable {
    let symbol: String
    let tint: Color
    let isActive: Bool
    let title: String
    let detail: String
    var detailIsError = false

    /// - Parameters:
    ///   - documents: documents in the corpus, from the last stats read; nil while unknown.
    ///   - sizeBytes: the database's size on disk; nil while unknown.
    init(
        status: PostgresStatus,
        port: Int,
        pendingMigrations: Int,
        isResetting: Bool,
        documents: Int?,
        sizeBytes: Int64?
    ) {
        if isResetting {
            self.init(
                symbol: "arrow.counterclockwise",
                tint: .red,
                isActive: true,
                title: "Resetting…",
                detail: "Stopping Garage's services and deleting the database."
            )
            return
        }
        switch status {
        case .running where pendingMigrations > 0, .needsMigration:
            let updates = pendingMigrations > 0
                ? DatabasePagePresentation.count(pendingMigrations, "schema update")
                : "Schema updates"
            self.init(
                symbol: "exclamationmark.triangle.fill",
                tint: .orange,
                isActive: true,
                title: "Needs a schema update",
                detail: "\(updates) to apply below before search and ingest can use it."
            )
        case .running:
            var parts = ["On this Mac, port \(port)"]
            if let documents {
                parts.append(DatabasePagePresentation.count(documents, "document"))
            }
            if let sizeBytes {
                parts.append(DatabasePagePresentation.bytes(sizeBytes))
            }
            self.init(symbol: "checkmark", tint: .green, isActive: true, title: "Running", detail: parts.joined(separator: " · "))
        case .starting:
            self.init(symbol: "cylinder.split.1x2", tint: .blue, isActive: true, title: "Starting…", detail: "Starting Postgres on port \(port)…")
        case .stopping:
            self.init(symbol: "cylinder.split.1x2", tint: .blue, isActive: true, title: "Stopping…", detail: "Stopping Postgres…")
        case .stopped:
            self.init(
                symbol: "cylinder.split.1x2",
                tint: .secondary,
                isActive: false,
                title: "Stopped",
                detail: "Search, ingest and the MCP server need the database running."
            )
        case .failed(let message):
            self.init(symbol: "xmark", tint: .red, isActive: true, title: "Couldn't start", detail: message, detailIsError: true)
        }
    }

    init(symbol: String, tint: Color, isActive: Bool, title: String, detail: String, detailIsError: Bool = false) {
        self.symbol = symbol
        self.tint = tint
        self.isActive = isActive
        self.title = title
        self.detail = detail
        self.detailIsError = detailIsError
    }
}

/// The Schema box's one row: whether every migration this build carries is applied.
struct DatabaseSchemaPresentation: Equatable {
    enum Action: Equatable {
        /// Apply Updates, prominent: there is something to apply.
        case apply
        /// Check Again, quiet: nothing to do but look again.
        case check
        /// No button: the database is not up, or updates are being applied.
        case hidden
    }

    let symbol: String
    let tint: Color
    let isActive: Bool
    let title: String
    let detail: String
    let action: Action

    init(status: PostgresStatus, pendingMigrations: [String], isApplying: Bool) {
        let isUp = status == .running || status == .needsMigration
        if isApplying {
            symbol = "arrow.triangle.2.circlepath"
            tint = .blue
            isActive = true
            title = "Applying schema updates…"
            detail = "Search and ingest wait until they are in."
            action = .hidden
        } else if !isUp {
            symbol = "cylinder.split.1x2"
            tint = .secondary
            isActive = false
            title = "Schema"
            detail = "Checked once the database is running."
            action = .hidden
        } else if !pendingMigrations.isEmpty {
            symbol = "exclamationmark.triangle.fill"
            tint = .orange
            isActive = true
            title = "\(DatabasePagePresentation.count(pendingMigrations.count, "update")) to apply"
            detail = "This version of Garage expects schema changes the database doesn't have yet. Your data is kept."
            action = .apply
        } else if status == .needsMigration {
            symbol = "exclamationmark.triangle.fill"
            tint = .orange
            isActive = true
            title = "Schema updates to apply"
            detail = "This version of Garage expects schema changes the database doesn't have yet. Your data is kept."
            action = .apply
        } else {
            symbol = "checkmark"
            tint = .green
            isActive = true
            title = "Schema up to date"
            detail = "Every migration this version of Garage carries is applied."
            action = .check
        }
    }
}

/// The Contents box: what the database holds, as the few numbers worth a glance.
struct DatabaseContentsPresentation: Equatable {
    struct Figure: Equatable, Identifiable {
        let label: String
        let value: String
        var note: String?
        var noteIsWarning = false
        var id: String { label }
    }

    let figures: [Figure]
    let isEmpty: Bool

    init(stats: CorpusStats, sizeBytes: Int64?) {
        var documents = Figure(label: "Documents", value: stats.documentsCount.formatted())
        if stats.documentsFailedCount > 0 {
            documents.note = "\(stats.documentsFailedCount.formatted()) failed"
            documents.noteIsWarning = true
        }
        var embedded = Figure(label: "Indexed", value: "—")
        if stats.totalChunks > 0, !stats.modelStats.isEmpty {
            let percent = Int((stats.embeddingProgressFraction * 100).rounded(.down))
            embedded = Figure(
                label: "Indexed",
                value: "\(percent)%",
                note: DatabasePagePresentation.count(stats.modelStats.count, "model")
            )
        } else if stats.modelStats.isEmpty {
            embedded.note = "No models"
        }
        var figures = [
            Figure(label: "Sources", value: stats.sourcesCount.formatted()),
            documents,
            Figure(label: "Chunks", value: stats.totalChunks.formatted()),
            embedded,
        ]
        if let sizeBytes {
            figures.append(Figure(label: "On Disk", value: DatabasePagePresentation.bytes(sizeBytes)))
        }
        self.figures = figures
        isEmpty = stats.documentsCount == 0 && stats.totalChunks == 0
    }
}

/// The last backup made from this Mac, kept in user defaults so Back Up… on the page and Back Up
/// First… in the reset sheet both count.
struct DatabaseBackupRecord: Equatable {
    static let dateKey = "garage.database.lastBackupAt"
    static let pathKey = "garage.database.lastBackupPath"

    let date: Date
    let url: URL

    static func record(_ url: URL, at date: Date = Date(), defaults: UserDefaults = .standard) {
        defaults.set(date.timeIntervalSince1970, forKey: dateKey)
        defaults.set(url.path, forKey: pathKey)
    }

    /// The record the two `@AppStorage` values describe, or nil when no backup was made.
    init?(timestamp: Double, path: String) {
        guard timestamp > 0, !path.isEmpty else { return nil }
        date = Date(timeIntervalSince1970: timestamp)
        url = URL(fileURLWithPath: path)
    }

    /// Whether the dump is still where it was written.
    var fileExists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}

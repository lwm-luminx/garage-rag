import Foundation
import PythonXPCService

/// One source registration: exactly what the AddSource RPC (and `garage add-source`) takes.
struct SourceSpec: Hashable, Sendable {
    var slug: String
    var root: String
    var kind: String
    var corpusClass: String
    var trust: String
}

/// The common local sources both the Status page's quick add and the Sources
/// page's preset menu offer, so the two cannot disagree on a slug or a title.
struct SourcePreset: Identifiable, Hashable, Sendable {
    let title: String
    let spec: SourceSpec

    var id: String { spec.slug }

    static let messages = SourcePreset(
        title: "Messages",
        spec: SourceSpec(slug: "apple-sms", root: "~/Library/Messages", kind: "sqlite", corpusClass: "communication", trust: "received")
    )
    static let mail = SourcePreset(
        title: "Apple Mail",
        spec: SourceSpec(slug: "apple-mail", root: "~/Library/Mail", kind: "maildir", corpusClass: "communication", trust: "received")
    )
    static let documents = SourcePreset(
        title: "Documents",
        spec: SourceSpec(slug: "documents", root: "~/Documents", kind: "filesystem", corpusClass: "document", trust: "authored")
    )
    static let downloads = SourcePreset(
        title: "Downloads",
        spec: SourceSpec(slug: "downloads", root: "~/Downloads", kind: "filesystem", corpusClass: "document", trust: "received")
    )
    static let desktop = SourcePreset(
        title: "Desktop",
        spec: SourceSpec(slug: "desktop", root: "~/Desktop", kind: "filesystem", corpusClass: "document", trust: "authored")
    )
    /// Rooted where Dropbox keeps its folder on this Mac (`DropboxFolder`), `~/Dropbox` when there is
    /// none, so the Sources menu still offers it.
    static let dropbox = SourcePreset(
        title: "Dropbox",
        spec: SourceSpec(slug: "dropbox", root: DropboxFolder.locate() ?? "~/Dropbox", kind: "filesystem", corpusClass: "document", trust: "authored")
    )

    /// Every preset, for the Sources page menu.
    static let all: [SourcePreset] = [messages, mail, documents, downloads, desktop, dropbox]

    /// The first-run quick-add set. Dropbox only when its folder was found; checked
    /// once per launch, not on every render of the Status page.
    static let quickAdd: [SourcePreset] = {
        var presets = [documents, messages]
        if DropboxFolder.locate() != nil {
            presets.append(dropbox)
        }
        return presets
    }()
}

extension AppState {
    /// Registers a source; a new source schedules maintenance so it gets indexed. Added while a scan
    /// or ingest runs, it is queued for its own scan once that run ends instead.
    @discardableResult
    func addSource(_ spec: SourceSpec) async -> Bool {
        let jobRunning = isScanning || isIngesting || isMaintenanceRunning
        let added = await runOperation(triggersMaintenance: !jobRunning) { try await $0.addSource(spec).message }
        if added, jobRunning {
            queueSourceScan(spec.slug)
        }
        return added
    }

    /// Registers a preset model (dims from the preset, else the known-model table),
    /// optionally making it the default for search and backfill.
    @discardableResult
    func registerModel(preset: ModelPresetEntry, makeDefault: Bool = false) async -> Bool {
        let dims = preset.effectiveDims
        let ref = preset.modelRef
        return await runOperation(triggersMaintenance: true) {
            try await $0.registerModel(
                slug: preset.slug,
                dims: dims > 0 ? dims : nil,
                modelRef: ref.flatMap { $0.isEmpty || $0 == preset.slug ? nil : $0 },
                provider: preset.provider ?? "llama_xpc",
                makeDefault: makeDefault
            ).message
        }
    }
}

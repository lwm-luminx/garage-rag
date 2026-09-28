import SwiftUI
import IngestClient
import PythonXPCService

// The Sources page's model, independent of the view: what each source row shows, what the page
// asks the person to fix at the top, and what the activity module says while the pipeline runs.
// Tests exercise it without a View.

/// The colour a status line or badge takes.
enum SourceTone: Equatable {
    case neutral
    case active
    case good
    case warning
    case bad

    var color: Color {
        switch self {
        case .neutral: .secondary
        case .active: .blue
        case .good: .green
        case .warning: .orange
        case .bad: .red
        }
    }
}

/// The pipeline's hold on one source, read from `AppState`.
enum SourceActivity: Equatable {
    case idle
    /// Waiting in a queue: the ingest of every source has not reached it, or it was added mid-run.
    case queued
    case scanning
    case ingesting(SourceIngestSnapshot)
    case removing
}

/// What a running ingest has done to one source so far.
struct SourceIngestSnapshot: Equatable {
    var phase: String
    /// 0…1 when the scan gave a total, nil when it did not (the bar is indeterminate then).
    var fraction: Double?
    var percent: String
    var seen: Int
    var total: Int
    var indexed: Int
    var skipped: Int
    var failed: Int
    var itemType: String
    var currentItem: String?
    var message: String
    var isCancelling: Bool
}

/// The outcome of the last ingest that covered a source, from `IngestService.progressBySource`.
struct SourceLastRun: Equatable {
    var indexed: Int
    var skipped: Int
    var failed: Int
    var error: String?
    var wasCancelled: Bool
}

/// One row on the Sources page.
struct SourceRowPresentation: Equatable {
    struct Badge: Equatable, Identifiable {
        let text: String
        let tone: SourceTone
        var id: String { text }
    }

    let symbol: String
    let tint: Color
    let title: String
    let path: String
    /// After the class and trust badges, which the view draws itself: how the source is set up and
    /// whether it can be read. What the pipeline is doing to it is the status line, not a badge.
    let badges: [Badge]
    let status: String
    let statusTone: SourceTone
    /// The bar's fraction: 1 when there is nothing left to index, so an up-to-date row keeps its
    /// full bar and the rows stay the same height. Nil only while a moving bar (`isIndeterminate`)
    /// stands in for it.
    let progress: Double?
    let isIndeterminate: Bool
    /// The counts at the right of the status line, in monospace.
    let counts: String?
    let currentItem: String?
    let error: String?
    /// Cancel replaces Scan & Ingest while the source is queued, scanned, ingested or removed.
    let showsCancel: Bool
    let cancelTitle: String
    let cancelDisabled: Bool

    static func make(
        source: RegisteredSource,
        access: SourcePathAccessResult?,
        activity: SourceActivity,
        lastRun: SourceLastRun?,
        isCancellingAll: Bool = false
    ) -> SourceRowPresentation {
        let symbol = Self.symbol(for: source)
        let tint = Self.tint(forCorpusClass: source.corpusClass)
        var badges: [Badge] = []

        // What the person set up, before what the pipeline is doing.
        if !source.enabled {
            badges.append(Badge(text: "DISABLED", tone: .neutral))
        }
        if source.includeCode {
            badges.append(Badge(text: "CODE", tone: .active))
        }
        // Declared in garage.json but not yet in the database: nothing indexes it until a sync. A
        // source only the database knows is the ordinary case for one added here, so it gets no badge.
        if source.origin == .config {
            badges.append(Badge(text: "NOT SYNCED", tone: .warning))
        }
        if let access, !access.isAccessible {
            if access.requiresTCCPermission || access.tccCategory != nil {
                badges.append(Badge(text: "PERMISSIONS NEEDED", tone: .warning))
            } else {
                badges.append(Badge(text: "UNREADABLE", tone: .bad))
            }
        }

        var status: String
        var tone: SourceTone
        var progress: Double? = nil
        var indeterminate = false
        var counts: String? = nil
        var currentItem: String? = nil
        var error: String? = nil
        var showsCancel = false
        var cancelTitle = "Cancel"
        var cancelDisabled = false

        let indexedFraction: Double? = source.expectedElements > 0
            ? min(1, Double(source.documentCount) / Double(max(source.documentCount, source.expectedElements)))
            : nil

        switch activity {
        case .removing:
            status = "Removing…"
            tone = .bad
            showsCancel = true
            cancelTitle = "Cancelling…"
            cancelDisabled = true
        case .ingesting(let run):
            status = run.isCancelling ? "Stopping…" : "Reading \(run.percent)"
            tone = .active
            progress = run.fraction
            indeterminate = run.fraction == nil
            counts = Self.runCounts(seen: run.seen, total: run.total, indexed: run.indexed, skipped: run.skipped, failed: run.failed, itemType: run.itemType)
            currentItem = run.currentItem.flatMap { $0.isEmpty ? nil : $0 }
            showsCancel = true
            cancelTitle = run.isCancelling ? "Cancelling…" : "Cancel"
            cancelDisabled = run.isCancelling || isCancellingAll
        case .scanning:
            status = "Counting items…"
            tone = .active
            indeterminate = true
            showsCancel = true
            cancelDisabled = isCancellingAll
        case .queued:
            status = "Waiting for its turn"
            tone = .neutral
            progress = indexedFraction
            counts = Self.indexedCounts(for: source)
            showsCancel = true
            cancelDisabled = isCancellingAll
        case .idle:
            if let access, !access.isAccessible {
                if access.requiresTCCPermission || access.tccCategory != nil {
                    status = "Needs permission to read this folder"
                    tone = .warning
                } else {
                    status = "Can't be read: \(access.statusDescription)"
                    tone = .bad
                }
                progress = indexedFraction
                counts = Self.indexedCounts(for: source)
            } else if let lastRun, let message = lastRun.error, !message.isEmpty {
                status = "Last ingest failed"
                tone = .bad
                error = message
                progress = indexedFraction
                counts = Self.indexedCounts(for: source)
            } else if !source.enabled {
                status = "Disabled: skipped by every scan and ingest"
                tone = .neutral
                counts = Self.indexedCounts(for: source)
            } else if source.documentCount == 0 {
                if source.expectedElements > 0 {
                    status = "\(source.expectedElements.formatted()) \(Self.plural("item", source.expectedElements)) found, none indexed yet"
                } else {
                    status = "Not indexed yet"
                }
                tone = .neutral
                progress = indexedFraction
            } else if source.expectedElements > source.documentCount {
                let remaining = source.expectedElements - source.documentCount
                status = "\(remaining.formatted()) \(Self.plural("item", remaining)) to go"
                tone = .active
                progress = indexedFraction
                counts = Self.indexedCounts(for: source)
            } else {
                status = "Up to date"
                tone = .good
                counts = Self.indexedCounts(for: source)
                if let lastRun, lastRun.wasCancelled {
                    status = "Last ingest was cancelled"
                    tone = .neutral
                }
            }
            // A row with nothing to count still draws a bar: full when it has documents, empty when not.
            if progress == nil {
                progress = source.documentCount > 0 ? 1 : 0
            }
        }

        return SourceRowPresentation(
            symbol: symbol,
            tint: tint,
            title: source.slug,
            path: source.root,
            badges: badges,
            status: status,
            statusTone: tone,
            progress: progress,
            isIndeterminate: indeterminate,
            counts: counts,
            currentItem: currentItem,
            error: error,
            showsCancel: showsCancel,
            cancelTitle: cancelTitle,
            cancelDisabled: cancelDisabled
        )
    }

    /// "1,180 of 1,204 documents" when a scan counted the folder, "1,204 documents" otherwise.
    static func indexedCounts(for source: RegisteredSource) -> String {
        if source.expectedElements > 0 {
            return "\(source.documentCount.formatted()) of \(source.expectedElements.formatted()) documents"
        }
        return "\(source.documentCount.formatted()) \(plural("document", source.documentCount))"
    }

    static func runCounts(seen: Int, total: Int, indexed: Int, skipped: Int, failed: Int, itemType: String) -> String {
        var parts: [String] = []
        if total > 0 {
            parts.append("\(seen.formatted()) of \(total.formatted()) \(itemType)")
        } else {
            parts.append("\(seen.formatted()) \(itemType)")
        }
        parts.append("\(indexed.formatted()) indexed")
        if skipped > 0 { parts.append("\(skipped.formatted()) skipped") }
        if failed > 0 { parts.append("\(failed.formatted()) failed") }
        return parts.joined(separator: " · ")
    }

    static func plural(_ noun: String, _ count: Int) -> String {
        count == 1 ? noun : noun + "s"
    }

    /// The glyph in the row's circle: what the source is, from its kind and, for a folder, where it points.
    static func symbol(for source: RegisteredSource) -> String {
        let root = source.root.lowercased()
        let slug = source.slug.lowercased()
        switch source.kind.lowercased() {
        case "sqlite":
            return slug.contains("sms") || root.contains("/messages") ? "message" : "cylinder"
        case "maildir":
            return "envelope"
        case "git":
            return "chevron.left.forwardslash.chevron.right"
        case "feed":
            return "dot.radiowaves.up.forward"
        default:
            break
        }
        let last = (root as NSString).lastPathComponent
        switch last {
        case "documents": return "doc.text"
        case "desktop": return "menubar.dock.rectangle"
        case "downloads": return "arrow.down.circle"
        case "dropbox": return "shippingbox"
        case "developer": return "chevron.left.forwardslash.chevron.right"
        default: break
        }
        if root.contains("mobile documents") || root.contains("icloud") { return "icloud" }
        if source.corpusClass == "code" { return "chevron.left.forwardslash.chevron.right" }
        return "folder"
    }

    /// The circle's colour follows the corpus class, as `CorpusClassBadge` does.
    static func tint(forCorpusClass corpusClass: String) -> Color {
        switch corpusClass.lowercased() {
        case "code": .purple
        case "communication": .green
        default: .blue
        }
    }
}

/// Something at the top of the page the person has to fix before every source can be read, with
/// the one action that fixes it beside it.
struct SourcesAttention: Equatable, Identifiable {
    enum Action: Equatable {
        case selectDisk
        case grantFolder(slug: String, path: String)
        case tccPrompt(TCCPermissionCategory, slug: String, path: String)
        case openPrivacySettings(TCCPermissionCategory)
        case recheck
    }

    struct Command: Equatable {
        let title: String
        let action: Action
    }

    let id: String
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let primary: Command
    let secondary: [Command]

    /// The disk-access problems first (nothing reads until they are fixed), then each source the last
    /// check could not read, in the order the page lists the sources.
    static func attentions(
        volumeStatus: VolumeAccessStatus,
        testResult: VolumeAccessTestResult?,
        sources: [RegisteredSource],
        sandboxed: Bool = GarageAppGroup.isSandboxed
    ) -> [SourcesAttention] {
        var items: [SourcesAttention] = []

        switch volumeStatus {
        case .notConfigured:
            items.append(SourcesAttention(
                id: "disk",
                symbol: "lock",
                tint: .orange,
                title: "Garage can't read outside its sandbox yet",
                detail: "Select your startup disk (Macintosh HD) once, and every source on it can be read.",
                primary: Command(title: "Select Disk…", action: .selectDisk),
                secondary: [Command(title: "Open Privacy Settings…", action: .openPrivacySettings(.fullDiskAccess))]
            ))
        case .accessDenied(let reason):
            items.append(SourcesAttention(
                id: "disk",
                symbol: "xmark",
                tint: .red,
                title: "Disk access was denied",
                detail: reason,
                primary: Command(title: "Select Disk…", action: .selectDisk),
                secondary: [Command(title: "Open Privacy Settings…", action: .openPrivacySettings(.fullDiskAccess))]
            ))
        case .staleBookmark(let url):
            items.append(SourcesAttention(
                id: "disk",
                symbol: "exclamationmark",
                tint: .orange,
                title: "Disk access needs re-granting",
                detail: "The saved permission for \(url.path) no longer works.",
                primary: Command(title: "Re-grant…", action: .selectDisk),
                secondary: []
            ))
        case .accessGranted:
            break
        }

        guard let testResult, !testResult.isAccessible else { return items }

        let bySlug = Dictionary(testResult.sourcePathResults.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
        let byPath = Dictionary(testResult.sourcePathResults.map { ($0.rawPath, $0) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<String> = []
        for source in sources {
            guard let access = bySlug[source.slug] ?? byPath[source.root], !access.isAccessible else { continue }
            guard seen.insert(access.id).inserted else { continue }
            let category = access.tccCategory ?? TCCPermissionCategory.detect(slug: source.slug, path: source.root)
            let name = Self.displayName(of: source)
            if let category, category.needsFullDiskAccess {
                // Mail and Messages: nothing reads them until Full Disk Access is on, so settings come
                // first; the folder grant follows only where the sandbox needs it too.
                var secondary: [Command] = []
                if sandboxed {
                    secondary.append(Command(title: "Grant Folder Access…", action: .grantFolder(slug: source.slug, path: source.root)))
                }
                secondary.append(Command(title: "Re-check", action: .recheck))
                items.append(SourcesAttention(
                    id: "source:\(source.slug)",
                    symbol: "lock",
                    tint: .orange,
                    title: "\(name) needs Full Disk Access",
                    detail: category.fullDiskAccessSteps(sandboxed: sandboxed),
                    primary: Command(title: "Open Privacy Settings…", action: .openPrivacySettings(category)),
                    secondary: secondary
                ))
            } else if access.requiresTCCPermission || access.tccCategory != nil, let category {
                items.append(SourcesAttention(
                    id: "source:\(source.slug)",
                    symbol: "lock",
                    tint: .orange,
                    title: "\(name) needs permission",
                    detail: access.tccHelpMessage ?? category.helpMessage,
                    primary: Command(title: "Grant Folder Access…", action: .grantFolder(slug: source.slug, path: source.root)),
                    secondary: [
                        Command(title: "Explain…", action: .tccPrompt(category, slug: source.slug, path: source.root)),
                        Command(title: "Open Privacy Settings…", action: .openPrivacySettings(category)),
                    ]
                ))
            } else {
                items.append(SourcesAttention(
                    id: "source:\(source.slug)",
                    symbol: "exclamationmark",
                    tint: .red,
                    title: "\(name) can't be read",
                    detail: "\(access.statusDescription) (\(source.root))",
                    primary: Command(title: "Grant Folder Access…", action: .grantFolder(slug: source.slug, path: source.root)),
                    secondary: category.map { [Command(title: "Open Privacy Settings…", action: .openPrivacySettings($0))] } ?? []
                ))
            }
        }

        // The check failed without naming a source (the startup disk itself, say).
        if items.isEmpty {
            items.append(SourcesAttention(
                id: "check",
                symbol: "exclamationmark",
                tint: .orange,
                title: "Some source folders can't be read",
                detail: testResult.message,
                primary: Command(title: "Re-check", action: .recheck),
                secondary: [Command(title: "Select Disk…", action: .selectDisk)]
            ))
        }
        return items
    }

    /// "Messages" for the Messages preset, the slug for everything else.
    static func displayName(of source: RegisteredSource) -> String {
        if let preset = SourcePreset.all.first(where: { $0.spec.slug == source.slug }) {
            return preset.title
        }
        return source.slug
    }
}

/// The module above the list while the pipeline runs, or right after it finished.
struct SourcesActivityPresentation: Equatable {
    enum Kind: Equatable {
        case scanning
        case ingesting
        case embedding
        case distilling
        case waiting
        case finished
        case cancelled
        case failed
    }

    let kind: Kind
    let symbol: String
    let tint: Color
    let title: String
    /// The counts line under the bar.
    let detail: String?
    let currentItem: String?
    let error: String?
    /// Nil hides the bar; with `isIndeterminate` the bar moves without a fraction.
    let progress: Double?
    let isIndeterminate: Bool
    let percent: String?

    var isRunning: Bool {
        switch kind {
        case .scanning, .ingesting, .embedding, .distilling, .waiting: true
        case .finished, .cancelled, .failed: false
        }
    }

    /// Where a whole-pipeline run is, for the "Scan › Read › Index › Glean" trail.
    var stage: MenuBarStatus.Stage? {
        switch kind {
        case .scanning: .scan
        case .ingesting: .ingest
        case .embedding: .embed
        case .distilling: .distill
        case .waiting, .finished, .cancelled, .failed: nil
        }
    }

    static func scanning(source: String, itemsSoFar: Int) -> SourcesActivityPresentation {
        let what = source == "*" ? "all sources" : source
        return SourcesActivityPresentation(
            kind: .scanning,
            symbol: "magnifyingglass",
            tint: .blue,
            title: "Scanning \(what)…",
            detail: itemsSoFar > 0 ? "\(itemsSoFar.formatted()) items so far" : "Counting what there is to index.",
            currentItem: nil,
            error: nil,
            progress: nil,
            isIndeterminate: true,
            percent: nil
        )
    }

    static func embedding() -> SourcesActivityPresentation {
        SourcesActivityPresentation(
            kind: .embedding,
            symbol: "point.3.connected.trianglepath.dotted",
            tint: .blue,
            title: "Indexing new chunks…",
            detail: "The Models page shows each model's progress.",
            currentItem: nil,
            error: nil,
            progress: nil,
            isIndeterminate: true,
            percent: nil
        )
    }

    static func distilling() -> SourcesActivityPresentation {
        SourcesActivityPresentation(
            kind: .distilling,
            symbol: "sparkles",
            tint: .blue,
            title: "Gleaning facts…",
            detail: "Documents no prompt has distilled yet. The Models page shows the run's log.",
            currentItem: nil,
            error: nil,
            progress: nil,
            isIndeterminate: true,
            percent: nil
        )
    }

    static func waiting(queued: [String]) -> SourcesActivityPresentation {
        let names = queued.prefix(3).joined(separator: ", ")
        let more = queued.count > 3 ? " and \(queued.count - 3) more" : ""
        return SourcesActivityPresentation(
            kind: .waiting,
            symbol: "clock",
            tint: .gray,
            title: "Waiting to scan \(names)\(more)",
            detail: "Each source gets its own scan and read once the current run ends.",
            currentItem: nil,
            error: nil,
            progress: nil,
            isIndeterminate: true,
            percent: nil
        )
    }

    /// `subject` is the source being ingested, or nil for a run over every source.
    static func ingesting(
        subject: String?,
        current: String?,
        fraction: Double,
        hasTotal: Bool,
        percent: String,
        counts: String,
        currentItem: String?,
        isCancelling: Bool
    ) -> SourcesActivityPresentation {
        var title: String
        if let subject {
            title = "Reading \(subject)"
        } else if let current, !current.isEmpty, current != "*" {
            title = "Reading all sources · \(current)"
        } else {
            title = "Reading all sources"
        }
        if isCancelling { title = "Stopping…" }
        return SourcesActivityPresentation(
            kind: .ingesting,
            symbol: "square.and.arrow.down",
            tint: .blue,
            title: title,
            detail: counts,
            currentItem: currentItem.flatMap { $0.isEmpty ? nil : $0 },
            error: nil,
            progress: hasTotal ? fraction : nil,
            isIndeterminate: !hasTotal,
            percent: hasTotal ? percent : nil
        )
    }

    static func ended(subject: String?, counts: String, wasCancelled: Bool, error: String?) -> SourcesActivityPresentation {
        let what = subject.map { "Ingest of \($0)" } ?? "Ingest"
        if let error, !error.isEmpty {
            return SourcesActivityPresentation(
                kind: .failed, symbol: "exclamationmark", tint: .red, title: "\(what) failed",
                detail: counts, currentItem: nil, error: error, progress: nil, isIndeterminate: false, percent: nil
            )
        }
        if wasCancelled {
            return SourcesActivityPresentation(
                kind: .cancelled, symbol: "xmark", tint: .orange, title: "\(what) cancelled",
                detail: counts, currentItem: nil, error: nil, progress: nil, isIndeterminate: false, percent: nil
            )
        }
        return SourcesActivityPresentation(
            kind: .finished, symbol: "checkmark", tint: .green, title: "\(what) finished",
            detail: counts, currentItem: nil, error: nil, progress: 1, isIndeterminate: false, percent: nil
        )
    }
}

/// The one-line summary of the corpus at the top of the list.
enum SourcesSummary {
    static func line(sources: Int, documents: Int) -> String {
        if sources == 0 { return "No sources yet" }
        let docs = "\(documents.formatted()) \(SourceRowPresentation.plural("document", documents))"
        return "\(docs) in \(sources.formatted()) \(SourceRowPresentation.plural("source", sources))"
    }
}

/// The name the form suggests for a source, from where it points and what it is, so people only
/// type one when they want something other than the folder's own name.
enum SourceSlugSuggestion {
    /// The preset's slug for a preset's location; otherwise the last path component (a file's name
    /// without its extension for a database; a feed's host), folded to `[a-z0-9-]` the way the setup
    /// assistant names a custom folder, and made unique against `taken` with "-2", "-3", ….
    static func suggest(root: String, kind: String, taken: Set<String>) -> String {
        let trimmed = root.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let preset = SourcePreset.all.first(where: { $0.spec.root == trimmed && $0.spec.kind == kind }) {
            return preset.spec.slug
        }
        let base: String
        switch kind.lowercased() {
        case "feed":
            let host = URL(string: trimmed)?.host ?? trimmed
            base = FirstRunSourceTemplate.slug(forFolderNamed: host)
        case "sqlite":
            let file = (trimmed as NSString).lastPathComponent
            let name = (file as NSString).deletingPathExtension
            base = FirstRunSourceTemplate.slug(forFolderNamed: name.isEmpty ? file : name)
        default:
            let path = trimmed.hasSuffix("/") && trimmed.count > 1 ? String(trimmed.dropLast()) : trimmed
            var name = (path as NSString).lastPathComponent
            if name == "~" || name.isEmpty || name == "/" { name = "home" }
            if name == "com~apple~CloudDocs" { name = "icloud-drive" }
            base = FirstRunSourceTemplate.slug(forFolderNamed: name)
        }
        return FirstRunSourceTemplate.uniqueSlug(base: base, taken: taken)
    }
}

import XCTest
@testable import GarageApp

final class SourcesPresentationTests: XCTestCase {

    private func source(
        slug: String = "notes",
        kind: String = "filesystem",
        root: String = "~/Notes",
        corpusClass: String = "document",
        enabled: Bool = true,
        includeCode: Bool = false,
        origin: RegisteredSource.SourceOrigin = .both,
        documents: Int = 0,
        expected: Int = 0
    ) -> RegisteredSource {
        RegisteredSource(
            slug: slug, kind: kind, root: root, corpusClass: corpusClass, enabled: enabled,
            includeCode: includeCode, origin: origin, documentCount: documents, expectedElements: expected
        )
    }

    private func access(
        slug: String = "notes",
        path: String = "~/Notes",
        readable: Bool,
        exists: Bool = true,
        category: TCCPermissionCategory? = nil,
        requiresTCC: Bool = false
    ) -> SourcePathAccessResult {
        SourcePathAccessResult(
            slug: slug, rawPath: path, resolvedPath: path, exists: exists, isReadable: readable,
            isDirectory: true, itemCount: readable ? 3 : nil, tccCategory: category, requiresTCCPermission: requiresTCC
        )
    }

    // MARK: - Rows

    func testAFreshSourceIsNotIndexedYet() {
        let row = SourceRowPresentation.make(source: source(), access: nil, activity: .idle, lastRun: nil)
        XCTAssertEqual(row.status, "Not indexed yet")
        XCTAssertEqual(row.statusTone, .neutral)
        XCTAssertEqual(row.progress, 0, "an empty bar keeps the row the height of the others")
        XCTAssertNil(row.counts)
        XCTAssertFalse(row.showsCancel)
        XCTAssertEqual(row.badges, [])
    }

    func testAScannedButUnindexedSourceSaysHowMuchThereIs() {
        let row = SourceRowPresentation.make(source: source(expected: 1_204), access: nil, activity: .idle, lastRun: nil)
        XCTAssertEqual(row.status, "1,204 items found, none indexed yet")
        XCTAssertEqual(row.progress, 0)
    }

    func testAPartlyIndexedSourceCountsWhatIsLeft() {
        let row = SourceRowPresentation.make(source: source(documents: 1_180, expected: 1_204), access: nil, activity: .idle, lastRun: nil)
        XCTAssertEqual(row.status, "24 items to go")
        XCTAssertEqual(row.statusTone, .active)
        XCTAssertEqual(row.counts, "1,180 of 1,204 documents")
        XCTAssertEqual(row.progress.map { ($0 * 1000).rounded() / 1000 }, 0.98)
    }

    func testAFullyIndexedSourceIsUpToDateWithAFullBar() {
        let row = SourceRowPresentation.make(source: source(documents: 1_204, expected: 1_204), access: nil, activity: .idle, lastRun: nil)
        XCTAssertEqual(row.status, "Up to date")
        XCTAssertEqual(row.statusTone, .good)
        XCTAssertEqual(row.progress, 1)
        XCTAssertEqual(row.counts, "1,204 of 1,204 documents")
    }

    func testMoreDocumentsThanTheScanExpectedStillReadsAsUpToDate() {
        let row = SourceRowPresentation.make(source: source(documents: 40, expected: 30), access: nil, activity: .idle, lastRun: nil)
        XCTAssertEqual(row.status, "Up to date")
    }

    func testAnUnscannedSourceWithDocumentsShowsTheCountAlone() {
        let row = SourceRowPresentation.make(source: source(documents: 1), access: nil, activity: .idle, lastRun: nil)
        XCTAssertEqual(row.status, "Up to date")
        XCTAssertEqual(row.counts, "1 document")
        XCTAssertEqual(row.progress, 1)
    }

    func testSetupBadgesNameWhatIsUnusualAboutASource() {
        let row = SourceRowPresentation.make(
            source: source(enabled: false, includeCode: true, origin: .config),
            access: nil, activity: .idle, lastRun: nil
        )
        XCTAssertEqual(row.badges.map(\.text), ["DISABLED", "CODE", "NOT SYNCED"])
        XCTAssertEqual(row.status, "Disabled: skipped by every scan and ingest")
    }

    func testASourceOnlyTheDatabaseKnowsGetsNoBadge() {
        let row = SourceRowPresentation.make(source: source(origin: .database), access: nil, activity: .idle, lastRun: nil)
        XCTAssertEqual(row.badges, [])
    }

    func testAProtectedFolderNeedsPermission() {
        let messages = source(slug: "apple-sms", kind: "sqlite", root: "~/Library/Messages", corpusClass: "communication")
        let denied = access(slug: "apple-sms", path: "~/Library/Messages", readable: false, category: .messages, requiresTCC: true)
        let row = SourceRowPresentation.make(source: messages, access: denied, activity: .idle, lastRun: nil)
        XCTAssertEqual(row.badges.map(\.text), ["PERMISSIONS NEEDED"])
        XCTAssertEqual(row.status, "Needs permission to read this folder")
        XCTAssertEqual(row.statusTone, .warning)
        XCTAssertEqual(row.symbol, "message")
        XCTAssertEqual(row.tint, .green)
    }

    func testAMissingFolderIsUnreadable() {
        let row = SourceRowPresentation.make(
            source: source(),
            access: access(readable: false, exists: false),
            activity: .idle, lastRun: nil
        )
        XCTAssertEqual(row.badges.map(\.text), ["UNREADABLE"])
        XCTAssertEqual(row.status, "Can't be read: Path does not exist")
        XCTAssertEqual(row.statusTone, .bad)
    }

    func testAReadableFolderGetsNoAccessBadge() {
        let row = SourceRowPresentation.make(source: source(), access: access(readable: true), activity: .idle, lastRun: nil)
        XCTAssertEqual(row.badges, [])
    }

    func testAFailedLastIngestShowsItsError() {
        let row = SourceRowPresentation.make(
            source: source(documents: 10, expected: 12),
            access: nil,
            activity: .idle,
            lastRun: SourceLastRun(indexed: 10, skipped: 0, failed: 2, error: "permission denied", wasCancelled: false)
        )
        XCTAssertEqual(row.status, "Last ingest failed")
        XCTAssertEqual(row.statusTone, .bad)
        XCTAssertEqual(row.error, "permission denied")
        XCTAssertEqual(row.counts, "10 of 12 documents")
    }

    func testAnIngestingSourceShowsItsRunAndCanBeCancelled() {
        let snapshot = SourceIngestSnapshot(
            phase: "ingest", fraction: 0.42, percent: "42%", seen: 1_204, total: 2_860, indexed: 1_180,
            skipped: 24, failed: 0, itemType: "documents", currentItem: "~/Notes/2024/retro.md",
            message: "", isCancelling: false
        )
        let row = SourceRowPresentation.make(source: source(), access: nil, activity: .ingesting(snapshot), lastRun: nil)
        XCTAssertEqual(row.status, "Reading 42%")
        XCTAssertEqual(row.statusTone, .active)
        XCTAssertEqual(row.progress, 0.42)
        XCTAssertFalse(row.isIndeterminate)
        XCTAssertEqual(row.counts, "1,204 of 2,860 documents · 1,180 indexed · 24 skipped")
        XCTAssertEqual(row.currentItem, "~/Notes/2024/retro.md")
        XCTAssertTrue(row.showsCancel)
        XCTAssertEqual(row.cancelTitle, "Cancel")
        XCTAssertFalse(row.cancelDisabled)
        XCTAssertEqual(row.badges, [], "the status line says it is ingesting; no badge repeats it")
    }

    func testAnIngestWithoutATotalMovesTheBarWithoutAFraction() {
        let snapshot = SourceIngestSnapshot(
            phase: "ingest", fraction: nil, percent: "0%", seen: 12, total: 0, indexed: 12,
            skipped: 0, failed: 1, itemType: "messages", currentItem: "", message: "", isCancelling: true
        )
        let row = SourceRowPresentation.make(source: source(), access: nil, activity: .ingesting(snapshot), lastRun: nil)
        XCTAssertEqual(row.status, "Stopping…")
        XCTAssertTrue(row.isIndeterminate)
        XCTAssertNil(row.progress)
        XCTAssertEqual(row.counts, "12 messages · 12 indexed · 1 failed")
        XCTAssertNil(row.currentItem, "an empty current item is not shown")
        XCTAssertEqual(row.cancelTitle, "Cancelling…")
        XCTAssertTrue(row.cancelDisabled)
    }

    func testQueuedScanningAndRemovingRows() {
        let queued = SourceRowPresentation.make(source: source(documents: 5, expected: 10), access: nil, activity: .queued, lastRun: nil)
        XCTAssertEqual(queued.status, "Waiting for its turn")
        XCTAssertEqual(queued.progress, 0.5)
        XCTAssertTrue(queued.showsCancel)

        let scanning = SourceRowPresentation.make(source: source(), access: nil, activity: .scanning, lastRun: nil)
        XCTAssertEqual(scanning.status, "Counting items…")
        XCTAssertTrue(scanning.isIndeterminate)
        XCTAssertTrue(scanning.showsCancel)

        let removing = SourceRowPresentation.make(source: source(), access: nil, activity: .removing, lastRun: nil)
        XCTAssertEqual(removing.status, "Removing…")
        XCTAssertEqual(removing.cancelTitle, "Cancelling…")
        XCTAssertTrue(removing.cancelDisabled)
    }

    func testCancelAllDisablesEveryRowsCancel() {
        let row = SourceRowPresentation.make(source: source(), access: nil, activity: .queued, lastRun: nil, isCancellingAll: true)
        XCTAssertTrue(row.cancelDisabled)
    }

    func testSymbolsFollowTheKindThenTheFolder() {
        XCTAssertEqual(SourceRowPresentation.symbol(for: source(kind: "maildir", root: "~/Library/Mail")), "envelope")
        XCTAssertEqual(SourceRowPresentation.symbol(for: source(kind: "git", root: "~/Developer/garage")), "chevron.left.forwardslash.chevron.right")
        XCTAssertEqual(SourceRowPresentation.symbol(for: source(kind: "sqlite", root: "~/data/app.db")), "cylinder")
        XCTAssertEqual(SourceRowPresentation.symbol(for: source(root: "~/Documents")), "doc.text")
        XCTAssertEqual(SourceRowPresentation.symbol(for: source(root: "~/Downloads")), "arrow.down.circle")
        XCTAssertEqual(SourceRowPresentation.symbol(for: source(root: "~/Dropbox")), "shippingbox")
        XCTAssertEqual(SourceRowPresentation.symbol(for: source(root: "~/Library/Mobile Documents/com~apple~CloudDocs")), "icloud")
        XCTAssertEqual(SourceRowPresentation.symbol(for: source(root: "~/src", corpusClass: "code")), "chevron.left.forwardslash.chevron.right")
        XCTAssertEqual(SourceRowPresentation.symbol(for: source(root: "~/Notes")), "folder")
    }

    func testTintFollowsTheCorpusClass() {
        XCTAssertEqual(SourceRowPresentation.tint(forCorpusClass: "document"), .blue)
        XCTAssertEqual(SourceRowPresentation.tint(forCorpusClass: "code"), .purple)
        XCTAssertEqual(SourceRowPresentation.tint(forCorpusClass: "communication"), .green)
    }

    // MARK: - Attention

    private func testResult(accessible: Bool, results: [SourcePathAccessResult], message: String = "") -> VolumeAccessTestResult {
        VolumeAccessTestResult(
            isAccessible: accessible, testedURL: URL(fileURLWithPath: "/"), rootItemsCount: 10,
            accessibleSubpaths: [], inaccessibleSubpaths: [], sourcePathResults: results,
            message: message, isSecurityScoped: true
        )
    }

    func testNothingToFixWhenEverythingReads() {
        let items = SourcesAttention.attentions(
            volumeStatus: .accessGranted(url: URL(fileURLWithPath: "/"), isSecurityScoped: true),
            testResult: testResult(accessible: true, results: [access(readable: true)]),
            sources: [source()]
        )
        XCTAssertTrue(items.isEmpty)
    }

    func testAnUnconfiguredSandboxAsksForTheDiskFirst() {
        let items = SourcesAttention.attentions(volumeStatus: .notConfigured, testResult: nil, sources: [])
        XCTAssertEqual(items.map(\.id), ["disk"])
        XCTAssertEqual(items.first?.primary.action, .selectDisk)
        XCTAssertEqual(items.first?.primary.title, "Select Disk…")
    }

    func testDeniedAndStaleAccessAreNamed() {
        let denied = SourcesAttention.attentions(volumeStatus: .accessDenied(reason: "no bookmark"), testResult: nil, sources: [])
        XCTAssertEqual(denied.first?.title, "Disk access was denied")
        XCTAssertEqual(denied.first?.detail, "no bookmark")

        let stale = SourcesAttention.attentions(volumeStatus: .staleBookmark(url: URL(fileURLWithPath: "/")), testResult: nil, sources: [])
        XCTAssertEqual(stale.first?.title, "Disk access needs re-granting")
        XCTAssertEqual(stale.first?.primary.title, "Re-grant…")
    }

    func testMailAndMessagesLeadWithFullDiskAccessAndTheStoreBuildAddsTheFolder() {
        let messages = source(slug: "apple-sms", kind: "sqlite", root: "~/Library/Messages", corpusClass: "communication")
        let mail = source(slug: "apple-mail", kind: "maildir", root: "~/Library/Mail", corpusClass: "communication")
        let results = [
            access(slug: "apple-sms", path: "~/Library/Messages", readable: false, category: .messages, requiresTCC: true),
            access(slug: "apple-mail", path: "~/Library/Mail", readable: false, category: .mail, requiresTCC: true),
        ]
        let store = SourcesAttention.attentions(
            volumeStatus: .accessGranted(url: URL(fileURLWithPath: "/"), isSecurityScoped: true),
            testResult: testResult(accessible: false, results: results),
            sources: [mail, messages],
            sandboxed: true
        )
        XCTAssertEqual(store.map(\.title), ["Apple Mail needs Full Disk Access", "Messages needs Full Disk Access"], "in the order the sources are listed")
        XCTAssertEqual(store.map(\.primary.action), [.openPrivacySettings(.mail), .openPrivacySettings(.messages)])
        XCTAssertEqual(store.first?.secondary.map(\.action), [
            .grantFolder(slug: "apple-mail", path: "~/Library/Mail"),
            .recheck,
        ])
        XCTAssertEqual(store.first?.detail, TCCPermissionCategory.mail.fullDiskAccessSteps(sandboxed: true))
        XCTAssertTrue(store.first?.detail.contains("quit and reopen Garage") ?? false)
        XCTAssertTrue(store.first?.detail.contains("select your startup disk") ?? false)

        let developerID = SourcesAttention.attentions(
            volumeStatus: .accessGranted(url: URL(fileURLWithPath: "/"), isSecurityScoped: false),
            testResult: testResult(accessible: false, results: results),
            sources: [messages],
            sandboxed: false
        )
        XCTAssertEqual(developerID.first?.primary.action, .openPrivacySettings(.messages))
        XCTAssertEqual(developerID.first?.secondary.map(\.action), [.recheck], "no sandbox, so no folder to grant")
        XCTAssertFalse(developerID.first?.detail.contains("startup disk") ?? true)
    }

    func testAnotherProtectedFolderStillGetsAFolderGrant() {
        let documents = source(slug: "documents", kind: "folder", root: "~/Documents", corpusClass: "document")
        let items = SourcesAttention.attentions(
            volumeStatus: .accessGranted(url: URL(fileURLWithPath: "/"), isSecurityScoped: true),
            testResult: testResult(accessible: false, results: [
                access(slug: "documents", path: "~/Documents", readable: false, category: .documents, requiresTCC: true),
            ]),
            sources: [documents],
            sandboxed: true
        )
        XCTAssertEqual(items.first?.title, "Documents needs permission", "named by its preset's title")
        XCTAssertEqual(items.first?.primary.action, .grantFolder(slug: "documents", path: "~/Documents"))
        XCTAssertEqual(items.first?.secondary.map(\.action), [
            .tccPrompt(.documents, slug: "documents", path: "~/Documents"),
            .openPrivacySettings(.documents),
        ])
    }
    func testAnUnreadableSourceIsReportedWithItsPath() {
        let items = SourcesAttention.attentions(
            volumeStatus: .accessGranted(url: URL(fileURLWithPath: "/"), isSecurityScoped: false),
            testResult: testResult(accessible: false, results: [access(readable: false, exists: false)]),
            sources: [source()]
        )
        XCTAssertEqual(items.map(\.title), ["notes can't be read"])
        XCTAssertEqual(items.first?.detail, "Path does not exist (~/Notes)")
        XCTAssertEqual(items.first?.primary.action, .grantFolder(slug: "notes", path: "~/Notes"))
    }

    func testAFailedCheckThatNamesNoSourceStillShowsUp() {
        let items = SourcesAttention.attentions(
            volumeStatus: .accessGranted(url: URL(fileURLWithPath: "/"), isSecurityScoped: true),
            testResult: testResult(accessible: false, results: [], message: "Root volume not readable"),
            sources: [source()]
        )
        XCTAssertEqual(items.map(\.id), ["check"])
        XCTAssertEqual(items.first?.detail, "Root volume not readable")
        XCTAssertEqual(items.first?.primary.action, .recheck)
    }

    func testDiskProblemsComeBeforeSourceProblems() {
        let items = SourcesAttention.attentions(
            volumeStatus: .staleBookmark(url: URL(fileURLWithPath: "/")),
            testResult: testResult(accessible: false, results: [access(readable: false)]),
            sources: [source()]
        )
        XCTAssertEqual(items.map(\.id), ["disk", "source:notes"])
    }

    // MARK: - Activity

    func testScanningNamesTheSourceAndCountsSoFar() {
        let all = SourcesActivityPresentation.scanning(source: "*", itemsSoFar: 0)
        XCTAssertEqual(all.title, "Scanning all sources…")
        XCTAssertEqual(all.detail, "Counting what there is to index.")
        XCTAssertTrue(all.isIndeterminate)
        XCTAssertTrue(all.isRunning)

        let one = SourcesActivityPresentation.scanning(source: "notes", itemsSoFar: 1_204)
        XCTAssertEqual(one.title, "Scanning notes…")
        XCTAssertEqual(one.detail, "1,204 items so far")
    }

    func testIngestingOneSourceOrAll() {
        let one = SourcesActivityPresentation.ingesting(
            subject: "notes", current: "notes", fraction: 0.42, hasTotal: true, percent: "42%",
            counts: "1,204 of 2,860 documents · 1,180 indexed", currentItem: "~/Notes/a.md", isCancelling: false
        )
        XCTAssertEqual(one.title, "Reading notes")
        XCTAssertEqual(one.percent, "42%")
        XCTAssertEqual(one.progress, 0.42)
        XCTAssertEqual(one.currentItem, "~/Notes/a.md")

        let all = SourcesActivityPresentation.ingesting(
            subject: nil, current: "mail", fraction: 0.1, hasTotal: false, percent: "10%",
            counts: "12 messages · 12 indexed", currentItem: "", isCancelling: false
        )
        XCTAssertEqual(all.title, "Reading all sources · mail")
        XCTAssertNil(all.percent, "no percentage without a total")
        XCTAssertTrue(all.isIndeterminate)
        XCTAssertNil(all.currentItem)

        let stopping = SourcesActivityPresentation.ingesting(
            subject: "notes", current: "notes", fraction: 0.5, hasTotal: true, percent: "50%",
            counts: "", currentItem: nil, isCancelling: true
        )
        XCTAssertEqual(stopping.title, "Stopping…")
    }

    func testTheEndOfARunKeepsItsOutcome() {
        let finished = SourcesActivityPresentation.ended(subject: "notes", counts: "2 documents · 2 indexed", wasCancelled: false, error: nil)
        XCTAssertEqual(finished.kind, .finished)
        XCTAssertEqual(finished.title, "Ingest of notes finished")
        XCTAssertEqual(finished.progress, 1)
        XCTAssertFalse(finished.isRunning)

        let cancelled = SourcesActivityPresentation.ended(subject: nil, counts: "", wasCancelled: true, error: nil)
        XCTAssertEqual(cancelled.kind, .cancelled)
        XCTAssertEqual(cancelled.title, "Ingest cancelled")

        let failed = SourcesActivityPresentation.ended(subject: "mail", counts: "", wasCancelled: true, error: "disk full")
        XCTAssertEqual(failed.kind, .failed, "an error outranks a cancellation")
        XCTAssertEqual(failed.title, "Ingest of mail failed")
        XCTAssertEqual(failed.error, "disk full")
    }

    func testEachRunningStepNamesItsStageOnTheTrail() {
        XCTAssertEqual(SourcesActivityPresentation.scanning(source: "*", itemsSoFar: 0).stage, .scan)
        XCTAssertEqual(SourcesActivityPresentation.embedding().stage, .embed)
        let distilling = SourcesActivityPresentation.distilling()
        XCTAssertEqual(distilling.stage, .distill)
        XCTAssertTrue(distilling.isRunning)
        XCTAssertTrue(distilling.isIndeterminate)
        XCTAssertNil(SourcesActivityPresentation.waiting(queued: ["notes"]).stage)
        XCTAssertNil(SourcesActivityPresentation.ended(subject: nil, counts: "", wasCancelled: false, error: nil).stage)
    }

    func testWaitingListsTheFirstFewQueuedSources() {
        let few = SourcesActivityPresentation.waiting(queued: ["notes", "mail"])
        XCTAssertEqual(few.title, "Waiting to scan notes, mail")
        let many = SourcesActivityPresentation.waiting(queued: ["a", "b", "c", "d", "e"])
        XCTAssertEqual(many.title, "Waiting to scan a, b, c and 2 more")
    }

    // MARK: - Suggested names

    func testTheNameComesFromTheFolder() {
        XCTAssertEqual(SourceSlugSuggestion.suggest(root: "~/Notes", kind: "filesystem", taken: []), "notes")
        XCTAssertEqual(SourceSlugSuggestion.suggest(root: "/Users/rick/My Notes (2024)/", kind: "filesystem", taken: []), "my-notes-2024")
        XCTAssertEqual(SourceSlugSuggestion.suggest(root: "~/Developer/garage-rag", kind: "git", taken: []), "garage-rag")
        XCTAssertEqual(SourceSlugSuggestion.suggest(root: "~/Library/Mobile Documents/com~apple~CloudDocs", kind: "filesystem", taken: []), "icloud-drive")
        XCTAssertEqual(SourceSlugSuggestion.suggest(root: "~", kind: "filesystem", taken: []), "home")
        XCTAssertEqual(SourceSlugSuggestion.suggest(root: "   ", kind: "filesystem", taken: []), "")
    }

    func testTheNameFollowsTheKind() {
        XCTAssertEqual(SourceSlugSuggestion.suggest(root: "/tmp/fixtures/chat.db", kind: "sqlite", taken: []), "chat")
        XCTAssertEqual(SourceSlugSuggestion.suggest(root: "https://example.com/feed.xml", kind: "feed", taken: []), "example-com")
        XCTAssertEqual(SourceSlugSuggestion.suggest(root: "~/Library/Mail", kind: "maildir", taken: []), "apple-mail")
    }

    func testAPresetLocationKeepsThePresetsName() {
        XCTAssertEqual(SourceSlugSuggestion.suggest(root: "~/Library/Messages", kind: "sqlite", taken: []), "apple-sms")
        XCTAssertEqual(SourceSlugSuggestion.suggest(root: "~/Documents", kind: "filesystem", taken: []), "documents")
        XCTAssertEqual(SourceSlugSuggestion.suggest(root: "~/Documents", kind: "git", taken: []), "documents", "a different kind still names the folder")
    }

    func testATakenNameGetsANumber() {
        XCTAssertEqual(SourceSlugSuggestion.suggest(root: "~/Notes", kind: "filesystem", taken: ["notes"]), "notes-2")
        XCTAssertEqual(SourceSlugSuggestion.suggest(root: "~/Notes", kind: "filesystem", taken: ["notes", "notes-2"]), "notes-3")
    }

    // MARK: - Summary

    func testTheSummaryLineCountsDocumentsAndSources() {
        XCTAssertEqual(SourcesSummary.line(sources: 0, documents: 0), "No sources yet")
        XCTAssertEqual(SourcesSummary.line(sources: 1, documents: 1), "1 document in 1 source")
        XCTAssertEqual(SourcesSummary.line(sources: 3, documents: 1_234), "1,234 documents in 3 sources")
    }
}

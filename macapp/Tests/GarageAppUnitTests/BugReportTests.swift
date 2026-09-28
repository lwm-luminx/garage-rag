import XCTest
@testable import GarageApp

final class BugReportTests: XCTestCase {

    private let redactor = BugReportRedactor(homeDirectory: "/Users/testuser", userName: "testuser")

    // MARK: - Redaction

    func testRedactsHomeDirectoryToTilde() {
        XCTAssertEqual(
            redactor.redact("failed to open /Users/testuser/Documents/taxes.pdf"),
            "failed to open ~/Documents/taxes.pdf"
        )
    }

    func testHomeDirectoryMatchIsBounded() {
        // A different account whose name merely starts with ours must not be
        // rewritten into the running user's home.
        XCTAssertEqual(
            redactor.redact("/Users/testuser2/notes.md"),
            "/Users/<user>/notes.md"
        )
    }

    func testRedactsOtherUsersHomeDirectories() {
        XCTAssertEqual(
            redactor.redact("copied from /Users/alice/Desktop"),
            "copied from /Users/<user>/Desktop"
        )
    }

    func testRedactsEmailAddresses() {
        XCTAssertEqual(
            redactor.redact("author rick.mark@example.com committed"),
            "author <email redacted> committed"
        )
    }

    func testRedactsConnectionStringPassword() {
        XCTAssertEqual(
            redactor.redact("postgresql://garage:hunter2@127.0.0.1:14824/garage-rag"),
            "postgresql://garage:<redacted>@127.0.0.1:14824/garage-rag"
        )
    }

    func testRedactsConnectionStringPasswordWithDriverSuffix() {
        // PostgresService.connectionURL() hands out the SQLAlchemy form, and
        // that is what actually reaches the logs.
        XCTAssertEqual(
            redactor.redact("postgresql+psycopg://garage:hunter2@localhost:14824/garage-rag"),
            "postgresql+psycopg://garage:<redacted>@localhost:14824/garage-rag"
        )
    }

    func testRedactsKeyValueSecrets() {
        XCTAssertEqual(redactor.redact("api_key: sk-abc123"), "api_key=<redacted>")
        XCTAssertEqual(redactor.redact("token=\"ghp_deadbeef\""), "token=<redacted>")
    }

    func testRedactsJSONEscapedConnectionString() {
        XCTAssertEqual(
            redactor.redact("{\"database_url\":\"postgresql+psycopg:\\/\\/garage:hunter2@localhost:14824\\/garage-rag\"}"),
            "{\"database_url\":\"postgresql+psycopg:\\/\\/garage:<redacted>@localhost:14824\\/garage-rag\"}"
        )
    }

    func testRedactsPrefixedAndJSONSecrets() {
        XCTAssertEqual(redactor.redact("PGPASSWORD=hunter2 psql"), "PGPASSWORD=<redacted> psql")
        XCTAssertEqual(redactor.redact("LMSTUDIO_API_KEY=abc123"), "LMSTUDIO_API_KEY=<redacted>")
        XCTAssertEqual(redactor.redact("{\"password\": \"hunter2\", \"n\": 1}"), "{\"password=<redacted>, \"n\": 1}")
        XCTAssertEqual(redactor.redact("\"lmstudio_api_token\":\"tok123\""), "\"lmstudio_api_token=<redacted>")
        // Counts and limits named after tokens are not secrets.
        XCTAssertEqual(redactor.redact("max_tokens=512"), "max_tokens=512")
    }

    func testRedactsBearerAndBasicCredentials() {
        XCTAssertFalse(redactor.redact("Authorization: Bearer sk-abcdef123456").contains("sk-abcdef123456"))
        XCTAssertFalse(redactor.redact("Authorization: Basic Z2FyYWdlOmh1bnRlcjI=").contains("Z2FyYWdlOmh1bnRlcjI="))
        XCTAssertEqual(redactor.redact("basic search mode"), "basic search mode")
    }

    func testRedactsBareUserName() {
        XCTAssertEqual(redactor.redact("ingest failed for testuser"), "ingest failed for <user>")
    }

    func testShortUserNameIsNotRedacted() {
        // Matching a two-letter name inside ordinary words would destroy more
        // text than it protects.
        let short = BugReportRedactor(homeDirectory: "/Users/ab", userName: "ab")
        XCTAssertEqual(short.redact("absolutely fine"), "absolutely fine")
    }

    func testRedactionLeavesOrdinaryTextAlone() {
        let text = "Ingest stopped after 1,204 of 8,000 documents (bge-m3, 1024 dims)."
        XCTAssertEqual(redactor.redact(text), text)
    }

    // MARK: - Draft

    func testDraftRequiresTitleAndDescription() {
        var draft = BugReportDraft()
        XCTAssertFalse(draft.isSubmittable)
        draft.title = "Ingest stalls"
        XCTAssertFalse(draft.isSubmittable)
        draft.whatHappened = "It stops at 40%."
        XCTAssertTrue(draft.isSubmittable)
    }

    func testDraftIgnoresWhitespaceOnlyInput() {
        var draft = BugReportDraft()
        draft.title = "   "
        draft.whatHappened = "\n\t "
        XCTAssertFalse(draft.isSubmittable)
    }

    func testEffectiveTitleFallsBackToFirstLineOfDescription() {
        var draft = BugReportDraft()
        draft.whatHappened = "Search returns nothing\nafter a backfill"
        XCTAssertEqual(draft.effectiveTitle, "Search returns nothing")
    }

    func testEffectiveTitleHasAFinalFallback() {
        XCTAssertEqual(BugReportDraft().effectiveTitle, "Bug report")
    }

    // MARK: - Composition

    private func draft(includeDiagnostics: Bool = false, includeLogs: Bool = false) -> BugReportDraft {
        var draft = BugReportDraft()
        draft.title = "Ingest stalls"
        draft.whatHappened = "Ingest stops at 40% and never finishes."
        draft.includeDiagnostics = includeDiagnostics
        draft.includeLogs = includeLogs
        return draft
    }

    func testComposeOmitsEmptyOptionalSections() {
        let body = BugReportComposer.compose(draft: draft(), diagnostics: [], redactor: redactor)
        XCTAssertTrue(body.contains("## What happened"))
        XCTAssertFalse(body.contains("## Steps to reproduce"))
        XCTAssertFalse(body.contains("## Expected behavior"))
        XCTAssertFalse(body.contains("## Diagnostics"))
    }

    func testComposeAlwaysEndsWithTheRedactionNotice() {
        let body = BugReportComposer.compose(draft: draft(), diagnostics: [], redactor: redactor)
        XCTAssertTrue(body.hasSuffix(BugReportComposer.footer))
    }

    func testComposeRedactsTheUsersOwnProse() {
        var draft = self.draft()
        draft.whatHappened = "Broke while indexing /Users/testuser/Notes"
        let body = BugReportComposer.compose(draft: draft, diagnostics: [], redactor: redactor)
        XCTAssertTrue(body.contains("~/Notes"))
        XCTAssertFalse(body.contains("/Users/testuser"))
    }

    func testComposeRendersDiagnosticsAsTables() {
        let sections = [DiagnosticSection("Application", [DiagnosticField("Garage", "Version 0.9")])]
        let body = BugReportComposer.compose(
            draft: draft(includeDiagnostics: true),
            diagnostics: sections,
            redactor: redactor
        )
        XCTAssertTrue(body.contains("## Diagnostics"))
        XCTAssertTrue(body.contains("### Application"))
        XCTAssertTrue(body.contains("| Garage | Version 0.9 |"))
    }

    func testDiagnosticsAreOmittedWhenTheToggleIsOff() {
        let sections = [DiagnosticSection("Application", [DiagnosticField("Garage", "Version 0.9")])]
        let body = BugReportComposer.compose(draft: draft(), diagnostics: sections, redactor: redactor)
        XCTAssertFalse(body.contains("## Diagnostics"))
    }

    func testDiagnosticValuesAreRedactedAndKeptInTheirCell() {
        let sections = [DiagnosticSection("Database", [
            DiagnosticField("URL", "postgresql://garage:hunter2@127.0.0.1:14824/db"),
            DiagnosticField("Note", "a | b\nsecond line"),
        ])]
        let body = BugReportComposer.compose(
            draft: draft(includeDiagnostics: true),
            diagnostics: sections,
            redactor: redactor
        )
        XCTAssertFalse(body.contains("hunter2"))
        XCTAssertTrue(body.contains("| Note | a \\| b second line |"))
    }

    func testComposeAttachesLogsInACollapsedBlock() {
        let lines = [
            LogLine(stream: .stderr, text: "FATAL: could not open /Users/testuser/db", source: "Postgres"),
        ]
        let body = BugReportComposer.compose(
            draft: draft(includeLogs: true),
            diagnostics: [],
            logLines: lines,
            redactor: redactor
        )
        XCTAssertTrue(body.contains("<details>"))
        XCTAssertTrue(body.contains("```text"))
        XCTAssertTrue(body.contains("~/db"))
        XCTAssertFalse(body.contains("/Users/testuser"))
    }

    func testLogsAreOmittedWhenTheToggleIsOff() {
        let lines = [LogLine(stream: .stdout, text: "hello", source: "App")]
        let body = BugReportComposer.compose(draft: draft(), diagnostics: [], logLines: lines, redactor: redactor)
        XCTAssertFalse(body.contains("<details>"))
    }

    // MARK: - Title and document

    func testTitleIsRedacted() {
        var draft = self.draft()
        draft.title = "Crash indexing /Users/testuser/Private"
        XCTAssertEqual(
            BugReportComposer.title(for: draft, redactor: redactor),
            "Crash indexing ~/Private"
        )
    }

    func testDocumentRedactsTheTitleItPrefixes() {
        // The summary is free text and is exported alongside the body, so it
        // must not be the one field that escapes redaction.
        var draft = self.draft()
        draft.title = "Fails for rick@example.com under /Users/testuser/Notes"
        let document = BugReportComposer.document(draft: draft, diagnostics: [], redactor: redactor)

        XCTAssertTrue(document.hasPrefix("# Fails for <email redacted> under ~/Notes\n\n"))
        XCTAssertFalse(document.contains("/Users/testuser"))
        XCTAssertFalse(document.contains("rick@example.com"))
    }

    func testDocumentIsTheBodyPlusTheTitle() {
        let draft = self.draft()
        let body = BugReportComposer.compose(draft: draft, diagnostics: [], redactor: redactor)
        let document = BugReportComposer.document(draft: draft, diagnostics: [], redactor: redactor)
        XCTAssertTrue(document.hasSuffix(body))
    }

    // MARK: - Log digest

    func testLogDigestKeepsTheMostRecentLines() {
        let lines = (0..<10).map { LogLine(stream: .stdout, text: "line \($0)", source: "App") }
        let selected = BugReportLogDigest.select(from: lines, limit: 3)
        XCTAssertEqual(selected.map(\.text), ["line 7", "line 8", "line 9"])
    }

    func testLogDigestKeepsEverythingUnderTheLimit() {
        let lines = [LogLine(stream: .stdout, text: "only", source: "App")]
        XCTAssertEqual(BugReportLogDigest.select(from: lines, limit: 10).count, 1)
    }

    func testLogDigestFormatIncludesLevel() {
        let line = LogLine(stream: .stderr, text: "ERROR: boom", source: "App")
        let formatted = BugReportLogDigest.format([line], redactor: redactor)
        XCTAssertTrue(formatted.contains("[ERROR]"))
        XCTAssertTrue(formatted.contains("boom"))
    }

    // MARK: - GitHub hand-off

    func testNewIssueURLCarriesTitleBodyAndLabel() throws {
        let url = try XCTUnwrap(BugReportDestination.newIssueURL(title: "Ingest stalls", body: "It stops."))
        let absolute = url.absoluteString
        XCTAssertTrue(absolute.hasPrefix("https://github.com/rickmark/garage-rag/issues/new?"))
        XCTAssertTrue(absolute.contains("title=Ingest%20stalls"))
        XCTAssertTrue(absolute.contains("body=It%20stops."))
        XCTAssertTrue(absolute.contains("labels=bug"))
    }

    func testNewIssueURLEncodesPlusAndAmpersand() throws {
        // `+` has to survive: a form decoder on the far side would otherwise
        // turn every one in a code snippet into a space.
        let url = try XCTUnwrap(BugReportDestination.newIssueURL(title: "a+b", body: "x & y+z"))
        XCTAssertTrue(url.absoluteString.contains("title=a%2Bb"))
        XCTAssertTrue(url.absoluteString.contains("body=x%20%26%20y%2Bz"))
    }

    func testNewIssueURLTruncatesOversizedBodies() throws {
        let body = String(repeating: "log line with detail\n", count: 5000)
        let url = try XCTUnwrap(BugReportDestination.newIssueURL(title: "Big", body: body))
        XCTAssertLessThanOrEqual(url.absoluteString.count, BugReportDestination.maxURLLength)
        let decoded = try XCTUnwrap(url.absoluteString.removingPercentEncoding)
        XCTAssertTrue(decoded.contains("Report truncated"))
    }

    func testNewIssueURLLeavesShortBodiesIntact() throws {
        let url = try XCTUnwrap(BugReportDestination.newIssueURL(title: "Small", body: "short"))
        let decoded = try XCTUnwrap(url.absoluteString.removingPercentEncoding)
        XCTAssertFalse(decoded.contains("Report truncated"))
    }

    func testTitleIsClampedToGitHubsLimit() throws {
        let url = try XCTUnwrap(BugReportDestination.newIssueURL(title: String(repeating: "t", count: 500), body: "b"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let title = try XCTUnwrap(components.queryItems?.first { $0.name == "title" }?.value)
        XCTAssertEqual(title.count, BugReportDestination.maxTitleLength)
    }

    // MARK: - Diagnostics collection

    @MainActor
    func testCollectedDiagnosticsDescribeTheEnvironmentWithoutCorpusContent() {
        let appState = AppState()
        appState.setRegisteredSourcesForTesting([
            RegisteredSource(slug: "private-notes", root: "/Users/testuser/Notes", corpusClass: "document"),
            RegisteredSource(slug: "work-repo", root: "/Users/testuser/src", corpusClass: "code"),
        ])

        let sections = BugReportDiagnosticsCollector.collect(
            appState: appState,
            version: AppVersionInfo(shortVersion: "0.9", build: "42")
        )

        XCTAssertTrue(sections.contains { $0.title == "Application" })
        XCTAssertTrue(sections.contains { $0.title == "Corpus" })

        let application = sections.first { $0.title == "Application" }
        XCTAssertEqual(application?.fields.first { $0.label == "Garage" }?.value, "Version 0.9 (build 42)")

        let corpus = sections.first { $0.title == "Corpus" }
        XCTAssertEqual(corpus?.fields.first { $0.label == "Sources" }?.value, "2")
        XCTAssertEqual(corpus?.fields.first { $0.label == "Corpus classes" }?.value, "code: 1, document: 1")

        // Source slugs and roots name the user's folders; counts do not.
        let rendered = sections.flatMap { $0.fields }.map { "\($0.label) \($0.value)" }.joined(separator: "\n")
        XCTAssertFalse(rendered.contains("private-notes"))
        XCTAssertFalse(rendered.contains("/Users/testuser"))
    }
}

import Foundation

// MARK: - Destinations

/// Where a bug report can end up. Garage never posts anything by itself: the
/// report is composed locally and the user either copies it, saves it, or
/// opens a pre-filled issue form in their browser.
enum BugReportLinks {
    static let newIssue = URL(string: "https://github.com/rickmark/garage-rag/issues/new")!
    static let issues = URL(string: "https://github.com/rickmark/garage-rag/issues")!
    static let troubleshooting = URL(string: "https://garagerag.app/support/troubleshooting.html")!
    /// Security problems are disclosed privately, never on the public tracker.
    static let securityEmail = URL(string: "mailto:security@rickmark.com?subject=Garage%20security%20report")!
}

extension Notification.Name {
    /// Posted to open the bug report sheet on demand (Help menu, menu bar, Logs).
    static let garageShowBugReport = Notification.Name("me.rickmark.garage-rag.showBugReport")
}

// MARK: - Redaction

/// Scrubs personal identifiers out of text headed for a bug report.
///
/// Garage indexes personal documents, code, and communications, so anything
/// that can leave the machine has to be treated as public. Log lines are the
/// realistic leak: they carry absolute paths (which embed the user's short
/// name), the occasional address parsed out of a document, and connection
/// strings. Redaction is deliberately over-eager — a mangled log line costs a
/// round trip, a leaked home directory costs the user's privacy.
struct BugReportRedactor: Sendable {
    /// Replacement for the running user's home directory.
    static let homePlaceholder = "~"
    static let userPlaceholder = "<user>"
    static let emailPlaceholder = "<email redacted>"
    static let secretPlaceholder = "<redacted>"

    let homeDirectory: String
    let userName: String

    init(homeDirectory: String = NSHomeDirectory(), userName: String = NSUserName()) {
        self.homeDirectory = homeDirectory
        self.userName = userName
    }

    /// Applies every redaction rule, in an order chosen so the most specific
    /// match wins (the running user's own home directory before other users').
    func redact(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text

        // The user's own home directory, collapsed to `~` the way the rest of
        // the UI shows paths. Matched up to a path boundary so `/Users/sam`
        // does not rewrite the unrelated `/Users/sam2`.
        if homeDirectory.count > 1,
           let home = Self.regex(NSRegularExpression.escapedPattern(for: homeDirectory) + "(?![A-Za-z0-9._-])") {
            result = home.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: Self.homePlaceholder
            )
        }

        for rule in Self.rules {
            result = rule.apply(to: result)
        }

        // Any remaining bare occurrence of the short user name. Very short
        // names are skipped: matching a two-letter name inside unrelated words
        // would destroy more than it protects.
        if userName.count >= 3, let escaped = Self.regex("\\b\(NSRegularExpression.escapedPattern(for: userName))\\b") {
            result = escaped.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: Self.userPlaceholder
            )
        }

        return result
    }

    /// A single regex-based substitution. `NSRegularExpression` is documented
    /// as thread-safe for matching, which is all this does with it.
    private struct Rule: @unchecked Sendable {
        let expression: NSRegularExpression
        let template: String

        func apply(to text: String) -> String {
            expression.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: template
            )
        }
    }

    private static let rules: [Rule] = [
        // Other accounts' home directories.
        rule("/Users/[A-Za-z0-9._-]+", "/Users/\(userPlaceholder)"),
        // Passwords embedded in a Postgres connection string. The scheme may
        // carry a SQLAlchemy driver suffix: `PostgresService.connectionURL()`
        // hands out `postgresql+psycopg://`, and that is the form that reaches
        // the logs, so missing it would leave the password in the report.
        // The slashes may be JSON-escaped (`:\/\/`) when the URL sits inside a JSON value.
        rule("(postgres(?:ql)?(?:\\+[A-Za-z0-9_.-]+)?:(?:\\\\?/){2}[^:/@\\s]+:)[^@\\s]+@", "$1\(secretPlaceholder)@"),
        // HTTP credentials: `Bearer <token>`, and `Authorization: Basic <credentials>` (only after
        // the header name, since "basic" is an ordinary word).
        rule("(?i)\\b(bearer)\\s+[A-Za-z0-9._~+/=-]{8,}", "$1 \(secretPlaceholder)"),
        rule("(?i)(authorization\\s*:\\s*basic)\\s+[A-Za-z0-9+/=]+", "$1 \(secretPlaceholder)"),
        // key=value / key: value secrets, including prefixed names (PGPASSWORD, LMSTUDIO_API_KEY,
        // lmstudio_api_token) and JSON members ("password": "…").
        rule("(?i)\\b([A-Za-z0-9_]*(?:password|passwd|token|secret|api[-_]?key)|authorization)\\b\"?\\s*[=:]\\s*\"?[^\\s\"&,]+\"?",
             "$1=\(secretPlaceholder)"),
        // E-mail addresses (senders in Mail/Messages logs, git author lines).
        rule("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", emailPlaceholder),
    ].compactMap { $0 }

    private static func rule(_ pattern: String, _ template: String) -> Rule? {
        guard let expression = regex(pattern) else { return nil }
        return Rule(expression: expression, template: template)
    }

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern)
    }
}

// MARK: - Diagnostics

/// One `label: value` pair inside the diagnostics block.
struct DiagnosticField: Equatable, Sendable {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

/// A titled group of diagnostic fields, rendered as one Markdown table.
struct DiagnosticSection: Equatable, Sendable {
    let title: String
    let fields: [DiagnosticField]

    init(_ title: String, _ fields: [DiagnosticField]) {
        self.title = title
        self.fields = fields
    }
}

// MARK: - Draft

/// What the user typed, plus what they agreed to attach. Kept separate from
/// the composed report so the preview can be regenerated on every keystroke.
struct BugReportDraft: Equatable, Sendable {
    var title: String = ""
    var whatHappened: String = ""
    var stepsToReproduce: String = ""
    var expectedBehavior: String = ""
    var includeDiagnostics: Bool = true
    /// Off by default: logs are the one attachment that can quote file paths
    /// and document names, so including them is an explicit choice.
    var includeLogs: Bool = false
    var logSource: LogsView.LogSource = .garage

    /// A report needs a title and some description of the problem; everything
    /// else is optional.
    var isSubmittable: Bool {
        !title.trimmed.isEmpty && !whatHappened.trimmed.isEmpty
    }

    /// Falls back to the description when the user left the title empty, so a
    /// copied report is never headless.
    var effectiveTitle: String {
        let trimmed = title.trimmed
        if !trimmed.isEmpty { return trimmed }
        let firstLine = whatHappened.trimmed.split(separator: "\n").first.map { String($0) } ?? ""
        return firstLine.isEmpty ? "Bug report" : String(firstLine.prefix(120))
    }
}

// MARK: - Log digest

/// Selects and formats the log lines attached to a report.
enum BugReportLogDigest {
    static let defaultLimit = 120

    /// Keeps the most recent `limit` lines, in chronological order — the tail
    /// is where the failure the user just hit actually is.
    static func select(from lines: [LogLine], limit: Int = defaultLimit) -> [LogLine] {
        guard limit > 0 else { return [] }
        guard lines.count > limit else { return lines }
        return Array(lines.suffix(limit))
    }

    static func format(_ lines: [LogLine], redactor: BugReportRedactor) -> String {
        lines.map { line in
            let stamp = timeFormatter.string(from: line.date)
            let text = redactor.redact(line.rawText ?? line.text)
            return "\(stamp) [\(line.level.rawValue.uppercased())] \(text)"
        }
        .joined(separator: "\n")
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

// MARK: - Composition

/// Turns a draft plus its attachments into the Markdown body that gets copied,
/// saved, or handed to GitHub's new-issue form.
enum BugReportComposer {
    static let footer = """
        _Filed from Garage's in-app bug reporter. Home directory, user name, e-mail addresses, and \
        secrets were redacted automatically — please read through the report before posting it._
        """

    static func compose(
        draft: BugReportDraft,
        diagnostics: [DiagnosticSection],
        logLines: [LogLine] = [],
        redactor: BugReportRedactor = BugReportRedactor()
    ) -> String {
        var blocks: [String] = []

        blocks.append(section("What happened", body: draft.whatHappened, redactor: redactor))
        blocks.append(section("Steps to reproduce", body: draft.stepsToReproduce, redactor: redactor))
        blocks.append(section("Expected behavior", body: draft.expectedBehavior, redactor: redactor))

        if draft.includeDiagnostics, !diagnostics.isEmpty {
            let tables = diagnostics
                .map { table(for: $0, redactor: redactor) }
                .filter { !$0.isEmpty }
            if !tables.isEmpty {
                blocks.append("## Diagnostics\n\n" + tables.joined(separator: "\n\n"))
            }
        }

        if draft.includeLogs, !logLines.isEmpty {
            let body = BugReportLogDigest.format(logLines, redactor: redactor)
            blocks.append("""
                <details>
                <summary>Recent \(draft.logSource.rawValue) logs (\(logLines.count) lines)</summary>

                ```text
                \(body)
                ```

                </details>
                """)
        }

        blocks.append("---\n\n" + footer)
        return blocks.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// The report's title, redacted like every other piece of user-typed text.
    /// The summary field is free text — a user will paste a path or an address
    /// into it as readily as into the description — and it is exported
    /// alongside the body, so it cannot be the one thing that skips the
    /// redactor.
    static func title(for draft: BugReportDraft, redactor: BugReportRedactor = BugReportRedactor()) -> String {
        redactor.redact(draft.effectiveTitle)
    }

    /// Title and body as one Markdown document. This is what the preview
    /// renders and what Copy and Save produce, so nothing reaches the
    /// clipboard or the disk that the user has not already read.
    static func document(
        draft: BugReportDraft,
        diagnostics: [DiagnosticSection],
        logLines: [LogLine] = [],
        redactor: BugReportRedactor = BugReportRedactor()
    ) -> String {
        "# \(title(for: draft, redactor: redactor))\n\n"
            + compose(draft: draft, diagnostics: diagnostics, logLines: logLines, redactor: redactor)
    }

    private static func section(_ heading: String, body: String, redactor: BugReportRedactor) -> String {
        let trimmed = body.trimmed
        guard !trimmed.isEmpty else { return "" }
        return "## \(heading)\n\n\(redactor.redact(trimmed))"
    }

    private static func table(for section: DiagnosticSection, redactor: BugReportRedactor) -> String {
        guard !section.fields.isEmpty else { return "" }
        var rows = ["### \(section.title)", "", "| | |", "| --- | --- |"]
        for field in section.fields {
            rows.append("| \(escapeCell(field.label)) | \(escapeCell(redactor.redact(field.value))) |")
        }
        return rows.joined(separator: "\n")
    }

    /// Keeps a value containing `|` or a newline from breaking out of its cell.
    private static func escapeCell(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "|", with: "\\|")
    }
}

// MARK: - GitHub hand-off

/// Builds the pre-filled GitHub issue URL.
enum BugReportDestination {
    /// GitHub answers 414 for very long request URIs; browsers have their own
    /// ceilings. Well under both, with room for the repo path and title.
    static let maxURLLength = 7500
    static let maxTitleLength = 200
    static let truncationNotice = "\n\n_Report truncated to fit in a URL — use “Copy Report” for the full text._"

    /// A `…/issues/new` URL with the title and body pre-filled. The body is
    /// trimmed (and says so) rather than producing a URL the browser or GitHub
    /// would reject outright.
    static func newIssueURL(title: String, body: String, maxLength: Int = maxURLLength) -> URL? {
        guard let full = url(title: title, body: body) else { return nil }
        if full.absoluteString.count <= maxLength { return full }

        var kept = body
        while !kept.isEmpty {
            guard let candidate = url(title: title, body: kept + truncationNotice) else { return nil }
            let overflow = candidate.absoluteString.count - maxLength
            if overflow <= 0 { return candidate }
            // Each dropped character removes at least one character of the
            // percent-encoded query, so this always makes progress.
            let drop = max(1, overflow / 3)
            kept = String(kept.dropLast(min(drop, kept.count)))
        }
        return url(title: title, body: truncationNotice)
    }

    private static func url(title: String, body: String) -> URL? {
        var components = URLComponents(url: BugReportLinks.newIssue, resolvingAgainstBaseURL: false)
        let items: [(name: String, value: String)] = [
            (name: "title", value: String(title.prefix(maxTitleLength))),
            (name: "body", value: body),
            (name: "labels", value: "bug"),
        ]
        // Encoded by hand rather than via `queryItems`: URLComponents leaves
        // `+` unescaped, and a form decoder on the far side would turn every
        // `+` in a log line or code snippet into a space.
        components?.percentEncodedQuery = items.compactMap { item -> String? in
            guard let encoded = item.value.addingPercentEncoding(withAllowedCharacters: queryAllowed) else {
                return nil
            }
            return "\(item.name)=\(encoded)"
        }
        .joined(separator: "&")
        return components?.url
    }

    private static let queryAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}

// MARK: - Helpers

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

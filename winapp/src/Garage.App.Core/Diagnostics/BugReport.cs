using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using Garage.App.Core.Logging;
using Garage.App.Core.Operations;

namespace Garage.App.Core.Diagnostics;

/// <summary>
/// Where a bug report can end up. Garage never posts anything by itself: the report is composed
/// here, and the person copies it, saves it, or opens a pre-filled issue form in their browser.
/// </summary>
public static class BugReportLinks
{
    /// <summary>A new issue.</summary>
    public static Uri NewIssue { get; } = new("https://github.com/rickmark/garage-rag/issues/new");

    /// <summary>The tracker.</summary>
    public static Uri Issues { get; } = new("https://github.com/rickmark/garage-rag/issues");

    /// <summary>The troubleshooting guide.</summary>
    public static Uri Troubleshooting { get; } = new("https://garagerag.app/support/troubleshooting.html");

    /// <summary>Security problems are disclosed privately, never on the public tracker.</summary>
    public static Uri SecurityEmail { get; } = new("mailto:security@rickmark.com?subject=Garage%20security%20report");
}

/// <summary>
/// Scrubs personal identifiers out of text headed for a bug report (the Mac's <c>BugReportRedactor</c>).
/// Garage indexes personal documents, code and communications, so anything that can leave the PC is
/// treated as public. Over-eager on purpose: a mangled log line costs a round trip, a leaked home
/// folder costs the person's privacy.
/// </summary>
public sealed partial class BugReportRedactor(string homeDirectory, string userName)
{
    /// <summary>The running user's home folder becomes this.</summary>
    public const string HomePlaceholder = "~";

    /// <summary>Other user names become this.</summary>
    public const string UserPlaceholder = "<user>";

    /// <summary>E-mail addresses become this.</summary>
    public const string EmailPlaceholder = "<email redacted>";

    /// <summary>Secrets become this.</summary>
    public const string SecretPlaceholder = "<redacted>";

    /// <summary>The running account's.</summary>
    public static BugReportRedactor ForThisAccount() =>
        new(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), Environment.UserName);

    /// <summary>The home folder this redactor folds to <c>~</c>.</summary>
    public string HomeDirectory { get; } = homeDirectory ?? "";

    /// <summary>The account name it removes.</summary>
    public string UserName { get; } = userName ?? "";

    /// <summary>Applies every rule, most specific first (this account's home before other accounts').</summary>
    public string Redact(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        if (text.Length == 0)
        {
            return text;
        }
        string result = text;
        string home = HomeDirectory.TrimEnd('\\', '/');
        if (home.Length > 3)
        {
            // The home folder in each spelling a log carries it: backslashes, forward slashes, and the
            // doubled backslashes of a JSON string; bounded so C:\Users\sam leaves C:\Users\sam2 alone.
            foreach (string spelling in new[] { home, home.Replace('\\', '/'), home.Replace("\\", @"\\", StringComparison.Ordinal) }.Distinct(StringComparer.Ordinal))
            {
                result = Regex.Replace(result, Regex.Escape(spelling) + "(?![A-Za-z0-9._-])", HomePlaceholder.Replace("$", "$$", StringComparison.Ordinal),
                    RegexOptions.IgnoreCase, TimeSpan.FromSeconds(1));
            }
        }
        result = WindowsHome().Replace(result, "$1" + UserPlaceholder);
        result = MacHome().Replace(result, "/Users/" + UserPlaceholder);
        result = ConnectionPassword().Replace(result, "$1" + SecretPlaceholder + "@");
        result = Bearer().Replace(result, "$1 " + SecretPlaceholder);
        result = Basic().Replace(result, "$1 " + SecretPlaceholder);
        result = KeyValueSecret().Replace(result, "$1=" + SecretPlaceholder);
        result = Email().Replace(result, EmailPlaceholder);
        // Any remaining bare account name; very short names are skipped, since matching two letters
        // inside ordinary words would destroy more than it protects.
        if (UserName.Length >= 3)
        {
            result = Regex.Replace(result, @"\b" + Regex.Escape(UserName) + @"\b", UserPlaceholder, RegexOptions.IgnoreCase, TimeSpan.FromSeconds(1));
        }
        return result;
    }

    // Other accounts' profile folders, on any drive and in either slash.
    [GeneratedRegex(@"([A-Za-z]:(?:\\\\|\\|/)Users(?:\\\\|\\|/))(?!<user>)[A-Za-z0-9._ -]+?(?=\\|/|""|\s|$)", RegexOptions.IgnoreCase)]
    private static partial Regex WindowsHome();

    // Mac paths that reach a log through a shared garage.json.
    [GeneratedRegex("/Users/[A-Za-z0-9._-]+")]
    private static partial Regex MacHome();

    // Passwords in a Postgres URL, with a SQLAlchemy driver suffix and JSON-escaped slashes.
    [GeneratedRegex(@"(postgres(?:ql)?(?:\+[A-Za-z0-9_.-]+)?:(?:\\?/){2}[^:/@\s]+:)[^@\s]+@")]
    private static partial Regex ConnectionPassword();

    [GeneratedRegex(@"(?i)\b(bearer)\s+[A-Za-z0-9._~+/=-]{8,}")]
    private static partial Regex Bearer();

    [GeneratedRegex(@"(?i)(authorization\s*:\s*basic)\s+[A-Za-z0-9+/=]+")]
    private static partial Regex Basic();

    // key=value and key: value secrets, prefixed names (PGPASSWORD, GARAGE_GRPC_TOKEN) and JSON members.
    [GeneratedRegex(@"(?i)\b([A-Za-z0-9_]*(?:password|passwd|token|secret|api[-_]?key)|authorization)\b""?\s*[=:]\s*""?[^\s""&,]+""?")]
    private static partial Regex KeyValueSecret();

    [GeneratedRegex(@"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")]
    private static partial Regex Email();
}

/// <summary>One <c>label: value</c> pair in the diagnostics.</summary>
public sealed record DiagnosticField(string Label, string Value);

/// <summary>A titled group of diagnostics, rendered as one Markdown table.</summary>
public sealed record DiagnosticSection(string Title, IReadOnlyList<DiagnosticField> Fields);

/// <summary>What the person typed, and what they agreed to attach.</summary>
public sealed record BugReportDraft
{
    /// <summary>The summary.</summary>
    public string Title { get; init; } = "";

    /// <summary>What happened.</summary>
    public string WhatHappened { get; init; } = "";

    /// <summary>Steps to reproduce.</summary>
    public string StepsToReproduce { get; init; } = "";

    /// <summary>What they expected.</summary>
    public string ExpectedBehavior { get; init; } = "";

    /// <summary>Attach the diagnostics (on by default: they hold no corpus content).</summary>
    public bool IncludeDiagnostics { get; init; } = true;

    /// <summary>
    /// Attach recent log lines. Off by default: logs are the one attachment that can quote file paths
    /// and document names, so including them is an explicit choice.
    /// </summary>
    public bool IncludeLogs { get; init; }

    /// <summary>Which log's lines.</summary>
    public string LogSource { get; init; } = "app";

    /// <summary>A report needs a title and some description of the problem.</summary>
    public bool IsSubmittable => Title.Trim().Length > 0 && WhatHappened.Trim().Length > 0;

    /// <summary>The title, else the description's first line, so a copied report is never headless.</summary>
    public string EffectiveTitle
    {
        get
        {
            string title = Title.Trim();
            if (title.Length > 0)
            {
                return title;
            }
            string first = WhatHappened.Trim().Split('\n')[0].Trim();
            return first.Length == 0 ? "Bug report" : first[..Math.Min(120, first.Length)];
        }
    }
}

/// <summary>Picks and formats the log lines attached to a report.</summary>
public static class BugReportLogDigest
{
    /// <summary>Lines attached.</summary>
    public const int DefaultLimit = 120;

    /// <summary>The most recent lines, oldest first: the tail is where the failure is.</summary>
    public static IReadOnlyList<LogLine> Select(IReadOnlyList<LogLine> lines, int limit = DefaultLimit)
    {
        ArgumentNullException.ThrowIfNull(lines);
        return limit <= 0 ? [] : lines.Count <= limit ? lines : [.. lines.Skip(lines.Count - limit)];
    }

    /// <summary>"14:02:11 [ERROR] …", redacted.</summary>
    public static string Format(IEnumerable<LogLine> lines, BugReportRedactor redactor)
    {
        ArgumentNullException.ThrowIfNull(redactor);
        return string.Join('\n', lines.Select(line =>
            string.Create(CultureInfo.InvariantCulture, $"{line.Timestamp:HH:mm:ss} [{line.Level.Name().ToUpperInvariant()}] {redactor.Redact(line.Text)}")));
    }
}

/// <summary>Turns a draft and its attachments into the Markdown that is copied, saved, or handed to GitHub.</summary>
public static class BugReportComposer
{
    /// <summary>The note every report ends with.</summary>
    public const string Footer = "_Filed from Garage's in-app bug reporter. Home folder, user name, e-mail addresses, and "
        + "secrets were redacted automatically — please read through the report before posting it._";

    /// <summary>The report's body.</summary>
    public static string Compose(BugReportDraft draft, IReadOnlyList<DiagnosticSection> diagnostics, IReadOnlyList<LogLine> logLines, BugReportRedactor redactor)
    {
        ArgumentNullException.ThrowIfNull(draft);
        ArgumentNullException.ThrowIfNull(diagnostics);
        ArgumentNullException.ThrowIfNull(logLines);
        ArgumentNullException.ThrowIfNull(redactor);
        List<string> blocks =
        [
            Section("What happened", draft.WhatHappened, redactor),
            Section("Steps to reproduce", draft.StepsToReproduce, redactor),
            Section("Expected behavior", draft.ExpectedBehavior, redactor),
        ];
        if (draft.IncludeDiagnostics && diagnostics.Count > 0)
        {
            List<string> tables = [.. diagnostics.Select(d => Table(d, redactor)).Where(t => t.Length > 0)];
            if (tables.Count > 0)
            {
                blocks.Add("## Diagnostics\n\n" + string.Join("\n\n", tables));
            }
        }
        if (draft.IncludeLogs && logLines.Count > 0)
        {
            blocks.Add(string.Create(CultureInfo.InvariantCulture,
                $"<details>\n<summary>Recent {draft.LogSource} logs ({logLines.Count} lines)</summary>\n\n```text\n{BugReportLogDigest.Format(logLines, redactor)}\n```\n\n</details>"));
        }
        blocks.Add("---\n\n" + Footer);
        return string.Join("\n\n", blocks.Where(b => b.Length > 0));
    }

    /// <summary>The title, redacted like everything else typed: a path or an address is pasted into it as readily as into the description.</summary>
    public static string Title(BugReportDraft draft, BugReportRedactor redactor)
    {
        ArgumentNullException.ThrowIfNull(draft);
        ArgumentNullException.ThrowIfNull(redactor);
        return redactor.Redact(draft.EffectiveTitle);
    }

    /// <summary>Title and body as one document: what the preview shows and Copy and Save produce.</summary>
    public static string Document(BugReportDraft draft, IReadOnlyList<DiagnosticSection> diagnostics, IReadOnlyList<LogLine> logLines, BugReportRedactor redactor) =>
        $"# {Title(draft, redactor)}\n\n" + Compose(draft, diagnostics, logLines, redactor);

    private static string Section(string heading, string body, BugReportRedactor redactor)
    {
        string trimmed = body.Trim();
        return trimmed.Length == 0 ? "" : $"## {heading}\n\n{redactor.Redact(trimmed)}";
    }

    private static string Table(DiagnosticSection section, BugReportRedactor redactor)
    {
        if (section.Fields.Count == 0)
        {
            return "";
        }
        var rows = new StringBuilder();
        rows.Append("### ").Append(section.Title).Append("\n\n| | |\n| --- | --- |");
        foreach (DiagnosticField field in section.Fields)
        {
            rows.Append("\n| ").Append(EscapeCell(field.Label)).Append(" | ").Append(EscapeCell(redactor.Redact(field.Value))).Append(" |");
        }
        return rows.ToString();
    }

    // Keeps a value with "|" or a newline from breaking out of its cell.
    private static string EscapeCell(string value) =>
        value.Replace("\r\n", " ", StringComparison.Ordinal).Replace("\n", " ", StringComparison.Ordinal).Replace("|", "\\|", StringComparison.Ordinal);
}

/// <summary>Builds the pre-filled GitHub issue URL.</summary>
public static class BugReportDestination
{
    /// <summary>GitHub answers 414 for very long URIs, and browsers have their own ceilings; well under both.</summary>
    public const int MaxUrlLength = 7500;

    /// <summary>GitHub's title limit.</summary>
    public const int MaxTitleLength = 200;

    /// <summary>Appended to a body cut to fit.</summary>
    public const string TruncationNotice = "\n\n_Report truncated to fit in a URL — use “Copy Report” for the full text._";

    /// <summary>A <c>…/issues/new</c> URL with the title and body; a body too long is trimmed, and says so.</summary>
    public static Uri NewIssueUrl(string title, string body, int maxLength = MaxUrlLength)
    {
        ArgumentNullException.ThrowIfNull(title);
        ArgumentNullException.ThrowIfNull(body);
        Uri full = Url(title, body);
        if (full.AbsoluteUri.Length <= maxLength)
        {
            return full;
        }
        string kept = body;
        while (kept.Length > 0)
        {
            Uri candidate = Url(title, kept + TruncationNotice);
            int overflow = candidate.AbsoluteUri.Length - maxLength;
            if (overflow <= 0)
            {
                return candidate;
            }
            // Each dropped character removes at least one character of the encoded query.
            kept = kept[..^Math.Min(Math.Max(1, overflow / 3), kept.Length)];
        }
        return Url(title, TruncationNotice);
    }

    // Encoded by hand: every character outside [A-Za-z0-9-._~] is percent-encoded, "+" included, so a
    // form decoder on the far side cannot turn the "+" in a log line into a space.
    private static Uri Url(string title, string body)
    {
        string query = string.Join('&',
            "title=" + Encode(title[..Math.Min(MaxTitleLength, title.Length)]),
            "body=" + Encode(body),
            "labels=bug");
        return new Uri(BugReportLinks.NewIssue.AbsoluteUri + "?" + query);
    }

    private static string Encode(string value) => Uri.EscapeDataString(value);
}

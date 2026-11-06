using System.Text.RegularExpressions;
using Garage.App.Core.Operations;

namespace Garage.App.Core.Logging;

/// <summary>A log line's severity, in priority order (the Mac's <c>LogLevel</c>).</summary>
public enum LogLevel
{
    /// <summary>Debug and trace output.</summary>
    Debug,

    /// <summary>Ordinary information.</summary>
    Info,

    /// <summary>A warning.</summary>
    Warning,

    /// <summary>An error.</summary>
    Error,
}

/// <summary>The Logs page's level filter (the Mac's <c>LogLevelFilter</c>).</summary>
public enum LogLevelFilter
{
    /// <summary>Every level.</summary>
    All,

    /// <summary>Errors only.</summary>
    Error,

    /// <summary>Warnings only.</summary>
    Warning,

    /// <summary>Info only.</summary>
    Info,

    /// <summary>Debug only.</summary>
    Debug,

    /// <summary>Warnings and errors.</summary>
    WarningsAndErrors,
}

/// <summary>Level inference, names and filtering, ported from the Mac's <c>ProcessRunner.swift</c> and <c>LogTableView.swift</c>.</summary>
public static partial class LogLevels
{
    /// <summary>The level's name as the table and the text filter show it ("Info").</summary>
    public static string Name(this LogLevel level) => level.ToString();

    /// <summary>The filter's menu title.</summary>
    public static string Title(this LogLevelFilter filter) => filter switch
    {
        LogLevelFilter.All => "All Levels",
        LogLevelFilter.WarningsAndErrors => "Warnings & Errors",
        _ => filter.ToString(),
    };

    /// <summary>Whether a line at <paramref name="level"/> passes <paramref name="filter"/>.</summary>
    public static bool Matches(this LogLevelFilter filter, LogLevel level) => filter switch
    {
        LogLevelFilter.All => true,
        LogLevelFilter.Error => level == LogLevel.Error,
        LogLevelFilter.Warning => level == LogLevel.Warning,
        LogLevelFilter.Info => level == LogLevel.Info,
        LogLevelFilter.Debug => level == LogLevel.Debug,
        LogLevelFilter.WarningsAndErrors => level is LogLevel.Warning or LogLevel.Error,
        _ => false,
    };

    /// <summary>
    /// The level a line most likely has, from its text: Python tracebacks, then structured
    /// <c>level</c> fields, then a leading level token, then tags anywhere; otherwise error on
    /// stderr and info on stdout. The same order and tokens as <c>LogLine.inferLevel</c> on the Mac.
    /// </summary>
    public static LogLevel Infer(LogChannel channel, string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        string trimmed = text.Trim();
        if (trimmed.Length == 0)
        {
            return channel == LogChannel.Stderr ? LogLevel.Error : LogLevel.Info;
        }

        string lower = trimmed.ToLowerInvariant();

        // 1. Python tracebacks
        if (lower.Contains("traceback (most recent call last):", StringComparison.Ordinal))
        {
            return LogLevel.Error;
        }

        // 2. Structured key-value / JSON logging
        if (HasLevelField(lower, "error", "fatal", "critical", "panic"))
        {
            return LogLevel.Error;
        }
        if (HasLevelField(lower, "warn", "warning"))
        {
            return LogLevel.Warning;
        }
        if (HasLevelField(lower, "debug", "trace"))
        {
            return LogLevel.Debug;
        }
        if (HasLevelField(lower, "info", "notice"))
        {
            return LogLevel.Info;
        }

        // 3. A leading prefix/token (Python logging, Uvicorn, timestamps, ...)
        Match match = LevelPrefix().Match(trimmed);
        if (match.Success && TokenLevel(match.Groups[1].Value) is { } fromToken)
        {
            return fromToken;
        }

        // 4. Bracketed / tagged levels anywhere in the line
        if (ContainsAny(lower, "[error]", "error:", "[fatal]", "fatal:", "panic:"))
        {
            return LogLevel.Error;
        }
        if (ContainsAny(lower, "[warn]", "[warning]", "warning:", "warn:"))
        {
            return LogLevel.Warning;
        }
        if (ContainsAny(lower, "[debug]", "[trace]", "debug:", "trace:"))
        {
            return LogLevel.Debug;
        }
        if (ContainsAny(lower, "[info]", "info:", "log:", "notice:", "detail:", "hint:"))
        {
            return LogLevel.Info;
        }

        return channel == LogChannel.Stderr ? LogLevel.Error : LogLevel.Info;
    }

    private static bool HasLevelField(string lower, params string[] names) =>
        names.Any(name =>
            lower.Contains($"\"level\":\"{name}\"", StringComparison.Ordinal)
            || lower.Contains($"\"level\": \"{name}\"", StringComparison.Ordinal)
            || lower.Contains($"level={name}", StringComparison.Ordinal));

    private static bool ContainsAny(string lower, params string[] needles) =>
        needles.Any(needle => lower.Contains(needle, StringComparison.Ordinal));

    private static LogLevel? TokenLevel(string token) => token.ToUpperInvariant() switch
    {
        "FATAL" or "CRITICAL" or "CRIT" or "PANIC" or "ERROR" or "ERR" => LogLevel.Error,
        "WARNING" or "WARN" or "WRN" => LogLevel.Warning,
        "DEBUG" or "DEBUG1" or "DEBUG2" or "DEBUG3" or "DEBUG4" or "DEBUG5" or "TRACE" or "TRC" or "DBG" => LogLevel.Debug,
        "INFO" or "INFORMATION" or "INF" or "NOTICE" or "LOG" or "DETAIL" or "HINT" or "STATEMENT" or "NOTE" => LogLevel.Info,
        _ => null,
    };

    // The Mac's levelPrefixRegex, verbatim: an optional timestamp, optional tags, then a level token.
    [GeneratedRegex(
        @"^(?:(?:\d{4}[-/]\d{2}[-/]\d{2}[T\s]\d{2}:\d{2}:\d{2}(?:[\.,]\d+)?(?:Z|[+-]\d{2}:?\d{2})?|\d{2}:\d{2}:\d{2}(?:[\.,]\d+)?|(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+\d+\s+\d{2}:\d{2}:\d{2})\s*)?(?:[-:\|]\s*|\[[^\]]+\]\s*|\([^\)]+\)\s*|\<[^\>]+\>\s*|[\w\.-]+@\w+\s*|[\w\.-]+\s*[-:\|]\s*)*[\[\(\<]?(FATAL|CRITICAL|CRIT|PANIC|ERROR|ERR|WARNING|WARN|WRN|DEBUG(?:[1-5])?|TRACE|TRC|DBG|INFO|INFORMATION|INF|NOTICE|LOG|DETAIL|HINT|STATEMENT|NOTE)[\]\)\>]?(?=[:\s\-\|/\[\(\<]|$)",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex LevelPrefix();
}

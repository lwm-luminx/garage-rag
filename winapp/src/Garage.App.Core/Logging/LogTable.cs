using System.Globalization;
using Garage.App.Core.Operations;

namespace Garage.App.Core.Logging;

/// <summary>
/// What the Logs table shows of a buffer: the lines passing the filters, at most
/// <see cref="MaximumRowsShown"/> of the newest, and the status bar's count. The Mac's
/// <c>LogTableView</c> statics, without the view.
/// </summary>
public static class LogTable
{
    /// <summary>
    /// The most rows the table shows; the filter reaches the rest. A table that lays out every
    /// row of a few thousand stalls the UI, as it did on the Mac.
    /// </summary>
    public const int MaximumRowsShown = 500;

    /// <summary>Whether <paramref name="line"/> contains <paramref name="searchText"/> in its text, source, channel or level.</summary>
    public static bool Matches(this LogLine line, string searchText)
    {
        ArgumentNullException.ThrowIfNull(line);
        if (string.IsNullOrEmpty(searchText))
        {
            return true;
        }
        return Contains(line.Text) || Contains(line.Source) || Contains(line.Channel.Name()) || Contains(line.Level.Name());

        bool Contains(string value) => value.Contains(searchText, StringComparison.CurrentCultureIgnoreCase);
    }

    /// <summary>The channel's name as the filter matches it ("stdout").</summary>
    public static string Name(this LogChannel channel) => channel == LogChannel.Stderr ? "stderr" : "stdout";

    /// <summary>Every line that passes the level filter and the (trimmed) text filter, in order.</summary>
    public static IReadOnlyList<LogLine> Matching(IEnumerable<LogLine> lines, LogLevelFilter level, string? searchText)
    {
        ArgumentNullException.ThrowIfNull(lines);
        string query = searchText?.Trim() ?? "";
        return [.. lines.Where(line => level.Matches(line.Level) && line.Matches(query))];
    }

    /// <summary>
    /// The rows shown: past <paramref name="limit"/>, the newest <paramref name="limit"/> lines, then
    /// ordered by time (oldest first, or newest first when <paramref name="newestFirst"/>).
    /// </summary>
    public static IReadOnlyList<LogLine> RowsShown(IReadOnlyList<LogLine> matches, bool newestFirst = false, int limit = MaximumRowsShown)
    {
        ArgumentNullException.ThrowIfNull(matches);
        IEnumerable<LogLine> rows = matches.Count > limit
            ? matches.OrderByDescending(line => line.Timestamp).Take(limit)
            : matches;
        return newestFirst
            ? [.. rows.OrderByDescending(line => line.Timestamp)]
            : [.. rows.OrderBy(line => line.Timestamp)];
    }

    /// <summary>The status bar's count: "3 of 12 entries", with ", showing the latest N" past the cap.</summary>
    public static string CountText(int shown, int matching, int total)
    {
        string entries = matching == 1 && total == 1 ? "entry" : "entries";
        string text = string.Create(CultureInfo.InvariantCulture, $"{matching} of {total} {entries}");
        return shown < matching ? string.Create(CultureInfo.InvariantCulture, $"{text}, showing the latest {shown}") : text;
    }
}

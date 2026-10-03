using System.Collections.ObjectModel;
using Garage.App.Core.Operations;

namespace Garage.App.Core.Logging;

/// <summary>
/// A rolling log: lines oldest first, capped at <see cref="Limit"/>. Past the cap it drops enough of
/// the oldest lines to come down to three quarters of it, not just back to it, as the Mac's
/// <c>LogLine.trimCount</c> does: trimming only the overflow removed the rows on screen on every
/// append once the buffer was full, which kept the UI busy during a fast ingest.
/// </summary>
/// <remarks>Change it on the UI thread; it raises collection events for bound lists.</remarks>
public sealed class LogBuffer(string source, int limit = LogBuffer.DefaultLimit) : ObservableCollection<LogLine>
{
    /// <summary>The Mac's per-buffer cap.</summary>
    public const int DefaultLimit = 4000;

    private readonly TimeProvider _time = TimeProvider.System;

    /// <summary>The name this buffer's lines carry.</summary>
    public string Source { get; } = source;

    /// <summary>Lines kept before a trim.</summary>
    public int Limit { get; } = limit > 0 ? limit : throw new ArgumentOutOfRangeException(nameof(limit));

    /// <summary>How many of the oldest lines to drop from <paramref name="count"/> lines capped at <paramref name="limit"/>.</summary>
    public static int TrimCount(int count, int limit) => count > limit ? count - (limit - (limit / 4)) : 0;

    /// <summary>Appends a line from this buffer's source, trimming past the cap.</summary>
    public LogLine Append(string text, LogChannel channel = LogChannel.Stdout, LogLevel? level = null)
    {
        var line = new LogLine(channel, text, Source, _time.GetLocalNow());
        if (level is { } explicitLevel)
        {
            line = line with { Level = explicitLevel };
        }
        Append(line);
        return line;
    }

    /// <summary>Appends a line as it is, trimming past the cap.</summary>
    public void Append(LogLine line)
    {
        Add(line);
        int drop = TrimCount(Count, Limit);
        for (int i = 0; i < drop; i++)
        {
            RemoveAt(0);
        }
    }
}

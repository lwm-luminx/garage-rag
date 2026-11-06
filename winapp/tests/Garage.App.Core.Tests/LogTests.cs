using Garage.App.Core.Logging;
using Garage.App.Core.Operations;

namespace Garage.App.Core.Tests;

// Ported from macapp/Tests/GarageAppUnitTests/LogTableViewTests.swift, plus the trim rule from
// ProcessRunner.swift's LogLine.trimCount.
public sealed class LogTests
{
    private static LogLine Line(string text, LogChannel channel = LogChannel.Stdout, string source = "app", DateTimeOffset? at = null) =>
        new(channel, text, source, at ?? DateTimeOffset.UnixEpoch);

    [Fact]
    public void Levels_are_ordered_by_priority()
    {
        Assert.True(LogLevel.Debug < LogLevel.Info);
        Assert.True(LogLevel.Info < LogLevel.Warning);
        Assert.True(LogLevel.Warning < LogLevel.Error);
        Assert.Equal(4, Enum.GetValues<LogLevel>().Length);
    }

    [Theory]
    [InlineData("FATAL: database cluster corrupted", LogChannel.Stdout, LogLevel.Error)]
    [InlineData("panic: runtime error: index out of range", LogChannel.Stdout, LogLevel.Error)]
    [InlineData("Traceback (most recent call last):", LogChannel.Stdout, LogLevel.Error)]
    [InlineData("[WARN] high memory consumption detected", LogChannel.Stdout, LogLevel.Warning)]
    [InlineData("WARNING: relation does not exist", LogChannel.Stdout, LogLevel.Warning)]
    [InlineData("[DEBUG] fetching 100 vector embeddings", LogChannel.Stdout, LogLevel.Debug)]
    [InlineData("server started on port 14824", LogChannel.Stdout, LogLevel.Info)]
    [InlineData("something failed", LogChannel.Stderr, LogLevel.Error)]
    // Beyond the Mac's cases: structured fields, a timestamped logger prefix, empty lines.
    [InlineData("{\"level\": \"warning\", \"msg\": \"slow\"}", LogChannel.Stdout, LogLevel.Warning)]
    [InlineData("ts=1 level=debug msg=x", LogChannel.Stderr, LogLevel.Debug)]
    [InlineData("2026-09-29 10:15:02,123 - garage_rag.ingest - INFO - ingested 12 files", LogChannel.Stderr, LogLevel.Info)]
    [InlineData("   ", LogChannel.Stderr, LogLevel.Error)]
    [InlineData("", LogChannel.Stdout, LogLevel.Info)]
    public void Levels_are_inferred_as_on_the_mac(string text, LogChannel channel, LogLevel expected) =>
        Assert.Equal(expected, Line(text, channel).Level);

    [Fact]
    public void An_explicit_level_overrides_inference() =>
        Assert.Equal(LogLevel.Warning, (Line("just a notice") with { Level = LogLevel.Warning }).Level);

    [Fact]
    public void Text_search_covers_text_source_channel_and_level()
    {
        LogLine line = Line("vacuum analyze completed", source: "postgres-worker");
        Assert.True(line.Matches(""));
        Assert.True(line.Matches("vacuum"));
        Assert.True(line.Matches("VACUUM"));
        Assert.True(line.Matches("worker"));
        Assert.True(line.Matches("stdout"));
        Assert.True(line.Matches("info"));
        Assert.False(line.Matches("nonexistent_token_xyz"));
    }

    [Fact]
    public void Level_filters_match_as_on_the_mac()
    {
        Assert.True(LogLevelFilter.All.Matches(LogLevel.Debug));
        Assert.True(LogLevelFilter.All.Matches(LogLevel.Error));
        Assert.True(LogLevelFilter.Error.Matches(LogLevel.Error));
        Assert.False(LogLevelFilter.Error.Matches(LogLevel.Warning));
        Assert.True(LogLevelFilter.Warning.Matches(LogLevel.Warning));
        Assert.False(LogLevelFilter.Warning.Matches(LogLevel.Info));
        Assert.True(LogLevelFilter.Info.Matches(LogLevel.Info));
        Assert.False(LogLevelFilter.Info.Matches(LogLevel.Debug));
        Assert.True(LogLevelFilter.Debug.Matches(LogLevel.Debug));
        Assert.False(LogLevelFilter.Debug.Matches(LogLevel.Error));
        Assert.True(LogLevelFilter.WarningsAndErrors.Matches(LogLevel.Warning));
        Assert.True(LogLevelFilter.WarningsAndErrors.Matches(LogLevel.Error));
        Assert.False(LogLevelFilter.WarningsAndErrors.Matches(LogLevel.Info));
        Assert.False(LogLevelFilter.WarningsAndErrors.Matches(LogLevel.Debug));
        Assert.Equal("Warnings & Errors", LogLevelFilter.WarningsAndErrors.Title());
        Assert.Equal("All Levels", LogLevelFilter.All.Title());
    }

    [Fact]
    public void Status_bar_count_text()
    {
        Assert.Equal("0 of 0 entries", LogTable.CountText(0, 0, 0));
        Assert.Equal("1 of 1 entry", LogTable.CountText(1, 1, 1));
        Assert.Equal("3 of 12 entries", LogTable.CountText(3, 3, 12));
        Assert.Equal("4000 of 4000 entries, showing the latest 500", LogTable.CountText(500, 4000, 4000));
    }

    [Fact]
    public void Rows_shown_keep_the_newest_lines_past_the_cap()
    {
        DateTimeOffset start = DateTimeOffset.UnixEpoch.AddSeconds(1000);
        List<LogLine> lines = [.. Enumerable.Range(0, 10).Select(i => Line($"line {i}", at: start.AddSeconds(i)))];
        List<LogLine> shuffled = [.. lines.OrderBy(_ => Random.Shared.Next())];

        Assert.Equal(["line 7", "line 8", "line 9"], LogTable.RowsShown(shuffled, limit: 3).Select(l => l.Text));
        Assert.Equal(["line 9", "line 8", "line 7"], LogTable.RowsShown(lines, newestFirst: true, limit: 3).Select(l => l.Text));
        Assert.Equal(10, LogTable.RowsShown(lines, limit: 50).Count);
    }

    [Theory]
    [InlineData(4000, 4000, 0)]
    [InlineData(4001, 4000, 1001)]
    [InlineData(10, 8, 4)]
    public void A_full_buffer_trims_to_three_quarters(int count, int limit, int drop) =>
        Assert.Equal(drop, LogBuffer.TrimCount(count, limit));

    [Fact]
    public void The_buffer_trims_a_quarter_at_a_time()
    {
        var buffer = new LogBuffer("app", limit: 8);
        for (int i = 0; i < 9; i++)
        {
            buffer.Append($"line {i}");
        }
        Assert.Equal(["line 3", "line 4", "line 5", "line 6", "line 7", "line 8"], buffer.Select(l => l.Text));
        Assert.All(buffer, l => Assert.Equal("app", l.Source));
    }

    [Fact]
    public void The_logs_page_filters_counts_and_follows_its_buffer()
    {
        var app = new LogBuffer("app");
        var garage = new LogBuffer("garage");
        app.Append("Starting server");
        app.Append("Connection pool exhausted", LogChannel.Stdout, LogLevel.Warning);
        app.Append("Crash in worker process", LogChannel.Stderr);
        var logs = new LogsViewModel([app, garage]);

        Assert.Equal("3 of 3 entries", logs.CountText);
        logs.Level = LogLevelFilter.WarningsAndErrors;
        Assert.Equal(["Connection pool exhausted", "Crash in worker process"], logs.Rows.Select(r => r.Text));
        logs.SearchText = "crash";
        Assert.Equal("1 of 3 entries", logs.CountText);

        app.Append("error: another crash here", LogChannel.Stdout);
        Assert.Equal(2, logs.Rows.Count);

        logs.Source = garage;
        Assert.Empty(logs.Rows);
        Assert.Equal("0 of 0 entries", logs.CountText);

        logs.Source = app;
        logs.Clear();
        Assert.Empty(app);
    }
}

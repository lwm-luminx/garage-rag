using System.Collections.ObjectModel;
using System.Collections.Specialized;
using CommunityToolkit.Mvvm.ComponentModel;
using Garage.App.Core.Operations;

namespace Garage.App.Core.Logging;

/// <summary>
/// The Logs page: pick a buffer, filter by text and level, and see at most
/// <see cref="LogTable.MaximumRowsShown"/> of the newest matching lines with the status bar's count
/// (the Mac's <c>LogsView</c> + <c>LogTableView</c>). The buffers are the app's own, the scan and
/// ingest runners', and each service's log stream.
/// </summary>
public sealed partial class LogsViewModel : ObservableObject
{
    private LogBuffer? _watched;

    /// <summary>Creates the page over the buffers it can show.</summary>
    public LogsViewModel(IReadOnlyList<LogBuffer> sources)
    {
        ArgumentNullException.ThrowIfNull(sources);
        Sources = sources;
        Source = sources.Count > 0 ? sources[0] : null;
    }

    /// <summary>The buffers on offer.</summary>
    public IReadOnlyList<LogBuffer> Sources { get; }

    /// <summary>The level filters on offer, in the Mac's order.</summary>
    public IReadOnlyList<LogLevelFilter> Levels { get; } = Enum.GetValues<LogLevelFilter>();

    /// <summary>The buffer shown.</summary>
    [ObservableProperty]
    public partial LogBuffer? Source { get; set; }

    /// <summary>Text filter over text, source, channel and level.</summary>
    [ObservableProperty]
    public partial string SearchText { get; set; } = "";

    /// <summary>Level filter.</summary>
    [ObservableProperty]
    public partial LogLevelFilter Level { get; set; }

    /// <summary>Newest first instead of oldest first.</summary>
    [ObservableProperty]
    public partial bool NewestFirst { get; set; }

    /// <summary>The status bar's count.</summary>
    [ObservableProperty]
    public partial string CountText { get; private set; } = LogTable.CountText(0, 0, 0);

    /// <summary>The rows shown.</summary>
    public ObservableCollection<LogLine> Rows { get; } = [];

    /// <summary>Empties the buffer shown.</summary>
    public void Clear()
    {
        Source?.Clear();
        Recompute();
    }

    /// <summary>The rows shown as text, one line each, for the clipboard.</summary>
    public string CopyText() => string.Join(Environment.NewLine,
        Rows.Select(line => $"{line.Timestamp:HH:mm:ss.fff}  {line.Level.Name(),-7}  {line.Source}  {line.Text}"));

    /// <summary>Recomputes the rows and count; called on every filter or buffer change.</summary>
    public void Recompute()
    {
        IReadOnlyList<LogLine> lines = Source is null ? [] : [.. Source];
        IReadOnlyList<LogLine> matching = LogTable.Matching(lines, Level, SearchText);
        IReadOnlyList<LogLine> shown = LogTable.RowsShown(matching, NewestFirst);
        Rows.Clear();
        foreach (LogLine line in shown)
        {
            Rows.Add(line);
        }
        CountText = LogTable.CountText(shown.Count, matching.Count, lines.Count);
    }

    partial void OnSourceChanged(LogBuffer? value)
    {
        if (_watched is not null)
        {
            _watched.CollectionChanged -= OnBufferChanged;
        }
        _watched = value;
        if (value is not null)
        {
            value.CollectionChanged += OnBufferChanged;
        }
        Recompute();
    }

    partial void OnSearchTextChanged(string value) => Recompute();

    partial void OnLevelChanged(LogLevelFilter value) => Recompute();

    partial void OnNewestFirstChanged(bool value) => Recompute();

    private void OnBufferChanged(object? sender, NotifyCollectionChangedEventArgs e) => Recompute();
}

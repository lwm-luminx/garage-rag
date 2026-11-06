using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using Garage.App.Core.Backend;
using Garage.App.Core.Mcp;
using Garage.App.Core.Search;
using Grpc.Core;

namespace Garage.App.Core.Tray;

/// <summary>Quick search's rules (the Mac's <c>MenuBarQuickSearch</c> statics).</summary>
public static class QuickSearch
{
    /// <summary>Hits shown under the field.</summary>
    public const int ResultLimit = 5;

    /// <summary>Citations shown under an answer.</summary>
    public const int CitationLimit = 4;

    /// <summary>How long typing must pause before the field searches.</summary>
    public static readonly TimeSpan Debounce = TimeSpan.FromMilliseconds(250);

    /// <summary>
    /// The file behind a hit's URI, when it is one: ingested files store a plain absolute path (a drive
    /// path or a UNC share on Windows, a POSIX path from a Mac), a few carry a <c>file://</c> URL.
    /// Anything else (a message id, another scheme, a relative name) is not a file to open.
    /// </summary>
    public static string? FilePathForUri(string uri)
    {
        ArgumentNullException.ThrowIfNull(uri);
        if (uri.Length >= 3 && char.IsAsciiLetter(uri[0]) && uri[1] == ':' && uri[2] is '\\' or '/')
        {
            return uri;
        }
        if (uri.StartsWith(@"\\", StringComparison.Ordinal) || uri.StartsWith('/'))
        {
            return uri;
        }
        return Uri.TryCreate(uri, UriKind.Absolute, out Uri? parsed) && parsed.IsFile ? parsed.LocalPath : null;
    }
}

/// <summary>
/// The notification-area flyout (the Mac's menu-bar popover): the status it shows, quick search of
/// the corpus, and Ask Garage, which sends the field's text to <c>rag_agent</c> on Garage's MCP server
/// and shows the answer with the steps the model took and the documents it rests on.
/// </summary>
public sealed partial class TrayViewModel : ObservableObject, IDisposable
{
    private static readonly TimeSpan CallTimeout = TimeSpan.FromSeconds(10);

    private readonly GarageService.GarageServiceClient _client;
    private readonly Func<TrayStatus> _readStatus;
    private readonly Func<Uri?> _mcpEndpoint;
    private readonly HttpClient? _http;
    private CancellationTokenSource? _search;
    private CancellationTokenSource? _ask;
    private McpHttpClient? _mcp;

    /// <summary>Creates the flyout's model.</summary>
    /// <param name="client">Where quick search goes.</param>
    /// <param name="readStatus">Reads the app's state into a <see cref="TrayStatus"/>.</param>
    /// <param name="mcpEndpoint">Garage's MCP server, when it serves.</param>
    /// <param name="http">For tests: the HTTP client MCP calls go through.</param>
    public TrayViewModel(GarageService.GarageServiceClient client, Func<TrayStatus> readStatus, Func<Uri?> mcpEndpoint, HttpClient? http = null)
    {
        _client = client ?? throw new ArgumentNullException(nameof(client));
        _readStatus = readStatus ?? throw new ArgumentNullException(nameof(readStatus));
        _mcpEndpoint = mcpEndpoint ?? throw new ArgumentNullException(nameof(mcpEndpoint));
        _http = http;
        Status = readStatus();
    }

    /// <summary>What the icon and flyout show.</summary>
    [ObservableProperty]
    public partial TrayStatus Status { get; private set; }

    /// <summary>The field's text.</summary>
    [ObservableProperty]
    public partial string Query { get; set; } = "";

    /// <summary>A search is in flight.</summary>
    [ObservableProperty]
    public partial bool IsSearching { get; private set; }

    /// <summary>Why the last search failed.</summary>
    [ObservableProperty]
    public partial string? SearchError { get; private set; }

    /// <summary>An ask is in flight.</summary>
    [ObservableProperty]
    public partial bool IsAsking { get; private set; }

    /// <summary>The question the answer (or the running ask) is for; the field may have moved on.</summary>
    [ObservableProperty]
    public partial string? AskedQuestion { get; private set; }

    /// <summary>The answer, once it came.</summary>
    [ObservableProperty]
    public partial AskAnswer? Answer { get; private set; }

    /// <summary>Why the ask failed, or the tool's own text when it was not an answer.</summary>
    [ObservableProperty]
    public partial string? AskError { get; private set; }

    /// <summary>The first few hits.</summary>
    public ObservableCollection<SearchResultItem> Results { get; } = [];

    /// <summary>The trimmed field.</summary>
    public string TrimmedQuery => Query.Trim();

    /// <summary>Whether the Ask Garage row shows.</summary>
    public bool ShowsAskRow => Status.CanAsk && TrimmedQuery.Length > 0;

    /// <summary>Whether the answer area shows.</summary>
    public bool ShowsAnswer => IsAsking || Answer is not null || AskError is not null;

    /// <summary>"No matches" under the field.</summary>
    public bool ShowsNoMatches => Results.Count == 0 && SearchError is null && TrimmedQuery.Length > 0 && !IsSearching;

    /// <summary>The citations shown under the answer.</summary>
    public IReadOnlyList<AskAnswer.Citation> ShownCitations => Answer?.Sources.Take(QuickSearch.CitationLimit).ToList() ?? [];

    /// <summary>Reads the status again; the app calls it on a timer and on changes.</summary>
    public void Refresh()
    {
        TrayStatus status = _readStatus();
        if (status != Status)
        {
            bool couldSearch = Status.CanSearch;
            bool couldAsk = Status.CanAsk;
            Status = status;
            if (couldSearch && !status.CanSearch)
            {
                Clear();
            }
            if (couldAsk && !status.CanAsk)
            {
                ClearAnswer();
            }
            OnPropertyChanged(nameof(ShowsAskRow));
        }
    }

    /// <summary>Empties the field, the hits and the answer.</summary>
    public void Clear()
    {
        _search?.Cancel();
        Query = "";
        Results.Clear();
        SearchError = null;
        IsSearching = false;
        ClearAnswer();
    }

    /// <summary>Forgets the answer and stops a running ask.</summary>
    public void ClearAnswer()
    {
        _ask?.Cancel();
        _ask = null;
        IsAsking = false;
        AskedQuestion = null;
        Answer = null;
        AskError = null;
        OnPropertyChanged(nameof(ShowsAnswer));
        OnPropertyChanged(nameof(ShownCitations));
    }

    partial void OnQueryChanged(string value)
    {
        OnPropertyChanged(nameof(TrimmedQuery));
        OnPropertyChanged(nameof(ShowsAskRow));
        _ = SearchSoonAsync();
    }

    /// <summary>Searches the field's text now (the debounce calls it; tests call it directly).</summary>
    public async Task SearchAsync(CancellationToken cancellationToken = default)
    {
        string text = TrimmedQuery;
        if (text.Length == 0 || !Status.CanSearch)
        {
            Results.Clear();
            SearchError = null;
            IsSearching = false;
            OnPropertyChanged(nameof(ShowsNoMatches));
            return;
        }
        IsSearching = true;
        SearchError = null;
        try
        {
            SearchResponse response = await _client.SearchAsync(
                new SearchRequest { Query = text, Mode = "hybrid", Limit = QuickSearch.ResultLimit },
                new CallOptions(deadline: DateTime.UtcNow + CallTimeout, cancellationToken: cancellationToken)).ConfigureAwait(true);
            cancellationToken.ThrowIfCancellationRequested();
            Results.Clear();
            foreach (SearchHit hit in response.Hits.Take(QuickSearch.ResultLimit))
            {
                Results.Add(SearchResultItem.From(hit));
            }
        }
        catch (RpcException ex) when (!cancellationToken.IsCancellationRequested)
        {
            Results.Clear();
            SearchError = RpcErrors.Describe(ex);
        }
        catch (OperationCanceledException)
        {
            return;
        }
        catch (RpcException)
        {
            return;
        }
        IsSearching = false;
        OnPropertyChanged(nameof(ShowsNoMatches));
    }

    /// <summary>
    /// Sends the field's text to <c>rag_agent</c> and shows what comes back. One ask at a time: a new
    /// one replaces a running one.
    /// </summary>
    public async Task AskAsync()
    {
        string question = TrimmedQuery;
        if (!ShowsAskRow || _mcpEndpoint() is not { } endpoint)
        {
            return;
        }
        _ask?.Cancel();
        var ask = new CancellationTokenSource();
        _ask = ask;
        AskedQuestion = question;
        Answer = null;
        AskError = null;
        IsAsking = true;
        OnPropertyChanged(nameof(ShowsAnswer));
        try
        {
            if (_mcp is null || _mcp.Endpoint != endpoint)
            {
                _mcp?.Dispose();
                _mcp = new McpHttpClient(endpoint, _http);
            }
            string output = await _mcp.CallToolAsync("rag_agent", new Dictionary<string, object?> { ["question"] = question },
                McpHttpClient.GenerationTimeout, ask.Token).ConfigureAwait(true);
            if (ask.IsCancellationRequested)
            {
                return;
            }
            Answer = AskAnswer.Parse(output);
            if (Answer is null)
            {
                AskError = OneLine(output);
            }
        }
        catch (McpCallException ex) when (!ask.IsCancellationRequested)
        {
            AskError = ex.Message;
        }
        catch (OperationCanceledException)
        {
            return;
        }
        if (!ask.IsCancellationRequested)
        {
            IsAsking = false;
            OnPropertyChanged(nameof(ShowsAnswer));
            OnPropertyChanged(nameof(ShownCitations));
        }
    }

    /// <summary>A tool's text on one line, for an error under the field.</summary>
    public static string OneLine(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        string joined = string.Join(' ', text.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries).Select(l => l.Trim()));
        return joined.Length > 300 ? joined[..300] + "…" : joined;
    }

    /// <inheritdoc/>
    public void Dispose()
    {
        _search?.Cancel();
        _search?.Dispose();
        _ask?.Cancel();
        _ask?.Dispose();
        _mcp?.Dispose();
    }

    private async Task SearchSoonAsync()
    {
        _search?.Cancel();
        var search = new CancellationTokenSource();
        _search = search;
        try
        {
            if (TrimmedQuery.Length > 0)
            {
                await Task.Delay(QuickSearch.Debounce, search.Token).ConfigureAwait(true);
            }
            await SearchAsync(search.Token).ConfigureAwait(true);
        }
        catch (OperationCanceledException)
        {
            // Superseded by more typing.
        }
    }
}

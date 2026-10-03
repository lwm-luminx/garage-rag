using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Globalization;
using CommunityToolkit.Mvvm.ComponentModel;
using Garage.App.Core.Corpus;
using Garage.App.Core.Backend;
using Grpc.Core;

namespace Garage.App.Core.Search;

/// <summary>One search hit, as the results list and inspector show it (the Mac's <c>SearchResultItem</c>).</summary>
public sealed record SearchResultItem(
    int Rank,
    string Title,
    string Uri,
    string CorpusClass,
    string TrustTier,
    string MatchedBy,
    float Score,
    string HeadingPath,
    IReadOnlyList<string> Authors,
    string Text,
    string Snippet)
{
    /// <summary>From a <c>SearchHit</c>.</summary>
    public static SearchResultItem From(SearchHit hit)
    {
        ArgumentNullException.ThrowIfNull(hit);
        return new(hit.Rank, hit.Title, hit.Uri, hit.CorpusClass, hit.TrustTier, hit.MatchedBy, hit.Score,
            hit.HeadingPath, [.. hit.Authors], hit.Text, hit.Snippet);
    }

    /// <summary>A stable identity for selection (rank, URI, score, as on the Mac).</summary>
    public string Id => string.Create(CultureInfo.InvariantCulture, $"{Rank}_{Uri}_{Score}");

    /// <summary>The title shown: title, heading path, file name, or "(untitled)".</summary>
    public string DisplayTitle => CorpusTaxonomy.DisplayTitle(Title, Uri, HeadingPath);

    /// <summary>The authors, comma-separated; empty when there are none.</summary>
    public string AuthorsList => string.Join(", ", Authors);

    /// <summary>"Score: 0.0328", four places as on the Mac.</summary>
    public string ScoreText => string.Create(CultureInfo.InvariantCulture, $"Score: {Score:0.0000}");

    /// <summary>The full content, or the snippet when the hit carries no text.</summary>
    public string Content => string.IsNullOrEmpty(Text) ? Snippet : Text;

    /// <summary>Whether the snippet says something the full content does not show as is.</summary>
    public bool HasDistinctSnippet => !string.IsNullOrEmpty(Snippet) && Snippet != Text;
}

/// <summary>A search mode: the value the server takes and the label the picker shows.</summary>
public sealed record SearchMode(string Value, string Title)
{
    /// <summary>The Mac's modes, in its order.</summary>
    public static IReadOnlyList<SearchMode> All { get; } =
        [new("hybrid", "Hybrid"), new("vector", "Vector"), new("fts", "Full-Text (FTS)")];
}

/// <summary>
/// The Search page: query, mode, limit, filters and results with an inspector. The Mac's
/// <c>SearchView</c> state and <c>runSearch</c>, with the wording kept.
/// </summary>
public sealed partial class SearchViewModel(GarageService.GarageServiceClient client) : ObservableObject
{
    /// <summary>The smallest and largest result counts the limit allows.</summary>
    public const int MinLimit = 1, MaxLimit = 100;

    private static readonly TimeSpan CallTimeout = TimeSpan.FromSeconds(60);

    [ObservableProperty]
    public partial string Query { get; set; } = "";

    [ObservableProperty]
    public partial SearchMode Mode { get; set; } = SearchMode.All[0];

    /// <summary>The model to search with; empty for the default model.</summary>
    [ObservableProperty]
    public partial string Model { get; set; } = "";

    [ObservableProperty]
    public partial int Limit { get; set; } = 10;

    [ObservableProperty]
    public partial string CorpusClass { get; set; } = CorpusTaxonomy.All;

    [ObservableProperty]
    public partial string TrustTier { get; set; } = CorpusTaxonomy.All;

    [ObservableProperty]
    public partial string Source { get; set; } = CorpusTaxonomy.All;

    [ObservableProperty]
    public partial bool IsSearching { get; private set; }

    [ObservableProperty]
    public partial bool HasSearched { get; private set; }

    [ObservableProperty]
    public partial string? ErrorMessage { get; private set; }

    [ObservableProperty]
    public partial string LastSearchedQuery { get; private set; } = "";

    [ObservableProperty]
    public partial double? LastLatencyMs { get; private set; }

    [ObservableProperty]
    public partial SearchResultItem? SelectedResult { get; set; }

    /// <summary>The results, by rank.</summary>
    public ObservableCollection<SearchResultItem> Results { get; } = [];

    /// <summary>Corpus class choices, "all" first.</summary>
    public IReadOnlyList<string> CorpusClasses { get; } = CorpusTaxonomy.WithAll(CorpusTaxonomy.CorpusClasses);

    /// <summary>Trust tier choices, "all" first.</summary>
    public IReadOnlyList<string> TrustTiers { get; } = CorpusTaxonomy.WithAll(CorpusTaxonomy.TrustTiers);

    /// <summary>Source choices, "all" first; filled by <see cref="LoadSourcesAsync"/>.</summary>
    public ObservableCollection<string> Sources { get; } = [CorpusTaxonomy.All];

    /// <summary>The status bar's text.</summary>
    public string StatusText => IsSearching
        ? "Searching…"
        : HasSearched && ErrorMessage is null
            ? string.Create(CultureInfo.CurrentCulture, $"{Results.Count} results for '{LastSearchedQuery}'")
                + (LastLatencyMs is { } ms ? string.Create(CultureInfo.CurrentCulture, $" • {ms:0} ms") : "")
            : "Ready";

    /// <summary>What the results area says when it has no rows, or null when it has some.</summary>
    public (string Title, string Detail)? EmptyState => Results.Count > 0 || IsSearching
        ? null
        : ErrorMessage is { } error
            ? ("Search Failed", error)
            : HasSearched
                ? ("No Results Found", $"No documents matched '{LastSearchedQuery}'. Try adjusting the search terms, mode, or filters.")
                : ("Search Knowledge Base", "Enter a search query to retrieve relevant document chunks using hybrid semantic and keyword search.");

    /// <summary>Puts every filter back to "all".</summary>
    public void ResetFilters()
    {
        CorpusClass = CorpusTaxonomy.All;
        TrustTier = CorpusTaxonomy.All;
        Source = CorpusTaxonomy.All;
    }

    /// <summary>Fills <see cref="Sources"/> from the registered sources; leaves it as is if the server does not answer.</summary>
    public async Task LoadSourcesAsync(CancellationToken cancellationToken = default)
    {
        try
        {
            ListSourcesResponse response = await client.ListSourcesAsync(
                new ListSourcesRequest(), new CallOptions(deadline: DateTime.UtcNow + CallTimeout, cancellationToken: cancellationToken)).ConfigureAwait(true);
            Sources.Clear();
            Sources.Add(CorpusTaxonomy.All);
            foreach (string slug in response.Sources.Select(s => s.Slug).Order(StringComparer.Ordinal))
            {
                Sources.Add(slug);
            }
        }
        catch (RpcException)
        {
            // The filter keeps "all"; the page still searches.
        }
    }

    /// <summary>
    /// Runs the query with the current mode, model, limit and filters. A blank query does nothing.
    /// Selects the first hit, as the Mac opens it in the inspector.
    /// </summary>
    public async Task SearchAsync(CancellationToken cancellationToken = default)
    {
        string trimmed = Query.Trim();
        if (trimmed.Length == 0)
        {
            return;
        }

        IsSearching = true;
        ErrorMessage = null;
        Notify();
        var request = new SearchRequest
        {
            Query = trimmed,
            Mode = Mode.Value,
            Model = Model,
            Limit = Math.Clamp(Limit, MinLimit, MaxLimit),
            Full = true,
        };
        if (CorpusTaxonomy.Filter(CorpusClass) is { } corpusClass)
        {
            request.CorpusClasses.Add(corpusClass);
        }
        if (CorpusTaxonomy.Filter(TrustTier) is { } trustTier)
        {
            request.TrustTiers.Add(trustTier);
        }
        if (CorpusTaxonomy.Filter(Source) is { } source)
        {
            request.Sources.Add(source);
        }

        long started = Stopwatch.GetTimestamp();
        try
        {
            SearchResponse response = await client.SearchAsync(
                request, new CallOptions(deadline: DateTime.UtcNow + CallTimeout, cancellationToken: cancellationToken)).ConfigureAwait(true);
            Results.Clear();
            foreach (SearchHit hit in response.Hits)
            {
                Results.Add(SearchResultItem.From(hit));
            }
            LastLatencyMs = Stopwatch.GetElapsedTime(started).TotalMilliseconds;
            SelectedResult = Results.FirstOrDefault();
        }
        catch (RpcException ex)
        {
            Results.Clear();
            SelectedResult = null;
            ErrorMessage = RpcErrors.Describe(ex);
        }
        finally
        {
            LastSearchedQuery = trimmed;
            HasSearched = true;
            IsSearching = false;
            Notify();
        }
    }

    private void Notify()
    {
        OnPropertyChanged(nameof(StatusText));
        OnPropertyChanged(nameof(EmptyState));
    }
}

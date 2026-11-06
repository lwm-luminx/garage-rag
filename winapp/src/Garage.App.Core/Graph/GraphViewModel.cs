using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using Garage.App.Core.Backend;
using Garage.App.Core.Corpus;
using Grpc.Core;

namespace Garage.App.Core.Graph;

/// <summary>
/// The Graph page (the Mac's <c>GraphView</c>): browse the <c>garage</c> graph Apache AGE holds. Pick
/// a document, author, fact or statement and see what it is connected to, a few hops out, with each
/// kind of vertex and edge switchable. The filters come from the graph itself (<c>GetGraphLabels</c>),
/// so a label added later shows up here.
/// </summary>
public sealed partial class GraphViewModel(GarageService.GarageServiceClient client, Func<bool>? databaseRunning = null) : ObservableObject
{
    private static readonly TimeSpan CallTimeout = TimeSpan.FromSeconds(60);
    private readonly Func<bool> _databaseRunning = databaseRunning ?? (() => true);
    private readonly HashSet<string> _enabledVertexLabels = new(StringComparer.Ordinal);
    private readonly HashSet<string> _enabledEdgeLabels = new(StringComparer.Ordinal);
    private int _generation;

    /// <summary>The graph's labels; null until the first load answers.</summary>
    [ObservableProperty]
    public partial GraphLabels? Labels { get; private set; }

    /// <summary>What the search field holds.</summary>
    [ObservableProperty]
    public partial string SearchText { get; set; } = "";

    /// <summary>The Kind picker: one vertex label, or <see cref="CorpusTaxonomy.All"/>.</summary>
    [ObservableProperty]
    public partial string SearchLabel { get; set; } = CorpusTaxonomy.All;

    /// <summary>Whether a search has run (so an empty result says "Nothing Found").</summary>
    [ObservableProperty]
    public partial bool HasSearched { get; private set; }

    /// <summary>Whether a search is in flight.</summary>
    [ObservableProperty]
    public partial bool IsSearching { get; private set; }

    /// <summary>The graph id of the vertex in the middle; null before one is chosen.</summary>
    [ObservableProperty]
    public partial long? CenterId { get; private set; }

    /// <summary>The neighbourhood drawn.</summary>
    [ObservableProperty]
    public partial GraphNeighborhood? Neighborhood { get; private set; }

    /// <summary>Hops out from the center, 1 to <see cref="GraphPagePresentation.MaxDepth"/>.</summary>
    [ObservableProperty]
    public partial int Depth { get; set; } = 1;

    /// <summary>The vertex the inspector shows.</summary>
    [ObservableProperty]
    public partial long? SelectedVertexId { get; set; }

    /// <summary>Whether labels or a neighbourhood are loading.</summary>
    [ObservableProperty]
    public partial bool IsLoading { get; private set; }

    /// <summary>Why the last load failed.</summary>
    [ObservableProperty]
    public partial string? ErrorMessage { get; private set; }

    /// <summary>Search results.</summary>
    public ObservableCollection<GraphVertexItem> Results { get; } = [];

    /// <summary>A vertex another page asked to center on, consumed when the page appears.</summary>
    public GraphFocus? PendingFocus { get; set; }

    /// <summary>Whether the database can answer.</summary>
    public bool DatabaseRunning => _databaseRunning();

    /// <summary>Whether a vertex label is switched on.</summary>
    public bool IsVertexLabelOn(string label) => _enabledVertexLabels.Contains(label);

    /// <summary>Whether an edge label is switched on.</summary>
    public bool IsEdgeLabelOn(string label) => _enabledEdgeLabels.Contains(label);

    /// <summary>The vertex the inspector shows: the selection, else the center.</summary>
    public GraphVertexItem? SelectedVertex => Neighborhood is not { } neighborhood
        ? null
        : SelectedVertexId is { } id && neighborhood.Vertex(id) is { } vertex ? vertex : neighborhood.Center;

    /// <summary>What the whole page says instead of the browser, or null when it browses.</summary>
    public GraphPagePresentation.Empty? PageEmptyState => ErrorMessage is not null || (Labels is null && IsLoading)
        ? null
        : !DatabaseRunning || Labels?.Available != true
            ? GraphPagePresentation.EmptyState(DatabaseRunning, Labels?.Available ?? false, false, false)
            : null;

    /// <summary>What the results column says when it lists nothing.</summary>
    public GraphPagePresentation.Empty ResultsEmptyState => GraphPagePresentation.EmptyState(true, true, false, HasSearched);

    /// <summary>What the picture says when it has nothing to draw.</summary>
    public GraphPagePresentation.Empty PictureEmptyState => GraphPagePresentation.EmptyState(true, true, CenterId is not null, false);

    /// <summary>The footer under the picture.</summary>
    public string Summary => Neighborhood is { } n
        ? GraphPagePresentation.Summary(n.Vertices.Count, n.Edges.Count, Depth, n.Truncated)
        : "";

    /// <summary>Loads the labels; a label new to the page starts switched on, while switches the user set stay as set.</summary>
    public async Task LoadLabelsAsync(CancellationToken cancellationToken = default)
    {
        if (!DatabaseRunning)
        {
            Labels = null;
            Notify();
            return;
        }
        IsLoading = true;
        ErrorMessage = null;
        Notify();
        try
        {
            GraphLabels loaded = GraphLabels.From(await client.GetGraphLabelsAsync(new GraphLabelsRequest(), Options(cancellationToken)).ConfigureAwait(true));
            HashSet<string> knownVertices = [.. Labels?.VertexLabels.Select(l => l.Label) ?? []];
            HashSet<string> knownEdges = [.. Labels?.EdgeLabels.Select(l => l.Label) ?? []];
            foreach (GraphLabelCountItem option in loaded.VertexLabels.Where(o => !knownVertices.Contains(o.Label)))
            {
                _enabledVertexLabels.Add(option.Label);
            }
            foreach (GraphLabelCountItem option in loaded.EdgeLabels.Where(o => !knownEdges.Contains(o.Label)))
            {
                _enabledEdgeLabels.Add(option.Label);
            }
            Labels = loaded;
        }
        catch (RpcException ex)
        {
            ErrorMessage = RpcErrors.Describe(ex);
        }
        finally
        {
            IsLoading = false;
            Notify();
        }
    }

    /// <summary>Finds vertices titled like <see cref="SearchText"/> (or carrying it as their id), under the Kind picker.</summary>
    public async Task SearchAsync(CancellationToken cancellationToken = default)
    {
        if (!DatabaseRunning)
        {
            return;
        }
        HasSearched = true;
        IsSearching = true;
        Notify();
        try
        {
            FindGraphVerticesResponse response = await client.FindGraphVerticesAsync(new FindGraphVerticesRequest
            {
                Query = SearchText.Trim(),
                Label = CorpusTaxonomy.Filter(SearchLabel) ?? "",
                Limit = 50,
            }, Options(cancellationToken)).ConfigureAwait(true);
            Results.Clear();
            foreach (GraphVertex vertex in response.Vertices)
            {
                Results.Add(GraphVertexItem.From(vertex));
            }
        }
        catch (RpcException ex)
        {
            ErrorMessage = RpcErrors.Describe(ex);
        }
        finally
        {
            IsSearching = false;
            Notify();
        }
    }

    /// <summary>Clears the search and its results.</summary>
    public void ClearSearch()
    {
        SearchText = "";
        Results.Clear();
        HasSearched = false;
        Notify();
    }

    /// <summary>Makes a vertex the center and loads what is around it.</summary>
    public Task CenterAsync(long id)
    {
        CenterId = id;
        SelectedVertexId = id;
        return LoadNeighborhoodAsync();
    }

    /// <summary>Centers on the vertex another page asked for.</summary>
    public Task ShowAsync(GraphFocus focus)
    {
        ArgumentNullException.ThrowIfNull(focus);
        PendingFocus = null;
        CenterId = null;
        SelectedVertexId = null;
        return LoadNeighborhoodAsync(focus);
    }

    /// <summary>Switches a vertex label on or off and reloads.</summary>
    public Task ToggleVertexLabelAsync(string label)
    {
        if (!_enabledVertexLabels.Remove(label))
        {
            _enabledVertexLabels.Add(label);
        }
        return LoadNeighborhoodAsync();
    }

    /// <summary>Switches an edge label on or off and reloads.</summary>
    public Task ToggleEdgeLabelAsync(string label)
    {
        if (!_enabledEdgeLabels.Remove(label))
        {
            _enabledEdgeLabels.Add(label);
        }
        return LoadNeighborhoodAsync();
    }

    /// <summary>Reloads labels, the neighbourhood and the search.</summary>
    public async Task RefreshAsync()
    {
        await LoadLabelsAsync().ConfigureAwait(true);
        await LoadNeighborhoodAsync().ConfigureAwait(true);
        if (HasSearched)
        {
            await SearchAsync().ConfigureAwait(true);
        }
    }

    /// <summary>
    /// The labels to ask for: null when every label is on, so a label the page has not seen yet (a
    /// fresh rebuild adding one) still comes through.
    /// </summary>
    internal static IReadOnlyList<string>? Requested(IReadOnlySet<string> enabled, IReadOnlyList<GraphLabelCountItem> options)
    {
        HashSet<string> all = [.. options.Select(o => o.Label)];
        return all.IsSubsetOf(enabled) ? null : [.. all.Where(enabled.Contains).Order(StringComparer.Ordinal)];
    }

    /// <summary>Loads the neighbourhood of <paramref name="focus"/>, or of the current center.</summary>
    public async Task LoadNeighborhoodAsync(GraphFocus? focus = null, CancellationToken cancellationToken = default)
    {
        if (!DatabaseRunning || (focus is null && CenterId is null))
        {
            return;
        }
        int request = ++_generation;
        IsLoading = true;
        ErrorMessage = null;
        Notify();
        var message = new GraphNeighborhoodRequest
        {
            Depth = Depth,
            Limit = GraphPagePresentation.VertexLimit,
        };
        if (focus is not null)
        {
            message.Label = focus.Label;
            message.Key = focus.Key;
        }
        else
        {
            message.VertexId = CenterId!.Value;
        }
        if (Requested(_enabledVertexLabels, Labels?.VertexLabels ?? []) is { } vertexLabels)
        {
            message.VertexLabels.AddRange(vertexLabels);
            message.FilterVertexLabels = true;
        }
        if (Requested(_enabledEdgeLabels, Labels?.EdgeLabels ?? []) is { } edgeLabels)
        {
            message.EdgeLabels.AddRange(edgeLabels);
            message.FilterEdgeLabels = true;
        }
        try
        {
            GraphNeighborhood loaded = GraphNeighborhood.From(await client.GetGraphNeighborhoodAsync(message, Options(cancellationToken)).ConfigureAwait(true));
            if (request != _generation)
            {
                return;
            }
            Neighborhood = loaded;
            CenterId = loaded.Center?.Id;
            if (SelectedVertexId is not { } selected || loaded.Vertex(selected) is null)
            {
                SelectedVertexId = loaded.Center?.Id;
            }
            if (!loaded.Available)
            {
                Labels = GraphLabels.Unavailable;
            }
        }
        catch (RpcException ex) when (request == _generation)
        {
            ErrorMessage = RpcErrors.Describe(ex);
        }
        finally
        {
            if (request == _generation)
            {
                IsLoading = false;
                Notify();
            }
        }
    }

    private static CallOptions Options(CancellationToken cancellationToken) =>
        new(deadline: DateTime.UtcNow + CallTimeout, cancellationToken: cancellationToken);

    private void Notify()
    {
        OnPropertyChanged(nameof(SelectedVertex));
        OnPropertyChanged(nameof(PageEmptyState));
        OnPropertyChanged(nameof(ResultsEmptyState));
        OnPropertyChanged(nameof(PictureEmptyState));
        OnPropertyChanged(nameof(Summary));
    }

    partial void OnSelectedVertexIdChanged(long? value) => OnPropertyChanged(nameof(SelectedVertex));
}

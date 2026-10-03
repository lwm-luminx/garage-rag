using System.Collections.ObjectModel;
using System.Globalization;
using CommunityToolkit.Mvvm.ComponentModel;
using Garage.App.Core.Corpus;
using Garage.App.Core.Backend;
using Grpc.Core;

namespace Garage.App.Core.Documents;

/// <summary>One document in the list (the Mac's <c>DocumentListItem</c>).</summary>
public sealed record DocumentListItem(
    long Id, string Uri, string Title, string SourceSlug, string CorpusClass, string TrustTier,
    string Mime, long ByteSize, int ChunkCount, int FactCount, string State, string IngestedAt)
{
    /// <summary>From a <c>DocumentSummary</c>.</summary>
    public static DocumentListItem From(DocumentSummary summary)
    {
        ArgumentNullException.ThrowIfNull(summary);
        return new(summary.Id, summary.Uri, summary.Title, summary.SourceSlug, summary.CorpusClass, summary.TrustTier,
            summary.Mime, summary.ByteSize, summary.ChunkCount, summary.FactCount, summary.State, summary.IngestedAt);
    }

    /// <summary>The title shown: title, file name, or "(untitled)".</summary>
    public string DisplayTitle => CorpusTaxonomy.DisplayTitle(Title, Uri);

    /// <summary>"12 chunks · 3 facts" (facts left out when there are none).</summary>
    public string Counts => FactCount > 0
        ? string.Create(CultureInfo.CurrentCulture, $"{Plural(ChunkCount, "chunk")} · {Plural(FactCount, "fact")}")
        : Plural(ChunkCount, "chunk");

    internal static string Plural(long count, string word) =>
        string.Create(CultureInfo.CurrentCulture, $"{count:N0} {(count == 1 ? word : word + "s")}");
}

/// <summary>One chunk of a document, in order.</summary>
public sealed record DocumentChunk(long Id, int Ord, string Text, int TokenCount, string HeadingPath)
{
    /// <summary>"#3 · 412 tokens · Heading › Sub".</summary>
    public string Caption => string.Join(" · ", new[]
    {
        string.Create(CultureInfo.CurrentCulture, $"#{Ord}"),
        DocumentListItem.Plural(TokenCount, "token"),
        HeadingPath,
    }.Where(part => part.Length > 0));
}

/// <summary>A document's detail: metadata, authors, chunks and facts (the Mac's <c>DocumentDetailItem</c>).</summary>
public sealed record DocumentDetail(
    long Id, string Uri, string Title, string SourceSlug, string CorpusClass, string TrustTier, string Mime,
    long ByteSize, string Extractor, string ExtractorVersion, string Chunker, string State, string Error,
    string IngestedAt, IReadOnlyList<string> Authors, IReadOnlyList<DocumentChunk> Chunks, IReadOnlyList<string> Facts)
{
    /// <summary>From a <c>GetDocument</c> reply.</summary>
    public static DocumentDetail From(GetDocumentResponse response)
    {
        ArgumentNullException.ThrowIfNull(response);
        Garage.DocumentDetail d = response.Document;
        return new(d.Id, d.Uri, d.Title, d.SourceSlug, d.CorpusClass, d.TrustTier, d.Mime, d.ByteSize,
            d.Extractor, d.ExtractorVersion, d.Chunker, d.State, d.Error, d.IngestedAt,
            [.. d.Authors.Select(a => string.IsNullOrEmpty(a.Role) || a.Role == "author" ? a.Name : $"{a.Name} ({a.Role})")],
            [.. response.Chunks.OrderBy(c => c.Ord).Select(c => new DocumentChunk(c.Id, c.Ord, c.Text, c.TokenCount, c.HeadingPath))],
            [.. response.Facts.OrderBy(f => f.Ord).Select(f => f.Fact)]);
    }

    /// <summary>The title shown.</summary>
    public string DisplayTitle => CorpusTaxonomy.DisplayTitle(Title, Uri);

    /// <summary>"document · authored · notes · text/markdown · 4 KB".</summary>
    public string Summary => string.Join(" · ", new[] { CorpusClass, TrustTier, SourceSlug, Mime, Bytes.Format(ByteSize) }
        .Where(part => !string.IsNullOrEmpty(part)));

    /// <summary>"markdown 3 · recursive:1000/150".</summary>
    public string ExtractedBy => string.Join(" · ", new[] { $"{Extractor} {ExtractorVersion}".Trim(), Chunker }
        .Where(part => part.Length > 0));
}

/// <summary>
/// The Documents page: filters, the list (a page of 200), and the selected document's detail.
/// The Mac's <c>DocumentsView</c> state, <c>refreshDocuments</c> and <c>loadDetail</c>.
/// </summary>
public sealed partial class DocumentsViewModel(GarageService.GarageServiceClient client) : ObservableObject
{
    /// <summary>Documents per request, as on the Mac.</summary>
    public const int PageSize = 200;

    private static readonly TimeSpan CallTimeout = TimeSpan.FromSeconds(60);
    private int _generation;

    /// <summary>Substring filter on title or URI.</summary>
    [ObservableProperty]
    public partial string SearchText { get; set; } = "";

    /// <summary>Source filter.</summary>
    [ObservableProperty]
    public partial string Source { get; set; } = CorpusTaxonomy.All;

    /// <summary>Corpus class filter.</summary>
    [ObservableProperty]
    public partial string CorpusClass { get; set; } = CorpusTaxonomy.All;

    /// <summary>Trust tier filter.</summary>
    [ObservableProperty]
    public partial string TrustTier { get; set; } = CorpusTaxonomy.All;

    /// <summary>Documents matching the filters, of which <see cref="Documents"/> holds the first page.</summary>
    [ObservableProperty]
    public partial long TotalCount { get; private set; }

    /// <summary>Whether the list is loading.</summary>
    [ObservableProperty]
    public partial bool IsLoadingList { get; private set; }

    /// <summary>Why the list failed to load.</summary>
    [ObservableProperty]
    public partial string? ListError { get; private set; }

    /// <summary>The selected document.</summary>
    [ObservableProperty]
    public partial DocumentListItem? Selected { get; set; }

    /// <summary>The selected document's detail, once loaded.</summary>
    [ObservableProperty]
    public partial DocumentDetail? Detail { get; private set; }

    /// <summary>Whether the detail is loading.</summary>
    [ObservableProperty]
    public partial bool IsLoadingDetail { get; private set; }

    /// <summary>Why the detail failed to load.</summary>
    [ObservableProperty]
    public partial string? DetailError { get; private set; }

    /// <summary>The listed documents.</summary>
    public ObservableCollection<DocumentListItem> Documents { get; } = [];

    /// <summary>Corpus class choices.</summary>
    public IReadOnlyList<string> CorpusClasses { get; } = CorpusTaxonomy.WithAll(CorpusTaxonomy.CorpusClasses);

    /// <summary>Trust tier choices.</summary>
    public IReadOnlyList<string> TrustTiers { get; } = CorpusTaxonomy.WithAll(CorpusTaxonomy.TrustTiers);

    /// <summary>Source choices, filled by <see cref="LoadSourcesAsync"/>.</summary>
    public ObservableCollection<string> Sources { get; } = [CorpusTaxonomy.All];

    /// <summary>"242 documents", or "200 of 1,204 documents" when the list is a page.</summary>
    public string CountText => Documents.Count < TotalCount
        ? string.Create(CultureInfo.CurrentCulture, $"{Documents.Count:N0} of {DocumentListItem.Plural(TotalCount, "document")}")
        : DocumentListItem.Plural(TotalCount, "document");

    /// <summary>What the list says when empty, or null.</summary>
    public (string Title, string Detail)? EmptyState => IsLoadingList || Documents.Count > 0
        ? null
        : ListError is { } error
            ? ("Failed to Load Documents", error)
            : ("No Documents Found", "No documents match these filters. Add a source and ingest it, or clear the filters.");

    /// <summary>Fills <see cref="Sources"/> from the registered sources.</summary>
    public async Task LoadSourcesAsync(CancellationToken cancellationToken = default)
    {
        try
        {
            ListSourcesResponse response = await client.ListSourcesAsync(new ListSourcesRequest(), Options(cancellationToken)).ConfigureAwait(true);
            Sources.Clear();
            Sources.Add(CorpusTaxonomy.All);
            foreach (string slug in response.Sources.Select(s => s.Slug).Order(StringComparer.Ordinal))
            {
                Sources.Add(slug);
            }
        }
        catch (RpcException)
        {
            // Keep "all".
        }
    }

    /// <summary>Reloads the list under the current filters; keeps the selection when it is still listed.</summary>
    public async Task RefreshAsync(CancellationToken cancellationToken = default)
    {
        int generation = ++_generation;
        IsLoadingList = true;
        ListError = null;
        Notify();
        var request = new ListDocumentsRequest
        {
            Source = CorpusTaxonomy.Filter(Source) ?? "",
            CorpusClass = CorpusTaxonomy.Filter(CorpusClass) ?? "",
            TrustTier = CorpusTaxonomy.Filter(TrustTier) ?? "",
            Query = SearchText.Trim(),
            Limit = PageSize,
        };
        try
        {
            ListDocumentsResponse response = await client.ListDocumentsAsync(request, Options(cancellationToken)).ConfigureAwait(true);
            if (generation != _generation)
            {
                return;  // a newer refresh is on its way
            }
            Documents.Clear();
            foreach (DocumentSummary summary in response.Documents)
            {
                Documents.Add(DocumentListItem.From(summary));
            }
            TotalCount = response.TotalCount;
            if (Selected is { } selected && Documents.All(d => d.Id != selected.Id))
            {
                Selected = null;
                Detail = null;
            }
        }
        catch (RpcException ex) when (generation == _generation)
        {
            ListError = Describe(ex);
        }
        finally
        {
            if (generation == _generation)
            {
                IsLoadingList = false;
                Notify();
            }
        }
    }

    /// <summary>More documents match than are listed.</summary>
    public bool CanLoadMore => !IsLoadingList && ListError is null && Documents.Count < TotalCount;

    private bool _loadingMore;

    /// <summary>
    /// Appends the next page under the same filters: the list asks as it nears its end, so a corpus of
    /// tens of thousands of documents scrolls without loading them all at once.
    /// </summary>
    public async Task LoadMoreAsync(CancellationToken cancellationToken = default)
    {
        if (!CanLoadMore || _loadingMore)
        {
            return;
        }
        _loadingMore = true;
        int generation = _generation;
        var request = new ListDocumentsRequest
        {
            Source = CorpusTaxonomy.Filter(Source) ?? "",
            CorpusClass = CorpusTaxonomy.Filter(CorpusClass) ?? "",
            TrustTier = CorpusTaxonomy.Filter(TrustTier) ?? "",
            Query = SearchText.Trim(),
            Limit = PageSize,
            Offset = Documents.Count,
        };
        try
        {
            ListDocumentsResponse response = await client.ListDocumentsAsync(request, Options(cancellationToken)).ConfigureAwait(true);
            if (generation != _generation)
            {
                return;  // the filters changed meanwhile
            }
            HashSet<long> listed = [.. Documents.Select(d => d.Id)];
            foreach (DocumentSummary summary in response.Documents.Where(d => !listed.Contains(d.Id)))
            {
                Documents.Add(DocumentListItem.From(summary));
            }
            TotalCount = response.TotalCount;
        }
        catch (RpcException ex) when (generation == _generation)
        {
            ListError = Describe(ex);
        }
        finally
        {
            _loadingMore = false;
            Notify();
        }
    }

    /// <summary>Loads the selected document's detail.</summary>
    public async Task LoadDetailAsync(CancellationToken cancellationToken = default)
    {
        if (Selected is not { } selected)
        {
            Detail = null;
            return;
        }
        IsLoadingDetail = true;
        DetailError = null;
        try
        {
            GetDocumentResponse response = await client.GetDocumentAsync(
                new GetDocumentRequest { DocumentId = selected.Id }, Options(cancellationToken)).ConfigureAwait(true);
            if (Selected?.Id == selected.Id)
            {
                Detail = DocumentDetail.From(response);
            }
        }
        catch (RpcException ex)
        {
            DetailError = Describe(ex);
            Detail = null;
        }
        finally
        {
            IsLoadingDetail = false;
        }
    }

    private static CallOptions Options(CancellationToken cancellationToken) =>
        new(deadline: DateTime.UtcNow + CallTimeout, cancellationToken: cancellationToken);

    private static string Describe(RpcException ex) =>
        RpcErrors.Describe(ex);

    private void Notify()
    {
        OnPropertyChanged(nameof(CountText));
        OnPropertyChanged(nameof(EmptyState));
        OnPropertyChanged(nameof(CanLoadMore));
    }
}

/// <summary>File sizes as the Mac's <c>ByteCountFormatter</c> (<c>.file</c>) shows them: decimal units.</summary>
public static class Bytes
{
    /// <summary>"512 bytes", "4 KB", "5 MB", "1.2 GB".</summary>
    public static string Format(long bytes)
    {
        if (bytes < 1000)
        {
            return string.Create(CultureInfo.CurrentCulture, $"{bytes:N0} {(bytes == 1 ? "byte" : "bytes")}");
        }
        string[] units = ["KB", "MB", "GB", "TB"];
        double value = bytes;
        int unit = -1;
        while (value >= 1000 && unit < units.Length - 1)
        {
            value /= 1000;
            unit++;
        }
        string format = value < 10 && unit >= 1 ? "0.#" : "0";
        return string.Create(CultureInfo.CurrentCulture, $"{value.ToString(format, CultureInfo.CurrentCulture)} {units[unit]}");
    }
}

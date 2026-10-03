using System.Collections.ObjectModel;
using System.Globalization;
using System.Text;
using System.Text.Json;
using CommunityToolkit.Mvvm.ComponentModel;
using Garage.App.Core.Corpus;
using Garage.App.Core.Backend;
using Grpc.Core;

namespace Garage.App.Core.Facts;

/// <summary>One of a fact's extractor attributes.</summary>
public sealed record FactField(string Key, string Value);

/// <summary>The grounded excerpt split around the fact's span.</summary>
public sealed record GroundedExcerpt(string Before, string Span, string After);

/// <summary>A fact class and how many facts carry it, for the Kind picker.</summary>
public sealed record FactClassCount(string FactClass, long Count)
{
    /// <summary>"event (12)".</summary>
    public string Label => string.Create(CultureInfo.CurrentCulture, $"{FactClass} ({Count:N0})");
}

/// <summary>
/// One fact with the document it was distilled from: a port of the Mac's <c>FactListItem</c>,
/// with its grounding and attribute rules.
/// </summary>
public sealed record FactListItem(
    long Id, long DocumentId, int Ord, string Fact, string FactClass, string AttributesJson,
    int? CharStart, int? CharEnd, string Extractor, string ExtractorModel, string CreatedAt,
    string DocumentTitle, string DocumentUri, string SourceSlug, string CorpusClass, string Excerpt, int ExcerptStart)
{
    /// <summary>From a <c>FactSummary</c>.</summary>
    public static FactListItem From(FactSummary summary)
    {
        ArgumentNullException.ThrowIfNull(summary);
        return new(summary.Id, summary.DocumentId, summary.Ord, summary.Fact, summary.FactClass, summary.AttributesJson,
            summary.HasCharStart ? summary.CharStart : null, summary.HasCharEnd ? summary.CharEnd : null,
            summary.Extractor, summary.ExtractorModel, summary.CreatedAt, summary.DocumentTitle, summary.DocumentUri,
            summary.SourceSlug, summary.CorpusClass, summary.Excerpt, summary.ExcerptStart);
    }

    /// <summary>The document's title, else its file name, else "(untitled)".</summary>
    public string DocumentDisplayTitle => CorpusTaxonomy.DisplayTitle(DocumentTitle, DocumentUri);

    /// <summary>
    /// The excerpt split around the grounded span, or null when the fact has none or the span does
    /// not fall inside the excerpt. Offsets count Unicode scalars (<see cref="Rune"/>s): Python's
    /// string indices, which the extractor recorded, and Postgres's <c>substr</c>, which cut the
    /// excerpt, both do; UTF-16 indices would drift on anything outside the BMP.
    /// </summary>
    public GroundedExcerpt? Grounded
    {
        get
        {
            if (Excerpt.Length == 0 || CharStart is not { } start || CharEnd is not { } end || end < start)
            {
                return null;
            }
            Rune[] runes = [.. Excerpt.EnumerateRunes()];
            int lower = start - ExcerptStart;
            int upper = end - ExcerptStart;
            if (lower < 0 || upper > runes.Length)
            {
                return null;
            }
            return new(Join(runes[..lower]), Join(runes[lower..upper]), Join(runes[upper..]));

            static string Join(Rune[] part)
            {
                var builder = new StringBuilder();
                foreach (Rune rune in part)
                {
                    builder.Append(rune.ToString());
                }
                return builder.ToString();
            }
        }
    }

    /// <summary>The extractor's attributes, sorted by key, values rendered as text; empty for missing or invalid JSON.</summary>
    public IReadOnlyList<FactField> Attributes
    {
        get
        {
            if (string.IsNullOrWhiteSpace(AttributesJson))
            {
                return [];
            }
            try
            {
                using JsonDocument document = JsonDocument.Parse(AttributesJson);
                if (document.RootElement.ValueKind != JsonValueKind.Object)
                {
                    return [];
                }
                return [.. document.RootElement.EnumerateObject()
                    .OrderBy(p => p.Name, StringComparer.Ordinal)
                    .Select(p => new FactField(p.Name, Render(p.Value)))];
            }
            catch (JsonException)
            {
                return [];
            }
        }
    }

    // Strings as they are; containers as compact JSON with sorted keys (the Mac's .sortedKeys); null as "".
    private static string Render(JsonElement value) => value.ValueKind switch
    {
        JsonValueKind.String => value.GetString() ?? "",
        JsonValueKind.Null or JsonValueKind.Undefined => "",
        JsonValueKind.Object or JsonValueKind.Array => Compact(value),
        _ => value.GetRawText(),
    };

    private static string Compact(JsonElement value)
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream))
        {
            Write(writer, value);
        }
        return Encoding.UTF8.GetString(stream.ToArray());

        static void Write(Utf8JsonWriter writer, JsonElement element)
        {
            switch (element.ValueKind)
            {
                case JsonValueKind.Object:
                    writer.WriteStartObject();
                    foreach (JsonProperty property in element.EnumerateObject().OrderBy(p => p.Name, StringComparer.Ordinal))
                    {
                        writer.WritePropertyName(property.Name);
                        Write(writer, property.Value);
                    }
                    writer.WriteEndObject();
                    break;
                case JsonValueKind.Array:
                    writer.WriteStartArray();
                    foreach (JsonElement item in element.EnumerateArray())
                    {
                        Write(writer, item);
                    }
                    writer.WriteEndArray();
                    break;
                default:
                    element.WriteTo(writer);
                    break;
            }
        }
    }
}

/// <summary>
/// The Facts page: search and filters, the fact list in pages of 200 with Load More, counts from
/// <c>GetFactStats</c>, and the selected fact's grounding. The Mac's <c>FactsView</c>.
/// </summary>
public sealed partial class FactsViewModel(GarageService.GarageServiceClient client) : ObservableObject
{
    /// <summary>Facts per page, as on the Mac.</summary>
    public const int PageSize = 200;

    private static readonly TimeSpan CallTimeout = TimeSpan.FromSeconds(60);
    private int _generation;

    /// <summary>Full-text or substring match on the fact.</summary>
    [ObservableProperty]
    public partial string SearchText { get; set; } = "";

    /// <summary>Source filter.</summary>
    [ObservableProperty]
    public partial string Source { get; set; } = CorpusTaxonomy.All;

    /// <summary>Fact class ("Kind") filter.</summary>
    [ObservableProperty]
    public partial string FactClass { get; set; } = CorpusTaxonomy.All;

    /// <summary>Corpus class filter.</summary>
    [ObservableProperty]
    public partial string CorpusClass { get; set; } = CorpusTaxonomy.All;

    /// <summary>Facts matching the filters.</summary>
    [ObservableProperty]
    public partial long TotalCount { get; private set; }

    /// <summary>Documents with at least one matching fact (<c>GetFactStats</c>).</summary>
    [ObservableProperty]
    public partial long? DocumentCount { get; private set; }

    /// <summary>Whether the first page is loading.</summary>
    [ObservableProperty]
    public partial bool IsLoading { get; private set; }

    /// <summary>Whether another page is loading.</summary>
    [ObservableProperty]
    public partial bool IsLoadingMore { get; private set; }

    /// <summary>Why the list failed to load.</summary>
    [ObservableProperty]
    public partial string? ErrorMessage { get; private set; }

    /// <summary>The selected fact.</summary>
    [ObservableProperty]
    public partial FactListItem? Selected { get; set; }

    /// <summary>The loaded facts.</summary>
    public ObservableCollection<FactListItem> Facts { get; } = [];

    /// <summary>Fact classes on offer under the other filters, most common first.</summary>
    public ObservableCollection<FactClassCount> Classes { get; } = [];

    /// <summary>Corpus class choices.</summary>
    public IReadOnlyList<string> CorpusClasses { get; } = CorpusTaxonomy.WithAll(CorpusTaxonomy.CorpusClasses);

    /// <summary>Source choices, filled by <see cref="LoadSourcesAsync"/>.</summary>
    public ObservableCollection<string> Sources { get; } = [CorpusTaxonomy.All];

    /// <summary>Whether more facts match than are loaded.</summary>
    public bool CanLoadMore => !IsLoading && !IsLoadingMore && Facts.Count < TotalCount;

    /// <summary>"1,204 facts from 87 documents".</summary>
    public string CountText => DocumentCount is { } documents
        ? string.Create(CultureInfo.CurrentCulture, $"{Plural(TotalCount, "fact")} from {Plural(documents, "document")}")
        : Plural(TotalCount, "fact");

    /// <summary>What the list says when empty, or null.</summary>
    public (string Title, string Detail)? EmptyState => IsLoading || Facts.Count > 0
        ? null
        : ErrorMessage is { } error
            ? ("Failed to Load Facts", error)
            : ("No Facts Found", "No facts match these filters. Facts appear after Glean Facts runs on your documents.");

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

    /// <summary>Loads the first page and the counts under the current filters.</summary>
    public async Task RefreshAsync(CancellationToken cancellationToken = default)
    {
        int generation = ++_generation;
        IsLoading = true;
        ErrorMessage = null;
        Notify();
        try
        {
            ListFactsResponse page = await client.ListFactsAsync(ListRequest(0), Options(cancellationToken)).ConfigureAwait(true);
            FactStatsResponse stats = await client.GetFactStatsAsync(StatsRequest(), Options(cancellationToken)).ConfigureAwait(true);
            if (generation != _generation)
            {
                return;
            }
            Facts.Clear();
            foreach (FactSummary summary in page.Facts)
            {
                Facts.Add(FactListItem.From(summary));
            }
            Classes.Clear();
            foreach (Garage.FactClassCount count in page.Classes)
            {
                Classes.Add(new FactClassCount(count.FactClass, count.Count));
            }
            TotalCount = page.TotalCount;
            DocumentCount = stats.Documents;
            if (Selected is { } selected && Facts.All(f => f.Id != selected.Id))
            {
                Selected = null;
            }
        }
        catch (RpcException ex) when (generation == _generation)
        {
            ErrorMessage = RpcErrors.Describe(ex);
        }
        finally
        {
            if (generation == _generation)
            {
                IsLoading = false;
                Notify();
            }
        }
    }

    /// <summary>Appends the next page.</summary>
    public async Task LoadMoreAsync(CancellationToken cancellationToken = default)
    {
        if (!CanLoadMore)
        {
            return;
        }
        int generation = _generation;
        IsLoadingMore = true;
        Notify();
        try
        {
            ListFactsResponse page = await client.ListFactsAsync(ListRequest(Facts.Count), Options(cancellationToken)).ConfigureAwait(true);
            if (generation == _generation)
            {
                foreach (FactSummary summary in page.Facts)
                {
                    Facts.Add(FactListItem.From(summary));
                }
                TotalCount = page.TotalCount;
            }
        }
        catch (RpcException ex) when (generation == _generation)
        {
            ErrorMessage = RpcErrors.Describe(ex);
        }
        finally
        {
            IsLoadingMore = false;
            Notify();
        }
    }

    /// <summary>The running Glean's latest step, e.g. "Gleaning facts… 12 of 240".</summary>
    [ObservableProperty]
    public partial string? GleanProgress { get; private set; }

    /// <summary>The running Glean's fraction.</summary>
    [ObservableProperty]
    public partial double? GleanFraction { get; private set; }

    /// <summary>
    /// Distills facts from every document whose prompts, content or model changed since its last run
    /// (<c>stale_only</c>, as Update Everything does on the Mac), on <paramref name="runner"/>, reporting
    /// each document; reloads the list when it ends. Cancel stops it at the next document.
    /// </summary>
    public async Task<Operations.OperationResult> GleanAsync(Operations.OperationRunner runner, State.INotifier? notifier = null)
    {
        ArgumentNullException.ThrowIfNull(runner);
        Operations.OperationResult result = await runner.RunAsync(async (log, token) =>
        {
            GleanProgress = "Starting…";
            GleanFraction = null;
            string summary = "";
            try
            {
                using AsyncServerStreamingCall<EnrichFactsStatus> call = client.EnrichFacts(
                    new EnrichFactsRequest { StaleOnly = true }, new CallOptions(cancellationToken: token));
                await foreach (EnrichFactsStatus step in call.ResponseStream.ReadAllAsync(token).ConfigureAwait(true))
                {
                    switch (step.Phase)
                    {
                        case "started":
                            GleanProgress = string.Create(CultureInfo.CurrentCulture, $"Gleaning facts from {Plural(step.Total, "document")} with {step.Model} via {step.Provider}…");
                            break;
                        case "document":
                            GleanFraction = step.Total > 0 ? Math.Clamp((double)step.Index / step.Total, 0, 1) : null;
                            GleanProgress = string.Create(CultureInfo.CurrentCulture, $"Gleaning facts… {step.Index:N0} of {step.Total:N0}");
                            if (!string.IsNullOrEmpty(step.Error))
                            {
                                log.AppendLog($"{step.DocumentUri}: {step.Error}", Operations.LogChannel.Stderr);
                            }
                            break;
                        case "finished":
                            summary = string.IsNullOrEmpty(step.Message)
                                ? string.Create(CultureInfo.CurrentCulture, $"Gleaned facts from {Plural(step.Enriched, "document")}; {step.Skipped:N0} unchanged, {step.Failed:N0} failed")
                                : step.Message;
                            break;
                    }
                }
                (notifier ?? State.SilentNotifier.Instance).Notify("Facts gleaned", summary);
                return summary;
            }
            finally
            {
                GleanProgress = null;
                GleanFraction = null;
            }
        }).ConfigureAwait(true);
        await RefreshAsync().ConfigureAwait(true);
        return result;
    }

    private ListFactsRequest ListRequest(int offset) => new()
    {
        Query = SearchText.Trim(),
        Source = CorpusTaxonomy.Filter(Source) ?? "",
        FactClass = CorpusTaxonomy.Filter(FactClass) ?? "",
        CorpusClass = CorpusTaxonomy.Filter(CorpusClass) ?? "",
        Limit = PageSize,
        Offset = offset,
    };

    private FactStatsRequest StatsRequest() => new()
    {
        Query = SearchText.Trim(),
        Source = CorpusTaxonomy.Filter(Source) ?? "",
        FactClass = CorpusTaxonomy.Filter(FactClass) ?? "",
        CorpusClass = CorpusTaxonomy.Filter(CorpusClass) ?? "",
    };

    private static CallOptions Options(CancellationToken cancellationToken) =>
        new(deadline: DateTime.UtcNow + CallTimeout, cancellationToken: cancellationToken);

    private static string Plural(long count, string word) =>
        string.Create(CultureInfo.CurrentCulture, $"{count:N0} {(count == 1 ? word : word + "s")}");

    private void Notify()
    {
        OnPropertyChanged(nameof(CountText));
        OnPropertyChanged(nameof(EmptyState));
        OnPropertyChanged(nameof(CanLoadMore));
    }
}

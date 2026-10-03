using System.Globalization;
using Garage.App.Core.Presentation;
using Garage.App.Core.Sources;

namespace Garage.App.Core.Library;

/// <summary>A whole-pipeline run's steps, for the "Scan › Read › Index › Glean" trail.</summary>
public enum LibraryStage
{
    /// <summary>Counting what the sources hold.</summary>
    Scan,

    /// <summary>Reading documents into the database (ingest).</summary>
    Read,

    /// <summary>Embedding new chunks with every model (backfill).</summary>
    Index,

    /// <summary>Gleaning facts from new documents.</summary>
    Glean,
}

/// <summary>What the pipeline is doing now (the Mac's <c>IndexingPresentation.Activity</c>).</summary>
public abstract record LibraryActivity
{
    private LibraryActivity()
    {
    }

    /// <summary>Nothing runs.</summary>
    public sealed record Idle : LibraryActivity;

    /// <summary>A scan of <paramref name="Source"/> ("*" for every source).</summary>
    public sealed record Scanning(string Source, long ItemsSoFar) : LibraryActivity;

    /// <summary>An ingest; <paramref name="Subject"/> is the source, or null for every source.</summary>
    public sealed record Ingesting(string? Subject, string? Current, SourceIngestSnapshot? Run) : LibraryActivity;

    /// <summary>A backfill; the Models page shows each model's progress.</summary>
    public sealed record Embedding(string? Progress, double? Fraction) : LibraryActivity;

    /// <summary>Fact gleaning; the Facts page shows its progress.</summary>
    public sealed record Distilling(string? Progress, double? Fraction) : LibraryActivity;

    /// <summary>Sources waiting in the queue, nothing running yet.</summary>
    public sealed record Waiting(IReadOnlyList<string> Queued) : LibraryActivity;

    /// <summary>The shared idle value.</summary>
    public static LibraryActivity None { get; } = new Idle();
}

/// <summary>The Library box's one action.</summary>
public enum LibraryAction
{
    /// <summary>No sources: send the person to the Sources page.</summary>
    AddSource,

    /// <summary>Run the whole pipeline now.</summary>
    UpdateEverything,

    /// <summary>A run is going: stop it after its current step.</summary>
    Stop,
}

/// <summary>The Library box's headline: symbol, title, bar and detail.</summary>
/// <remarks><c>Progress</c> null hides the bar; <c>IsIndeterminate</c> moves it without a fraction.</remarks>
public sealed record LibraryHeadline(
    StatusSymbol Symbol,
    Tint Tint,
    bool IsActive,
    string Title,
    string? Percent = null,
    string? Detail = null,
    bool DetailIsError = false,
    string? CurrentItem = null,
    double? Progress = null,
    bool IsIndeterminate = false,
    LibraryStage? Stage = null);

/// <summary>
/// The Library box on Status and the activity banner on Sources: what the pipeline is doing, or how
/// much of the corpus is left to index. A port of the Mac's <c>IndexingPresentation</c>, without the
/// "documents to glean" count, which <c>GetStats</c> does not report.
/// </summary>
/// <param name="Sources">The registered sources (their scanned totals give "documents to read").</param>
/// <param name="Stats">The corpus counts.</param>
/// <param name="ModelCount">Registered embedding models.</param>
/// <param name="Activity">What runs now.</param>
/// <param name="IsStopping">Stop was pressed and the run has not ended yet.</param>
/// <param name="LastRunError">The last run's failure, shown in place of the detail.</param>
/// <param name="BackendIsRunning">Whether the backend answers.</param>
public sealed record LibraryPresentation(
    IReadOnlyList<RegisteredSource> Sources,
    Database.CorpusStats Stats,
    int ModelCount,
    LibraryActivity Activity,
    bool IsStopping = false,
    string? LastRunError = null,
    bool BackendIsRunning = true)
{
    /// <summary>Whether a run is under way.</summary>
    public bool IsRunning => Activity is not LibraryActivity.Idle;

    /// <summary>Documents the scans found that are not read yet, across the sources.</summary>
    public long DocumentsToRead => Sources.Where(s => s.Enabled).Sum(s => Math.Max(0, s.ExpectedElements - s.DocumentCount));

    /// <summary>Vectors missing across every model.</summary>
    public long ChunksToIndex => ModelCount > 0
        ? Math.Max(0, (Stats.TotalChunks * ModelCount) - Stats.Models.Sum(m => Math.Min(m.EmbeddedCount, Stats.TotalChunks)))
        : 0;

    /// <summary>The box's action.</summary>
    public LibraryAction Action => IsRunning ? LibraryAction.Stop
        : BackendIsRunning && SourceCount == 0 ? LibraryAction.AddSource
        : LibraryAction.UpdateEverything;

    /// <summary>Whether Update Everything can start.</summary>
    public bool CanUpdateEverything => BackendIsRunning && SourceCount > 0 && !IsRunning;

    private int SourceCount => Math.Max(Sources.Count, (int)Stats.SourcesCount);

    /// <summary>The headline for the current state.</summary>
    public LibraryHeadline Headline()
    {
        switch (Activity)
        {
            case LibraryActivity.Scanning scan:
                string what = scan.Source is "*" or "" ? "all sources" : scan.Source;
                return new(StatusSymbol.Search, Tint.Blue, true, IsStopping ? "Stopping…" : $"Scanning {what}…",
                    Detail: scan.ItemsSoFar > 0 ? N($"{scan.ItemsSoFar:N0} items so far") : "Counting what there is to index.",
                    IsIndeterminate: true, Stage: LibraryStage.Scan);
            case LibraryActivity.Ingesting ingest:
                string title = !string.IsNullOrEmpty(ingest.Subject) ? $"Reading {ingest.Subject}"
                    : !string.IsNullOrEmpty(ingest.Current) && ingest.Current != "*" ? $"Reading all sources · {ingest.Current}"
                    : "Reading all sources";
                SourceIngestSnapshot? run = ingest.Run;
                return new(StatusSymbol.Download, Tint.Blue, true, IsStopping ? "Stopping…" : title,
                    Percent: run?.Fraction is not null ? run.Percent : null,
                    Detail: run is null ? "Starting…" : SourceRowPresentation.RunCounts(run.Seen, run.Total, run.Indexed, run.Skipped, run.Failed, run.ItemType),
                    CurrentItem: run?.CurrentItem,
                    Progress: run?.Fraction, IsIndeterminate: run?.Fraction is null, Stage: LibraryStage.Read);
            case LibraryActivity.Embedding embed:
                return new(StatusSymbol.Working, Tint.Blue, true, IsStopping ? "Stopping…" : "Indexing new chunks",
                    Percent: Percent(embed.Fraction),
                    Detail: embed.Progress ?? "Vectors for every registered model. The Models page shows each model's progress.",
                    Progress: embed.Fraction, IsIndeterminate: embed.Fraction is null, Stage: LibraryStage.Index);
            case LibraryActivity.Distilling glean:
                return new(StatusSymbol.Quote, Tint.Blue, true, IsStopping ? "Stopping…" : "Gleaning facts",
                    Percent: Percent(glean.Fraction),
                    Detail: glean.Progress ?? "Facts for each document no prompt has distilled yet.",
                    Progress: glean.Fraction, IsIndeterminate: glean.Fraction is null, Stage: LibraryStage.Glean);
            case LibraryActivity.Waiting waiting:
                return new(StatusSymbol.Clock, Tint.Secondary, true, WaitingTitle(waiting.Queued),
                    Detail: "Each source gets its read once the current step ends.", IsIndeterminate: true);
        }

        if (!BackendIsRunning)
        {
            return new(StatusSymbol.Paused, Tint.Secondary, false, "Backend stopped", Detail: "Your library updates once Garage's services run.");
        }
        if (SourceCount == 0)
        {
            return new(StatusSymbol.Tray, Tint.Secondary, false, "Nothing to index yet", Detail: "Add a folder on the Sources page and Garage indexes it.");
        }
        string? error = FirstLine(LastRunError);
        if (Stats.DocumentsCount == 0 && Sources.All(s => s.ExpectedElements == 0))
        {
            return new(StatusSymbol.Tray, Tint.Orange, false, "Not indexed yet",
                Detail: error ?? N($"{SourceCount:N0} {Plural("source", SourceCount)} · Update Everything scans, reads, indexes and gleans them."),
                DetailIsError: error is not null);
        }
        long read = DocumentsToRead;
        long index = ChunksToIndex;
        if (read + index > 0)
        {
            List<string> parts = [];
            if (read > 0)
            {
                parts.Add(N($"{read:N0} {Plural("document", read)} to read"));
            }
            if (index > 0)
            {
                parts.Add(N($"{index:N0} {Plural("chunk", index)} to index"));
            }
            double? fraction = Fraction();
            return new(StatusSymbol.Pending, Tint.Orange, false, N($"{read + index:N0} {Plural("item", read + index)} to index"),
                Percent: Percent(fraction), Detail: error ?? string.Join(" · ", parts), DetailIsError: error is not null, Progress: fraction);
        }
        return new(StatusSymbol.Checkmark, Tint.Green, true, "Up to date", Detail: error ?? CorpusLine(), DetailIsError: error is not null);
    }

    /// <summary>"Waiting to read notes, mail", "Waiting to read a, b, c and 2 more".</summary>
    public static string WaitingTitle(IReadOnlyList<string> queued)
    {
        ArgumentNullException.ThrowIfNull(queued);
        string names = string.Join(", ", queued.Take(3));
        string more = queued.Count > 3 ? N($" and {queued.Count - 3} more") : "";
        return $"Waiting to read {names}{more}";
    }

    /// <summary>"1,234 documents in 3 sources · indexed with 2 models".</summary>
    public string CorpusLine()
    {
        string line = N($"{Stats.DocumentsCount:N0} {Plural("document", Stats.DocumentsCount)} in {SourceCount:N0} {Plural("source", SourceCount)}");
        return ModelCount > 0 && Stats.TotalChunks > 0 ? N($"{line} · indexed with {ModelCount:N0} {Plural("model", ModelCount)}") : line;
    }

    // Reading and indexing weigh the same, as on the Mac; a step that does not apply is left out.
    private double? Fraction()
    {
        List<double> parts = [];
        long expected = Sources.Where(s => s.Enabled).Sum(s => Math.Max(s.ExpectedElements, s.DocumentCount));
        if (expected > 0)
        {
            parts.Add(Math.Clamp(1 - ((double)DocumentsToRead / expected), 0, 1));
        }
        if (ModelCount > 0 && Stats.TotalChunks > 0)
        {
            parts.Add(Math.Clamp(1 - ((double)ChunksToIndex / (Stats.TotalChunks * ModelCount)), 0, 1));
        }
        return parts.Count == 0 ? null : parts.Average();
    }

    private static string? Percent(double? fraction) =>
        fraction is { } f ? string.Create(CultureInfo.InvariantCulture, $"{Math.Floor(Math.Clamp(f, 0, 1) * 100):0}%") : null;

    private static string? FirstLine(string? text) =>
        text?.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).FirstOrDefault();

    private static string Plural(string noun, long count) => count == 1 ? noun : noun + "s";

    private static string N(FormattableString text) => text.ToString(CultureInfo.CurrentCulture);
}

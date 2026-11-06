using System.Globalization;
using Garage.App.Core.Database;
using Garage.App.Core.Library;
using Garage.App.Core.Presentation;

namespace Garage.App.Core.Tray;

/// <summary>The MCP server as the tray reports it.</summary>
public enum TrayServerState
{
    /// <summary>Not running, though HTTP is on.</summary>
    Stopped,

    /// <summary>Starting.</summary>
    Starting,

    /// <summary>Serving over HTTP.</summary>
    Running,

    /// <summary>Stopping.</summary>
    Stopping,

    /// <summary>Failed to start.</summary>
    Failed,

    /// <summary>HTTP is off by choice: assistants run Garage over stdio, so nothing is wrong.</summary>
    Stdio,
}

/// <summary>The MCP server, with how many assistants are registered with it.</summary>
public sealed record TrayServer(TrayServerState State, int Clients = 0, string? Message = null)
{
    /// <summary>Stopped.</summary>
    public static TrayServer Stopped { get; } = new(TrayServerState.Stopped);
}

/// <summary>A running ingest, as the tray reports it.</summary>
public sealed record TrayIngestProgress(
    string Source,
    long Processed = 0,
    long Total = 0,
    string ItemType = "documents",
    string? CurrentItem = null,
    double? ReportedFraction = null)
{
    /// <summary>0…1 when anything is known about how far along it is.</summary>
    public double? Fraction => Total > 0
        ? Math.Clamp((double)Processed / Total, 0, 1)
        : ReportedFraction is { } reported ? Math.Clamp(reported, 0, 1) : null;
}

/// <summary>What the pipeline is doing.</summary>
public abstract record TrayActivity
{
    private TrayActivity()
    {
    }

    /// <summary>Nothing.</summary>
    public sealed record Idle : TrayActivity;

    /// <summary>Counting; <paramref name="ItemsSoFar"/> is null until the scan reports anything.</summary>
    public sealed record Scanning(long? ItemsSoFar) : TrayActivity;

    /// <summary>Reading documents.</summary>
    public sealed record Ingesting(TrayIngestProgress Progress) : TrayActivity;

    /// <summary>Embedding.</summary>
    public sealed record Embedding : TrayActivity;

    /// <summary>Gleaning facts.</summary>
    public sealed record Distilling : TrayActivity;

    /// <summary>The shared idle value.</summary>
    public static TrayActivity None { get; } = new Idle();
}

/// <summary>Something the user has to act on or know about, in the order the flyout lists them.</summary>
public sealed record TrayAttention(TrayAttentionKind Kind, string? Message = null);

/// <summary>The kinds of <see cref="TrayAttention"/>.</summary>
public enum TrayAttentionKind
{
    /// <summary>The database failed.</summary>
    DatabaseFailed,

    /// <summary>The schema needs updates.</summary>
    DatabaseNeedsMigration,

    /// <summary>The MCP server failed while the database runs.</summary>
    McpFailed,

    /// <summary>The last ingest failed.</summary>
    IngestFailed,
}

/// <summary>The notification-area icon's picture.</summary>
public enum TrayIconKind
{
    /// <summary>The database serves (the Mac's open garage door).</summary>
    Open,

    /// <summary>The database is down (closed door).</summary>
    Closed,

    /// <summary>Something blocks the app.</summary>
    Warning,
}

/// <summary>The flyout's one services row: "All systems go", or the worst problem in a few words.</summary>
public sealed record TraySummary(StatusSymbol Symbol, string Title, string Detail, Tint Tint);

/// <summary>
/// Everything the notification-area icon and its flyout say, from plain values so it is tested
/// without an app (the Mac's <c>MenuBarStatus</c>, case for case). Two services matter to someone
/// glancing at the tray, the database and the MCP server, plus what the pipeline is doing.
/// </summary>
public sealed record TrayStatus(
    PostgresStatus Database,
    TrayServer? Mcp = null,
    TrayActivity? Activity = null,
    string? LastIngestError = null,
    long SourceCount = 0,
    long DocumentCount = 0,
    bool IsCancellingIngest = false)
{
    /// <summary>The MCP server.</summary>
    public TrayServer Server => Mcp ?? TrayServer.Stopped;

    /// <summary>The pipeline.</summary>
    public TrayActivity Doing => Activity ?? TrayActivity.None;

    private PostgresState Db => Database.State;

    /// <summary>The pipeline is running.</summary>
    public bool IsBusy => Doing is not TrayActivity.Idle;

    /// <summary>The database is on its way up or down.</summary>
    public bool IsDatabaseTransitioning => Db is PostgresState.Starting or PostgresState.Stopping;

    /// <summary>The stage the pipeline is on, or null when idle.</summary>
    public LibraryStage? Stage => Doing switch
    {
        TrayActivity.Scanning => LibraryStage.Scan,
        TrayActivity.Ingesting => LibraryStage.Read,
        TrayActivity.Embedding => LibraryStage.Index,
        TrayActivity.Distilling => LibraryStage.Glean,
        _ => null,
    };

    /// <summary>The trail under the bar: all four, so a run that stops at Index reads as three of four.</summary>
    public IReadOnlyList<LibraryStage> StageTrail { get; } = [LibraryStage.Scan, LibraryStage.Read, LibraryStage.Index, LibraryStage.Glean];

    /// <summary>
    /// What needs the user, worst first. An MCP failure while the database is down is a consequence,
    /// not a second problem, so it is listed only while the database runs.
    /// </summary>
    public IReadOnlyList<TrayAttention> Attentions
    {
        get
        {
            List<TrayAttention> list = [];
            if (Db == PostgresState.Failed)
            {
                list.Add(new(TrayAttentionKind.DatabaseFailed, Database.FailureMessage));
            }
            else if (Db == PostgresState.NeedsMigration)
            {
                list.Add(new(TrayAttentionKind.DatabaseNeedsMigration));
            }
            if (Db == PostgresState.Running && Server.State == TrayServerState.Failed)
            {
                list.Add(new(TrayAttentionKind.McpFailed, Server.Message));
            }
            if (!IsBusy && !string.IsNullOrEmpty(LastIngestError))
            {
                list.Add(new(TrayAttentionKind.IngestFailed, LastIngestError));
            }
            return list;
        }
    }

    /// <summary>The icon swaps to a warning only for what blocks the app, not for an ingest that failed on one file.</summary>
    public bool NeedsAttention => Attentions.Any(a => a.Kind != TrayAttentionKind.IngestFailed);

    /// <summary>The database runs and the MCP server serves (or HTTP is off by choice).</summary>
    public bool AllSystemsGo => Db == PostgresState.Running && Server.State is TrayServerState.Running or TrayServerState.Stdio;

    /// <summary>The line under "All systems go".</summary>
    public string AllSystemsGoDetail => Server.State switch
    {
        TrayServerState.Stdio => "Database running · " + Assistants(Server.Clients),
        TrayServerState.Running => "Database and MCP running · " + Assistants(Server.Clients),
        _ => "Database and MCP running",
    };

    /// <summary>The services row.</summary>
    public TraySummary Summary
    {
        get
        {
            const string Fix = "Open Status to fix it.";
            switch (Db)
            {
                case PostgresState.Failed:
                    return new(StatusSymbol.Warning, "Database failed to start", FirstLine(Database.FailureMessage) ?? Fix, Tint.Red);
                case PostgresState.NeedsMigration:
                    return new(StatusSymbol.Warning, "Database needs a schema update", "Open Status to apply it.", Tint.Orange);
                case PostgresState.Stopped:
                    return new(StatusSymbol.Paused, "Database stopped", "Open Status to start it.", Tint.Secondary);
                case PostgresState.Starting:
                    return new(StatusSymbol.Pending, "Starting up…", "Database, MCP and search come up together.", Tint.Yellow);
                case PostgresState.Stopping:
                    return new(StatusSymbol.Pending, "Shutting down…", "Waiting for connections to close.", Tint.Yellow);
                default:
                    break;
            }
            return Server.State switch
            {
                TrayServerState.Running or TrayServerState.Stdio => new(StatusSymbol.Checkmark, "All systems go", AllSystemsGoDetail, Tint.Green),
                TrayServerState.Failed => new(StatusSymbol.Warning, "MCP server failed", FirstLine(Server.Message) ?? Fix, Tint.Red),
                TrayServerState.Stopped => new(StatusSymbol.Warning, "MCP server not running", $"Claude can't reach your corpus. {Fix}", Tint.Orange),
                _ => new(StatusSymbol.Pending, "MCP server restarting…", "Database is running.", Tint.Yellow),
            };
        }
    }

    /// <summary>Whether the activity title carries a status dot; idle on a running database leads with the corpus instead.</summary>
    public bool ShowsActivityDot => !(Doing is TrayActivity.Idle && Db == PostgresState.Running);

    /// <summary>Ingest Now is offered when it could do something.</summary>
    public bool CanIngest => Db == PostgresState.Running && !IsBusy && SourceCount > 0;

    /// <summary>Quick search needs the database.</summary>
    public bool CanSearch => Db == PostgresState.Running;

    /// <summary>Ask Garage runs <c>rag_agent</c> on the MCP server, so it needs the server up as well.</summary>
    public bool CanAsk => CanSearch && Server.State == TrayServerState.Running;

    /// <summary>The icon: open while the database serves, closed while it is down, a warning when something blocks the app.</summary>
    public TrayIconKind Icon => NeedsAttention
        ? TrayIconKind.Warning
        : Db is PostgresState.Running or PostgresState.NeedsMigration ? TrayIconKind.Open : TrayIconKind.Closed;

    /// <summary>Whether the icon shows motion: the pipeline runs, or the database is coming up.</summary>
    public bool IsPulsing => !NeedsAttention && (Db == PostgresState.Starting || (Db == PostgresState.Running && IsBusy));

    /// <summary>The icon's tooltip and accessible name.</summary>
    public string AccessibilityLabel => $"Garage, {Headline}";

    /// <summary>The one-line summary.</summary>
    public string Headline => Db switch
    {
        PostgresState.Stopped => "Database stopped",
        PostgresState.Starting => "Starting…",
        PostgresState.Stopping => "Stopping…",
        PostgresState.NeedsMigration => "Schema update needed",
        PostgresState.Failed => "Database failed",
        _ => Doing switch
        {
            TrayActivity.Scanning => "Scanning sources",
            TrayActivity.Ingesting { Progress.Source: "" } => "Reading",
            TrayActivity.Ingesting ingesting => $"Reading {ingesting.Progress.Source}",
            TrayActivity.Embedding => "Indexing chunks",
            TrayActivity.Distilling => "Gleaning facts",
            _ => "Ready",
        },
    };

    /// <summary>What is in the corpus, while idle.</summary>
    public string CorpusLine => SourceCount == 0
        ? "No sources yet"
        : DocumentCount == 0
            ? "No documents yet"
            : string.Create(CultureInfo.CurrentCulture,
                $"{DocumentCount:N0} {(DocumentCount == 1 ? "document" : "documents")} in {SourceCount:N0} {(SourceCount == 1 ? "source" : "sources")}");

    /// <summary>The counts under the bar while busy, or null.</summary>
    public string? ActivityDetail => Doing switch
    {
        TrayActivity.Scanning { ItemsSoFar: { } found } => string.Create(CultureInfo.CurrentCulture, $"{found:N0} items found so far"),
        TrayActivity.Ingesting ingesting => ProgressLine(ingesting.Progress.Processed, ingesting.Progress.Total, ingesting.Progress.ItemType),
        TrayActivity.Embedding => "Vectors for every registered model",
        TrayActivity.Distilling => "Facts for each new document",
        _ => null,
    };

    /// <summary>The ingest's fraction, while ingesting.</summary>
    public double? IngestFraction => Doing is TrayActivity.Ingesting ingesting ? ingesting.Progress.Fraction : null;

    /// <summary>The file being read, when one is.</summary>
    public string? CurrentItem => Doing is TrayActivity.Ingesting { Progress.CurrentItem: { Length: > 0 } item } ? item : null;

    /// <summary>The database row's detail.</summary>
    public string DatabaseDetail => Db switch
    {
        PostgresState.Stopped => "Stopped",
        PostgresState.Starting => "Starting…",
        PostgresState.Stopping => "Stopping…",
        PostgresState.Running => "Running",
        PostgresState.NeedsMigration => "Schema update needed",
        _ => Database.FailureMessage ?? "Failed",
    };

    /// <summary>The MCP row's detail.</summary>
    public string McpDetail => Server.State switch
    {
        TrayServerState.Stopped => Db == PostgresState.Running ? "Not running" : "Waits for the database",
        TrayServerState.Starting => "Starting…",
        TrayServerState.Running => "Serving · " + Assistants(Server.Clients),
        TrayServerState.Stdio => "Over stdio · " + Assistants(Server.Clients),
        TrayServerState.Stopping => "Stopping…",
        _ => Server.Message ?? "Failed",
    };

    /// <summary>The flyout's overall tint, for the dot beside the headline.</summary>
    public Tint Tint => Db switch
    {
        PostgresState.Running => IsBusy ? Tint.Blue : Tint.Green,
        PostgresState.Starting or PostgresState.Stopping => Tint.Yellow,
        PostgresState.NeedsMigration => Tint.Orange,
        PostgresState.Failed => Tint.Red,
        _ => Tint.Secondary,
    };

    /// <summary>"42%", clamped.</summary>
    public static string Percent(double fraction) =>
        string.Create(CultureInfo.InvariantCulture, $"{(int)Math.Round(Math.Clamp(fraction, 0, 1) * 100, MidpointRounding.AwayFromZero)}%");

    /// <summary>"1,204 of 2,860 documents", or the processed count until a scan has sized the run.</summary>
    public static string ProgressLine(long processed, long total, string itemType)
    {
        string noun = string.IsNullOrEmpty(itemType) ? "documents" : itemType;
        return total > 0
            ? string.Create(CultureInfo.CurrentCulture, $"{processed:N0} of {total:N0} {noun}")
            : string.Create(CultureInfo.CurrentCulture, $"{processed:N0} {noun}");
    }

    /// <summary>A path under the home folder shown as <c>~\…</c>.</summary>
    public static string AbbreviatedPath(string path, string home) =>
        Onboarding.FirstRunSourceTemplate.AbbreviatedPath(path, home);

    /// <summary>An error's first line, trimmed, or null when there is nothing to show.</summary>
    public static string? FirstLine(string? message)
    {
        string line = (message ?? "").Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()?.Trim() ?? "";
        return line.Length == 0 ? null : line;
    }

    private static string Assistants(int clients) => clients switch
    {
        0 => "no assistants connected",
        1 => "1 assistant connected",
        _ => string.Create(CultureInfo.CurrentCulture, $"{clients} assistants connected"),
    };
}

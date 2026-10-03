using System.Globalization;
using Garage.App.Core.Documents;
using Garage.App.Core.Presentation;

namespace Garage.App.Core.Database;

/// <summary>Where the app's Postgres stands (the Mac's <c>PostgresStatus</c>).</summary>
public enum PostgresState
{
    /// <summary>Starting.</summary>
    Starting,

    /// <summary>Running with the schema up to date.</summary>
    Running,

    /// <summary>Running, with schema updates to apply.</summary>
    NeedsMigration,

    /// <summary>Stopping.</summary>
    Stopping,

    /// <summary>Stopped.</summary>
    Stopped,

    /// <summary>Failed to start.</summary>
    Failed,
}

/// <summary>The Postgres state, with the failure message when <see cref="PostgresState.Failed"/>.</summary>
public sealed record PostgresStatus(PostgresState State, string? FailureMessage = null)
{
    /// <summary>Whether the server answers queries.</summary>
    public bool IsUp => State is PostgresState.Running or PostgresState.NeedsMigration;
}

/// <summary>Counting and sizes, worded as the Mac's <c>DatabasePagePresentation</c>.</summary>
public static class DatabaseWording
{
    /// <summary>"1 update", "2 updates".</summary>
    public static string Count(long value, string word) =>
        string.Create(CultureInfo.CurrentCulture, $"{value:N0} {(value == 1 ? word : word + "s")}");
}

/// <summary>The server row: a symbol, a tint, a title and one line under it (the Mac's <c>DatabaseHeadline</c>).</summary>
public sealed record DatabaseHeadline(StatusSymbol Symbol, Tint Tint, bool IsActive, string Title, string Detail, bool DetailIsError = false)
{
    /// <summary>The row for <paramref name="status"/>; resetting wins over every status.</summary>
    /// <param name="status">Where Postgres stands.</param>
    /// <param name="port">Its port.</param>
    /// <param name="pendingMigrations">Schema updates known to be pending.</param>
    /// <param name="isResetting">Whether Database Reset is under way.</param>
    /// <param name="documents">Documents in the corpus, when known.</param>
    /// <param name="sizeBytes">The database's size on disk, when known.</param>
    public static DatabaseHeadline For(PostgresStatus status, int port, int pendingMigrations, bool isResetting, long? documents, long? sizeBytes)
    {
        ArgumentNullException.ThrowIfNull(status);
        if (isResetting)
        {
            return new(StatusSymbol.Resetting, Tint.Red, true, "Resetting…", "Stopping Garage's services and deleting the database.");
        }
        return status.State switch
        {
            PostgresState.Running when pendingMigrations > 0 => NeedsUpdate(pendingMigrations),
            PostgresState.NeedsMigration => NeedsUpdate(pendingMigrations),
            PostgresState.Running => Running(port, documents, sizeBytes),
            PostgresState.Starting => new(StatusSymbol.Database, Tint.Blue, true, "Starting…",
                string.Create(CultureInfo.InvariantCulture, $"Starting Postgres on port {port}…")),
            PostgresState.Stopping => new(StatusSymbol.Database, Tint.Blue, true, "Stopping…", "Stopping Postgres…"),
            PostgresState.Stopped => new(StatusSymbol.Database, Tint.Secondary, false, "Stopped",
                "Search, ingest and the MCP server need the database running."),
            _ => new(StatusSymbol.Cross, Tint.Red, true, "Couldn't start", status.FailureMessage ?? "", DetailIsError: true),
        };
    }

    private static DatabaseHeadline NeedsUpdate(int pending)
    {
        string updates = pending > 0 ? DatabaseWording.Count(pending, "schema update") : "Schema updates";
        return new(StatusSymbol.Warning, Tint.Orange, true, "Needs a schema update",
            $"{updates} to apply below before search and ingest can use it.");
    }

    // "On this PC" where the Mac says "On this Mac".
    private static DatabaseHeadline Running(int port, long? documents, long? sizeBytes)
    {
        List<string> parts = [string.Create(CultureInfo.InvariantCulture, $"On this PC, port {port}")];
        if (documents is { } count)
        {
            parts.Add(DatabaseWording.Count(count, "document"));
        }
        if (sizeBytes is { } size)
        {
            parts.Add(Bytes.Format(size));
        }
        return new(StatusSymbol.Checkmark, Tint.Green, true, "Running", string.Join(" · ", parts));
    }
}

/// <summary>What the Schema row offers.</summary>
public enum SchemaAction
{
    /// <summary>Apply Updates, prominent: there is something to apply.</summary>
    Apply,

    /// <summary>Check Again, quiet: nothing to do but look again.</summary>
    Check,

    /// <summary>No button: the database is not up, or updates are being applied.</summary>
    Hidden,
}

/// <summary>The Schema box's one row (the Mac's <c>DatabaseSchemaPresentation</c>).</summary>
public sealed record DatabaseSchemaPresentation(StatusSymbol Symbol, Tint Tint, bool IsActive, string Title, string Detail, SchemaAction Action)
{
    private const string Expects =
        "This version of Garage expects schema changes the database doesn't have yet. Your data is kept.";

    /// <summary>The row for the database's state and the migrations it lacks.</summary>
    public static DatabaseSchemaPresentation For(PostgresStatus status, IReadOnlyCollection<string> pendingMigrations, bool isApplying)
    {
        ArgumentNullException.ThrowIfNull(status);
        ArgumentNullException.ThrowIfNull(pendingMigrations);
        if (isApplying)
        {
            return new(StatusSymbol.Applying, Tint.Blue, true, "Applying schema updates…", "Search and ingest wait until they are in.", SchemaAction.Hidden);
        }
        if (!status.IsUp)
        {
            return new(StatusSymbol.Database, Tint.Secondary, false, "Schema", "Checked once the database is running.", SchemaAction.Hidden);
        }
        if (pendingMigrations.Count > 0)
        {
            return new(StatusSymbol.Warning, Tint.Orange, true, $"{DatabaseWording.Count(pendingMigrations.Count, "update")} to apply", Expects, SchemaAction.Apply);
        }
        if (status.State == PostgresState.NeedsMigration)
        {
            return new(StatusSymbol.Warning, Tint.Orange, true, "Schema updates to apply", Expects, SchemaAction.Apply);
        }
        return new(StatusSymbol.Checkmark, Tint.Green, true, "Schema up to date",
            "Every migration this version of Garage carries is applied.", SchemaAction.Check);
    }
}

/// <summary>One embedding model's vector count.</summary>
public sealed record ModelEmbeddingStats(string Slug, bool IsDefault, long EmbeddedCount);

/// <summary>
/// Corpus counts as the Database page uses them (the Mac's <c>CorpusStats</c>, the part the
/// Contents box reads). <see cref="DocumentsFailedCount"/> needs direct database access, which the app
/// does not have yet; from <c>GetStats</c> it is 0.
/// </summary>
public sealed record CorpusStats(
    long SourcesCount = 0,
    long DocumentsCount = 0,
    long DocumentsFailedCount = 0,
    long TotalChunks = 0,
    long EmbeddedChunks = 0,
    IReadOnlyList<ModelEmbeddingStats>? ModelStats = null)
{
    /// <summary>Per-model vector counts; empty when no model is registered.</summary>
    public IReadOnlyList<ModelEmbeddingStats> Models => ModelStats ?? [];

    /// <summary>From a <c>GetStats</c> reply: <c>chunks_by_model</c> is each model's vector count.</summary>
    public static CorpusStats From(StatsResponse stats)
    {
        ArgumentNullException.ThrowIfNull(stats);
        return new(stats.Sources, stats.Documents, 0, stats.Chunks, 0,
            [.. stats.ChunksByModel.OrderBy(p => p.Key, StringComparer.Ordinal).Select(p => new ModelEmbeddingStats(p.Key, false, p.Value))]);
    }

    /// <summary>
    /// How much of the corpus has vectors under every model: embedded vectors over chunks × models,
    /// clamped to 0…1 (the Mac's <c>embeddingProgressFraction</c>).
    /// </summary>
    public double EmbeddingProgressFraction
    {
        get
        {
            long required = Models.Count * TotalChunks;
            if (required <= 0)
            {
                return TotalChunks > 0 && EmbeddedChunks > 0 ? Math.Clamp((double)EmbeddedChunks / TotalChunks, 0, 1) : 0;
            }
            return Math.Clamp((double)Models.Sum(m => m.EmbeddedCount) / required, 0, 1);
        }
    }
}

/// <summary>One figure in the Contents box.</summary>
public sealed record DatabaseFigure(string Label, string Value, string? Note = null, bool NoteIsWarning = false);

/// <summary>The Contents box: what the database holds (the Mac's <c>DatabaseContentsPresentation</c>).</summary>
public sealed record DatabaseContentsPresentation(IReadOnlyList<DatabaseFigure> Figures, bool IsEmpty)
{
    /// <summary>The figures for <paramref name="stats"/>, with the size on disk when known.</summary>
    public static DatabaseContentsPresentation For(CorpusStats stats, long? sizeBytes)
    {
        ArgumentNullException.ThrowIfNull(stats);
        var documents = new DatabaseFigure("Documents", Number(stats.DocumentsCount));
        if (stats.DocumentsFailedCount > 0)
        {
            documents = documents with { Note = $"{Number(stats.DocumentsFailedCount)} failed", NoteIsWarning = true };
        }

        var embedded = new DatabaseFigure("Indexed", "—");
        if (stats.TotalChunks > 0 && stats.Models.Count > 0)
        {
            int percent = (int)Math.Floor(stats.EmbeddingProgressFraction * 100);
            embedded = new DatabaseFigure("Indexed", string.Create(CultureInfo.InvariantCulture, $"{percent}%"), DatabaseWording.Count(stats.Models.Count, "model"));
        }
        else if (stats.Models.Count == 0)
        {
            embedded = embedded with { Note = "No models" };
        }

        List<DatabaseFigure> figures =
        [
            new("Sources", Number(stats.SourcesCount)),
            documents,
            new("Chunks", Number(stats.TotalChunks)),
            embedded,
        ];
        if (sizeBytes is { } size)
        {
            figures.Add(new("On Disk", Bytes.Format(size)));
        }
        return new(figures, stats.DocumentsCount == 0 && stats.TotalChunks == 0);
    }

    private static string Number(long value) => value.ToString("N0", CultureInfo.CurrentCulture);
}

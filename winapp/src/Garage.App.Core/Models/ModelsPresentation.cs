using System.Globalization;
using Garage.App.Core.Database;
using Garage.App.Core.Presentation;

namespace Garage.App.Core.Models;

/// <summary>A model server (the Mac's <c>ModelsView.ModelProvider</c>).</summary>
public enum ModelProvider
{
    /// <summary>Garage's own llama.cpp service (<c>llama_xpc</c>).</summary>
    BuiltIn,

    /// <summary>Ollama.</summary>
    Ollama,

    /// <summary>LM Studio.</summary>
    LmStudio,
}

/// <summary>Provider names both ways, as the Mac parses and shows them.</summary>
public static class ModelProviders
{
    /// <summary>The providers in picker order.</summary>
    public static IReadOnlyList<ModelProvider> All { get; } = [ModelProvider.BuiltIn, ModelProvider.Ollama, ModelProvider.LmStudio];

    /// <summary>From a config or proto string; unknown or empty is the built-in engine, as on the Mac.</summary>
    public static ModelProvider From(string? value) => value?.Trim().ToLowerInvariant() switch
    {
        "ollama" => ModelProvider.Ollama,
        "lmstudio" or "lm studio" or "lm-studio" => ModelProvider.LmStudio,
        _ => ModelProvider.BuiltIn,
    };

    /// <summary>The value the CLI, config and proto take.</summary>
    public static string CliValue(this ModelProvider provider) => provider switch
    {
        ModelProvider.Ollama => "ollama",
        ModelProvider.LmStudio => "lmstudio",
        _ => "llama_xpc",
    };

    /// <summary>What the page calls it.</summary>
    public static string DisplayName(this ModelProvider provider) => provider switch
    {
        ModelProvider.Ollama => "Ollama",
        ModelProvider.LmStudio => "LM Studio",
        _ => "Built-in engine",
    };
}

/// <summary>Where the Embedding headline stands, in the order the Mac checks.</summary>
public enum EmbeddingHeadlineKind
{
    /// <summary>No model registered.</summary>
    NoModel,

    /// <summary>A model's file is not downloaded (built-in engine only).</summary>
    FilesMissing,

    /// <summary>No chunks yet.</summary>
    WaitingForIngest,

    /// <summary>Every chunk embedded under every model.</summary>
    Ready,

    /// <summary>A backfill is running with work left.</summary>
    Embedding,

    /// <summary>Work left, nothing running.</summary>
    ToGo,
}

/// <summary>The Overall headline's row.</summary>
public sealed record ModelsHeadline(StatusSymbol Symbol, Tint Tint, bool IsActive, string Title, string Detail, double? Progress = null);

/// <summary>The Models page's figures and wording, a port of the Mac's <c>ModelsPresentation</c>.</summary>
public static class ModelsPresentation
{
    /// <summary>
    /// Embeddings the models named by <paramref name="modelSlugs"/> need and how many are missing,
    /// counted over the models registered now: a model the stats do not list yet has embedded nothing,
    /// and a model no longer registered does not count.
    /// </summary>
    public static (long Required, long Missing) EmbeddingsRequiredAndMissing(IReadOnlyCollection<string> modelSlugs, CorpusStats stats)
    {
        ArgumentNullException.ThrowIfNull(modelSlugs);
        ArgumentNullException.ThrowIfNull(stats);
        long required = modelSlugs.Count * stats.TotalChunks;
        long missing = modelSlugs.Sum(slug =>
            Math.Max(0, stats.TotalChunks - (stats.Models.FirstOrDefault(m => m.Slug == slug)?.EmbeddedCount ?? 0)));
        return (required, missing);
    }

    /// <summary>"2 models · 9,120 of 10,000 embeddings done", or what is missing for that.</summary>
    public static string EmbeddingSummary(int modelCount, long totalChunks, long required, long missing)
    {
        if (modelCount == 0)
        {
            return "Text embedding models turn each chunk into a vector for semantic search. Each keeps its own vector table; search uses the default one.";
        }
        string models = Models(modelCount);
        if (totalChunks == 0)
        {
            return $"{models} · no chunks to embed until a source is ingested";
        }
        if (missing == 0)
        {
            return $"{models} · every chunk embedded";
        }
        long done = Math.Max(0, required - missing);
        return string.Create(CultureInfo.CurrentCulture, $"{models} · {done:N0} of {required:N0} embeddings done");
    }

    /// <summary>
    /// Whether the running backfill embeds under <paramref name="slug"/>: <paramref name="target"/> is
    /// the model an Embed on this page runs for, "*" for Embed All, or null for a run started
    /// elsewhere, which covers every model.
    /// </summary>
    public static bool IsEmbedding(string slug, bool backfillRunning, string? target) =>
        backfillRunning && (target is null || target == "*" || target == slug);

    /// <summary>The headline's state.</summary>
    public static EmbeddingHeadlineKind HeadlineKind(int modelCount, IReadOnlyCollection<string> missingFileNames, long totalChunks, long missing, bool backfillRunning)
    {
        ArgumentNullException.ThrowIfNull(missingFileNames);
        if (modelCount == 0)
        {
            return EmbeddingHeadlineKind.NoModel;
        }
        if (missingFileNames.Count > 0)
        {
            return EmbeddingHeadlineKind.FilesMissing;
        }
        if (totalChunks == 0)
        {
            return EmbeddingHeadlineKind.WaitingForIngest;
        }
        if (missing == 0)
        {
            return EmbeddingHeadlineKind.Ready;
        }
        return backfillRunning ? EmbeddingHeadlineKind.Embedding : EmbeddingHeadlineKind.ToGo;
    }

    /// <summary>The Overall tab's Embedding card, worded as on the Mac.</summary>
    public static ModelsHeadline Headline(int modelCount, IReadOnlyList<string> missingFileNames, long totalChunks, long required, long missing, bool backfillRunning)
    {
        ArgumentNullException.ThrowIfNull(missingFileNames);
        string models = Models(modelCount);
        double? fraction = required > 0 ? Math.Clamp((double)(required - missing) / required, 0, 1) : null;
        return HeadlineKind(modelCount, missingFileNames, totalChunks, missing, backfillRunning) switch
        {
            EmbeddingHeadlineKind.NoModel => new(StatusSymbol.Warning, Tint.Orange, false, "No embedding model",
                "Search needs one. Register a model below."),
            EmbeddingHeadlineKind.FilesMissing => new(StatusSymbol.Download, Tint.Orange, false, "Model file missing",
                $"{string.Join(", ", missingFileNames)} {(missingFileNames.Count == 1 ? "is" : "are")} not downloaded, so nothing can be embedded with {(missingFileNames.Count == 1 ? "it" : "them")}."),
            EmbeddingHeadlineKind.WaitingForIngest => new(StatusSymbol.Database, Tint.Secondary, false, "Waiting for ingest",
                $"{models} registered; there are no chunks to embed until a source is ingested."),
            EmbeddingHeadlineKind.Ready => new(StatusSymbol.Checkmark, Tint.Green, true, "Search ready",
                string.Create(CultureInfo.CurrentCulture, $"{totalChunks:N0} chunks embedded under {models}.")),
            EmbeddingHeadlineKind.Embedding => new(StatusSymbol.Working, Tint.Blue, true, "Embedding…",
                string.Create(CultureInfo.CurrentCulture, $"{missing:N0} of {required:N0} embeddings to go across {models}."), fraction),
            _ => new(StatusSymbol.Warning, Tint.Orange, false,
                string.Create(CultureInfo.CurrentCulture, $"{missing:N0} embedding{(missing == 1 ? "" : "s")} to go"),
                "Search finds only embedded chunks. Embed All picks up where the last run stopped.", fraction),
        };
    }

    private static string Models(int count) => string.Create(CultureInfo.CurrentCulture, $"{count} model{(count == 1 ? "" : "s")}");
}

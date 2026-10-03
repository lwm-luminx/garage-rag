using System.Collections.ObjectModel;
using System.Globalization;
using System.Text.Json;
using CommunityToolkit.Mvvm.ComponentModel;
using Garage.App.Core.Backend;
using Garage.App.Core.Database;
using Garage.App.Core.Operations;
using Garage.App.Core.State;
using Grpc.Core;

namespace Garage.App.Core.Models;

/// <summary>One registered embedding model and how far it has embedded the corpus.</summary>
public sealed record ModelItem(
    string Slug, ModelProvider Provider, string ModelRef, int Dims, string StorageKind, string Distance,
    bool IsDefault, long Embedded, long TotalChunks)
{
    /// <summary>From a <c>ModelInfo</c> and the corpus counts.</summary>
    public static ModelItem From(ModelInfo info, CorpusStats stats)
    {
        ArgumentNullException.ThrowIfNull(info);
        ArgumentNullException.ThrowIfNull(stats);
        long embedded = stats.Models.FirstOrDefault(m => m.Slug == info.Slug)?.EmbeddedCount ?? 0;
        return new(info.Slug, ModelProviders.From(info.Provider), info.ModelRef, info.Dims, info.StorageKind, info.Distance,
            info.IsDefault, embedded, stats.TotalChunks);
    }

    /// <summary>"Ollama · bge-m3 · 1024 dims · cosine".</summary>
    public string Detail => string.Join(" · ", new[]
    {
        Provider.DisplayName(),
        ModelRef,
        Dims > 0 ? string.Create(CultureInfo.CurrentCulture, $"{Dims} dims") : "",
        Distance,
    }.Where(part => part.Length > 0));

    /// <summary>"2,226 of 2,226 chunks embedded".</summary>
    public string Progress => string.Create(CultureInfo.CurrentCulture, $"{Math.Min(Embedded, TotalChunks):N0} of {TotalChunks:N0} chunks embedded");

    /// <summary>0…1.</summary>
    public double Fraction => TotalChunks > 0 ? Math.Clamp((double)Embedded / TotalChunks, 0, 1) : 0;
}

/// <summary>What the Register Model form sends.</summary>
public sealed record NewModel(string Slug, ModelProvider Provider, int Dims = 0, string ModelRef = "", bool MakeDefault = false);

/// <summary>
/// The Models page: the registered embedding models with their progress, the headline and summary,
/// Register / Set Default / Drop (on the ordinary runner), Embed (backfill, on its own runner, streaming
/// its progress), and the distillation model (<c>facts.provider</c> / <c>facts.model</c>).
/// </summary>
public sealed partial class ModelsViewModel : ObservableObject
{
    private static readonly TimeSpan CallTimeout = TimeSpan.FromSeconds(60);

    private readonly GarageService.GarageServiceClient _client;
    private readonly OperationRunner _operations;
    private readonly OperationRunner _backfill;
    private readonly INotifier _notifier;

    /// <summary>Creates the page's model.</summary>
    public ModelsViewModel(GarageService.GarageServiceClient client, OperationRunner operations, OperationRunner backfill, INotifier? notifier = null)
    {
        _client = client ?? throw new ArgumentNullException(nameof(client));
        _operations = operations ?? throw new ArgumentNullException(nameof(operations));
        _backfill = backfill ?? throw new ArgumentNullException(nameof(backfill));
        _notifier = notifier ?? SilentNotifier.Instance;
        _backfill.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(OperationRunner.IsRunning))
            {
                Recompute();
            }
        };
    }

    /// <summary>The registered models, default first.</summary>
    public ObservableCollection<ModelItem> Models { get; } = [];

    /// <summary>The Embedding card.</summary>
    [ObservableProperty]
    public partial ModelsHeadline? Headline { get; private set; }

    /// <summary>The line under the heading.</summary>
    [ObservableProperty]
    public partial string Summary { get; private set; } = "";

    /// <summary>The running backfill's latest step, e.g. "bge-m3: 1,200 of 2,226 embedded".</summary>
    [ObservableProperty]
    public partial string? BackfillProgress { get; private set; }

    /// <summary>The running backfill's fraction, when it reports one.</summary>
    [ObservableProperty]
    public partial double? BackfillFraction { get; private set; }

    /// <summary>Which model the running Embed covers: a slug, "*", or null for none started here.</summary>
    [ObservableProperty]
    public partial string? BackfillTarget { get; private set; }

    /// <summary>The distillation provider (<c>facts.provider</c>).</summary>
    [ObservableProperty]
    public partial ModelProvider FactsProvider { get; set; }

    /// <summary>The distillation model (<c>facts.model</c>).</summary>
    [ObservableProperty]
    public partial string FactsModel { get; set; } = "";

    /// <summary>Why the page failed to load.</summary>
    [ObservableProperty]
    public partial string? ErrorMessage { get; private set; }

    /// <summary>The last operation's outcome.</summary>
    [ObservableProperty]
    public partial string? LastResult { get; private set; }

    /// <summary>Whether a backfill is running.</summary>
    public bool IsEmbedding => _backfill.IsRunning;

    /// <summary>Whether an ordinary operation is running.</summary>
    public bool IsBusy => _operations.IsRunning;

    private CorpusStats _stats = new();

    /// <summary>Reads the models, the corpus counts and the distillation settings.</summary>
    public async Task LoadAsync(CancellationToken cancellationToken = default)
    {
        ErrorMessage = null;
        try
        {
            ListModelsResponse listed = await _client.ListModelsAsync(new ListModelsRequest(), Options(cancellationToken)).ConfigureAwait(true);
            StatsResponse stats = await _client.GetStatsAsync(new StatsRequest(), Options(cancellationToken)).ConfigureAwait(true);
            _stats = CorpusStats.From(stats);
            Models.Clear();
            foreach (ModelInfo info in listed.Models.OrderByDescending(m => m.IsDefault).ThenBy(m => m.Slug, StringComparer.Ordinal))
            {
                Models.Add(ModelItem.From(info, _stats));
            }
            FactsProvider = ModelProviders.From(await ReadSettingAsync("facts.provider", cancellationToken).ConfigureAwait(true));
            FactsModel = await ReadSettingAsync("facts.model", cancellationToken).ConfigureAwait(true) ?? "";
            Recompute();
        }
        catch (RpcException ex)
        {
            ErrorMessage = RpcErrors.Describe(ex);
        }
    }

    /// <summary>
    /// Called after a model is registered: the app starts Automatic Updates' run, which embeds the
    /// corpus with it (the Mac's <c>triggersMaintenance</c>).
    /// </summary>
    public Action? Registered { get; set; }

    /// <summary>Registers a model (creating its vector table), then reloads.</summary>
    public async Task<OperationResult> RegisterAsync(NewModel model)
    {
        OperationResult result = await RegisterOnlyAsync(model).ConfigureAwait(true);
        if (result.Succeeded)
        {
            Registered?.Invoke();
        }
        return result;
    }

    private Task<OperationResult> RegisterOnlyAsync(NewModel model) => RunAsync(_operations, async (_, token) =>
    {
        ArgumentNullException.ThrowIfNull(model);
        RegisterModelResponse registered = await _client.RegisterModelAsync(new RegisterModelRequest
        {
            Slug = model.Slug.Trim(),
            Provider = model.Provider.CliValue(),
            Dims = model.Dims,
            ModelRef = model.ModelRef.Trim(),
            MakeDefault = model.MakeDefault,
        }, Options(token)).ConfigureAwait(true);
        return string.Join('\n', new[] { registered.Message }.Concat(registered.Notes).Where(line => !string.IsNullOrWhiteSpace(line)));
    });

    /// <summary>Makes <paramref name="slug"/> the model search uses.</summary>
    public Task<OperationResult> SetDefaultAsync(string slug) => RunAsync(_operations, async (_, token) =>
        (await _client.SetDefaultModelAsync(new SetDefaultModelRequest { Slug = slug }, Options(token)).ConfigureAwait(true)).Message);

    /// <summary>Deregisters <paramref name="slug"/> and drops its vectors.</summary>
    public Task<OperationResult> DropAsync(string slug) => RunAsync(_operations, async (_, token) =>
        (await _client.DropModelAsync(new DropModelRequest { Slug = slug }, Options(token)).ConfigureAwait(true)).Message);

    /// <summary>Saves the distillation provider and model.</summary>
    public Task<OperationResult> SaveFactsModelAsync(ModelProvider provider, string model) => RunAsync(_operations, async (_, token) =>
    {
        await _client.SetSettingAsync(new SetSettingRequest { Name = "facts.provider", Value = provider.CliValue() }, Options(token)).ConfigureAwait(true);
        SetSettingResponse saved = await _client.SetSettingAsync(new SetSettingRequest { Name = "facts.model", Value = model.Trim() }, Options(token)).ConfigureAwait(true);
        return $"Distillation model: {model.Trim()} via {provider.DisplayName()} (saved to {saved.Path})";
    });

    /// <summary>
    /// Embeds every chunk <paramref name="model"/> has no vector for ("*" for every model), on the
    /// backfill runner, reporting each step. Cancel stops it at the next batch.
    /// </summary>
    public Task<OperationResult> EmbedAsync(string model = "*") => RunAsync(_backfill, async (runner, token) =>
    {
        BackfillTarget = model;
        BackfillProgress = "Starting…";
        BackfillFraction = null;
        Recompute();
        string last = "";
        try
        {
            using AsyncServerStreamingCall<BackfillStatus> call = _client.Backfill(new BackfillRequest { Model = model }, new CallOptions(cancellationToken: token));
            await foreach (BackfillStatus step in call.ResponseStream.ReadAllAsync(token).ConfigureAwait(true))
            {
                BackfillProgress = Describe(step);
                BackfillFraction = step.Total > 0 ? Math.Clamp((double)(step.Total - step.Remaining) / step.Total, 0, 1) : null;
                if (step.Phase is "complete" or "skipped" or "finished" || step.Failed > 0)
                {
                    runner.AppendLog(BackfillProgress, step.Failed > 0 ? LogChannel.Stderr : LogChannel.Stdout);
                }
                last = BackfillProgress;
            }
            _notifier.Notify("Embedding finished", last);
            return last;
        }
        finally
        {
            BackfillTarget = null;
            BackfillProgress = null;
            BackfillFraction = null;
        }
    });

    /// <summary>Stops a running backfill at its next step.</summary>
    public void CancelEmbed() => _backfill.Cancel();

    /// <summary>Whether <paramref name="slug"/>'s row should say it is embedding.</summary>
    public bool IsEmbeddingModel(string slug) => ModelsPresentation.IsEmbedding(slug, _backfill.IsRunning, BackfillTarget);

    /// <summary>One backfill step in words.</summary>
    public static string Describe(BackfillStatus step)
    {
        ArgumentNullException.ThrowIfNull(step);
        if (!string.IsNullOrWhiteSpace(step.Message))
        {
            // The server's messages usually name the model already ("bge-m3: embedded 3").
            bool named = string.IsNullOrEmpty(step.ModelSlug) || step.Message.StartsWith(step.ModelSlug + ":", StringComparison.Ordinal);
            return named ? step.Message : $"{step.ModelSlug}: {step.Message}";
        }
        string counts = string.Create(CultureInfo.CurrentCulture, $"{step.Total - step.Remaining:N0} of {step.Total:N0} embedded");
        if (step.Failed > 0)
        {
            counts += string.Create(CultureInfo.CurrentCulture, $", {step.Failed:N0} failed");
        }
        return step.Phase switch
        {
            "complete" => $"{step.ModelSlug}: already complete",
            "skipped" => $"{step.ModelSlug}: skipped",
            "started" => string.Create(CultureInfo.CurrentCulture, $"{step.ModelSlug}: {step.Remaining:N0} chunks to embed"),
            _ => $"{step.ModelSlug}: {counts}",
        };
    }

    private async Task<string?> ReadSettingAsync(string name, CancellationToken cancellationToken)
    {
        try
        {
            GetSettingResponse setting = await _client.GetSettingAsync(new GetSettingRequest { Name = name }, Options(cancellationToken)).ConfigureAwait(true);
            return SettingValue.Text(setting.ValueJson);
        }
        catch (RpcException)
        {
            return null;
        }
    }

    private async Task<OperationResult> RunAsync(OperationRunner runner, Func<OperationRunner, CancellationToken, Task<string>> operation)
    {
        OnPropertyChanged(nameof(IsBusy));
        OperationResult result = await runner.RunAsync(operation).ConfigureAwait(true);
        LastResult = result.Output;
        OnPropertyChanged(nameof(IsBusy));
        await LoadAsync().ConfigureAwait(true);
        return result;
    }

    private void Recompute()
    {
        List<string> slugs = [.. Models.Select(m => m.Slug)];
        (long required, long missing) = ModelsPresentation.EmbeddingsRequiredAndMissing(slugs, _stats);
        Summary = ModelsPresentation.EmbeddingSummary(slugs.Count, _stats.TotalChunks, required, missing);
        Headline = ModelsPresentation.Headline(slugs.Count, [], _stats.TotalChunks, required, missing, _backfill.IsRunning);
        OnPropertyChanged(nameof(IsEmbedding));
    }

    private static CallOptions Options(CancellationToken cancellationToken) =>
        new(deadline: DateTime.UtcNow + CallTimeout, cancellationToken: cancellationToken);
}

/// <summary>A setting's value as <c>GetSetting</c> returns it: JSON, shown as text.</summary>
public static class SettingValue
{
    /// <summary>A JSON string as its text, a list as comma-separated text, anything else as its JSON; null for JSON null.</summary>
    public static string? Text(string? valueJson)
    {
        if (string.IsNullOrWhiteSpace(valueJson))
        {
            return null;
        }
        try
        {
            using JsonDocument document = JsonDocument.Parse(valueJson);
            JsonElement root = document.RootElement;
            return root.ValueKind switch
            {
                JsonValueKind.String => root.GetString(),
                JsonValueKind.Null => null,
                JsonValueKind.Array => string.Join(", ", root.EnumerateArray().Select(e => e.ValueKind == JsonValueKind.String ? e.GetString() : e.GetRawText())),
                _ => root.GetRawText(),
            };
        }
        catch (JsonException)
        {
            return valueJson;
        }
    }
}

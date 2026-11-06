using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using Garage.App.Core.Database;
using Garage.App.Core.Library;
using Garage.App.Core.Mcp;
using Garage.App.Core.Models;
using Garage.App.Core.Operations;
using Garage.App.Core.Sources;
using Garage.App.Core.State;

namespace Garage.App.Core.Onboarding;

/// <summary>What the "Setting things up" page reads, taken from the app each time it looks.</summary>
public sealed record FirstRunServiceInputs(
    PostgresStatus Database,
    bool? SchemaApplied,
    bool IsApplyingSchema,
    McpServerStatus Backend,
    McpServerStatus Mcp,
    bool McpHttpEnabled);

/// <summary>
/// Drives the setup assistant (the Mac's <c>FirstRunCoordinator</c>): which page shows, what has
/// been picked, and the operations that turn the picks into a configuration, through the same
/// Sources, Models and MCP Server view models as the pages, so the two can never disagree.
/// </summary>
public sealed partial class FirstRunCoordinator : ObservableObject
{
    /// <summary>The preference set once the assistant is finished or skipped (the Mac's <c>garage.firstRun.completed</c>).</summary>
    public const string CompletedKey = "firstRun.completed";

    /// <summary>How often page 1 looks at the services.</summary>
    public static readonly TimeSpan PollInterval = TimeSpan.FromMilliseconds(250);

    /// <summary>How long page 1 waits before saying the services did not come up.</summary>
    public static readonly TimeSpan ReadinessTimeout = TimeSpan.FromMinutes(3);

    private readonly IPreferences _preferences;
    private readonly bool _persistsCompletion;
    private readonly HashSet<string> _selectedSources = new(StringComparer.Ordinal);
    private readonly HashSet<string> _selectedEmbeddings = new(StringComparer.Ordinal);
    private readonly HashSet<string> _selectedClients = new(StringComparer.Ordinal);
    private bool _completedThisLaunch;
    private CancellationTokenSource? _readiness;

    /// <summary>
    /// Creates the coordinator. Whether the window opens on the assistant is decided here, before the
    /// window exists, so it never draws the pages first and then swaps (as on the Mac).
    /// </summary>
    /// <param name="preferences">Where completion is remembered.</param>
    /// <param name="persistsCompletion">False for a throwaway data folder (UI tests): finishing then lasts for this launch only.</param>
    /// <param name="afterDatabaseReset">This launch follows Reset Database: the assistant always runs.</param>
    public FirstRunCoordinator(IPreferences preferences, bool persistsCompletion = true, bool afterDatabaseReset = false)
    {
        _preferences = preferences ?? throw new ArgumentNullException(nameof(preferences));
        _persistsCompletion = persistsCompletion;
        IsAfterDatabaseReset = afterDatabaseReset;
        IsActive = afterDatabaseReset || !HasCompleted;
    }

    /// <summary>The Sources page's model, which adds the picked sources.</summary>
    public SourcesViewModel? Sources { get; set; }

    /// <summary>The Models page's model, which registers the picked models.</summary>
    public ModelsViewModel? Models { get; set; }

    /// <summary>The MCP Server page's model, which connects the picked assistants.</summary>
    public McpViewModel? Mcp { get; set; }

    /// <summary>The pipeline, held while the assistant is open.</summary>
    public LibraryCoordinator? Library { get; set; }

    /// <summary>The model catalog the models page offers.</summary>
    public ModelCatalog Catalog { get; set; } = ModelCatalog.Empty;

    /// <summary>The services' states, for page 1.</summary>
    public Func<FirstRunServiceInputs>? ReadServices { get; set; }

    /// <summary>Retry on page 1: the app starts what failed again.</summary>
    public Func<Task>? RestartServices { get; set; }

    /// <summary>This PC's folders, for the data page's templates.</summary>
    public Func<FirstRunSourceTemplate.Folders> Folders { get; set; } = () => FirstRunSourceTemplate.ThisPc();

    /// <summary>Whether a folder is there; injectable for tests.</summary>
    public Func<string, bool> FolderExists { get; set; } = Directory.Exists;

    /// <summary>Called once the assistant closes, finished or skipped: the app shows its pages and rereads them.</summary>
    public event EventHandler? Finished;

    /// <summary>The assistant is showing.</summary>
    [ObservableProperty]
    public partial bool IsActive { get; private set; }

    /// <summary>The page showing.</summary>
    [ObservableProperty]
    public partial FirstRunStep Step { get; private set; }

    /// <summary>A page is registering its picks.</summary>
    [ObservableProperty]
    public partial bool IsWorking { get; private set; }

    /// <summary>What went wrong on this page.</summary>
    [ObservableProperty]
    public partial string? ErrorMessage { get; private set; }

    /// <summary>What a working page is doing ("Adding Documents…").</summary>
    [ObservableProperty]
    public partial string? ProgressMessage { get; private set; }

    /// <summary>This run follows Reset Database: page 1 says the database is new.</summary>
    [ObservableProperty]
    public partial bool IsAfterDatabaseReset { get; private set; }

    /// <summary>Page 1's rows.</summary>
    [ObservableProperty]
    public partial IReadOnlyList<FirstRunServiceCheck> ServiceChecks { get; private set; } = [];

    /// <summary>The agent page's summary of what was written.</summary>
    [ObservableProperty]
    public partial string? RegistrationSummary { get; private set; }

    /// <summary>The provider the models page registers with (Ollama or LM Studio).</summary>
    [ObservableProperty]
    public partial ModelProvider Provider { get; set; } = ModelProvider.Ollama;

    /// <summary>The distillation model as the provider names it; empty for none.</summary>
    [ObservableProperty]
    public partial string DistillationModel { get; set; } = "";

    /// <summary>The data page's choices: the built-in templates, then the folders added.</summary>
    public ObservableCollection<FirstRunSourceTemplate> SourceTemplates { get; } = [];

    /// <summary>The agent page's assistants.</summary>
    public ObservableCollection<McpClientRowPresentation> Clients { get; } = [];

    /// <summary>The picked templates' ids.</summary>
    public IReadOnlySet<string> SelectedSourceIds => _selectedSources;

    /// <summary>The picked embedding presets' slugs.</summary>
    public IReadOnlySet<string> SelectedEmbeddingSlugs => _selectedEmbeddings;

    /// <summary>The picked assistants' keys.</summary>
    public IReadOnlySet<string> SelectedClientKeys => _selectedClients;

    /// <summary>The picked templates, in the page's order.</summary>
    public IReadOnlyList<FirstRunSourceTemplate> SelectedSources => [.. SourceTemplates.Where(t => _selectedSources.Contains(t.Id))];

    /// <summary>The embedding presets, featured first.</summary>
    public IReadOnlyList<ModelPreset> EmbeddingPresets => FirstRunModelPlan.Ordered(Catalog.Embedding);

    /// <summary>The distillation presets, featured first.</summary>
    public IReadOnlyList<ModelPreset> DistillationPresets => FirstRunModelPlan.Ordered(Catalog.Distillation);

    /// <summary>True once the assistant has been finished or skipped.</summary>
    public bool HasCompleted => _completedThisLaunch || _preferences.Read(CompletedKey, false);

    /// <summary>The required services are up.</summary>
    public bool ServicesReady => FirstRunReadiness.IsReady(ServiceChecks);

    /// <summary>A required service failed.</summary>
    public bool ServicesFailed => FirstRunReadiness.HasBlockingFailure(ServiceChecks);

    /// <summary>
    /// An install that already has sources or models was set up by hand, or by an earlier version,
    /// and is not walked through the assistant again.
    /// </summary>
    public static bool LooksAlreadyConfigured(int sources, int models) => sources > 0 || models > 0;

    /// <summary>
    /// Opens the assistant on its first page and starts watching the services. <paramref name="force"/>
    /// re-runs a completed assistant (Settings' Setup Assistant…); <paramref name="afterDatabaseReset"/>
    /// always runs and never takes the already-configured shortcut, since <c>garage.json</c> still
    /// lists the sources the new database was given again.
    /// </summary>
    public void Begin(bool force = false, bool afterDatabaseReset = false)
    {
        afterDatabaseReset |= IsAfterDatabaseReset && IsActive;
        if (!force && !afterDatabaseReset && HasCompleted)
        {
            return;
        }
        // A page still registering its picks keeps going; the running assistant shows its progress.
        if (IsActive && IsWorking)
        {
            return;
        }
        IsAfterDatabaseReset = afterDatabaseReset;
        ErrorMessage = null;
        ProgressMessage = null;
        RegistrationSummary = null;
        Step = FirstRunStep.SettingUp;
        IsActive = true;
        _selectedSources.Clear();
        _selectedEmbeddings.Clear();
        _selectedClients.Clear();
        DistillationModel = "";
        ResetTemplates(Folders());
        Library?.HoldForFirstRun();
        StartReadiness(skipIfConfigured: !force && !afterDatabaseReset);
    }

    /// <summary>Marks the assistant done and returns to the pages; held indexing starts now.</summary>
    public void Finish()
    {
        _readiness?.Cancel();
        _readiness = null;
        if (_persistsCompletion)
        {
            _preferences.Write(CompletedKey, true);
        }
        else
        {
            _completedThisLaunch = true;
        }
        IsActive = false;
        IsWorking = false;
        IsAfterDatabaseReset = false;
        Library?.ResumeAfterFirstRun();
        Finished?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>"I'll decide later": remembers completion so the assistant stays out of the way.</summary>
    public void Skip() => Finish();

    /// <summary>Forgets completion (tests, and a developer's reset).</summary>
    public void ResetCompletion()
    {
        _completedThisLaunch = false;
        _preferences.Write(CompletedKey, false);
    }

    /// <summary>Back a page; the services page is never re-entered.</summary>
    public void GoBack()
    {
        if (Step.Previous() is { } previous && previous != FirstRunStep.SettingUp)
        {
            ErrorMessage = null;
            Step = previous;
        }
    }

    /// <summary>Retry after a service failed.</summary>
    public async Task RetryServicesAsync()
    {
        ErrorMessage = null;
        if (RestartServices is not null)
        {
            await RestartServices().ConfigureAwait(true);
        }
        StartReadiness(skipIfConfigured: false);
    }

    /// <summary>Reads page 1's rows now.</summary>
    public void RefreshChecks()
    {
        if (ReadServices?.Invoke() is { } inputs)
        {
            ServiceChecks = FirstRunReadiness.Checks(inputs.Database, inputs.SchemaApplied, inputs.IsApplyingSchema, inputs.Backend, inputs.Mcp, inputs.McpHttpEnabled);
        }
    }

    // ---- Page 2: data

    /// <summary>Picks or unpicks a template; one that is not on this PC cannot be picked.</summary>
    public void ToggleSource(FirstRunSourceTemplate template)
    {
        ArgumentNullException.ThrowIfNull(template);
        if (!template.IsAvailable)
        {
            return;
        }
        if (!_selectedSources.Remove(template.Id))
        {
            _selectedSources.Add(template.Id);
        }
        OnPropertyChanged(nameof(SelectedSourceIds));
    }

    /// <summary>Adds a folder picked with Add Folder… as a picked source, with a slug no other has.</summary>
    public void AddCustomFolder(string folder)
    {
        HashSet<string> taken = [.. SourceTemplates.Select(t => t.Slug)];
        if (Sources is not null)
        {
            taken.UnionWith(Sources.TakenSlugs);
        }
        string id = "custom:" + folder;
        if (SourceTemplates.All(t => t.Id != id))
        {
            SourceTemplates.Add(FirstRunSourceTemplate.Custom(folder, taken));
        }
        _selectedSources.Add(id);
        OnPropertyChanged(nameof(SelectedSourceIds));
    }

    /// <summary>Removes an added folder; built-in templates stay.</summary>
    public void RemoveCustomFolder(FirstRunSourceTemplate template)
    {
        ArgumentNullException.ThrowIfNull(template);
        if (!template.IsCustom)
        {
            return;
        }
        SourceTemplates.Remove(template);
        _selectedSources.Remove(template.Id);
        OnPropertyChanged(nameof(SelectedSourceIds));
    }

    /// <summary>Adds the picked sources, then moves to the models page. Without the Sources model nothing can be added, and the page stays.</summary>
    public async Task CommitSourcesAsync()
    {
        if (Sources is null)
        {
            return;
        }
        IReadOnlyList<FirstRunSourceTemplate> picks = SelectedSources;
        if (picks.Count > 0)
        {
            IsWorking = true;
            ErrorMessage = null;
            List<string> failures = [];
            try
            {
                foreach (FirstRunSourceTemplate template in picks)
                {
                    ProgressMessage = $"Adding {template.Title}…";
                    OperationResult result = await Sources.AddAsync(template.Spec).ConfigureAwait(true);
                    if (!result.Succeeded)
                    {
                        failures.Add($"{template.Slug}: {result.Output.Trim()}");
                    }
                }
            }
            finally
            {
                ProgressMessage = null;
                IsWorking = false;
            }
            if (failures.Count > 0)
            {
                ErrorMessage = "Some sources could not be added:\n" + string.Join('\n', failures);
                return;
            }
        }
        await PrepareModelsPageAsync().ConfigureAwait(true);
        Step = FirstRunStep.SelectModels;
    }

    // ---- Page 3: models

    /// <summary>Picks or unpicks an embedding preset.</summary>
    public void ToggleEmbedding(ModelPreset preset)
    {
        ArgumentNullException.ThrowIfNull(preset);
        if (!_selectedEmbeddings.Remove(preset.Slug))
        {
            _selectedEmbeddings.Add(preset.Slug);
        }
        OnPropertyChanged(nameof(SelectedEmbeddingSlugs));
    }

    /// <summary>
    /// Picks the distillation model, as the provider names it; picking the same one again clears it,
    /// since <c>facts.model</c> names a single model.
    /// </summary>
    public void ToggleDistillation(ModelPreset preset)
    {
        ArgumentNullException.ThrowIfNull(preset);
        string name = preset.ReferenceFor(Provider);
        DistillationModel = DistillationModel == name ? "" : name;
    }

    /// <summary>Registers the picked embedding models (the first becomes the default when none is), sets the distillation model, and moves to the agent page.</summary>
    public async Task CommitModelsAsync()
    {
        if (Models is null)
        {
            return;
        }
        IsWorking = true;
        ErrorMessage = null;
        List<string> failures = [];
        try
        {
            HashSet<string> registered = [.. Models.Models.Select(m => m.Slug)];
            bool madeDefault = Models.Models.Any(m => m.IsDefault);
            foreach (ModelPreset preset in EmbeddingPresets.Where(p => _selectedEmbeddings.Contains(p.Slug) && !registered.Contains(p.Slug)))
            {
                ProgressMessage = FirstRunModelPlan.Registering(preset.Name);
                OperationResult result = await Models.RegisterAsync(FirstRunModelPlan.Registration(preset, Provider, makeDefault: !madeDefault)).ConfigureAwait(true);
                if (result.Succeeded)
                {
                    madeDefault = true;
                }
                else
                {
                    failures.Add($"{preset.Slug}: {result.Output.Trim()}");
                }
            }
            string distiller = DistillationModel.Trim();
            if (distiller.Length > 0 && (Models.FactsModel != distiller || Models.FactsProvider != Provider))
            {
                ProgressMessage = $"Selecting {distiller} for facts…";
                OperationResult result = await Models.SaveFactsModelAsync(Provider, distiller).ConfigureAwait(true);
                if (!result.Succeeded)
                {
                    failures.Add($"{distiller}: {result.Output.Trim()}");
                }
            }
        }
        finally
        {
            ProgressMessage = null;
            IsWorking = false;
        }
        await Models.LoadAsync().ConfigureAwait(true);
        if (failures.Count > 0)
        {
            ErrorMessage = "Some models could not be registered:\n" + string.Join('\n', failures);
            return;
        }
        await PrepareAgentPageAsync().ConfigureAwait(true);
        Step = FirstRunStep.SetupAgent;
    }

    // ---- Page 4: agent

    /// <summary>Picks or unpicks an assistant.</summary>
    public void ToggleClient(string key)
    {
        if (!_selectedClients.Remove(key))
        {
            _selectedClients.Add(key);
        }
        OnPropertyChanged(nameof(SelectedClientKeys));
    }

    /// <summary>Writes Garage into every picked assistant's config, and says how each went.</summary>
    public async Task RegisterSelectedClientsAsync()
    {
        if (Mcp is null)
        {
            return;
        }
        List<McpClientRowPresentation> picks = [.. Clients.Where(c => _selectedClients.Contains(c.Client.Key))];
        if (picks.Count == 0)
        {
            return;
        }
        IsWorking = true;
        ErrorMessage = null;
        List<string> lines = [];
        bool failed = false;
        try
        {
            foreach (McpClientRowPresentation client in picks)
            {
                ProgressMessage = $"Connecting {client.Client.Label}…";
                OperationResult result = await Mcp.ConnectAsync(client.Client.Key).ConfigureAwait(true);
                failed |= !result.Succeeded;
                lines.Add($"{(result.Succeeded ? "✓" : "✗")} {client.Client.Label}: {result.Output.Trim()}");
            }
        }
        finally
        {
            ProgressMessage = null;
            IsWorking = false;
        }
        ReloadClients();
        RegistrationSummary = string.Join('\n', lines);
        if (failed)
        {
            ErrorMessage = "Some assistants could not be connected. See the summary below.";
        }
    }

    private void ResetTemplates(FirstRunSourceTemplate.Folders folders)
    {
        SourceTemplates.Clear();
        foreach (FirstRunSourceTemplate template in FirstRunSourceTemplate.BuiltIn(folders, FolderExists))
        {
            SourceTemplates.Add(template);
        }
    }

    private void PrepareDataPage()
    {
        if (_selectedSources.Count == 0 && SourceTemplates.FirstOrDefault(t => t.Id == "documents") is { IsAvailable: true } documents)
        {
            _selectedSources.Add(documents.Id);
            OnPropertyChanged(nameof(SelectedSourceIds));
        }
    }

    private async Task PrepareModelsPageAsync()
    {
        if (Models is not null)
        {
            await Models.LoadAsync().ConfigureAwait(true);
            if (_selectedEmbeddings.Count == 0)
            {
                IEnumerable<string> registered = Models.Models.Select(m => m.Slug);
                _selectedEmbeddings.UnionWith(Models.Models.Count == 0
                    ? FirstRunModelPlan.DefaultSelection(Catalog.Embedding)
                    : registered.Intersect(Catalog.Embedding.Select(p => p.Slug)));
                OnPropertyChanged(nameof(SelectedEmbeddingSlugs));
            }
            if (DistillationModel.Length == 0 && Models.FactsModel.Length > 0)
            {
                DistillationModel = Models.FactsModel;
                if (Models.FactsProvider != ModelProvider.BuiltIn)
                {
                    Provider = Models.FactsProvider;
                }
            }
        }
    }

    private async Task PrepareAgentPageAsync()
    {
        if (Mcp is null)
        {
            return;
        }
        await Mcp.LoadAsync().ConfigureAwait(true);
        ReloadClients();
        if (_selectedClients.Count == 0)
        {
            _selectedClients.UnionWith(Clients.Where(c => c.State == McpClientState.NotConnected).Select(c => c.Client.Key));
            OnPropertyChanged(nameof(SelectedClientKeys));
        }
    }

    private void ReloadClients()
    {
        Clients.Clear();
        foreach (McpClientRowPresentation row in Mcp?.Rows ?? [])
        {
            Clients.Add(row);
        }
    }

    private void StartReadiness(bool skipIfConfigured)
    {
        _readiness?.Cancel();
        var readiness = new CancellationTokenSource();
        _readiness = readiness;
        _ = RunReadinessAsync(skipIfConfigured, readiness.Token);
    }

    private async Task RunReadinessAsync(bool skipIfConfigured, CancellationToken token)
    {
        try
        {
            DateTime deadline = DateTime.UtcNow + ReadinessTimeout;
            RefreshChecks();
            while (!ServicesReady && !ServicesFailed && DateTime.UtcNow < deadline)
            {
                await Task.Delay(PollInterval, token).ConfigureAwait(true);
                RefreshChecks();
            }
            if (!ServicesReady)
            {
                if (!ServicesFailed)
                {
                    ErrorMessage = "Garage's services did not become ready in time. Check the Logs page for details, then retry.";
                }
                return;
            }
            if (Sources is not null)
            {
                await Sources.LoadAsync(token).ConfigureAwait(true);
            }
            if (Models is not null)
            {
                await Models.LoadAsync(token).ConfigureAwait(true);
            }
            token.ThrowIfCancellationRequested();
            if (skipIfConfigured && LooksAlreadyConfigured(Sources?.TakenSlugs.Count ?? 0, Models?.Models.Count ?? 0))
            {
                Finish();
                return;
            }
            PrepareDataPage();
            Step = FirstRunStep.SelectData;
        }
        catch (OperationCanceledException)
        {
            // Finished, skipped or retried meanwhile.
        }
    }

    /// <summary>For tests: puts the assistant on a page.</summary>
    internal void SetStepForTesting(FirstRunStep step, bool active = true)
    {
        Step = step;
        IsActive = active;
    }

    /// <summary>For tests: replaces the data page's templates.</summary>
    internal void SetSourceTemplatesForTesting(IEnumerable<FirstRunSourceTemplate> templates)
    {
        SourceTemplates.Clear();
        foreach (FirstRunSourceTemplate template in templates)
        {
            SourceTemplates.Add(template);
        }
    }
}

using Garage.App.Core.Backend;
using Garage.App.Core.Database;
using Garage.App.Core.Diagnostics;
using Garage.App.Core.Documents;
using Garage.App.Core.Facts;
using Garage.App.Core.Library;
using Garage.App.Core.Logging;
using Garage.App.Core.Mcp;
using Garage.App.Core.Models;
using Garage.App.Core.Onboarding;
using Garage.App.Core.Search;
using Garage.App.Core.Services;
using Garage.App.Core.Settings;
using Garage.App.Core.Sources;
using Garage.App.Core.State;
using Garage.App.Core.Tray;

namespace Garage.App;

/// <summary>How this launch of the app was started and installed, for the models that depend on it.</summary>
/// <param name="AfterDatabaseReset">This launch follows Reset Database.</param>
/// <param name="PersistsCompletion">Finishing the setup assistant is remembered (false for a throwaway data folder).</param>
/// <param name="Startup">Launch at sign-in.</param>
/// <param name="Distribution">How this copy was installed.</param>
/// <param name="AppDirectory">The app's folder, where the model catalog is found.</param>
public sealed record AppLaunch(bool AfterDatabaseReset, bool PersistsCompletion, IStartupRegistration Startup, AppDistribution Distribution, string AppDirectory);

/// <summary>
/// One view model per page, made once and kept for the session, so a page's query, filters and
/// selection are still there when the user comes back to it (as the Mac's views keep their state).
/// </summary>
public sealed class PageModels : IDisposable
{
    /// <summary>Creates every page's model over <paramref name="state"/>.</summary>
    public PageModels(AppState state, IPreferences preferences, AppLaunch launch, PostgresSupervisor? postgres = null)
    {
        ArgumentNullException.ThrowIfNull(state);
        ArgumentNullException.ThrowIfNull(launch);
        State = state;
        Models = new(state.Client, state.Operations, state.Backfill, state.Notifier);
        Facts = new(state.Client);
        // Update Everything and Automatic Updates embed and glean through the Models and Facts pages'
        // own runs, so those pages show the progress whoever started it.
        Library = new LibraryCoordinator(
            state.Client,
            state.Backend.Ingest,
            new LibraryJobs(
                () => Models.EmbedAsync(),
                () => Facts.GleanAsync(state.Facts, state.Notifier),
                state.Backfill.Cancel,
                state.Facts.Cancel,
                () => state.Backfill.IsRunning),
            preferences,
            state.Notifier);
        Models.Registered = Library.TriggerSoon;
        Sources = new(state.Client, state.Operations, state.Notifier, library: Library);
        Status = new(state, Library, Models, Facts, postgres);
        Mcp = new(state.Client, state.Operations)
        {
            Preferences = preferences,
            Http = state.Backend is Core.Backend.ServiceHostBackend serviceHost ? new ServiceMcpHost(serviceHost.Services) : null,
        };
        Search = new(state.Client);
        Documents = new(state.Client);
        Database = new(state.Client, postgres)
        {
            // A restore replaces what the pipeline reads and writes: stop it first, and reread every
            // page afterwards, since the dump's sources and models are its own.
            BeforeReplace = async () =>
            {
                Library.CancelAll();
                for (int i = 0; i < 240 && Library.HasCancellableWork; i++)
                {
                    await Task.Delay(250).ConfigureAwait(true);
                }
            },
            AfterReplace = async () =>
            {
                await state.RefreshAsync().ConfigureAwait(true);
                await Status.LoadAsync().ConfigureAwait(true);
                await Sources.LoadAsync().ConfigureAwait(true);
            },
        };
        List<LogBuffer> logs = [.. state.LogSources, Library.Scanner.Logs, Library.Ingester.Logs];
        if (postgres is not null)
        {
            logs.Add(postgres.Log);
        }
        if (state.Backend.Host is { } host)
        {
            logs.AddRange(host.Services.Select(s => s.Log));
        }
        Logs = new(logs);
        _logs = logs;
        Settings = new(state.Client, state.Operations);
        Options = new AppOptionsViewModel(preferences, launch.Startup, launch.Distribution);
        _distribution = launch.Distribution;

        ServiceProcess? core = state.Backend is ServiceHostBackend serviceBackend ? serviceBackend.Services.Core : null;
        FirstRun = new FirstRunCoordinator(preferences, launch.PersistsCompletion, launch.AfterDatabaseReset)
        {
            Sources = Sources,
            Models = Models,
            Mcp = Mcp,
            Library = Library,
            Catalog = ModelCatalog.Load(launch.AppDirectory),
            ReadServices = () => new FirstRunServiceInputs(
                TrayStatusReader.Database(state, Database),
                // Without its own Postgres the app applies no schema; the backend answering is enough.
                Database.HasOwnServer ? Database.SchemaApplied : state.Connection == BackendConnection.Connected ? true : null,
                Database.IsApplyingSchema,
                TrayStatusReader.Service(core, state.Connection),
                TrayStatusReader.Service(Mcp.Http?.Service, state.Connection),
                Mcp.HttpEnabled),
        };
        Tray = new TrayViewModel(state.Client, () => TrayStatusReader.Read(state, Status, Database, Mcp), () => state.Backend.Mcp);
    }

    private readonly IReadOnlyList<LogBuffer> _logs;
    private readonly AppDistribution _distribution;

    /// <summary>The setup assistant.</summary>
    public FirstRunCoordinator FirstRun { get; }

    /// <summary>The notification-area flyout.</summary>
    public TrayViewModel Tray { get; }

    /// <summary>The app's own options on the Settings page.</summary>
    public AppOptionsViewModel Options { get; }

    /// <summary>A new bug report, with this moment's diagnostics; the sources and models are read first, since their pages may not have been opened.</summary>
    public async Task<BugReportViewModel> NewBugReportAsync()
    {
        await Sources.LoadAsync().ConfigureAwait(true);
        await Models.LoadAsync().ConfigureAwait(true);
        return new(Diagnostics, _logs);
    }

    private IReadOnlyList<DiagnosticSection> Diagnostics()
    {
        string database = Database.Headline is { } headline
            ? $"{headline.Title} · {headline.Detail}"
            : State.DatabaseStatus ?? State.Connection.ToString();
        List<(string, string)> services = State.Backend.Host is { } host
            ? [.. host.Services.Select(s => (ServiceRowPresentation.NameFor(s.Id), BugReportDiagnostics.Describe(s)))]
            : [("Backend", State.Backend.Description)];
        return BugReportDiagnostics.Collect(
            AppEnvironment.Current(_distribution.ToString()),
            database,
            Sources.Registered,
            State.Counts,
            [.. Models.Models],
            services);
    }

    /// <summary>The app state.</summary>
    public AppState State { get; }

    /// <summary>The pipeline: scans, ingests, Update Everything, Automatic Updates.</summary>
    public LibraryCoordinator Library { get; }

    /// <summary>Status.</summary>
    public StatusViewModel Status { get; }

    /// <summary>Sources.</summary>
    public SourcesViewModel Sources { get; }

    /// <summary>Models.</summary>
    public ModelsViewModel Models { get; }

    /// <summary>MCP Server.</summary>
    public McpViewModel Mcp { get; }

    /// <summary>Search.</summary>
    public SearchViewModel Search { get; }

    /// <summary>Documents.</summary>
    public DocumentsViewModel Documents { get; }

    /// <summary>Facts.</summary>
    public FactsViewModel Facts { get; }

    /// <summary>Database.</summary>
    public DatabaseViewModel Database { get; }

    /// <summary>Logs.</summary>
    public LogsViewModel Logs { get; }

    /// <summary>Settings.</summary>
    public SettingsViewModel Settings { get; }

    /// <inheritdoc/>
    public void Dispose()
    {
        Library.Dispose();
        Tray.Dispose();
    }
}

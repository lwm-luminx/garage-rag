using System.Diagnostics;
using System.Globalization;
using Garage.App.Core.Backend;
using Garage.App.Core.Database;
using Garage.App.Core.Navigation;
using Garage.App.Core.Operations;
using Garage.App.Core.Services;
using Garage.App.Core.State;
using Garage.App.Platform;
using Garage.App.Tray;
using Grpc.Net.Client;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace Garage.App;

/// <summary>
/// The application: starts Garage's Postgres and services, builds the app state over them, the main
/// window and the notification-area icon. Closing the window hides it; Quit (tray menu) ends the app,
/// its services and its Postgres, as on the Mac.
/// </summary>
public sealed partial class App : Application, IDisposable
{
    /// <summary>The argument a relaunch after Reset Database carries, with the old instance's pid.</summary>
    public const string AfterDatabaseResetArgument = "--after-database-reset";

    private GrpcChannel? _channel;
    private ServiceManager? _services;
    private PostgresSupervisor? _postgres;
    private PageModels? _pages;
    private MainWindow? _window;
    private TrayIcon? _tray;
    private TrayFlyoutWindow? _flyout;
    private DispatcherQueueTimer? _trayTimer;
    private ToastNotifier? _toasts;
    private bool _handedOffToRelaunch;

    /// <summary>
    /// <c>--appearance light|dark</c> pins the app's theme for this run, as on the Mac (screenshots, UI
    /// tests); otherwise it follows Windows.
    /// </summary>
    public const string AppearanceArgument = "--appearance";

    /// <summary>Creates the application.</summary>
    public App()
    {
        // Only settable before the first window: in the constructor, ahead of the resources.
        string[] arguments = Environment.GetCommandLineArgs();
        int appearance = Array.IndexOf(arguments, AppearanceArgument);
        if (appearance >= 0 && appearance + 1 < arguments.Length)
        {
            if (arguments[appearance + 1].Equals("dark", StringComparison.OrdinalIgnoreCase))
            {
                RequestedTheme = ApplicationTheme.Dark;
            }
            else if (arguments[appearance + 1].Equals("light", StringComparison.OrdinalIgnoreCase))
            {
                RequestedTheme = ApplicationTheme.Light;
            }
        }
        InitializeComponent();
        // A crash leaves its exception in the data folder's logs, where a bug report can find it.
        UnhandledException += (_, e) =>
        {
            try
            {
                string data = ServiceHostLayout.CurrentDataDirectory();
                Directory.CreateDirectory(Path.Combine(data, "logs"));
                File.AppendAllText(Path.Combine(data, "logs", "app-crash.log"), $"{DateTimeOffset.Now:O} {e.Exception}\n\n");
            }
            catch (IOException)
            {
                // Nowhere to write it.
            }
        };
    }

    /// <summary>The running application, once started.</summary>
    public static new App? Current => Application.Current as App;

    /// <summary>The state every page reads.</summary>
    public AppState State { get; private set; } = null!;

    /// <inheritdoc/>
    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        var dispatcher = new DispatcherQueueDispatcher(DispatcherQueue.GetForCurrentThread());
        (IBackend backend, string? problem) = ChooseBackend(dispatcher);
        _channel = backend.Grpc.OpenChannel();
        State = new AppState(backend, backend.Grpc.CreateClient(_channel), dispatcher);
        _toasts = new ToastNotifier();
        State.Notifier = _toasts;
        if (problem is not null)
        {
            State.AppLog.Append(problem, LogChannel.Stderr);
        }

        string dataDirectory = _services?.Layout.DataDirectory ?? ServiceHostLayout.CurrentDataDirectory();
        string[] arguments = Environment.GetCommandLineArgs();
        bool afterReset = arguments.Contains(AfterDatabaseResetArgument, StringComparer.Ordinal);
        var launch = new AppLaunch(afterReset, PersistsCompletion: true, Distribution.Startup(), Distribution.Current, AppContext.BaseDirectory);
        _pages = new PageModels(State, new JsonPreferences(Path.Combine(dataDirectory, "app-settings.json")), launch, _postgres);
        _pages.FirstRun.RestartServices = RetryStartAsync;
        _pages.FirstRun.Finished += (_, _) => _ = RefreshAfterFirstRunAsync();
        _window = new MainWindow(_pages);
        BuildTray();
        JumpList.Register();

        // The assistant starts watching the services now; it holds Automatic Updates until it closes.
        if (_pages.FirstRun.IsActive)
        {
            _pages.FirstRun.Begin(afterDatabaseReset: afterReset);
        }
        // The MSIX's StartupTask starts Garage with no command line; the Run key passes --background.
        LaunchAction action = Distribution.LaunchedAtSignIn() ? LaunchAction.Background : LaunchCommand.Parse(arguments.Skip(1));
        // Launch at sign-in starts in the notification area only, unless the assistant needs the window.
        if (action != LaunchAction.Background || _pages.FirstRun.IsActive)
        {
            _window.Activate();
        }
        _ = StartLoggedAsync();
        if (action is not (LaunchAction.Open or LaunchAction.Background))
        {
            Perform(action);
        }
    }

    /// <summary>
    /// A second launch handed its activation over (the jump list, a shortcut, launch at sign-in while
    /// already running): acts on its command line. A second background launch only brings the window up.
    /// </summary>
    public void OnRedirected(string commandLine)
    {
        LaunchAction action = LaunchCommand.Parse([commandLine]);
        _window?.DispatcherQueue.TryEnqueue(() => Perform(action == LaunchAction.Background ? LaunchAction.Open : action));
    }

    /// <summary>Does what a launch asked for.</summary>
    public void Perform(LaunchAction action)
    {
        if (_window is null || _pages is null)
        {
            return;
        }
        switch (action)
        {
            case LaunchAction.Background:
                break;
            case LaunchAction.Ask:
                _flyout?.ShowFlyout();
                break;
            case LaunchAction.Search:
                _window.ShowAndActivate();
                _window.Select(AppSection.Search);
                break;
            case LaunchAction.AddSource:
                _window.ShowAndActivate();
                _window.OpenAddSource();
                break;
            case LaunchAction.UpdateEverything:
                _window.ShowAndActivate();
                _window.Select(AppSection.Status);
                _ = _pages.Library.UpdateEverythingAsync();
                break;
            case LaunchAction.ReportBug:
                _window.ShowAndActivate();
                _ = _window.ShowBugReportAsync();
                break;
            default:
                _window.ShowAndActivate();
                break;
        }
    }

    // The notification-area icon, its flyout, and a timer that keeps both in step with the app.
    private void BuildTray()
    {
        if (_pages is null)
        {
            return;
        }
        PageModels pages = _pages;
        _flyout = new TrayFlyoutWindow(pages.Tray, new TrayActions(
            Open: () =>
            {
                _flyout?.Hide();
                ShowMainWindow();
            },
            Quit: Quit,
            Show: section =>
            {
                _flyout?.Hide();
                _window?.ShowAndActivate();
                _window?.Select(section);
            },
            SearchAll: query =>
            {
                _flyout?.Hide();
                pages.Search.Query = query;
                _window?.ShowAndActivate();
                _window?.Select(AppSection.Search);
                _ = pages.Search.SearchAsync();
            },
            IngestNow: () => pages.Library.IngestAllAsync(),
            Stop: () =>
            {
                // CancelAll stops a backfill only when the pipeline started it; this one may not have.
                pages.Library.CancelAll();
                State.Backfill.Cancel();
                State.Facts.Cancel();
            },
            Dismiss: () => { }));
        _tray = new TrayIcon(() => _flyout?.Toggle(), new TrayMenu(
            Open: ShowMainWindow,
            Ask: () => _flyout?.ShowFlyout(),
            ToggleAutomaticUpdates: () => pages.Library.AutomaticUpdatesEnabled = !pages.Library.AutomaticUpdatesEnabled,
            AutomaticUpdatesOn: () => pages.Library.AutomaticUpdatesEnabled,
            ReportBug: () => Perform(LaunchAction.ReportBug),
            Quit: Quit));
        _trayTimer = DispatcherQueue.GetForCurrentThread().CreateTimer();
        _trayTimer.Interval = TimeSpan.FromSeconds(1);
        _trayTimer.Tick += (_, _) =>
        {
            pages.Tray.Refresh();
            _tray?.Show(pages.Tray.Status);
        };
        _trayTimer.Start();
    }

    // The assistant closed: the pages show what it set up.
    private async Task RefreshAfterFirstRunAsync()
    {
        if (_pages is null)
        {
            return;
        }
        await State.RefreshAsync().ConfigureAwait(true);
        await _pages.Status.LoadAsync().ConfigureAwait(true);
    }

    // Retry on the assistant's first page: starts again what failed, then the schema.
    private async Task RetryStartAsync()
    {
        if (_postgres is not null && _postgres.Status.State == PostgresState.Failed)
        {
            await _postgres.StartAsync().ConfigureAwait(true);
        }
        if (_services is not null)
        {
            foreach (ServiceProcess service in _services.Services.Where(s => s.State == ServiceState.Unreachable && s != _services.Mcp).ToList())
            {
                await _services.RestartAsync(service).ConfigureAwait(true);
            }
        }
        if (_postgres is { Status.State: PostgresState.Running } && _services?.Core.State == ServiceState.Running && _pages is not null)
        {
            (bool ok, string message) = await DatabaseViewModel.PrepareAsync(State.Client, _postgres.CreatedCluster).ConfigureAwait(true);
            State.AppLog.Append(message, ok ? LogChannel.Stdout : LogChannel.Stderr);
            _pages.Database.RecordSchema(ok);
        }
        await State.RefreshAsync().ConfigureAwait(true);
    }

    /// <summary>The main window's handle, for pickers and dialogs that need an owner.</summary>
    public nint MainWindowHandle => _window is null ? 0 : WinRT.Interop.WindowNative.GetWindowHandle(_window);

    /// <summary>Shows a page in the main window.</summary>
    public void ShowSection(Core.Navigation.AppSection section) => _window?.Select(section);

    /// <summary>Shows the main window and brings it to the front.</summary>
    public void ShowMainWindow() => _window?.DispatcherQueue.TryEnqueue(() => _window.ShowAndActivate());

    /// <summary>Ends the app: the only way out, since closing the window only hides it.</summary>
    public async void Quit()
    {
        _pages?.Library.CancelAll();
        if (_services is not null)
        {
            State.AppLog.Append("Stopping Garage's services");
            await _services.StopAsync().ConfigureAwait(true);
        }
        if (_postgres is not null && !_handedOffToRelaunch)
        {
            await _postgres.StopAsync().ConfigureAwait(true);
        }
        Shutdown();
    }

    /// <summary>
    /// Reset Database: stops the pipeline, the services and Postgres, deletes the cluster, and starts a
    /// new instance of the app, which creates an empty database and registers <c>garage.json</c>'s
    /// sources again (<see cref="DatabaseViewModel.PrepareAsync"/>). The Mac's
    /// <c>resetDatabaseAndRelaunch</c>. This instance then quits without its usual shutdown, which
    /// the new instance's Postgres must not get.
    /// </summary>
    public async Task ResetDatabaseAndRelaunchAsync()
    {
        if (_postgres is null || _pages is null)
        {
            return;
        }
        _pages.Database.IsResetting = true;
        State.AppLog.Append("Reset Database: stopping Garage's services and deleting the database");
        _pages.Library.CancelAll();
        if (_services is not null)
        {
            await _services.StopAsync().ConfigureAwait(true);
        }
        try
        {
            await _postgres.DeleteClusterAsync().ConfigureAwait(true);
        }
        catch (IOException ex)
        {
            _pages.Database.IsResetting = false;
            _pages.Database.ResetOutcome = (false, $"The database could not be deleted: {ex.Message}. Quit Garage and try again.");
            return;
        }
        string exe = Environment.ProcessPath ?? throw new InvalidOperationException("the app's path is unknown");
        var relaunch = new ProcessStartInfo(exe) { UseShellExecute = false };
        relaunch.ArgumentList.Add(AfterDatabaseResetArgument);
        relaunch.ArgumentList.Add(Environment.ProcessId.ToString(CultureInfo.InvariantCulture));
        foreach (string arg in Environment.GetCommandLineArgs().Skip(1).Where(a => a == "--dev-backend"))
        {
            relaunch.ArgumentList.Add(arg);
        }
        Process.Start(relaunch)?.Dispose();
        _handedOffToRelaunch = true;
        Shutdown();
    }

    /// <inheritdoc/>
    public void Dispose()
    {
        _trayTimer?.Stop();
        _pages?.Dispose();
        _tray?.Dispose();
        _toasts?.Dispose();
        _channel?.Dispose();
        // Closes the Job Object: any service still running ends with it.
        _services?.Dispose();
    }

    private void Shutdown()
    {
        _trayTimer?.Stop();
        _flyout?.AllowClose();
        _flyout?.Close();
        _window?.AllowClose();
        _tray?.Dispose();
        _toasts?.Dispose();
        _window?.Close();
        Dispose();
        Exit();
    }

    /// <summary>
    /// The service host, unless the development backend is asked for: <c>--dev-backend</c> on the command
    /// line, or <c>GARAGE_GRPC_PORT</c> set (a <c>garage serve</c> started by hand, windows-ui.md §2.3).
    /// When the services cannot be found the app falls back to the development backend and says why.
    /// With the services, Garage's own Postgres runs when its build is found (<see cref="PostgresLayout.Locate"/>);
    /// otherwise the services use the database <c>garage.json</c> names.
    /// </summary>
    private (IBackend Backend, string? Problem) ChooseBackend(DispatcherQueueDispatcher dispatcher)
    {
        bool dev = Environment.GetCommandLineArgs().Contains("--dev-backend", StringComparer.OrdinalIgnoreCase)
            || !string.IsNullOrEmpty(Environment.GetEnvironmentVariable("GARAGE_GRPC_PORT"));
        if (!dev)
        {
            try
            {
                ServiceHostLayout layout = ServiceHostLayout.Locate(AppContext.BaseDirectory);
                _services = new ServiceManager(layout, dispatcher);
                if (PostgresLayout.Locate(AppContext.BaseDirectory, layout.DataDirectory) is { } postgres)
                {
                    _postgres = new PostgresSupervisor(postgres, new WindowsCredentialStore(), dispatcher);
                }
                return (new ServiceHostBackend(_services), null);
            }
            catch (Exception ex) when (ex is FileNotFoundException or InvalidOperationException)
            {
                return (DevBackend.FromEnvironment(), $"Garage's services could not start: {ex.Message}. Using a development backend instead.");
            }
        }
        return (DevBackend.FromEnvironment(), null);
    }

    // Start-up runs unawaited from OnLaunched: an exception must reach the log, not vanish.
    private async Task StartLoggedAsync()
    {
        try
        {
            await StartAsync().ConfigureAwait(true);
        }
#pragma warning disable CA1031 // Anything start-up throws is reported, and the app stays up to show it.
        catch (Exception ex)
#pragma warning restore CA1031
        {
            State.AppLog.Append($"Start-up failed: {ex.GetType().Name}: {ex.Message}", LogChannel.Stderr);
        }
    }

    // Postgres first, then the services (the backend, then ingest, which persists through it), then the
    // schema and, for a new cluster, garage.json's sources; then the pages' data and Automatic Updates,
    // whose launch run waits for all of it, as on the Mac.
    private async Task StartAsync()
    {
        bool afterReset = Environment.GetCommandLineArgs().Contains(AfterDatabaseResetArgument, StringComparer.Ordinal);
        if (afterReset && _pages is not null)
        {
            _pages.Database.IsFinishingReset = true;
        }
        bool postgresRunning = false;
        if (_postgres is not null && _services is not null)
        {
            State.AppLog.Append($"Starting Garage's Postgres ({_postgres.Layout.Home})");
            bool running = postgresRunning = await _postgres.StartAsync().ConfigureAwait(true);
            State.AppLog.Append(running ? $"{_postgres.Version} is running" : $"Garage's Postgres did not start: {_postgres.Status.FailureMessage}",
                running ? LogChannel.Stdout : LogChannel.Stderr);
            // Even when it failed: the services must never fall back to another database.
            _services.Environment["GARAGE_DATABASE_URL"] = SafeDatabaseUrl(_postgres);
            // One libpq, the server's own build: GARAGE_LIBPQ names it, and the pure-Python driver is the
            // one that loads it (an installed psycopg-binary would bring its own copy).
            _services.Environment["GARAGE_LIBPQ"] = _postgres.Layout.Libpq;
            _services.Environment["PSYCOPG_IMPL"] = "python";
        }
        bool servicesStarted = false;
        if (_services is not null)
        {
            State.AppLog.Append($"Starting Garage's services ({_services.Layout.ServicesExecutable})");
            bool started = servicesStarted = await _services.StartAsync().ConfigureAwait(true);
            State.AppLog.Append(started
                ? "Garage's services are running"
                : $"Garage's services did not all start: {string.Join("; ", _services.Services.Where(s => s.Error is not null).Select(s => $"{ServiceRowPresentation.NameFor(s.Id)}: {s.Error}"))}",
                started ? LogChannel.Stdout : LogChannel.Stderr);
        }
        // The schema before the first status check: a new cluster has no tables to report on yet.
        // The start methods' results, not the observable states, which reach this thread by posting.
        if (_postgres is not null && postgresRunning && servicesStarted)
        {
            State.AppLog.Append(_postgres.CreatedCluster ? "Setting up the new database" : "Applying schema updates");
            (bool ok, string message) = await DatabaseViewModel.PrepareAsync(State.Client, _postgres.CreatedCluster).ConfigureAwait(true);
            State.AppLog.Append(message, ok ? LogChannel.Stdout : LogChannel.Stderr);
            _pages?.Database.RecordSchema(ok);
            // The services' start-up self tests ran before the schema existed; run them again, as the
            // Mac re-runs its helpers' tests once they are configured.
            if (_services is not null)
            {
                await Task.WhenAll(_services.Services.Where(s => s.State == ServiceState.Running)
                    .Select(s => _services.RunSelfTestsAsync(s))).ConfigureAwait(true);
            }
            if (afterReset && _pages is not null)
            {
                _pages.Database.ResetOutcome = (ok, message);
            }
        }
        else if (afterReset && _pages is not null)
        {
            _pages.Database.ResetOutcome = (false, $"The new database could not be set up: {_postgres?.Status.FailureMessage ?? _services?.Core.Error ?? "Garage's services did not start"}");
        }
        await State.RefreshAsync().ConfigureAwait(true);
        if (_pages is not null)
        {
            _pages.Database.IsFinishingReset = false;
            await _pages.Status.LoadAsync().ConfigureAwait(true);
            // The MCP HTTP server comes back on when it was on at the last quit.
            await _pages.Mcp.RestoreHttpAsync().ConfigureAwait(true);
            if (State.Connection == BackendConnection.Connected)
            {
                _pages.Library.Start();
            }
        }
    }

    // The URL with the password; without one (Credential Manager lost it), a URL to the same server that
    // fails to authenticate, so the Status page says why instead of the services opening another database.
    private static string SafeDatabaseUrl(PostgresSupervisor postgres)
    {
        try
        {
            return postgres.DatabaseUrl();
        }
        catch (PostgresException)
        {
            return string.Create(CultureInfo.InvariantCulture,
                $"postgresql+psycopg://{PostgresLayout.User}@127.0.0.1:{postgres.Layout.Port}/{PostgresLayout.DatabaseName}");
        }
    }
}

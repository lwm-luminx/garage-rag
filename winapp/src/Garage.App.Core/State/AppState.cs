using CommunityToolkit.Mvvm.ComponentModel;
using Garage.App.Core.Backend;
using Garage.App.Core.Logging;
using Garage.App.Core.Operations;
using Garage.App.Core.Threading;
using Grpc.Core;

namespace Garage.App.Core.State;

/// <summary>How the app's connection to <c>GarageService</c> stands.</summary>
public enum BackendConnection
{
    /// <summary>Not checked yet.</summary>
    Unknown,

    /// <summary>A check is in flight.</summary>
    Connecting,

    /// <summary>The service answered.</summary>
    Connected,

    /// <summary>The service did not answer, or refused.</summary>
    Unavailable,
}

/// <summary>
/// The state every page reads: the counterpart of the Mac app's <c>AppState</c>, grown phase by
/// phase (docs/plans/windows-ui.md §4). U0 holds the backend connection and the corpus counts.
/// </summary>
public sealed partial class AppState : ObservableObject
{
    private static readonly TimeSpan CallTimeout = TimeSpan.FromSeconds(10);

    private readonly GarageService.GarageServiceClient _client;
    private readonly IUiDispatcher _dispatcher;

    /// <summary>Creates the state over a backend's client.</summary>
    public AppState(IBackend backend, GarageService.GarageServiceClient client, IUiDispatcher dispatcher)
    {
        ArgumentNullException.ThrowIfNull(backend);
        Backend = backend;
        _client = client ?? throw new ArgumentNullException(nameof(client));
        _dispatcher = dispatcher ?? throw new ArgumentNullException(nameof(dispatcher));
    }

    /// <summary>Where the backend is.</summary>
    public IBackend Backend { get; }

    /// <summary>The client the pages' view models call through.</summary>
    public GarageService.GarageServiceClient Client => _client;

    /// <summary>The runner for ordinary operations (sources, models, settings, MCP registration).</summary>
    public OperationRunner Operations { get; } = new("garage");

    /// <summary>Embedding backfills, on their own runner so a long one never blocks an ordinary operation.</summary>
    public OperationRunner Backfill { get; } = new("backfill");

    /// <summary>Fact distillation, on its own runner for the same reason.</summary>
    public OperationRunner Facts { get; } = new("enrich-facts");

    /// <summary>Where finished long operations are announced; the app installs toasts.</summary>
    public INotifier Notifier { get; set; } = SilentNotifier.Instance;

    /// <summary>The app's own log: connection changes and failures, for the Logs page.</summary>
    public LogBuffer AppLog { get; } = new("app");

    /// <summary>The buffers the Logs page offers, app log first.</summary>
    public IReadOnlyList<LogBuffer> LogSources => [AppLog, Operations.Logs, Backfill.Logs, Facts.Logs];

    /// <summary>The connection's state.</summary>
    [ObservableProperty]
    public partial BackendConnection Connection { get; private set; }

    /// <summary>Why the backend is unavailable, when it is.</summary>
    [ObservableProperty]
    public partial string? ConnectionError { get; private set; }

    /// <summary>The server's <c>garage_rag</c> version.</summary>
    [ObservableProperty]
    public partial string? ServerVersion { get; private set; }

    /// <summary>The server's view of the database (<c>StatusResponse.db_status</c>).</summary>
    [ObservableProperty]
    public partial string? DatabaseStatus { get; private set; }

    /// <summary>The corpus counts, once read.</summary>
    [ObservableProperty]
    public partial CorpusCounts? Counts { get; private set; }

    /// <summary>
    /// Asks the backend for its status and the corpus counts. Never throws for an unreachable or
    /// refusing server: that is <see cref="BackendConnection.Unavailable"/> with a reason.
    /// </summary>
    public async Task RefreshAsync(CancellationToken cancellationToken = default)
    {
        _dispatcher.Run(() => Connection = BackendConnection.Connecting);
        try
        {
            StatusResponse status = await _client.GetStatusAsync(new StatusRequest(), Options(cancellationToken)).ConfigureAwait(false);
            StatsResponse stats = await _client.GetStatsAsync(new StatsRequest(), Options(cancellationToken)).ConfigureAwait(false);
            _dispatcher.Run(() =>
            {
                if (Connection != BackendConnection.Connected || ServerVersion != status.Version)
                {
                    AppLog.Append($"Connected to Garage {status.Version} at {Backend.Grpc.Address.Authority}");
                }
                ServerVersion = status.Version;
                DatabaseStatus = status.DbStatus;
                Counts = new CorpusCounts(stats.Documents, stats.Chunks, stats.Sources, stats.Models);
                ConnectionError = null;
                Connection = BackendConnection.Connected;
            });
        }
        catch (RpcException ex) when (ex.StatusCode != StatusCode.Cancelled || !cancellationToken.IsCancellationRequested)
        {
            _dispatcher.Run(() =>
            {
                ConnectionError = Describe(ex);
                Connection = BackendConnection.Unavailable;
                AppLog.Append($"Garage isn't reachable at {Backend.Grpc.Address.Authority}: {ConnectionError} ({ex.StatusCode})", LogChannel.Stderr);
            });
        }
    }

    private static CallOptions Options(CancellationToken cancellationToken) =>
        new(deadline: DateTime.UtcNow + CallTimeout, cancellationToken: cancellationToken);

    private static string Describe(RpcException ex) => ex.StatusCode switch
    {
        StatusCode.Unavailable => "The Garage service is not running or not reachable.",
        StatusCode.Unauthenticated => "The Garage service rejected the connection token.",
        StatusCode.DeadlineExceeded => "The Garage service did not answer in time.",
        _ => RpcErrors.Describe(ex),
    };
}

/// <summary>Row counts across the corpus (<c>GetStats</c>).</summary>
public sealed record CorpusCounts(long Documents, long Chunks, long Sources, long Models);

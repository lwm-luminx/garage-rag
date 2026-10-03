using System.Collections.ObjectModel;
using System.ComponentModel;
using CommunityToolkit.Mvvm.ComponentModel;
using Garage.App.Core.Database;
using Garage.App.Core.Facts;
using Garage.App.Core.Library;
using Garage.App.Core.Models;
using Garage.App.Core.Services;
using Garage.App.Core.Sources;
using Grpc.Core;

namespace Garage.App.Core.State;

/// <summary>
/// The Status page: the Library box (what the pipeline is doing, or what is left to index, with Update
/// Everything or Stop), Automatic Updates, and the Services box. The Mac's <c>StatusView</c> with
/// <c>IndexingPresentation</c> and <c>ServiceRowPresentation</c>.
/// </summary>
public sealed partial class StatusViewModel : ObservableObject
{
    private static readonly TimeSpan CallTimeout = TimeSpan.FromSeconds(15);

    private readonly AppState _state;
    private readonly ModelsViewModel _models;
    private readonly FactsViewModel _facts;
    private IReadOnlyList<RegisteredSource> _sources = [];
    private CorpusStats _stats = new();
    private int _modelCount;
    private readonly PostgresSupervisor? _postgres;

    /// <summary>Creates the page's model and follows everything the Library box reports on.</summary>
    public StatusViewModel(AppState state, LibraryCoordinator library, ModelsViewModel models, FactsViewModel facts, PostgresSupervisor? postgres = null)
    {
        _postgres = postgres;
        if (postgres is not null)
        {
            postgres.PropertyChanged += (_, _) => RebuildServices();
        }
        _state = state ?? throw new ArgumentNullException(nameof(state));
        Library = library ?? throw new ArgumentNullException(nameof(library));
        _models = models ?? throw new ArgumentNullException(nameof(models));
        _facts = facts ?? throw new ArgumentNullException(nameof(facts));

        PropertyChangedEventHandler recompute = (_, _) => Recompute();
        foreach (INotifyPropertyChanged source in (INotifyPropertyChanged[])[state, library, library.Scanner, library.Ingester, state.Backfill, state.Facts, models, facts])
        {
            source.PropertyChanged += recompute;
        }
        library.IngestQueue.CollectionChanged += (_, _) => Recompute();
        // After a scan, an ingest or a whole run: the connection card's counts and the Library box.
        library.SourcesChanged += async (_, _) =>
        {
            await state.RefreshAsync().ConfigureAwait(true);
            await LoadAsync().ConfigureAwait(true);
        };
        if (state.Backend.Host is { } host)
        {
            foreach (ServiceProcess service in host.Services)
            {
                service.PropertyChanged += (_, _) => RebuildServices();
            }
        }
        Recompute();
        RebuildServices();
    }

    /// <summary>The pipeline.</summary>
    public LibraryCoordinator Library { get; }

    /// <summary>The Services box's rows; empty with a development backend.</summary>
    public ObservableCollection<ServiceRowPresentation> Services { get; } = [];

    /// <summary>Whether the app runs its own services (not a development backend).</summary>
    public bool HasServices => _state.Backend.Host is not null;

    /// <summary>The Database row's self tests: the server's size and extensions, once Test has read them.</summary>
    private PostgresDetails? _postgresDetails;

    /// <summary>The Library box's headline.</summary>
    [ObservableProperty]
    public partial LibraryHeadline Headline { get; private set; } = new(Presentation.StatusSymbol.Working, Presentation.Tint.Secondary, false, "Checking your library…");

    /// <summary>The Library box's action.</summary>
    [ObservableProperty]
    public partial LibraryAction Action { get; private set; }

    /// <summary>Whether Update Everything can start.</summary>
    [ObservableProperty]
    public partial bool CanUpdateEverything { get; private set; }

    /// <summary>Stop was pressed and the run has not ended.</summary>
    [ObservableProperty]
    public partial bool IsStopping { get; private set; }

    /// <summary>Whether a run is going.</summary>
    [ObservableProperty]
    public partial bool IsRunning { get; private set; }

    /// <summary>Reads the sources and counts the Library box works from.</summary>
    public async Task LoadAsync(CancellationToken cancellationToken = default)
    {
        try
        {
            var options = new CallOptions(deadline: DateTime.UtcNow + CallTimeout, cancellationToken: cancellationToken);
            ListSourcesResponse sources = await _state.Client.ListSourcesAsync(new ListSourcesRequest(), options).ConfigureAwait(true);
            StatsResponse stats = await _state.Client.GetStatsAsync(new StatsRequest(), options).ConfigureAwait(true);
            _sources = [.. sources.Sources.Select(s => RegisteredSource.From(s))];
            _stats = CorpusStats.From(stats);
            _modelCount = (int)stats.Models;
        }
        catch (RpcException)
        {
            // The connection card says why; the box shows what it knew.
        }
        Recompute();
    }

    /// <summary>Update Everything: scan, read, index and glean.</summary>
    public Task<bool> UpdateEverythingAsync() => Library.UpdateEverythingAsync();

    /// <summary>
    /// Stop: the pipeline's run, and a backfill or glean started from Models or Facts, which have runners
    /// of their own, as the Mac's Stop does.
    /// </summary>
    public void Stop()
    {
        Library.CancelAll();
        _state.Backfill.Cancel();
        _state.Facts.Cancel();
    }

    /// <summary>The self tests of <paramref name="id"/>'s last report.</summary>
    public IReadOnlyList<SelfTestLine> SelfTests(string id)
    {
        if (id == "postgres")
        {
            return _postgresDetails is { } details
                ? [new SelfTestLine("Server", "passed", $"{_postgres?.Version} · {Documents.Bytes.Format(details.SizeBytes)}", Presentation.Tint.Green, ""),
                   new SelfTestLine("Extensions", "passed", string.Join(", ", details.Extensions), Presentation.Tint.Green, "")]
                : [];
        }
        return Service(id)?.Report is { } report ? [.. report.Tests.Select(SelfTestLine.From)] : [];
    }

    /// <summary>Runs one service's self tests.</summary>
    public async Task TestAsync(string id)
    {
        if (id == "postgres" && _postgres is not null)
        {
            try
            {
                _postgresDetails = await _postgres.DetailsAsync().ConfigureAwait(true);
            }
            catch (PostgresException)
            {
                _postgresDetails = null;
            }
            RebuildServices(force: true);
            return;
        }
        if (_state.Backend.Host is { } host && Service(id) is { } service)
        {
            await host.RunSelfTestsAsync(service).ConfigureAwait(true);
        }
    }

    /// <summary>Runs every service's self tests.</summary>
    public async Task TestAllAsync()
    {
        if (_state.Backend.Host is { } host)
        {
            await Task.WhenAll(host.Services.Select(s => host.RunSelfTestsAsync(s))).ConfigureAwait(true);
        }
    }

    /// <summary>Restarts one service.</summary>
    public async Task RestartAsync(string id)
    {
        if (id == "postgres" && _postgres is not null)
        {
            // The services reconnect through their pools once the server is back.
            await _postgres.StopAsync().ConfigureAwait(true);
            await _postgres.StartAsync().ConfigureAwait(true);
            await _state.RefreshAsync().ConfigureAwait(true);
            return;
        }
        if (_state.Backend.Host is { } host && Service(id) is { } service)
        {
            await host.RestartAsync(service).ConfigureAwait(true);
            await _state.RefreshAsync().ConfigureAwait(true);
        }
    }

    /// <summary>Asks every service for its state.</summary>
    public async Task RefreshServicesAsync()
    {
        if (_state.Backend.Host is { } host)
        {
            await Task.WhenAll(host.Services.Select(s => host.RefreshAsync(s))).ConfigureAwait(true);
        }
    }

    /// <summary>What the pipeline is doing now, from the coordinator and the Models and Facts runs.</summary>
    public LibraryActivity CurrentActivity()
    {
        if (Library.ScanningSource is { } scanning)
        {
            return new LibraryActivity.Scanning(scanning, Library.ScanItemsSoFar);
        }
        if (Library.Ingester.IsRunning || Library.IsIngestingAll)
        {
            return new LibraryActivity.Ingesting(Library.IsIngestingAll ? null : Library.IngestingSource, Library.IngestingSource, Library.IngestSnapshot);
        }
        if (_state.Backfill.IsRunning)
        {
            return new LibraryActivity.Embedding(_models.BackfillProgress, _models.BackfillFraction);
        }
        if (_state.Facts.IsRunning)
        {
            return new LibraryActivity.Distilling(_facts.GleanProgress, _facts.GleanFraction);
        }
        return Library.IngestQueue.Count > 0 ? new LibraryActivity.Waiting([.. Library.IngestQueue]) : LibraryActivity.None;
    }

    private ServiceProcess? Service(string id) => _state.Backend.Host?.Services.FirstOrDefault(s => s.Id == id);

    private void Recompute()
    {
        var presentation = new LibraryPresentation(
            _sources,
            _stats,
            _modelCount,
            CurrentActivity(),
            IsStopping: Library.IsCancellingAll,
            LastRunError: Library.LastRunError,
            BackendIsRunning: _state.Connection == BackendConnection.Connected);
        Headline = presentation.Headline();
        Action = presentation.Action;
        CanUpdateEverything = presentation.CanUpdateEverything && Library.IngestUnavailable is null;
        IsStopping = Library.IsCancellingAll;
        IsRunning = presentation.IsRunning;
    }

    private void RebuildServices(bool force = false)
    {
        if (_state.Backend.Host is not { } host)
        {
            return;
        }
        List<ServiceRowPresentation> rows = [.. host.Services.Select(ServiceRowPresentation.From)];
        if (_postgres is not null)
        {
            rows.Insert(0, ServiceRowPresentation.ForPostgres(_postgres.Status, _postgres.Version, _postgres.Layout.Port));
        }
        if (!force && rows.SequenceEqual(Services))
        {
            return;
        }
        Services.Clear();
        foreach (ServiceRowPresentation row in rows)
        {
            Services.Add(row);
        }
    }
}

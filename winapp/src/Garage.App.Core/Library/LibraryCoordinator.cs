using System.Collections.ObjectModel;
using System.Globalization;
using CommunityToolkit.Mvvm.ComponentModel;
using Garage.App.Core.Backend;
using Garage.App.Core.Operations;
using Garage.App.Core.Sources;
using Garage.App.Core.State;
using Garage.Grpc.Services;
using Grpc.Core;

namespace Garage.App.Core.Library;

/// <summary>
/// The steps of a whole-pipeline run that other pages own: embedding (Models) and gleaning (Facts). Their
/// pages keep showing each run's progress, whoever started it.
/// </summary>
/// <param name="EmbedAll">Embeds every model's missing vectors (the Models page's Embed All).</param>
/// <param name="GleanStale">Gleans facts from documents no enabled prompt has distilled (<c>stale_only</c>).</param>
/// <param name="CancelEmbed">Stops a running backfill.</param>
/// <param name="CancelGlean">Stops a running glean.</param>
/// <param name="IsEmbedding">Whether a backfill runs.</param>
public sealed record LibraryJobs(
    Func<Task<OperationResult>> EmbedAll,
    Func<Task<OperationResult>> GleanStale,
    Action CancelEmbed,
    Action CancelGlean,
    Func<bool> IsEmbedding)
{
    /// <summary>No embedding or gleaning: a pipeline that scans and reads only (tests, the Sources page alone).</summary>
    public static LibraryJobs None { get; } = new(
        () => Task.FromResult(new OperationResult(true, "")),
        () => Task.FromResult(new OperationResult(true, "")),
        () => { },
        () => { },
        () => false);
}

/// <summary>
/// The pipeline: scans, the ingest queue, Update Everything and Automatic Updates. A port of the part
/// of the Mac's <c>AppState</c> that runs them (<c>scanSources</c>, <c>ingestAllSources</c>,
/// <c>scanAndIngestSource</c>, <c>cancelAll</c>, <c>cancel(source:)</c>, <c>updateEverything</c>,
/// <c>runPipeline</c> and the maintenance schedule).
/// </summary>
/// <remarks>Call it on the UI thread: it sets bound properties after every await.</remarks>
public sealed partial class LibraryCoordinator : ObservableObject, IDisposable
{
    /// <summary>The Automatic Updates intervals the Status page offers, as the Mac's picker does.</summary>
    public static readonly IReadOnlyList<TimeSpan> Intervals =
        [TimeSpan.FromMinutes(15), TimeSpan.FromHours(1), TimeSpan.FromHours(6), TimeSpan.FromHours(24)];

    /// <summary>A burst of changes (several sources added) shares one run that starts this long after the last.</summary>
    public static readonly TimeSpan Debounce = TimeSpan.FromSeconds(1);

    private const string EnabledKey = "automaticUpdates.enabled";
    private const string IntervalKey = "automaticUpdates.intervalMinutes";
    private const string AtLaunchKey = "automaticUpdates.runsAtLaunch";
    private static readonly TimeSpan CallTimeout = TimeSpan.FromSeconds(30);

    private readonly GarageService.GarageServiceClient _client;
    private readonly IIngestHost _ingest;
    private readonly LibraryJobs _jobs;
    private readonly IPreferences _preferences;
    private readonly INotifier _notifier;
    private readonly TimeProvider _time;
    private readonly Dictionary<string, long> _scanFound = new(StringComparer.Ordinal);
    private readonly Dictionary<string, SourceLastRun> _lastRuns = new(StringComparer.Ordinal);
    private readonly HashSet<string> _cancelledFromRun = new(StringComparer.Ordinal);
    private HashSet<string> _scanningSlugs = new(StringComparer.Ordinal);
    private string? _cancellingSource;
    private CancellationTokenSource? _schedule;
    private CancellationTokenSource? _debounce;
    private bool _started;
    private bool _loading;

    /// <summary>Creates the coordinator; nothing runs by itself until <see cref="Start"/>.</summary>
    public LibraryCoordinator(
        GarageService.GarageServiceClient client,
        IIngestHost ingest,
        LibraryJobs jobs,
        IPreferences preferences,
        INotifier? notifier = null,
        TimeProvider? time = null)
    {
        _client = client ?? throw new ArgumentNullException(nameof(client));
        _ingest = ingest ?? throw new ArgumentNullException(nameof(ingest));
        _jobs = jobs ?? throw new ArgumentNullException(nameof(jobs));
        _preferences = preferences ?? throw new ArgumentNullException(nameof(preferences));
        _notifier = notifier ?? SilentNotifier.Instance;
        _time = time ?? TimeProvider.System;
        // Loading, not changing: the change handlers leave the preferences and the schedule alone.
        _loading = true;
        AutomaticUpdatesEnabled = preferences.Read(EnabledKey, true);
        AutomaticUpdatesInterval = TimeSpan.FromMinutes(Math.Max(1, preferences.Read(IntervalKey, 60.0)));
        RunsAtLaunch = preferences.Read(AtLaunchKey, false);
        _loading = false;
    }

    /// <summary>Scans, on their own runner (the Mac's <c>scanner</c>).</summary>
    public OperationRunner Scanner { get; } = new("scan");

    /// <summary>Ingests, one source at a time.</summary>
    public OperationRunner Ingester { get; } = new("ingest");

    /// <summary>Sources an ingest of every source has yet to reach, in order.</summary>
    public ObservableCollection<string> IngestQueue { get; } = [];

    /// <summary>Items each source's running scan has found so far.</summary>
    public IReadOnlyDictionary<string, long> ScanFound => _scanFound;

    /// <summary>How each source's last ingest ended.</summary>
    public IReadOnlyDictionary<string, SourceLastRun> LastRuns => _lastRuns;

    /// <summary>The source being scanned ("*" for every one), or null.</summary>
    [ObservableProperty]
    public partial string? ScanningSource { get; private set; }

    /// <summary>Items the running scan has found across its sources.</summary>
    [ObservableProperty]
    public partial long ScanItemsSoFar { get; private set; }

    /// <summary>The source being ingested now, or null.</summary>
    [ObservableProperty]
    public partial string? IngestingSource { get; private set; }

    /// <summary>The running ingest's latest progress.</summary>
    [ObservableProperty]
    public partial SourceIngestSnapshot? IngestSnapshot { get; private set; }

    /// <summary>An ingest of every source is under way, including between sources.</summary>
    [ObservableProperty]
    public partial bool IsIngestingAll { get; private set; }

    /// <summary>Set by <see cref="CancelAll"/> until the work it stopped has ended.</summary>
    [ObservableProperty]
    public partial bool IsCancellingAll { get; private set; }

    /// <summary>Update Everything is running.</summary>
    [ObservableProperty]
    public partial bool IsUpdatingEverything { get; private set; }

    /// <summary>A whole-pipeline run (scheduled, or Update Everything) is between or inside its steps.</summary>
    [ObservableProperty]
    public partial bool IsMaintenanceRunning { get; private set; }

    /// <summary>Where a whole-pipeline run is.</summary>
    [ObservableProperty]
    public partial LibraryStage? Stage { get; private set; }

    /// <summary>"notes: permission denied", or "2 sources failed: notes, mail": the last run's failure.</summary>
    [ObservableProperty]
    public partial string? LastRunError { get; private set; }

    /// <summary>The last operation's outcome.</summary>
    [ObservableProperty]
    public partial string? LastResult { get; private set; }

    /// <summary>Keep every source up to date on a schedule (on by default, as on the Mac).</summary>
    [ObservableProperty]
    public partial bool AutomaticUpdatesEnabled { get; set; }

    /// <summary>How often Automatic Updates run.</summary>
    [ObservableProperty]
    public partial TimeSpan AutomaticUpdatesInterval { get; set; }

    /// <summary>Also run once when Garage starts, once its services are up.</summary>
    [ObservableProperty]
    public partial bool RunsAtLaunch { get; set; }

    /// <summary>Raised when a scan or ingest ended, so pages reload their sources and counts.</summary>
    public event EventHandler? SourcesChanged;

    /// <summary>Why ingest cannot run, or null.</summary>
    public string? IngestUnavailable => _ingest.Unavailable;

    /// <summary>A scan or ingest is running, or waiting in the queue: what <see cref="CancelAll"/> stops.</summary>
    public bool HasCancellableWork =>
        ScanningSource is not null || Ingester.IsRunning || IsIngestingAll || IsMaintenanceRunning || IngestQueue.Count > 0;

    /// <summary>Whether a scan or ingest covers <paramref name="slug"/> now or it waits in the queue.</summary>
    public SourceActivity ActivityOf(string slug)
    {
        if (IngestingSource == slug)
        {
            return SourceActivity.Ingesting;
        }
        if (ScanningSource == slug || (ScanningSource == "*" && _scanningSlugs.Contains(slug)))
        {
            return SourceActivity.Scanning;
        }
        return IngestQueue.Contains(slug) ? SourceActivity.Queued : SourceActivity.Idle;
    }

    /// <summary>
    /// Starts the schedule, and the launch run when <see cref="RunsAtLaunch"/> asks for one. The app
    /// calls it once the services are up (the Mac waits for the helpers' configuration the same way).
    /// </summary>
    public void Start()
    {
        if (_started)
        {
            return;
        }
        _started = true;
        Reschedule();
        if (AutomaticUpdatesEnabled && RunsAtLaunch)
        {
            TriggerSoon();
        }
    }

    /// <summary>Counts what <paramref name="source"/> holds ("*": every enabled source), streaming the counts.</summary>
    public async Task<bool> ScanAsync(string source = "*", bool includeCode = false, bool followedByIngest = false)
    {
        if (Ingester.IsRunning || IsIngestingAll)
        {
            LastResult = "Cannot scan while ingestion is in progress.";
            return false;
        }
        if (ScanningSource is not null)
        {
            LastResult = "A scan is already running.";
            return false;
        }
        if (IsCancellingAll)
        {
            return false;
        }
        ScanningSource = source;
        ScanItemsSoFar = 0;
        _scanFound.Clear();
        try
        {
            if (source == "*")
            {
                _cancelledFromRun.Clear();
                _scanningSlugs = [.. (await ListSourcesAsync().ConfigureAwait(true)).Where(s => s.Enabled).Select(s => s.Slug)];
            }
            OperationResult result = await Scanner.RunAsync(async (runner, token) =>
            {
                using AsyncServerStreamingCall<ScanStatus> call = _client.Scan(
                    new ScanRequest { Source = source, IncludeCode = includeCode }, new CallOptions(cancellationToken: token));
                string summary = "";
                await foreach (ScanStatus status in call.ResponseStream.ReadAllAsync(token).ConfigureAwait(true))
                {
                    switch (status.Phase)
                    {
                        case "progress":
                            _scanFound[status.Source] = status.SourceItems;
                            ScanItemsSoFar = status.TotalItems;
                            OnPropertyChanged(nameof(ScanFound));
                            break;
                        case "source":
                            SourceScanStatus done = status.Result;
                            _scanningSlugs.Remove(done.Source);
                            runner.AppendLog(string.IsNullOrEmpty(done.Error)
                                ? string.Create(CultureInfo.CurrentCulture, $"{done.Source}: {done.ItemCount:N0} {done.ItemType} in {done.DurationSeconds:0.0}s")
                                : $"{done.Source}: {done.Error}",
                                string.IsNullOrEmpty(done.Error) ? LogChannel.Stdout : LogChannel.Stderr);
                            OnPropertyChanged(nameof(ScanFound));
                            break;
                        case "finished":
                            summary = string.IsNullOrEmpty(status.Summary?.Message)
                                ? string.Create(CultureInfo.CurrentCulture, $"Scan found {status.TotalItems:N0} items")
                                : status.Summary.Message;
                            break;
                    }
                }
                return summary;
            }).ConfigureAwait(true);
            LastResult = result.Output;
            if (!result.Succeeded || !followedByIngest)
            {
                // No ingest follows this scan, so nothing should skip the sources cancelled during it.
                _cancelledFromRun.Clear();
            }
            return result.Succeeded;
        }
        catch (RpcException ex)
        {
            LastResult = RpcErrors.Describe(ex);
            return false;
        }
        finally
        {
            ScanningSource = null;
            ScanItemsSoFar = 0;
            _scanFound.Clear();
            _scanningSlugs = new(StringComparer.Ordinal);
            SourcesChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    /// <summary>
    /// Scan &amp; Ingest of one source. It waits in the queue from the start of its scan until its ingest
    /// ends, so Stop (or its row's Cancel) between the two keeps the ingest from starting.
    /// </summary>
    public async Task<bool> ScanAndIngestAsync(string slug, bool includeCode = false)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(slug);
        if (_ingest.Unavailable is { } why)
        {
            LastResult = why;
            return false;
        }
        if (IngestQueue.Contains(slug))
        {
            return false;
        }
        IngestQueue.Add(slug);
        try
        {
            if (!await ScanAsync(slug, includeCode).ConfigureAwait(true) || !IngestQueue.Contains(slug) || IsCancellingAll)
            {
                return false;
            }
            IngestQueue.Remove(slug);
            return await IngestOneAsync(slug, includeCode).ConfigureAwait(true);
        }
        finally
        {
            IngestQueue.Remove(slug);
        }
    }

    /// <summary>
    /// Ingests every enabled source in turn. The queue, not the list it started from, decides what runs
    /// next: <see cref="CancelAsync"/> takes a source out of it and <see cref="CancelAll"/> empties it.
    /// </summary>
    public async Task<bool> IngestAllAsync()
    {
        if (_ingest.Unavailable is { } why)
        {
            LastResult = why;
            return false;
        }
        if (IsIngestingAll)
        {
            LastResult = "An ingest of every source is already running.";
            return false;
        }
        IsIngestingAll = true;
        List<(string Slug, string Message)> failures = [];
        try
        {
            IReadOnlyList<RegisteredSource> sources = await ListSourcesAsync().ConfigureAwait(true);
            List<string> queued = [.. sources.Where(s => s.Enabled && !_cancelledFromRun.Contains(s.Slug)).Select(s => s.Slug)];
            if (queued.Count == 0)
            {
                LastResult = "No sources registered to ingest.";
                return false;
            }
            IngestQueue.Clear();
            foreach (string slug in queued)
            {
                IngestQueue.Add(slug);
            }
            LastRunError = null;
            while (IngestQueue.Count > 0 && !IsCancellingAll)
            {
                string slug = IngestQueue[0];
                IngestQueue.RemoveAt(0);
                if (!await IngestOneAsync(slug).ConfigureAwait(true)
                    && _lastRuns.GetValueOrDefault(slug) is { Error.Length: > 0 } run)
                {
                    failures.Add((slug, run.Error!));
                }
            }
            return failures.Count == 0;
        }
        catch (RpcException ex)
        {
            LastResult = RpcErrors.Describe(ex);
            return false;
        }
        finally
        {
            LastRunError = FailureSummary(failures);
            IngestQueue.Clear();
            _cancelledFromRun.Clear();
            IsIngestingAll = false;
        }
    }

    /// <summary>"notes: permission denied" for one failed source, "2 sources failed: notes, mail" for more.</summary>
    public static string? FailureSummary(IReadOnlyList<(string Slug, string Message)> failures)
    {
        ArgumentNullException.ThrowIfNull(failures);
        if (failures.Count == 0)
        {
            return null;
        }
        if (failures.Count == 1)
        {
            string message = failures[0].Message.Trim();
            return message.Length == 0 ? $"{failures[0].Slug} failed" : $"{failures[0].Slug}: {message}";
        }
        return string.Create(CultureInfo.CurrentCulture, $"{failures.Count} sources failed: {string.Join(", ", failures.Select(f => f.Slug))}");
    }

    /// <summary>
    /// Stops everything: empties the queue, then cancels the scan or ingest in progress, and the backfill
    /// and glean when a whole-pipeline run started them. <see cref="IsCancellingAll"/> stays set until that
    /// work has ended, so no later step starts.
    /// </summary>
    public void CancelAll()
    {
        if (!HasCancellableWork || IsCancellingAll)
        {
            return;
        }
        IsCancellingAll = true;
        CancelDebounce();
        IngestQueue.Clear();
        Scanner.Cancel();
        if (IsMaintenanceRunning)
        {
            _jobs.CancelEmbed();
        }
        if (IsUpdatingEverything)
        {
            _jobs.CancelGlean();
        }
        if (Ingester.IsRunning && IngestSnapshot is { } run)
        {
            IngestSnapshot = run with { IsCancelling = true };
        }
        Ingester.Cancel();
        _ = ClearCancellingWhenIdleAsync();
    }

    /// <summary>
    /// Cancels <paramref name="slug"/> alone: it leaves the queue, and its scan or ingest stops when it is
    /// the one running. An ingest of every source goes on with the next source; a scan of every source
    /// cannot skip one, so the ingest after it does.
    /// </summary>
    public Task CancelAsync(string slug)
    {
        IngestQueue.Remove(slug);
        if (ScanningSource == slug)
        {
            Scanner.Cancel();
        }
        else if (ScanningSource == "*" && _scanningSlugs.Remove(slug))
        {
            _cancelledFromRun.Add(slug);
        }
        if (IngestingSource == slug && Ingester.IsRunning)
        {
            _cancellingSource = slug;
            if (IngestSnapshot is { } run)
            {
                IngestSnapshot = run with { IsCancelling = true };
            }
            Ingester.Cancel();
        }
        OnPropertyChanged(nameof(ScanFound));
        return Task.CompletedTask;
    }

    /// <summary>
    /// The whole pipeline once, now: scan, read every source, embed with every model, then glean facts from
    /// documents no enabled prompt has distilled yet. Stop (<see cref="CancelAll"/>) ends it at the current step.
    /// </summary>
    public async Task<bool> UpdateEverythingAsync()
    {
        if (HasCancellableWork || _jobs.IsEmbedding() || IsUpdatingEverything)
        {
            LastResult = "Garage is already updating; Stop it first or wait for it to finish.";
            return false;
        }
        if (_ingest.Unavailable is { } why)
        {
            LastResult = why;
            return false;
        }
        IsUpdatingEverything = true;
        IsMaintenanceRunning = true;
        try
        {
            return await RunPipelineAsync(gleansFacts: true).ConfigureAwait(true);
        }
        finally
        {
            IsMaintenanceRunning = false;
            IsUpdatingEverything = false;
        }
    }

    /// <summary>
    /// After a change that leaves something unindexed (a source added, a model registered): runs the
    /// scheduled pipeline a moment later, when Automatic Updates are on. A burst of changes shares one run.
    /// </summary>
    public void TriggerSoon()
    {
        if (!AutomaticUpdatesEnabled)
        {
            return;
        }
        CancelDebounce();
        var debounce = new CancellationTokenSource();
        _debounce = debounce;
        _ = RunAfterAsync(Debounce, debounce.Token);
    }

    /// <summary>
    /// Held while the setup assistant is open: a run that comes due only notes it is owed, since a
    /// scan would hold the operations the assistant's pages run (the Mac's
    /// <c>isMaintenanceDeferredForFirstRun</c>). <see cref="ResumeAfterFirstRun"/> runs it then.
    /// </summary>
    [ObservableProperty]
    public partial bool IsDeferredForFirstRun { get; private set; }

    private bool _isHeldForFirstRun;

    /// <summary>Holds scheduled runs while the setup assistant is open.</summary>
    public void HoldForFirstRun() => _isHeldForFirstRun = true;

    /// <summary>The assistant closed: runs what came due meanwhile, with the sources and models it chose.</summary>
    public void ResumeAfterFirstRun()
    {
        _isHeldForFirstRun = false;
        if (IsDeferredForFirstRun)
        {
            IsDeferredForFirstRun = false;
            TriggerSoon();
        }
    }

    /// <summary>The scheduled run: scan, read and embed, without gleaning, as the Mac's maintenance.</summary>
    public async Task<bool> RunScheduledAsync()
    {
        if (_isHeldForFirstRun)
        {
            IsDeferredForFirstRun = true;
            return false;
        }
        if (_ingest.Unavailable is not null || HasCancellableWork || _jobs.IsEmbedding())
        {
            return false;
        }
        IsMaintenanceRunning = true;
        try
        {
            return await RunPipelineAsync(gleansFacts: false).ConfigureAwait(true);
        }
        finally
        {
            IsMaintenanceRunning = false;
        }
    }

    partial void OnAutomaticUpdatesEnabledChanged(bool value)
    {
        if (_loading)
        {
            return;
        }
        _preferences.Write(EnabledKey, value);
        Reschedule();
    }

    partial void OnAutomaticUpdatesIntervalChanged(TimeSpan value)
    {
        if (_loading)
        {
            return;
        }
        _preferences.Write(IntervalKey, value.TotalMinutes);
        Reschedule();
    }

    partial void OnRunsAtLaunchChanged(bool value)
    {
        if (!_loading)
        {
            _preferences.Write(AtLaunchKey, value);
        }
    }

    private async Task<bool> RunPipelineAsync(bool gleansFacts)
    {
        try
        {
            Stage = LibraryStage.Scan;
            await ScanAsync("*", followedByIngest: true).ConfigureAwait(true);
            if (IsCancellingAll)
            {
                return false;
            }
            Stage = LibraryStage.Read;
            bool read = await IngestAllAsync().ConfigureAwait(true);
            if (IsCancellingAll)
            {
                return false;
            }
            Stage = LibraryStage.Index;
            bool indexed = (await _jobs.EmbedAll().ConfigureAwait(true)).Succeeded;
            bool gleaned = true;
            if (gleansFacts && !IsCancellingAll)
            {
                Stage = LibraryStage.Glean;
                gleaned = (await _jobs.GleanStale().ConfigureAwait(true)).Succeeded;
            }
            bool ok = read && indexed && gleaned;
            LastResult = ok ? "Everything is up to date." : LastRunError ?? "Part of the update did not finish; the Logs page has the details.";
            if (gleansFacts)
            {
                _notifier.Notify(ok ? "Library updated" : "Library update finished with problems", LastResult);
            }
            return ok;
        }
        finally
        {
            Stage = null;
            SourcesChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    private async Task<bool> IngestOneAsync(string slug, bool includeCode = false)
    {
        IngestingSource = slug;
        IngestSnapshot = null;
        _cancellingSource = null;
        SourceIngestSnapshot? last = null;
        string? error = null;
        bool cancelled = false;
        OperationResult result = await Ingester.RunAsync(async (runner, token) =>
        {
            await foreach (IngestProgress progress in _ingest.IngestAsync(new IngestSourceRequest { Source = slug, IncludeCode = includeCode }, token).ConfigureAwait(true))
            {
                last = SourceIngestSnapshot.From(progress, _cancellingSource == slug || IsCancellingAll);
                IngestSnapshot = last;
                switch (progress.Phase)
                {
                    case "error":
                        error = string.IsNullOrEmpty(progress.Error) ? progress.Message : progress.Error;
                        runner.AppendLog($"{slug}: {error}", LogChannel.Stderr);
                        break;
                    case "cancelled":
                        cancelled = true;
                        runner.AppendLog(progress.Message, LogChannel.Stderr);
                        break;
                    case "scan" or "complete":
                        runner.AppendLog(progress.Message);
                        break;
                }
            }
            return last is null ? $"Ingest of {slug} finished" : SourceRowPresentation.RunCounts(last.Seen, last.Total, last.Indexed, last.Skipped, last.Failed, last.ItemType);
        }).ConfigureAwait(true);

        cancelled |= !result.Succeeded && (_cancellingSource == slug || IsCancellingAll || result.Output.EndsWith("cancelled", StringComparison.Ordinal));
        if (!result.Succeeded && !cancelled)
        {
            error ??= result.Output;
        }
        _lastRuns[slug] = new SourceLastRun(last?.Indexed ?? 0, last?.Skipped ?? 0, last?.Failed ?? 0, error, cancelled);
        LastResult = error is not null ? $"{slug}: {error}" : cancelled ? $"Ingest of {slug} cancelled" : $"Ingest of {slug} finished: {result.Output}";
        IngestingSource = null;
        IngestSnapshot = null;
        _cancellingSource = null;
        SourcesChanged?.Invoke(this, EventArgs.Empty);
        return error is null && !cancelled;
    }

    private async Task<IReadOnlyList<RegisteredSource>> ListSourcesAsync()
    {
        ListSourcesResponse listed = await _client.ListSourcesAsync(new ListSourcesRequest(),
            new CallOptions(deadline: DateTime.UtcNow + CallTimeout)).ConfigureAwait(true);
        return [.. listed.Sources.Select(s => RegisteredSource.From(s))];
    }

    private async Task ClearCancellingWhenIdleAsync()
    {
        // Each cancelled step ends at its next progress step; look rather than track every path.
        while (HasCancellableWork)
        {
            await Task.Delay(TimeSpan.FromMilliseconds(250), _time).ConfigureAwait(true);
        }
        IsCancellingAll = false;
        _cancelledFromRun.Clear();
    }

    private void Reschedule()
    {
        _schedule?.Cancel();
        _schedule?.Dispose();
        _schedule = null;
        if (!_started || !AutomaticUpdatesEnabled)
        {
            return;
        }
        var schedule = new CancellationTokenSource();
        _schedule = schedule;
        _ = ScheduleLoopAsync(AutomaticUpdatesInterval, schedule.Token);
    }

    private async Task ScheduleLoopAsync(TimeSpan interval, CancellationToken token)
    {
        try
        {
            while (!token.IsCancellationRequested)
            {
                await Task.Delay(interval, _time, token).ConfigureAwait(true);
                await RunScheduledAsync().ConfigureAwait(true);
            }
        }
        catch (OperationCanceledException)
        {
            // Rescheduled or turned off.
        }
    }

    private async Task RunAfterAsync(TimeSpan delay, CancellationToken token)
    {
        try
        {
            await Task.Delay(delay, _time, token).ConfigureAwait(true);
            await RunScheduledAsync().ConfigureAwait(true);
        }
        catch (OperationCanceledException)
        {
            // Superseded by a later change, or Stop.
        }
    }

    private void CancelDebounce()
    {
        _debounce?.Cancel();
        _debounce?.Dispose();
        _debounce = null;
    }

    /// <inheritdoc/>
    public void Dispose()
    {
        _started = false;
        CancelDebounce();
        _schedule?.Cancel();
        _schedule?.Dispose();
        _schedule = null;
    }
}

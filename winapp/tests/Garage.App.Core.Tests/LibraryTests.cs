using System.Runtime.CompilerServices;
using Garage.App.Core.Database;
using Garage.App.Core.Library;
using Garage.App.Core.Operations;
using Garage.App.Core.Presentation;
using Garage.App.Core.Services;
using Garage.App.Core.Sources;
using Garage.App.Core.State;
using Garage.App.Core.Tests.TestSupport;
using Garage.Grpc.Services;

namespace Garage.App.Core.Tests;

// The pipeline (the Mac's AppState scan, ingest queue, cancel and Update Everything), with a fake
// ingest service; and the wording ported from IndexingPresentation, ServiceRowPresentation and the
// ingest cases of SourcesPresentationTests.swift.
public sealed class LibraryTests
{
    private static FakeGarageClient Client(params string[] slugs) => new()
    {
        OnListSources = _ => new ListSourcesResponse
        {
            Sources = { slugs.Select(s => new SourceInfo { Slug = s, Kind = "filesystem", Root = $@"C:\{s}", Enabled = true }) },
        },
        OnScan = r => [new ScanStatus { Phase = "finished", TotalItems = 3, Summary = new ScanResponse { Message = $"scanned {r.Source}" } }],
    };

    private static IngestProgress Progress(string source, string phase, long seen = 0, long total = 0, long indexed = 0, string? error = null) => new()
    {
        Source = source,
        Phase = phase,
        Seen = seen,
        TotalItems = total,
        Indexed = indexed,
        Progress = total > 0 ? (double)seen / total : 0,
        ItemType = "documents",
        Message = $"{source} {phase}",
        Error = error ?? "",
    };

    private sealed class FakeIngest : IIngestHost
    {
        public List<string> Ingested { get; } = [];

        public HashSet<string> Failing { get; } = [];

        /// <summary>Sources whose ingest waits after its first update until cancelled.</summary>
        public HashSet<string> Blocking { get; } = [];

        public TaskCompletionSource Started { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public string? Unavailable => null;

        public async IAsyncEnumerable<IngestProgress> IngestAsync(IngestSourceRequest request, [EnumeratorCancellation] CancellationToken cancellationToken)
        {
            Ingested.Add(request.Source);
            yield return Progress(request.Source, "scan", total: 2);
            if (Blocking.Contains(request.Source))
            {
                yield return Progress(request.Source, "ingest", seen: 1, total: 2, indexed: 1);
                Started.TrySetResult();
                await Task.Delay(Timeout.Infinite, cancellationToken);
            }
            yield return Failing.Contains(request.Source)
                ? Progress(request.Source, "error", seen: 2, total: 2, error: "permission denied")
                : Progress(request.Source, "complete", seen: 2, total: 2, indexed: 2);
        }
    }

    private sealed class Jobs
    {
        public List<string> Ran { get; } = [];

        public LibraryJobs Make() => new(
            () => { Ran.Add("embed"); return Task.FromResult(new OperationResult(true, "")); },
            () => { Ran.Add("glean"); return Task.FromResult(new OperationResult(true, "")); },
            () => Ran.Add("cancel embed"),
            () => Ran.Add("cancel glean"),
            () => false);
    }

    private static LibraryCoordinator Library(FakeGarageClient client, IIngestHost ingest, Jobs? jobs = null, IPreferences? preferences = null) =>
        new(client, ingest, (jobs ?? new Jobs()).Make(), preferences ?? new MemoryPreferences());

    [Fact]
    public async Task Ingest_all_reads_every_enabled_source_in_turn()
    {
        var ingest = new FakeIngest();
        using LibraryCoordinator library = Library(Client("notes", "mail"), ingest);

        Assert.True(await library.IngestAllAsync());

        Assert.Equal(["notes", "mail"], ingest.Ingested);
        Assert.Empty(library.IngestQueue);
        Assert.False(library.IsIngestingAll);
        Assert.Equal(new SourceLastRun(2, 0, 0, null, false), library.LastRuns["mail"]);
        Assert.Null(library.LastRunError);
    }

    [Fact]
    public async Task A_failing_source_is_reported_and_the_rest_still_run()
    {
        var ingest = new FakeIngest { Failing = { "notes" } };
        using LibraryCoordinator library = Library(Client("notes", "mail"), ingest);

        Assert.False(await library.IngestAllAsync());

        Assert.Equal(["notes", "mail"], ingest.Ingested);
        Assert.Equal("notes: permission denied", library.LastRunError);
        Assert.Equal("permission denied", library.LastRuns["notes"].Error);
    }

    [Fact]
    public void Failure_summaries_as_on_the_mac()
    {
        using var culture = new CultureScope("en-US");
        Assert.Null(LibraryCoordinator.FailureSummary([]));
        Assert.Equal("notes: permission denied", LibraryCoordinator.FailureSummary([("notes", " permission denied ")]));
        Assert.Equal("notes failed", LibraryCoordinator.FailureSummary([("notes", "")]));
        Assert.Equal("2 sources failed: notes, mail", LibraryCoordinator.FailureSummary([("notes", "a"), ("mail", "b")]));
    }

    [Fact]
    public async Task Cancelling_one_source_stops_its_read_and_the_run_goes_on()
    {
        var ingest = new FakeIngest { Blocking = { "notes" } };
        using LibraryCoordinator library = Library(Client("notes", "mail"), ingest);

        Task<bool> run = library.IngestAllAsync();
        await ingest.Started.Task.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);
        Assert.Equal(SourceActivity.Ingesting, library.ActivityOf("notes"));
        Assert.Equal(SourceActivity.Queued, library.ActivityOf("mail"));
        Assert.Equal("Reading 50%", SourceRow("notes", library).Status);

        await library.CancelAsync("notes");
        await run.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);

        Assert.Equal(["notes", "mail"], ingest.Ingested);
        Assert.True(library.LastRuns["notes"].WasCancelled);
        Assert.Null(library.LastRuns["notes"].Error);
        Assert.False(library.LastRuns["mail"].WasCancelled);
        Assert.Null(library.LastRunError);
    }

    [Fact]
    public async Task Stop_empties_the_queue_and_nothing_after_it_starts()
    {
        var ingest = new FakeIngest { Blocking = { "notes" } };
        var jobs = new Jobs();
        using LibraryCoordinator library = Library(Client("notes", "mail", "code"), ingest, jobs);

        Task<bool> run = library.UpdateEverythingAsync();
        await ingest.Started.Task.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);
        Assert.Equal(LibraryStage.Read, library.Stage);

        library.CancelAll();
        Assert.True(library.IsCancellingAll);
        Assert.False(await run.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken));

        Assert.Equal(["notes"], ingest.Ingested);
        Assert.DoesNotContain("embed", jobs.Ran);
        Assert.Contains("cancel embed", jobs.Ran);
        Assert.Contains("cancel glean", jobs.Ran);
        for (int i = 0; i < 40 && library.IsCancellingAll; i++)
        {
            await Task.Delay(100, TestContext.Current.CancellationToken);
        }
        Assert.False(library.IsCancellingAll);
    }

    [Fact]
    public async Task Update_everything_scans_reads_indexes_then_gleans()
    {
        var client = Client("notes");
        var ingest = new FakeIngest();
        var jobs = new Jobs();
        var notifier = new SourcesTests.RecordingNotifier();
        using var library = new LibraryCoordinator(client, ingest, jobs.Make(), new MemoryPreferences(), notifier);

        Assert.True(await library.UpdateEverythingAsync());

        Assert.Equal("*", client.Requests.OfType<ScanRequest>().Single().Source);
        Assert.Equal(["notes"], ingest.Ingested);
        Assert.Equal(["embed", "glean"], jobs.Ran);
        Assert.Null(library.Stage);
        Assert.False(library.IsUpdatingEverything);
        Assert.Equal(("Library updated", "Everything is up to date."), notifier.Last);
    }

    [Fact]
    public async Task The_scheduled_run_does_not_glean()
    {
        var jobs = new Jobs();
        using LibraryCoordinator library = Library(Client("notes"), new FakeIngest(), jobs);

        Assert.True(await library.RunScheduledAsync());

        Assert.Equal(["embed"], jobs.Ran);
    }

    [Fact]
    public async Task Scan_and_ingest_reads_after_its_scan()
    {
        var client = Client("notes");
        var ingest = new FakeIngest();
        using LibraryCoordinator library = Library(client, ingest);

        Assert.True(await library.ScanAndIngestAsync("notes"));

        Assert.Equal("notes", client.Requests.OfType<ScanRequest>().Single().Source);
        Assert.Equal(["notes"], ingest.Ingested);
        Assert.Empty(library.IngestQueue);
    }

    [Fact]
    public async Task Without_an_ingest_service_nothing_is_read_and_the_page_says_why()
    {
        var client = Client("notes");
        using LibraryCoordinator library = Library(client, NoIngestHost.Instance);

        Assert.False(await library.ScanAndIngestAsync("notes"));
        Assert.False(await library.UpdateEverythingAsync());

        Assert.Empty(client.Requests.OfType<ScanRequest>());
        Assert.StartsWith("Ingest runs in Garage's own services", library.LastResult, StringComparison.Ordinal);
        Assert.False(await library.RunScheduledAsync());
    }

    [Fact]
    public async Task Automatic_updates_are_kept_and_a_change_triggers_one_run()
    {
        var preferences = new MemoryPreferences();
        var jobs = new Jobs();
        using (LibraryCoordinator library = Library(Client("notes"), new FakeIngest(), jobs, preferences))
        {
            Assert.True(library.AutomaticUpdatesEnabled, "on by default, as on the Mac");
            Assert.Equal(TimeSpan.FromHours(1), library.AutomaticUpdatesInterval);
            library.AutomaticUpdatesInterval = TimeSpan.FromHours(6);
            library.RunsAtLaunch = true;

            // Two changes in a burst share one run.
            library.TriggerSoon();
            library.TriggerSoon();
            for (int i = 0; i < 50 && jobs.Ran.Count == 0; i++)
            {
                await Task.Delay(100, TestContext.Current.CancellationToken);
            }
            await Task.Delay(300, TestContext.Current.CancellationToken);
            Assert.Equal(["embed"], jobs.Ran);
        }

        using LibraryCoordinator reloaded = Library(Client("notes"), new FakeIngest(), preferences: preferences);
        Assert.Equal(TimeSpan.FromHours(6), reloaded.AutomaticUpdatesInterval);
        Assert.True(reloaded.RunsAtLaunch);
        reloaded.AutomaticUpdatesEnabled = false;
        Assert.False(preferences.Read("automaticUpdates.enabled", true));
    }

    [Fact]
    public void Json_preferences_survive_a_reload()
    {
        string path = Path.Combine(Path.GetTempPath(), $"garage-prefs-{Guid.NewGuid():N}.json");
        try
        {
            new JsonPreferences(path).Write("automaticUpdates.intervalMinutes", 15.0);
            Assert.Equal(15.0, new JsonPreferences(path).Read("automaticUpdates.intervalMinutes", 60.0));
            Assert.True(new JsonPreferences(path).Read("missing", true));
            File.WriteAllText(path, "not json");
            Assert.Equal(60.0, new JsonPreferences(path).Read("automaticUpdates.intervalMinutes", 60.0));
        }
        finally
        {
            File.Delete(path);
        }
    }

    private static SourceRowPresentation SourceRow(string slug, LibraryCoordinator library)
    {
        using var culture = new CultureScope("en-US");
        SourceActivity activity = library.ActivityOf(slug);
        return SourceRowPresentation.Make(
            new RegisteredSource(slug, "filesystem", $@"C:\{slug}", "document"), null, activity,
            run: activity == SourceActivity.Ingesting ? library.IngestSnapshot : null);
    }

    // ---- Sources rows during a run (SourcesPresentationTests.swift) ----------------------------

    private static RegisteredSource Source(long documents = 0, long expected = 0) =>
        new("notes", "filesystem", "~/Notes", "document", DocumentCount: documents, ExpectedElements: expected);

    [Fact]
    public void An_ingesting_source_shows_its_run_and_can_be_cancelled()
    {
        using var culture = new CultureScope("en-US");
        var run = new SourceIngestSnapshot("ingest", 0.42, "42%", 1_204, 2_860, 1_180, 24, 0, "documents", @"C:\Notes\2024\retro.md", "", false);
        SourceRowPresentation row = SourceRowPresentation.Make(Source(), null, SourceActivity.Ingesting, run: run);
        Assert.Equal("Reading 42%", row.Status);
        Assert.Equal(SourceTone.Active, row.StatusTone);
        Assert.Equal(0.42, row.Progress);
        Assert.False(row.IsIndeterminate);
        Assert.Equal("1,204 of 2,860 documents · 1,180 indexed · 24 skipped", row.Counts);
        Assert.Equal(@"C:\Notes\2024\retro.md", row.CurrentItem);
        Assert.True(row.ShowsCancel);
        Assert.Equal("Cancel", row.CancelTitle);
        Assert.False(row.CancelDisabled);
        Assert.Empty(row.Badges);
    }

    [Fact]
    public void An_ingest_without_a_total_moves_the_bar_without_a_fraction()
    {
        using var culture = new CultureScope("en-US");
        var run = new SourceIngestSnapshot("ingest", null, "0%", 12, 0, 12, 0, 1, "messages", null, "", true);
        SourceRowPresentation row = SourceRowPresentation.Make(Source(), null, SourceActivity.Ingesting, run: run);
        Assert.Equal("Stopping…", row.Status);
        Assert.True(row.IsIndeterminate);
        Assert.Null(row.Progress);
        Assert.Equal("12 messages · 12 indexed · 1 failed", row.Counts);
        Assert.Null(row.CurrentItem);
        Assert.Equal("Cancelling…", row.CancelTitle);
        Assert.True(row.CancelDisabled);
    }

    [Fact]
    public void Queued_rows_and_cancel_all()
    {
        using var culture = new CultureScope("en-US");
        SourceRowPresentation queued = SourceRowPresentation.Make(Source(5, 10), null, SourceActivity.Queued);
        Assert.Equal("Waiting for its turn", queued.Status);
        Assert.Equal(0.5, queued.Progress);
        Assert.True(queued.ShowsCancel);
        Assert.True(SourceRowPresentation.Make(Source(), null, SourceActivity.Queued, isCancellingAll: true).CancelDisabled);
        SourceRowPresentation removing = SourceRowPresentation.Make(Source(), null, SourceActivity.Removing);
        Assert.Equal("Cancelling…", removing.CancelTitle);
        Assert.True(removing.CancelDisabled);
    }

    [Fact]
    public void The_last_run_shows_on_an_idle_row()
    {
        using var culture = new CultureScope("en-US");
        SourceRowPresentation failed = SourceRowPresentation.Make(Source(10, 12), null, SourceActivity.Idle,
            lastRun: new SourceLastRun(10, 0, 2, "permission denied", false));
        Assert.Equal("Last ingest failed", failed.Status);
        Assert.Equal(SourceTone.Bad, failed.StatusTone);
        Assert.Equal("permission denied", failed.Error);
        Assert.Equal("10 of 12 documents", failed.Counts);

        SourceRowPresentation cancelled = SourceRowPresentation.Make(Source(12, 12), null, SourceActivity.Idle,
            lastRun: new SourceLastRun(0, 12, 0, null, true));
        Assert.Equal("Last ingest was cancelled", cancelled.Status);
        Assert.Equal(SourceTone.Neutral, cancelled.StatusTone);
    }

    // ---- The Library box (IndexingPresentation) -------------------------------------------------

    private static LibraryPresentation Box(LibraryActivity? activity = null, long documents = 0, long expected = 0, long chunks = 0,
        long embedded = 0, int models = 0, bool backend = true, string? error = null, int sources = 1) =>
        new(
            [.. Enumerable.Range(0, sources).Select(i => new RegisteredSource($"s{i}", "filesystem", "~", "document", DocumentCount: documents, ExpectedElements: expected))],
            new CorpusStats(sources, documents * sources, 0, chunks, 0, models > 0 ? [new ModelEmbeddingStats("bge-m3", true, embedded)] : null),
            models,
            activity ?? LibraryActivity.None,
            LastRunError: error,
            BackendIsRunning: backend);

    [Fact]
    public void Idle_headlines()
    {
        using var culture = new CultureScope("en-US");
        Assert.Equal("Backend stopped", Box(backend: false).Headline().Title);
        LibraryPresentation empty = Box(sources: 0);
        Assert.Equal("Nothing to index yet", empty.Headline().Title);
        Assert.Equal(LibraryAction.AddSource, empty.Action);
        Assert.Equal("Not indexed yet", Box().Headline().Title);
        Assert.Equal("1 source · Update Everything scans, reads, indexes and gleans them.", Box().Headline().Detail);

        LibraryHeadline toIndex = Box(documents: 90, expected: 100, chunks: 1000, embedded: 880, models: 1).Headline();
        Assert.Equal("130 items to index", toIndex.Title);
        Assert.Equal("10 documents to read · 120 chunks to index", toIndex.Detail);
        Assert.Equal((0.9 + 0.88) / 2, toIndex.Progress!.Value, 6);

        LibraryHeadline done = Box(documents: 100, expected: 100, chunks: 1000, embedded: 1000, models: 1).Headline();
        Assert.Equal("Up to date", done.Title);
        Assert.Equal("100 documents in 1 source · indexed with 1 model", done.Detail);
        Assert.Equal(LibraryAction.UpdateEverything, Box().Action);

        LibraryHeadline failed = Box(documents: 100, expected: 100, error: "notes: permission denied\ntraceback").Headline();
        Assert.Equal("notes: permission denied", failed.Detail);
        Assert.True(failed.DetailIsError);
    }

    [Fact]
    public void Running_headlines()
    {
        using var culture = new CultureScope("en-US");
        LibraryHeadline scan = Box(new LibraryActivity.Scanning("*", 1_204)).Headline();
        Assert.Equal(("Scanning all sources…", "1,204 items so far", LibraryStage.Scan), (scan.Title, scan.Detail, scan.Stage));

        var run = new SourceIngestSnapshot("ingest", 0.5, "50%", 1, 2, 1, 0, 0, "documents", @"C:\a.md", "", false);
        LibraryHeadline one = Box(new LibraryActivity.Ingesting("notes", "notes", run)).Headline();
        Assert.Equal(("Reading notes", "50%", "1 of 2 documents · 1 indexed", @"C:\a.md"), (one.Title, one.Percent, one.Detail, one.CurrentItem));
        Assert.Equal("Reading all sources · mail", Box(new LibraryActivity.Ingesting(null, "mail", null)).Headline().Title);
        Assert.Equal("Stopping…", (Box(new LibraryActivity.Ingesting(null, "mail", null)) with { IsStopping = true }).Headline().Title);
        Assert.Equal("Indexing new chunks", Box(new LibraryActivity.Embedding(null, null)).Headline().Title);
        Assert.Equal("Gleaning facts", Box(new LibraryActivity.Distilling("Gleaning facts… 3 of 9", 0.33)).Headline().Title);
        Assert.Equal(LibraryAction.Stop, Box(new LibraryActivity.Embedding(null, null)).Action);
        Assert.Equal("Waiting to read a, b, c and 2 more", LibraryPresentation.WaitingTitle(["a", "b", "c", "d", "e"]));
    }

    // ---- Service rows (ServiceRowPresentation.xpc) ---------------------------------------------

    private static SelfTestResult Test(string name, string status) => new() { Name = name, Status = status };

    [Fact]
    public void Service_rows()
    {
        using var culture = new CultureScope("en-US");
        var report = new ServiceStatusReport { State = "running", Tests = { Test("Python Runtime", "passed"), Test("libpq", "passed"), Test("libtesseract", "skipped") } };
        ServiceRowPresentation running = ServiceRowPresentation.Make("ingest", ServiceState.Running, null, 3.4, report);
        Assert.Equal(("Ingest", "Running · 3 ms · 2 passed, 1 skipped (libtesseract)", false), (running.Name, running.Detail, running.DetailIsError));
        Assert.Null(running.RestartTint);

        report.Tests.Add(Test("Database Connection", "failed"));
        ServiceRowPresentation failing = ServiceRowPresentation.Make("core", ServiceState.Running, null, 1, report);
        Assert.Equal("Garage Backend", failing.Name);
        Assert.True(failing.DetailIsError);
        Assert.Equal(Tint.Orange, failing.RestartTint);

        ServiceRowPresentation gone = ServiceRowPresentation.Make("core", ServiceState.Unreachable, "The process exited (code 1)\nmore", null, null);
        Assert.Equal("Can't be reached: The process exited (code 1)", gone.Detail);
        Assert.Equal((Tint.Red, Tint.Red), (gone.Tint, gone.RestartTint));
        Assert.Equal("Starting…", ServiceRowPresentation.Make("core", ServiceState.Checking, null, null, null).Detail);
        Assert.True(ServiceRowPresentation.Make("core", ServiceState.Restarting, null, null, null).IsBusy);
    }
}

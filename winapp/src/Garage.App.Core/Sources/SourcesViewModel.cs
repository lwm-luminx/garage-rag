using System.Collections.ObjectModel;
using System.Globalization;
using CommunityToolkit.Mvvm.ComponentModel;
using Garage.App.Core.Backend;
using Garage.App.Core.Library;
using Garage.App.Core.Operations;
using Garage.App.Core.State;
using Grpc.Core;

namespace Garage.App.Core.Sources;

/// <summary>What the Add Source form sends.</summary>
public sealed record NewSource(string Slug, string Root, string Kind = "filesystem", string CorpusClass = "document", string TrustTier = "authored");

/// <summary>
/// The Sources page: the registered sources with their rows, and the operations that change them —
/// Add, Remove, Sync with <c>garage.json</c> on <see cref="AppState.Operations"/>, one at a time as on the
/// Mac — and the pipeline's Scan, Scan &amp; Ingest, Update Everything and Cancel through the
/// <see cref="LibraryCoordinator"/>, whose queue and progress the rows show.
/// </summary>
public sealed partial class SourcesViewModel : ObservableObject
{
    private static readonly TimeSpan CallTimeout = TimeSpan.FromSeconds(60);

    /// <summary>A quarter second each: a minute for a cancelled scan or ingest to reach its next step.</summary>
    private const int RemovalWaitLooks = 240;

    private readonly GarageService.GarageServiceClient _client;
    private readonly OperationRunner _runner;
    private readonly INotifier _notifier;
    private readonly Func<string, SourceAccess> _checkAccess;
    private readonly HashSet<string> _removing = new(StringComparer.Ordinal);
    private IReadOnlyList<RegisteredSource> _sources = [];
    private Dictionary<string, SourceAccess> _access = new(StringComparer.Ordinal);

    /// <summary>Creates the page's model.</summary>
    /// <param name="client">The backend.</param>
    /// <param name="runner">The runner operations go through.</param>
    /// <param name="notifier">Where finished scans are announced.</param>
    /// <param name="checkAccess">Checks a root on this PC; <see cref="LocalAccess.Check"/> by default.</param>
    /// <param name="library">The pipeline; one without ingest when none is given (tests).</param>
    public SourcesViewModel(
        GarageService.GarageServiceClient client,
        OperationRunner runner,
        INotifier? notifier = null,
        Func<string, SourceAccess>? checkAccess = null,
        LibraryCoordinator? library = null)
    {
        _client = client ?? throw new ArgumentNullException(nameof(client));
        _runner = runner ?? throw new ArgumentNullException(nameof(runner));
        _notifier = notifier ?? SilentNotifier.Instance;
        _checkAccess = checkAccess ?? LocalAccess.Check;
        Library = library ?? new LibraryCoordinator(client, NoIngestHost.Instance, LibraryJobs.None, new MemoryPreferences(), _notifier);
        Library.PropertyChanged += (_, _) => Rebuild();
        Library.IngestQueue.CollectionChanged += (_, _) => Rebuild();
        Library.SourcesChanged += async (_, _) => await LoadAsync().ConfigureAwait(true);
    }

    /// <summary>The pipeline the page drives.</summary>
    public LibraryCoordinator Library { get; }

    /// <summary>The sources as last read.</summary>
    public IReadOnlyList<RegisteredSource> Registered => _sources;

    /// <summary>The rows, in the server's order.</summary>
    public ObservableCollection<SourceRowPresentation> Rows { get; } = [];

    /// <summary>"1,234 documents in 3 sources".</summary>
    [ObservableProperty]
    public partial string Summary { get; private set; } = SourcesSummary.Line(0, 0);

    /// <summary>Why the list failed to load.</summary>
    [ObservableProperty]
    public partial string? ErrorMessage { get; private set; }

    /// <summary>The last operation's outcome, for the page's status line.</summary>
    [ObservableProperty]
    public partial string? LastResult { get; private set; }

    /// <summary>Whether an operation is running (the runner's busy flag).</summary>
    public bool IsBusy => _runner.IsRunning;

    /// <summary>Why ingest cannot run here, or null.</summary>
    public string? IngestUnavailable => Library.IngestUnavailable;

    /// <summary>The slugs in use, for the Add form's suggestion.</summary>
    public IReadOnlySet<string> TakenSlugs => _sources.Select(s => s.Slug).ToHashSet(StringComparer.Ordinal);

    /// <summary>The source behind a row.</summary>
    public RegisteredSource? SourceFor(string slug) => _sources.FirstOrDefault(s => s.Slug == slug);

    /// <summary>
    /// Reads the sources, and which of <c>garage.json</c>'s are not in the database yet (a dry-run
    /// sync), then checks each root on this PC.
    /// </summary>
    public async Task LoadAsync(CancellationToken cancellationToken = default)
    {
        ErrorMessage = null;
        try
        {
            ListSourcesResponse listed = await _client.ListSourcesAsync(new ListSourcesRequest(), Options(cancellationToken)).ConfigureAwait(true);
            HashSet<string> undeclared = [];
            List<string> configOnly = [];
            try
            {
                SyncSourcesResponse sync = await _client.SyncSourcesAsync(new SyncSourcesRequest { DryRun = true }, Options(cancellationToken)).ConfigureAwait(true);
                undeclared = [.. sync.Undeclared.Select(u => u.Slug)];
                configOnly = [.. sync.Created];
            }
            catch (RpcException)
            {
                // Without the dry run every source reads as in both; nothing is lost but the badges.
            }

            List<RegisteredSource> sources =
            [
                .. listed.Sources.Select(s => RegisteredSource.From(s, undeclared.Contains(s.Slug) ? SourceOrigin.Database : SourceOrigin.Both)),
                .. configOnly.Where(slug => listed.Sources.All(s => s.Slug != slug))
                    .Select(slug => new RegisteredSource(slug, "filesystem", "declared in garage.json", "document", Origin: SourceOrigin.Config)),
            ];
            Dictionary<string, SourceAccess> access = await Task.Run(
                () => sources.Where(s => s.Origin != SourceOrigin.Config && s.Kind is "filesystem" or "git")
                    .ToDictionary(s => s.Slug, s => _checkAccess(s.Root), StringComparer.Ordinal),
                cancellationToken).ConfigureAwait(true);
            _sources = sources;
            _access = access;
            Rebuild();
        }
        catch (RpcException ex)
        {
            ErrorMessage = RpcErrors.Describe(ex);
        }
    }

    /// <summary>
    /// Registers a source, then reloads. With Automatic Updates on, the new source is scanned and read
    /// a moment later, as on the Mac.
    /// </summary>
    public async Task<OperationResult> AddAsync(NewSource source)
    {
        OperationResult result = await RunAsync(async (_, token) =>
        {
            ArgumentNullException.ThrowIfNull(source);
            AddSourceResponse added = await _client.AddSourceAsync(new AddSourceRequest
            {
                Slug = source.Slug.Trim(),
                Root = source.Root.Trim(),
                Kind = source.Kind,
                CorpusClass = source.CorpusClass,
                Trust = source.TrustTier,
            }, Options(token)).ConfigureAwait(true);
            return string.IsNullOrEmpty(added.Message) ? $"{(added.Created ? "Added" : "Updated")} {added.Slug} → {added.Root}" : added.Message;
        }).ConfigureAwait(true);
        if (result.Succeeded)
        {
            Library.TriggerSoon();
        }
        return result;
    }

    /// <summary>
    /// Deregisters a source and deletes its documents, chunks and vectors, then reloads. Whatever covers
    /// the source is cancelled first, and the removal waits for it to stop, so it never races a scan or
    /// ingest of it.
    /// </summary>
    public async Task<OperationResult> RemoveAsync(string slug)
    {
        if (!_removing.Add(slug))
        {
            return new OperationResult(false, $"{slug} is already being removed");
        }
        Rebuild();
        try
        {
            await Library.CancelAsync(slug).ConfigureAwait(true);
            for (int look = 0; Library.ActivityOf(slug) != SourceActivity.Idle; look++)
            {
                if (look >= RemovalWaitLooks)
                {
                    LastResult = $"Could not remove {slug}: its scan or ingest has not stopped yet. Try again shortly.";
                    return new OperationResult(false, LastResult);
                }
                await Task.Delay(250).ConfigureAwait(true);
            }
            return await RunAsync(async (_, token) =>
            {
                RemoveSourceResponse removed = await _client.RemoveSourceAsync(new RemoveSourceRequest { Slug = slug }, Options(token)).ConfigureAwait(true);
                return string.IsNullOrEmpty(removed.Message)
                    ? string.Create(CultureInfo.CurrentCulture, $"Removed {slug} and {removed.DeletedDocuments:N0} {SourceRowPresentation.Plural("document", removed.DeletedDocuments)}")
                    : removed.Message;
            }).ConfigureAwait(true);
        }
        finally
        {
            _removing.Remove(slug);
            Rebuild();
        }
    }

    /// <summary>Applies <c>garage.json</c>'s sources to the database, then reloads.</summary>
    public Task<OperationResult> SyncAsync() => RunAsync(async (_, token) =>
    {
        SyncSourcesResponse sync = await _client.SyncSourcesAsync(new SyncSourcesRequest(), Options(token)).ConfigureAwait(true);
        return string.IsNullOrEmpty(sync.Message)
            ? $"Synced {sync.Declared} declared sources: {sync.Created.Count} added, {sync.Updated.Count} updated"
            : sync.Message;
    });

    /// <summary>
    /// Counts what one source (or every enabled one, for "*") holds, updating each row as the scan
    /// reports, then reloads so the rows show the new totals.
    /// </summary>
    public async Task<OperationResult> ScanAsync(string source = "*")
    {
        bool ok = await Library.ScanAsync(source).ConfigureAwait(true);
        LastResult = Library.LastResult;
        if (ok)
        {
            _notifier.Notify("Scan finished", LastResult ?? "");
        }
        return new OperationResult(ok, LastResult ?? "");
    }

    /// <summary>Scan &amp; Ingest of one source: its row shows the queue, the scan, then the read.</summary>
    public async Task<bool> ScanAndIngestAsync(string slug)
    {
        bool ok = await Library.ScanAndIngestAsync(slug).ConfigureAwait(true);
        LastResult = Library.LastResult;
        return ok;
    }

    /// <summary>Update Everything: scan, read, index and glean.</summary>
    public async Task<bool> UpdateEverythingAsync()
    {
        bool ok = await Library.UpdateEverythingAsync().ConfigureAwait(true);
        LastResult = Library.LastResult;
        return ok;
    }

    /// <summary>Cancels one source's scan, read or place in the queue.</summary>
    public Task CancelAsync(string slug) => Library.CancelAsync(slug);

    /// <summary>Stops everything the pipeline is doing.</summary>
    public void Cancel() => Library.CancelAll();

    private async Task<OperationResult> RunAsync(Func<OperationRunner, CancellationToken, Task<string>> operation)
    {
        OnPropertyChanged(nameof(IsBusy));
        OperationResult result = await _runner.RunAsync(operation).ConfigureAwait(true);
        LastResult = result.Output;
        OnPropertyChanged(nameof(IsBusy));
        await LoadAsync().ConfigureAwait(true);
        return result;
    }

    private void Rebuild()
    {
        List<SourceRowPresentation> rows = [];
        foreach (RegisteredSource source in _sources)
        {
            SourceActivity activity = _removing.Contains(source.Slug) ? SourceActivity.Removing : Library.ActivityOf(source.Slug);
            rows.Add(SourceRowPresentation.Make(
                source,
                _access.GetValueOrDefault(source.Slug),
                activity,
                Library.ScanFound.GetValueOrDefault(source.Slug),
                activity == SourceActivity.Ingesting ? Library.IngestSnapshot : null,
                Library.LastRuns.GetValueOrDefault(source.Slug),
                Library.IsCancellingAll));
        }
        // Replace only the rows that changed, so a progress update does not rebuild the whole list.
        for (int i = 0; i < rows.Count; i++)
        {
            if (i >= Rows.Count)
            {
                Rows.Add(rows[i]);
            }
            else if (!RowEquals(Rows[i], rows[i]))
            {
                Rows[i] = rows[i];
            }
        }
        while (Rows.Count > rows.Count)
        {
            Rows.RemoveAt(Rows.Count - 1);
        }
        Summary = SourcesSummary.Line(_sources.Count(s => s.Origin != SourceOrigin.Config), _sources.Sum(s => s.DocumentCount));
    }

    // Records compare their Badges list by reference; compare it by content.
    private static bool RowEquals(SourceRowPresentation a, SourceRowPresentation b) =>
        a with { Badges = [] } == b with { Badges = [] } && a.Badges.SequenceEqual(b.Badges);

    private static CallOptions Options(CancellationToken cancellationToken) =>
        new(deadline: DateTime.UtcNow + CallTimeout, cancellationToken: cancellationToken);
}

/// <summary>Whether this PC can read a folder: it exists, and listing it is allowed.</summary>
public static class LocalAccess
{
    /// <summary>Checks <paramref name="root"/>, expanding a leading <c>~</c> to the user's profile.</summary>
    public static SourceAccess Check(string root)
    {
        ArgumentNullException.ThrowIfNull(root);
        string path = Expand(root);
        try
        {
            if (File.Exists(path))
            {
                return new SourceAccess(true, true, "");
            }
            if (!Directory.Exists(path))
            {
                return new SourceAccess(false, false, "Path does not exist");
            }
            using IEnumerator<string> entries = Directory.EnumerateFileSystemEntries(path).GetEnumerator();
            _ = entries.MoveNext();
            return new SourceAccess(true, true, "");
        }
        catch (UnauthorizedAccessException)
        {
            return new SourceAccess(true, false, "Access is denied");
        }
        catch (IOException ex)
        {
            return new SourceAccess(true, false, ex.Message);
        }
    }

    /// <summary><c>~</c> and <c>~/…</c> (or <c>~\…</c>) under the user's profile; anything else as it is.</summary>
    public static string Expand(string root)
    {
        ArgumentNullException.ThrowIfNull(root);
        if (root == "~" || root.StartsWith("~/", StringComparison.Ordinal) || root.StartsWith("~\\", StringComparison.Ordinal))
        {
            string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            return root.Length == 1 ? home : Path.Combine(home, root[2..]);
        }
        return root;
    }
}

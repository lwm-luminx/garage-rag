using System.ComponentModel;
using System.Globalization;
using CommunityToolkit.Mvvm.ComponentModel;
using Garage.App.Core.Backend;
using Grpc.Core;

namespace Garage.App.Core.Database;

/// <summary>
/// The Database page: the server row (Garage's own Postgres, when the app runs one), the Schema row,
/// Backups, the Contents box from <c>GetStats</c>, and Reset Database. The Mac's <c>DatabaseView</c>
/// with <c>DatabasePresentation</c>.
/// </summary>
public sealed partial class DatabaseViewModel : ObservableObject
{
    private static readonly TimeSpan CallTimeout = TimeSpan.FromSeconds(30);

    private readonly GarageService.GarageServiceClient _client;
    private long? _documents;
    private bool _schemaFailed;
    private bool _schemaKnown;

    /// <summary>The server's state with the schema taken into account (a failed schema step reads as updates needed), or null without an own server.</summary>
    public PostgresStatus? EffectiveStatus => Postgres is null
        ? null
        : _schemaFailed && Postgres.Status.State == PostgresState.Running ? Postgres.Status with { State = PostgresState.NeedsMigration } : Postgres.Status;

    /// <summary>Whether the schema was applied at start-up (or since): null until it has been tried.</summary>
    public bool? SchemaApplied => _schemaKnown ? !_schemaFailed : null;

    /// <summary>Creates the page's model; <paramref name="postgres"/> is null when the app runs no Postgres of its own.</summary>
    public DatabaseViewModel(GarageService.GarageServiceClient client, PostgresSupervisor? postgres = null)
    {
        _client = client ?? throw new ArgumentNullException(nameof(client));
        Postgres = postgres;
        if (postgres is not null)
        {
            ((INotifyPropertyChanged)postgres).PropertyChanged += (_, _) => Recompute();
        }
        Recompute();
    }

    /// <summary>Garage's own Postgres, or null.</summary>
    public PostgresSupervisor? Postgres { get; }

    /// <summary>Whether the app runs its own Postgres, which the server row and Reset need.</summary>
    public bool HasOwnServer => Postgres is not null;

    /// <summary>The server row.</summary>
    [ObservableProperty]
    public partial DatabaseHeadline? Headline { get; private set; }

    /// <summary>The Schema row.</summary>
    [ObservableProperty]
    public partial DatabaseSchemaPresentation? Schema { get; private set; }

    /// <summary>The schema is being applied.</summary>
    [ObservableProperty]
    public partial bool IsApplyingSchema { get; private set; }

    /// <summary>A backup or restore is running.</summary>
    [ObservableProperty]
    public partial bool IsBackingUp { get; private set; }

    /// <summary>The server's size and extensions, once read.</summary>
    [ObservableProperty]
    public partial PostgresDetails? Details { get; private set; }

    /// <summary>The last schema, backup or restore run's outcome, shown under its box.</summary>
    [ObservableProperty]
    public partial (bool Succeeded, string Message)? ActionResult { get; private set; }

    /// <summary>
    /// Called before a restore replaces the database, to stop what reads or writes it (the pipeline),
    /// and after, to reread what every page shows. The app sets them.
    /// </summary>
    public Func<Task>? BeforeReplace { get; set; }

    /// <inheritdoc cref="BeforeReplace"/>
    public Func<Task>? AfterReplace { get; set; }

    /// <summary>The Contents box, once read.</summary>
    [ObservableProperty]
    public partial DatabaseContentsPresentation? Contents { get; private set; }

    /// <summary>Whether a read is in flight.</summary>
    [ObservableProperty]
    public partial bool IsLoading { get; private set; }

    /// <summary>Why the read failed.</summary>
    [ObservableProperty]
    public partial string? ErrorMessage { get; private set; }

    /// <summary>Reset Database is stopping the services and deleting the cluster.</summary>
    [ObservableProperty]
    public partial bool IsResetting { get; set; }

    /// <summary>A relaunch after a reset is creating the new database and registering the sources.</summary>
    [ObservableProperty]
    public partial bool IsFinishingReset { get; set; }

    /// <summary>How the second half of a reset went, for the page (the Mac's <c>databaseResetOutcome</c>).</summary>
    [ObservableProperty]
    public partial (bool Succeeded, string Message)? ResetOutcome { get; set; }

    /// <summary>Reads the corpus counts.</summary>
    public async Task RefreshAsync(CancellationToken cancellationToken = default)
    {
        IsLoading = true;
        ErrorMessage = null;
        try
        {
            StatsResponse stats = await _client.GetStatsAsync(
                new StatsRequest(), new CallOptions(deadline: DateTime.UtcNow + CallTimeout, cancellationToken: cancellationToken)).ConfigureAwait(true);
            _documents = stats.Documents;
            if (Postgres is { Status.IsUp: true } postgres)
            {
                try
                {
                    Details = await postgres.DetailsAsync(cancellationToken).ConfigureAwait(true);
                }
                catch (PostgresException)
                {
                    Details = null;
                }
            }
            Contents = DatabaseContentsPresentation.For(CorpusStats.From(stats), Details?.SizeBytes);
        }
        catch (RpcException ex)
        {
            ErrorMessage = RpcErrors.Describe(ex);
        }
        finally
        {
            IsLoading = false;
            Recompute();
        }
    }

    /// <summary>
    /// Readies a database the app's services just connected to: applies the schema (the migrations are
    /// meant to be re-applied), and for a new cluster (a first launch, or after a reset), or one with no
    /// sources, registers the sources <c>garage.json</c> declares, as the Mac's <c>finishDatabaseReset</c>.
    /// </summary>
    /// <returns>What happened, for the log and, after a reset, the page.</returns>
    public static async Task<(bool Succeeded, string Message)> PrepareAsync(GarageService.GarageServiceClient client, bool createdCluster, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(client);
        var options = new CallOptions(deadline: DateTime.UtcNow + TimeSpan.FromMinutes(5), cancellationToken: cancellationToken);
        try
        {
            InitDbResponse schema = await client.InitDbAsync(new InitDbRequest(), options).ConfigureAwait(true);
            // A cluster an earlier start created but never finished (the app quit first) has no sources
            // either; registering garage.json's into an empty table only adds them.
            bool empty = createdCluster || (await client.ListSourcesAsync(new ListSourcesRequest(), options).ConfigureAwait(true)).Sources.Count == 0;
            if (!empty)
            {
                return (true, string.IsNullOrEmpty(schema.Message) ? "Schema is up to date" : schema.Message);
            }
            SyncSourcesResponse synced = await client.SyncSourcesAsync(new SyncSourcesRequest(), options).ConfigureAwait(true);
            int sources = synced.Created.Count + synced.Updated.Count;
            return (true, sources == 0
                ? "A new database was created. garage.json declares no sources; add them on the Sources page."
                : string.Create(CultureInfo.CurrentCulture, $"A new database was created, with the {sources} {(sources == 1 ? "source" : "sources")} garage.json declares. Update Everything indexes them."));
        }
        catch (RpcException ex)
        {
            return (false, $"The new database could not be set up: {RpcErrors.Describe(ex)}");
        }
    }

    /// <summary>
    /// Records how the start-up schema step went (<see cref="PrepareAsync"/>): a failure leaves the
    /// Schema row asking for the updates.
    /// </summary>
    public void RecordSchema(bool applied)
    {
        _schemaKnown = true;
        _schemaFailed = !applied;
        Recompute();
    }

    /// <summary>Check Again / Apply Updates: applies the schema (<c>InitDb</c>) now.</summary>
    public async Task ApplySchemaAsync(CancellationToken cancellationToken = default)
    {
        IsApplyingSchema = true;
        try
        {
            InitDbResponse schema = await _client.InitDbAsync(new InitDbRequest(),
                new CallOptions(deadline: DateTime.UtcNow + TimeSpan.FromMinutes(5), cancellationToken: cancellationToken)).ConfigureAwait(true);
            _schemaFailed = false;
            _schemaKnown = true;
            ActionResult = (true, string.IsNullOrEmpty(schema.Message) ? "The schema is up to date." : schema.Message);
        }
        catch (RpcException ex)
        {
            _schemaFailed = true;
            _schemaKnown = true;
            ActionResult = (false, $"The schema could not be applied: {RpcErrors.Describe(ex)}");
        }
        finally
        {
            IsApplyingSchema = false;
        }
    }

    /// <summary>Back Up…: a custom-format dump to <paramref name="destination"/>.</summary>
    public async Task BackupAsync(string destination, CancellationToken cancellationToken = default)
    {
        if (Postgres is null)
        {
            return;
        }
        IsBackingUp = true;
        try
        {
            await Postgres.BackupAsync(destination, cancellationToken).ConfigureAwait(true);
            ActionResult = (true, $"Saved {Path.GetFileName(destination)}.");
        }
        catch (Exception ex) when (ex is PostgresException or IOException)
        {
            ActionResult = (false, ex.Message);
        }
        finally
        {
            IsBackingUp = false;
        }
    }

    /// <summary>
    /// Restore…: replaces the database with the dump at <paramref name="source"/>, then applies the
    /// schema and rereads everything, since the dump's sources, models and schema are its own.
    /// </summary>
    public async Task RestoreAsync(string source, CancellationToken cancellationToken = default)
    {
        if (Postgres is null)
        {
            return;
        }
        IsBackingUp = true;
        try
        {
            if (BeforeReplace is { } before)
            {
                await before().ConfigureAwait(true);
            }
            await Postgres.RestoreAsync(source, cancellationToken).ConfigureAwait(true);
            await ApplySchemaAsync(cancellationToken).ConfigureAwait(true);
            ActionResult = _schemaFailed ? ActionResult : (true, $"Restored the database from {Path.GetFileName(source)}.");
        }
        catch (Exception ex) when (ex is PostgresException or IOException)
        {
            ActionResult = (false, ex.Message);
        }
        finally
        {
            IsBackingUp = false;
            if (AfterReplace is { } after)
            {
                await after().ConfigureAwait(true);
            }
            await RefreshAsync(cancellationToken).ConfigureAwait(true);
        }
    }

    private void Recompute()
    {
        if (Postgres is null)
        {
            Headline = null;
            Schema = null;
            return;
        }
        PostgresStatus status = EffectiveStatus!;
        Headline = DatabaseHeadline.For(status, Postgres.Layout.Port, pendingMigrations: 0, IsResetting, _documents, Details?.SizeBytes);
        Schema = DatabaseSchemaPresentation.For(status, [], IsApplyingSchema);
    }

    partial void OnIsApplyingSchemaChanged(bool value) => Recompute();

    partial void OnDetailsChanged(PostgresDetails? value) => Recompute();

    partial void OnIsResettingChanged(bool value) => Recompute();
}

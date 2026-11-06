using Garage.App.Core.Database;
using Garage.App.Core.Presentation;
using Garage.App.Core.State;
using Garage.App.Core.Tests.TestSupport;
using Grpc.Core;

namespace Garage.App.Core.Tests;

// Readying the app's own database after a start or a reset (the Mac's finishDatabaseReset), and the
// Database page's server row. PostgresSupervisor itself is tested against a real build in
// Garage.Services.Tests (GARAGE_TEST_POSTGRES_HOME).
public sealed class DatabaseHostTests
{
    [Fact]
    public async Task A_new_cluster_gets_the_schema_and_garage_json_sources()
    {
        using var culture = new CultureScope("en-US");
        var client = new FakeGarageClient { OnSyncSources = _ => new SyncSourcesResponse { Created = { "notes", "mail" } } };

        (bool ok, string message) = await DatabaseViewModel.PrepareAsync(client, createdCluster: true, TestContext.Current.CancellationToken);

        Assert.True(ok);
        Assert.Equal("A new database was created, with the 2 sources garage.json declares. Update Everything indexes them.", message);
        Assert.Equal([typeof(InitDbRequest), typeof(SyncSourcesRequest)], client.Requests.Select(r => r.GetType()));
        Assert.False(client.Requests.OfType<SyncSourcesRequest>().Single().DryRun);
    }

    [Fact]
    public async Task An_existing_database_only_gets_schema_updates()
    {
        var client = new FakeGarageClient
        {
            OnListSources = _ => new ListSourcesResponse { Sources = { new SourceInfo { Slug = "notes" } } },
        };

        (bool ok, string message) = await DatabaseViewModel.PrepareAsync(client, createdCluster: false, TestContext.Current.CancellationToken);

        Assert.True(ok);
        Assert.Equal("schema applied", message);
        Assert.Empty(client.Requests.OfType<SyncSourcesRequest>());
    }

    [Fact]
    public async Task A_cluster_left_without_sources_gets_them_on_the_next_start()
    {
        using var culture = new CultureScope("en-US");
        var client = new FakeGarageClient();

        (bool ok, string message) = await DatabaseViewModel.PrepareAsync(client, createdCluster: false, TestContext.Current.CancellationToken);

        Assert.True(ok);
        Assert.StartsWith("A new database was created. garage.json declares no sources", message, StringComparison.Ordinal);
        Assert.Single(client.Requests.OfType<SyncSourcesRequest>());
    }

    [Fact]
    public async Task A_failure_says_what_the_server_said()
    {
        var client = new FakeGarageClient { OnInitDb = _ => throw new RpcException(new Status(StatusCode.Internal, "permission denied for schema public\nDETAIL: …")) };

        (bool ok, string message) = await DatabaseViewModel.PrepareAsync(client, createdCluster: true, TestContext.Current.CancellationToken);

        Assert.False(ok);
        Assert.Equal("The new database could not be set up: permission denied for schema public", message);
    }

    [Fact]
    public async Task The_server_row_follows_the_supervisor()
    {
        using var culture = new CultureScope("en-US");
        var postgres = new PostgresSupervisor(new PostgresLayout(@"C:\no-postgres", Path.GetTempPath()), new MemorySecretStore());
        var client = new FakeGarageClient { OnStats = _ => new StatsResponse { Documents = 1234 } };
        var page = new DatabaseViewModel(client, postgres);

        Assert.True(page.HasOwnServer);
        Assert.Equal("Stopped", page.Headline!.Title);
        Assert.False(page.Headline.IsActive);

        // The build isn't there, so the start fails and says so.
        Assert.False(await postgres.StartAsync(TestContext.Current.CancellationToken));
        Assert.Equal("Couldn't start", page.Headline.Title);
        Assert.True(page.Headline.DetailIsError);

        await page.RefreshAsync(TestContext.Current.CancellationToken);
        page.IsResetting = true;
        Assert.Equal(("Resetting…", Tint.Red), (page.Headline.Title, page.Headline.Tint));

        Assert.False(new DatabaseViewModel(client).HasOwnServer);
        Assert.Null(new DatabaseViewModel(client).Headline);
    }

    [Fact]
    public void The_database_row_on_status()
    {
        Assert.Equal("Running · PostgreSQL 18.6 · port 14824",
            Services.ServiceRowPresentation.ForPostgres(new PostgresStatus(PostgresState.Running), "PostgreSQL 18.6", 14824).Detail);
        Services.ServiceRowPresentation failed = Services.ServiceRowPresentation.ForPostgres(
            new PostgresStatus(PostgresState.Failed, "initdb failed: out of disk\nmore"), null, 14824);
        Assert.Equal(("Database", "Can't be reached: initdb failed: out of disk", true), (failed.Name, failed.Detail, failed.DetailIsError));
        Assert.True(Services.ServiceRowPresentation.ForPostgres(new PostgresStatus(PostgresState.NeedsMigration), null, 14824).DetailIsError);
        Assert.True(Services.ServiceRowPresentation.ForPostgres(new PostgresStatus(PostgresState.Starting), null, 14824).IsBusy);
    }

    [Fact]
    public async Task Check_again_reapplies_the_schema_and_a_failure_asks_for_updates()
    {
        var client = new FakeGarageClient { OnInitDb = _ => throw new RpcException(new Status(StatusCode.Internal, "disk full")) };
        var postgres = new PostgresSupervisor(new PostgresLayout(@"C:
o-postgres", Path.GetTempPath()), new MemorySecretStore());
        var page = new DatabaseViewModel(client, postgres);

        await page.ApplySchemaAsync(TestContext.Current.CancellationToken);
        Assert.Equal((false, "The schema could not be applied: disk full"), page.ActionResult);

        client.OnInitDb = _ => new InitDbResponse { Message = "applied 14 migrations" };
        await page.ApplySchemaAsync(TestContext.Current.CancellationToken);
        Assert.Equal((true, "applied 14 migrations"), page.ActionResult);
        Assert.Equal(2, client.Requests.OfType<InitDbRequest>().Count());
    }

    [Fact]
    public void The_database_url_escapes_the_password()
    {
        var secrets = new MemorySecretStore();
        secrets.Write(PostgresSupervisor.PasswordSecret, "p@ss/word");
        var postgres = new PostgresSupervisor(new PostgresLayout(@"C:\pg", @"C:\data", 15000), secrets);
        Assert.Equal("postgresql+psycopg://garage:p%40ss%2Fword@127.0.0.1:15000/garage-rag", postgres.DatabaseUrl());
    }
}

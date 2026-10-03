using Garage.App.Core.Database;
using Garage.App.Core.Presentation;
using Garage.App.Core.Tests.TestSupport;

namespace Garage.App.Core.Tests;

// Ported from macapp/Tests/GarageAppUnitTests/DatabasePresentationTests.swift ("On this Mac" reads
// "On this PC"). Server details and backups are U3 and have no counterpart yet.
public sealed class DatabaseTests
{
    private static readonly PostgresStatus Running = new(PostgresState.Running);

    [Fact]
    public void Running_headline_carries_port_documents_and_size()
    {
        using var culture = new CultureScope("en-US");
        DatabaseHeadline headline = DatabaseHeadline.For(Running, 14824, 0, false, 1234, 5_000_000);
        Assert.Equal("Running", headline.Title);
        Assert.Equal(Tint.Green, headline.Tint);
        Assert.StartsWith("On this PC, port 14824 · 1,234 documents · ", headline.Detail, StringComparison.Ordinal);
        Assert.EndsWith("5 MB", headline.Detail, StringComparison.Ordinal);
        Assert.False(headline.DetailIsError);
    }

    [Fact]
    public void Running_headline_leaves_out_what_is_not_known_yet() =>
        Assert.Equal("On this PC, port 14824", DatabaseHeadline.For(Running, 14824, 0, false, null, null).Detail);

    [Fact]
    public void Pending_migrations_turn_the_headline_orange()
    {
        DatabaseHeadline headline = DatabaseHeadline.For(Running, 14824, 2, false, 10, null);
        Assert.Equal("Needs a schema update", headline.Title);
        Assert.Equal(Tint.Orange, headline.Tint);
        Assert.StartsWith("2 schema updates", headline.Detail, StringComparison.Ordinal);

        DatabaseHeadline one = DatabaseHeadline.For(new PostgresStatus(PostgresState.NeedsMigration), 14824, 1, false, null, null);
        Assert.StartsWith("1 schema update to apply", one.Detail, StringComparison.Ordinal);
    }

    [Fact]
    public void Failed_headline_shows_the_error_in_red()
    {
        DatabaseHeadline headline = DatabaseHeadline.For(new PostgresStatus(PostgresState.Failed, "port 14824 is in use"), 14824, 0, false, null, null);
        Assert.Equal("Couldn't start", headline.Title);
        Assert.Equal("port 14824 is in use", headline.Detail);
        Assert.True(headline.DetailIsError);
    }

    [Fact]
    public void Stopped_headline_is_inactive()
    {
        DatabaseHeadline headline = DatabaseHeadline.For(new PostgresStatus(PostgresState.Stopped), 14824, 0, false, null, null);
        Assert.Equal("Stopped", headline.Title);
        Assert.False(headline.IsActive);
    }

    [Fact]
    public void Resetting_wins_over_every_status() =>
        Assert.Equal("Resetting…", DatabaseHeadline.For(Running, 14824, 3, true, 1, 1).Title);

    [Fact]
    public void Schema_up_to_date_offers_check_again()
    {
        DatabaseSchemaPresentation schema = DatabaseSchemaPresentation.For(Running, [], false);
        Assert.Equal("Schema up to date", schema.Title);
        Assert.Equal(SchemaAction.Check, schema.Action);
    }

    [Fact]
    public void Pending_migrations_offer_apply()
    {
        var needs = new PostgresStatus(PostgresState.NeedsMigration);
        DatabaseSchemaPresentation schema = DatabaseSchemaPresentation.For(needs, ["013_fact_prompts.sql", "014_x.sql"], false);
        Assert.Equal("2 updates to apply", schema.Title);
        Assert.Equal(SchemaAction.Apply, schema.Action);
        Assert.Equal(SchemaAction.Apply, DatabaseSchemaPresentation.For(needs, [], false).Action);
    }

    [Fact]
    public void Schema_while_applying_or_stopped_has_no_button()
    {
        Assert.Equal(SchemaAction.Hidden, DatabaseSchemaPresentation.For(Running, ["a.sql"], true).Action);
        DatabaseSchemaPresentation stopped = DatabaseSchemaPresentation.For(new PostgresStatus(PostgresState.Stopped), [], false);
        Assert.Equal(SchemaAction.Hidden, stopped.Action);
        Assert.False(stopped.IsActive);
    }

    [Fact]
    public void Contents_figures()
    {
        using var culture = new CultureScope("en-US");
        var stats = new CorpusStats(3, 1200, 4, 1000, 500, [new("bge-m3", true, 1000), new("nomic", false, 500)]);
        DatabaseContentsPresentation contents = DatabaseContentsPresentation.For(stats, null);
        Assert.Equal(["Sources", "Documents", "Chunks", "Indexed"], contents.Figures.Select(f => f.Label));
        Assert.Equal("1,200", contents.Figures[1].Value);
        Assert.Equal("4 failed", contents.Figures[1].Note);
        Assert.True(contents.Figures[1].NoteIsWarning);
        Assert.Equal("75%", contents.Figures[3].Value);
        Assert.Equal("2 models", contents.Figures[3].Note);
        Assert.False(contents.IsEmpty);
    }

    [Fact]
    public void Contents_without_models_or_size()
    {
        DatabaseContentsPresentation contents = DatabaseContentsPresentation.For(new CorpusStats(), 2048);
        Assert.Equal(["Sources", "Documents", "Chunks", "Indexed", "On Disk"], contents.Figures.Select(f => f.Label));
        Assert.Equal("—", contents.Figures[3].Value);
        Assert.Equal("No models", contents.Figures[3].Note);
        Assert.Null(contents.Figures[1].Note);
        Assert.True(contents.IsEmpty);
    }

    [Fact]
    public async Task The_page_reads_its_contents_from_GetStats()
    {
        using var culture = new CultureScope("en-US");
        var client = new FakeGarageClient
        {
            OnStats = _ => new StatsResponse { Sources = 2, Documents = 242, Chunks = 2226, ChunksByModel = { ["bge-m3"] = 2226 } },
        };
        var page = new DatabaseViewModel(client);
        await page.RefreshAsync(TestContext.Current.CancellationToken);

        Assert.Equal(["2", "242", "2,226", "100%"], page.Contents!.Figures.Select(f => f.Value));
        Assert.Equal("1 model", page.Contents.Figures[3].Note);
    }
}

using Garage.App.Core.Operations;
using Garage.App.Core.Presentation;
using Garage.App.Core.Sources;
using Garage.App.Core.Tests.TestSupport;

namespace Garage.App.Core.Tests;

// Ported from macapp/Tests/GarageAppUnitTests/SourcesPresentationTests.swift: the idle rows, badges,
// symbols, tints, suggested names and summary. The ingest rows and the macOS permission cards are U3
// and have no Windows counterpart yet.
public sealed class SourcesTests
{
    private static RegisteredSource Source(
        string slug = "notes", string kind = "filesystem", string root = "~/Notes", string corpusClass = "document",
        bool enabled = true, SourceOrigin origin = SourceOrigin.Both, long documents = 0, long expected = 0) =>
        new(slug, kind, root, corpusClass, "authored", enabled, origin, documents, expected);

    private static SourceRowPresentation Row(RegisteredSource source, SourceAccess? access = null, SourceActivity activity = SourceActivity.Idle)
    {
        using var culture = new CultureScope("en-US");
        return SourceRowPresentation.Make(source, access, activity);
    }

    [Fact]
    public void A_fresh_source_is_not_indexed_yet()
    {
        SourceRowPresentation row = Row(Source());
        Assert.Equal("Not indexed yet", row.Status);
        Assert.Equal(SourceTone.Neutral, row.StatusTone);
        Assert.Equal(0, row.Progress);
        Assert.Null(row.Counts);
        Assert.Empty(row.Badges);
    }

    [Fact]
    public void A_scanned_but_unindexed_source_says_how_much_there_is()
    {
        SourceRowPresentation row = Row(Source(expected: 1_204));
        Assert.Equal("1,204 items found, none indexed yet", row.Status);
        Assert.Equal(0, row.Progress);
    }

    [Fact]
    public void A_partly_indexed_source_counts_what_is_left()
    {
        SourceRowPresentation row = Row(Source(documents: 1_180, expected: 1_204));
        Assert.Equal("24 items to go", row.Status);
        Assert.Equal(SourceTone.Active, row.StatusTone);
        Assert.Equal("1,180 of 1,204 documents", row.Counts);
        Assert.Equal(0.98, Math.Round(row.Progress!.Value, 3));
    }

    [Fact]
    public void A_fully_indexed_source_is_up_to_date_with_a_full_bar()
    {
        SourceRowPresentation row = Row(Source(documents: 1_204, expected: 1_204));
        Assert.Equal("Up to date", row.Status);
        Assert.Equal(SourceTone.Good, row.StatusTone);
        Assert.Equal(1, row.Progress);
        Assert.Equal("1,204 of 1,204 documents", row.Counts);
    }

    [Fact]
    public void More_documents_than_the_scan_expected_still_reads_as_up_to_date() =>
        Assert.Equal("Up to date", Row(Source(documents: 40, expected: 30)).Status);

    [Fact]
    public void An_unscanned_source_with_documents_shows_the_count_alone()
    {
        SourceRowPresentation row = Row(Source(documents: 1));
        Assert.Equal("Up to date", row.Status);
        Assert.Equal("1 document", row.Counts);
        Assert.Equal(1, row.Progress);
    }

    [Fact]
    public void Setup_badges_name_what_is_unusual_about_a_source()
    {
        SourceRowPresentation row = Row(Source(enabled: false, origin: SourceOrigin.Config));
        Assert.Equal(["DISABLED", "NOT SYNCED"], row.Badges.Select(b => b.Text));
        Assert.Equal("Disabled: skipped by every scan and ingest", row.Status);
    }

    [Fact]
    public void A_source_only_the_database_knows_gets_no_badge() =>
        Assert.Empty(Row(Source(origin: SourceOrigin.Database)).Badges);

    [Fact]
    public void A_missing_folder_is_unreadable()
    {
        SourceRowPresentation row = Row(Source(), new SourceAccess(false, false, "Path does not exist"));
        Assert.Equal(["UNREADABLE"], row.Badges.Select(b => b.Text));
        Assert.Equal("Can't be read: Path does not exist", row.Status);
        Assert.Equal(SourceTone.Bad, row.StatusTone);
    }

    [Fact]
    public void A_readable_folder_gets_no_access_badge() =>
        Assert.Empty(Row(Source(), new SourceAccess(true, true, "")).Badges);

    [Fact]
    public void Scanning_and_removing_rows()
    {
        SourceRowPresentation scanning = Row(Source(), activity: SourceActivity.Scanning);
        Assert.Equal("Counting items…", scanning.Status);
        Assert.True(scanning.IsIndeterminate);

        using var culture = new CultureScope("en-US");
        Assert.Equal("Counting items… 1,500 so far", SourceRowPresentation.Make(Source(), null, SourceActivity.Scanning, 1_500).Status);

        SourceRowPresentation removing = Row(Source(), activity: SourceActivity.Removing);
        Assert.Equal("Removing…", removing.Status);
        Assert.Equal(SourceTone.Bad, removing.StatusTone);
    }

    [Theory]
    [InlineData("maildir", "~/Library/Mail", "document", SourceSymbol.Mail)]
    [InlineData("git", "~/Developer/garage", "document", SourceSymbol.Code)]
    [InlineData("sqlite", "~/data/app.db", "document", SourceSymbol.Database)]
    [InlineData("filesystem", "~/Documents", "document", SourceSymbol.Documents)]
    [InlineData("filesystem", @"C:\Users\me\Documents", "document", SourceSymbol.Documents)]
    [InlineData("filesystem", "~/Downloads", "document", SourceSymbol.Downloads)]
    [InlineData("filesystem", "~/Dropbox", "document", SourceSymbol.Cloud)]
    [InlineData("filesystem", @"C:\Users\me\OneDrive - Contoso", "document", SourceSymbol.Cloud)]
    [InlineData("filesystem", @"G:\My Drive", "document", SourceSymbol.Cloud)]
    [InlineData("filesystem", "~/Library/Mobile Documents/com~apple~CloudDocs", "document", SourceSymbol.Cloud)]
    [InlineData("filesystem", "~/src", "code", SourceSymbol.Code)]
    [InlineData("filesystem", "~/Notes", "document", SourceSymbol.Folder)]
    public void Symbols_follow_the_kind_then_the_folder(string kind, string root, string corpusClass, SourceSymbol expected) =>
        Assert.Equal(expected, SourceRowPresentation.SymbolFor(Source(kind: kind, root: root, corpusClass: corpusClass)));

    [Fact]
    public void Tint_follows_the_corpus_class()
    {
        Assert.Equal(Tint.Blue, SourceRowPresentation.TintFor("document"));
        Assert.Equal(Tint.Purple, SourceRowPresentation.TintFor("code"));
        Assert.Equal(Tint.Green, SourceRowPresentation.TintFor("communication"));
    }

    [Theory]
    [InlineData("~/Notes", "filesystem", "notes")]
    [InlineData("/Users/rick/My Notes (2024)/", "filesystem", "my-notes-2024")]
    [InlineData(@"C:\Users\me\My Notes (2024)\", "filesystem", "my-notes-2024")]
    [InlineData("~/Developer/garage-rag", "git", "garage-rag")]
    [InlineData("~/Library/Mobile Documents/com~apple~CloudDocs", "filesystem", "icloud-drive")]
    [InlineData("~", "filesystem", "home")]
    [InlineData(@"D:\", "filesystem", "drive-d")]
    [InlineData("Résumés", "filesystem", "resumes")]
    [InlineData("   ", "filesystem", "")]
    [InlineData("/tmp/fixtures/chat.db", "sqlite", "chat")]
    [InlineData("https://example.com/feed.xml", "feed", "example-com")]
    public void The_suggested_name_comes_from_the_folder_and_the_kind(string root, string kind, string expected) =>
        Assert.Equal(expected, SourceSlugSuggestion.Suggest(root, kind, new HashSet<string>()));

    [Fact]
    public void A_taken_name_gets_a_number()
    {
        Assert.Equal("notes-2", SourceSlugSuggestion.Suggest("~/Notes", "filesystem", new HashSet<string> { "notes" }));
        Assert.Equal("notes-3", SourceSlugSuggestion.Suggest("~/Notes", "filesystem", new HashSet<string> { "notes", "notes-2" }));
    }

    [Fact]
    public void The_summary_line_counts_documents_and_sources()
    {
        using var culture = new CultureScope("en-US");
        Assert.Equal("No sources yet", SourcesSummary.Line(0, 0));
        Assert.Equal("1 document in 1 source", SourcesSummary.Line(1, 1));
        Assert.Equal("1,234 documents in 3 sources", SourcesSummary.Line(3, 1_234));
    }

    [Fact]
    public async Task The_page_marks_config_only_and_unreadable_sources()
    {
        var client = new FakeGarageClient
        {
            OnListSources = _ => new ListSourcesResponse
            {
                Sources =
                {
                    new SourceInfo { Slug = "gdrive", Kind = "filesystem", Root = @"G:\My Drive", CorpusClass = "document", Enabled = true, DocumentCount = 242, ExpectedElements = 25_427 },
                    new SourceInfo { Slug = "gone", Kind = "filesystem", Root = @"X:\nowhere", CorpusClass = "document", Enabled = true },
                },
            },
            OnSyncSources = r => new SyncSourcesResponse { Created = { "declared" }, Undeclared = { new UndeclaredSource { Slug = "gone" } } },
        };
        var page = new SourcesViewModel(client, new OperationRunner(), checkAccess: root => root.StartsWith('X') ? new SourceAccess(false, false, "Path does not exist") : new SourceAccess(true, true, ""));
        using var culture = new CultureScope("en-US");

        await page.LoadAsync(TestContext.Current.CancellationToken);

        Assert.True(client.Requests.OfType<SyncSourcesRequest>().Single().DryRun, "loading never applies a sync");
        Assert.Equal(["gdrive", "gone", "declared"], page.Rows.Select(r => r.Title));
        Assert.Equal("25,185 items to go", page.Rows[0].Status);
        Assert.Equal(SourceSymbol.Cloud, page.Rows[0].Symbol);
        Assert.Equal(["UNREADABLE"], page.Rows[1].Badges.Select(b => b.Text));
        Assert.Equal(["NOT SYNCED"], page.Rows[2].Badges.Select(b => b.Text));
        Assert.Equal("242 documents in 2 sources", page.Summary);
        Assert.Contains("gdrive", page.TakenSlugs);
    }

    [Fact]
    public async Task Add_remove_and_sync_run_on_the_operations_runner_and_reload()
    {
        var client = new FakeGarageClient { OnRemoveSource = r => new RemoveSourceResponse { Slug = r.Slug, DeletedDocuments = 53 } };
        var runner = new OperationRunner("garage");
        var page = new SourcesViewModel(client, runner, checkAccess: _ => new SourceAccess(true, true, ""));
        using var culture = new CultureScope("en-US");

        OperationResult added = await page.AddAsync(new NewSource(" notes ", @" C:\Notes ", CorpusClass: "document", TrustTier: "reference"));
        AddSourceRequest sent = client.Requests.OfType<AddSourceRequest>().Single();
        Assert.Equal(("notes", @"C:\Notes", "filesystem", "document", "reference"), (sent.Slug, sent.Root, sent.Kind, sent.CorpusClass, sent.Trust));
        Assert.Equal(@"Added notes → C:\Notes", added.Output);

        OperationResult removed = await page.RemoveAsync("gdrive");
        Assert.Equal("Removed gdrive and 53 documents", removed.Output);

        await page.SyncAsync();
        Assert.Contains(client.Requests.OfType<SyncSourcesRequest>(), r => !r.DryRun);
        Assert.Equal(3, client.Requests.OfType<ListSourcesRequest>().Count());
        Assert.Contains("Added notes", runner.Logs.Select(l => l.Text).First(), StringComparison.Ordinal);
    }

    [Fact]
    public async Task Scan_reports_each_source_and_announces_the_total()
    {
        var notifier = new RecordingNotifier();
        var client = new FakeGarageClient
        {
            OnListSources = _ => new ListSourcesResponse { Sources = { new SourceInfo { Slug = "notes", Kind = "filesystem", Root = "~", Enabled = true } } },
            OnScan = _ =>
            [
                new ScanStatus { Phase = "progress", Source = "notes", SourceItems = 10 },
                new ScanStatus { Phase = "source", Source = "notes", Result = new SourceScanStatus { Source = "notes", ItemCount = 12, ItemType = "files", DurationSeconds = 0.4 } },
                new ScanStatus { Phase = "finished", TotalItems = 12, Summary = new ScanResponse { Message = "Found 12 items in 1 source" } },
            ],
        };
        var runner = new OperationRunner("garage");
        var page = new SourcesViewModel(client, runner, notifier, _ => new SourceAccess(true, true, ""));
        await page.LoadAsync(TestContext.Current.CancellationToken);

        OperationResult scanned = await page.ScanAsync();

        Assert.Equal("*", client.Requests.OfType<ScanRequest>().Single().Source);
        Assert.Equal("Found 12 items in 1 source", scanned.Output);
        Assert.Equal(("Scan finished", "Found 12 items in 1 source"), notifier.Last);
        Assert.Contains(page.Library.Scanner.Logs, l => l.Text.StartsWith("notes: 12 files", StringComparison.Ordinal));
        Assert.Equal(SourceActivity.Idle, SourceActivity.Idle);
        Assert.DoesNotContain(page.Rows, r => r.Status.StartsWith("Counting", StringComparison.Ordinal));
    }

    [Fact]
    public void Local_access_checks_this_pc()
    {
        string folder = Path.Combine(Path.GetTempPath(), "garage-access-" + Guid.NewGuid().ToString("N"));
        Assert.False(LocalAccess.Check(folder).Exists);
        Directory.CreateDirectory(folder);
        try
        {
            Assert.True(LocalAccess.Check(folder).IsAccessible);
        }
        finally
        {
            Directory.Delete(folder);
        }
        Assert.Equal(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), LocalAccess.Expand("~"));
        Assert.Equal(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Notes"), LocalAccess.Expand("~/Notes"));
    }

    internal sealed class RecordingNotifier : State.INotifier
    {
        public (string Title, string Message)? Last { get; private set; }

        public void Notify(string title, string message, bool isError = false) => Last = (title, message);
    }
}

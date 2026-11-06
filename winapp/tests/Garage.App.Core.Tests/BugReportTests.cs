using Garage.App.Core.Diagnostics;
using Garage.App.Core.Logging;
using Garage.App.Core.Models;
using Garage.App.Core.Navigation;
using Garage.App.Core.Operations;
using Garage.App.Core.Settings;
using Garage.App.Core.Sources;
using Garage.App.Core.State;
using Garage.App.Core.Store;

namespace Garage.App.Core.Tests;

// Ported from macapp/Tests/GarageAppUnitTests/BugReportTests.swift with Windows home folders
// (C:\Users\testuser, in each spelling a log carries it), and TipJarTests.swift; plus the Settings
// page's own options and the jump list's command lines.
public sealed class BugReportTests
{
    private readonly BugReportRedactor _redactor = new(@"C:\Users\testuser", "testuser");

    private static LogLine Line(string text, LogChannel channel = LogChannel.Stdout) => new(channel, text, "app", DateTimeOffset.Now);

    // ---- Redaction

    [Fact]
    public void Redacts_the_home_folder_to_a_tilde()
    {
        Assert.Equal(@"failed to open ~\Documents\taxes.pdf", _redactor.Redact(@"failed to open C:\Users\testuser\Documents\taxes.pdf"));
        Assert.Equal("failed to open ~/Documents/taxes.pdf", _redactor.Redact("failed to open C:/Users/testuser/Documents/taxes.pdf"));
        Assert.Equal(@"{""root"": ""~\\Notes""}", _redactor.Redact(@"{""root"": ""C:\\Users\\testuser\\Notes""}"));
        Assert.Equal(@"~\Notes", _redactor.Redact(@"c:\users\TESTUSER\Notes"));
    }

    [Fact]
    public void The_home_folder_match_is_bounded() =>
        // Another account whose name merely starts with ours is not rewritten into ours.
        Assert.Equal(@"C:\Users\<user>\notes.md", _redactor.Redact(@"C:\Users\testuser2\notes.md"));

    [Fact]
    public void Redacts_other_accounts_home_folders()
    {
        Assert.Equal(@"copied from C:\Users\<user>\Desktop", _redactor.Redact(@"copied from C:\Users\alice\Desktop"));
        Assert.Equal(@"D:\Users\<user>\x", _redactor.Redact(@"D:\Users\bob.smith\x"));
        Assert.Equal("copied from /Users/<user>/Desktop", _redactor.Redact("copied from /Users/alice/Desktop"));
    }

    [Fact]
    public void Redacts_email_addresses() =>
        Assert.Equal("author <email redacted> committed", _redactor.Redact("author rick.mark@example.com committed"));

    [Fact]
    public void Redacts_connection_string_passwords()
    {
        Assert.Equal("postgresql://garage:<redacted>@127.0.0.1:14824/garage-rag", _redactor.Redact("postgresql://garage:hunter2@127.0.0.1:14824/garage-rag"));
        Assert.Equal("postgresql+psycopg://garage:<redacted>@localhost:14824/garage-rag", _redactor.Redact("postgresql+psycopg://garage:hunter2@localhost:14824/garage-rag"));
        Assert.Equal(@"{""database_url"":""postgresql+psycopg:\/\/garage:<redacted>@localhost:14824\/garage-rag""}",
            _redactor.Redact(@"{""database_url"":""postgresql+psycopg:\/\/garage:hunter2@localhost:14824\/garage-rag""}"));
    }

    [Fact]
    public void Redacts_key_value_secrets()
    {
        Assert.Equal("api_key=<redacted>", _redactor.Redact("api_key: sk-abc123"));
        Assert.Equal("token=<redacted>", _redactor.Redact("token=\"ghp_deadbeef\""));
        Assert.Equal("PGPASSWORD=<redacted> psql", _redactor.Redact("PGPASSWORD=hunter2 psql"));
        Assert.Equal("GARAGE_GRPC_TOKEN=<redacted>", _redactor.Redact("GARAGE_GRPC_TOKEN=abc123"));
        Assert.Equal("{\"password=<redacted>, \"n\": 1}", _redactor.Redact("{\"password\": \"hunter2\", \"n\": 1}"));
        // Counts and limits named after tokens are not secrets.
        Assert.Equal("max_tokens=512", _redactor.Redact("max_tokens=512"));
    }

    [Fact]
    public void Redacts_bearer_and_basic_credentials()
    {
        Assert.DoesNotContain("sk-abcdef123456", _redactor.Redact("Authorization: Bearer sk-abcdef123456"), StringComparison.Ordinal);
        Assert.DoesNotContain("Z2FyYWdlOmh1bnRlcjI=", _redactor.Redact("Authorization: Basic Z2FyYWdlOmh1bnRlcjI="), StringComparison.Ordinal);
        Assert.Equal("basic search mode", _redactor.Redact("basic search mode"));
    }

    [Fact]
    public void Redacts_the_bare_user_name() => Assert.Equal("ingest failed for <user>", _redactor.Redact("ingest failed for testuser"));

    [Fact]
    public void A_short_user_name_is_not_redacted() =>
        Assert.Equal("absolutely fine", new BugReportRedactor(@"C:\Users\ab", "ab").Redact("absolutely fine"));

    [Fact]
    public void Redaction_leaves_ordinary_text_alone()
    {
        const string Text = "Ingest stopped after 1,204 of 8,000 documents (bge-m3, 1024 dims).";
        Assert.Equal(Text, _redactor.Redact(Text));
    }

    // ---- Draft

    [Fact]
    public void A_draft_needs_a_title_and_a_description()
    {
        Assert.False(new BugReportDraft().IsSubmittable);
        Assert.False(new BugReportDraft { Title = "Ingest stalls" }.IsSubmittable);
        Assert.True(new BugReportDraft { Title = "Ingest stalls", WhatHappened = "It stops at 40%." }.IsSubmittable);
        Assert.False(new BugReportDraft { Title = "   ", WhatHappened = "\n\t " }.IsSubmittable);
    }

    [Fact]
    public void The_effective_title_falls_back_to_the_descriptions_first_line()
    {
        Assert.Equal("Search returns nothing", new BugReportDraft { WhatHappened = "Search returns nothing\nafter a backfill" }.EffectiveTitle);
        Assert.Equal("Bug report", new BugReportDraft().EffectiveTitle);
    }

    // ---- Composition

    private static BugReportDraft Draft(bool diagnostics = false, bool logs = false) =>
        new() { Title = "Ingest stalls", WhatHappened = "Ingest stops at 40% and never finishes.", IncludeDiagnostics = diagnostics, IncludeLogs = logs };

    private string Compose(BugReportDraft draft, IReadOnlyList<DiagnosticSection>? sections = null, IReadOnlyList<LogLine>? lines = null) =>
        BugReportComposer.Compose(draft, sections ?? [], lines ?? [], _redactor);

    [Fact]
    public void Compose_omits_empty_optional_sections()
    {
        string body = Compose(Draft());
        Assert.Contains("## What happened", body, StringComparison.Ordinal);
        Assert.DoesNotContain("## Steps to reproduce", body, StringComparison.Ordinal);
        Assert.DoesNotContain("## Expected behavior", body, StringComparison.Ordinal);
        Assert.DoesNotContain("## Diagnostics", body, StringComparison.Ordinal);
        Assert.EndsWith(BugReportComposer.Footer, body, StringComparison.Ordinal);
    }

    [Fact]
    public void Compose_redacts_the_persons_own_prose()
    {
        string body = Compose(Draft() with { WhatHappened = @"Broke while indexing C:\Users\testuser\Notes" });
        Assert.Contains(@"~\Notes", body, StringComparison.Ordinal);
        Assert.DoesNotContain(@"C:\Users\testuser", body, StringComparison.Ordinal);
    }

    [Fact]
    public void Diagnostics_render_as_tables_only_when_attached()
    {
        DiagnosticSection[] sections = [new("Application", [new("Garage", "Version 0.9")])];
        string body = Compose(Draft(diagnostics: true), sections);
        Assert.Contains("## Diagnostics", body, StringComparison.Ordinal);
        Assert.Contains("### Application", body, StringComparison.Ordinal);
        Assert.Contains("| Garage | Version 0.9 |", body, StringComparison.Ordinal);
        Assert.DoesNotContain("## Diagnostics", Compose(Draft(), sections), StringComparison.Ordinal);
    }

    [Fact]
    public void Diagnostic_values_are_redacted_and_kept_in_their_cell()
    {
        DiagnosticSection[] sections = [new("Database", [new("URL", "postgresql://garage:hunter2@127.0.0.1:14824/db"), new("Note", "a | b\nsecond line")])];
        string body = Compose(Draft(diagnostics: true), sections);
        Assert.DoesNotContain("hunter2", body, StringComparison.Ordinal);
        Assert.Contains(@"| Note | a \| b second line |", body, StringComparison.Ordinal);
    }

    [Fact]
    public void Logs_are_attached_in_a_collapsed_block_only_when_asked()
    {
        LogLine[] lines = [Line(@"FATAL: could not open C:\Users\testuser\db", LogChannel.Stderr)];
        string body = Compose(Draft(logs: true), lines: lines);
        Assert.Contains("<details>", body, StringComparison.Ordinal);
        Assert.Contains("```text", body, StringComparison.Ordinal);
        Assert.Contains(@"~\db", body, StringComparison.Ordinal);
        Assert.DoesNotContain(@"C:\Users\testuser", body, StringComparison.Ordinal);
        Assert.DoesNotContain("<details>", Compose(Draft(), lines: lines), StringComparison.Ordinal);
    }

    [Fact]
    public void The_title_is_redacted_and_heads_the_document()
    {
        BugReportDraft draft = Draft() with { Title = @"Fails for rick@example.com under C:\Users\testuser\Notes" };
        string document = BugReportComposer.Document(draft, [], [], _redactor);
        Assert.StartsWith("# Fails for <email redacted> under ~\\Notes\n\n", document, StringComparison.Ordinal);
        Assert.EndsWith(Compose(draft), document, StringComparison.Ordinal);
    }

    // ---- Log digest

    [Fact]
    public void The_log_digest_keeps_the_most_recent_lines()
    {
        LogLine[] lines = [.. Enumerable.Range(0, 10).Select(i => Line($"line {i}"))];
        Assert.Equal(["line 7", "line 8", "line 9"], BugReportLogDigest.Select(lines, 3).Select(l => l.Text));
        Assert.Single(BugReportLogDigest.Select([Line("only")], 10));
    }

    [Fact]
    public void The_log_digest_shows_the_level()
    {
        string formatted = BugReportLogDigest.Format([Line("ERROR: boom", LogChannel.Stderr)], _redactor);
        Assert.Contains("[ERROR]", formatted, StringComparison.Ordinal);
        Assert.Contains("boom", formatted, StringComparison.Ordinal);
    }

    // ---- GitHub hand-off

    [Fact]
    public void The_issue_url_carries_title_body_and_label()
    {
        string url = BugReportDestination.NewIssueUrl("Ingest stalls", "It stops.").AbsoluteUri;
        Assert.StartsWith("https://github.com/rickmark/garage-rag/issues/new?", url, StringComparison.Ordinal);
        Assert.Contains("title=Ingest%20stalls", url, StringComparison.Ordinal);
        Assert.Contains("body=It%20stops.", url, StringComparison.Ordinal);
        Assert.Contains("labels=bug", url, StringComparison.Ordinal);
    }

    [Fact]
    public void The_issue_url_encodes_plus_and_ampersand()
    {
        string url = BugReportDestination.NewIssueUrl("a+b", "x & y+z").AbsoluteUri;
        Assert.Contains("title=a%2Bb", url, StringComparison.Ordinal);
        Assert.Contains("body=x%20%26%20y%2Bz", url, StringComparison.Ordinal);
    }

    [Fact]
    public void Oversized_bodies_are_truncated_and_say_so()
    {
        Uri url = BugReportDestination.NewIssueUrl("Big", string.Concat(Enumerable.Repeat("log line with detail\n", 5000)));
        Assert.True(url.AbsoluteUri.Length <= BugReportDestination.MaxUrlLength);
        Assert.Contains("Report truncated", Uri.UnescapeDataString(url.AbsoluteUri), StringComparison.Ordinal);
        Assert.DoesNotContain("Report truncated", Uri.UnescapeDataString(BugReportDestination.NewIssueUrl("Small", "short").AbsoluteUri), StringComparison.Ordinal);
    }

    [Fact]
    public void The_title_is_clamped_to_githubs_limit()
    {
        string url = BugReportDestination.NewIssueUrl(new string('t', 500), "b").AbsoluteUri;
        string title = url.Split('?')[1].Split('&').Single(p => p.StartsWith("title=", StringComparison.Ordinal))["title=".Length..];
        Assert.Equal(BugReportDestination.MaxTitleLength, title.Length);
    }

    // ---- Diagnostics

    [Fact]
    public void Diagnostics_describe_the_pc_without_corpus_content()
    {
        RegisteredSource[] sources =
        [
            new("private-notes", "filesystem", @"C:\Users\testuser\Notes", "document", "authored", true, SourceOrigin.Both, 3, 3),
            new("work-repo", "git", @"C:\Users\testuser\src", "code", "authored", true, SourceOrigin.Both, 1, 1),
        ];
        IReadOnlyList<DiagnosticSection> sections = BugReportDiagnostics.Collect(
            new AppEnvironment("Version 0.9.0", "Microsoft Windows 10.0.26200", "x64", 32, "Unpackaged"),
            "Running · PostgreSQL 18.6 · port 14824",
            sources,
            new CorpusCounts(4, 40, 2, 1),
            [new ModelItem("bge-m3", ModelProvider.Ollama, "bge-m3", 1024, "vector", "cosine", true, 40, 40)],
            [("Garage Backend", "Running")]);

        Assert.Equal(["Application", "Database", "Corpus", "Models", "Services"], sections.Select(s => s.Title));
        Assert.Equal("Version 0.9.0", sections[0].Fields.Single(f => f.Label == "Garage").Value);
        DiagnosticSection corpus = sections.Single(s => s.Title == "Corpus");
        Assert.Equal("2", corpus.Fields.Single(f => f.Label == "Sources").Value);
        Assert.Equal("code: 1, document: 1", corpus.Fields.Single(f => f.Label == "Corpus classes").Value);
        Assert.Equal("ollama, 1024 dims, vector", sections.Single(s => s.Title == "Models").Fields.Single(f => f.Label == "bge-m3 (default)").Value);

        // Slugs and roots name the person's folders; counts do not.
        string rendered = string.Join('\n', sections.SelectMany(s => s.Fields).Select(f => $"{f.Label} {f.Value}"));
        Assert.DoesNotContain("private-notes", rendered, StringComparison.Ordinal);
        Assert.DoesNotContain(@"C:\Users\testuser", rendered, StringComparison.Ordinal);
    }

    [Fact]
    public void The_dialog_previews_what_will_be_copied()
    {
        var log = new LogBuffer("app");
        log.Append(@"opened C:\Users\testuser\x.md");
        var dialog = new BugReportViewModel(() => [new("Application", [new("Garage", "Version 0.9")])], [log], _redactor);
        Assert.False(dialog.IsSubmittable);
        dialog.Title = "Crash";
        dialog.WhatHappened = "It crashed.";
        Assert.True(dialog.IsSubmittable);
        Assert.StartsWith("# Crash\n\n## What happened\n\nIt crashed.", dialog.Document, StringComparison.Ordinal);
        Assert.Contains("| Garage | Version 0.9 |", dialog.Document, StringComparison.Ordinal);
        Assert.DoesNotContain("<details>", dialog.Document, StringComparison.Ordinal);
        dialog.IncludeLogs = true;
        Assert.Contains(@"opened ~\x.md", dialog.Document, StringComparison.Ordinal);
        Assert.Contains("title=Crash", dialog.IssueUrl.AbsoluteUri, StringComparison.Ordinal);
        Assert.Equal("Garage bug report 2026-09-30.md", BugReportViewModel.SuggestedFileName(new DateTimeOffset(2026, 9, 30, 12, 0, 0, TimeSpan.Zero)));
    }

    // ---- Settings: launch at sign-in, update channel

    [Fact]
    public void The_update_channel_is_remembered_and_explained()
    {
        var preferences = new MemoryPreferences();
        var options = new AppOptionsViewModel(preferences, new MemoryStartupRegistration(), AppDistribution.AppInstaller);
        Assert.Equal(UpdateChannel.Stable, options.Channel);
        Assert.True(options.CanChooseChannel);
        options.Channel = UpdateChannel.Beta;
        Assert.Equal("Beta", preferences.Read(AppOptionsViewModel.ChannelKey, ""));
        Assert.Equal(UpdateFeeds.Beta, options.Feed);
        Assert.Equal("Garage checks for betas and releases each time it starts.", options.UpdateExplanation);
        Assert.Equal(UpdateChannel.Beta, new AppOptionsViewModel(preferences, new MemoryStartupRegistration(), AppDistribution.AppInstaller).Channel);

        Assert.False(new AppOptionsViewModel(preferences, new MemoryStartupRegistration(), AppDistribution.Store).CanChooseChannel);
        Assert.StartsWith("The Microsoft Store keeps Garage up to date", UpdateFeeds.Explanation(AppDistribution.Store, UpdateChannel.Beta), StringComparison.Ordinal);
        Assert.Equal("This copy of Garage runs from a build folder and does not update itself.", UpdateFeeds.Explanation(AppDistribution.Unpackaged, UpdateChannel.Stable));
        Assert.Equal("Garage updates when a newer installer is run, by you or by your organization.", UpdateFeeds.Explanation(AppDistribution.WindowsInstaller, UpdateChannel.Beta));
        Assert.False(new AppOptionsViewModel(preferences, new MemoryStartupRegistration(), AppDistribution.WindowsInstaller).CanChooseChannel);
    }

    [Fact]
    public void Launch_at_sign_in_follows_the_registration()
    {
        var startup = new MemoryStartupRegistration();
        var options = new AppOptionsViewModel(new MemoryPreferences(), startup, AppDistribution.Unpackaged);
        Assert.False(options.LaunchAtStartup);
        options.LaunchAtStartup = true;
        Assert.True(startup.IsEnabled);

        var refused = new AppOptionsViewModel(new MemoryPreferences(), new MemoryStartupRegistration { IsAvailable = false }, AppDistribution.Unpackaged);
        Assert.False(refused.CanLaunchAtStartup);
        refused.LaunchAtStartup = true;
        Assert.False(refused.LaunchAtStartup);
        Assert.NotNull(refused.ErrorMessage);
    }

    // ---- Jump list and launch arguments

    [Fact]
    public void Launch_commands_round_trip()
    {
        foreach ((LaunchAction action, string _, string _) in LaunchCommand.JumpListTasks)
        {
            Assert.Equal(action, LaunchCommand.Parse([LaunchCommand.Arguments(action)]));
            Assert.Equal(action, LaunchCommand.Parse(LaunchCommand.Arguments(action).Split(' ')));
        }
        Assert.Equal([LaunchAction.Search, LaunchAction.Ask, LaunchAction.AddSource, LaunchAction.UpdateEverything], LaunchCommand.JumpListTasks.Select(t => t.Action));
        Assert.Equal(LaunchAction.Background, LaunchCommand.Parse(["--background"]));
        Assert.Equal(LaunchAction.Open, LaunchCommand.Parse([]));
        Assert.Equal(LaunchAction.Open, LaunchCommand.Parse(["--do", "nonsense"]));
        // A redirected activation carries the whole command line, the program path first.
        Assert.Equal(LaunchAction.Ask, LaunchCommand.Parse([@"""C:\Program Files\Garage\Garage.exe"" --do ask"]));
    }

    // ---- Tip jar (TipJarTests.swift)

    [Fact]
    public void Tips_are_ordered_smallest_first_and_strangers_dropped()
    {
        string[] shuffled = [TipProducts.Ultra, TipProducts.Large, "me.rickmark.garage_rag.other", TipProducts.Small, TipProducts.Max, TipProducts.Medium];
        Assert.Equal(TipProducts.All, TipProducts.Ordered(shuffled, id => id));
        Assert.Equal([TipProducts.Large], TipProducts.Ordered([TipProducts.Large], id => id));
    }

    [Fact]
    public void Offer_tokens_match_the_macs_product_identifiers()
    {
        foreach (string id in TipProducts.All)
        {
            Assert.Matches("^me\\.rickmark\\.garage_rag\\.tip\\.[a-z]+$", id);
        }
    }

    [Fact]
    public async Task The_tip_jar_loads_buys_and_thanks()
    {
        var store = new FakeStore([new("9P2", TipProducts.Medium, "$4.99"), new("9P1", TipProducts.Small, "$1.99")]);
        var jar = new TipJarViewModel(store);
        await jar.LoadAsync();
        Assert.Equal(TipJarPhase.Ready, jar.Phase);
        Assert.Equal([TipProducts.Small, TipProducts.Medium], jar.Products.Select(p => p.OfferToken));
        await jar.PurchaseAsync(jar.Products[0]);
        Assert.Equal(TipJarPhase.Thanked, jar.Phase);
        Assert.Equal("Thank you! Your tip keeps Garage going.", jar.Note);

        store.Outcome = (TipPurchaseOutcome.Failed, "no payment method");
        await jar.PurchaseAsync(jar.Products[0]);
        Assert.Equal("The tip didn't go through: no payment method", jar.Note);
        store.Outcome = (TipPurchaseOutcome.Cancelled, null);
        await jar.PurchaseAsync(jar.Products[0]);
        Assert.Equal(TipJarPhase.Ready, jar.Phase);
    }

    [Fact]
    public async Task No_tips_from_the_store_shows_no_tip_jar()
    {
        var jar = new TipJarViewModel(new FakeStore([]));
        await jar.LoadAsync();
        Assert.Equal(TipJarPhase.Unavailable, jar.Phase);
        Assert.False(jar.IsOffered);
    }

    private sealed class FakeStore(IReadOnlyList<TipProduct> products) : ITipStore
    {
        public (TipPurchaseOutcome, string?) Outcome { get; set; } = (TipPurchaseOutcome.Succeeded, null);

        public Task<IReadOnlyList<TipProduct>> LoadAsync() => Task.FromResult(products);

        public Task<(TipPurchaseOutcome Outcome, string? Message)> PurchaseAsync(TipProduct product) => Task.FromResult(Outcome);
    }
}

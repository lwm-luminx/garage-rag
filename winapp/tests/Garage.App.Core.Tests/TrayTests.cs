using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using Garage.App.Core.Database;
using Garage.App.Core.Library;
using Garage.App.Core.Mcp;
using Garage.App.Core.Presentation;
using Garage.App.Core.Tests.TestSupport;
using Garage.App.Core.Tray;

namespace Garage.App.Core.Tests;

// Ported from macapp/Tests/GarageAppUnitTests/MenuBarStatusTests.swift and MenuBarAnswerTests.swift
// (the menu bar is the notification area here: "door.garage.open" is TrayIconKind.Open), plus the
// MCP client and the flyout's search and ask.
public sealed class TrayTests
{
    private static readonly PostgresStatus Running = new(PostgresState.Running);
    private static readonly PostgresStatus Stopped = new(PostgresState.Stopped);
    private static readonly PostgresStatus Starting = new(PostgresState.Starting);

    private static TrayServer Serving(int clients) => new(TrayServerState.Running, clients);

    // ---- Icon

    [Fact]
    public void Idle_running_database_shows_an_open_door_at_rest()
    {
        var status = new TrayStatus(Running, Serving(1));
        Assert.Equal(TrayIconKind.Open, status.Icon);
        Assert.False(status.IsPulsing);
        Assert.Equal("Ready", status.Headline);
        Assert.False(status.IsBusy);
        Assert.False(status.NeedsAttention);
        Assert.Empty(status.Attentions);
    }

    [Fact]
    public void Stopped_database_shows_a_closed_door()
    {
        var status = new TrayStatus(Stopped);
        Assert.Equal(TrayIconKind.Closed, status.Icon);
        Assert.False(status.IsPulsing);
        Assert.Equal("Database stopped", status.Headline);
        Assert.False(status.CanSearch);
        Assert.False(status.CanAsk);
        Assert.False(status.CanIngest);
    }

    [Fact]
    public void Ask_needs_the_database_and_the_mcp_server()
    {
        Assert.True(new TrayStatus(Running, Serving(0)).CanAsk);
        Assert.False(new TrayStatus(Running, TrayServer.Stopped).CanAsk);
        Assert.False(new TrayStatus(Running, new(TrayServerState.Starting)).CanAsk);
        Assert.False(new TrayStatus(Running, new(TrayServerState.Failed, Message: "port in use")).CanAsk);
        Assert.False(new TrayStatus(Starting, Serving(1)).CanAsk);
        // Search only needs the database.
        Assert.True(new TrayStatus(Running, TrayServer.Stopped).CanSearch);
    }

    [Fact]
    public void Starting_database_pulses_behind_a_closed_door()
    {
        var status = new TrayStatus(Starting);
        Assert.Equal(TrayIconKind.Closed, status.Icon);
        Assert.True(status.IsPulsing);
        Assert.True(status.IsDatabaseTransitioning);
    }

    [Fact]
    public void Work_pulses_the_open_door()
    {
        TrayActivity[] activities =
        [
            new TrayActivity.Scanning(null),
            new TrayActivity.Ingesting(new("notes")),
            new TrayActivity.Embedding(),
            new TrayActivity.Distilling(),
        ];
        foreach (TrayActivity activity in activities)
        {
            var status = new TrayStatus(Running, Activity: activity);
            Assert.Equal(TrayIconKind.Open, status.Icon);
            Assert.True(status.IsPulsing, activity.ToString());
            Assert.True(status.IsBusy, activity.ToString());
        }
    }

    [Fact]
    public void Blocking_problems_swap_the_icon_for_a_warning_and_stop_the_motion()
    {
        foreach (PostgresStatus database in new[] { new PostgresStatus(PostgresState.Failed, "port in use"), new PostgresStatus(PostgresState.NeedsMigration) })
        {
            var status = new TrayStatus(database, Activity: new TrayActivity.Embedding());
            Assert.True(status.NeedsAttention);
            Assert.Equal(TrayIconKind.Warning, status.Icon);
            Assert.False(status.IsPulsing);
        }
    }

    [Fact]
    public void Mcp_failure_is_a_warning_only_while_the_database_runs()
    {
        var running = new TrayStatus(Running, new(TrayServerState.Failed, Message: "port 8787 in use"));
        Assert.True(running.NeedsAttention);
        Assert.Equal([new TrayAttention(TrayAttentionKind.McpFailed, "port 8787 in use")], running.Attentions);

        // Stopping the database fails MCP as a consequence; that is not a second problem.
        var stopped = new TrayStatus(Stopped, new(TrayServerState.Failed, Message: "Database is not online"));
        Assert.False(stopped.NeedsAttention);
        Assert.Empty(stopped.Attentions);
        Assert.Equal(TrayIconKind.Closed, stopped.Icon);
    }

    [Fact]
    public void A_failed_ingest_is_listed_but_does_not_shout_from_the_tray()
    {
        var status = new TrayStatus(Running, LastIngestError: "3 files failed");
        Assert.Equal([new TrayAttention(TrayAttentionKind.IngestFailed, "3 files failed")], status.Attentions);
        Assert.False(status.NeedsAttention);
        Assert.Equal(TrayIconKind.Open, status.Icon);
    }

    [Fact]
    public void A_stale_ingest_error_is_hidden_while_a_new_run_is_underway() =>
        Assert.Empty(new TrayStatus(Running, Activity: new TrayActivity.Ingesting(new("notes")), LastIngestError: "old").Attentions);

    [Fact]
    public void Attentions_are_ordered_worst_first()
    {
        var status = new TrayStatus(new(PostgresState.NeedsMigration), new(TrayServerState.Failed, Message: "x"), LastIngestError: "y");
        Assert.Equal([new TrayAttention(TrayAttentionKind.DatabaseNeedsMigration), new TrayAttention(TrayAttentionKind.IngestFailed, "y")], status.Attentions);
    }

    // ---- Headline and progress

    [Fact]
    public void Ingest_headline_names_the_source_and_the_percentage_comes_from_the_counts()
    {
        var status = new TrayStatus(Running, Activity: new TrayActivity.Ingesting(new("notes", 424, 1000, "documents", ReportedFraction: 0.1)));
        Assert.Equal("Reading notes", status.Headline);
        Assert.Equal(0.424, status.IngestFraction);
        Assert.Equal("424 of 1,000 documents", status.ActivityDetail);
        Assert.Equal(LibraryStage.Read, status.Stage);
    }

    [Fact]
    public void Ingest_falls_back_to_the_reported_fraction_until_the_scan_has_sized_the_run()
    {
        var status = new TrayStatus(Running, Activity: new TrayActivity.Ingesting(new("", 12, 0, ReportedFraction: 0.3)));
        Assert.Equal("Reading", status.Headline);
        Assert.Equal(0.3, status.IngestFraction);
        Assert.Equal("12 documents", status.ActivityDetail);
    }

    [Fact]
    public void Ingest_without_any_progress_yet_has_no_fraction()
    {
        var status = new TrayStatus(Running, Activity: new TrayActivity.Ingesting(new("notes")));
        Assert.Null(status.IngestFraction);
        Assert.Null(status.CurrentItem);
    }

    [Fact]
    public void Current_item_is_only_reported_when_not_empty()
    {
        Assert.Null(new TrayStatus(Running, Activity: new TrayActivity.Ingesting(new("n", CurrentItem: ""))).CurrentItem);
        Assert.Equal(@"C:\tmp\a.md", new TrayStatus(Running, Activity: new TrayActivity.Ingesting(new("n", CurrentItem: @"C:\tmp\a.md"))).CurrentItem);
    }

    [Fact]
    public void Scan_reports_what_it_has_found_so_far()
    {
        Assert.Null(new TrayStatus(Running, Activity: new TrayActivity.Scanning(null)).ActivityDetail);
        var status = new TrayStatus(Running, Activity: new TrayActivity.Scanning(1234));
        Assert.Equal("Scanning sources", status.Headline);
        Assert.Equal("1,234 items found so far", status.ActivityDetail);
        Assert.Equal(LibraryStage.Scan, status.Stage);
    }

    [Fact]
    public void Database_state_wins_over_activity_in_the_headline() =>
        Assert.Equal("Stopping…", new TrayStatus(new(PostgresState.Stopping), Activity: new TrayActivity.Ingesting(new("notes"))).Headline);

    [Fact]
    public void Stage_trail_always_shows_all_four()
    {
        Assert.Equal([LibraryStage.Scan, LibraryStage.Read, LibraryStage.Index, LibraryStage.Glean], new TrayStatus(Running, Activity: new TrayActivity.Embedding()).StageTrail);
        Assert.Null(new TrayStatus(Running).Stage);
    }

    // ---- Rows

    [Fact]
    public void Corpus_line_reads_naturally()
    {
        Assert.Equal("No sources yet", new TrayStatus(Running).CorpusLine);
        Assert.Equal("No documents yet", new TrayStatus(Running, SourceCount: 2).CorpusLine);
        Assert.Equal("1 document in 1 source", new TrayStatus(Running, SourceCount: 1, DocumentCount: 1).CorpusLine);
        Assert.Equal("1,234 documents in 3 sources", new TrayStatus(Running, SourceCount: 3, DocumentCount: 1234).CorpusLine);
    }

    [Fact]
    public void Ingest_now_needs_a_running_database_an_idle_pipeline_and_a_source()
    {
        Assert.True(new TrayStatus(Running, SourceCount: 1).CanIngest);
        Assert.False(new TrayStatus(Running, SourceCount: 0).CanIngest);
        Assert.False(new TrayStatus(Running, Activity: new TrayActivity.Embedding(), SourceCount: 1).CanIngest);
        Assert.False(new TrayStatus(Stopped, SourceCount: 1).CanIngest);
    }

    [Fact]
    public void Mcp_detail_counts_registered_clients()
    {
        Assert.Equal("Serving · no assistants connected", new TrayStatus(Running, Serving(0)).McpDetail);
        Assert.Equal("Serving · 1 assistant connected", new TrayStatus(Running, Serving(1)).McpDetail);
        Assert.Equal("Serving · 2 assistants connected", new TrayStatus(Running, Serving(2)).McpDetail);
        Assert.Equal("Not running", new TrayStatus(Running, TrayServer.Stopped).McpDetail);
        Assert.Equal("Waits for the database", new TrayStatus(Stopped, TrayServer.Stopped).McpDetail);
        Assert.Equal("boom", new TrayStatus(Running, new(TrayServerState.Failed, Message: "boom")).McpDetail);
    }

    [Fact]
    public void Database_detail_carries_the_failure_message()
    {
        Assert.Equal("port in use", new TrayStatus(new(PostgresState.Failed, "port in use")).DatabaseDetail);
        Assert.Equal("Schema update needed", new TrayStatus(new(PostgresState.NeedsMigration)).DatabaseDetail);
    }

    // ---- Formatting

    [Fact]
    public void Percent_clamps()
    {
        Assert.Equal("0%", TrayStatus.Percent(-0.2));
        Assert.Equal("42%", TrayStatus.Percent(0.424));
        Assert.Equal("100%", TrayStatus.Percent(1.7));
    }

    [Fact]
    public void Progress_line_falls_back_to_documents()
    {
        Assert.Equal("3 of 10 messages", TrayStatus.ProgressLine(3, 10, "messages"));
        Assert.Equal("3 documents", TrayStatus.ProgressLine(3, 0, ""));
    }

    [Fact]
    public void Abbreviated_path_replaces_the_home_folder()
    {
        Assert.Equal(@"~\Notes\a.md", TrayStatus.AbbreviatedPath(@"C:\Users\rick\Notes\a.md", @"C:\Users\rick"));
        Assert.Equal(@"C:\Users\rickmark\a.md", TrayStatus.AbbreviatedPath(@"C:\Users\rickmark\a.md", @"C:\Users\rick"));
        Assert.Equal(@"D:\tmp\a.md", TrayStatus.AbbreviatedPath(@"D:\tmp\a.md", @"C:\Users\rick"));
    }

    // ---- All systems go

    [Fact]
    public void Database_and_serving_mcp_fold_into_all_systems_go()
    {
        var status = new TrayStatus(Running, Serving(2));
        Assert.True(status.AllSystemsGo);
        Assert.Equal("Database and MCP running · 2 assistants connected", status.AllSystemsGoDetail);
        Assert.Equal("Database and MCP running · 1 assistant connected", new TrayStatus(Running, Serving(1)).AllSystemsGoDetail);
        Assert.Equal("Database and MCP running · no assistants connected", new TrayStatus(Running, Serving(0)).AllSystemsGoDetail);
    }

    [Fact]
    public void Any_service_not_fine_spells_the_rows_out_again()
    {
        Assert.False(new TrayStatus(Running, TrayServer.Stopped).AllSystemsGo);
        Assert.False(new TrayStatus(Running, new(TrayServerState.Failed, Message: "port in use")).AllSystemsGo);
        Assert.False(new TrayStatus(Running, new(TrayServerState.Starting)).AllSystemsGo);
        Assert.False(new TrayStatus(Stopped, Serving(1)).AllSystemsGo);
        Assert.False(new TrayStatus(new(PostgresState.NeedsMigration), Serving(1)).AllSystemsGo);
    }

    [Fact]
    public void Stdio_with_http_off_is_all_systems_go()
    {
        var status = new TrayStatus(Running, new(TrayServerState.Stdio, 2));
        Assert.True(status.AllSystemsGo);
        Assert.Equal("Database running · 2 assistants connected", status.AllSystemsGoDetail);
        Assert.Equal("Database running · no assistants connected", new TrayStatus(Running, new(TrayServerState.Stdio, 0)).AllSystemsGoDetail);
        Assert.Equal("All systems go", status.Summary.Title);
        Assert.Equal("Over stdio · 2 assistants connected", status.McpDetail);
        Assert.False(new TrayStatus(Stopped, new(TrayServerState.Stdio, 1)).AllSystemsGo);
    }

    [Fact]
    public void Idle_on_a_running_database_has_no_second_status_dot()
    {
        Assert.False(new TrayStatus(Running, Serving(1)).ShowsActivityDot);
        Assert.True(new TrayStatus(Running, Serving(1), new TrayActivity.Embedding()).ShowsActivityDot);
        Assert.True(new TrayStatus(Stopped).ShowsActivityDot);
    }

    [Fact]
    public void Summary_is_all_systems_go_when_everything_runs()
    {
        TraySummary summary = new TrayStatus(Running, Serving(2)).Summary;
        Assert.Equal("All systems go", summary.Title);
        Assert.Equal("Database and MCP running · 2 assistants connected", summary.Detail);
        Assert.Equal(Tint.Green, summary.Tint);
    }

    [Fact]
    public void Summary_names_the_worst_problem_first()
    {
        // A database failure hides the MCP server's knock-on failure.
        TraySummary failed = new TrayStatus(new(PostgresState.Failed, "port 14824 already in use\nFATAL: ..."), new(TrayServerState.Failed, Message: "no database")).Summary;
        Assert.Equal("Database failed to start", failed.Title);
        Assert.Equal("port 14824 already in use", failed.Detail);
        Assert.Equal(Tint.Red, failed.Tint);

        Assert.Equal("Database needs a schema update", new TrayStatus(new(PostgresState.NeedsMigration)).Summary.Title);
        Assert.Equal("Database stopped", new TrayStatus(Stopped).Summary.Title);
        Assert.Equal("Open Status to fix it.", new TrayStatus(Running, new(TrayServerState.Failed, Message: "")).Summary.Detail);
        Assert.Equal("MCP server not running", new TrayStatus(Running, TrayServer.Stopped).Summary.Title);
    }

    // ---- Quick search

    [Fact]
    public void Quick_search_opens_plain_paths_and_file_urls_only()
    {
        Assert.Equal(@"C:\Users\me\notes.md", QuickSearch.FilePathForUri(@"C:\Users\me\notes.md"));
        Assert.Equal(@"\\nas\share\notes.md", QuickSearch.FilePathForUri(@"\\nas\share\notes.md"));
        Assert.Equal(@"C:\Users\me\notes.md", QuickSearch.FilePathForUri("file:///C:/Users/me/notes.md"));
        Assert.Null(QuickSearch.FilePathForUri("imessage://chat/123"));
        Assert.Null(QuickSearch.FilePathForUri("notes.md"));
    }

    [Fact]
    public async Task Typing_searches_the_first_five_hits()
    {
        var client = new FakeGarageClient
        {
            OnSearch = r => new SearchResponse { Hits = { Enumerable.Range(1, 8).Select(i => new SearchHit { Rank = i, Title = $"hit {i}", Uri = $@"C:\n\{i}.md" }) } },
        };
        using var tray = new TrayViewModel(client, () => new TrayStatus(Running, Serving(0)), () => null);
        tray.Query = "garage";
        await tray.SearchAsync(TestContext.Current.CancellationToken);
        Assert.Equal(5, tray.Results.Count);
        SearchRequest request = Assert.IsType<SearchRequest>(client.Requests.Last(r => r is SearchRequest));
        Assert.Equal(("garage", "hybrid", 5), (request.Query, request.Mode, request.Limit));
        Assert.True(tray.ShowsAskRow);
        Assert.False(tray.ShowsNoMatches);
    }

    [Fact]
    public async Task Nothing_is_searched_or_asked_while_the_database_is_down()
    {
        var client = new FakeGarageClient();
        using var tray = new TrayViewModel(client, () => new TrayStatus(Stopped), () => new Uri("http://127.0.0.1:1/mcp"));
        tray.Query = "garage";
        await tray.SearchAsync(TestContext.Current.CancellationToken);
        Assert.DoesNotContain(client.Requests, r => r is SearchRequest);
        Assert.False(tray.ShowsAskRow);
    }

    // ---- Ask Garage

    private const string Sample = """
        {
          "answer": "Widgets ship on Tuesdays, per the User Guide.",
          "model": "gemma2-2b",
          "provider": "llama_xpc",
          "question": "when do widgets ship?",
          "steps": [
            {"n": 1, "tool": "rag_search", "arguments": {"query": "widgets"}, "summary": "Searched for “widgets”: 3 hits", "ok": true},
            {"n": 2, "tool": "rag_get_document", "arguments": {"document_id": 10}, "summary": "Read User Guide", "ok": true},
            {"n": 3, "tool": "rag_get_document", "arguments": {"document_id": 99}, "summary": "rag_get_document failed", "ok": false}
          ],
          "citations": [
            {"n": 1, "document_id": 10, "title": "User Guide", "location": "~/docs/guide.md", "snippet": "Widgets ship…", "corpus_class": "document"},
            {"n": 2, "document_id": 11, "title": null, "location": "~/code/ship.py", "snippet": "", "corpus_class": "code"}
          ],
          "prompt_tokens": 900,
          "completion_tokens": 40
        }
        """;

    [Fact]
    public void Parses_the_tool_result()
    {
        AskAnswer answer = AskAnswer.Parse(Sample)!;
        Assert.Equal("Widgets ship on Tuesdays, per the User Guide.", answer.Answer);
        Assert.Equal("gemma2-2b", answer.Model);
        Assert.Equal("when do widgets ship?", answer.Question);
        Assert.Equal(["rag_search", "rag_get_document", "rag_get_document"], answer.Trail.Select(s => s.Tool));
        Assert.Equal([true, true, false], answer.Trail.Select(s => s.Ok));
        Assert.Equal([10L, 11L], answer.Sources.Select(c => c.DocumentId));
        Assert.Null(answer.Sources[1].Title);
    }

    [Fact]
    public void Parse_rejects_what_is_not_an_answer()
    {
        Assert.Null(AskAnswer.Parse("Tool call failed: local model is not available"));
        Assert.Null(AskAnswer.Parse("""{"text": "pong"}"""));
        Assert.Null(AskAnswer.Parse("""{"answer": "   "}"""));
        Assert.Null(AskAnswer.Parse(""));
    }

    [Fact]
    public void Missing_optional_fields_have_defaults()
    {
        AskAnswer answer = AskAnswer.Parse("""{"answer": "Nothing in the corpus says."}""")!;
        Assert.Equal("", answer.Model);
        Assert.Empty(answer.Trail);
        Assert.Empty(answer.Sources);
        Assert.Equal("Answered without searching", answer.Footnote);
    }

    [Fact]
    public void Footnote_counts_the_steps_that_worked()
    {
        // The failed read is not counted.
        Assert.Equal("Searched once and read 1 document · gemma2-2b", AskAnswer.Parse(Sample)!.Footnote);

        AskAnswer.ToolCall[] steps =
        [
            new(1, "rag_search", ""), new(2, "rag_search", ""), new(3, "rag_stats", ""),
            new(4, "rag_get_document", ""), new(5, "rag_get_document", ""), new(6, "rag_get_document", ""),
        ];
        Assert.Equal("Searched twice, read 3 documents and looked up the corpus once · m", new AskAnswer("a", "m", "p", "q", steps).Footnote);
        Assert.Equal("Searched twice", new AskAnswer("a", "", "p", "q", steps[..2]).Footnote);
    }

    [Fact]
    public void Citation_title_falls_back_to_the_file_name()
    {
        Assert.Equal("User Guide", new AskAnswer.Citation(1, 1, "User Guide", "~/docs/guide.md", "", "document").DisplayTitle);
        Assert.Equal("ship.py", new AskAnswer.Citation(2, 2, null, "~/code/ship.py", "", "code").DisplayTitle);
        Assert.Equal("ship.py", new AskAnswer.Citation(2, 2, null, @"C:\code\ship.py", "", "code").DisplayTitle);
        Assert.Equal("Untitled", new AskAnswer.Citation(3, 3, "  ", "", "", "document").DisplayTitle);
    }

    [Fact]
    public void Citation_file_path_expands_the_home_folder()
    {
        Assert.Equal(@"C:\Users\me\docs\guide.md", new AskAnswer.Citation(1, 1, null, "~/docs/guide.md", "", "document").FilePath(@"C:\Users\me"));
        Assert.Null(new AskAnswer.Citation(2, 2, null, "imessage:chat123", "", "communication").FilePath(@"C:\Users\me"));
    }

    [Fact]
    public void A_reply_is_read_as_json_or_as_an_event_stream()
    {
        Assert.Equal(1, McpHttpClient.ParseReply("""{"jsonrpc":"2.0","id":1,"result":{}}""")!["id"]!.GetValue<int>());
        JsonObject streamed = McpHttpClient.ParseReply("event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{}}\n\n")!;
        Assert.Equal(7, streamed["id"]!.GetValue<int>());
        Assert.Null(McpHttpClient.ParseReply("event: ping\n\n"));
    }

    [Fact]
    public void Tool_text_joins_the_content_and_raises_errors()
    {
        var result = JsonNode.Parse("""{"result":{"content":[{"type":"text","text":"one"},{"type":"text","text":"two"}]}}""")!.AsObject();
        Assert.Equal("one\ntwo", McpHttpClient.ToolText(result));
        var error = JsonNode.Parse("""{"error":{"code":-32000,"message":"no model"}}""")!.AsObject();
        Assert.Equal("Tool call failed: no model", Assert.Throws<McpCallException>(() => McpHttpClient.ToolText(error)).Message);
    }

    [Fact]
    public async Task Ask_initializes_a_session_calls_rag_agent_and_shows_the_answer()
    {
        var server = new FakeMcpServer(Sample);
        using var http = new HttpClient(server);
        using var tray = new TrayViewModel(new FakeGarageClient(), () => new TrayStatus(Running, Serving(1)), () => new Uri("http://127.0.0.1:8787/mcp"), http);
        tray.Query = "  when do widgets ship?  ";
        await tray.AskAsync();

        Assert.Equal(["initialize", "notifications/initialized", "tools/call"], server.Methods);
        Assert.Equal("session-1", server.SessionsSeen[^1]);
        Assert.Equal("rag_agent", server.LastCall!["params"]!["name"]!.GetValue<string>());
        Assert.Equal("when do widgets ship?", server.LastCall["params"]!["arguments"]!["question"]!.GetValue<string>());
        Assert.False(tray.IsAsking);
        Assert.Equal("when do widgets ship?", tray.AskedQuestion);
        Assert.Equal("Widgets ship on Tuesdays, per the User Guide.", tray.Answer!.Answer);
        Assert.Equal(2, tray.ShownCitations.Count);
        Assert.True(tray.ShowsAnswer);

        // A second ask reuses the session.
        await tray.AskAsync();
        Assert.Equal(["initialize", "notifications/initialized", "tools/call", "tools/call"], server.Methods);
    }

    [Fact]
    public async Task A_tool_reply_that_is_not_an_answer_shows_as_an_error()
    {
        var server = new FakeMcpServer("Tool call failed: the local model\nis not available");
        using var http = new HttpClient(server);
        using var tray = new TrayViewModel(new FakeGarageClient(), () => new TrayStatus(Running, Serving(1)), () => new Uri("http://127.0.0.1:8787/mcp"), http);
        tray.Query = "q";
        await tray.AskAsync();
        Assert.Null(tray.Answer);
        Assert.Equal("Tool call failed: the local model is not available", tray.AskError);
    }

    [Fact]
    public async Task An_unreachable_server_is_an_ask_error()
    {
        using var http = new HttpClient(new FailingHandler());
        using var tray = new TrayViewModel(new FakeGarageClient(), () => new TrayStatus(Running, Serving(1)), () => new Uri("http://127.0.0.1:8787/mcp"), http);
        tray.Query = "q";
        await tray.AskAsync();
        Assert.StartsWith("Garage's MCP server isn't reachable", tray.AskError, StringComparison.Ordinal);
    }

    [Fact]
    public void Losing_the_mcp_server_clears_the_answer_and_losing_the_database_clears_the_field()
    {
        TrayStatus current = new(Running, Serving(1));
        using var tray = new TrayViewModel(new FakeGarageClient(), () => current, () => null);
        tray.Query = "q";
        current = new TrayStatus(Running, TrayServer.Stopped);
        tray.Refresh();
        Assert.False(tray.ShowsAskRow);
        Assert.Equal("q", tray.Query);
        current = new TrayStatus(Stopped);
        tray.Refresh();
        Assert.Equal("", tray.Query);
    }

    private sealed class FakeMcpServer(string toolText) : HttpMessageHandler
    {
        public List<string> Methods { get; } = [];

        public List<string?> SessionsSeen { get; } = [];

        public JsonObject? LastCall { get; private set; }

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            JsonObject body = JsonNode.Parse(await request.Content!.ReadAsStringAsync(cancellationToken))!.AsObject();
            string method = body["method"]!.GetValue<string>();
            Methods.Add(method);
            SessionsSeen.Add(request.Headers.TryGetValues("Mcp-Session-Id", out IEnumerable<string>? ids) ? ids.First() : null);
            HttpResponseMessage response;
            if (method == "initialize")
            {
                response = Json("""{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","serverInfo":{"name":"garage"}}}""");
                response.Headers.Add("Mcp-Session-Id", "session-1");
            }
            else if (method == "tools/call")
            {
                LastCall = body;
                var reply = new JsonObject
                {
                    ["jsonrpc"] = "2.0",
                    ["id"] = body["id"]!.GetValue<int>(),
                    ["result"] = new JsonObject { ["content"] = new JsonArray(new JsonObject { ["type"] = "text", ["text"] = toolText }) },
                };
                // Streamable HTTP may answer as an event stream.
                response = new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent($"event: message\ndata: {reply.ToJsonString()}\n\n", Encoding.UTF8, "text/event-stream") };
            }
            else
            {
                response = new HttpResponseMessage(HttpStatusCode.Accepted);
            }
            return response;
        }

        private static HttpResponseMessage Json(string text) => new(HttpStatusCode.OK) { Content = new StringContent(text, Encoding.UTF8, "application/json") };
    }

    private sealed class FailingHandler : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
            throw new HttpRequestException("No connection could be made because the target machine actively refused it.");
    }
}

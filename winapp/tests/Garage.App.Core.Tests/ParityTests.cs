using System.Net;
using System.Text;
using Garage.App.Core.Documents;
using Garage.App.Core.Facts;
using Garage.App.Core.Mcp;
using Garage.App.Core.Models;
using Garage.App.Core.Operations;
using Garage.App.Core.Search;
using Garage.App.Core.Sources;
using Garage.App.Core.Tests.TestSupport;

namespace Garage.App.Core.Tests;

// The surfaces added to reach the Mac app's pages (docs/plans/windows-ui.md §8, 2026-10-12): Distill
// Facts and its filters, the Sources page's More menu, the MCP page's Try It and port, Test an
// Embedding, and the links between pages.
public sealed class ParityTests
{
    [Fact]
    public void A_fact_maps_its_distilled_fact_agreement_and_restatement()
    {
        var summary = new FactSummary { Id = 7, Fact = "f" };
        FactListItem alone = FactListItem.From(summary);
        Assert.Null(alone.DistilledFactId);
        Assert.Null(alone.RestatesFactId);
        Assert.Null(alone.AgreementPercent);
        Assert.Equal("", alone.Badge);

        summary.DistilledFactId = 11;
        summary.DistilledSize = 3;
        summary.DistilledSpread = 0.0125;
        summary.RestatesFactId = 5;
        summary.DistilledStatement = "The roof is slate.";
        using var culture = new CultureScope("en-US");
        FactListItem item = FactListItem.From(summary);
        Assert.Equal(11, item.DistilledFactId);
        Assert.Equal(5, item.RestatesFactId);
        Assert.Equal(98, item.AgreementPercent);
        Assert.Equal("×3", item.Badge);
        Assert.Equal("Stated 3 times", item.BadgeHelp);
        Assert.Equal("Stated 3 Times", item.StatedTitle);
        Assert.Equal("The statements agree 98% (how close their meanings are).", item.AgreementText);
        Assert.Equal("↻", (item with { DistilledSize = 1 }).Badge);
    }

    [Fact]
    public async Task Group_restatements_and_the_filters_shape_the_request()
    {
        var client = new FakeGarageClient();
        var page = new FactsViewModel(client) { GroupRestatements = true };
        await page.RefreshAsync(TestContext.Current.CancellationToken);
        ListFactsRequest grouped = client.Requests.OfType<ListFactsRequest>().Last();
        Assert.True(grouped.Collapse);
        Assert.Equal((0L, 0L), (grouped.DocumentId, grouped.DistilledFactId));

        page.DocumentFilter = new FactsDocumentFilter(3, "house.md");
        page.DistilledFilter = new FactsDistilledFilter(11, "The roof is slate.");
        await page.RefreshAsync(TestContext.Current.CancellationToken);
        ListFactsRequest narrowed = client.Requests.OfType<ListFactsRequest>().Last();
        // Listing one claim's statements lists every one of them, grouped or not.
        Assert.False(narrowed.Collapse);
        Assert.Equal((3L, 11L), (narrowed.DocumentId, narrowed.DistilledFactId));
        Assert.Equal(3L, client.Requests.OfType<FactStatsRequest>().Last().DocumentId);
        Assert.Equal("Facts from house.md", page.DocumentFilterTitle);
        Assert.Equal("Statements of \u201CThe roof is slate.\u201D", page.DistilledFilterTitle);
    }

    [Fact]
    public async Task Distill_streams_cluster_facts_and_reloads()
    {
        var notifier = new SourcesTests.RecordingNotifier();
        var client = new FakeGarageClient
        {
            OnClusterFacts = _ =>
            [
                new ClusterFactsStatus { Phase = "distill", ToDistill = 4, Distilled = 1, Message = "asking" },
                new ClusterFactsStatus { Phase = "finished", Message = "12 distilled facts", Graph = "graph rebuilt", Errors = { "one group failed" } },
            ],
        };
        var page = new FactsViewModel(client);
        var runner = new OperationRunner("enrich-facts");

        OperationResult result = await page.DistillAsync(runner, full: true, notifier);

        Assert.True(result.Succeeded);
        Assert.True(client.Requests.OfType<ClusterFactsRequest>().Single().Full);
        Assert.Contains(runner.Logs, l => l.Text == "graph rebuilt");
        Assert.Contains(runner.Logs, l => l.Text == "one group failed" && l.Channel == LogChannel.Stderr);
        Assert.Equal(("Facts distilled", "12 distilled facts"), notifier.Last);
        Assert.Null(page.GleanProgress);
        Assert.Single(client.Requests.OfType<ListFactsRequest>());
    }

    [Fact]
    public void Distill_steps_read_as_progress()
    {
        using var culture = new CultureScope("en-US");
        Assert.Equal("Stating each claim once… 2 of 9", FactsViewModel.DistillProgress(new ClusterFactsStatus { Phase = "distill", Distilled = 2, ToDistill = 9 }));
        Assert.Equal("Finding similar facts… 40 of 100", FactsViewModel.DistillProgress(new ClusterFactsStatus { Phase = "neighbors", Scanned = 40, Facts = 100 }));
        Assert.Null(FactsViewModel.DistillProgress(new ClusterFactsStatus { Phase = "finished" }));
    }

    [Fact]
    public void A_glean_scope_narrows_the_request()
    {
        Assert.True(GleanScope.Stale.Request().StaleOnly);
        EnrichFactsRequest source = new GleanScope(Source: "notes").Request();
        Assert.Equal(("notes", 0L, false), (source.Source, source.DocumentId, source.StaleOnly));
        Assert.Equal(42, new GleanScope(DocumentId: 42).Request().DocumentId);
        Assert.Equal(["people"], new GleanScope(Prompts: ["people"]).Request().Prompts);
    }

    [Fact]
    public async Task Check_and_forget_deleted_files_reconcile_one_source()
    {
        var client = new FakeGarageClient
        {
            OnReconcile = r => new ReconcileResponse { Source = r.Source, TotalDocuments = 40, Candidates = 3, Deleted = r.Apply ? 3 : 0 },
        };
        var page = new SourcesViewModel(client, new OperationRunner("garage"), checkAccess: _ => new SourceAccess(true, true, ""));
        using var culture = new CultureScope("en-US");

        OperationResult check = await page.ReconcileAsync("notes", apply: false);
        Assert.Equal("3 of 40 documents in notes point at files that are gone. Forget Deleted Files removes them.", check.Output);
        OperationResult forget = await page.ReconcileAsync("notes", apply: true);
        Assert.Equal("Forgot 3 deleted files (3 of 40 documents in notes were missing)", forget.Output);
        Assert.Equal([false, true], client.Requests.OfType<ReconcileRequest>().Select(r => r.Apply));
    }

    [Fact]
    public void A_refused_or_clean_reconcile_says_so()
    {
        Assert.Equal("Did not forget deleted files in notes: 90% of the source is missing",
            SourcesReconcile.Describe(new ReconcileResponse { Source = "notes", Refused = true, Reason = "90% of the source is missing" }, apply: true));
        Assert.Equal("Every file in notes is still there", SourcesReconcile.Describe(new ReconcileResponse { Source = "notes", TotalDocuments = 4 }, apply: false));
        Assert.Equal("server says", SourcesReconcile.Describe(new ReconcileResponse { Message = "server says" }, apply: false));
    }

    [Fact]
    public void Try_it_sends_what_an_assistant_would()
    {
        var page = new McpTryItViewModel(() => new Uri("http://127.0.0.1:8787/mcp")) { Prompt = "  What roof?  " };
        (string tool, Dictionary<string, object?> args) = page.Request();
        Assert.Equal("rag_ask", tool);
        Assert.Equal("What roof?", args["question"]);
        Assert.Equal(6, args["limit"]);
        Assert.Equal(512, args["max_tokens"]);

        page.Mode = TryItMode.Prompt;
        Assert.Equal(256, page.MaxTokens);
        Assert.Equal(0.7, page.Temperature);
        Assert.Equal("rag_generate", page.Request().Tool);

        page.Mode = TryItMode.Tool;
        page.ToolName = "rag_get_document";
        Assert.Equal(ToolArgumentKind.DocumentId, page.ArgumentKind);
        page.ToolDocumentId = "x";
        Assert.False(page.CanRun);
        page.ToolDocumentId = "12";
        Assert.Equal(12L, page.Request().Arguments["document_id"]);

        page.ToolName = "rag_stats";
        Assert.Equal(ToolArgumentKind.None, page.ArgumentKind);
        Assert.Empty(page.Request().Arguments);
    }

    [Fact]
    public void Try_it_needs_a_running_server_and_reads_any_tool_by_its_schema()
    {
        var off = new McpTryItViewModel(() => null) { Prompt = "q" };
        Assert.False(off.CanRun);

        var page = new McpTryItViewModel(() => new Uri("http://127.0.0.1:8787/mcp")) { Mode = TryItMode.Tool };
        page.ListedTools.Add(new McpToolInfo("rag_ask", "Answer", """{"type":"object","properties":{"question":{"type":"string"}}}"""));
        page.ListedTools.Add(new McpToolInfo("rag_ping", "", """{"type":"object","properties":{}}"""));
        page.ToolName = "rag_ask";
        Assert.Equal(ToolArgumentKind.Json, page.ArgumentKind);
        Assert.Equal("Answer", page.ToolDescription);
        page.ToolArgumentsJson = "[1]";
        Assert.False(page.CanRun);
        page.ToolArgumentsJson = """{"question": "q"}""";
        Assert.True(page.CanRun);
        page.ToolName = "rag_ping";
        Assert.Equal(ToolArgumentKind.None, page.ArgumentKind);
    }

    [Fact]
    public void An_answer_parses_with_citations_and_anything_else_stays_raw()
    {
        PlaygroundAnswer? answer = PlaygroundAnswer.Parse("""{"answer": "Slate.", "model": "gemma2:2b", "provider": "ollama", "citations": [{"n": 1, "document_id": 4, "title": "House", "location": "~/house.md", "snippet": "slate roof", "score": 0.81234}]}""");
        Assert.NotNull(answer);
        Assert.Equal("Slate.", answer.DisplayText);
        Assert.Equal("gemma2:2b via ollama", answer.ModelLine);
        PlaygroundCitation citation = Assert.Single(answer.Citations!);
        Assert.Equal(("House", "0.812"), (citation.DisplayTitle, citation.ScoreText));
        Assert.Equal("A haiku.", PlaygroundAnswer.Parse("""{"text": "A haiku."}""")?.DisplayText);
        Assert.Null(PlaygroundAnswer.Parse("""{"results": []}"""));
        Assert.Null(PlaygroundAnswer.Parse("Error: no model"));
    }

    [Fact]
    public void Tools_list_parses_names_descriptions_and_schemas()
    {
        IReadOnlyList<McpToolInfo> tools = McpToolInfo.Parse(System.Text.Json.Nodes.JsonNode.Parse(
            """{"result": {"tools": [{"name": "rag_search", "description": " Search. ", "inputSchema": {"type": "object", "properties": {"query": {}}}}, {"description": "no name"}]}}""")!.AsObject());
        McpToolInfo tool = Assert.Single(tools);
        Assert.Equal(("rag_search", "Search."), (tool.Name, tool.Description));
        Assert.False(tool.TakesNoArguments);
        Assert.Throws<McpCallException>(() => McpToolInfo.Parse(System.Text.Json.Nodes.JsonNode.Parse("""{"error": {"message": "nope"}}""")!.AsObject()));
    }

    [Fact]
    public async Task Test_lists_the_servers_tools_for_try_it()
    {
        using var handler = new ScriptedHandler(
            """{"jsonrpc":"2.0","id":1,"result":{}}""",
            "",
            """{"jsonrpc":"2.0","id":101,"result":{"tools":[{"name":"rag_search","description":"Search"},{"name":"rag_agent","description":"Agent"}]}}""");
        using var http = new HttpClient(handler);
        var page = new McpTryItViewModel(() => new Uri("http://127.0.0.1:8787/mcp"), uri => new McpHttpClient(uri, http));

        string line = await page.TestAsync(TestContext.Current.CancellationToken);

        Assert.Contains("2 tools: rag_search, rag_agent", line, StringComparison.Ordinal);
        Assert.Equal(["rag_search", "rag_agent"], page.AvailableTools.Select(t => t.Name));
        Assert.Contains("\"tools/list\"", handler.Bodies[^1], StringComparison.Ordinal);
    }

    [Fact]
    public async Task The_port_is_remembered_and_moves_a_running_server()
    {
        var preferences = new State.MemoryPreferences();
        var http = new FakeMcpHost();
        var page = new McpViewModel(new FakeGarageClient(), new OperationRunner()) { Preferences = preferences, Http = http };
        await page.SetHttpEnabledAsync(true);

        Assert.False(await page.SetPortAsync(80));
        Assert.True(await page.SetPortAsync(9911));
        Assert.Equal(9911, http.Port);
        Assert.Equal(9911, preferences.Read(McpViewModel.PortKey, 0));
        // Stopped and started again on the new port.
        Assert.Equal([true, false, true], http.Calls);

        var next = new McpViewModel(new FakeGarageClient(), new OperationRunner()) { Preferences = preferences, Http = new FakeMcpHost() };
        await next.RestoreHttpAsync();
        Assert.Equal(9911, next.Port);
    }

    [Fact]
    public async Task Connect_a_config_file_registers_stdio_there()
    {
        var client = new FakeGarageClient();
        var page = new McpViewModel(client, new OperationRunner());
        await page.ConnectConfigFileAsync(@"C:\work\.mcp.json");
        McpInstallRequest request = client.Requests.OfType<McpInstallRequest>().Single();
        Assert.Equal((@"C:\work\.mcp.json", true, true), (request.Path, request.Stdio, request.Force));
    }

    [Fact]
    public async Task Test_an_embedding_shows_the_vector_and_copies_it()
    {
        var client = new FakeGarageClient
        {
            OnEmbedText = r => new EmbedTextResponse { Model = "bge-m3", Provider = "ollama", NativeDims = 4, Vector = { 0.6f, 0.8f } },
        };
        var page = new EmbeddingTestViewModel(client) { Text = "the roof", Model = "bge-m3", Dimensions = 2 };
        using var culture = new CultureScope("en-US");

        await page.RunAsync(TestContext.Current.CancellationToken);

        EmbedTextRequest request = client.Requests.OfType<EmbedTextRequest>().Single();
        Assert.Equal(("the roof", "bge-m3", 2), (request.Text, request.Model, request.Dimensions));
        EmbeddingInspection result = page.Result!;
        Assert.Equal("bge-m3 via ollama · 2 dimensions of 4", result.Caption);
        Assert.Equal(1, result.Norm, 5);
        Assert.Equal("0.6000, 0.8000", result.Preview());
        Assert.Equal("index,value\n0,0.6\n1,0.8\n", result.Csv());
        Assert.Equal("[0.6,0.8]", result.Json());
    }

    [Fact]
    public async Task A_failed_embedding_says_why()
    {
        var client = new FakeGarageClient { OnEmbedText = _ => throw FakeGarageClient.Failure(global::Grpc.Core.StatusCode.Unavailable, "ollama embed failed: refused") };
        var page = new EmbeddingTestViewModel(client);
        await page.RunAsync(TestContext.Current.CancellationToken);
        Assert.Contains("refused", page.Error, StringComparison.Ordinal);
        Assert.Null(page.Result);
        Assert.False(new EmbeddingTestViewModel(client) { Text = "  " }.CanRun);
    }

    [Fact]
    public async Task Open_document_filters_to_it_and_selects_it()
    {
        var client = new FakeGarageClient
        {
            OnListDocuments = _ => new ListDocumentsResponse { Documents = { new DocumentSummary { Id = 9, Uri = "/notes/house.md", Title = "House" } }, TotalCount = 1 },
            OnGetDocument = r => new GetDocumentResponse { Document = new Garage.DocumentDetail { Id = r.DocumentId, Uri = "/notes/house.md", Title = "House" } },
        };
        var page = new DocumentsViewModel(client) { Source = "mail", PendingFocus = new DocumentFocus(9, "/notes/house.md") };

        await page.ShowAsync(page.PendingFocus!, TestContext.Current.CancellationToken);

        ListDocumentsRequest list = client.Requests.OfType<ListDocumentsRequest>().Single();
        Assert.Equal(("/notes/house.md", ""), (list.Query, list.Source));
        Assert.Equal(9, page.Selected?.Id);
        Assert.Equal("House", page.Detail?.Title);
        Assert.Null(page.PendingFocus);
    }

    [Fact]
    public async Task Search_offers_the_registered_models()
    {
        var client = new FakeGarageClient { OnListModels = _ => new ListModelsResponse { Models = { new ModelInfo { Slug = "nomic" }, new ModelInfo { Slug = "bge-m3" } } } };
        var page = new SearchViewModel(client) { Model = "gone" };
        await page.LoadModelsAsync(TestContext.Current.CancellationToken);
        Assert.Equal(["", "bge-m3", "nomic"], page.Models);
        Assert.Equal("", page.Model);
        Assert.Equal("Model: Default", SearchViewModel.ModelTitle(""));
        Assert.Equal("Model: nomic", SearchViewModel.ModelTitle("nomic"));
    }

    private sealed class FakeMcpHost : IMcpHttpHost
    {
        public Services.ServiceProcess Service { get; } = new("mcp", "pipe", Threading.InlineDispatcher.Instance);

        public Uri Url => new($"http://127.0.0.1:{Port}/mcp");

        public int Port { get; set; } = 8787;

        public List<bool> Calls { get; } = [];

        public Task<bool> SetEnabledAsync(bool enabled)
        {
            Calls.Add(enabled);
            Service.Set(enabled ? Services.ServiceState.Running : Services.ServiceState.Stopped);
            return Task.FromResult(true);
        }
    }

    /// <summary>Answers each POST with the next scripted body, recording what was sent.</summary>
    private sealed class ScriptedHandler(params string[] replies) : HttpMessageHandler
    {
        private int _next;

        public List<string> Bodies { get; } = [];

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Bodies.Add(request.Content is null ? "" : await request.Content.ReadAsStringAsync(cancellationToken));
            string body = _next < replies.Length ? replies[_next++] : "";
            var response = new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
            response.Headers.Add("Mcp-Session-Id", "s1");
            return response;
        }
    }
}

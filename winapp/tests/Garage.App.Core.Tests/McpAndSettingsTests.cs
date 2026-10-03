using Garage.App.Core.Mcp;
using Garage.App.Core.Operations;
using Garage.App.Core.Presentation;
using Garage.App.Core.Settings;
using Garage.App.Core.Tests.TestSupport;

namespace Garage.App.Core.Tests;

// Ported from macapp/Tests/GarageAppUnitTests/MCPServerPresentationTests.swift ("this Mac" reads
// "this PC"), plus the config reader and the page's operations.
public sealed class McpAndSettingsTests
{
    private static readonly Uri Endpoint = new("http://127.0.0.1:8787/mcp");

    private static McpClient Client(string key = "claude-desktop", bool exists = true, bool registered = false, string? url = null) =>
        new(key, key, $@"C:\cfg\{key}.json", exists, registered, url);

    [Fact]
    public void A_running_server_that_answered_counts_its_tools()
    {
        McpServerHeadline headline = McpServerHeadline.For(new(McpServerState.Running), new(true, 2), false, true, 1);
        Assert.Equal("Running", headline.Title);
        Assert.Equal("Answering on this PC only · 2 tools", headline.Detail);
        Assert.Equal(Tint.Green, headline.Tint);
        Assert.False(headline.DetailIsError);
    }

    [Fact]
    public void A_running_server_that_failed_its_check_says_so()
    {
        McpServerHeadline headline = McpServerHeadline.For(new(McpServerState.Running), new(false, ErrorMessage: "connection refused"), false, true, 0);
        Assert.Equal("Running, but not answering", headline.Title);
        Assert.Equal("connection refused", headline.Detail);
        Assert.True(headline.DetailIsError);
    }

    [Fact]
    public void A_check_in_flight_wins_over_an_old_result() =>
        Assert.Equal("Checking that it answers…", McpServerHeadline.For(new(McpServerState.Running), new(false, ErrorMessage: "old"), true, true, 0).Detail);

    [Fact]
    public void A_stopped_server_names_the_assistants_it_strands()
    {
        McpServerHeadline headline = McpServerHeadline.For(new(McpServerState.Stopped), null, false, false, 2);
        Assert.Equal("Stopped", headline.Title);
        Assert.Equal("2 connected assistants can't reach Garage until it runs. Starting it also starts the database.", headline.Detail);
        Assert.False(headline.IsActive);
    }

    [Fact]
    public void A_stopped_server_ignores_an_earlier_check() =>
        Assert.Equal("Assistants reach Garage through this server once they're connected.",
            McpServerHeadline.For(new(McpServerState.Stopped), new(true, 1), false, true, 0).Detail);

    [Fact]
    public void A_stopped_server_with_http_off_is_the_normal_stdio_state()
    {
        McpServerHeadline headline = McpServerHeadline.For(new(McpServerState.Stopped), null, false, true, 2, httpEnabled: false);
        Assert.Equal("HTTP off", headline.Title);
        Assert.Equal(StatusSymbol.Terminal, headline.Symbol);
        Assert.True(headline.IsActive);
        Assert.False(McpServerHeadline.For(new(McpServerState.Stopped), null, false, true, 0, httpEnabled: false).IsActive);
    }

    [Fact]
    public void A_failed_server_shows_its_error()
    {
        McpServerHeadline headline = McpServerHeadline.For(new(McpServerState.Failed, "port in use"), null, false, true, 0);
        Assert.Equal("Couldn't start", headline.Title);
        Assert.Equal("port in use", headline.Detail);
        Assert.True(headline.DetailIsError);
    }

    [Fact]
    public void Assistant_rows()
    {
        McpClientRowPresentation connected = McpClientRowPresentation.For(Client(registered: true, url: "http://127.0.0.1:8787/mcp/"), Endpoint);
        Assert.Equal((McpClientState.Connected, "Connected", (string?)null), (connected.State, connected.Status, connected.ActionTitle));
        Assert.Equal(McpClientState.Connected, McpClientRowPresentation.For(Client(registered: true), Endpoint).State);

        McpClientRowPresentation httpOff = McpClientRowPresentation.For(Client(registered: true, url: "http://127.0.0.1:8787/mcp"), null);
        Assert.Equal(McpClientState.Outdated, httpOff.State);
        Assert.Equal("Update", httpOff.ActionTitle);
        Assert.Equal("Points at http://127.0.0.1:8787/mcp, but the HTTP server is off", httpOff.Status);
        Assert.Equal(McpClientState.Connected, McpClientRowPresentation.For(Client(registered: true), null).State);

        McpClientRowPresentation oldPort = McpClientRowPresentation.For(Client(registered: true, url: "http://127.0.0.1:9000/mcp"), Endpoint);
        Assert.True(oldPort.IsOutdated);
        Assert.Equal("Points at http://127.0.0.1:9000/mcp, not http://127.0.0.1:8787/mcp", oldPort.Status);

        McpClientRowPresentation installed = McpClientRowPresentation.For(Client(), Endpoint);
        Assert.Equal((McpClientState.NotConnected, "Installed, not connected", "Connect"), (installed.State, installed.Status, installed.ActionTitle));

        McpClientRowPresentation missing = McpClientRowPresentation.For(Client(exists: false), Endpoint);
        Assert.Equal((McpClientState.NotInstalled, "Not found on this PC"), (missing.State, missing.Status));
    }

    [Fact]
    public void Each_known_client_has_its_own_symbol()
    {
        Assert.Equal(McpClientSymbol.Terminal, McpClientRowPresentation.SymbolFor("claude-code-user"));
        Assert.Equal(McpClientSymbol.Chat, McpClientRowPresentation.SymbolFor("claude-desktop"));
        Assert.Equal(McpClientSymbol.Editor, McpClientRowPresentation.SymbolFor("cursor"));
        Assert.Equal(McpClientSymbol.Extension, McpClientRowPresentation.SymbolFor("something-new"));
    }

    private static List<McpClientRowPresentation> Rows(params McpClient[] clients) => [.. clients.Select(c => McpClientRowPresentation.For(c, Endpoint))];

    [Fact]
    public void Summaries()
    {
        List<McpClientRowPresentation> none = Rows(Client("a", exists: false), Client("b", exists: false));
        Assert.Equal("No assistants found on this PC", McpPagePresentation.ClientSummary(none));
        Assert.False(McpPagePresentation.CanConnectAll(none));

        List<McpClientRowPresentation> unconnected = Rows(Client("a"), Client("b"), Client("c", exists: false));
        Assert.Equal("None of 2 installed assistants connected yet", McpPagePresentation.ClientSummary(unconnected));
        Assert.True(McpPagePresentation.CanConnectAll(unconnected));

        List<McpClientRowPresentation> some = Rows(Client("a", registered: true), Client("b", registered: true, url: "http://127.0.0.1:1/mcp"), Client("c"));
        Assert.Equal("1 of 3 installed assistants connected · 1 needs updating", McpPagePresentation.ClientSummary(some));

        List<McpClientRowPresentation> all = Rows(Client("a", registered: true), Client("b", registered: true), Client("c", exists: false));
        Assert.Equal("All 2 installed assistants are connected", McpPagePresentation.ClientSummary(all));
        Assert.False(McpPagePresentation.CanConnectAll(all));

        Assert.Equal("Your assistant is connected", McpPagePresentation.ClientSummary(Rows(Client("a", registered: true))));
    }

    [Theory]
    [InlineData("""{"mcpServers": {"garage-rag": {"type": "http", "url": "http://127.0.0.1:8787/mcp"}}}""", "http://127.0.0.1:8787/mcp")]
    [InlineData("""{"mcpServers": {"garage-rag": {"command": "garage-mcp", "args": []}}}""", null)]
    [InlineData("""{"servers": {"garage-rag": {"url": "http://127.0.0.1:8787/mcp"}}}""", "http://127.0.0.1:8787/mcp")]
    [InlineData("""{"context_servers": {"garage-rag": {"url": "http://x/mcp"}}, /* Zed allows comments */ }""", "http://x/mcp")]
    [InlineData("""{"mcpServers": {"other": {"url": "http://elsewhere"}}}""", null)]
    [InlineData("not json", null)]
    [InlineData("", null)]
    public void The_config_reader_finds_garages_url(string json, string? expected) =>
        Assert.Equal(expected, McpClientConfigReader.RegisteredUrlIn(json));

    [Fact]
    public async Task The_mcp_page_connects_over_stdio_and_disconnects()
    {
        var client = new FakeGarageClient
        {
            OnMcpStatus = _ => new McpStatusResponse
            {
                ServerCommand = @"C:\venv\Scripts\garage-mcp.exe",
                Clients =
                {
                    new McpClientInfo { Key = "claude-desktop", Label = "Claude Desktop", Path = @"C:\cfg\desktop.json", ConfigExists = true },
                    new McpClientInfo { Key = "claude-code-user", Label = "Claude Code", Path = @"C:\cfg\code.json", ConfigExists = true, Registered = true },
                    new McpClientInfo { Key = "zed", Label = "Zed", Path = @"C:\cfg\zed.json" },
                },
            },
        };
        var page = new McpViewModel(client, new OperationRunner(), path => path.EndsWith("code.json", StringComparison.Ordinal) ? "http://127.0.0.1:8787/mcp" : null);

        await page.LoadAsync(TestContext.Current.CancellationToken);

        Assert.Equal([McpClientState.NotConnected, McpClientState.Outdated, McpClientState.NotInstalled], page.Rows.Select(r => r.State));
        Assert.Equal("0 of 2 installed assistants connected · 1 needs updating", page.Summary);
        Assert.Equal("HTTP off", page.Headline!.Title);
        Assert.True(page.CanConnectAll);

        await page.ConnectAllAsync();
        Assert.Equal(["claude-desktop", "claude-code-user"], client.Requests.OfType<McpInstallRequest>().Select(r => r.Target));
        Assert.All(client.Requests.OfType<McpInstallRequest>(), r => Assert.True(r.Stdio && r.Force));

        OperationResult removed = await page.DisconnectAsync("claude-code-user");
        Assert.Equal("disconnected claude-code-user", removed.Output);
    }

    [Fact]
    public async Task Settings_read_and_save_only_what_changed()
    {
        var client = new FakeGarageClient
        {
            OnGetSetting = r => new GetSettingResponse { Name = r.Name, ValueJson = r.Name == "facts.model" ? "\"gemma2:2b\"" : "\"\"" },
        };
        var page = new SettingsViewModel(client, new OperationRunner());
        await page.LoadAsync(TestContext.Current.CancellationToken);

        SettingField model = page.Fields.Single(f => f.Name == "facts.model");
        Assert.Equal("gemma2:2b", model.Value);
        Assert.False(model.IsChanged);
        Assert.Equal(["llama_xpc", "ollama", "lmstudio"], page.Fields.Single(f => f.Name == "facts.provider").Choices);

        model.Value = "qwen3:4b ";
        Assert.True(model.IsChanged);
        OperationResult saved = await page.SaveAsync();

        Assert.Equal([("facts.model", "qwen3:4b")], client.Requests.OfType<SetSettingRequest>().Select(r => (r.Name, r.Value)));
        Assert.Equal(@"facts.model = qwen3:4b (in C:\Users\me\.garage.json)", saved.Output);
        Assert.False(model.IsChanged);

        model.Value = "other";
        page.Revert();
        Assert.Equal("qwen3:4b", model.Value);
    }

    [Fact]
    public async Task A_refused_setting_keeps_the_edit_and_says_why()
    {
        var client = new FakeGarageClient { OnSetSetting = _ => throw FakeGarageClient.Failure(global::Grpc.Core.StatusCode.InvalidArgument, "embedding.ollama_host: not a URL") };
        var page = new SettingsViewModel(client, new OperationRunner());
        SettingField host = page.Fields.First();
        host.Value = "nope";

        OperationResult saved = await page.SaveAsync();

        Assert.False(saved.Succeeded);
        Assert.Contains("not a URL", page.ErrorMessage, StringComparison.Ordinal);
        Assert.Equal("nope", host.Value);
    }

    private sealed class FakeHttp : Mcp.IMcpHttpHost
    {
        public Services.ServiceProcess Service { get; } = new("mcp", "pipe", Threading.InlineDispatcher.Instance);

        public Uri Url { get; } = new("http://127.0.0.1:8787/mcp");

        public List<bool> Calls { get; } = [];

        public Task<bool> SetEnabledAsync(bool enabled)
        {
            Calls.Add(enabled);
            Service.Set(enabled ? Services.ServiceState.Running : Services.ServiceState.Stopped);
            return Task.FromResult(true);
        }
    }

    [Fact]
    public async Task The_http_switch_serves_mcp_and_is_remembered()
    {
        var preferences = new State.MemoryPreferences();
        var http = new FakeHttp();
        var page = new Mcp.McpViewModel(new FakeGarageClient(), new Operations.OperationRunner()) { Preferences = preferences, Http = http };
        Assert.True(page.CanServeHttp);
        Assert.Equal("HTTP off", page.Headline!.Title);

        Assert.True(await page.SetHttpEnabledAsync(true));
        Assert.True(page.HttpEnabled);
        Assert.Equal(new Uri("http://127.0.0.1:8787/mcp"), page.HttpUrl);
        Assert.Equal("Running", page.Headline!.Title);
        Assert.True(preferences.Read(Mcp.McpViewModel.HttpEnabledKey, false));

        // The next launch turns it back on.
        var next = new Mcp.McpViewModel(new FakeGarageClient(), new Operations.OperationRunner()) { Preferences = preferences, Http = new FakeHttp() };
        await next.RestoreHttpAsync();
        Assert.True(next.HttpEnabled);

        Assert.True(await page.SetHttpEnabledAsync(false));
        Assert.Null(page.HttpUrl);
        Assert.Equal([true, false], http.Calls);
        Assert.False(preferences.Read(Mcp.McpViewModel.HttpEnabledKey, true));
        Assert.False(new Mcp.McpViewModel(new FakeGarageClient(), new Operations.OperationRunner()).CanServeHttp);
    }
}

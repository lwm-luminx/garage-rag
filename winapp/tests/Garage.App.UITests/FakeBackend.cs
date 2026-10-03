using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using System.Text.Json.Nodes;
using Grpc.Core;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Server.Kestrel.Core;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

namespace Garage.App.UITests;

/// <summary>
/// The backend the UI tests run the app against (the Mac's UI tests use fixtures and a deterministic
/// engine): a GarageService with a small in-memory corpus, and an MCP endpoint whose <c>rag_agent</c>
/// gives a fixed answer. It records what the app asked of it.
/// </summary>
public sealed class FakeBackend : IAsyncDisposable
{
    /// <summary>The fixed Ask Garage answer.</summary>
    public const string Answer = "The workbench is on the north wall, under the pegboard.";

    private WebApplication? _app;

    private FakeBackend(int documents) => Garage = new FakeGarage(documents);

    /// <summary>The GarageService.</summary>
    public FakeGarage Garage { get; }

    /// <summary>gRPC port.</summary>
    public int GrpcPort { get; private set; }

    /// <summary>MCP endpoint.</summary>
    public Uri McpUrl { get; private set; } = null!;

    /// <summary>Questions <c>rag_agent</c> was asked.</summary>
    public ConcurrentQueue<string> Questions { get; } = new();

    /// <summary>Starts both endpoints on free loopback ports; <paramref name="documents"/> sizes the corpus.</summary>
    public static async Task<FakeBackend> StartAsync(int documents = 2)
    {
        var backend = new FakeBackend(documents);
        backend.GrpcPort = FreePort();
        int mcpPort = FreePort();
        backend.McpUrl = new Uri($"http://127.0.0.1:{mcpPort}/mcp");
        WebApplicationBuilder builder = WebApplication.CreateSlimBuilder();
        builder.Logging.ClearProviders();
        builder.Services.AddGrpc(o => o.MaxReceiveMessageSize = 256 * 1024 * 1024);
        builder.Services.AddSingleton(backend.Garage);
        builder.WebHost.ConfigureKestrel(k =>
        {
            k.Listen(IPAddress.Loopback, backend.GrpcPort, l => l.Protocols = HttpProtocols.Http2);
            k.Listen(IPAddress.Loopback, mcpPort, l => l.Protocols = HttpProtocols.Http1);
        });
        WebApplication app = builder.Build();
        app.MapGrpcService<FakeGarage>();
        app.MapPost("/mcp", backend.McpAsync);
        await app.StartAsync().ConfigureAwait(false);
        backend._app = app;
        return backend;
    }

    /// <inheritdoc/>
    public async ValueTask DisposeAsync()
    {
        if (_app is not null)
        {
            await _app.StopAsync().ConfigureAwait(false);
            await _app.DisposeAsync().ConfigureAwait(false);
        }
    }

    private async Task McpAsync(HttpContext context)
    {
        JsonObject request = (await JsonNode.ParseAsync(context.Request.Body).ConfigureAwait(false))!.AsObject();
        string method = request["method"]!.GetValue<string>();
        context.Response.Headers["Mcp-Session-Id"] = "ui-test";
        if (!request.ContainsKey("id"))
        {
            context.Response.StatusCode = 202;
            return;
        }
        JsonNode result = method switch
        {
            "initialize" => new JsonObject { ["protocolVersion"] = "2025-06-18", ["capabilities"] = new JsonObject(), ["serverInfo"] = new JsonObject { ["name"] = "garage-fake" } },
            "tools/call" => ToolCall(request["params"]!.AsObject()),
            _ => new JsonObject(),
        };
        var reply = new JsonObject { ["jsonrpc"] = "2.0", ["id"] = request["id"]!.DeepClone(), ["result"] = result };
        context.Response.ContentType = "application/json";
        await context.Response.WriteAsync(reply.ToJsonString()).ConfigureAwait(false);
    }

    private JsonObject ToolCall(JsonObject parameters)
    {
        string question = parameters["arguments"]?["question"]?.GetValue<string>() ?? "";
        Questions.Enqueue(question);
        string text = JsonSerializer.Serialize(new
        {
            answer = Answer,
            model = "deterministic",
            provider = "fake",
            question,
            steps = new object[] { new { n = 1, tool = "rag_search", summary = "Searched for the workbench: 1 hit", ok = true } },
            citations = new object[] { new { n = 1, document_id = 1, title = "The garage", location = "~/notes/garage.md", snippet = "The workbench is on the north wall", corpus_class = "document" } },
        });
        return new JsonObject { ["content"] = new JsonArray(new JsonObject { ["type"] = "text", ["text"] = text }) };
    }

    private static int FreePort()
    {
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        return ((IPEndPoint)listener.LocalEndpoint).Port;
    }
}

/// <summary>GarageService over an in-memory corpus.</summary>
public sealed class FakeGarage(int documents) : GarageService.GarageServiceBase
{
    private readonly Lock _lock = new();
    private readonly List<SourceInfo> _sources = [];
    private readonly List<ModelInfo> _models = [];
    private readonly Dictionary<string, string> _settings = new(StringComparer.Ordinal);

    /// <summary>Every request, in order.</summary>
    public ConcurrentQueue<object> Requests { get; } = new();

    /// <summary>How many documents the corpus holds.</summary>
    public int DocumentCount { get; } = documents;

    public override Task<PingResponse> Ping(PingRequest request, ServerCallContext context) => Task.FromResult(new PingResponse());

    public override Task<StatusResponse> GetStatus(StatusRequest request, ServerCallContext context) =>
        Task.FromResult(new StatusResponse { Version = "1.5.0-uitest", IsReady = true, DbStatus = "ok", ServerType = "fake" });

    public override Task<StatsResponse> GetStats(StatsRequest request, ServerCallContext context)
    {
        lock (_lock)
        {
            return Task.FromResult(new StatsResponse { Documents = DocumentCount, Chunks = DocumentCount, Sources = _sources.Count, Models = _models.Count });
        }
    }

    public override Task<ListSourcesResponse> ListSources(ListSourcesRequest request, ServerCallContext context)
    {
        lock (_lock)
        {
            return Task.FromResult(new ListSourcesResponse { Sources = { _sources.Select(s => s.Clone()) } });
        }
    }

    public override Task<AddSourceResponse> AddSource(AddSourceRequest request, ServerCallContext context)
    {
        Requests.Enqueue(request);
        lock (_lock)
        {
            _sources.RemoveAll(s => s.Slug == request.Slug);
            _sources.Add(new SourceInfo { Slug = request.Slug, Root = request.Root, Kind = request.Kind, CorpusClass = request.CorpusClass, TrustTier = request.Trust, Enabled = true });
        }
        return Task.FromResult(new AddSourceResponse { Slug = request.Slug, Root = request.Root, Created = true });
    }

    public override Task<SyncSourcesResponse> SyncSources(SyncSourcesRequest request, ServerCallContext context) =>
        Task.FromResult(new SyncSourcesResponse { ConfigPath = "garage.json" });

    public override Task<ListModelsResponse> ListModels(ListModelsRequest request, ServerCallContext context)
    {
        lock (_lock)
        {
            return Task.FromResult(new ListModelsResponse { Models = { _models.Select(m => m.Clone()) } });
        }
    }

    public override Task<RegisterModelResponse> RegisterModel(RegisterModelRequest request, ServerCallContext context)
    {
        Requests.Enqueue(request);
        var model = new ModelInfo { Slug = request.Slug, Provider = request.Provider, ModelRef = request.ModelRef, Dims = request.Dims, StorageKind = "vector", Distance = "cosine" };
        lock (_lock)
        {
            model.IsDefault = request.MakeDefault || _models.Count == 0;
            _models.Add(model);
        }
        return Task.FromResult(new RegisterModelResponse { Model = model, Message = $"registered {request.Slug}" });
    }

    public override Task<GetSettingResponse> GetSetting(GetSettingRequest request, ServerCallContext context)
    {
        lock (_lock)
        {
            return Task.FromResult(new GetSettingResponse { Name = request.Name, ValueJson = JsonSerializer.Serialize(_settings.GetValueOrDefault(request.Name, "")) });
        }
    }

    public override Task<SetSettingResponse> SetSetting(SetSettingRequest request, ServerCallContext context)
    {
        Requests.Enqueue(request);
        lock (_lock)
        {
            _settings[request.Name] = request.Value;
        }
        return Task.FromResult(new SetSettingResponse { Name = request.Name, ValueJson = JsonSerializer.Serialize(request.Value), Path = "garage.json" });
    }

    public override Task<McpStatusResponse> McpStatus(McpStatusRequest request, ServerCallContext context) =>
        Task.FromResult(new McpStatusResponse
        {
            ServerCommand = "garage-mcp",
            Clients = { new McpClientInfo { Key = "claude-desktop", Label = "Claude Desktop", Path = @"C:\fake\claude_desktop_config.json", ConfigExists = true } },
        });

    public override Task<McpInstallResponse> McpInstall(McpInstallRequest request, ServerCallContext context)
    {
        Requests.Enqueue(request);
        return Task.FromResult(new McpInstallResponse { Message = $"connected {request.Target}" });
    }

    public override Task<SearchResponse> Search(SearchRequest request, ServerCallContext context)
    {
        Requests.Enqueue(request);
        return Task.FromResult(new SearchResponse
        {
            Hits =
            {
                new SearchHit { Rank = 1, Title = "The garage", Uri = @"C:\fake\notes\garage.md", Snippet = "The workbench is on the north wall", Text = "The workbench is on the north wall, under the pegboard.", Score = 0.9f, CorpusClass = "document", TrustTier = "authored", MatchedBy = "hybrid" },
                new SearchHit { Rank = 2, Title = "The car", Uri = @"C:\fake\notes\car.md", Snippet = "The oil was changed in March", Text = "The oil was changed in March.", Score = 0.4f, CorpusClass = "document", TrustTier = "authored", MatchedBy = "keyword" },
            },
            TotalHits = 2,
        });
    }

    public override Task<ListDocumentsResponse> ListDocuments(ListDocumentsRequest request, ServerCallContext context)
    {
        Requests.Enqueue(request);
        int limit = request.Limit > 0 ? request.Limit : 200;
        var response = new ListDocumentsResponse { TotalCount = DocumentCount };
        for (int id = request.Offset + 1; id <= Math.Min(DocumentCount, request.Offset + limit); id++)
        {
            response.Documents.Add(new DocumentSummary
            {
                Id = id,
                Uri = $@"C:\fake\notes\note-{id:D5}.md",
                Title = $"Note {id:D5}",
                SourceSlug = "notes",
                CorpusClass = "document",
                TrustTier = "authored",
                ChunkCount = 1,
                State = "ok",
            });
        }
        return Task.FromResult(response);
    }

    public override Task<FactStatsResponse> GetFactStats(FactStatsRequest request, ServerCallContext context) => Task.FromResult(new FactStatsResponse());

    public override Task<ListFactsResponse> ListFacts(ListFactsRequest request, ServerCallContext context) => Task.FromResult(new ListFactsResponse());

    public override Task<ListFactPromptsResponse> ListFactPrompts(ListFactPromptsRequest request, ServerCallContext context) => Task.FromResult(new ListFactPromptsResponse { ConfiguredJson = "[]" });

    public override Task<InitDbResponse> InitDb(InitDbRequest request, ServerCallContext context) => Task.FromResult(new InitDbResponse { Message = "schema ready" });
}

using Grpc.Core;

namespace Garage.App.Core.Tests.TestSupport;

/// <summary>
/// A GarageService client whose calls are answered by the test: set a handler per method, read
/// back the requests it received. A handler that throws an <see cref="RpcException"/> fails the call.
/// </summary>
internal sealed class FakeGarageClient : GarageService.GarageServiceClient
{
    public Func<SearchRequest, SearchResponse> OnSearch { get; set; } = _ => new SearchResponse();

    public Func<ListSourcesRequest, ListSourcesResponse> OnListSources { get; set; } = _ => new ListSourcesResponse();

    public Func<ListDocumentsRequest, ListDocumentsResponse> OnListDocuments { get; set; } = _ => new ListDocumentsResponse();

    public Func<GetDocumentRequest, GetDocumentResponse> OnGetDocument { get; set; } = _ => new GetDocumentResponse { Document = new DocumentDetail() };

    public Func<ListFactsRequest, ListFactsResponse> OnListFacts { get; set; } = _ => new ListFactsResponse();

    public Func<FactStatsRequest, FactStatsResponse> OnFactStats { get; set; } = _ => new FactStatsResponse();

    public Func<StatsRequest, StatsResponse> OnStats { get; set; } = _ => new StatsResponse();

    public Func<ListModelsRequest, ListModelsResponse> OnListModels { get; set; } = _ => new ListModelsResponse();

    public Func<RegisterModelRequest, RegisterModelResponse> OnRegisterModel { get; set; } = r => new RegisterModelResponse { Message = $"registered {r.Slug}" };

    public Func<SetDefaultModelRequest, SetDefaultModelResponse> OnSetDefaultModel { get; set; } = r => new SetDefaultModelResponse { Message = $"default is {r.Slug}" };

    public Func<DropModelRequest, DropModelResponse> OnDropModel { get; set; } = r => new DropModelResponse { Message = $"dropped {r.Slug}" };

    public Func<GetSettingRequest, GetSettingResponse> OnGetSetting { get; set; } = r => new GetSettingResponse { Name = r.Name, ValueJson = "\"\"" };

    public Func<SetSettingRequest, SetSettingResponse> OnSetSetting { get; set; } = r => new SetSettingResponse { Name = r.Name, ValueJson = System.Text.Json.JsonSerializer.Serialize(r.Value), Path = @"C:\Users\me\.garage.json" };

    public Func<McpStatusRequest, McpStatusResponse> OnMcpStatus { get; set; } = _ => new McpStatusResponse();

    public Func<McpInstallRequest, McpInstallResponse> OnMcpInstall { get; set; } = r => new McpInstallResponse { Message = $"connected {r.Target}" };

    public Func<McpUninstallRequest, McpUninstallResponse> OnMcpUninstall { get; set; } = r => new McpUninstallResponse { Removed = true, Message = $"disconnected {r.Target}" };

    public Func<AddSourceRequest, AddSourceResponse> OnAddSource { get; set; } = r => new AddSourceResponse { Slug = r.Slug, Root = r.Root, Created = true };

    public Func<RemoveSourceRequest, RemoveSourceResponse> OnRemoveSource { get; set; } = r => new RemoveSourceResponse { Slug = r.Slug };

    public Func<SyncSourcesRequest, SyncSourcesResponse> OnSyncSources { get; set; } = _ => new SyncSourcesResponse();

    public Func<InitDbRequest, InitDbResponse> OnInitDb { get; set; } = _ => new InitDbResponse { Message = "schema applied" };

    public Func<ScanRequest, IEnumerable<ScanStatus>> OnScan { get; set; } = _ => [];

    public Func<BackfillRequest, IEnumerable<BackfillStatus>> OnBackfill { get; set; } = _ => [];

    public Func<EnrichFactsRequest, IEnumerable<EnrichFactsStatus>> OnEnrichFacts { get; set; } = _ => [];

    public List<object> Requests { get; } = [];

    public override AsyncUnaryCall<ListModelsResponse> ListModelsAsync(ListModelsRequest request, CallOptions options) => Answer(request, OnListModels);

    public override AsyncUnaryCall<RegisterModelResponse> RegisterModelAsync(RegisterModelRequest request, CallOptions options) => Answer(request, OnRegisterModel);

    public override AsyncUnaryCall<SetDefaultModelResponse> SetDefaultModelAsync(SetDefaultModelRequest request, CallOptions options) => Answer(request, OnSetDefaultModel);

    public override AsyncUnaryCall<DropModelResponse> DropModelAsync(DropModelRequest request, CallOptions options) => Answer(request, OnDropModel);

    public override AsyncUnaryCall<GetSettingResponse> GetSettingAsync(GetSettingRequest request, CallOptions options) => Answer(request, OnGetSetting);

    public override AsyncUnaryCall<SetSettingResponse> SetSettingAsync(SetSettingRequest request, CallOptions options) => Answer(request, OnSetSetting);

    public override AsyncUnaryCall<McpStatusResponse> McpStatusAsync(McpStatusRequest request, CallOptions options) => Answer(request, OnMcpStatus);

    public override AsyncUnaryCall<McpInstallResponse> McpInstallAsync(McpInstallRequest request, CallOptions options) => Answer(request, OnMcpInstall);

    public override AsyncUnaryCall<McpUninstallResponse> McpUninstallAsync(McpUninstallRequest request, CallOptions options) => Answer(request, OnMcpUninstall);

    public override AsyncUnaryCall<AddSourceResponse> AddSourceAsync(AddSourceRequest request, CallOptions options) => Answer(request, OnAddSource);

    public override AsyncUnaryCall<RemoveSourceResponse> RemoveSourceAsync(RemoveSourceRequest request, CallOptions options) => Answer(request, OnRemoveSource);

    public override AsyncUnaryCall<SyncSourcesResponse> SyncSourcesAsync(SyncSourcesRequest request, CallOptions options) => Answer(request, OnSyncSources);

    public override AsyncUnaryCall<InitDbResponse> InitDbAsync(InitDbRequest request, CallOptions options) => Answer(request, OnInitDb);

    public override AsyncServerStreamingCall<ScanStatus> Scan(ScanRequest request, CallOptions options) => Stream(request, OnScan, options);

    public override AsyncServerStreamingCall<BackfillStatus> Backfill(BackfillRequest request, CallOptions options) => Stream(request, OnBackfill, options);

    public override AsyncServerStreamingCall<EnrichFactsStatus> EnrichFacts(EnrichFactsRequest request, CallOptions options) => Stream(request, OnEnrichFacts, options);

    private AsyncServerStreamingCall<T> Stream<TRequest, T>(TRequest request, Func<TRequest, IEnumerable<T>> steps, CallOptions options)
        where TRequest : class
    {
        Requests.Add(request);
        return new AsyncServerStreamingCall<T>(
            new StepReader<T>(steps(request), options.CancellationToken), Task.FromResult(new Metadata()), () => Status.DefaultSuccess, () => [], () => { });
    }

    /// <summary>Replays the steps a test scripted; honours cancellation between steps.</summary>
    private sealed class StepReader<T>(IEnumerable<T> steps, CancellationToken token) : IAsyncStreamReader<T>
    {
        private readonly IEnumerator<T> _steps = steps.GetEnumerator();

        public T Current => _steps.Current;

        public Task<bool> MoveNext(CancellationToken cancellationToken)
        {
            token.ThrowIfCancellationRequested();
            cancellationToken.ThrowIfCancellationRequested();
            return Task.FromResult(_steps.MoveNext());
        }
    }

    public override AsyncUnaryCall<SearchResponse> SearchAsync(SearchRequest request, CallOptions options) => Answer(request, OnSearch);

    public override AsyncUnaryCall<ListSourcesResponse> ListSourcesAsync(ListSourcesRequest request, CallOptions options) => Answer(request, OnListSources);

    public override AsyncUnaryCall<ListDocumentsResponse> ListDocumentsAsync(ListDocumentsRequest request, CallOptions options) => Answer(request, OnListDocuments);

    public override AsyncUnaryCall<GetDocumentResponse> GetDocumentAsync(GetDocumentRequest request, CallOptions options) => Answer(request, OnGetDocument);

    public override AsyncUnaryCall<ListFactsResponse> ListFactsAsync(ListFactsRequest request, CallOptions options) => Answer(request, OnListFacts);

    public override AsyncUnaryCall<FactStatsResponse> GetFactStatsAsync(FactStatsRequest request, CallOptions options) => Answer(request, OnFactStats);

    public override AsyncUnaryCall<StatsResponse> GetStatsAsync(StatsRequest request, CallOptions options) => Answer(request, OnStats);

    public static RpcException Failure(StatusCode code, string detail) => new(new Status(code, detail));

    private AsyncUnaryCall<TResponse> Answer<TRequest, TResponse>(TRequest request, Func<TRequest, TResponse> handler)
        where TRequest : class
    {
        Requests.Add(request);
        Task<TResponse> response;
        try
        {
            response = Task.FromResult(handler(request));
        }
        catch (RpcException ex)
        {
            response = Task.FromException<TResponse>(ex);
        }
        return new AsyncUnaryCall<TResponse>(response, Task.FromResult(new Metadata()), () => Status.DefaultSuccess, () => [], () => { });
    }
}

/// <summary>Runs a block with a fixed culture, restoring the previous one (number formats in wording tests).</summary>
internal sealed class CultureScope : IDisposable
{
    private readonly System.Globalization.CultureInfo _previous = System.Globalization.CultureInfo.CurrentCulture;

    public CultureScope(string name) =>
        System.Globalization.CultureInfo.CurrentCulture = System.Globalization.CultureInfo.GetCultureInfo(name);

    public void Dispose() => System.Globalization.CultureInfo.CurrentCulture = _previous;
}

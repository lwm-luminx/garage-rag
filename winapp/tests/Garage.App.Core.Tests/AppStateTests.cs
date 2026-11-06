using Garage.App.Core.Backend;
using Garage.App.Core.Presentation;
using Garage.App.Core.State;
using Garage.App.Core.Threading;
using Grpc.Core;

namespace Garage.App.Core.Tests;

public sealed class AppStateTests
{
    private static readonly DevBackend WithToken = DevBackend.FromEnvironment(new Dictionary<string, string?> { ["GARAGE_GRPC_TOKEN"] = "t" });
    private static readonly DevBackend WithoutToken = DevBackend.FromEnvironment(new Dictionary<string, string?>());

    [Fact]
    public async Task A_reachable_server_fills_in_version_and_counts()
    {
        var client = new FakeClient
        {
            Status = new StatusResponse { Version = "1.5.0", DbStatus = "ok", IsReady = true },
            Stats = new StatsResponse { Documents = 1204, Chunks = 1, Sources = 3, Models = 2 },
        };
        var state = new AppState(WithToken, client, InlineDispatcher.Instance);
        List<BackendConnection> seen = [];
        state.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(AppState.Connection))
            {
                seen.Add(state.Connection);
            }
        };

        await state.RefreshAsync(TestContext.Current.CancellationToken);

        Assert.Equal([BackendConnection.Connecting, BackendConnection.Connected], seen);
        Assert.Equal("1.5.0", state.ServerVersion);
        Assert.Equal(new CorpusCounts(1204, 1, 3, 2), state.Counts);

        ConnectionPresentation shown = ConnectionPresentation.From(state);
        Assert.Equal("Connected to Garage 1.5.0", shown.Title);
        Assert.Equal(StatusSeverity.Success, shown.Severity);
        Assert.Contains("1 chunk ·", shown.Detail, StringComparison.Ordinal);
        Assert.Contains("3 sources", shown.Detail, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Without_a_token_the_connection_is_read_only()
    {
        var client = new FakeClient { Status = new StatusResponse { Version = "1.5.0" }, Stats = new StatsResponse() };
        var state = new AppState(WithoutToken, client, InlineDispatcher.Instance);
        await state.RefreshAsync(TestContext.Current.CancellationToken);

        ConnectionPresentation shown = ConnectionPresentation.From(state);
        Assert.Equal(StatusSeverity.Warning, shown.Severity);
        Assert.Contains("read-only", shown.Detail, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData(StatusCode.Unavailable, "not running or not reachable")]
    [InlineData(StatusCode.Unauthenticated, "rejected the connection token")]
    [InlineData(StatusCode.DeadlineExceeded, "did not answer in time")]
    [InlineData(StatusCode.Internal, "database is down")]
    public async Task An_unreachable_or_refusing_server_is_unavailable_with_a_reason(StatusCode code, string reason)
    {
        var client = new FakeClient { Failure = new RpcException(new Status(code, "database is down")) };
        var state = new AppState(WithToken, client, InlineDispatcher.Instance);

        await state.RefreshAsync(TestContext.Current.CancellationToken);

        Assert.Equal(BackendConnection.Unavailable, state.Connection);
        Assert.Contains(reason, state.ConnectionError, StringComparison.Ordinal);
        ConnectionPresentation shown = ConnectionPresentation.From(state);
        Assert.Equal("Garage isn't reachable", shown.Title);
        Assert.Equal(StatusSeverity.Error, shown.Severity);
    }

    [Fact]
    public async Task Recovers_once_the_server_answers()
    {
        var client = new FakeClient { Failure = new RpcException(new Status(StatusCode.Unavailable, "")) };
        var state = new AppState(WithToken, client, InlineDispatcher.Instance);
        await state.RefreshAsync(TestContext.Current.CancellationToken);
        Assert.Equal(BackendConnection.Unavailable, state.Connection);

        client.Failure = null;
        client.Status = new StatusResponse { Version = "1.5.0" };
        client.Stats = new StatsResponse();
        await state.RefreshAsync(TestContext.Current.CancellationToken);

        Assert.Equal(BackendConnection.Connected, state.Connection);
        Assert.Null(state.ConnectionError);
    }

    [Fact]
    public void Before_the_first_refresh_the_backend_is_described()
    {
        var state = new AppState(WithToken, new FakeClient(), InlineDispatcher.Instance);
        ConnectionPresentation shown = ConnectionPresentation.From(state);
        Assert.Equal("Not connected yet", shown.Title);
        Assert.Contains("127.0.0.1:50051", shown.Detail, StringComparison.Ordinal);
    }

    /// <summary>A GarageService client that answers GetStatus and GetStats from its properties.</summary>
    private sealed class FakeClient : GarageService.GarageServiceClient
    {
        public StatusResponse Status { get; set; } = new();

        public StatsResponse Stats { get; set; } = new();

        public RpcException? Failure { get; set; }

        public override AsyncUnaryCall<StatusResponse> GetStatusAsync(StatusRequest request, CallOptions options) => Answer(Status);

        public override AsyncUnaryCall<StatsResponse> GetStatsAsync(StatsRequest request, CallOptions options) => Answer(Stats);

        private AsyncUnaryCall<T> Answer<T>(T response) => new(
            Failure is null ? Task.FromResult(response) : Task.FromException<T>(Failure),
            Task.FromResult(new Metadata()),
            () => global::Grpc.Core.Status.DefaultSuccess,
            () => [],
            () => { });
    }
}

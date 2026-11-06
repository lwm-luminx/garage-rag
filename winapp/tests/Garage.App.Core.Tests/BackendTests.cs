using Garage.App.Core.Backend;
using Garage.Grpc;
using Grpc.Core;

namespace Garage.App.Core.Tests;

public sealed class BackendTests
{
    private static DevBackend From(params (string Name, string? Value)[] variables) =>
        DevBackend.FromEnvironment(variables.ToDictionary(v => v.Name, v => v.Value));

    [Fact]
    public void Defaults_to_garage_serve_on_loopback_without_a_token()
    {
        DevBackend backend = From();
        Assert.Equal(new Uri("http://127.0.0.1:50051/"), backend.Grpc.Address);
        Assert.Null(backend.Grpc.Token);
        Assert.Equal(DevBackend.DefaultMcp, backend.Mcp);
        Assert.Contains("no token", backend.Description, StringComparison.Ordinal);
    }

    [Fact]
    public void Reads_the_python_sides_variable_names()
    {
        DevBackend backend = From(
            ("GARAGE_GRPC_HOST", "localhost"),
            ("GARAGE_GRPC_PORT", " 50999 "),
            ("GARAGE_GRPC_TOKEN", "s3cret"),
            ("GARAGE_MCP_URL", "http://127.0.0.1:9000/mcp"));
        Assert.Equal(new Uri("http://localhost:50999/"), backend.Grpc.Address);
        Assert.Equal("s3cret", backend.Grpc.Token);
        Assert.Equal(new Uri("http://127.0.0.1:9000/mcp"), backend.Mcp);
        Assert.DoesNotContain("no token", backend.Description, StringComparison.Ordinal);
    }

    [Fact]
    public void Blank_variables_count_as_unset()
    {
        DevBackend backend = From(("GARAGE_GRPC_TOKEN", "   "), ("GARAGE_GRPC_PORT", ""));
        Assert.Null(backend.Grpc.Token);
        Assert.Equal(DevBackend.DefaultPort, backend.Grpc.Address.Port);
    }

    [Theory]
    [InlineData("GARAGE_GRPC_PORT", "not-a-port")]
    [InlineData("GARAGE_GRPC_PORT", "70000")]
    [InlineData("GARAGE_GRPC_PORT", "-1")]
    [InlineData("GARAGE_MCP_URL", "ftp://127.0.0.1/mcp")]
    [InlineData("GARAGE_MCP_URL", "mcp")]
    public void Unusable_values_are_rejected_by_name(string name, string value)
    {
        ArgumentException error = Assert.Throws<ArgumentException>(() => From((name, value)));
        Assert.Contains(name, error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void The_token_never_appears_in_ToString()
    {
        var endpoint = new GarageEndpoint(new Uri("http://127.0.0.1:50051"), "s3cret");
        Assert.DoesNotContain("s3cret", endpoint.ToString(), StringComparison.Ordinal);
        Assert.DoesNotContain("s3cret", From(("GARAGE_GRPC_TOKEN", "s3cret")).Description, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Every_call_carries_the_token_replacing_any_other()
    {
        var capture = new CapturingInvoker();
        var endpoint = new GarageEndpoint(new Uri("http://127.0.0.1:50051"), "s3cret");
        GarageService.GarageServiceClient client = endpoint.CreateClient(new CapturingChannel(capture));

        await client.PingAsync(new PingRequest(), new Metadata { { GarageEndpoint.TokenMetadataKey, "stale" }, { "other", "kept" } }, cancellationToken: TestContext.Current.CancellationToken);

        Metadata sent = capture.LastHeaders!;
        Assert.Equal(["s3cret"], sent.Where(e => e.Key == GarageEndpoint.TokenMetadataKey).Select(e => e.Value));
        Assert.Equal("kept", sent.GetValue("other"));
    }

    [Fact]
    public async Task No_token_means_no_header()
    {
        var capture = new CapturingInvoker();
        var endpoint = new GarageEndpoint(new Uri("http://127.0.0.1:50051"), null);
        GarageService.GarageServiceClient client = endpoint.CreateClient(new CapturingChannel(capture));

        await client.PingAsync(new PingRequest(), cancellationToken: TestContext.Current.CancellationToken);

        Assert.DoesNotContain(capture.LastHeaders ?? [], e => e.Key == GarageEndpoint.TokenMetadataKey);
    }

    /// <summary>A channel whose calls go to <paramref name="invoker"/>, with no network.</summary>
    private sealed class CapturingChannel(CallInvoker invoker) : ChannelBase("capture")
    {
        public override CallInvoker CreateCallInvoker() => invoker;
    }

    /// <summary>A call invoker that records the headers of the last unary call and answers it empty.</summary>
    private sealed class CapturingInvoker : CallInvoker
    {
        public Metadata? LastHeaders { get; private set; }

        public override AsyncUnaryCall<TResponse> AsyncUnaryCall<TRequest, TResponse>(
            Method<TRequest, TResponse> method, string? host, CallOptions options, TRequest request)
        {
            LastHeaders = options.Headers;
            TResponse response = Activator.CreateInstance<TResponse>();
            return new AsyncUnaryCall<TResponse>(
                Task.FromResult(response), Task.FromResult(new Metadata()), () => Status.DefaultSuccess, () => [], () => { });
        }

        public override TResponse BlockingUnaryCall<TRequest, TResponse>(
            Method<TRequest, TResponse> method, string? host, CallOptions options, TRequest request) =>
            throw new NotSupportedException();

        public override AsyncServerStreamingCall<TResponse> AsyncServerStreamingCall<TRequest, TResponse>(
            Method<TRequest, TResponse> method, string? host, CallOptions options, TRequest request) =>
            throw new NotSupportedException();

        public override AsyncClientStreamingCall<TRequest, TResponse> AsyncClientStreamingCall<TRequest, TResponse>(
            Method<TRequest, TResponse> method, string? host, CallOptions options) =>
            throw new NotSupportedException();

        public override AsyncDuplexStreamingCall<TRequest, TResponse> AsyncDuplexStreamingCall<TRequest, TResponse>(
            Method<TRequest, TResponse> method, string? host, CallOptions options) =>
            throw new NotSupportedException();
    }
}

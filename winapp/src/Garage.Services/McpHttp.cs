using System.Text.Json.Nodes;
using Garage.Services.Native;

namespace Garage.Services;

/// <summary>
/// The MCP service's work: the Rust MCP server's streamable-HTTP transport (<c>rust/garage-mcp</c>,
/// through <c>garage_mcp_ffi.dll</c>) at <c>http://127.0.0.1:&lt;port&gt;/mcp</c>, over the backend on
/// loopback, as GarageMCPServerService runs it on the Mac. Loopback only; it is the app's only listener
/// an assistant connects to, and runs only while the MCP Server page's HTTP switch is on.
/// </summary>
internal sealed unsafe class McpHttp(ServiceRuntime runtime) : IDisposable
{
    private readonly ModelServerHost _host = new(runtime.Log);
    private nint _server;

    /// <summary>Whether the server is serving.</summary>
    public bool IsRunning => _server != 0 && GarageNative.McpHttpIsRunning(_server);

    /// <summary>Starts the server; throws with the server's reason when it cannot bind or start.</summary>
    public void Start()
    {
        var request = new JsonObject
        {
            ["grpc"] = new JsonObject
            {
                ["host"] = "127.0.0.1",
                ["port"] = runtime.Options.GrpcPort,
                ["token"] = Environment.GetEnvironmentVariable("GARAGE_GRPC_TOKEN") ?? "",
            },
            ["http"] = new JsonObject { ["host"] = "127.0.0.1", ["port"] = runtime.Options.McpPort, ["path"] = "/mcp" },
        };
        GarageNative.McpHost host = _host.McpHost;
        byte* text = GarageNative.Request(request);
        byte* result = null;
        nint server = 0;
        int status;
        try
        {
            status = GarageNative.McpHttpStart(text, &host, &server, &result);
        }
        finally
        {
            NativeString.Free(text);
        }
        JsonObject reply = GarageNative.TakeResult(status, result, &GarageNative.McpStringFree, $"the MCP server did not start on 127.0.0.1:{runtime.Options.McpPort}");
        _server = server;
        runtime.Log.Info($"MCP listening on http://{reply["address"]?.GetValue<string>() ?? $"127.0.0.1:{runtime.Options.McpPort}"}{reply["path"]?.GetValue<string>() ?? "/mcp"}");
    }

    /// <summary>Stops the server; requests in flight get up to ten seconds.</summary>
    public void Stop()
    {
        nint server = Interlocked.Exchange(ref _server, 0);
        if (server == 0)
        {
            return;
        }
        GarageNative.McpHttpStop(server);
        runtime.Log.Info("MCP server stopped");
    }

    /// <inheritdoc/>
    public void Dispose()
    {
        Stop();
        _host.Dispose();
    }
}

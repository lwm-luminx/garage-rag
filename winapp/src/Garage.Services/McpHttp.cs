using Garage.Python;
using Py = Garage.Python.Python;

namespace Garage.Services;

/// <summary>
/// The MCP service's work: <c>garage_rag.mcp_server.server.start_background_server</c>, the
/// streamable-HTTP server at <c>http://127.0.0.1:&lt;port&gt;/mcp</c>, as GarageMCPServerService
/// runs it on the Mac. Loopback only; it is the app's only listener an assistant connects to, and
/// runs only while the MCP Server page's HTTP switch is on.
/// </summary>
internal sealed class McpHttp(ServiceRuntime runtime) : IDisposable
{
    private const string Module = "garage_rag.mcp_server.server";

    private bool _started;

    /// <summary>Starts the server; throws with Python's reason when it cannot bind or start.</summary>
    public void Start()
    {
        using PythonObject server = Py.Import(Module);
        using PythonObject started = server.Invoke("start_background_server", [], [new("host", "127.0.0.1"), new("port", runtime.Options.McpPort)]);
        if (!started.IsTrue())
        {
            using PythonObject error = server.Invoke("background_server_error");
            throw new InvalidOperationException(error.IsTrue() ? error.As<string>() : $"the MCP server did not start on 127.0.0.1:{runtime.Options.McpPort}");
        }
        _started = true;
        runtime.Log.Info($"MCP listening on http://127.0.0.1:{runtime.Options.McpPort}/mcp");
    }

    /// <summary>Stops the server.</summary>
    public void Stop()
    {
        if (!_started)
        {
            return;
        }
        try
        {
            using PythonObject server = Py.Import(Module);
            server.Invoke("stop_background_server").Dispose();
            runtime.Log.Info("MCP server stopped");
        }
        catch (PythonException ex)
        {
            runtime.Log.Error($"The MCP server did not stop cleanly: {PythonHost.Describe(ex)}");
        }
        _started = false;
    }

    /// <inheritdoc/>
    public void Dispose() => Stop();
}

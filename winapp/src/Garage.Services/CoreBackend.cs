using Garage.Python;
using Py = Garage.Python.Python;

namespace Garage.Services;

/// <summary>
/// The core service's work: <c>garage_rag.service.server.create_grpc_server</c> on loopback, with the
/// app's per-launch token (<c>GARAGE_GRPC_TOKEN</c>, inherited), as GarageXPCService starts it on the
/// Mac. The app and the ingest service reach every operation and the database facade through it.
/// </summary>
internal sealed class CoreBackend(ServiceRuntime runtime) : IDisposable
{
    private PythonObject? _server;

    /// <summary>Starts the server; throws with Python's reason when it cannot.</summary>
    public void Start()
    {
        if (string.IsNullOrEmpty(Environment.GetEnvironmentVariable("GARAGE_GRPC_TOKEN")))
        {
            // Without a token every account on the machine could call it, and the config-changing
            // methods would be refused over TCP anyway (service/auth.py).
            throw new InvalidOperationException("GARAGE_GRPC_TOKEN is not set; the backend will not listen without it");
        }
        using PythonObject server = Py.Import("garage_rag.service.server");
        using PythonObject created = server.Invoke("create_grpc_server", [], [new("host", "127.0.0.1"), new("port", runtime.Options.GrpcPort)]);
        _server = created[0];
        _server.Invoke("start").Dispose();
        runtime.Log.Info($"GarageService listening on 127.0.0.1:{runtime.Options.GrpcPort}");
    }

    /// <summary>Stops the server, letting calls in flight finish for up to two seconds.</summary>
    public void Stop()
    {
        if (_server is null)
        {
            return;
        }
        try
        {
            using PythonObject stopped = _server.Invoke("stop", 2.0);
            stopped.Invoke("wait", 5.0).Dispose();
            runtime.Log.Info("GarageService stopped");
        }
        catch (PythonException ex)
        {
            runtime.Log.Error($"GarageService did not stop cleanly: {PythonHost.Describe(ex)}");
        }
        _server.Dispose();
        _server = null;
    }

    /// <inheritdoc/>
    public void Dispose() => Stop();
}

using System.Text.Json.Nodes;
using Garage.Services.Native;

namespace Garage.Services;

/// <summary>
/// The core service's work: GarageService (<c>rust/garage-service</c>, through <c>garage_service_ffi.dll</c>)
/// on loopback, behind the app's per-launch token (<c>GARAGE_GRPC_TOKEN</c>, inherited), as
/// GarageXPCService runs it on the Mac. It runs on the data folder's <c>garage.json</c> (written there
/// by the first <c>SetSetting</c>) and applies the shipped schema on <c>InitDb</c>. The app and the
/// ingest service reach every operation and the database facade through it.
/// </summary>
internal sealed unsafe class CoreBackend(ServiceRuntime runtime) : IDisposable
{
    private readonly ModelServerHost _host = new(runtime.Log);
    private nint _server;

    /// <summary>Whether the server is serving.</summary>
    public bool IsRunning => _server != 0 && GarageNative.ServiceIsRunning(_server);

    /// <summary>Starts the server; throws with the service's reason when it cannot.</summary>
    public void Start()
    {
        string token = Environment.GetEnvironmentVariable("GARAGE_GRPC_TOKEN") ?? "";
        if (string.IsNullOrEmpty(token))
        {
            // Without a token every account on the machine could call it, and the config-changing
            // methods would be refused over TCP anyway (auth.rs).
            throw new InvalidOperationException("GARAGE_GRPC_TOKEN is not set; the backend will not listen without it");
        }
        var request = new JsonObject
        {
            ["endpoint"] = new JsonObject { ["host"] = "127.0.0.1", ["port"] = runtime.Options.GrpcPort },
            ["token"] = token,
            ["config"] = Path.Combine(runtime.Options.DataDirectory, "garage.json"),
        };
        if (runtime.Options.SchemaDirectory is { } schema)
        {
            request["sql_dir"] = schema;
        }
        GarageNative.ServiceHost host = _host.ServiceHost;
        byte* text = GarageNative.Request(request);
        byte* result = null;
        nint server = 0;
        int status;
        try
        {
            status = GarageNative.ServiceStart(text, &host, &server, &result);
        }
        finally
        {
            NativeString.Free(text);
        }
        JsonObject reply = GarageNative.TakeResult(status, result, &GarageNative.ServiceStringFree, "GarageService did not start");
        _server = server;
        runtime.Log.Info($"GarageService listening on {reply["endpoint"]?.GetValue<string>() ?? $"127.0.0.1:{runtime.Options.GrpcPort}"} (version {reply["version"]?.GetValue<string>()})");
    }

    /// <summary>Stops the server, letting calls in flight finish for up to two seconds.</summary>
    public void Stop()
    {
        nint server = Interlocked.Exchange(ref _server, 0);
        if (server == 0)
        {
            return;
        }
        GarageNative.ServiceStop(server, 2.0);
        runtime.Log.Info("GarageService stopped");
    }

    /// <inheritdoc/>
    public void Dispose()
    {
        Stop();
        _host.Dispose();
    }
}

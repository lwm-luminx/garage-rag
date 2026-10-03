using System.Net;
using System.Net.Sockets;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using Garage.Python.Interop;

namespace Garage.Python.Tests;

/// <summary>
/// The host side of the C contracts <c>garage_rag</c> defines for the process that embeds it,
/// exercised against the real Python modules: what the Swift <c>LlamaInferenceBridge</c> and
/// <c>LlamaModelLoaderBridge</c> provide on macOS, provided from C#.
/// </summary>
/// <remarks>Tests in one class run one at a time, so the static host state below is not shared.</remarks>
public sealed unsafe class GarageHostContractTests(PythonFixture fixture)
{
    private static int _allocations;
    private static int _releases;
    private static string? _lastRequest;
    private static bool _failRequests;

    // ---- garage_rag.inference.bridge ------------------------------------------------------

    [Fact]
    public void Inference_bridge_carries_a_request_and_its_reply()
    {
        fixture.RequireGarage();
        ResetBridgeState();
        InstallInferenceBridge();
        try
        {
            using PythonObject globals = Python.Exec("""
                from garage_rag.inference import bridge
                status, body = bridge.current()("POST", "/v1/embeddings", b'{"input": "h\xc3\xa9"}', 5.0)
                """);
            Assert.Equal(200L, globals["status"].As<long>());
            Assert.Equal("""{"echo": "POST /v1/embeddings {"input": "hé"}"}""",
                Encoding.UTF8.GetString(globals["body"].As<byte[]>()));
            Assert.Equal("POST /v1/embeddings timeout=5", _lastRequest);
            Assert.Equal(1, _allocations);
            Assert.Equal(_allocations, _releases);  // Python released the reply through the host
        }
        finally
        {
            ClearInferenceBridge();
        }
    }

    [Fact]
    public void Inference_bridge_failure_raises_bridge_error_with_the_host_message()
    {
        fixture.RequireGarage();
        ResetBridgeState();
        _failRequests = true;
        InstallInferenceBridge();
        try
        {
            using PythonObject bridge = Python.Import("garage_rag.inference.bridge");
            using PythonObject request = bridge.Invoke("current");
            PythonException error = Assert.Throws<PythonException>(
                () => request.Call("GET", "/health", null, 1.0).Dispose());
            Assert.Equal("garage_rag.inference.bridge.BridgeError", error.PythonType);
            Assert.Equal("Garage.Llama is not running", error.PythonMessage);
            Assert.Equal(_allocations, _releases);
        }
        finally
        {
            ClearInferenceBridge();
        }
    }

    private static void InstallInferenceBridge()
    {
        using PythonObject bridge = Python.Import("garage_rag.inference.bridge");
        bridge.Invoke(
            "install",
            (nint)(delegate* unmanaged[Cdecl]<byte*, byte*, byte*, double, int*, nint*, int>)&BridgeRequest,
            (nint)(delegate* unmanaged[Cdecl]<nint, void>)&BridgeRelease).Dispose();
    }

    private static void ClearInferenceBridge()
    {
        using PythonObject bridge = Python.Import("garage_rag.inference.bridge");
        bridge.Invoke("set_bridge", [null], null).Dispose();
    }

    // int32 request(const char *method, const char *path, const char *body, double timeout, int32 *status, char **reply)
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int BridgeRequest(byte* method, byte* path, byte* body, double timeout, int* status, nint* reply)
    {
        string m = NativeUtf8.Read((nint)method) ?? "";
        string p = NativeUtf8.Read((nint)path) ?? "";
        string b = NativeUtf8.Read((nint)body) ?? "";
        _lastRequest = $"{m} {p} timeout={timeout}";
        Interlocked.Increment(ref _allocations);
        if (_failRequests)
        {
            *reply = NativeUtf8.Duplicate("Garage.Llama is not running");
            return 1;
        }
        *status = 200;
        *reply = NativeUtf8.Duplicate($$"""{"echo": "{{m}} {{p}} {{b}}"}""");
        return 0;
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static void BridgeRelease(nint reply)
    {
        Interlocked.Increment(ref _releases);
        NativeUtf8.Free(reply);
    }

    private static void ResetBridgeState()
    {
        _allocations = 0;
        _releases = 0;
        _lastRequest = null;
        _failRequests = false;
    }

    // ---- garage_rag.xpc.host (model loader) -----------------------------------------------

    [Fact]
    public void Model_loader_reports_a_resident_model()
    {
        fixture.RequireGarage();
        InstallModelLoader();
        try
        {
            using PythonObject host = Python.Import("garage_rag.xpc.host");
            using PythonObject message = host.Invoke("ensure_model", ["nomic-embed-text"], [new("allow_remote", false)]);
            Assert.Equal("nomic-embed-text is resident", message.As<string>());
        }
        finally
        {
            ClearModelLoader();
        }
    }

    [Fact]
    public void Model_loader_failure_raises_model_load_error()
    {
        fixture.RequireGarage();
        InstallModelLoader();
        try
        {
            using PythonObject host = Python.Import("garage_rag.xpc.host");
            PythonException error = Assert.Throws<PythonException>(
                () => host.Invoke("ensure_model", ["missing-model"], [new("allow_remote", false)]).Dispose());
            Assert.Equal("garage_rag.xpc.host.ModelLoadError", error.PythonType);
            Assert.Equal("missing-model is not in the catalog", error.PythonMessage);
        }
        finally
        {
            ClearModelLoader();
        }
    }

    private static void InstallModelLoader()
    {
        using PythonObject host = Python.Import("garage_rag.xpc.host");
        host.Invoke("install_model_loader", (nint)(delegate* unmanaged[Cdecl]<byte*, byte*, nuint, int>)&LoadModel).Dispose();
    }

    private static void ClearModelLoader()
    {
        using PythonObject host = Python.Import("garage_rag.xpc.host");
        host.Invoke("set_model_loader", [null], null).Dispose();
    }

    // int32 loader(const char *alias, char *message, size_t capacity)
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int LoadModel(byte* alias, byte* message, nuint capacity)
    {
        string name = NativeUtf8.Read((nint)alias) ?? "";
        bool known = name == "nomic-embed-text";
        NativeUtf8.WriteTruncated(known ? $"{name} is resident" : $"{name} is not in the catalog", (nint)message, capacity);
        return known ? 0 : 1;
    }

    // ---- garage_rag.service.server --------------------------------------------------------

    [Fact]
    public void Serves_the_garage_grpc_facade_from_the_embedded_interpreter()
    {
        fixture.RequireGarage();
        int port = FreeLoopbackPort();
        using PythonObject serverModule = Python.Import("garage_rag.service.server");
        using PythonObject created = serverModule.Invoke(
            "create_grpc_server", [], [new("host", "127.0.0.1"), new("port", port)]);
        using PythonObject server = created[0];
        server.Invoke("start").Dispose();
        try
        {
            // The server's worker threads need the GIL while this thread waits on the reply:
            // the round trip only completes because the host released it after start-up.
            using PythonObject clientModule = Python.Import("garage_rag.service.client");
            using PythonObject client = clientModule.Invoke(
                "GarageClient", [], [new("host", "127.0.0.1"), new("port", port), new("in_process", false)]);
            try
            {
                using PythonObject reply = client.Invoke("ping", "from C#");
                Assert.Contains("from C#", reply.GetAttr("message").As<string>(), StringComparison.Ordinal);
            }
            finally
            {
                client.Invoke("close").Dispose();
            }
        }
        finally
        {
            server.Invoke("stop", 0).Invoke("wait").Dispose();
        }
    }

    private static int FreeLoopbackPort()
    {
        using TcpListener listener = new(IPAddress.Loopback, 0);
        listener.Start();
        return ((IPEndPoint)listener.LocalEndpoint).Port;
    }
}

using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text.Json.Nodes;
using Garage.Services.Native;

namespace Garage.Services;

/// <summary>
/// What the Rust service and MCP server ask of the process they run in: an HTTP request to a model
/// server the service's egress rules already approved (Ollama, LM Studio), sent to exactly its URL
/// with no proxy and no redirect followed, as the Mac's <c>GarageEmbedWorkerHost</c> sends it. A
/// <c>llama_xpc</c> request, a model load and the image models are the Mac app's LlamaXPCService
/// and image service, which Windows does not have yet (windows.md §2.4): they are answered as
/// unavailable, and the service reports that to its caller.
/// </summary>
/// <remarks>
/// The entries below are called from the libraries' own threads, several at once, so each call
/// is synchronous and self-contained; an exception never crosses back into the native frame.
/// </remarks>
internal sealed unsafe class ModelServerHost : IDisposable
{
    private static readonly HttpClient Client = new(new SocketsHttpHandler
    {
        UseProxy = false,
        AllowAutoRedirect = false,
        ConnectTimeout = TimeSpan.FromSeconds(10),
        PooledConnectionLifetime = TimeSpan.FromMinutes(5),
    })
    {
        // Each request carries its own timeout.
        Timeout = Timeout.InfiniteTimeSpan,
    };

    private readonly ServiceLog _log;
    private GCHandle _self;

    public ModelServerHost(ServiceLog log)
    {
        _log = log;
        _self = GCHandle.Alloc(this);
    }

    /// <summary>The context the entries get back: this host.</summary>
    private void* Context => (void*)GCHandle.ToIntPtr(_self);

    /// <summary>The struct GarageService calls through. Valid while this host is.</summary>
    public GarageNative.ServiceHost ServiceHost => new()
    {
        Context = Context,
        Http = &HttpEntry,
        EnsureLlamaModel = &UnavailableEntry,
        EmbedImages = &UnavailableEntry,
        EmbedImageTexts = &UnavailableEntry,
        Release = &ReleaseEntry,
    };

    /// <summary>The struct the MCP server calls through. Valid while this host is.</summary>
    public GarageNative.McpHost McpHost => new()
    {
        Context = Context,
        Http = &HttpEntry,
        EnsureLlamaModel = &UnavailableEntry,
        Release = &ReleaseEntry,
    };

    /// <inheritdoc/>
    public void Dispose()
    {
        if (_self.IsAllocated)
        {
            _self.Free();
        }
    }

    /// <summary>
    /// Sends one approved request: <c>{"backend", "method", "url", "path", "headers": [[name, value]],
    /// "body", "timeout"}</c> to <c>{"status", "body"}</c>. Throws when no reply came.
    /// </summary>
    public string Http(JsonObject request)
    {
        string backend = request["backend"]?.GetValue<string>() ?? "";
        if (backend == "llama_xpc")
        {
            throw new InvalidOperationException("the llama_xpc provider is the Mac app's LlamaXPCService, which Windows does not have yet; use Ollama or LM Studio");
        }
        string url = request["url"]?.GetValue<string>() ?? throw new InvalidOperationException("the request names no url");
        string method = request["method"]?.GetValue<string>() ?? "GET";
        double timeout = request["timeout"]?.GetValue<double>() ?? 60;
        using var message = new HttpRequestMessage(new HttpMethod(method), url);
        string body = request["body"]?.GetValue<string>() ?? "";
        if (body.Length > 0 || method is "POST" or "PUT" or "PATCH")
        {
            message.Content = new StringContent(body);
            message.Content.Headers.ContentType = null;
        }
        if (request["headers"] is JsonArray headers)
        {
            foreach (JsonNode? pair in headers)
            {
                if (pair is JsonArray { Count: 2 } header && header[0]?.GetValue<string>() is { } name && header[1]?.GetValue<string>() is { } value)
                {
                    if (name.StartsWith("content-", StringComparison.OrdinalIgnoreCase) && message.Content is not null)
                    {
                        message.Content.Headers.TryAddWithoutValidation(name, value);
                    }
                    else
                    {
                        message.Headers.TryAddWithoutValidation(name, value);
                    }
                }
            }
        }
        using var cancel = new CancellationTokenSource(TimeSpan.FromSeconds(Math.Max(1, timeout)));
        using HttpResponseMessage response = Client.Send(message, HttpCompletionOption.ResponseContentRead, cancel.Token);
        using Stream stream = response.Content.ReadAsStream(cancel.Token);
        using var reader = new StreamReader(stream);
        return new JsonObject
        {
            ["status"] = (int)response.StatusCode,
            ["body"] = reader.ReadToEnd(),
        }.ToJsonString();
    }

    private static ModelServerHost? From(void* context) =>
        context is null ? null : GCHandle.FromIntPtr((nint)context).Target as ModelServerHost;

    // Answers one call: 0 with the reply, or 1 with the reason, as the Swift host does.
    private static int Answer(void* context, byte* request, byte** reply, Func<ModelServerHost, JsonObject, string> handle)
    {
        if (reply is null)
        {
            return 2;
        }
        try
        {
            ModelServerHost host = From(context) ?? throw new InvalidOperationException("the host was called without a context");
            JsonObject body = JsonNode.Parse(NativeString.Read(request) ?? "") as JsonObject
                ?? throw new InvalidOperationException("the request is not a JSON object");
            *reply = NativeString.Duplicate(handle(host, body));
            return 0;
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            string reason = ex is OperationCanceledException ? "timed out" : ex.GetBaseException().Message;
            *reply = NativeString.Duplicate(reason);
            return 1;
        }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int HttpEntry(void* context, byte* request, byte** reply) =>
        Answer(context, request, reply, static (host, body) => host.Http(body));

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static int UnavailableEntry(void* context, byte* request, byte** reply) =>
        Answer(context, request, reply, static (host, body) =>
        {
            string model = body["model"]?.GetValue<string>() ?? "the model";
            host._log.Warning($"{model} needs the Mac app's LlamaXPCService or image service, which Windows does not have yet");
            throw new InvalidOperationException($"{model} is served by the Mac app's LlamaXPCService or image service, which Windows does not have yet; use Ollama or LM Studio");
        });

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static void ReleaseEntry(void* context, byte* reply) => NativeString.Free(reply);
}

using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Threading.Channels;
using Garage.Grpc.Services;
using Garage.Python;
using Garage.Python.Interop;
using Google.Protobuf;
using Grpc.Core;
using Py = Garage.Python.Python;

namespace Garage.Services;

/// <summary>
/// <c>IngestControl</c>: runs <c>garage_rag.ingest.ingest_xpc</c>, which persists every document
/// through the backend's <c>GarageService</c> (the database facade), as GarageIngestXPCService does.
/// One ingest at a time: the Python side keeps one cancel flag per process.
/// </summary>
internal sealed class IngestService(ServiceRuntime runtime) : IngestControl.IngestControlBase
{
    private static readonly JsonParser Parser = new(JsonParser.Settings.Default.WithIgnoreUnknownFields(true));
    private static readonly SemaphoreSlim OneAtATime = new(1, 1);
    private static Channel<IngestProgress>? _progress;
    private static bool _callbackRegistered;

    public override async Task IngestSource(IngestSourceRequest request, IServerStreamWriter<IngestProgress> responseStream, ServerCallContext context)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(responseStream);
        ArgumentNullException.ThrowIfNull(context);
        if (string.IsNullOrWhiteSpace(request.Source))
        {
            throw new RpcException(new Status(StatusCode.InvalidArgument, "source is required (a slug, or * for every source)"));
        }
        if (!PythonHost.IsReady)
        {
            throw new RpcException(new Status(StatusCode.FailedPrecondition, $"Python did not start: {PythonHost.StartError}"));
        }
        if (!await OneAtATime.WaitAsync(0, context.CancellationToken).ConfigureAwait(false))
        {
            throw new RpcException(new Status(StatusCode.FailedPrecondition, "An ingest is already running."));
        }
        try
        {
            var channel = Channel.CreateUnbounded<IngestProgress>(new UnboundedChannelOptions { SingleReader = true });
            Volatile.Write(ref _progress, channel);
            RegisterCallback();

            runtime.Log.Info($"Ingest of {request.Source} started (include_code={request.IncludeCode}, force={request.Force})");
            Task run = Task.Factory.StartNew(
                () => Ingest(request, channel.Writer),
                CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);

            // Cancelling the call (the app's Stop) stops the ingest at its next item.
            using CancellationTokenRegistration cancel = context.CancellationToken.Register(RequestCancel);
            await foreach (IngestProgress progress in channel.Reader.ReadAllAsync(CancellationToken.None).ConfigureAwait(false))
            {
                if (!context.CancellationToken.IsCancellationRequested)
                {
                    await responseStream.WriteAsync(progress, context.CancellationToken).ConfigureAwait(false);
                }
            }
            await run.ConfigureAwait(false);
        }
        finally
        {
            Volatile.Write(ref _progress, null);
            OneAtATime.Release();
        }
    }

    public override Task<CancelIngestReply> CancelIngest(CancelIngestRequest request, ServerCallContext context)
    {
        bool running = OneAtATime.CurrentCount == 0;
        if (running)
        {
            RequestCancel();
        }
        return Task.FromResult(new CancelIngestReply { WasRunning = running });
    }

    // On a thread of its own: ingest_xpc blocks for the whole run, holding the GIL only while
    // Python code runs, so the service's other calls go on meanwhile.
    private void Ingest(IngestSourceRequest request, ChannelWriter<IngestProgress> writer)
    {
        try
        {
            using PythonObject ingest = Py.Import("garage_rag.ingest");
            ingest.Invoke(
                "ingest_xpc",
                [request.Source],
                [
                    new("include_code", request.IncludeCode),
                    new("limit", request.Limit > 0 ? request.Limit : null),
                    new("force", request.Force),
                    new("grpc_host", "127.0.0.1"),
                    new("grpc_port", runtime.Options.GrpcPort),
                ]).Dispose();
            runtime.Log.Info($"Ingest of {request.Source} finished");
            writer.TryComplete();
        }
        catch (Exception ex)
        {
            string message = PythonHost.Describe(ex);
            runtime.Log.Error($"Ingest of {request.Source} failed: {message}");
            writer.TryComplete(new RpcException(new Status(StatusCode.Internal, message)));
        }
    }

    private void RequestCancel()
    {
        runtime.Log.Info("Ingest cancel requested");
        try
        {
            using PythonObject ingest = Py.Import("garage_rag.ingest");
            ingest.Invoke("cancel_ingest").Dispose();
        }
        catch (PythonException ex)
        {
            runtime.Log.Error($"cancel_ingest failed: {PythonHost.Describe(ex)}");
        }
    }

    private static unsafe void RegisterCallback()
    {
        if (_callbackRegistered)
        {
            return;
        }
        using PythonObject ingest = Py.Import("garage_rag.ingest");
        ingest.Invoke("set_c_progress_callback", (nint)(delegate* unmanaged[Cdecl]<byte*, void>)&OnProgress).Dispose();
        _callbackRegistered = true;
    }

    // void callback(const char *json): one garage_rag.ingest.IngestProgress as JSON.
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static unsafe void OnProgress(byte* json)
    {
        try
        {
            if (Volatile.Read(ref _progress) is { } channel && NativeUtf8.Read((nint)json) is { } text)
            {
                channel.Writer.TryWrite(Parser.Parse<IngestProgress>(text));
            }
        }
        catch (Exception)
        {
            // A malformed update is dropped; an exception must never cross back into Python's frame.
        }
    }
}

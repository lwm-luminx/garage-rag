using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text.Json.Nodes;
using System.Threading.Channels;
using Garage.Grpc.Services;
using Garage.Services.Native;
using Google.Protobuf;
using Grpc.Core;

namespace Garage.Services;

/// <summary>
/// <c>IngestControl</c>: runs the Rust ingest (<c>garage_ingest_run</c> in <c>garage_ingest_ffi.dll</c>,
/// the port of <c>ingest_xpc</c>) with the Rust readers, persisting every document through the
/// backend's <c>GarageService</c> (the database facade), as GarageIngestXPCService does. One ingest
/// at a time; the app's Stop cancels it at its next file.
/// </summary>
internal sealed class IngestService(ServiceRuntime runtime) : IngestControl.IngestControlBase
{
    private static readonly JsonParser Parser = new(JsonParser.Settings.Default.WithIgnoreUnknownFields(true));
    private static readonly SemaphoreSlim OneAtATime = new(1, 1);
    private static Run? _current;

    public override async Task IngestSource(IngestSourceRequest request, IServerStreamWriter<IngestProgress> responseStream, ServerCallContext context)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(responseStream);
        ArgumentNullException.ThrowIfNull(context);
        if (string.IsNullOrWhiteSpace(request.Source))
        {
            throw new RpcException(new Status(StatusCode.InvalidArgument, "source is required (a slug, or * for every source)"));
        }
        if (!await OneAtATime.WaitAsync(0, context.CancellationToken).ConfigureAwait(false))
        {
            throw new RpcException(new Status(StatusCode.FailedPrecondition, "An ingest is already running."));
        }
        var run = new Run();
        try
        {
            Volatile.Write(ref _current, run);
            runtime.Log.Info($"Ingest of {request.Source} started (include_code={request.IncludeCode}, force={request.Force})");
            Task work = Task.Factory.StartNew(
                () => Ingest(request, run),
                CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);

            // Cancelling the call (the app's Stop) stops the ingest at its next file.
            using CancellationTokenRegistration cancel = context.CancellationToken.Register(run.Cancel);
            await foreach (IngestProgress progress in run.Progress.Reader.ReadAllAsync(CancellationToken.None).ConfigureAwait(false))
            {
                if (!context.CancellationToken.IsCancellationRequested)
                {
                    await responseStream.WriteAsync(progress, context.CancellationToken).ConfigureAwait(false);
                }
            }
            await work.ConfigureAwait(false);
        }
        finally
        {
            Volatile.Write(ref _current, null);
            run.Dispose();
            OneAtATime.Release();
        }
    }

    public override Task<CancelIngestReply> CancelIngest(CancelIngestRequest request, ServerCallContext context)
    {
        Run? running = Volatile.Read(ref _current);
        if (running is not null)
        {
            runtime.Log.Info("Ingest cancel requested");
            running.Cancel();
        }
        return Task.FromResult(new CancelIngestReply { WasRunning = running is not null });
    }

    // On a thread of its own: garage_ingest_run blocks for the whole run, and the host's callbacks
    // come back on this thread.
    private unsafe void Ingest(IngestSourceRequest request, Run run)
    {
        try
        {
            var json = new JsonObject
            {
                ["facade"] = new JsonObject
                {
                    ["host"] = "127.0.0.1",
                    ["port"] = runtime.Options.GrpcPort,
                    ["token"] = Environment.GetEnvironmentVariable("GARAGE_GRPC_TOKEN") ?? "",
                },
                ["source"] = request.Source,
                // Settings from GarageService's GetSetting, and the Rust readers with its extraction.* settings.
                ["settings"] = "service",
                ["readers"] = new JsonObject(),
                ["include_code"] = request.IncludeCode,
                ["force"] = request.Force,
                // Git history through the libgit2 linked in.
                ["read_git"] = true,
            };
            if (request.Limit > 0)
            {
                json["limit"] = request.Limit;
            }
            var host = new GarageNative.IngestHost
            {
                Context = (void*)GCHandle.ToIntPtr(run.Handle),
                Read = null,
                Release = &ReleaseEntry,
                Progress = &ProgressEntry,
                Cancelled = &CancelledEntry,
                SharedNames = null,
            };
            byte* text = GarageNative.Request(json);
            byte* result = null;
            int status;
            try
            {
                status = GarageNative.IngestRun(text, &host, &result);
            }
            finally
            {
                NativeString.Free(text);
            }
            JsonObject reply = GarageNative.TakeResult(status, result, &GarageNative.IngestStringFree, $"Ingest of {request.Source} failed");
            if (reply["error"]?.GetValue<string>() is { Length: > 0 } error)
            {
                throw new InvalidOperationException(error);
            }
            runtime.Log.Info(reply["cancelled"]?.GetValue<bool>() == true ? $"Ingest of {request.Source} cancelled" : $"Ingest of {request.Source} finished");
            run.Progress.Writer.TryComplete();
        }
        catch (Exception ex) when (ex is NativeCallException or InvalidOperationException)
        {
            runtime.Log.Error(ex.Message);
            run.Progress.Writer.TryComplete(new RpcException(new Status(StatusCode.Internal, ex.Message)));
        }
    }

    private static unsafe Run? From(void* context) =>
        context is null ? null : GCHandle.FromIntPtr((nint)context).Target as Run;

    // void progress(void *context, const char *event): one IngestProgress as JSON.
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static unsafe void ProgressEntry(void* context, byte* json)
    {
        try
        {
            if (From(context) is { } run && NativeString.Read(json) is { } text)
            {
                run.Progress.Writer.TryWrite(Parser.Parse<IngestProgress>(text));
            }
        }
        catch (Exception)
        {
            // A malformed update is dropped; an exception must never cross back into the native frame.
        }
    }

    // bool cancelled(void *context): asked before each file.
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static unsafe byte CancelledEntry(void* context) => From(context)?.IsCancelled == true ? (byte)1 : (byte)0;

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static unsafe void ReleaseEntry(void* context, byte* reply) => NativeString.Free(reply);

    /// <summary>One ingest in progress: its updates and its cancel flag, reachable from the native callbacks.</summary>
    private sealed class Run : IDisposable
    {
        private int _cancelled;

        public Run()
        {
            Handle = GCHandle.Alloc(this);
        }

        public GCHandle Handle { get; }

        public Channel<IngestProgress> Progress { get; } = Channel.CreateUnbounded<IngestProgress>(new UnboundedChannelOptions { SingleReader = true });

        public bool IsCancelled => Volatile.Read(ref _cancelled) != 0;

        public void Cancel() => Volatile.Write(ref _cancelled, 1);

        public void Dispose()
        {
            if (Handle.IsAllocated)
            {
                Handle.Free();
            }
        }
    }
}

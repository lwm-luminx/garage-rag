using Garage.Grpc.Services;
using Grpc.Core;

namespace Garage.Services;

/// <summary><c>ServiceControl</c>: what every service answers (services.proto).</summary>
internal sealed class ControlService(ServiceRuntime runtime) : ServiceControl.ServiceControlBase
{
    public override Task<Garage.Grpc.Services.PingReply> Ping(Garage.Grpc.Services.PingRequest request, ServerCallContext context) =>
        Task.FromResult(new PingReply { ServiceId = runtime.Options.ServiceId, Pid = Environment.ProcessId });

    public override Task<ServiceStatusReport> GetServiceStatus(ServiceStatusRequest request, ServerCallContext context) =>
        Task.FromResult(runtime.Report());

    // Off the request thread: the database and gRPC checks can take seconds.
    public override Task<ServiceStatusReport> RunSelfTests(RunSelfTestsRequest request, ServerCallContext context) =>
        Task.Run(runtime.RunSelfTests, context.CancellationToken);

    public override Task<FetchLogsReply> FetchLogs(FetchLogsRequest request, ServerCallContext context)
    {
        ArgumentNullException.ThrowIfNull(request);
        var reply = new FetchLogsReply();
        reply.Entries.AddRange(runtime.Log.Recent(request.Limit > 0 ? request.Limit : ServiceLog.Capacity));
        return Task.FromResult(reply);
    }

    public override async Task SubscribeToLogStream(LogStreamRequest request, IServerStreamWriter<LogEntry> responseStream, ServerCallContext context)
    {
        ArgumentNullException.ThrowIfNull(responseStream);
        ArgumentNullException.ThrowIfNull(context);
        using ServiceLog.Subscription subscription = runtime.Log.Subscribe();
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(context.CancellationToken, runtime.Stopping.Token);
        try
        {
            await foreach (LogEntry entry in subscription.Reader.ReadAllAsync(stop.Token).ConfigureAwait(false))
            {
                await responseStream.WriteAsync(entry, stop.Token).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException)
        {
            // The app went away or the service is stopping: the stream just ends.
        }
    }

    public override Task<ShutdownReply> Shutdown(ShutdownRequest request, ServerCallContext context)
    {
        runtime.Log.Info("Shutdown requested by the app");
        // After the reply is on its way.
        _ = Task.Delay(100).ContinueWith(_ => runtime.Stopping.Cancel(), TaskScheduler.Default);
        return Task.FromResult(new ShutdownReply());
    }
}

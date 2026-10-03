using System.Diagnostics;
using Garage.Services;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Server.Kestrel.Core;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

// One Garage service process (docs/plans/windows.md §2.1). The app's ServiceManager starts it, puts it
// in a kill-on-close Job Object, and talks to it over the named pipe; see ServiceOptions for the command
// line. The control plane answers at once; Python starts on a thread of its own, and the Status page
// shows the service as starting until it is ready.

ServiceOptions options;
try
{
    options = ServiceOptions.Parse(args, Environment.GetEnvironmentVariable);
}
catch (ArgumentException ex)
{
    await Console.Error.WriteLineAsync($"Garage.Services: {ex.Message}").ConfigureAwait(false);
    return 2;
}

Directory.CreateDirectory(options.DataDirectory);
// garage_rag finds ./garage.json first, then ~/.garage.json (config/__init__.py): the data folder's
// config is the app's, as the Mac's services run in theirs.
Environment.CurrentDirectory = options.DataDirectory;

using var log = new ServiceLog(options.ServiceId, Path.Combine(options.DataDirectory, "logs", $"{options.ServiceId}.log"));
var runtime = new ServiceRuntime(options, log);
log.Info($"Garage.Services {options.ServiceId} starting (pid {Environment.ProcessId}, parent {options.ParentPid})");

WebApplicationBuilder builder = WebApplication.CreateSlimBuilder();
builder.Logging.ClearProviders();
builder.Logging.AddProvider(new ServiceLogProvider(log));
builder.Logging.SetMinimumLevel(LogLevel.Warning);
var peers = new PeerCheck(options.ParentPid, log);
// The pipe admits the signed-in user only (CurrentUserOnly, Kestrel's default); the peer check narrows
// that to Garage's own processes.
builder.WebHost.UseNamedPipes(pipe => pipe.CurrentUserOnly = true);
builder.WebHost.ConfigureKestrel(kestrel => kestrel.ListenNamedPipe(options.PipeName, listen =>
{
    listen.Protocols = HttpProtocols.Http2;
    listen.Use(peers.Middleware);
}));
builder.Services.AddGrpc(grpc => grpc.MaxReceiveMessageSize = 4 * 1024 * 1024);
builder.Services.AddSingleton(runtime);

await using WebApplication app = builder.Build();
app.MapGrpcService<ControlService>();
if (options.Role == ServiceRole.Ingest)
{
    app.MapGrpcService<IngestService>();
}

await app.StartAsync().ConfigureAwait(false);
log.Info($"Control plane listening on pipe {options.PipeName}");

// Also stop when the app is gone: the Job Object ends every service with the app, but a service
// started by hand (tests, debugging) has no job.
_ = WatchParentAsync(options.ParentPid, runtime);

using var core = options.Role == ServiceRole.Core ? new CoreBackend(runtime) : null;
using var mcp = options.Role == ServiceRole.Mcp ? new McpHttp(runtime) : null;
var startup = new Thread(() =>
{
    if (!PythonHost.Start(options, log))
    {
        runtime.MarkFailed($"Python did not start: {PythonHost.StartError}");
        return;
    }
    try
    {
        core?.Start();
        mcp?.Start();
        runtime.MarkRunning();
    }
    catch (Exception ex)
    {
        runtime.MarkFailed(PythonHost.Describe(ex));
    }
    runtime.RunSelfTests();
})
{ IsBackground = true, Name = "python-startup" };
startup.Start();

try
{
    await Task.Delay(Timeout.Infinite, runtime.Stopping.Token).ConfigureAwait(false);
}
catch (OperationCanceledException)
{
}

log.Info("Stopping");
core?.Stop();
mcp?.Stop();
await app.StopAsync(CancellationToken.None).ConfigureAwait(false);
return 0;

static async Task WatchParentAsync(int parentPid, ServiceRuntime runtime)
{
    try
    {
        using Process parent = Process.GetProcessById(parentPid);
        await parent.WaitForExitAsync(runtime.Stopping.Token).ConfigureAwait(false);
        runtime.Log.Info($"The app (pid {parentPid}) exited");
    }
    catch (ArgumentException)
    {
        runtime.Log.Warning($"The app (pid {parentPid}) is not running");
    }
    catch (OperationCanceledException)
    {
        return;
    }
    await runtime.Stopping.CancelAsync().ConfigureAwait(false);
}

using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Runtime.Versioning;
using System.Security.Cryptography;
using Garage.App.Core.Logging;
using Garage.App.Core.Operations;
using Garage.App.Core.Threading;
using Garage.Grpc;
using Garage.Grpc.Services;
using Grpc.Core;

namespace Garage.App.Core.Services;

/// <summary>
/// Starts and watches the app's service processes (docs/plans/windows.md §2.1): the counterpart of the
/// Mac's <c>XPCServiceManager</c>. Each launch gets a fresh instance id (in every pipe name), a fresh
/// <c>GARAGE_GRPC_TOKEN</c> and a free loopback port for the backend; every process goes into one
/// kill-on-close Job Object, so none outlives the app.
/// </summary>
[SupportedOSPlatform("windows")]
public sealed class ServiceManager : IServiceHost, IDisposable
{
    /// <summary>
    /// How often a running service is asked for its state: the rows pick up the self tests it runs
    /// after start-up, and a service that stops answering shows as unreachable.
    /// </summary>
    public static readonly TimeSpan MonitorInterval = TimeSpan.FromSeconds(10);

    /// <summary>How long a service has to start its Python and report itself running.</summary>
    public static readonly TimeSpan StartTimeout = TimeSpan.FromSeconds(90);

    private static readonly TimeSpan CallTimeout = TimeSpan.FromSeconds(10);

    private readonly ServiceHostLayout _layout;
    private readonly IUiDispatcher _dispatcher;
    private readonly string _instance;
    private readonly string _token;
    private readonly JobObject _job = new();
    private readonly SemaphoreSlim _starting = new(1, 1);
    private readonly CancellationTokenSource _monitor = new();
    private bool _disposed;
    private bool _monitoring;

    /// <summary>Creates the manager; nothing starts until <see cref="StartAsync"/>.</summary>
    public ServiceManager(ServiceHostLayout layout, IUiDispatcher dispatcher, int? grpcPort = null)
    {
        _layout = layout ?? throw new ArgumentNullException(nameof(layout));
        _dispatcher = dispatcher ?? throw new ArgumentNullException(nameof(dispatcher));
        _instance = Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(4));
        _token = Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(32));
        GrpcPort = grpcPort ?? FreeLoopbackPort();
        Core = new ServiceProcess("core", ServicePipe.Name(_instance, "core"), dispatcher);
        Ingest = new ServiceProcess("ingest", ServicePipe.Name(_instance, "ingest"), dispatcher);
        Mcp = new ServiceProcess("mcp", ServicePipe.Name(_instance, "mcp"), dispatcher);
        Mcp.Set(ServiceState.Stopped, McpOff);
    }

    /// <summary>Where everything is.</summary>
    public ServiceHostLayout Layout => _layout;

    /// <summary>The backend's loopback port.</summary>
    public int GrpcPort { get; }

    /// <summary>The backend's endpoint, with this launch's token.</summary>
    public GarageEndpoint Grpc => new(new UriBuilder(Uri.UriSchemeHttp, "127.0.0.1", GrpcPort).Uri, _token);

    /// <summary>The backend: <c>GarageService</c> (the Mac's GarageXPCService).</summary>
    public ServiceProcess Core { get; }

    /// <summary>Ingestion (the Mac's GarageIngestXPCService).</summary>
    public ServiceProcess Ingest { get; }

    /// <summary>MCP over HTTP (the Mac's GarageMCPServerService): started only while it is switched on.</summary>
    public ServiceProcess Mcp { get; }

    /// <summary>The MCP HTTP server's port, the Mac's.</summary>
    public int McpPort { get; init; } = 8787;

    /// <summary>The MCP HTTP server's address.</summary>
    public Uri McpUrl => new UriBuilder(Uri.UriSchemeHttp, "127.0.0.1", McpPort, "/mcp").Uri;

    /// <summary>What the MCP row says while HTTP is off.</summary>
    public const string McpOff = "Off: assistants use stdio. Turn HTTP on on the MCP Server page.";

    /// <summary>
    /// More environment for every service process from its next start: the app's own database
    /// (<c>GARAGE_DATABASE_URL</c>, a secret) and its libpq (<c>GARAGE_LIBPQ</c>).
    /// </summary>
    public IDictionary<string, string> Environment { get; } = new Dictionary<string, string>(StringComparer.Ordinal);

    /// <summary>Every service, in the Status page's order.</summary>
    public IReadOnlyList<ServiceProcess> Services => [Core, Ingest, Mcp];

    /// <summary>
    /// Starts or stops the MCP HTTP service. Off is the normal state: assistants start Garage
    /// themselves over stdio, and no port is open.
    /// </summary>
    public async Task<bool> SetMcpEnabledAsync(bool enabled, CancellationToken cancellationToken = default)
    {
        await _starting.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (enabled)
            {
                return Mcp.State == ServiceState.Running || await StartOneAsync(Mcp, cancellationToken).ConfigureAwait(false);
            }
            await StopOneAsync(Mcp).ConfigureAwait(false);
            Mcp.Set(ServiceState.Stopped, McpOff);
            return true;
        }
        finally
        {
            _starting.Release();
        }
    }

    /// <summary>
    /// Starts the backend, waits for it to listen, then starts ingest, which persists through it.
    /// Returns whether both came up; a service that did not says why in its <see cref="ServiceProcess.Error"/>.
    /// </summary>
    public async Task<bool> StartAsync(CancellationToken cancellationToken = default)
    {
        await _starting.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            bool core = await StartOneAsync(Core, cancellationToken).ConfigureAwait(false);
            bool ingest = core && await StartOneAsync(Ingest, cancellationToken).ConfigureAwait(false);
            if (!core)
            {
                Ingest.Set(ServiceState.Stopped, "Waits for the backend to start");
            }
            _ = MonitorAsync(_monitor.Token);
            return core && ingest;
        }
        finally
        {
            _starting.Release();
        }
    }

    /// <summary>Stops and starts one service; restarting the backend restarts ingest after it.</summary>
    public async Task<bool> RestartAsync(ServiceProcess service, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(service);
        await _starting.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            service.Set(ServiceState.Restarting);
            service.AppendLog("Restarting", LogLevel.Info);
            service.Kill();
            bool ok = await StartOneAsync(service, cancellationToken).ConfigureAwait(false);
            if (ok && service == Core)
            {
                Ingest.Kill();
                ok = await StartOneAsync(Ingest, cancellationToken).ConfigureAwait(false);
            }
            return ok;
        }
        finally
        {
            _starting.Release();
        }
    }

    /// <summary>Asks one service for its state (a ping, then its report), as the Status page's refresh does.</summary>
    public async Task RefreshAsync(ServiceProcess service, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(service);
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (service.Control is not { } control || service.State is ServiceState.Restarting or ServiceState.Stopped)
        {
            return;
        }
        try
        {
            var clock = Stopwatch.StartNew();
            await control.PingAsync(new Garage.Grpc.Services.PingRequest(), Options(cancellationToken)).ConfigureAwait(false);
            double latency = clock.Elapsed.TotalMilliseconds;
            ServiceStatusReport report = await control.GetServiceStatusAsync(new ServiceStatusRequest(), Options(cancellationToken)).ConfigureAwait(false);
            service.SetReport(report, latency);
        }
        catch (RpcException ex) when (!cancellationToken.IsCancellationRequested)
        {
            service.Set(ServiceState.Unreachable, ex.Status.Detail is { Length: > 0 } detail ? detail : ex.StatusCode.ToString());
        }
    }

    /// <summary>Runs one service's self tests and records the report.</summary>
    public async Task<ServiceStatusReport?> RunSelfTestsAsync(ServiceProcess service, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(service);
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (service.Control is not { } control)
        {
            return null;
        }
        try
        {
            var clock = Stopwatch.StartNew();
            ServiceStatusReport report = await control.RunSelfTestsAsync(new RunSelfTestsRequest(),
                new CallOptions(deadline: DateTime.UtcNow.AddMinutes(1), cancellationToken: cancellationToken)).ConfigureAwait(false);
            service.SetReport(report, clock.Elapsed.TotalMilliseconds);
            return report;
        }
        catch (RpcException ex) when (!cancellationToken.IsCancellationRequested)
        {
            service.Set(ServiceState.Unreachable, ex.Status.Detail is { Length: > 0 } detail ? detail : ex.StatusCode.ToString());
            return null;
        }
    }

    /// <summary>Asks every service to stop, then ends whatever has not.</summary>
    public async Task StopAsync()
    {
        foreach (ServiceProcess service in Services.Reverse())
        {
            await RequestShutdownAsync(service).ConfigureAwait(false);
        }
        await Task.Delay(TimeSpan.FromMilliseconds(500)).ConfigureAwait(false);
        foreach (ServiceProcess service in Services)
        {
            service.Kill();
            service.Set(ServiceState.Stopped);
        }
    }

    private static async Task StopOneAsync(ServiceProcess service)
    {
        if (await RequestShutdownAsync(service).ConfigureAwait(false))
        {
            await Task.Delay(TimeSpan.FromMilliseconds(300)).ConfigureAwait(false);
        }
        service.Kill();
    }

    private static async Task<bool> RequestShutdownAsync(ServiceProcess service)
    {
        if (service.Control is not { } control || service.ProcessId is null)
        {
            return false;
        }
        try
        {
            await control.ShutdownAsync(new ShutdownRequest(), deadline: DateTime.UtcNow.AddSeconds(2)).ConfigureAwait(false);
            return true;
        }
        catch (RpcException)
        {
            return false;  // The caller kills it.
        }
    }

    // Started once; Dispose stops it. A service being restarted or stopped is skipped by RefreshAsync.
    private async Task MonitorAsync(CancellationToken cancellationToken)
    {
        if (_monitoring)
        {
            return;
        }
        _monitoring = true;
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                await Task.Delay(MonitorInterval, cancellationToken).ConfigureAwait(false);
                foreach (ServiceProcess service in Services.Where(s => s.State is ServiceState.Running or ServiceState.Checking))
                {
                    await RefreshAsync(service, cancellationToken).ConfigureAwait(false);
                }
            }
        }
        catch (OperationCanceledException)
        {
        }
        catch (ObjectDisposedException)
        {
        }
    }

    private async Task<bool> StartOneAsync(ServiceProcess service, CancellationToken cancellationToken)
    {
        service.Set(ServiceState.Checking);
        Process process;
        try
        {
            process = Launch(service);
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException or FileNotFoundException)
        {
            service.Set(ServiceState.Unreachable, $"Could not start: {ex.Message}");
            service.AppendLog($"Could not start: {ex.Message}", LogLevel.Error, LogChannel.Stderr);
            return false;
        }
        service.Attach(process, ServicePipe.OpenChannel(service.PipeName));
        service.AppendLog($"Started process {process.Id}", LogLevel.Info);

        // The control plane answers within a second; Python's start-up takes a few more.
        DateTime deadline = DateTime.UtcNow + StartTimeout;
        bool following = false;
        while (DateTime.UtcNow < deadline)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (process.HasExited)
            {
                return false;  // Exited sets the state and the reason.
            }
            await RefreshAsync(service, cancellationToken).ConfigureAwait(false);
            if (service.Report is not null && !following)
            {
                service.FollowLog();
                following = true;
            }
            if (service.Report?.State is "running")
            {
                return true;
            }
            if (service.Report?.State is "failed")
            {
                return false;
            }
            await Task.Delay(TimeSpan.FromMilliseconds(250), cancellationToken).ConfigureAwait(false);
        }
        service.Set(ServiceState.Unreachable, $"Did not start within {StartTimeout.TotalSeconds:0} seconds");
        return false;
    }

    private Process Launch(ServiceProcess service)
    {
        bool isDll = _layout.ServicesExecutable.EndsWith(".dll", StringComparison.OrdinalIgnoreCase);
        var info = new ProcessStartInfo(isDll ? "dotnet" : _layout.ServicesExecutable)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = _layout.DataDirectory,
        };
        if (isDll)
        {
            info.ArgumentList.Add(_layout.ServicesExecutable);
        }
        foreach (string arg in (string[])[
            "--service", service.Id,
            "--pipe", service.PipeName,
            "--parent", System.Environment.ProcessId.ToString(System.Globalization.CultureInfo.InvariantCulture),
            "--grpc-port", GrpcPort.ToString(System.Globalization.CultureInfo.InvariantCulture),
            "--data-dir", _layout.DataDirectory,
            "--mcp-port", McpPort.ToString(System.Globalization.CultureInfo.InvariantCulture)])
        {
            info.ArgumentList.Add(arg);
        }
        // Secrets and locations through the environment, never the command line (other processes of the
        // account can read a command line).
        info.Environment["GARAGE_PYTHON_HOME"] = _layout.PythonHome;
        info.Environment["GARAGE_PYTHON_SITE_PACKAGES"] = _layout.SitePackages;
        info.Environment["GARAGE_PYTHON_PATH"] = string.Join(';', _layout.PythonPath);
        info.Environment["GARAGE_GRPC_TOKEN"] = _token;
        info.Environment["GARAGE_GRPC_HOST"] = "127.0.0.1";
        info.Environment["GARAGE_GRPC_PORT"] = GrpcPort.ToString(System.Globalization.CultureInfo.InvariantCulture);
        foreach ((string name, string value) in Environment)
        {
            info.Environment[name] = value;
        }

        Directory.CreateDirectory(_layout.DataDirectory);
        Process process = Process.Start(info) ?? throw new InvalidOperationException("the process did not start");
        _job.Assign(process);
        // Anything the service prints outside its log (the runtime's own crash report) still reaches the app.
        process.OutputDataReceived += (_, e) => { if (e.Data is { Length: > 0 } line) { service.AppendLog(line, LogLevel.Info); } };
        process.ErrorDataReceived += (_, e) => { if (e.Data is { Length: > 0 } line) { service.AppendLog(line, LogLevel.Warning, LogChannel.Stderr); } };
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        return process;
    }

    private static CallOptions Options(CancellationToken cancellationToken) =>
        new(deadline: DateTime.UtcNow + CallTimeout, cancellationToken: cancellationToken);

    private static int FreeLoopbackPort()
    {
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        return ((IPEndPoint)listener.LocalEndpoint).Port;
    }

    /// <inheritdoc/>
    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        _monitor.Cancel();
        _monitor.Dispose();
        foreach (ServiceProcess service in Services)
        {
            service.Dispose();
        }
        _job.Dispose();
        _starting.Dispose();
    }
}

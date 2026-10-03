using System.Diagnostics;
using Garage.Grpc.Services;

namespace Garage.Services;

/// <summary>
/// One service process's state: what <c>GetServiceStatus</c> reports. The counterpart of
/// <c>GarageXPCServiceBase</c>'s status snapshot.
/// </summary>
internal sealed class ServiceRuntime(ServiceOptions options, ServiceLog log)
{
    private readonly Lock _lock = new();
    private readonly Stopwatch _uptime = Stopwatch.StartNew();
    private string _state = "starting";
    private string _error = "";
    private IReadOnlyList<SelfTestResult> _tests = [];

    /// <summary>The process's settings.</summary>
    public ServiceOptions Options { get; } = options;

    /// <summary>The process's log.</summary>
    public ServiceLog Log { get; } = log;

    /// <summary>Signalled when the app asks the service to stop.</summary>
    public CancellationTokenSource Stopping { get; } = new();

    /// <summary>The service is ready for work.</summary>
    public void MarkRunning()
    {
        lock (_lock)
        {
            _state = "running";
            _error = "";
        }
        Log.Info($"{DisplayName} is running");
    }

    /// <summary>The service cannot work; <paramref name="error"/> says why.</summary>
    public void MarkFailed(string error)
    {
        lock (_lock)
        {
            _state = "failed";
            _error = error;
        }
        Log.Error($"{DisplayName} failed: {error}");
    }

    /// <summary>"Garage Backend", "Ingest": the Mac's row names.</summary>
    public string DisplayName => Options.Role switch
    {
        ServiceRole.Core => "Garage Backend",
        ServiceRole.Ingest => "Ingest",
        ServiceRole.Mcp => "MCP Server",
        _ => Options.ServiceId,
    };

    /// <summary>Runs the self tests and keeps their results for <see cref="Report"/>.</summary>
    public ServiceStatusReport RunSelfTests()
    {
        IReadOnlyList<SelfTestResult> results = SelfTests.Run(SelfTests.For(Options, Log));
        lock (_lock)
        {
            _tests = results;
        }
        int failed = results.Count(r => r.Status == "failed");
        Log.Append(failed > 0 ? 30 : 20, $"Self tests: {results.Count(r => r.Status == "passed")} passed, {failed} failed, {results.Count(r => r.Status == "skipped")} skipped");
        return Report();
    }

    /// <summary>The current state and the last self-test results.</summary>
    public ServiceStatusReport Report()
    {
        var report = new ServiceStatusReport
        {
            ServiceId = Options.ServiceId,
            DisplayName = DisplayName,
            Pid = Environment.ProcessId,
            PythonVersion = PythonHost.IsReady ? Python.Python.Version : "",
            UptimeSeconds = _uptime.Elapsed.TotalSeconds,
        };
        lock (_lock)
        {
            report.State = _state;
            report.Error = _error;
            report.Tests.AddRange(_tests);
        }
        return report;
    }
}

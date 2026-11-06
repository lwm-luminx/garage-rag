using System.Diagnostics;
using CommunityToolkit.Mvvm.ComponentModel;
using Garage.App.Core.Logging;
using Garage.App.Core.Operations;
using Garage.App.Core.Threading;
using Garage.Grpc.Services;
using Grpc.Core;
using Grpc.Net.Client;

namespace Garage.App.Core.Services;

/// <summary>How a service process stands, as the Status page's row shows it (the Mac's <c>XPCServiceInfo.state</c>).</summary>
public enum ServiceState
{
    /// <summary>Not started or checked yet.</summary>
    Unknown,

    /// <summary>Started, not answering or not ready yet; or a check is in flight.</summary>
    Checking,

    /// <summary>Being stopped and started again.</summary>
    Restarting,

    /// <summary>Answering and ready.</summary>
    Running,

    /// <summary>Stopped on purpose.</summary>
    Stopped,

    /// <summary>Exited, not answering, or failed to start; <see cref="ServiceProcess.Error"/> says why.</summary>
    Unreachable,
}

/// <summary>
/// One service process the app runs: its process, its control channel, and its state. The counterpart
/// of an <c>XPCServiceInfo</c> plus its connection in the Mac's <c>XPCServiceManager</c>.
/// </summary>
public sealed partial class ServiceProcess : ObservableObject, IDisposable
{
    private readonly IUiDispatcher _dispatcher;
    private GrpcChannel? _channel;
    private Process? _process;
    private CancellationTokenSource? _logStream;

    internal ServiceProcess(string id, string pipeName, IUiDispatcher dispatcher)
    {
        Id = id;
        PipeName = pipeName;
        _dispatcher = dispatcher;
        Log = new LogBuffer(id);
    }

    /// <summary>"core", "ingest".</summary>
    public string Id { get; }

    /// <summary>The control plane's pipe.</summary>
    public string PipeName { get; }

    /// <summary>The service's log as the app receives it, for the Logs page.</summary>
    public LogBuffer Log { get; }

    /// <summary>The state.</summary>
    [ObservableProperty]
    public partial ServiceState State { get; private set; }

    /// <summary>Why the service is unreachable or failed.</summary>
    [ObservableProperty]
    public partial string? Error { get; private set; }

    /// <summary>The round trip of the last ping, in milliseconds.</summary>
    [ObservableProperty]
    public partial double? LatencyMs { get; private set; }

    /// <summary>The service's last status report, with its self-test results.</summary>
    [ObservableProperty]
    public partial ServiceStatusReport? Report { get; private set; }

    /// <summary>The process's id while it runs.</summary>
    public int? ProcessId => _process is { HasExited: false } p ? p.Id : null;

    /// <summary>The control client; null until the service is started.</summary>
    internal ServiceControl.ServiceControlClient? Control { get; private set; }

    /// <summary>The ingest client (the ingest service only); null until it is started.</summary>
    internal IngestControl.IngestControlClient? Ingest { get; private set; }

    internal void Attach(Process process, GrpcChannel channel)
    {
        _process = process;
        _channel?.Dispose();
        _channel = channel;
        Control = new ServiceControl.ServiceControlClient(_channel);
        Ingest = new IngestControl.IngestControlClient(_channel);
        process.EnableRaisingEvents = true;
        process.Exited += (_, _) =>
        {
            int code = SafeExitCode(process);
            if (ReferenceEquals(_process, process))
            {
                Set(ServiceState.Unreachable, $"The process exited (code {code})");
            }
        };
    }

    internal void Set(ServiceState state, string? error = null) => _dispatcher.Run(() =>
    {
        State = state;
        Error = error;
    });

    internal void SetReport(ServiceStatusReport report, double latencyMs) => _dispatcher.Run(() =>
    {
        Report = report;
        LatencyMs = latencyMs;
        (State, Error) = report.State switch
        {
            "running" => (ServiceState.Running, (string?)null),
            "failed" => (ServiceState.Unreachable, report.Error),
            _ => (ServiceState.Checking, null),
        };
    });

    internal void AppendLog(string text, LogLevel level, LogChannel channel = LogChannel.Stdout) =>
        _dispatcher.Run(() => Log.Append(text, channel, level));

    /// <summary>Follows the service's log stream into <see cref="Log"/> until the service goes away.</summary>
    internal void FollowLog()
    {
        _logStream?.Cancel();
        _logStream?.Dispose();
        _logStream = new CancellationTokenSource();
        CancellationToken token = _logStream.Token;
        ServiceControl.ServiceControlClient? control = Control;
        if (control is null)
        {
            return;
        }
        _ = Task.Run(async () =>
        {
            try
            {
                // What the service logged before the stream opened, then everything after.
                FetchLogsReply recent = await control.FetchLogsAsync(new FetchLogsRequest { Limit = 500 }, cancellationToken: token).ConfigureAwait(false);
                foreach (LogEntry entry in recent.Entries)
                {
                    Append(entry);
                }
                using AsyncServerStreamingCall<LogEntry> call = control.SubscribeToLogStream(new LogStreamRequest(), cancellationToken: token);
                await foreach (LogEntry entry in call.ResponseStream.ReadAllAsync(token).ConfigureAwait(false))
                {
                    Append(entry);
                }
            }
            catch (RpcException)
            {
                // The service stopped or restarted; the manager follows the new one.
            }
            catch (OperationCanceledException)
            {
            }
        }, token);
    }

    private void Append(LogEntry entry)
    {
        LogLevel level = entry.Level switch
        {
            <= 10 => LogLevel.Debug,
            <= 20 => LogLevel.Info,
            <= 30 => LogLevel.Warning,
            _ => LogLevel.Error,
        };
        var time = DateTimeOffset.FromUnixTimeMilliseconds(entry.TimeMs).ToLocalTime();
        var line = new LogLine(level >= LogLevel.Error ? LogChannel.Stderr : LogChannel.Stdout, entry.Message, Id, time) { Level = level };
        _dispatcher.Run(() => Log.Append(line));
    }

    /// <summary>Ends the process now (the Job Object would at exit anyway).</summary>
    internal void Kill()
    {
        _logStream?.Cancel();
        Process? process = _process;
        _process = null;
        if (process is { HasExited: false })
        {
            try
            {
                process.Kill(entireProcessTree: true);
                process.WaitForExit(5000);
            }
            catch (InvalidOperationException)
            {
                // Already gone.
            }
        }
        process?.Dispose();
    }

    private static int SafeExitCode(Process process)
    {
        try
        {
            return process.ExitCode;
        }
        catch (InvalidOperationException)
        {
            return -1;
        }
    }

    /// <inheritdoc/>
    public void Dispose()
    {
        Kill();
        _logStream?.Dispose();
        _channel?.Dispose();
    }
}

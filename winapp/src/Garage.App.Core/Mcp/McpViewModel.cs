using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using Garage.App.Core.Backend;
using Garage.App.Core.State;
using Garage.App.Core.Services;
using Garage.App.Core.Operations;
using Grpc.Core;

namespace Garage.App.Core.Mcp;

/// <summary>
/// The MCP Server page: the server row and one row per assistant, with Connect / Update / Disconnect
/// and Connect All. Assistants are registered over stdio (<c>McpInstall</c> with <c>stdio</c>), as the
/// Mac registers the bundled launcher. The optional HTTP server comes with Garage's MCP service; until
/// then HTTP is off, which is the normal state.
/// </summary>
public sealed partial class McpViewModel(GarageService.GarageServiceClient client, OperationRunner runner, Func<string, string?>? readRegisteredUrl = null) : ObservableObject
{
    private static readonly TimeSpan CallTimeout = TimeSpan.FromSeconds(60);
    private readonly Func<string, string?> _readRegisteredUrl = readRegisteredUrl ?? (path => McpClientConfigReader.RegisteredUrl(path));

    /// <summary>One row per known assistant.</summary>
    public ObservableCollection<McpClientRowPresentation> Rows { get; } = [];

    /// <summary>The server row.</summary>
    [ObservableProperty]
    public partial McpServerHeadline? Headline { get; private set; }

    /// <summary>The line over the list.</summary>
    [ObservableProperty]
    public partial string Summary { get; private set; } = "";

    /// <summary>Whether Connect All has anything to do.</summary>
    [ObservableProperty]
    public partial bool CanConnectAll { get; private set; }

    /// <summary>The command assistants are registered to run.</summary>
    [ObservableProperty]
    public partial string ServerCommand { get; private set; } = "";

    /// <summary>Why the page failed to load.</summary>
    [ObservableProperty]
    public partial string? ErrorMessage { get; private set; }

    /// <summary>The last operation's outcome.</summary>
    [ObservableProperty]
    public partial string? LastResult { get; private set; }

    /// <summary>Whether the app serves MCP over HTTP (with Garage's MCP service); off, assistants run stdio.</summary>
    [ObservableProperty]
    public partial bool HttpEnabled { get; private set; }

    /// <summary>The switch is being flipped.</summary>
    [ObservableProperty]
    public partial bool IsSwitchingHttp { get; private set; }

    /// <summary>The preference that keeps the switch across launches (the Mac's <c>garage.mcp.httpEnabled</c>).</summary>
    public const string HttpEnabledKey = "mcp.httpEnabled";

    private IMcpHttpHost? _http;
    private int _connected;

    /// <summary>The app's MCP HTTP server; null with a development backend, which cannot serve one.</summary>
    public IMcpHttpHost? Http
    {
        get => _http;
        set
        {
            _http = value;
            if (value is not null)
            {
                value.Service.PropertyChanged += (_, _) => RecomputeHeadline();
            }
            OnPropertyChanged(nameof(CanServeHttp));
            RecomputeHeadline();
        }
    }

    /// <summary>Where the switch is remembered; memory only when unset.</summary>
    public IPreferences Preferences { get; set; } = new MemoryPreferences();

    /// <summary>Whether this app can serve HTTP at all.</summary>
    public bool CanServeHttp => _http is not null;

    /// <summary>The server's address, when it runs.</summary>
    public Uri? HttpUrl => _http?.Service.State == ServiceState.Running ? _http.Url : null;

    /// <summary>
    /// Starts or stops the HTTP server, and remembers the choice. Off, a registration at its address
    /// reads as out of date and Update rewrites it to stdio, as on the Mac.
    /// </summary>
    public async Task<bool> SetHttpEnabledAsync(bool enabled)
    {
        if (_http is null)
        {
            return false;
        }
        IsSwitchingHttp = true;
        try
        {
            bool ok = await _http.SetEnabledAsync(enabled).ConfigureAwait(true);
            HttpEnabled = enabled && ok;
            Preferences.Write(HttpEnabledKey, HttpEnabled);
            LastResult = enabled
                ? ok ? $"MCP is served at {_http.Url}" : $"The MCP HTTP server did not start: {_http.Service.Error}"
                : "The MCP HTTP server is off; assistants use stdio.";
            await LoadAsync().ConfigureAwait(true);
            return ok;
        }
        finally
        {
            IsSwitchingHttp = false;
        }
    }

    /// <summary>At launch: the remembered port, and the HTTP server back on when it was on when the app last ran.</summary>
    public Task RestoreHttpAsync()
    {
        if (_http is null)
        {
            return Task.CompletedTask;
        }
        int port = Preferences.Read(PortKey, _http.Port);
        if (IsValidPort(port))
        {
            _http.Port = port;
        }
        OnPropertyChanged(nameof(Port));
        return Preferences.Read(HttpEnabledKey, false) ? SetHttpEnabledAsync(true) : Task.CompletedTask;
    }

    /// <summary>The preference that keeps the port across launches (the Mac's <c>garage.mcp.port</c>).</summary>
    public const string PortKey = "mcp.port";

    /// <summary>The HTTP server's port.</summary>
    public int Port => _http?.Port ?? 8787;

    /// <summary>Whether <paramref name="port"/> can be listened on without administrator rights.</summary>
    public static bool IsValidPort(int port) => port is >= 1024 and <= 65535;

    /// <summary>A port from the dynamic range, for the page's Random.</summary>
    public static int RandomPort() => Random.Shared.Next(49152, 65536);

    /// <summary>
    /// Moves the HTTP server to <paramref name="port"/> and remembers it; a running server restarts
    /// there, and the registrations at the old address read as out of date until Update rewrites them.
    /// </summary>
    public async Task<bool> SetPortAsync(int port)
    {
        if (_http is null || !IsValidPort(port))
        {
            LastResult = string.Create(System.Globalization.CultureInfo.CurrentCulture, $"{port} is not a port Garage can use: pick one from 1024 to 65535.");
            return false;
        }
        if (port == _http.Port)
        {
            return true;
        }
        _http.Port = port;
        Preferences.Write(PortKey, port);
        OnPropertyChanged(nameof(Port));
        if (HttpEnabled)
        {
            return await RestartHttpAsync().ConfigureAwait(true);
        }
        await LoadAsync().ConfigureAwait(true);
        return true;
    }

    /// <summary>Stops the HTTP server and starts it again (the Mac's Restart).</summary>
    public async Task<bool> RestartHttpAsync()
    {
        if (_http is null)
        {
            return false;
        }
        IsSwitchingHttp = true;
        try
        {
            await _http.SetEnabledAsync(false).ConfigureAwait(true);
            bool ok = await _http.SetEnabledAsync(true).ConfigureAwait(true);
            HttpEnabled = ok;
            Preferences.Write(HttpEnabledKey, ok);
            LastResult = ok ? $"MCP is served at {_http.Url}" : $"The MCP HTTP server did not start: {_http.Service.Error}";
            await LoadAsync().ConfigureAwait(true);
            return ok;
        }
        finally
        {
            IsSwitchingHttp = false;
        }
    }

    /// <summary>Connect a Config File…: registers Garage in an MCP config file the page did not find, as stdio.</summary>
    public Task<OperationResult> ConnectConfigFileAsync(string path) => RunAsync(async token =>
    {
        McpInstallResponse installed = await client.McpInstallAsync(
            new McpInstallRequest { Path = path, Stdio = true, Force = true }, Options(token)).ConfigureAwait(true);
        return Describe(installed);
    });

    /// <summary>Check Registrations: reads every assistant's config again and says what it found.</summary>
    public async Task CheckRegistrationsAsync()
    {
        await LoadAsync().ConfigureAwait(true);
        if (ErrorMessage is null)
        {
            LastResult = Summary;
        }
    }

    /// <summary>Reads which assistants are registered, and at what address.</summary>
    public async Task LoadAsync(CancellationToken cancellationToken = default)
    {
        ErrorMessage = null;
        try
        {
            McpStatusResponse status = await client.McpStatusAsync(new McpStatusRequest(), Options(cancellationToken)).ConfigureAwait(true);
            ServerCommand = status.ServerCommand;
            List<McpClient> clients = await Task.Run(
                () => status.Clients.Select(c => new McpClient(c.Key, c.Label, c.Path, c.ConfigExists, c.Registered,
                    c.Registered ? _readRegisteredUrl(c.Path) : null)).ToList(),
                cancellationToken).ConfigureAwait(true);
            List<McpClientRowPresentation> rows = [.. clients.Select(c => McpClientRowPresentation.For(c, endpoint: HttpUrl))];
            Rows.Clear();
            foreach (McpClientRowPresentation row in rows)
            {
                Rows.Add(row);
            }
            Summary = McpPagePresentation.ClientSummary(rows);
            CanConnectAll = McpPagePresentation.CanConnectAll(rows);
            _connected = rows.Count(r => r.IsConnected);
            RecomputeHeadline();
        }
        catch (RpcException ex)
        {
            ErrorMessage = RpcErrors.Describe(ex);
        }
    }

    /// <summary>Registers Garage with one assistant, or rewrites an outdated entry, as a stdio command.</summary>
    public Task<OperationResult> ConnectAsync(string key) => RunAsync(async token =>
    {
        McpInstallResponse installed = await client.McpInstallAsync(
            new McpInstallRequest { Target = key, Stdio = true, Force = true }, Options(token)).ConfigureAwait(true);
        return Describe(installed);
    });

    /// <summary>Registers Garage with every installed assistant that is not connected.</summary>
    public Task<OperationResult> ConnectAllAsync()
    {
        List<string> keys = [.. Rows.Where(r => r.State != McpClientState.NotInstalled && !r.IsConnected).Select(r => r.Client.Key)];
        return RunAsync(async token =>
        {
            List<string> lines = [];
            foreach (string key in keys)
            {
                McpInstallResponse installed = await client.McpInstallAsync(
                    new McpInstallRequest { Target = key, Stdio = true, Force = true }, Options(token)).ConfigureAwait(true);
                lines.Add(Describe(installed));
            }
            return lines.Count == 0 ? "Every installed assistant is already connected" : string.Join('\n', lines);
        });
    }

    /// <summary>Removes Garage's entry from one assistant's config.</summary>
    public Task<OperationResult> DisconnectAsync(string key) => RunAsync(async token =>
    {
        McpUninstallResponse removed = await client.McpUninstallAsync(new McpUninstallRequest { Target = key }, Options(token)).ConfigureAwait(true);
        return string.IsNullOrEmpty(removed.Message) ? (removed.Removed ? $"Disconnected from {removed.Path}" : "Nothing to remove") : removed.Message;
    });

    private static string Describe(McpInstallResponse installed)
    {
        if (!string.IsNullOrEmpty(installed.Message))
        {
            return installed.Message;
        }
        return string.Join('\n', installed.Outcomes.Select(o => o.Written
            ? $"{o.Label}: connected ({o.Path})"
            : $"{o.Label}: {(string.IsNullOrEmpty(o.Skipped) ? "unchanged" : o.Skipped)}"));
    }

    private void RecomputeHeadline()
    {
        McpServerStatus status = _http?.Service is not { } service
            ? new McpServerStatus(McpServerState.Stopped)
            : service.State switch
            {
                ServiceState.Running => new McpServerStatus(McpServerState.Running),
                ServiceState.Checking or ServiceState.Restarting => new McpServerStatus(McpServerState.Starting),
                ServiceState.Unreachable => new McpServerStatus(McpServerState.Failed, service.Error),
                _ => new McpServerStatus(McpServerState.Stopped),
            };
        Headline = McpServerHeadline.For(status, null, false, true, _connected, HttpEnabled || status.State != McpServerState.Stopped);
        OnPropertyChanged(nameof(HttpUrl));
    }

    private async Task<OperationResult> RunAsync(Func<CancellationToken, Task<string>> operation)
    {
        OperationResult result = await runner.RunAsync((_, token) => operation(token)).ConfigureAwait(true);
        LastResult = result.Output;
        await LoadAsync().ConfigureAwait(true);
        return result;
    }

    private static CallOptions Options(CancellationToken cancellationToken) =>
        new(deadline: DateTime.UtcNow + CallTimeout, cancellationToken: cancellationToken);
}

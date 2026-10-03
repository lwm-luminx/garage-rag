using Garage.App.Core.Database;
using Garage.App.Core.Library;
using Garage.App.Core.Mcp;
using Garage.App.Core.Services;
using Garage.App.Core.State;

namespace Garage.App.Core.Tray;

/// <summary>
/// Reads the live app into the plain values the tray and the setup assistant decide from (the Mac's
/// <c>MenuBarStatus(appState:)</c> and <c>FirstRunCoordinator.serviceChecks</c>).
/// </summary>
public static class TrayStatusReader
{
    /// <summary>The database as the app sees it: its own Postgres, else the server the backend reaches.</summary>
    public static PostgresStatus Database(AppState state, DatabaseViewModel database)
    {
        ArgumentNullException.ThrowIfNull(state);
        ArgumentNullException.ThrowIfNull(database);
        return database.EffectiveStatus ?? state.Connection switch
        {
            BackendConnection.Connected => new PostgresStatus(PostgresState.Running),
            BackendConnection.Unavailable => new PostgresStatus(PostgresState.Failed, state.ConnectionError),
            _ => new PostgresStatus(PostgresState.Starting),
        };
    }

    /// <summary>A service process as a server state.</summary>
    public static McpServerStatus Service(ServiceProcess? service, BackendConnection connection) => service is null
        ? connection switch
        {
            BackendConnection.Connected => new McpServerStatus(McpServerState.Running),
            BackendConnection.Unavailable => new McpServerStatus(McpServerState.Failed, "Garage isn't reachable"),
            _ => new McpServerStatus(McpServerState.Starting),
        }
        : service.State switch
        {
            ServiceState.Running => new McpServerStatus(McpServerState.Running),
            ServiceState.Checking or ServiceState.Restarting or ServiceState.Unknown => new McpServerStatus(McpServerState.Starting),
            ServiceState.Unreachable => new McpServerStatus(McpServerState.Failed, service.Error),
            _ => new McpServerStatus(McpServerState.Stopped),
        };

    /// <summary>The MCP server: its service's state, or stdio when HTTP is off by choice.</summary>
    public static TrayServer Mcp(AppState state, McpViewModel mcp)
    {
        ArgumentNullException.ThrowIfNull(state);
        ArgumentNullException.ThrowIfNull(mcp);
        int clients = mcp.Rows.Count(r => r.IsConnected);
        if (state.Backend.Host is null)
        {
            // A development backend: its MCP server is a `garage mcp-serve` started by hand, if any.
            return state.Backend.Mcp is null ? new TrayServer(TrayServerState.Stdio, clients) : new TrayServer(TrayServerState.Running, clients);
        }
        ServiceProcess? service = mcp.Http?.Service;
        return service?.State switch
        {
            ServiceState.Running => new TrayServer(TrayServerState.Running, clients),
            ServiceState.Checking or ServiceState.Restarting => new TrayServer(TrayServerState.Starting, clients),
            ServiceState.Unreachable => new TrayServer(TrayServerState.Failed, clients, service.Error),
            _ => mcp.HttpEnabled ? new TrayServer(TrayServerState.Stopped, clients) : new TrayServer(TrayServerState.Stdio, clients),
        };
    }

    /// <summary>What the pipeline is doing, from the Status page's reading of it.</summary>
    public static TrayActivity Activity(LibraryActivity activity) => activity switch
    {
        LibraryActivity.Scanning scanning => new TrayActivity.Scanning(scanning.ItemsSoFar > 0 ? scanning.ItemsSoFar : null),
        LibraryActivity.Ingesting ingesting => new TrayActivity.Ingesting(new TrayIngestProgress(
            ingesting.Subject ?? "",
            ingesting.Run?.Seen ?? 0,
            ingesting.Run?.Total ?? 0,
            string.IsNullOrEmpty(ingesting.Run?.ItemType) ? "documents" : ingesting.Run.ItemType,
            ingesting.Run?.CurrentItem,
            ingesting.Run?.Fraction)),
        LibraryActivity.Waiting => new TrayActivity.Ingesting(new TrayIngestProgress("")),
        LibraryActivity.Embedding => new TrayActivity.Embedding(),
        LibraryActivity.Distilling => new TrayActivity.Distilling(),
        _ => TrayActivity.None,
    };

    /// <summary>The whole tray status.</summary>
    public static TrayStatus Read(AppState state, StatusViewModel status, DatabaseViewModel database, McpViewModel mcp)
    {
        ArgumentNullException.ThrowIfNull(state);
        ArgumentNullException.ThrowIfNull(status);
        return new TrayStatus(
            Database(state, database),
            Mcp(state, mcp),
            Activity(status.CurrentActivity()),
            status.Library.LastRunError,
            state.Counts?.Sources ?? 0,
            state.Counts?.Documents ?? 0,
            status.Library.IsCancellingAll);
    }
}

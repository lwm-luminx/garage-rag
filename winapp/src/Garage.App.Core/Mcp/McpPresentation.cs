using System.Globalization;
using System.Text.Json;
using Garage.App.Core.Presentation;

namespace Garage.App.Core.Mcp;

/// <summary>Where the app's HTTP MCP server stands (the Mac's <c>GarageMCPStatus</c>).</summary>
public enum McpServerState
{
    /// <summary>Starting.</summary>
    Starting,

    /// <summary>Running.</summary>
    Running,

    /// <summary>Stopping.</summary>
    Stopping,

    /// <summary>Stopped.</summary>
    Stopped,

    /// <summary>Failed to start.</summary>
    Failed,
}

/// <summary>The server's state, with the failure when <see cref="McpServerState.Failed"/>.</summary>
public sealed record McpServerStatus(McpServerState State, string? FailureMessage = null);

/// <summary>The last check that the server answers.</summary>
public sealed record McpTestResult(bool IsSuccess, int ToolCount = 0, string? ErrorMessage = null);

/// <summary>The server row (the Mac's <c>MCPServerHeadline</c>; "this Mac" reads "this PC").</summary>
public sealed record McpServerHeadline(StatusSymbol Symbol, Tint Tint, bool IsActive, string Title, string Detail, bool DetailIsError = false)
{
    /// <summary>The row for the server's state.</summary>
    /// <param name="status">Where the server stands.</param>
    /// <param name="test">The last check; ignored unless the server is running.</param>
    /// <param name="isTesting">Whether a check is in flight.</param>
    /// <param name="isDatabaseRunning">Whether the database is up.</param>
    /// <param name="connectedCount">Assistants registered with the server.</param>
    /// <param name="httpEnabled">Whether the app serves HTTP at all; off, a stopped server is the normal state.</param>
    public static McpServerHeadline For(McpServerStatus status, McpTestResult? test, bool isTesting, bool isDatabaseRunning, int connectedCount, bool httpEnabled = true)
    {
        ArgumentNullException.ThrowIfNull(status);
        if (status.State == McpServerState.Stopped && !httpEnabled)
        {
            return new(StatusSymbol.Terminal, Tint.Green, connectedCount > 0, "HTTP off",
                "Connected assistants start Garage themselves and talk to it over stdio; no port is open. Start the HTTP server only for an assistant that needs an address.");
        }
        switch (status.State)
        {
            case McpServerState.Running when isTesting:
                return new(StatusSymbol.Server, Tint.Green, true, "Running", "Checking that it answers…");
            case McpServerState.Running when test is { IsSuccess: false }:
                return new(StatusSymbol.Warning, Tint.Orange, true, "Running, but not answering", test.ErrorMessage ?? "The last check got no reply.", DetailIsError: true);
            case McpServerState.Running when test is not null:
                return new(StatusSymbol.Checkmark, Tint.Green, true, "Running",
                    string.Create(CultureInfo.CurrentCulture, $"Answering on this PC only · {test.ToolCount} {McpPagePresentation.Plural("tool", test.ToolCount)}"));
            case McpServerState.Running:
                return new(StatusSymbol.Server, Tint.Green, true, "Running", "Listening on this PC only");
            case McpServerState.Starting:
                return new(StatusSymbol.Server, Tint.Blue, true, "Starting…", isDatabaseRunning ? "Starting the server…" : "Starting the database first…");
            case McpServerState.Stopping:
                return new(StatusSymbol.Server, Tint.Blue, true, "Stopping…", "Stopping the server…");
            case McpServerState.Stopped:
                string detail = connectedCount > 0
                    ? string.Create(CultureInfo.CurrentCulture, $"{connectedCount} connected {McpPagePresentation.Plural("assistant", connectedCount)} can't reach Garage until it runs.")
                    : "Assistants reach Garage through this server once they're connected.";
                if (!isDatabaseRunning)
                {
                    detail += " Starting it also starts the database.";
                }
                return new(StatusSymbol.Server, Tint.Secondary, false, "Stopped", detail);
            default:
                return new(StatusSymbol.Cross, Tint.Red, true, "Couldn't start", status.FailureMessage ?? "", DetailIsError: true);
        }
    }
}

/// <summary>One assistant's config: where it is and what it says about Garage.</summary>
public sealed record McpClient(string Key, string Label, string Path, bool ExistsOnDisk, bool IsRegistered, string? RegisteredUrl);

/// <summary>An assistant's standing with this server.</summary>
public enum McpClientState
{
    /// <summary>Registered at this server's address, or as a stdio command.</summary>
    Connected,

    /// <summary>Registered at an address the server no longer listens on.</summary>
    Outdated,

    /// <summary>The config exists without an entry for Garage.</summary>
    NotConnected,

    /// <summary>No config file: probably not installed.</summary>
    NotInstalled,
}

/// <summary>What an assistant's glyph shows.</summary>
public enum McpClientSymbol
{
    /// <summary>A chat app (Claude Desktop).</summary>
    Chat,

    /// <summary>A terminal (Claude Code).</summary>
    Terminal,

    /// <summary>A model app (LM Studio).</summary>
    Chip,

    /// <summary>An editor (Cursor, VS Code, Windsurf, Zed).</summary>
    Editor,

    /// <summary>Anything else.</summary>
    Extension,
}

/// <summary>One assistant row (the Mac's <c>MCPClientRowPresentation</c>).</summary>
public sealed record McpClientRowPresentation(McpClient Client, McpClientState State, McpClientSymbol Symbol, Tint Tint, bool IsActive, string Status, string? ActionTitle)
{
    /// <summary>The row, given the HTTP address assistants are registered at (null when HTTP is off and they run stdio).</summary>
    public static McpClientRowPresentation For(McpClient client, Uri? endpoint)
    {
        ArgumentNullException.ThrowIfNull(client);
        McpClientSymbol symbol = SymbolFor(client.Key);
        if (client.IsRegistered)
        {
            if (client.RegisteredUrl is { } url && endpoint is null)
            {
                return new(client, McpClientState.Outdated, symbol, Tint.Orange, true, $"Points at {url}, but the HTTP server is off", "Update");
            }
            if (client.RegisteredUrl is { } other && endpoint is not null && !SameEndpoint(other, endpoint))
            {
                return new(client, McpClientState.Outdated, symbol, Tint.Orange, true, $"Points at {other}, not {endpoint.AbsoluteUri}", "Update");
            }
            return new(client, McpClientState.Connected, symbol, Tint.Green, true, "Connected", null);
        }
        return client.ExistsOnDisk
            ? new(client, McpClientState.NotConnected, symbol, Tint.Blue, false, "Installed, not connected", "Connect")
            : new(client, McpClientState.NotInstalled, symbol, Tint.Secondary, false, "Not found on this PC", "Connect");
    }

    /// <summary>Whether it is connected.</summary>
    public bool IsConnected => State == McpClientState.Connected;

    /// <summary>Whether it points at an old address.</summary>
    public bool IsOutdated => State == McpClientState.Outdated;

    /// <summary>The glyph for a client key.</summary>
    public static McpClientSymbol SymbolFor(string key) => key switch
    {
        "claude-desktop" => McpClientSymbol.Chat,
        "project" or "claude-code-user" => McpClientSymbol.Terminal,
        "lmstudio" => McpClientSymbol.Chip,
        "cursor" or "cursor-global" or "vscode" or "vscode-global" or "windsurf" or "zed" => McpClientSymbol.Editor,
        _ => McpClientSymbol.Extension,
    };

    /// <summary>The same server, ignoring trailing slashes and case.</summary>
    public static bool SameEndpoint(string registered, Uri endpoint)
    {
        ArgumentNullException.ThrowIfNull(registered);
        ArgumentNullException.ThrowIfNull(endpoint);
        static string Normalized(string value) => value.Trim().ToLowerInvariant().TrimEnd('/');
        return Normalized(registered) == Normalized(endpoint.AbsoluteUri);
    }
}

/// <summary>The summary over the assistant list (the Mac's <c>MCPPagePresentation</c>).</summary>
public static class McpPagePresentation
{
    /// <summary>"1 of 3 installed assistants connected · 1 needs updating", and the other cases.</summary>
    public static string ClientSummary(IReadOnlyList<McpClientRowPresentation> rows)
    {
        ArgumentNullException.ThrowIfNull(rows);
        int installed = rows.Count(r => r.State != McpClientState.NotInstalled);
        int connected = rows.Count(r => r.IsConnected);
        int outdated = rows.Count(r => r.IsOutdated);
        if (installed == 0)
        {
            return "No assistants found on this PC";
        }
        string summary = connected == 0 && outdated == 0
            ? string.Create(CultureInfo.CurrentCulture, $"None of {installed} installed {Plural("assistant", installed)} connected yet")
            : connected == installed
                ? connected == 1 ? "Your assistant is connected" : string.Create(CultureInfo.CurrentCulture, $"All {connected} installed assistants are connected")
                : string.Create(CultureInfo.CurrentCulture, $"{connected} of {installed} installed {Plural("assistant", installed)} connected");
        if (outdated > 0)
        {
            summary += string.Create(CultureInfo.CurrentCulture, $" · {outdated} {(outdated == 1 ? "needs" : "need")} updating");
        }
        return summary;
    }

    /// <summary>Whether Connect All has anything to do.</summary>
    public static bool CanConnectAll(IReadOnlyList<McpClientRowPresentation> rows)
    {
        ArgumentNullException.ThrowIfNull(rows);
        return rows.Any(r => r.State != McpClientState.NotInstalled && !r.IsConnected);
    }

    /// <summary>"tool" or "tools".</summary>
    public static string Plural(string word, int count) => count == 1 ? word : word + "s";
}

/// <summary>
/// Reads an assistant's config file for Garage's entry, as the Mac reads it to tell an HTTP entry
/// from a stdio one: the <c>url</c> of the named server under <c>mcpServers</c> (Claude, Cursor, ...),
/// <c>servers</c> (VS Code) or <c>context_servers</c> (Zed).
/// </summary>
public static class McpClientConfigReader
{
    private static readonly string[] Containers = ["mcpServers", "servers", "context_servers"];

    /// <summary>The registered URL, or null for a stdio entry, no entry, or an unreadable file.</summary>
    public static string? RegisteredUrl(string path, string serverName = "garage-rag")
    {
        ArgumentNullException.ThrowIfNull(path);
        try
        {
            return File.Exists(path) ? RegisteredUrlIn(File.ReadAllText(path), serverName) : null;
        }
        catch (IOException)
        {
            return null;
        }
        catch (UnauthorizedAccessException)
        {
            return null;
        }
    }

    /// <summary>The same, from the file's text.</summary>
    public static string? RegisteredUrlIn(string json, string serverName = "garage-rag")
    {
        if (string.IsNullOrWhiteSpace(json))
        {
            return null;
        }
        try
        {
            using JsonDocument document = JsonDocument.Parse(json, new JsonDocumentOptions { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true });
            if (document.RootElement.ValueKind != JsonValueKind.Object)
            {
                return null;
            }
            foreach (string container in Containers)
            {
                if (document.RootElement.TryGetProperty(container, out JsonElement servers)
                    && servers.ValueKind == JsonValueKind.Object
                    && servers.TryGetProperty(serverName, out JsonElement entry)
                    && entry.ValueKind == JsonValueKind.Object
                    && entry.TryGetProperty("url", out JsonElement url)
                    && url.ValueKind == JsonValueKind.String)
                {
                    return url.GetString();
                }
            }
            return null;
        }
        catch (JsonException)
        {
            return null;
        }
    }
}

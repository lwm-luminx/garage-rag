using System.Runtime.Versioning;
using Garage.App.Core.Services;

namespace Garage.App.Core.Mcp;

/// <summary>
/// The app's MCP HTTP server: the service that runs it, its address, and the switch. The Mac's
/// <c>GarageMCPService</c> start/stop, over the Windows MCP service process.
/// </summary>
public interface IMcpHttpHost
{
    /// <summary>The service process; its state is the server's.</summary>
    ServiceProcess Service { get; }

    /// <summary>Where the server listens: <c>http://127.0.0.1:8787/mcp</c>.</summary>
    Uri Url { get; }

    /// <summary>Starts or stops the server; returns whether it reached the asked-for state.</summary>
    Task<bool> SetEnabledAsync(bool enabled);
}

/// <summary>The MCP HTTP server as the app's <see cref="ServiceManager"/> runs it.</summary>
[SupportedOSPlatform("windows")]
public sealed class ServiceMcpHost(ServiceManager services) : IMcpHttpHost
{
    /// <inheritdoc/>
    public ServiceProcess Service => services.Mcp;

    /// <inheritdoc/>
    public Uri Url => services.McpUrl;

    /// <inheritdoc/>
    public Task<bool> SetEnabledAsync(bool enabled) => services.SetMcpEnabledAsync(enabled);
}

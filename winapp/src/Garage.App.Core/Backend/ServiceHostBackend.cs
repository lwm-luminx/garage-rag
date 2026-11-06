using System.Runtime.Versioning;
using Garage.App.Core.Library;
using Garage.App.Core.Services;
using Garage.Grpc;

namespace Garage.App.Core.Backend;

/// <summary>
/// The backend a shipped app uses (docs/plans/windows-ui.md §2.3): the app's own service processes,
/// started by a <see cref="ServiceManager"/>, with the backend on a loopback port behind this launch's
/// token and ingest in its own process.
/// </summary>
[SupportedOSPlatform("windows")]
public sealed class ServiceHostBackend(ServiceManager services) : IBackend
{
    private readonly ServiceIngestHost _ingest = new(services.Ingest);

    /// <summary>The service processes.</summary>
    public ServiceManager Services { get; } = services;

    /// <inheritdoc/>
    public GarageEndpoint Grpc => Services.Grpc;

    /// <inheritdoc/>
    /// <remarks>The MCP HTTP service's address while it runs (the MCP Server page's switch).</remarks>
    public Uri? Mcp => Services.Mcp.State == ServiceState.Running ? Services.McpUrl : null;

    /// <inheritdoc/>
    public IServiceHost? Host => Services;

    /// <inheritdoc/>
    public IIngestHost Ingest => _ingest;

    /// <inheritdoc/>
    public string Description => $"Garage's services: backend on 127.0.0.1:{Services.GrpcPort}, data in {Services.Layout.DataDirectory}";
}

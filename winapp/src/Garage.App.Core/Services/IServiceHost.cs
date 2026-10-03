using Garage.Grpc.Services;

namespace Garage.App.Core.Services;

/// <summary>
/// The app's own service processes, as the Status page sees them: the counterpart of the Mac's
/// <c>XPCServiceManager</c> surface (refresh, test, restart). <see cref="ServiceManager"/> implements it.
/// </summary>
public interface IServiceHost
{
    /// <summary>Every service, in the Status page's order.</summary>
    IReadOnlyList<ServiceProcess> Services { get; }

    /// <summary>Asks one service for its state.</summary>
    Task RefreshAsync(ServiceProcess service, CancellationToken cancellationToken = default);

    /// <summary>Runs one service's self tests.</summary>
    Task<ServiceStatusReport?> RunSelfTestsAsync(ServiceProcess service, CancellationToken cancellationToken = default);

    /// <summary>Stops and starts one service.</summary>
    Task<bool> RestartAsync(ServiceProcess service, CancellationToken cancellationToken = default);
}

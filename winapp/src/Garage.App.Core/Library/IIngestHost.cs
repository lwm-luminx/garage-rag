using System.Runtime.CompilerServices;
using System.Runtime.Versioning;
using Garage.App.Core.Services;
using Garage.Grpc.Services;
using Grpc.Core;

namespace Garage.App.Core.Library;

/// <summary>
/// Where ingests run: the ingest service (the Mac's <c>IngestService</c> over GarageIngestXPCService).
/// A development backend has none, and the Sources page says so.
/// </summary>
public interface IIngestHost
{
    /// <summary>Why ingest cannot run now, or null when it can.</summary>
    string? Unavailable { get; }

    /// <summary>
    /// Ingests one source, streaming <c>garage_rag.ingest</c>'s progress. Cancelling
    /// <paramref name="cancellationToken"/> stops the ingest at its next item.
    /// </summary>
    IAsyncEnumerable<IngestProgress> IngestAsync(IngestSourceRequest request, CancellationToken cancellationToken);
}

/// <summary>No ingest: the app runs against a <c>garage serve</c> started by hand.</summary>
public sealed class NoIngestHost : IIngestHost
{
    /// <summary>The shared instance.</summary>
    public static NoIngestHost Instance { get; } = new();

    /// <inheritdoc/>
    public string? Unavailable => "Ingest runs in Garage's own services; this window is connected to a development backend.";

    /// <inheritdoc/>
    public IAsyncEnumerable<IngestProgress> IngestAsync(IngestSourceRequest request, CancellationToken cancellationToken) =>
        throw new InvalidOperationException(Unavailable);
}

/// <summary>Ingest through the ingest service process.</summary>
[SupportedOSPlatform("windows")]
public sealed class ServiceIngestHost(ServiceProcess ingest) : IIngestHost
{
    /// <inheritdoc/>
    public string? Unavailable => ingest.State switch
    {
        ServiceState.Running => null,
        ServiceState.Checking or ServiceState.Restarting or ServiceState.Unknown => "The ingest service is starting.",
        _ => $"The ingest service isn't running{(ingest.Error is { Length: > 0 } e ? $": {e}" : ".")}",
    };

    /// <inheritdoc/>
    public async IAsyncEnumerable<IngestProgress> IngestAsync(IngestSourceRequest request, [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        IngestControl.IngestControlClient client = ingest.Ingest ?? throw new InvalidOperationException(Unavailable ?? "The ingest service is not started.");
        using AsyncServerStreamingCall<IngestProgress> call = client.IngestSource(request, cancellationToken: cancellationToken);
        await foreach (IngestProgress progress in call.ResponseStream.ReadAllAsync(cancellationToken).ConfigureAwait(true))
        {
            yield return progress;
        }
    }
}

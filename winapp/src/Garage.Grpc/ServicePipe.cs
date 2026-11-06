using System.IO.Pipes;
using System.Security.Principal;
using Grpc.Net.Client;

namespace Garage.Grpc;

/// <summary>
/// The named pipe a Garage service's control plane listens on (docs/plans/windows.md §2.1), and a
/// gRPC channel to it. The name carries the user's SID and the logon session, so two accounts, or
/// two sessions of one account, never meet on a pipe; the server's ACL grants that user alone.
/// </summary>
[System.Runtime.Versioning.SupportedOSPlatform("windows")]
public static class ServicePipe
{
    /// <summary>Every Garage pipe name starts with this.</summary>
    public const string Prefix = "Garage";

    /// <summary>
    /// <c>Garage-&lt;SID&gt;-&lt;session&gt;-&lt;instance&gt;-&lt;service&gt;</c>. <paramref name="instance"/> tells two
    /// launches apart, so a service left over from a crashed app is never reached by the new one.
    /// </summary>
    public static string Name(string instance, string serviceId)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(instance);
        ArgumentException.ThrowIfNullOrWhiteSpace(serviceId);
        using WindowsIdentity user = WindowsIdentity.GetCurrent();
        string sid = user.User?.Value ?? "unknown";
        return $"{Prefix}-{sid}-{SessionId()}-{instance}-{serviceId}";
    }

    /// <summary>
    /// A channel whose every connection is a new client end of <paramref name="pipeName"/>. The
    /// address is a placeholder: HTTP/2 needs an authority, the pipe decides where the bytes go.
    /// </summary>
    public static GrpcChannel OpenChannel(string pipeName, TimeSpan? connectTimeout = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(pipeName);
        int timeoutMs = (int)(connectTimeout ?? TimeSpan.FromSeconds(5)).TotalMilliseconds;
        var handler = new SocketsHttpHandler
        {
            ConnectCallback = async (_, cancellationToken) =>
            {
                var pipe = new NamedPipeClientStream(
                    ".", pipeName, PipeDirection.InOut, PipeOptions.Asynchronous,
                    // The service learns who called from the pipe (the peer check), not from impersonation.
                    TokenImpersonationLevel.Identification);
                try
                {
                    using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                    timeout.CancelAfter(timeoutMs);
                    await pipe.ConnectAsync(timeout.Token).ConfigureAwait(false);
                    return pipe;
                }
                catch
                {
                    await pipe.DisposeAsync().ConfigureAwait(false);
                    throw;
                }
            },
            // A service's log stream stays open for the app's lifetime.
            KeepAlivePingPolicy = HttpKeepAlivePingPolicy.WithActiveRequests,
        };
        return GrpcChannel.ForAddress("http://garage-service", new GrpcChannelOptions
        {
            HttpHandler = handler,
            DisposeHttpClient = true,
            MaxReceiveMessageSize = GarageEndpoint.MaxReceiveMessageBytes,
        });
    }

    private static int SessionId()
    {
        using var process = System.Diagnostics.Process.GetCurrentProcess();
        return process.SessionId;
    }
}

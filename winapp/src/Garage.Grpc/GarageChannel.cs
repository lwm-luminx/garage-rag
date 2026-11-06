using Grpc.Core;
using Grpc.Core.Interceptors;
using Grpc.Net.Client;

namespace Garage.Grpc;

/// <summary>
/// Where a <c>GarageService</c> listens and how to authenticate to it: the counterpart of the
/// macOS app's <c>GarageGRPCService</c> connection settings.
/// </summary>
/// <param name="Address">An <c>http://</c> address; the server speaks cleartext HTTP/2 on loopback.</param>
/// <param name="Token">
/// The per-launch token (<c>GARAGE_GRPC_TOKEN</c>), sent as <c>x-garage-token</c> on every call.
/// Null for a server started without one, which then refuses config-changing methods over TCP.
/// </param>
public sealed record GarageEndpoint(Uri Address, string? Token)
{
    /// <summary>The metadata key <c>garage_rag.service.auth</c> checks.</summary>
    public const string TokenMetadataKey = "x-garage-token";

    /// <summary>
    /// Largest reply the client accepts. <c>GetDocument</c> carries a whole document's text and
    /// chunks, far beyond gRPC's 4 MiB default; the server accepts requests up to 256 MiB.
    /// </summary>
    public const int MaxReceiveMessageBytes = 256 * 1024 * 1024;

    /// <summary>Opens a channel to this endpoint.</summary>
    public GrpcChannel OpenChannel() =>
        GrpcChannel.ForAddress(Address, new GrpcChannelOptions
        {
            MaxReceiveMessageSize = MaxReceiveMessageBytes,
            MaxSendMessageSize = MaxReceiveMessageBytes,
        });

    /// <summary>A <c>GarageService</c> client over <paramref name="channel"/> that sends this endpoint's token.</summary>
    public GarageService.GarageServiceClient CreateClient(ChannelBase channel)
    {
        ArgumentNullException.ThrowIfNull(channel);
        CallInvoker invoker = channel.CreateCallInvoker();
        if (!string.IsNullOrEmpty(Token))
        {
            invoker = invoker.Intercept(new TokenInterceptor(Token));
        }
        return new GarageService.GarageServiceClient(invoker);
    }

    /// <summary>Keeps the token out of logs and <c>ToString</c>.</summary>
    public override string ToString() => $"{Address} ({(Token is null ? "no token" : "token set")})";
}

/// <summary>Adds <c>x-garage-token</c> to every call, replacing any value already present.</summary>
internal sealed class TokenInterceptor(string token) : Interceptor
{
    public override AsyncUnaryCall<TResponse> AsyncUnaryCall<TRequest, TResponse>(
        TRequest request, ClientInterceptorContext<TRequest, TResponse> context,
        AsyncUnaryCallContinuation<TRequest, TResponse> continuation) =>
        continuation(request, WithToken(context));

    public override AsyncServerStreamingCall<TResponse> AsyncServerStreamingCall<TRequest, TResponse>(
        TRequest request, ClientInterceptorContext<TRequest, TResponse> context,
        AsyncServerStreamingCallContinuation<TRequest, TResponse> continuation) =>
        continuation(request, WithToken(context));

    public override TResponse BlockingUnaryCall<TRequest, TResponse>(
        TRequest request, ClientInterceptorContext<TRequest, TResponse> context,
        BlockingUnaryCallContinuation<TRequest, TResponse> continuation) =>
        continuation(request, WithToken(context));

    private ClientInterceptorContext<TRequest, TResponse> WithToken<TRequest, TResponse>(
        ClientInterceptorContext<TRequest, TResponse> context)
        where TRequest : class
        where TResponse : class
    {
        Metadata headers = [];
        foreach (Metadata.Entry entry in context.Options.Headers ?? [])
        {
            if (!string.Equals(entry.Key, GarageEndpoint.TokenMetadataKey, StringComparison.OrdinalIgnoreCase))
            {
                headers.Add(entry);
            }
        }
        headers.Add(GarageEndpoint.TokenMetadataKey, token);
        return new ClientInterceptorContext<TRequest, TResponse>(
            context.Method, context.Host, context.Options.WithHeaders(headers));
    }
}

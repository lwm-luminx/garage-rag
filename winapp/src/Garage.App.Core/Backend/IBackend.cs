using System.Globalization;
using Garage.App.Core.Library;
using Garage.App.Core.Services;
using Garage.Grpc;

namespace Garage.App.Core.Backend;

/// <summary>
/// Where the app's backend is: the <c>GarageService</c> endpoint, and the MCP endpoint Ask Garage
/// calls <c>rag_agent</c> through (docs/plans/windows-ui.md §2.3).
/// </summary>
public interface IBackend
{
    /// <summary>One line for the Status page and logs, with no secrets.</summary>
    string Description { get; }

    /// <summary>The gRPC endpoint.</summary>
    GarageEndpoint Grpc { get; }

    /// <summary>The MCP endpoint (streamable HTTP), or null when none is configured.</summary>
    Uri? Mcp { get; }

    /// <summary>The app's own service processes, or null for a backend started by hand.</summary>
    IServiceHost? Host { get; }

    /// <summary>Where ingests run.</summary>
    IIngestHost Ingest { get; }
}

/// <summary>
/// A backend a developer started by hand: <c>garage serve</c> (and optionally <c>garage mcp-serve</c>)
/// from a venv. Chosen with <c>--dev-backend</c> or <c>GARAGE_GRPC_PORT</c>, and never in a shipped build.
/// </summary>
/// <remarks>
/// Read from the environment, using the names the Python side already uses:
/// <list type="bullet">
/// <item><c>GARAGE_GRPC_HOST</c> (default <c>127.0.0.1</c>) and <c>GARAGE_GRPC_PORT</c> (default <c>50051</c>);</item>
/// <item><c>GARAGE_GRPC_TOKEN</c>: start <c>garage serve</c> with the same value, so the server
/// answers config-changing methods over loopback (<c>service/auth.py</c>);</item>
/// <item><c>GARAGE_MCP_URL</c> (default <c>http://127.0.0.1:8787/mcp</c>, <c>garage mcp-serve</c>'s address).</item>
/// </list>
/// </remarks>
public sealed class DevBackend : IBackend
{
    /// <summary>The address <c>garage serve</c> listens on by default.</summary>
    public const string DefaultHost = "127.0.0.1";

    /// <summary>The port <c>garage serve</c> listens on by default.</summary>
    public const int DefaultPort = 50051;

    /// <summary>Where <c>garage mcp-serve</c> listens by default.</summary>
    public static readonly Uri DefaultMcp = new("http://127.0.0.1:8787/mcp");

    private DevBackend(GarageEndpoint grpc, Uri? mcp)
    {
        Grpc = grpc;
        Mcp = mcp;
    }

    /// <inheritdoc/>
    public GarageEndpoint Grpc { get; }

    /// <inheritdoc/>
    public Uri? Mcp { get; }

    /// <inheritdoc/>
    public IServiceHost? Host => null;

    /// <inheritdoc/>
    public IIngestHost Ingest => NoIngestHost.Instance;

    /// <inheritdoc/>
    public string Description => $"Development backend: garage serve at {Grpc.Address.Authority}"
        + (Grpc.Token is null ? " (no token: settings and sources are read-only)" : "");

    /// <summary>Reads the backend from <paramref name="environment"/> (the process environment when null).</summary>
    /// <exception cref="ArgumentException">A variable holds a value that cannot be used.</exception>
    public static DevBackend FromEnvironment(IReadOnlyDictionary<string, string?>? environment = null)
    {
        string? Read(string name)
        {
            string? value = environment is null
                ? Environment.GetEnvironmentVariable(name)
                : environment.GetValueOrDefault(name);
            return string.IsNullOrWhiteSpace(value) ? null : value.Trim();
        }

        string host = Read("GARAGE_GRPC_HOST") ?? DefaultHost;
        int port = DefaultPort;
        if (Read("GARAGE_GRPC_PORT") is { } portText
            && (!int.TryParse(portText, NumberStyles.None, CultureInfo.InvariantCulture, out port) || port is < 1 or > 65535))
        {
            throw new ArgumentException($"GARAGE_GRPC_PORT must be a port number (1-65535), not '{portText}'");
        }

        Uri? mcp = DefaultMcp;
        if (Read("GARAGE_MCP_URL") is { } mcpText
            && (!Uri.TryCreate(mcpText, UriKind.Absolute, out mcp) || (mcp.Scheme != Uri.UriSchemeHttp && mcp.Scheme != Uri.UriSchemeHttps)))
        {
            throw new ArgumentException($"GARAGE_MCP_URL must be an http(s) URL, not '{mcpText}'");
        }

        var address = new UriBuilder(Uri.UriSchemeHttp, host, port).Uri;
        return new DevBackend(new GarageEndpoint(address, Read("GARAGE_GRPC_TOKEN")), mcp);
    }
}

using System.Globalization;

namespace Garage.Services;

/// <summary>Which service a process runs.</summary>
internal enum ServiceRole
{
    /// <summary>The GarageService gRPC backend (the Mac's GarageXPCService).</summary>
    Core,

    /// <summary>Ingestion (the Mac's GarageIngestXPCService).</summary>
    Ingest,

    /// <summary>MCP over HTTP (the Mac's GarageMCPServerService), only while it is switched on.</summary>
    Mcp,
}

/// <summary>
/// A service process's start-up settings: its command line, set by the app's <c>ServiceManager</c>,
/// and the environment it inherits. Secrets (<c>GARAGE_GRPC_TOKEN</c>, a database URL) come only
/// through the environment, never the command line, which every process of the account can read.
/// </summary>
/// <remarks>
/// <code>
/// Garage.Services --service core|ingest|mcp --pipe NAME --parent PID --grpc-port N [--data-dir DIR] [--mcp-port N]
/// </code>
/// Environment:
/// <list type="bullet">
/// <item><c>GARAGE_NATIVE_DIR</c>: the folder holding the Rust libraries (<c>garage_service_ffi.dll</c>,
/// <c>garage_ingest_ffi.dll</c>, <c>garage_mcp_ffi.dll</c>) when they are not beside the executable
/// (a checkout's <c>rust\target\release</c> during development);</item>
/// <item><c>GARAGE_SQL_DIR</c>: the schema <c>InitDb</c> applies (<c>data\sql</c>; the shipped <c>schema\</c>);</item>
/// <item><c>GARAGE_GRPC_TOKEN</c>: the backend's per-launch token.</item>
/// </list>
/// </remarks>
internal sealed record ServiceOptions(
    ServiceRole Role,
    string PipeName,
    int ParentPid,
    int GrpcPort,
    string DataDirectory,
    int McpPort,
    string? NativeDirectory,
    string? SchemaDirectory)
{
    /// <summary>The service's identifier in logs, pipe names and the Status page ("core", "ingest").</summary>
    public string ServiceId => Role switch
    {
        ServiceRole.Core => "core",
        ServiceRole.Ingest => "ingest",
        ServiceRole.Mcp => "mcp",
        _ => throw new InvalidOperationException(),
    };

    /// <summary>Parses the command line and environment; throws <see cref="ArgumentException"/> with what is wrong.</summary>
    public static ServiceOptions Parse(IReadOnlyList<string> args, Func<string, string?> environment)
    {
        ArgumentNullException.ThrowIfNull(args);
        ArgumentNullException.ThrowIfNull(environment);
        Dictionary<string, string> values = new(StringComparer.Ordinal);
        for (int i = 0; i < args.Count; i++)
        {
            string name = args[i];
            if (!name.StartsWith("--", StringComparison.Ordinal) || i + 1 >= args.Count)
            {
                throw new ArgumentException($"expected '--name value', found '{name}'");
            }
            values[name[2..]] = args[++i];
        }

        string Required(string name) => values.GetValueOrDefault(name) is { Length: > 0 } value
            ? value
            : throw new ArgumentException($"--{name} is required");

        ServiceRole role = Required("service") switch
        {
            "core" => ServiceRole.Core,
            "ingest" => ServiceRole.Ingest,
            "mcp" => ServiceRole.Mcp,
            var other => throw new ArgumentException($"unknown service '{other}' (expected core, ingest or mcp)"),
        };
        int parent = Number("parent", Required("parent"), 1, int.MaxValue);
        int port = Number("grpc-port", Required("grpc-port"), 1, 65535);
        int mcpPort = values.GetValueOrDefault("mcp-port") is { Length: > 0 } mcp ? Number("mcp-port", mcp, 1, 65535) : 8787;
        string data = values.GetValueOrDefault("data-dir") is { Length: > 0 } dir
            ? Path.GetFullPath(dir)
            : DefaultDataDirectory();

        string? Folder(string name) => environment(name) is { Length: > 0 } value ? value.Trim() : null;
        return new ServiceOptions(role, Required("pipe"), parent, port, data, mcpPort, Folder("GARAGE_NATIVE_DIR"), Folder("GARAGE_SQL_DIR"));
    }

    /// <summary>
    /// <c>%LOCALAPPDATA%\Garage</c>: an unpackaged build's data folder (windows.md §2.6), as unentitled
    /// Mac builds use <c>~/Library/Application Support/GarageApp</c>.
    /// </summary>
    public static string DefaultDataDirectory() =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Garage");

    private static int Number(string name, string text, int min, int max) =>
        int.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out int value) && value >= min && value <= max
            ? value
            : throw new ArgumentException($"--{name} must be a number from {min} to {max}, not '{text}'");
}

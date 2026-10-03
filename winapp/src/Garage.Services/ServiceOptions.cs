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
/// Garage.Services --service core|ingest --pipe NAME --parent PID [--grpc-port N] [--data-dir DIR]
/// </code>
/// Environment:
/// <list type="bullet">
/// <item><c>GARAGE_PYTHON_HOME</c>: the CPython 3.14 home (<c>python314.dll</c>, <c>Lib</c>, <c>DLLs</c>);</item>
/// <item><c>GARAGE_PYTHON_SITE_PACKAGES</c>: the site-packages holding <c>garage_rag</c>'s dependencies;</item>
/// <item><c>GARAGE_PYTHON_PATH</c>: more <c>sys.path</c> entries, <c>;</c>-separated (a checkout's
/// <c>garage_python\src</c> during development);</item>
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
    string PythonHome,
    string? SitePackages,
    IReadOnlyList<string> ExtraPythonPaths)
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

        string pythonHome = environment("GARAGE_PYTHON_HOME") is { Length: > 0 } home
            ? home
            : throw new ArgumentException("GARAGE_PYTHON_HOME is not set: the service has no Python to run");
        string? site = environment("GARAGE_PYTHON_SITE_PACKAGES") is { Length: > 0 } s ? s : null;
        string[] extra = environment("GARAGE_PYTHON_PATH") is { Length: > 0 } paths
            ? paths.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            : [];

        return new ServiceOptions(role, Required("pipe"), parent, port, data, mcpPort, pythonHome, site, extra);
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

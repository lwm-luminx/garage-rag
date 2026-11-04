namespace Garage.App.Core.Services;

/// <summary>
/// Where the service executable and the Rust libraries it runs are, and where the data lives: what
/// the <see cref="ServiceManager"/> needs to start the services.
/// </summary>
/// <param name="ServicesExecutable">
/// <c>Garage.Services.exe</c>, or its <c>Garage.Services.dll</c>, which is started through
/// <c>dotnet</c> (a test's output folder carries the dll only).
/// </param>
/// <param name="NativeDirectory">
/// The folder holding <c>garage_service_ffi.dll</c>, <c>garage_ingest_ffi.dll</c> and
/// <c>garage_mcp_ffi.dll</c>, when they are not beside the executable (the shipped layout keeps them
/// in <c>native\</c>; a checkout builds them into <c>rust\target\release</c>).
/// </param>
/// <param name="SchemaDirectory">The SQL schema <c>InitDb</c> applies (<c>data\sql</c>; the shipped <c>schema\</c>).</param>
/// <param name="DataDirectory">The data folder: <c>garage.json</c>, <c>logs</c>.</param>
public sealed record ServiceHostLayout(
    string ServicesExecutable,
    string? NativeDirectory,
    string? SchemaDirectory,
    string DataDirectory)
{
    /// <summary>The services' file name.</summary>
    public const string ExecutableName = "Garage.Services.exe";

    /// <summary>The library a folder must hold to be the native folder.</summary>
    public const string NativeMarker = "garage_service_ffi.dll";

    /// <summary>
    /// <c>%LOCALAPPDATA%\Garage</c>: an unpackaged build's data folder (windows.md §2.6). The packaged
    /// build moves to the package's <c>LocalState</c>.
    /// </summary>
    public static string DefaultDataDirectory() =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Garage");

    /// <summary>
    /// The data folder this process uses: <c>GARAGE_DATA_DIR</c> when set (tests, scratch runs), else
    /// <see cref="DefaultDataDirectory"/>. The app's own preferences go here even with a development backend.
    /// </summary>
    public static string CurrentDataDirectory() =>
        Environment.GetEnvironmentVariable("GARAGE_DATA_DIR") is { Length: > 0 } custom ? custom : DefaultDataDirectory();

    /// <summary>
    /// Finds the layout, first match wins:
    /// <list type="number">
    /// <item><c>GARAGE_SERVICES_EXE</c>, <c>GARAGE_NATIVE_DIR</c>, <c>GARAGE_SQL_DIR</c> and <c>GARAGE_DATA_DIR</c>,
    /// each on its own;</item>
    /// <item>beside the app: <c>services\Garage.Services.exe</c>, <c>native\</c> and <c>schema\</c> (the shipped layout);</item>
    /// <item>in a checkout, for development: the services' build output, the Cargo build in
    /// <c>rust\target\release</c> (then <c>debug</c>) and <c>data\sql</c>.</item>
    /// </list>
    /// Without a native folder the runtime probes beside the executable, where a publish puts the libraries.
    /// </summary>
    /// <exception cref="FileNotFoundException">The executable could not be found.</exception>
    public static ServiceHostLayout Locate(string appDirectory, Func<string, string?>? environment = null)
    {
        environment ??= Environment.GetEnvironmentVariable;
        string? Env(string name) => environment(name) is { Length: > 0 } value ? value.Trim() : null;
        string? checkout = FindCheckout(appDirectory);

        string executable = Env("GARAGE_SERVICES_EXE")
            ?? Existing(Path.Combine(appDirectory, "services", ExecutableName))
            ?? (checkout is null ? null : NewestBuild(Path.Combine(checkout, "winapp", "src", "Garage.Services", "bin")))
            ?? throw new FileNotFoundException($"{ExecutableName} was not found beside the app or in a checkout; set GARAGE_SERVICES_EXE");

        string? native = Env("GARAGE_NATIVE_DIR")
            ?? NativeFolder(Path.Combine(appDirectory, "native"))
            ?? (checkout is null ? null : NativeFolder(Path.Combine(checkout, "rust", "target", "release")) ?? NativeFolder(Path.Combine(checkout, "rust", "target", "debug")));

        string? schema = Env("GARAGE_SQL_DIR")
            ?? ExistingDirectory(Path.Combine(appDirectory, "schema"))
            ?? (checkout is null ? null : ExistingDirectory(Path.Combine(checkout, "data", "sql")));

        return new ServiceHostLayout(executable, native, schema, Env("GARAGE_DATA_DIR") ?? DefaultDataDirectory());
    }

    /// <summary>The folder above <paramref name="start"/> that holds <c>winapp\Garage.slnx</c> and <c>rust\Cargo.toml</c>, or null.</summary>
    public static string? FindCheckout(string start)
    {
        for (DirectoryInfo? dir = new(start); dir is not null; dir = dir.Parent)
        {
            if (File.Exists(Path.Combine(dir.FullName, "winapp", "Garage.slnx"))
                && File.Exists(Path.Combine(dir.FullName, "rust", "Cargo.toml")))
            {
                return dir.FullName;
            }
        }
        return null;
    }

    private static string? Existing(string path) => File.Exists(path) ? path : null;

    private static string? ExistingDirectory(string path) => Directory.Exists(path) ? path : null;

    private static string? NativeFolder(string path) => File.Exists(Path.Combine(path, NativeMarker)) ? path : null;

    // The most recently built Garage.Services.exe under bin\ (Debug or Release).
    private static string? NewestBuild(string bin) =>
        Directory.Exists(bin)
            ? Directory.EnumerateFiles(bin, ExecutableName, SearchOption.AllDirectories)
                .OrderByDescending(File.GetLastWriteTimeUtc)
                .FirstOrDefault()
            : null;
}

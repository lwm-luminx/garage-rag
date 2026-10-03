using System.Diagnostics;

namespace Garage.App.Core.Services;

/// <summary>
/// Where the service executable and the Python it embeds are, and where the data lives: what the
/// <see cref="ServiceManager"/> needs to start the services.
/// </summary>
/// <param name="ServicesExecutable">
/// <c>Garage.Services.exe</c>, or its <c>Garage.Services.dll</c>, which is started through
/// <c>dotnet</c> (a test's output folder carries the dll only).
/// </param>
/// <param name="PythonHome">The CPython 3.14 home.</param>
/// <param name="SitePackages">The site-packages with <c>garage_rag</c>'s dependencies.</param>
/// <param name="PythonPath">More <c>sys.path</c> entries (a checkout's <c>garage_python\src</c>).</param>
/// <param name="DataDirectory">The data folder: <c>garage.json</c>, <c>logs</c>.</param>
public sealed record ServiceHostLayout(
    string ServicesExecutable,
    string PythonHome,
    string? SitePackages,
    IReadOnlyList<string> PythonPath,
    string DataDirectory)
{
    /// <summary>The services' file name.</summary>
    public const string ExecutableName = "Garage.Services.exe";

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
    /// <item><c>GARAGE_SERVICES_EXE</c>, <c>GARAGE_PYTHON_HOME</c>, <c>GARAGE_PYTHON_SITE_PACKAGES</c>,
    /// <c>GARAGE_PYTHON_PATH</c> and <c>GARAGE_DATA_DIR</c>, each on its own;</item>
    /// <item>beside the app: <c>services\Garage.Services.exe</c>, <c>python\</c> and <c>site-packages\</c>
    /// (the shipped layout);</item>
    /// <item>in a checkout, for development: the services' build output, the <c>py</c> launcher's 3.14,
    /// <c>garage_python\.venv</c> and <c>garage_python\src</c>.</item>
    /// </list>
    /// </summary>
    /// <exception cref="FileNotFoundException">A piece could not be found; the message says which.</exception>
    public static ServiceHostLayout Locate(string appDirectory, Func<string, string?>? environment = null)
    {
        environment ??= Environment.GetEnvironmentVariable;
        string? Env(string name) => environment(name) is { Length: > 0 } value ? value.Trim() : null;
        string? checkout = FindCheckout(appDirectory);

        string executable = Env("GARAGE_SERVICES_EXE")
            ?? Existing(Path.Combine(appDirectory, "services", ExecutableName))
            ?? (checkout is null ? null : NewestBuild(Path.Combine(checkout, "winapp", "src", "Garage.Services", "bin")))
            ?? throw new FileNotFoundException($"{ExecutableName} was not found beside the app or in a checkout; set GARAGE_SERVICES_EXE");

        string home = Env("GARAGE_PYTHON_HOME")
            ?? ExistingDirectory(Path.Combine(appDirectory, "python"))
            ?? PythonFromLauncher()
            ?? throw new FileNotFoundException("no CPython 3.14 was found beside the app or through the py launcher; set GARAGE_PYTHON_HOME");

        string? site = Env("GARAGE_PYTHON_SITE_PACKAGES")
            ?? ExistingDirectory(Path.Combine(appDirectory, "site-packages"))
            ?? (checkout is null ? null : ExistingDirectory(Path.Combine(checkout, "garage_python", ".venv", "Lib", "site-packages")));

        string[] path = Env("GARAGE_PYTHON_PATH") is { } extra
            ? extra.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            : checkout is null ? [] : [Path.Combine(checkout, "garage_python", "src")];

        return new ServiceHostLayout(executable, home, site, path, Env("GARAGE_DATA_DIR") ?? DefaultDataDirectory());
    }

    /// <summary>The folder above <paramref name="start"/> that holds <c>winapp\Garage.slnx</c>, or null.</summary>
    public static string? FindCheckout(string start)
    {
        for (DirectoryInfo? dir = new(start); dir is not null; dir = dir.Parent)
        {
            if (File.Exists(Path.Combine(dir.FullName, "winapp", "Garage.slnx"))
                && Directory.Exists(Path.Combine(dir.FullName, "garage_python", "src", "garage_rag")))
            {
                return dir.FullName;
            }
        }
        return null;
    }

    private static string? Existing(string path) => File.Exists(path) ? path : null;

    private static string? ExistingDirectory(string path) => Directory.Exists(path) ? path : null;

    // The most recently built Garage.Services.exe under bin\ (Debug or Release).
    private static string? NewestBuild(string bin) =>
        Directory.Exists(bin)
            ? Directory.EnumerateFiles(bin, ExecutableName, SearchOption.AllDirectories)
                .OrderByDescending(File.GetLastWriteTimeUtc)
                .FirstOrDefault()
            : null;

    private static string? PythonFromLauncher()
    {
        try
        {
            using Process? process = Process.Start(new ProcessStartInfo("py", ["-3.14", "-c", "import sys; print(sys.base_prefix)"])
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            });
            if (process is null)
            {
                return null;
            }
            string output = process.StandardOutput.ReadToEnd().Trim();
            return process.WaitForExit(10_000) && process.ExitCode == 0 && Directory.Exists(output) ? output : null;
        }
        catch (System.ComponentModel.Win32Exception)
        {
            return null;
        }
    }
}

using System.Text.RegularExpressions;

namespace Garage.Python;

/// <summary>
/// The on-disk layout of the interpreter a Garage process embeds: the Windows counterpart of
/// <c>GaragePythonEnvironment</c> in the Mac app's <c>PythonXPCService</c>.
/// </summary>
/// <remarks>
/// A CPython home on Windows looks like:
/// <code>
/// home\                      &lt;- PyConfig.home; python3XY.dll lives here
/// home\Lib\                  &lt;- standard library (os.py)
/// home\DLLs\                 &lt;- compiled stdlib extension modules (.pyd), the Windows lib-dynload
/// home\Lib\site-packages\    &lt;- third-party packages, unless the bundle keeps its own
/// </code>
/// <see cref="SearchPaths"/> becomes <c>sys.path</c> verbatim; nothing is searched for.
/// </remarks>
public sealed partial class PythonEnvironment
{
    /// <summary>Creates an environment from explicit locations.</summary>
    /// <param name="home">The interpreter's home folder (<c>PyConfig.home</c>).</param>
    /// <param name="libraryPath">The interpreter DLL, e.g. <c>home\python314.dll</c>.</param>
    /// <param name="sitePackagesDir">Third-party packages; defaults to <c>home\Lib\site-packages</c>.</param>
    /// <param name="extraSearchPaths">Entries appended to <c>sys.path</c> after site-packages.</param>
    public PythonEnvironment(
        string home,
        string libraryPath,
        string? sitePackagesDir = null,
        IReadOnlyList<string>? extraSearchPaths = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(home);
        ArgumentException.ThrowIfNullOrWhiteSpace(libraryPath);
        Home = Path.GetFullPath(home);
        LibraryPath = Path.GetFullPath(libraryPath);
        StdlibDir = Path.Combine(Home, "Lib");
        DllsDir = Path.Combine(Home, "DLLs");
        SitePackagesDir = Path.GetFullPath(sitePackagesDir ?? Path.Combine(StdlibDir, "site-packages"));
        ExtraSearchPaths = [.. (extraSearchPaths ?? []).Select(Path.GetFullPath)];
    }

    /// <summary>The interpreter's home folder (<c>PyConfig.home</c>).</summary>
    public string Home { get; }

    /// <summary>The interpreter DLL this process loads.</summary>
    public string LibraryPath { get; }

    /// <summary>The standard library, <c>home\Lib</c>.</summary>
    public string StdlibDir { get; }

    /// <summary>Compiled standard-library modules, <c>home\DLLs</c>.</summary>
    public string DllsDir { get; }

    /// <summary>Third-party packages and <c>garage_rag</c>.</summary>
    public string SitePackagesDir { get; }

    /// <summary>Entries appended to <c>sys.path</c> after <see cref="SitePackagesDir"/>.</summary>
    public IReadOnlyList<string> ExtraSearchPaths { get; }

    /// <summary>The <c>sys.path</c> the interpreter starts with, in order.</summary>
    public IReadOnlyList<string> SearchPaths => [StdlibDir, DllsDir, SitePackagesDir, .. ExtraSearchPaths];

    /// <summary>
    /// An environment for the interpreter installed at <paramref name="home"/>, finding its DLL there
    /// (<c>python3XY.dll</c>, or <c>python3XYt.dll</c> when <paramref name="freeThreaded"/>).
    /// </summary>
    /// <exception cref="FileNotFoundException">No matching interpreter DLL is in <paramref name="home"/>.</exception>
    public static PythonEnvironment FromHome(
        string home,
        string? sitePackagesDir = null,
        IReadOnlyList<string>? extraSearchPaths = null,
        bool freeThreaded = false)
    {
        string full = Path.GetFullPath(home);
        string? library = Directory.Exists(full)
            ? Directory.EnumerateFiles(full, "python3*.dll")
                .Where(path => InterpreterDll().Match(Path.GetFileName(path)) is { Success: true } match
                    && match.Groups["t"].Success == freeThreaded)
                .OrderByDescending(path => path, StringComparer.OrdinalIgnoreCase)
                .FirstOrDefault()
            : null;
        return library is null
            ? throw new FileNotFoundException(
                $"no {(freeThreaded ? "free-threaded " : "")}Python DLL (python3XY{(freeThreaded ? "t" : "")}.dll) in {full}")
            : new PythonEnvironment(full, library, sitePackagesDir, extraSearchPaths);
    }

    /// <summary>
    /// Problems with this layout (missing landmarks), in human-readable form. Empty means valid.
    /// </summary>
    public IReadOnlyList<string> ValidationProblems()
    {
        List<string> problems = [];
        if (!Directory.Exists(Home))
        {
            problems.Add($"Python home directory is missing: {Home}");
            return problems;
        }
        if (!File.Exists(LibraryPath))
        {
            problems.Add($"Python library is missing: {LibraryPath}");
        }
        if (!File.Exists(Path.Combine(StdlibDir, "os.py")))
        {
            problems.Add($"Standard library landmark 'os.py' not found in {StdlibDir}");
        }
        if (!Directory.Exists(DllsDir))
        {
            problems.Add($"DLLs directory is missing: {DllsDir}");
        }
        if (!Directory.Exists(SitePackagesDir))
        {
            problems.Add($"site-packages directory is missing: {SitePackagesDir}");
        }
        problems.AddRange(ExtraSearchPaths.Where(p => !Directory.Exists(p)).Select(p => $"search path is missing: {p}"));
        return problems;
    }

    // python314.dll or python314t.dll; not python3.dll (the stable-ABI forwarder).
    [GeneratedRegex(@"^python3\d{1,2}(?<t>t)?\.dll$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex InterpreterDll();
}

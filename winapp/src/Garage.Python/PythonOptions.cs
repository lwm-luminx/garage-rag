namespace Garage.Python;

/// <summary>
/// How the embedded interpreter starts; the defaults match <c>GaragePythonEmbedOptionsDefault</c>
/// in the Mac app. The interpreter is always isolated: <c>PYTHON*</c> environment variables, the
/// working directory, user site-packages and the command line are ignored, so it sees only the
/// environment the host ships.
/// </summary>
public sealed record PythonOptions
{
    /// <summary><c>sys.executable</c>'s stand-in name (<c>PyConfig.program_name</c>).</summary>
    public string ProgramName { get; init; } = "python";

    /// <summary>
    /// Import <c>site</c> after start-up and process the <c>.pth</c> files in
    /// <see cref="PythonEnvironment.SitePackagesDir"/> (<c>site.addsitedir</c>). The interpreter's own
    /// site directories (the home folder, <c>home\Lib\site-packages</c>) are never added, so
    /// <c>sys.path</c> stays <see cref="PythonEnvironment.SearchPaths"/>.
    /// </summary>
    public bool ImportSite { get; init; } = true;

    /// <summary>
    /// Write <c>.pyc</c> files. Off by default: a packaged app's install folder is read-only.
    /// </summary>
    public bool WriteBytecode { get; init; }

    /// <summary>
    /// Let Python install its own signal (console control) handlers. Off by default: the host
    /// owns shutdown.
    /// </summary>
    public bool InstallSignalHandlers { get; init; }

    /// <summary>Verbose import tracing and path-configuration warnings, for diagnosing a bundle.</summary>
    public bool Verbose { get; init; }

    /// <summary>
    /// Release the GIL once start-up finishes so any thread can take it with <see cref="Python.Gil"/>
    /// and threads Python starts can run. On by default.
    /// </summary>
    public bool ReleaseGilAfterInit { get; init; } = true;
}

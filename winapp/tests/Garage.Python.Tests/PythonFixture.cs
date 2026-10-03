using System.Diagnostics;

[assembly: AssemblyFixture(typeof(Garage.Python.Tests.PythonFixture))]

namespace Garage.Python.Tests;

/// <summary>
/// Starts one interpreter for the whole test run (a process starts CPython once).
/// </summary>
/// <remarks>
/// <list type="bullet">
/// <item><c>GARAGE_TEST_PYTHON_HOME</c> names a CPython 3.14 home (the folder with
/// <c>python314.dll</c>, <c>Lib</c> and <c>DLLs</c>); without it the fixture asks the
/// <c>py</c> launcher for 3.14. With neither, every test skips.</item>
/// <item><c>GARAGE_TEST_PYTHON_SITE_PACKAGES</c> names a site-packages with <c>garage_rag</c>'s
/// dependencies (a venv's <c>Lib\site-packages</c>); <c>garage_python/src</c> from this checkout
/// goes on <c>sys.path</c> after it. Without it the <c>garage_rag</c> tests skip.</item>
/// <item><c>GARAGE_TEST_REQUIRE_PYTHON=1</c> (CI) turns both skips into failures, so a
/// misconfigured job cannot pass by skipping everything.</item>
/// </list>
/// </remarks>
public sealed class PythonFixture
{
    public PythonFixture()
    {
        string? home = Environment.GetEnvironmentVariable("GARAGE_TEST_PYTHON_HOME") is { Length: > 0 } fromEnv
            ? fromEnv
            : HomeFromLauncher();
        if (home is null)
        {
            SkipReason = "no CPython 3.14: set GARAGE_TEST_PYTHON_HOME or install it for the py launcher";
            return;
        }

        string? sitePackages = Environment.GetEnvironmentVariable("GARAGE_TEST_PYTHON_SITE_PACKAGES") is { Length: > 0 } site
            ? site
            : null;
        GarageSource = Path.Combine(RepoRoot(), "garage_python", "src");
        HasGarageDependencies = sitePackages is not null;

        Environment_ = PythonEnvironment.FromHome(home, sitePackages, [GarageSource]);
        Python.Initialize(Environment_);
    }

    /// <summary>Why the Python tests skip, or null when the interpreter is running.</summary>
    public string? SkipReason { get; }

    /// <summary>Whether <c>garage_rag</c>'s dependencies are importable.</summary>
    public bool HasGarageDependencies { get; }

    /// <summary>This checkout's <c>garage_python/src</c>.</summary>
    public string GarageSource { get; } = "";

    public PythonEnvironment? Environment_ { get; }

    public void RequirePython() => SkipOrFail(SkipReason is not null, SkipReason ?? "");

    public void RequireGarage()
    {
        RequirePython();
        SkipOrFail(!HasGarageDependencies, "set GARAGE_TEST_PYTHON_SITE_PACKAGES to a site-packages with garage_rag's dependencies");
    }

    private static bool Required => Environment.GetEnvironmentVariable("GARAGE_TEST_REQUIRE_PYTHON") == "1";

    private static void SkipOrFail(bool missing, string reason)
    {
        if (missing && Required)
        {
            Assert.Fail($"GARAGE_TEST_REQUIRE_PYTHON is set, but {reason}");
        }
        Assert.SkipWhen(missing, reason);
    }

    private static string? HomeFromLauncher()
    {
        try
        {
            using Process process = Process.Start(new ProcessStartInfo("py", ["-3.14", "-c", "import sys; print(sys.base_prefix)"])
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            })!;
            string output = process.StandardOutput.ReadToEnd().Trim();
            process.WaitForExit(10_000);
            return process.ExitCode == 0 && Directory.Exists(output) ? output : null;
        }
        catch (System.ComponentModel.Win32Exception)
        {
            return null;  // no py launcher
        }
    }

    private static string RepoRoot()
    {
        for (DirectoryInfo? dir = new(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
        {
            if (Directory.Exists(Path.Combine(dir.FullName, "garage_python", "src", "garage_rag")))
            {
                return dir.FullName;
            }
        }
        throw new InvalidOperationException($"no garage_python/src above {AppContext.BaseDirectory}");
    }
}

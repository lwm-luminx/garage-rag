using System.Diagnostics;
using Garage.App.Core.Services;
using Garage.App.Core.Threading;

namespace Garage.Services.Tests;

/// <summary>
/// What the service tests need: an interpreter and a site-packages (the same variables as
/// Garage.Python.Tests), a scratch data folder, and optionally a Postgres server.
/// </summary>
/// <remarks>
/// <list type="bullet">
/// <item><c>GARAGE_TEST_PYTHON_HOME</c> or the <c>py</c> launcher's 3.14, and <c>GARAGE_TEST_PYTHON_SITE_PACKAGES</c>:
/// without both the tests that start services skip (fail under <c>GARAGE_TEST_REQUIRE_PYTHON=1</c>).</item>
/// <item><c>GARAGE_TEST_DATABASE_URL</c>, a superuser URL as <c>test_postgres.py</c> takes: the end-to-end
/// ingest test creates a throwaway <c>garage_test_*</c> database there and drops it. Unset, it skips.</item>
/// </list>
/// Every service runs with a scratch data folder whose <c>garage.json</c> names the database, so no
/// test reads or writes the account's own <c>~/.garage.json</c>.
/// </remarks>
public static class ServiceFixture
{
    private static readonly Lazy<string?> Home = new(() =>
        Environment.GetEnvironmentVariable("GARAGE_TEST_PYTHON_HOME") is { Length: > 0 } home ? home : FromLauncher());

    /// <summary>This checkout.</summary>
    public static string RepoRoot { get; } = ServiceHostLayout.FindCheckout(AppContext.BaseDirectory)
        ?? throw new InvalidOperationException($"no checkout above {AppContext.BaseDirectory}");

    /// <summary>A layout over a new scratch data folder, or a skip.</summary>
    public static ServiceHostLayout Layout(string dataDirectory)
    {
        string? site = Environment.GetEnvironmentVariable("GARAGE_TEST_PYTHON_SITE_PACKAGES") is { Length: > 0 } s ? s : null;
        SkipOrFail(Home.Value is null, "no CPython 3.14: set GARAGE_TEST_PYTHON_HOME or install it for the py launcher");
        SkipOrFail(site is null, "set GARAGE_TEST_PYTHON_SITE_PACKAGES to a site-packages with garage_rag's dependencies");
        string exe = Path.Combine(AppContext.BaseDirectory, ServiceHostLayout.ExecutableName);
        return new ServiceHostLayout(
            File.Exists(exe) ? exe : Path.Combine(AppContext.BaseDirectory, "Garage.Services.dll"),
            Home.Value!,
            site,
            [Path.Combine(RepoRoot, "garage_python", "src")],
            dataDirectory);
    }

    /// <summary>A scratch data folder whose garage.json names <paramref name="databaseUrl"/>.</summary>
    public static string DataDirectory(string databaseUrl = "postgresql+psycopg://garage@no-database.invalid:5432/garage_none")
    {
        string dir = Path.Combine(Path.GetTempPath(), "garage-services-test-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(dir);
        File.WriteAllText(Path.Combine(dir, "garage.json"),
            System.Text.Json.JsonSerializer.Serialize(new { database = new { url = databaseUrl } }));
        return dir;
    }

    /// <summary>The superuser URL tests may create databases on, or a skip.</summary>
    public static string DatabaseServer()
    {
        string? url = Environment.GetEnvironmentVariable("GARAGE_TEST_DATABASE_URL");
        Assert.SkipWhen(string.IsNullOrEmpty(url), "GARAGE_TEST_DATABASE_URL is not set");
        return url!;
    }

    /// <summary>Runs <paramref name="code"/> in the test interpreter with the site-packages on its path.</summary>
    public static string RunPython(string code)
    {
        var info = new ProcessStartInfo(Path.Combine(Home.Value!, "python.exe"), ["-c", code])
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        info.Environment["PYTHONPATH"] = Environment.GetEnvironmentVariable("GARAGE_TEST_PYTHON_SITE_PACKAGES");
        using Process process = Process.Start(info)!;
        string output = process.StandardOutput.ReadToEnd();
        string error = process.StandardError.ReadToEnd();
        process.WaitForExit();
        Assert.True(process.ExitCode == 0, $"python failed: {error}");
        return output.Trim();
    }

    /// <summary>Removes a scratch folder, tolerating a service that still holds a log file.</summary>
    public static void Delete(string dir)
    {
        for (int attempt = 0; attempt < 10 && Directory.Exists(dir); attempt++)
        {
            try
            {
                Directory.Delete(dir, recursive: true);
            }
            catch (IOException)
            {
                Thread.Sleep(200);
            }
            catch (UnauthorizedAccessException)
            {
                Thread.Sleep(200);
            }
        }
    }

    private static void SkipOrFail(bool missing, string reason)
    {
        if (missing && Environment.GetEnvironmentVariable("GARAGE_TEST_REQUIRE_PYTHON") == "1")
        {
            Assert.Fail($"GARAGE_TEST_REQUIRE_PYTHON is set, but {reason}");
        }
        Assert.SkipWhen(missing, reason);
    }

    private static string? FromLauncher()
    {
        try
        {
            using Process process = Process.Start(new ProcessStartInfo("py", ["-3.14", "-c", "import sys; print(sys.base_prefix)"])
            {
                RedirectStandardOutput = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            })!;
            string output = process.StandardOutput.ReadToEnd().Trim();
            process.WaitForExit(10_000);
            return process.ExitCode == 0 && Directory.Exists(output) ? output : null;
        }
        catch (System.ComponentModel.Win32Exception)
        {
            return null;
        }
    }
}

/// <summary>Runs every "UI" update under one lock: the tests' stand-in for the UI thread.</summary>
public sealed class SerialDispatcher : IUiDispatcher
{
    private readonly Lock _lock = new();

    public bool HasThreadAccess => false;

    public void Post(Action action)
    {
        ArgumentNullException.ThrowIfNull(action);
        lock (_lock)
        {
            action();
        }
    }
}

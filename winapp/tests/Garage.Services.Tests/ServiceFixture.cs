using System.Diagnostics;
using Garage.App.Core.Services;
using Garage.App.Core.Threading;

namespace Garage.Services.Tests;

/// <summary>
/// What the service tests need: the Rust libraries the services run, a scratch data folder, and
/// optionally a Postgres server.
/// </summary>
/// <remarks>
/// <list type="bullet">
/// <item><c>GARAGE_TEST_NATIVE_DIR</c>, or a checkout's <c>rust\target\release</c> (then <c>debug</c>) holding
/// <c>garage_service_ffi.dll</c>, <c>garage_ingest_ffi.dll</c> and <c>garage_mcp_ffi.dll</c>
/// (<c>cargo build --release -p garage-service-ffi -p garage-ingest-ffi -p garage-mcp-ffi</c>): without
/// them the tests that start services skip (fail under <c>GARAGE_TEST_REQUIRE_NATIVE=1</c>).</item>
/// <item><c>GARAGE_TEST_DATABASE_URL</c>, a superuser URL as <c>test_postgres.py</c> takes: the end-to-end
/// ingest test creates a throwaway <c>garage_test_*</c> database there (with <c>psql</c>, from
/// <c>GARAGE_TEST_POSTGRES_HOME</c> or the PATH) and drops it. Unset, it skips.</item>
/// </list>
/// Every service runs with a scratch data folder whose <c>garage.json</c> names the database, so no
/// test reads or writes the account's own <c>~/.garage.json</c>.
/// </remarks>
public static class ServiceFixture
{
    /// <summary>This checkout.</summary>
    public static string RepoRoot { get; } = ServiceHostLayout.FindCheckout(AppContext.BaseDirectory)
        ?? throw new InvalidOperationException($"no checkout above {AppContext.BaseDirectory}");

    private static readonly Lazy<string?> Native = new(() =>
    {
        string? named = Environment.GetEnvironmentVariable("GARAGE_TEST_NATIVE_DIR");
        if (!string.IsNullOrEmpty(named))
        {
            return named;
        }
        foreach (string profile in (string[])["release", "debug"])
        {
            string dir = Path.Combine(RepoRoot, "rust", "target", profile);
            if (File.Exists(Path.Combine(dir, ServiceHostLayout.NativeMarker)))
            {
                return dir;
            }
        }
        return null;
    });

    /// <summary>A layout over a new scratch data folder, or a skip.</summary>
    public static ServiceHostLayout Layout(string dataDirectory)
    {
        SkipOrFail(Native.Value is null, "no Rust libraries: set GARAGE_TEST_NATIVE_DIR or build them into rust\\target (cargo build --release -p garage-service-ffi -p garage-ingest-ffi -p garage-mcp-ffi)");
        string exe = Path.Combine(AppContext.BaseDirectory, ServiceHostLayout.ExecutableName);
        return new ServiceHostLayout(
            File.Exists(exe) ? exe : Path.Combine(AppContext.BaseDirectory, "Garage.Services.dll"),
            Native.Value!,
            Path.Combine(RepoRoot, "data", "sql"),
            dataDirectory);
    }

    /// <summary>A scratch data folder whose garage.json names <paramref name="databaseUrl"/>.</summary>
    public static string DataDirectory(string databaseUrl = "postgresql://garage@no-database.invalid:5432/garage_none")
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

    /// <summary>Runs <paramref name="sql"/> on <paramref name="serverUrl"/> with psql, or skips when there is none.</summary>
    public static void Psql(string serverUrl, string sql)
    {
        string? home = Environment.GetEnvironmentVariable("GARAGE_TEST_POSTGRES_HOME");
        string psql = string.IsNullOrEmpty(home) ? "psql" : Path.Combine(home, "bin", "psql.exe");
        ProcessStartInfo info = new(psql, [serverUrl.Replace("postgresql+psycopg://", "postgresql://", StringComparison.Ordinal), "-v", "ON_ERROR_STOP=1", "-c", sql])
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        Process process;
        try
        {
            process = Process.Start(info) ?? throw new InvalidOperationException("psql did not start");
        }
        catch (System.ComponentModel.Win32Exception)
        {
            Assert.Skip("psql is not on the PATH and GARAGE_TEST_POSTGRES_HOME is not set");
            return;
        }
        using (process)
        {
            string output = process.StandardOutput.ReadToEnd();
            string error = process.StandardError.ReadToEnd();
            process.WaitForExit();
            Assert.True(process.ExitCode == 0, $"psql failed: {error}{output}");
        }
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
        if (missing && Environment.GetEnvironmentVariable("GARAGE_TEST_REQUIRE_NATIVE") == "1")
        {
            Assert.Fail($"GARAGE_TEST_REQUIRE_NATIVE is set, but {reason}");
        }
        Assert.SkipWhen(missing, reason);
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

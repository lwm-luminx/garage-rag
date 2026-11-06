using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using Garage.App.Core.Database;
using Garage.App.Core.State;

namespace Garage.Services.Tests;

/// <summary>
/// Garage's own Postgres, run by <see cref="PostgresSupervisor"/> from a Windows build of
/// <c>//ext/postgres</c>: <c>GARAGE_TEST_POSTGRES_HOME</c> names one (the <c>postgres-windows-x64</c>
/// artifact of windows.yaml). Unset, these tests skip. Each uses its own folder and port.
/// </summary>
public sealed class PostgresTests
{
    private static string Home()
    {
        string? home = Environment.GetEnvironmentVariable("GARAGE_TEST_POSTGRES_HOME");
        Assert.SkipWhen(string.IsNullOrEmpty(home), "GARAGE_TEST_POSTGRES_HOME is not set");
        return home!;
    }

    private static int FreePort()
    {
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        return ((IPEndPoint)listener.LocalEndpoint).Port;
    }

    private static string Query(PostgresLayout layout, string password, string sql)
    {
        var info = new ProcessStartInfo(layout.Tool("psql"), ["-h", "127.0.0.1", "-p", layout.Port.ToString(System.Globalization.CultureInfo.InvariantCulture),
            "-U", PostgresLayout.User, "-d", PostgresLayout.DatabaseName, "-tAc", sql])
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        info.Environment["PGPASSWORD"] = password;
        using Process process = Process.Start(info)!;
        string output = process.StandardOutput.ReadToEnd() + process.StandardError.ReadToEnd();
        process.WaitForExit();
        return output.Trim();
    }

    [Fact]
    public async Task A_first_start_creates_the_cluster_and_later_starts_reuse_it()
    {
        string data = ServiceFixture.DataDirectory();
        var secrets = new MemorySecretStore();
        var layout = new PostgresLayout(Home(), data, FreePort());
        var postgres = new PostgresSupervisor(layout, secrets);
        CancellationToken token = TestContext.Current.CancellationToken;
        try
        {
            Assert.True(await postgres.StartAsync(token), postgres.Status.FailureMessage);
            Assert.Equal(PostgresState.Running, postgres.Status.State);
            Assert.True(postgres.CreatedCluster);
            Assert.StartsWith("PostgreSQL 18", postgres.Version, StringComparison.Ordinal);

            string password = secrets.Read(PostgresSupervisor.PasswordSecret)!;
            Assert.Equal(48, password.Length);
            Assert.Contains($"garage:{password}@127.0.0.1:{layout.Port}/garage-rag", postgres.DatabaseUrl(), StringComparison.Ordinal);
            Assert.Equal("scram-sha-256", Query(layout, password, "SHOW password_encryption"));
            Assert.Equal("127.0.0.1", Query(layout, password, "SHOW listen_addresses"));
            Assert.Contains("password authentication failed", Query(layout, "wrong", "SELECT 1"), StringComparison.Ordinal);
            Assert.Equal("vector", Query(layout, password, "CREATE EXTENSION IF NOT EXISTS vector; SELECT extname FROM pg_extension WHERE extname = 'vector'").Split('\n')[^1]);

            // A second supervisor finds the server the first left running (an app that crashed) and
            // takes over rather than talking to the old one.
            var again = new PostgresSupervisor(layout, secrets);
            Assert.True(await again.StartAsync(token), again.Status.FailureMessage);
            Assert.False(again.CreatedCluster);
            Assert.Contains(again.Log, l => l.Text.Contains("still up", StringComparison.Ordinal));
            Assert.Equal("1", Query(layout, password, "SELECT 1"));

            await again.StopAsync(token);
            Assert.Equal(PostgresState.Stopped, again.Status.State);
            Assert.StartsWith("psql: error", Query(layout, password, "SELECT 1"), StringComparison.Ordinal);

            await again.DeleteClusterAsync(token);
            Assert.False(layout.HasCluster);
        }
        finally
        {
            await postgres.StopAsync(CancellationToken.None);
            ServiceFixture.Delete(data);
        }
    }

    [Fact]
    public async Task A_backup_brings_the_database_back_after_a_change()
    {
        string data = ServiceFixture.DataDirectory();
        var secrets = new MemorySecretStore();
        var layout = new PostgresLayout(Home(), data, FreePort());
        var postgres = new PostgresSupervisor(layout, secrets);
        CancellationToken token = TestContext.Current.CancellationToken;
        try
        {
            Assert.True(await postgres.StartAsync(token), postgres.Status.FailureMessage);
            string password = secrets.Read(PostgresSupervisor.PasswordSecret)!;
            Query(layout, password, "CREATE TABLE notes (body text); INSERT INTO notes VALUES ('before')");
            string backup = Path.Combine(data, "backups", "garage.garagedump");

            await postgres.BackupAsync(backup, token);
            Assert.True(new FileInfo(backup).Length > 0);
            Query(layout, password, "UPDATE notes SET body = 'after'; CREATE TABLE extra (x int)");

            await postgres.RestoreAsync(backup, token);
            Assert.Equal("before", Query(layout, password, "SELECT body FROM notes"));
            Assert.Contains("does not exist", Query(layout, password, "SELECT * FROM extra"), StringComparison.Ordinal);

            PostgresDetails details = await postgres.DetailsAsync(token);
            Assert.True(details.SizeBytes > 1_000_000);
            await Assert.ThrowsAsync<PostgresException>(() => postgres.RestoreAsync(Path.Combine(data, "missing.dump"), token));
        }
        finally
        {
            await postgres.StopAsync(CancellationToken.None);
            ServiceFixture.Delete(data);
        }
    }

    [Fact]
    public async Task A_cluster_without_its_password_says_so()
    {
        string data = ServiceFixture.DataDirectory();
        var layout = new PostgresLayout(Home(), data, FreePort());
        try
        {
            var secrets = new MemorySecretStore();
            var postgres = new PostgresSupervisor(layout, secrets);
            Assert.True(await postgres.StartAsync(TestContext.Current.CancellationToken), postgres.Status.FailureMessage);
            await postgres.StopAsync(TestContext.Current.CancellationToken);

            var lost = new PostgresSupervisor(layout, new MemorySecretStore());
            Assert.False(await lost.StartAsync(TestContext.Current.CancellationToken));
            Assert.Equal(PostgresState.Failed, lost.Status.State);
            Assert.Contains("password is missing", lost.Status.FailureMessage, StringComparison.Ordinal);
        }
        finally
        {
            ServiceFixture.Delete(data);
        }
    }

    [Fact]
    public void The_layout_is_found_from_the_environment_or_beside_the_app()
    {
        string data = Path.GetTempPath();
        Assert.Null(PostgresLayout.Locate(Path.GetTempPath(), data, _ => null));
        string home = Home();
        PostgresLayout? layout = PostgresLayout.Locate(Path.GetTempPath(), data, name => name == "GARAGE_POSTGRES_HOME" ? home : null);
        Assert.NotNull(layout);
        Assert.Equal(Path.Combine(Path.GetFullPath(home), "bin", "libpq.dll"), layout.Libpq);
        Assert.Equal(Path.Combine(data, "pgdata"), layout.ClusterDirectory);
    }

    [Fact]
    public void Credential_manager_keeps_a_secret_for_this_account()
    {
        string prefix = $"Garage-test-{Guid.NewGuid():N}/";
        var store = new WindowsCredentialStore(prefix);
        try
        {
            Assert.Null(store.Read("secret"));
            store.Write("secret", "s3cr3t pässword");
            Assert.Equal("s3cr3t pässword", store.Read("secret"));
            store.Write("secret", "replaced");
            Assert.Equal("replaced", new WindowsCredentialStore(prefix).Read("secret"));
        }
        finally
        {
            store.Delete("secret");
        }
        Assert.Null(store.Read("secret"));
        store.Delete("secret");
    }
}

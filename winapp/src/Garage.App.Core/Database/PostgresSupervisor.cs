using System.Diagnostics;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using CommunityToolkit.Mvvm.ComponentModel;
using Garage.App.Core.Logging;
using Garage.App.Core.Operations;
using Garage.App.Core.State;
using Garage.App.Core.Threading;

namespace Garage.App.Core.Database;

/// <summary>
/// Where Garage's own Postgres is: the build from <c>//ext/postgres</c> (with pgvector) and the
/// cluster's folder. The counterpart of the Mac's bundled Postgres paths.
/// </summary>
/// <param name="Home">The Postgres install: <c>bin\postgres.exe</c>, <c>share</c>, <c>lib</c>.</param>
/// <param name="DataDirectory">The app's data folder; the cluster is its <c>pgdata</c>.</param>
/// <param name="Port">
/// Loopback only, and not 5432, so it never meets another Postgres. The Mac's socket comes with the
/// AF_UNIX spike (windows.md §2.5, S2); until then the password and <c>127.0.0.1</c> guard it.
/// </param>
public sealed record PostgresLayout(string Home, string DataDirectory, int Port = PostgresLayout.DefaultPort)
{
    /// <summary>The Mac's port (<c>GaragePostgresEndpoint.port</c>).</summary>
    public const int DefaultPort = 14824;

    /// <summary>The Mac's database name.</summary>
    public const string DatabaseName = "garage-rag";

    /// <summary>The cluster's superuser; the Mac uses the account name, which here may hold spaces.</summary>
    public const string User = "garage";

    /// <summary>The binaries.</summary>
    public string BinDirectory => Path.Combine(Home, "bin");

    /// <summary>The cluster.</summary>
    public string ClusterDirectory => Path.Combine(DataDirectory, "pgdata");

    /// <summary>The server's log.</summary>
    public string LogFile => Path.Combine(DataDirectory, "logs", "postgres.log");

    /// <summary>The client library psycopg should load (<c>GARAGE_LIBPQ</c>).</summary>
    public string Libpq => Path.Combine(BinDirectory, "libpq.dll");

    /// <summary>Whether <see cref="ClusterDirectory"/> holds a cluster.</summary>
    public bool HasCluster => File.Exists(Path.Combine(ClusterDirectory, "PG_VERSION"));

    /// <summary>A tool's path.</summary>
    public string Tool(string name) => Path.Combine(BinDirectory, name + ".exe");

    /// <summary>
    /// Garage's Postgres, first match wins: <c>GARAGE_POSTGRES_HOME</c>, then <c>postgres\</c> beside the
    /// app (the shipped layout). Null when there is none: the app then uses the database
    /// <c>garage.json</c> names, as a CLI install does.
    /// </summary>
    public static PostgresLayout? Locate(string appDirectory, string dataDirectory, Func<string, string?>? environment = null)
    {
        environment ??= Environment.GetEnvironmentVariable;
        string? home = environment("GARAGE_POSTGRES_HOME") is { Length: > 0 } fromEnv ? fromEnv.Trim() : Path.Combine(appDirectory, "postgres");
        return File.Exists(Path.Combine(home, "bin", "postgres.exe")) ? new PostgresLayout(Path.GetFullPath(home), dataDirectory) : null;
    }
}

/// <summary>
/// Runs Garage's own Postgres cluster: the counterpart of the Mac's <c>PostgresService</c>.
/// <list type="bullet">
/// <item>The first start runs <c>initdb</c>: UTF-8 with ICU collation, SCRAM authentication and a
/// generated password kept in the <see cref="ISecretStore"/>.</item>
/// <item>A server left running by a previous app (a crash, a force-quit) is stopped and started
/// again, so the app never talks to a stale postmaster.</item>
/// <item>Stop is a fast shutdown (<c>pg_ctl stop -m fast</c>), never a smart one, which would wait on
/// the services' pooled connections.</item>
/// </list>
/// The server runs detached (<c>pg_ctl start</c>), outside the services' Job Object, so a crash of
/// the app does not cut it off mid-write; the next start stops it cleanly.
/// </summary>
public sealed partial class PostgresSupervisor : ObservableObject
{
    /// <summary>The secret's name in the store.</summary>
    public const string PasswordSecret = "postgres-password";

    private static readonly TimeSpan ToolTimeout = TimeSpan.FromMinutes(3);

    private readonly ISecretStore _secrets;
    private readonly IUiDispatcher _dispatcher;

    /// <summary>Creates the supervisor; nothing runs until <see cref="StartAsync"/>.</summary>
    public PostgresSupervisor(PostgresLayout layout, ISecretStore secrets, IUiDispatcher? dispatcher = null)
    {
        Layout = layout ?? throw new ArgumentNullException(nameof(layout));
        _secrets = secrets ?? throw new ArgumentNullException(nameof(secrets));
        _dispatcher = dispatcher ?? InlineDispatcher.Instance;
        Log = new LogBuffer("postgres");
        Status = new PostgresStatus(PostgresState.Stopped);
    }

    /// <summary>Where everything is.</summary>
    public PostgresLayout Layout { get; }

    /// <summary>What the supervisor did (initdb, start, stop), for the Logs page.</summary>
    public LogBuffer Log { get; }

    /// <summary>The server's state.</summary>
    [ObservableProperty]
    public partial PostgresStatus Status { get; private set; }

    /// <summary>"PostgreSQL 18.6", once started.</summary>
    [ObservableProperty]
    public partial string? Version { get; private set; }

    /// <summary>Whether the last start created the cluster (a first launch, or after a reset).</summary>
    public bool CreatedCluster { get; private set; }

    /// <summary>
    /// The SQLAlchemy URL the services connect with (<c>GARAGE_DATABASE_URL</c>). It carries the
    /// password: pass it through a process's environment only, never a command line or a log.
    /// </summary>
    public string DatabaseUrl() =>
        string.Create(CultureInfo.InvariantCulture,
            $"postgresql+psycopg://{PostgresLayout.User}:{Uri.EscapeDataString(Password())}@127.0.0.1:{Layout.Port}/{PostgresLayout.DatabaseName}");

    /// <summary>Creates the cluster when there is none, starts the server, and creates the database.</summary>
    /// <returns>Whether the server is running; <see cref="Status"/> says why not.</returns>
    public async Task<bool> StartAsync(CancellationToken cancellationToken = default)
    {
        Set(new PostgresStatus(PostgresState.Starting));
        try
        {
            string password = Password();
            Directory.CreateDirectory(Path.GetDirectoryName(Layout.LogFile)!);
            CreatedCluster = false;
            if (!Layout.HasCluster)
            {
                await InitDbAsync(password, cancellationToken).ConfigureAwait(false);
                CreatedCluster = true;
            }
            else if ((await RunAsync("pg_ctl", ["status", "-D", Layout.ClusterDirectory], cancellationToken).ConfigureAwait(false)).ExitCode == 0)
            {
                Append("A server from an earlier run is still up; stopping it first");
                await StopServerAsync(cancellationToken).ConfigureAwait(false);
            }

            ToolResult started = await RunAsync("pg_ctl",
            [
                "start", "-w", "-t", "60", "-D", Layout.ClusterDirectory, "-l", Layout.LogFile,
                "-o", string.Create(CultureInfo.InvariantCulture, $"-p {Layout.Port} -c listen_addresses=127.0.0.1"),
            ], cancellationToken, capture: false).ConfigureAwait(false);
            if (started.ExitCode != 0)
            {
                throw new PostgresException($"the server did not start (pg_ctl exit {started.ExitCode}):{LogTail()}");
            }

            ToolResult version = await RunAsync("postgres", ["--version"], cancellationToken).ConfigureAwait(false);
            await EnsureDatabaseAsync(password, cancellationToken).ConfigureAwait(false);
            _dispatcher.Run(() => Version = version.Output.Trim().Replace("postgres (PostgreSQL)", "PostgreSQL", StringComparison.Ordinal));
            Set(new PostgresStatus(PostgresState.Running));
            Append($"Running on 127.0.0.1:{Layout.Port}, cluster in {Layout.ClusterDirectory}");
            return true;
        }
        catch (Exception ex) when (ex is PostgresException or IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
        {
            Set(new PostgresStatus(PostgresState.Failed, ex.Message));
            Append(ex.Message, LogLevel.Error);
            return false;
        }
    }

    /// <summary>Stops the server with a fast shutdown.</summary>
    public async Task StopAsync(CancellationToken cancellationToken = default)
    {
        if (!Layout.HasCluster)
        {
            Set(new PostgresStatus(PostgresState.Stopped));
            return;
        }
        Set(new PostgresStatus(PostgresState.Stopping));
        await StopServerAsync(cancellationToken).ConfigureAwait(false);
        Set(new PostgresStatus(PostgresState.Stopped));
    }

    /// <summary>
    /// Stops the server and deletes the cluster: the data half of Reset Database. The next
    /// <see cref="StartAsync"/> creates a new, empty one. The password stays.
    /// </summary>
    public async Task DeleteClusterAsync(CancellationToken cancellationToken = default)
    {
        await StopAsync(cancellationToken).ConfigureAwait(false);
        if (Directory.Exists(Layout.ClusterDirectory))
        {
            Directory.Delete(Layout.ClusterDirectory, recursive: true);
            Append($"Deleted {Layout.ClusterDirectory}");
        }
    }

    /// <summary>Writes a portable custom-format dump of the database (the Mac's <c>backupDatabase</c>).</summary>
    public async Task BackupAsync(string destination, CancellationToken cancellationToken = default)
    {
        RequireRunning();
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(destination))!);
        ToolResult dumped = await RunAsync("pg_dump",
            [.. ClientArguments(), "--format=custom", "--no-owner", "--no-privileges", "--file", destination, PostgresLayout.DatabaseName],
            cancellationToken, Auth()).ConfigureAwait(false);
        if (dumped.ExitCode != 0)
        {
            File.Delete(destination);
            throw new PostgresException($"pg_dump failed: {LastLines(dumped.Output)}");
        }
        Append($"Backed up the database to {destination}");
    }

    /// <summary>
    /// Replaces the database with a custom-format dump (the Mac's <c>restoreDatabase</c>): drops it,
    /// disconnecting the services' connections, creates it empty, and restores into it. The caller
    /// applies the schema afterwards, since a dump from an older Garage may lack migrations.
    /// </summary>
    public async Task RestoreAsync(string source, CancellationToken cancellationToken = default)
    {
        RequireRunning();
        if (!File.Exists(source))
        {
            throw new PostgresException($"the backup {source} does not exist");
        }
        ToolResult dropped = await RunAsync("dropdb", [.. ClientArguments(), "--force", "--if-exists", PostgresLayout.DatabaseName], cancellationToken, Auth()).ConfigureAwait(false);
        if (dropped.ExitCode != 0)
        {
            throw new PostgresException($"dropdb failed: {LastLines(dropped.Output)}");
        }
        await EnsureDatabaseAsync(Password(), cancellationToken).ConfigureAwait(false);
        ToolResult restored = await RunAsync("pg_restore",
            [.. ClientArguments(), "--no-owner", "--no-privileges", "--exit-on-error", "--dbname", PostgresLayout.DatabaseName, source],
            cancellationToken, Auth()).ConfigureAwait(false);
        if (restored.ExitCode != 0)
        {
            throw new PostgresException($"pg_restore failed: {LastLines(restored.Output)}");
        }
        Append($"Restored the database from {source}");
    }

    /// <summary>The database's size on disk and its extensions (the Mac's <c>fetchServerDetails</c>).</summary>
    public async Task<PostgresDetails> DetailsAsync(CancellationToken cancellationToken = default)
    {
        RequireRunning();
        ToolResult rows = await RunAsync("psql",
        [
            .. ClientArguments(), "-d", PostgresLayout.DatabaseName, "-tA", "-F", "|", "-c",
            "SELECT 'size', pg_database_size(current_database())::text UNION ALL SELECT extname, extversion FROM pg_extension WHERE extname <> 'plpgsql' ORDER BY 1",
        ], cancellationToken, Auth()).ConfigureAwait(false);
        if (rows.ExitCode != 0)
        {
            throw new PostgresException($"could not read the server's details: {LastLines(rows.Output)}");
        }
        long size = 0;
        List<string> extensions = [];
        foreach (string line in rows.Output.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            string[] parts = line.Split('|');
            if (parts.Length != 2)
            {
                continue;
            }
            if (parts[0] == "size")
            {
                _ = long.TryParse(parts[1], NumberStyles.None, CultureInfo.InvariantCulture, out size);
            }
            else
            {
                extensions.Add($"{parts[0]} {parts[1]}");
            }
        }
        return new PostgresDetails(size, extensions);
    }

    private void RequireRunning()
    {
        if (Status.State is not (PostgresState.Running or PostgresState.NeedsMigration))
        {
            throw new PostgresException("Garage's Postgres is not running");
        }
    }

    private Dictionary<string, string> Auth() => new(StringComparer.Ordinal) { ["PGPASSWORD"] = Password() };

    private async Task StopServerAsync(CancellationToken cancellationToken)
    {
        ToolResult stopped = await RunAsync("pg_ctl", ["stop", "-D", Layout.ClusterDirectory, "-m", "fast", "-w", "-t", "60"], cancellationToken).ConfigureAwait(false);
        Append(stopped.ExitCode == 0 ? "Stopped" : $"pg_ctl stop: {LastLines(stopped.Output)}", stopped.ExitCode == 0 ? LogLevel.Info : LogLevel.Warning);
    }

    private async Task InitDbAsync(string password, CancellationToken cancellationToken)
    {
        Append($"Creating the cluster in {Layout.ClusterDirectory}");
        Directory.CreateDirectory(Layout.ClusterDirectory);
        // initdb reads the password from a file; it lives only for the call, beside the cluster.
        string passwordFile = Path.Combine(Layout.DataDirectory, $".initdb-password-{Guid.NewGuid():N}");
        await File.WriteAllTextAsync(passwordFile, password + "\n", cancellationToken).ConfigureAwait(false);
        try
        {
            // UTF-8 with ICU collation under the C locale, as the Windows CI cluster: a Windows
            // locale (English_United States.1252) would clash with UTF-8.
            ToolResult result = await RunAsync("initdb",
            [
                "-D", Layout.ClusterDirectory, "-U", PostgresLayout.User, "-E", "UTF8", "--locale=C",
                "--locale-provider=icu", "--icu-locale=en-US", "--auth=scram-sha-256",
                $"--pwfile={passwordFile}", "--no-instructions",
            ], cancellationToken).ConfigureAwait(false);
            if (result.ExitCode != 0)
            {
                throw new PostgresException($"initdb failed: {LastLines(result.Output)}");
            }
        }
        finally
        {
            File.Delete(passwordFile);
        }
    }

    private async Task EnsureDatabaseAsync(string password, CancellationToken cancellationToken)
    {
        Dictionary<string, string> auth = new(StringComparer.Ordinal) { ["PGPASSWORD"] = password };
        ToolResult exists = await RunAsync("psql",
            [.. ClientArguments(), "-d", "postgres", "-tAc", $"SELECT 1 FROM pg_database WHERE datname = '{PostgresLayout.DatabaseName}'"],
            cancellationToken, auth).ConfigureAwait(false);
        if (exists.ExitCode != 0)
        {
            throw new PostgresException($"could not list the databases: {LastLines(exists.Output)}");
        }
        if (exists.Output.Trim() == "1")
        {
            return;
        }
        ToolResult created = await RunAsync("createdb", [.. ClientArguments(), PostgresLayout.DatabaseName], cancellationToken, auth).ConfigureAwait(false);
        if (created.ExitCode != 0)
        {
            throw new PostgresException($"createdb failed: {LastLines(created.Output)}");
        }
        Append($"Created the database {PostgresLayout.DatabaseName}");
    }

    private string[] ClientArguments() =>
        ["-h", "127.0.0.1", "-p", Layout.Port.ToString(CultureInfo.InvariantCulture), "-U", PostgresLayout.User];

    // The stored password, or a new one on first use. Letters and digits only, so it needs no quoting.
    private string Password()
    {
        if (_secrets.Read(PasswordSecret) is { Length: > 0 } stored)
        {
            return stored;
        }
        if (Layout.HasCluster)
        {
            throw new PostgresException(
                $"the database password is missing from Credential Manager (Garage/{PasswordSecret}), so the cluster in {Layout.ClusterDirectory} cannot be opened. Reset Database starts a new one.");
        }
        string password = Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(24));
        _secrets.Write(PasswordSecret, password);
        return password;
    }

    private sealed record ToolResult(int ExitCode, string Output);

    // capture: false for pg_ctl start, whose server inherits the tool's handles and holds redirected
    // pipes open for as long as it runs; its output goes to the server log instead.
    private async Task<ToolResult> RunAsync(string tool, IReadOnlyList<string> arguments, CancellationToken cancellationToken,
        IReadOnlyDictionary<string, string>? environment = null, bool capture = true)
    {
        var info = new ProcessStartInfo(Layout.Tool(tool))
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = capture,
            RedirectStandardError = capture,
            WorkingDirectory = Layout.DataDirectory,
        };
        if (capture)
        {
            info.StandardOutputEncoding = Encoding.UTF8;
            info.StandardErrorEncoding = Encoding.UTF8;
        }
        foreach (string argument in arguments)
        {
            info.ArgumentList.Add(argument);
        }
        // Nothing from the account's own Postgres setup may point these tools elsewhere.
        foreach (string name in (string[])["PGHOST", "PGPORT", "PGUSER", "PGDATABASE", "PGPASSWORD", "PGPASSFILE", "PGSERVICE", "PGDATA"])
        {
            info.Environment.Remove(name);
        }
        foreach ((string name, string value) in environment ?? new Dictionary<string, string>())
        {
            info.Environment[name] = value;
        }
        using Process process = Process.Start(info) ?? throw new PostgresException($"{tool} did not start");
        Task<string> stdout = capture ? process.StandardOutput.ReadToEndAsync(cancellationToken) : Task.FromResult("");
        Task<string> stderr = capture ? process.StandardError.ReadToEndAsync(cancellationToken) : Task.FromResult("");
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(ToolTimeout);
        await process.WaitForExitAsync(timeout.Token).ConfigureAwait(false);
        string output = (await stdout.ConfigureAwait(false)) + (await stderr.ConfigureAwait(false));
        return new ToolResult(process.ExitCode, output);
    }

    private string LogTail()
    {
        try
        {
            return File.Exists(Layout.LogFile) ? $"\n{LastLines(File.ReadAllText(Layout.LogFile))}" : "";
        }
        catch (IOException)
        {
            return "";
        }
    }

    private static string LastLines(string text) =>
        string.Join('\n', text.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).TakeLast(3));

    private void Set(PostgresStatus status) => _dispatcher.Run(() => Status = status);

    private void Append(string text, LogLevel level = LogLevel.Info) =>
        _dispatcher.Run(() => Log.Append(text, level >= LogLevel.Error ? LogChannel.Stderr : LogChannel.Stdout, level));
}

/// <summary>What the Database page shows about the running server.</summary>
/// <param name="SizeBytes">The database's size on disk.</param>
/// <param name="Extensions">"vector 0.8.6", "pg_trgm 1.6", …</param>
public sealed record PostgresDetails(long SizeBytes, IReadOnlyList<string> Extensions);

/// <summary>Garage's Postgres could not be created, started or reached.</summary>
public sealed class PostgresException : Exception
{
    /// <summary>Creates the exception.</summary>
    public PostgresException()
    {
    }

    /// <summary>Creates the exception with a message.</summary>
    public PostgresException(string message)
        : base(message)
    {
    }

    /// <summary>Creates the exception with a message and a cause.</summary>
    public PostgresException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}

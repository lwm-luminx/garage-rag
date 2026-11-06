using System.Globalization;
using Garage.App.Core.Presentation;
using Garage.Grpc.Services;

namespace Garage.App.Core.Services;

/// <summary>One self test as the expanded row lists it.</summary>
public sealed record SelfTestLine(string Name, string Status, string Summary, Tint Tint, string Duration)
{
    /// <summary>From a service's report.</summary>
    public static SelfTestLine From(SelfTestResult result)
    {
        ArgumentNullException.ThrowIfNull(result);
        Tint tint = result.Status switch
        {
            "passed" => Tint.Green,
            "failed" => Tint.Red,
            _ => Tint.Secondary,
        };
        return new(result.Name, result.Status, result.Summary, tint,
            string.Create(CultureInfo.CurrentCulture, $"{result.DurationMs:0} ms"));
    }
}

/// <summary>
/// A row in the Status page's Services box: a port of the Mac's <c>ServiceRowPresentation</c> (its
/// <c>xpc</c> case: state, latency and the self-test summary).
/// </summary>
public sealed record ServiceRowPresentation(string Id, string Name, ServiceState State, string Detail, bool DetailIsError)
{
    /// <summary>The dot's colour.</summary>
    public Tint Tint => State switch
    {
        ServiceState.Running => Tint.Green,
        ServiceState.Checking or ServiceState.Restarting => Tint.Orange,
        ServiceState.Unreachable => Tint.Red,
        _ => Tint.Secondary,
    };

    /// <summary>A filled dot for a running or unreachable service, a ring otherwise.</summary>
    public bool IsActive => State is ServiceState.Running or ServiceState.Unreachable;

    /// <summary>A spinner stands in for the dot.</summary>
    public bool IsBusy => State is ServiceState.Checking or ServiceState.Restarting;

    /// <summary>
    /// The Restart button's colour when a restart is what the row calls for: red for a service that
    /// cannot be reached, orange for one that runs but fails its tests, none otherwise.
    /// </summary>
    public Tint? RestartTint => State switch
    {
        ServiceState.Unreachable => Tint.Red,
        ServiceState.Running when DetailIsError => Tint.Orange,
        _ => null,
    };

    /// <summary>The state in a word.</summary>
    public string StateTitle => State switch
    {
        ServiceState.Running => "Running",
        ServiceState.Checking => "Checking…",
        ServiceState.Restarting => "Restarting…",
        ServiceState.Stopped => "Stopped",
        ServiceState.Unreachable => "Can't be reached",
        _ => "Not checked yet",
    };

    /// <summary>The row's name for a service id.</summary>
    public static string NameFor(string id) => id switch
    {
        "core" => "Garage Backend",
        "ingest" => "Ingest",
        "embed" => "Embeddings",
        "llama" => "Built-in Engine",
        "mcp" => "MCP Server",
        "postgres" => "Database",
        _ => id,
    };

    /// <summary>What each service does, for the expanded row.</summary>
    public static string RoleFor(string id) => id switch
    {
        "core" => "The Python GarageService over gRPC: search, documents, sources, models, stats, and every operation the app runs.",
        "ingest" => "Reads sources into the database through the backend, one source at a time.",
        "postgres" => "Garage's own PostgreSQL with pgvector, on this PC only. The Database page has its schema, backups and Reset.",
        _ => "",
    };

    /// <summary>The row for <paramref name="id"/> in <paramref name="state"/>, with its last report.</summary>
    public static ServiceRowPresentation Make(string id, ServiceState state, string? error, double? latencyMs, ServiceStatusReport? report)
    {
        List<string> parts = [];
        bool isError = false;
        switch (state)
        {
            case ServiceState.Running:
                parts.Add("Running");
                if (latencyMs is { } ms)
                {
                    parts.Add(string.Create(CultureInfo.CurrentCulture, $"{ms:0} ms"));
                }
                if (report is { Tests.Count: > 0 })
                {
                    parts.Add(SelfTestSummary(report.Tests));
                    isError = report.Tests.Any(t => t.Status == "failed");
                }
                break;
            case ServiceState.Checking:
                parts.Add(report is null ? "Starting…" : "Checking…");
                break;
            case ServiceState.Restarting:
                parts.Add("Restarting…");
                break;
            case ServiceState.Stopped:
                parts.Add(error ?? "Stopped");
                break;
            case ServiceState.Unreachable:
                parts.Add($"Can't be reached: {FirstLine(error) ?? "no reply"}");
                isError = true;
                break;
            default:
                parts.Add("Not checked yet");
                break;
        }
        return new(id, NameFor(id), state, string.Join(" · ", parts), isError);
    }

    /// <summary>
    /// The Database row: Garage's own Postgres among the services, as the Mac's Status page lists its
    /// database. "Running · PostgreSQL 18.6 · port 14824".
    /// </summary>
    public static ServiceRowPresentation ForPostgres(Database.PostgresStatus status, string? version, int port)
    {
        ArgumentNullException.ThrowIfNull(status);
        string where = string.Create(CultureInfo.InvariantCulture, $"port {port}");
        return status.State switch
        {
            Database.PostgresState.Running => new("postgres", NameFor("postgres"), ServiceState.Running,
                string.Join(" · ", new[] { "Running", version, where }.Where(p => !string.IsNullOrEmpty(p))), false),
            Database.PostgresState.NeedsMigration => new("postgres", NameFor("postgres"), ServiceState.Running,
                "Running · schema updates to apply (Database page)", true),
            Database.PostgresState.Starting => new("postgres", NameFor("postgres"), ServiceState.Checking, "Starting…", false),
            Database.PostgresState.Stopping => new("postgres", NameFor("postgres"), ServiceState.Checking, "Stopping…", false),
            Database.PostgresState.Stopped => new("postgres", NameFor("postgres"), ServiceState.Stopped, "Stopped", false),
            _ => new("postgres", NameFor("postgres"), ServiceState.Unreachable,
                $"Can't be reached: {FirstLine(status.FailureMessage) ?? "did not start"}", true),
        };
    }

    /// <summary>The row for a running service process.</summary>
    public static ServiceRowPresentation From(ServiceProcess service)
    {
        ArgumentNullException.ThrowIfNull(service);
        return Make(service.Id, service.State, service.Error, service.LatencyMs, service.Report);
    }

    /// <summary>
    /// "10 passed, 1 skipped (libtesseract)": a skipped test is neither a pass nor a failure, so
    /// "10 of 12 passed" would read as two failures; the skipped ones are named.
    /// </summary>
    public static string SelfTestSummary(IEnumerable<SelfTestResult> tests)
    {
        ArgumentNullException.ThrowIfNull(tests);
        List<SelfTestResult> all = [.. tests];
        int passed = all.Count(t => t.Status == "passed");
        int failed = all.Count(t => t.Status == "failed");
        List<string> skipped = [.. all.Where(t => t.Status == "skipped").Select(t => t.Name)];
        List<string> parts = [string.Create(CultureInfo.CurrentCulture, $"{passed} passed")];
        if (failed > 0)
        {
            parts.Add(string.Create(CultureInfo.CurrentCulture, $"{failed} failed"));
        }
        if (skipped.Count > 0)
        {
            parts.Add(string.Create(CultureInfo.CurrentCulture, $"{skipped.Count} skipped ({string.Join(", ", skipped)})"));
        }
        return string.Join(", ", parts);
    }

    private static string? FirstLine(string? text) =>
        text?.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).FirstOrDefault();
}

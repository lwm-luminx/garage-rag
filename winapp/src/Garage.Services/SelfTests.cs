using System.Diagnostics;
using System.Text.Json.Nodes;
using Garage.Grpc;
using Garage.Grpc.Services;
using Garage.Services.Native;

namespace Garage.Services;

/// <summary>
/// A service's self tests, the counterpart of <c>GarageXPCStandardSelfTests</c>: each checks one
/// thing the service needs, and the Status page shows the results ("4 passed, 1 skipped (…)").
/// </summary>
internal static class SelfTests
{
    /// <summary>A test whose check returns its summary, or throws to fail, or <see cref="Skip"/>s.</summary>
    public sealed record Test(string Name, string Description, Func<string> Check);

    /// <summary>Thrown by a check that has nothing to check yet.</summary>
    public sealed class SkipException(string reason) : Exception(reason);

    /// <summary>Ends a check as skipped.</summary>
    public static string Skip(string reason) => throw new SkipException(reason);

    /// <summary>The tests <paramref name="options"/>' service runs.</summary>
    public static IReadOnlyList<Test> For(ServiceOptions options, ServiceLog log, Func<bool>? listening = null)
    {
        List<Test> tests = [NativeLibraries(), Database(options)];
        if (options.Role == ServiceRole.Ingest)
        {
            tests.Add(GrpcConnection(options.GrpcPort));
        }
        if (options.Role == ServiceRole.Mcp)
        {
            tests.Add(HttpServer(options.McpPort, listening ?? (() => false)));
        }
        tests.Add(Logging(log));
        return tests;
    }

    /// <summary>Runs <paramref name="tests"/> in order.</summary>
    public static IReadOnlyList<SelfTestResult> Run(IEnumerable<Test> tests)
    {
        List<SelfTestResult> results = [];
        foreach (Test test in tests)
        {
            var result = new SelfTestResult { Name = test.Name, Description = test.Description };
            var clock = Stopwatch.StartNew();
            try
            {
                result.Summary = test.Check();
                result.Status = "passed";
            }
            catch (SkipException skip)
            {
                result.Status = "skipped";
                result.Summary = skip.Message;
            }
            catch (Exception ex) when (ex is not OutOfMemoryException)
            {
                result.Status = "failed";
                result.Summary = ex.GetBaseException().Message;
                result.Details = ex is NativeCallException ? "" : ex.ToString();
            }
            result.DurationMs = clock.Elapsed.TotalMilliseconds;
            results.Add(result);
        }
        return results;
    }

    private static Test NativeLibraries() => new(
        "Native Libraries",
        "Loads the Rust libraries the service runs: garage_service_ffi, garage_ingest_ffi and garage_mcp_ffi.",
        () =>
        {
            List<string> loaded = [];
            foreach (string library in GarageNative.Libraries)
            {
                loaded.Add(Path.GetFileName(GarageNative.Load(library)));
            }
            return $"GarageService {GarageNative.ServiceVersion()}; {string.Join(", ", loaded)}";
        });

    private static unsafe Test Database(ServiceOptions options) => new(
        "Database Connection",
        "GarageService reaches the configured database (garage.json, or GARAGE_DATABASE_URL) and reads its version.",
        () =>
        {
            var request = new JsonObject { ["config"] = Path.Combine(options.DataDirectory, "garage.json") };
            byte* text = GarageNative.Request(request);
            byte* result = null;
            int status;
            try
            {
                status = GarageNative.ServiceProbe(text, &result);
            }
            finally
            {
                NativeString.Free(text);
            }
            JsonObject reply = GarageNative.TakeResult(status, result, &GarageNative.ServiceStringFree, "the database did not answer");
            return $"{reply["database"]?.GetValue<string>() ?? "unknown"} at {reply["database_url"]?.GetValue<string>() ?? ""}";
        });

    private static Test GrpcConnection(int port) => new(
        "gRPC Connection",
        "Opens a channel to the Garage backend with this launch's token and pings it.",
        () =>
        {
            var endpoint = new GarageEndpoint(new UriBuilder(Uri.UriSchemeHttp, "127.0.0.1", port).Uri, Environment.GetEnvironmentVariable("GARAGE_GRPC_TOKEN"));
            using Grpc.Net.Client.GrpcChannel channel = endpoint.OpenChannel();
            endpoint.CreateClient(channel).Ping(new Garage.PingRequest(), deadline: DateTime.UtcNow.AddSeconds(10));
            return $"Backend reachable at 127.0.0.1:{port}";
        });

    private static Test HttpServer(int port, Func<bool> listening) => new(
        "HTTP Server",
        "The streamable-HTTP server is up on this PC only.",
        () => listening() ? $"Listening on http://127.0.0.1:{port}/mcp" : throw new InvalidOperationException("not running"));

    private static Test Logging(ServiceLog log) => new(
        "Logging",
        "The log folder is writable.",
        () => log.HasFile ? $"Writing {log.FilePath}" : throw new IOException("the log file could not be opened"));
}

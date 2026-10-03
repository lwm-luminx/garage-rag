using System.Diagnostics;
using Garage.Grpc.Services;
using Garage.Python;
using Py = Garage.Python.Python;

namespace Garage.Services;

/// <summary>
/// A service's self tests, the counterpart of <c>GarageXPCStandardSelfTests</c>: each checks one
/// thing the service needs, and the Status page shows the results ("8 passed, 1 skipped (…)").
/// </summary>
internal static class SelfTests
{
    /// <summary>A test whose check returns its summary, or throws to fail, or <see cref="Skip"/>s.</summary>
    public sealed record Test(string Name, string Description, Func<string> Check, bool RequiresPython = true);

    /// <summary>Thrown by a check that has nothing to check yet.</summary>
    public sealed class SkipException(string reason) : Exception(reason);

    /// <summary>Ends a check as skipped.</summary>
    public static string Skip(string reason) => throw new SkipException(reason);

    /// <summary>The tests <paramref name="options"/>' service runs.</summary>
    public static IReadOnlyList<Test> For(ServiceOptions options, ServiceLog log)
    {
        List<Test> tests =
        [
            PythonRuntime(options),
            StdlibExtensions(),
            SitePackages(["grpc", "psycopg", "google.protobuf", "pydantic", "garage_rag"]),
            Libpq(),
            Tesseract(),
        ];
        tests.Add(options.Role switch
        {
            ServiceRole.Core => ServiceModule("garage_rag.service.server", ["create_grpc_server"]),
            ServiceRole.Ingest => ServiceModule("garage_rag.ingest", ["ingest_xpc", "cancel_ingest", "set_c_progress_callback", "set_c_log_callback"]),
            ServiceRole.Mcp => ServiceModule("garage_rag.mcp_server.server", ["start_background_server", "stop_background_server", "is_background_server_running", "background_server_error"]),
            _ => throw new InvalidOperationException(),
        });
        tests.Add(Database());
        if (options.Role == ServiceRole.Ingest)
        {
            tests.Add(GrpcConnection(options.GrpcPort));
        }
        if (options.Role == ServiceRole.Mcp)
        {
            tests.Add(HttpServer(options.McpPort));
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
            if (test.RequiresPython && !PythonHost.IsReady)
            {
                result.Status = "failed";
                result.Summary = $"Python did not start: {PythonHost.StartError ?? "not started"}";
            }
            else
            {
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
                catch (Exception ex)
                {
                    result.Status = "failed";
                    result.Summary = PythonHost.Describe(ex);
                    result.Details = ex is PythonException { PythonTraceback: { } traceback } ? traceback : "";
                }
            }
            result.DurationMs = clock.Elapsed.TotalMilliseconds;
            results.Add(result);
        }
        return results;
    }

    // Each check runs a short Python snippet that leaves its summary in `summary`, or `skip` with a reason.
    private static string RunPython(string code)
    {
        using PythonObject globals = Py.Exec(code);
        return globals.HasItem("skip") && globals["skip"].As<string>() is { Length: > 0 } reason
            ? Skip(reason)
            : globals["summary"].As<string>();
    }

    private static bool HasItem(this PythonObject dict, string key)
    {
        using PythonObject contains = dict.Invoke("__contains__", key);
        return contains.IsTrue();
    }

    private static Test PythonRuntime(ServiceOptions options) => new(
        "Python Runtime",
        "Interpreter started from the configured home with an isolated sys.path.",
        () =>
        {
            string[] roots = [options.PythonHome, options.SitePackages ?? "", .. options.ExtraPythonPaths];
            return RunPython($$"""
                import os, sys
                norm = lambda p: os.path.normcase(os.path.abspath(p))
                roots = [norm(p) for p in {{Literal(string.Join(';', roots))}}.split(";") if p]
                outside = [p for p in sys.path if p and not any(norm(p).startswith(r) for r in roots)]
                if outside:
                    raise RuntimeError("sys.path reaches outside the environment: " + ", ".join(outside))
                if not sys.flags.isolated:
                    raise RuntimeError("the interpreter is not isolated")
                summary = f"Python {sys.version.split()[0]}, isolated, {len(sys.path)} path entries"
                """);
        });

    private static Test StdlibExtensions()
    {
        string[] modules = ["_socket", "_ssl", "_hashlib", "zlib", "_json", "_sqlite3", "_ctypes", "select", "math", "_datetime"];
        return new(
            "Standard Library Extensions",
            "Loads compiled extension modules from the home's DLLs folder (sockets, TLS, zlib, sqlite, ctypes).",
            () => RunPython($$"""
                import importlib
                names = {{Literal(string.Join(',', modules))}}.split(",")
                for name in names:
                    importlib.import_module(name)
                summary = f"{len(names)} extension modules load"
                """));
    }

    private static Test SitePackages(string[] modules) => new(
        "Site Packages",
        $"Imports required packages: {string.Join(", ", modules)}.",
        () => RunPython($$"""
            import importlib
            names = {{Literal(string.Join(',', modules))}}.split(",")
            for name in names:
                importlib.import_module(name)
            summary = f"{len(names)} packages import"
            """));

    private static Test Libpq() => new(
        "libpq",
        "psycopg finds a libpq: its binary wheel's copy on Windows.",
        () => RunPython("""
            import psycopg
            v = psycopg.pq.version()
            summary = f"psycopg {psycopg.__version__} ({psycopg.pq.__impl__}), libpq {v // 10000}.{v % 100}"
            """));

    private static Test Tesseract() => new(
        "libtesseract",
        "garage_rag's OCR finds libtesseract and its tessdata (installed with Tesseract until the app bundles it).",
        () => RunPython("""
            from garage_rag.extract import tesseract
            try:
                summary = f"Tesseract {tesseract.version()}"
            except tesseract.TesseractUnavailable as e:
                skip = f"not installed: images are not read ({str(e).splitlines()[0]})"
            """));

    private static Test ServiceModule(string module, string[] attributes) => new(
        "Service Module",
        $"Imports {module} and verifies {string.Join(", ", attributes)}.",
        () => RunPython($$"""
            import importlib
            m = importlib.import_module({{Literal(module)}})
            missing = [a for a in {{Literal(string.Join(',', attributes))}}.split(",") if not hasattr(m, a)]
            if missing:
                raise AttributeError(f"{m.__name__} lacks " + ", ".join(missing))
            summary = f"{m.__name__} has " + ", ".join({{Literal(string.Join(',', attributes))}}.split(","))
            """));

    private static Test Database() => new(
        "Database Connection",
        "Opens a psycopg connection to the configured database, runs SELECT version() and checks the vector extension.",
        () => RunPython("""
            import psycopg
            from garage_rag.config import get_settings
            url = get_settings().database_url.replace("postgresql+psycopg://", "postgresql://", 1)
            with psycopg.connect(url, connect_timeout=5) as conn:
                version = conn.execute("SHOW server_version").fetchone()[0]
                ext = dict(conn.execute("SELECT extname, extversion FROM pg_extension").fetchall())
            if "vector" not in ext:
                raise RuntimeError(f"PostgreSQL {version} has no vector extension; run garage init-db")
            summary = f"PostgreSQL {version}, pgvector {ext['vector']}" + (f", AGE {ext['age']}" if "age" in ext else "")
            """));

    private static Test GrpcConnection(int port) => new(
        "gRPC Connection",
        "Opens a grpc channel to the Garage backend and waits for it to become ready.",
        () => RunPython($$"""
            import grpc
            channel = grpc.insecure_channel("127.0.0.1:{{port}}")
            try:
                grpc.channel_ready_future(channel).result(timeout=10)
            finally:
                channel.close()
            summary = "Backend reachable at 127.0.0.1:{{port}}"
            """));

    private static Test HttpServer(int port) => new(
        "HTTP Server",
        "The streamable-HTTP server is up on this PC only.",
        () => RunPython($$"""
            from garage_rag.mcp_server import server
            if not server.is_background_server_running():
                raise RuntimeError(server.background_server_error() or "not running")
            summary = "Listening on http://127.0.0.1:{{port}}/mcp"
            """));

    private static Test Logging(ServiceLog log) => new(
        "Logging",
        "The log folder is writable.",
        () => log.HasFile ? $"Writing {log.FilePath}" : throw new IOException("the log file could not be opened"),
        RequiresPython: false);

    // A Python string literal for a value from the host.
    private static string Literal(string value) =>
        "\"" + value.Replace("\\", "\\\\", StringComparison.Ordinal).Replace("\"", "\\\"", StringComparison.Ordinal) + "\"";
}

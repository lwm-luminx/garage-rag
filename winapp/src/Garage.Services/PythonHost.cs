using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Garage.Python;
using Garage.Python.Interop;

namespace Garage.Services;

/// <summary>
/// The service's interpreter: started once, with Python's logging, <c>print</c> and uncaught
/// exceptions routed into the <see cref="ServiceLog"/> through <c>garage_rag.ingest.set_c_log_callback</c>,
/// as the Mac services route them into unified logging.
/// </summary>
internal static unsafe class PythonHost
{
    private static ServiceLog? _log;

    /// <summary>Why the interpreter could not start, when it could not.</summary>
    public static string? StartError { get; private set; }

    /// <summary>Whether the interpreter is running.</summary>
    public static bool IsReady => Python.Python.IsRunning && StartError is null;

    /// <summary>
    /// Starts the interpreter from <paramref name="options"/>' environment. Failure is recorded in
    /// <see cref="StartError"/> rather than thrown: the service still answers the app, whose Status
    /// page then shows why.
    /// </summary>
    public static bool Start(ServiceOptions options, ServiceLog log)
    {
        _log = log;
        try
        {
            PythonEnvironment environment = PythonEnvironment.FromHome(options.PythonHome, options.SitePackages, options.ExtraPythonPaths);
            if (environment.ValidationProblems() is { Count: > 0 } problems)
            {
                throw new PythonInitializationException(string.Join("; ", problems));
            }
            Python.Python.Initialize(environment, new PythonOptions { ProgramName = "Garage.Services" });
            log.Info($"Python {Python.Python.Version} started from {environment.Home}");

            using PythonObject ingest = Python.Python.Import("garage_rag.ingest");
            ingest.Invoke("set_c_log_callback", (nint)(delegate* unmanaged[Cdecl]<int, byte*, void>)&OnPythonLog).Dispose();
            return true;
        }
        catch (Exception ex) when (ex is PythonInitializationException or PythonException or FileNotFoundException or DllNotFoundException or BadImageFormatException)
        {
            StartError = ex is PythonException python ? $"{python.PythonType}: {python.PythonMessage}" : ex.Message;
            log.Error($"Python did not start: {StartError}");
            return false;
        }
    }

    /// <summary>A Python exception's first line, for a reply or a log line.</summary>
    public static string Describe(Exception ex) => ex switch
    {
        PythonException python => $"{ShortType(python.PythonType)}: {python.PythonMessage}",
        _ => ex.Message,
    };

    private static string ShortType(string type) => type.StartsWith("builtins.", StringComparison.Ordinal) ? type[9..] : type;

    // void callback(int level, const char *message), what garage_rag.ingest's OSLogHandler calls.
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static void OnPythonLog(int level, byte* message)
    {
        try
        {
            if (NativeUtf8.Read((nint)message) is { } text)
            {
                _log?.Append(level, text, "python");
            }
        }
        catch (Exception)
        {
            // An exception must never cross back into Python's frame.
        }
    }
}

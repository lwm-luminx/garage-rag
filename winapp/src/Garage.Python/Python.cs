using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using Garage.Python.Native;

namespace Garage.Python;

/// <summary>
/// The embedded interpreter: start-up, GIL scopes and module access. The Windows counterpart of
/// <c>GaragePythonRuntime</c> plus <c>GaragePythonEmbed.c</c> in the Mac app, with the C shim's
/// work done through PEP 741's <c>PyInitConfig</c> API, which needs no struct layouts.
/// </summary>
/// <remarks>
/// A process starts one interpreter, once (<see cref="Initialize"/>). With
/// <see cref="PythonOptions.ReleaseGilAfterInit"/> (the default) no thread holds the GIL afterwards;
/// any thread takes it with <see cref="Gil"/>, and <see cref="PythonObject"/> takes it itself.
/// </remarks>
public static class Python
{
    private static readonly Lock Gate = new();
    private static readonly ConcurrentQueue<nint> PendingDecRefs = new();
    private static volatile RuntimeState _state = RuntimeState.NotStarted;
    private static int _initThreadId;
    private static PythonEnvironment? _environment;

    private enum RuntimeState
    {
        NotStarted,
        Running,
        Finalized,
    }

    /// <summary>Whether the interpreter is running (initialized and not finalized).</summary>
    public static bool IsRunning => _state == RuntimeState.Running;

    /// <summary>The environment the interpreter was started with, or null before <see cref="Initialize"/>.</summary>
    public static PythonEnvironment? Environment => _environment;

    /// <summary>The running interpreter's version string (<c>Py_GetVersion</c>).</summary>
    public static string Version
    {
        get
        {
            EnsureRunning();
            return Marshal.PtrToStringUTF8(CPython.Py_GetVersion()) ?? "";
        }
    }

    /// <summary>
    /// Loads the interpreter DLL and starts an isolated interpreter over <paramref name="environment"/>.
    /// </summary>
    /// <exception cref="PythonInitializationException">The layout is incomplete, or CPython refused to start.</exception>
    /// <exception cref="InvalidOperationException">An interpreter was already started in this process.</exception>
    public static void Initialize(PythonEnvironment environment, PythonOptions? options = null)
    {
        ArgumentNullException.ThrowIfNull(environment);
        options ??= new PythonOptions();

        lock (Gate)
        {
            if (_state != RuntimeState.NotStarted)
            {
                throw new InvalidOperationException(
                    _state == RuntimeState.Running
                        ? "the Python interpreter is already running in this process"
                        : "the Python interpreter was finalized; a process starts it only once");
            }

            IReadOnlyList<string> problems = environment.ValidationProblems();
            if (problems.Count > 0)
            {
                throw new PythonInitializationException(
                    "Bundled Python environment is incomplete:\n  - " + string.Join("\n  - ", problems));
            }

            PythonLibrary.Load(environment.LibraryPath);
            if (CPython.Py_IsInitialized() != 0)
            {
                throw new InvalidOperationException("something else in this process already started this interpreter");
            }

            nint config = CPython.PyInitConfig_Create();
            if (config == 0)
            {
                throw new PythonInitializationException("PyInitConfig_Create returned NULL (out of memory)");
            }
            try
            {
                Configure(config, environment, options);
                if (CPython.Py_InitializeFromInitConfig(config) < 0)
                {
                    throw InitializationFailure(config, "Py_InitializeFromInitConfig");
                }
            }
            finally
            {
                CPython.PyInitConfig_Free(config);
            }

            _initThreadId = System.Environment.CurrentManagedThreadId;
            _environment = environment;
            _state = RuntimeState.Running;
            if (options.ImportSite)
            {
                // site.main() would also add the home folder and home\Lib\site-packages, which on
                // Windows exist, so a package installed into the interpreter itself could shadow the
                // bundle's. Start without it and process only the bundle's site-packages (.pth files).
                using PythonObject site = Import("site");
                site.Invoke("addsitedir", environment.SitePackagesDir).Dispose();
            }
            if (options.ReleaseGilAfterInit)
            {
                // The initializing thread holds the GIL now. Release it so any thread can take it
                // with PyGILState_Ensure and threads Python starts can run. The saved state is
                // this thread's; PyGILState_Ensure finds it again when this thread comes back.
                _ = CPython.PyEval_SaveThread();
            }
        }
    }

    /// <summary>
    /// Takes the GIL for the current thread until the returned scope is disposed:
    /// <c>using GilScope gil = Python.Gil();</c>. Scopes nest.
    /// </summary>
    public static GilScope Gil()
    {
        EnsureRunning();
        int state = CPython.PyGILState_Ensure();
        DrainPendingDecRefs();
        return new GilScope(state);
    }

    /// <summary>
    /// Releases the GIL this thread holds until the returned scope is disposed, so Python threads
    /// run while this thread waits: <c>using AllowThreadsScope _ = Python.AllowThreads();</c>.
    /// </summary>
    /// <exception cref="InvalidOperationException">This thread does not hold the GIL.</exception>
    public static AllowThreadsScope AllowThreads()
    {
        EnsureRunning();
        return CPython.PyGILState_Check() == 1
            ? new AllowThreadsScope(CPython.PyEval_SaveThread())
            : throw new InvalidOperationException("this thread does not hold the GIL");
    }

    /// <summary><c>import name</c>; returns the module (for a dotted name, the leaf module).</summary>
    /// <exception cref="PythonException">The import raised.</exception>
    public static PythonObject Import(string name)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(name);
        using GilScope gil = Gil();
        return PythonObject.Checked(CPython.PyImport_ImportModule(name), $"import {name}");
    }

    /// <summary>Python's <c>None</c>.</summary>
    public static PythonObject None => Constant(CPython.Py_CONSTANT_NONE);

    /// <summary>Python's <c>True</c>.</summary>
    public static PythonObject True => Constant(CPython.Py_CONSTANT_TRUE);

    /// <summary>Python's <c>False</c>.</summary>
    public static PythonObject False => Constant(CPython.Py_CONSTANT_FALSE);

    /// <summary>Converts a .NET value to a Python object; the rules are on <see cref="PythonObject.From"/>.</summary>
    public static PythonObject ToPython(object? value) => PythonObject.From(value);

    /// <summary>
    /// Evaluates a Python expression, with <paramref name="variables"/> as its globals.
    /// </summary>
    public static PythonObject Evaluate(string expression, IDictionary<string, object?>? variables = null)
    {
        ArgumentNullException.ThrowIfNull(expression);
        using GilScope gil = Gil();
        using PythonObject builtins = Import("builtins");
        using PythonObject globals = Globals(variables);
        return builtins.Invoke("eval", expression, globals);
    }

    /// <summary>
    /// Runs Python statements with <paramref name="variables"/> as their globals, and returns the
    /// globals afterwards, so the caller can read what the code defined.
    /// </summary>
    public static PythonObject Exec(string code, IDictionary<string, object?>? variables = null)
    {
        ArgumentNullException.ThrowIfNull(code);
        using GilScope gil = Gil();
        using PythonObject builtins = Import("builtins");
        PythonObject globals = Globals(variables);
        try
        {
            builtins.Invoke("exec", code, globals).Dispose();
            return globals;
        }
        catch
        {
            globals.Dispose();
            throw;
        }
    }

    /// <summary>
    /// Stops the interpreter (<c>Py_FinalizeEx</c>). Call from the thread that called
    /// <see cref="Initialize"/>, after every other thread has stopped using Python. Objects still
    /// alive afterwards are abandoned, not released. Services usually exit the process instead.
    /// </summary>
    /// <returns>0, or -1 when flushing buffered data failed (as <c>Py_FinalizeEx</c>).</returns>
    public static int Shutdown()
    {
        lock (Gate)
        {
            if (_state != RuntimeState.Running)
            {
                return 0;
            }
            if (System.Environment.CurrentManagedThreadId != _initThreadId)
            {
                throw new InvalidOperationException("finalize the interpreter from the thread that initialized it");
            }
            _ = CPython.PyGILState_Ensure();
            DrainPendingDecRefs();
            _state = RuntimeState.Finalized;
            return CPython.Py_FinalizeEx();
        }
    }

    /// <summary>Queues a reference for release the next time a thread takes the GIL (finalizers).</summary>
    internal static void DeferDecRef(nint handle)
    {
        if (handle != 0 && _state == RuntimeState.Running)
        {
            PendingDecRefs.Enqueue(handle);
        }
    }

    private static void DrainPendingDecRefs()
    {
        while (PendingDecRefs.TryDequeue(out nint handle))
        {
            CPython.Py_DecRef(handle);
        }
    }

    private static PythonObject Constant(uint id)
    {
        using GilScope gil = Gil();
        return PythonObject.Borrow(CPython.Py_GetConstantBorrowed(id));
    }

    // eval/exec add __builtins__ to a globals dict that lacks it.
    private static PythonObject Globals(IDictionary<string, object?>? variables) =>
        PythonObject.From(new Dictionary<string, object?>(variables ?? new Dictionary<string, object?>()));

    private static void EnsureRunning()
    {
        if (_state != RuntimeState.Running)
        {
            throw new InvalidOperationException(
                _state == RuntimeState.NotStarted
                    ? "the Python interpreter is not running; call Python.Initialize first"
                    : "the Python interpreter was finalized");
        }
    }

    // ---- PEP 741 configuration ------------------------------------------------------------

    private static unsafe void Configure(nint config, PythonEnvironment environment, PythonOptions options)
    {
        // UTF-8 mode (PEP 540): every string this interpreter exchanges with the host is UTF-8, and
        // a service started without a console must not fall back to a legacy code page for stdio.
        SetInt(config, "utf8_mode", 1);

        // Isolated configuration (PyInitConfig_Create's defaults), spelled out as the Mac shim does:
        // no PYTHON* variables, no working directory or user site on sys.path, no argv parsing.
        SetInt(config, "isolated", 1);
        SetInt(config, "use_environment", 0);
        SetInt(config, "user_site_directory", 0);
        SetInt(config, "safe_path", 1);
        SetInt(config, "parse_argv", 0);
        SetInt(config, "configure_c_stdio", 0);
        SetInt(config, "buffered_stdio", 0);
        SetInt(config, "site_import", 0);  // see Initialize: only the bundle's site-packages is processed
        SetInt(config, "install_signal_handlers", options.InstallSignalHandlers ? 1 : 0);
        SetInt(config, "write_bytecode", options.WriteBytecode ? 1 : 0);
        SetInt(config, "pathconfig_warnings", options.Verbose ? 1 : 0);
        SetInt(config, "verbose", options.Verbose ? 1 : 0);

        SetStr(config, "home", environment.Home);
        SetStr(config, "program_name", options.ProgramName);

        // Setting module_search_paths makes it sys.path verbatim (module_search_paths_set), so the
        // landmark search in getpath never runs and nothing outside the bundle is found.
        SetStrList(config, "module_search_paths", environment.SearchPaths);
    }

    private static void SetInt(nint config, string name, long value)
    {
        if (CPython.PyInitConfig_SetInt(config, name, value) < 0)
        {
            throw InitializationFailure(config, name);
        }
    }

    private static void SetStr(nint config, string name, string value)
    {
        if (CPython.PyInitConfig_SetStr(config, name, value) < 0)
        {
            throw InitializationFailure(config, name);
        }
    }

    private static unsafe void SetStrList(nint config, string name, IReadOnlyList<string> values)
    {
        nint[] items = new nint[values.Count];
        try
        {
            for (int i = 0; i < values.Count; i++)
            {
                items[i] = Marshal.StringToCoTaskMemUTF8(values[i]);
            }
            fixed (nint* p = items)
            {
                if (CPython.PyInitConfig_SetStrList(config, name, (nuint)items.Length, p) < 0)
                {
                    throw InitializationFailure(config, name);
                }
            }
        }
        finally
        {
            foreach (nint item in items)
            {
                Marshal.FreeCoTaskMem(item);
            }
        }
    }

    private static PythonInitializationException InitializationFailure(nint config, string step)
    {
        if (CPython.PyInitConfig_GetExitCode(config, out int exitCode) == 1)
        {
            return new PythonInitializationException($"{step}: the interpreter asked to exit (code {exitCode})", exitCode);
        }
        string message = CPython.PyInitConfig_GetError(config, out nint error) == 1
            ? Marshal.PtrToStringUTF8(error) ?? "unknown error"
            : "unknown error";
        return new PythonInitializationException($"{step}: {message}");
    }
}

/// <summary>The embedded interpreter could not start.</summary>
public sealed class PythonInitializationException : Exception
{
    /// <summary>Creates the exception.</summary>
    public PythonInitializationException()
    {
    }

    /// <summary>Creates the exception with a message.</summary>
    public PythonInitializationException(string message)
        : base(message)
    {
    }

    /// <summary>Creates the exception with a message and an inner exception.</summary>
    public PythonInitializationException(string message, Exception innerException)
        : base(message, innerException)
    {
    }

    /// <summary>Creates the exception for an interpreter that asked to exit during start-up.</summary>
    public PythonInitializationException(string message, int exitCode)
        : base(message) => ExitCode = exitCode;

    /// <summary>The exit code, when start-up ended with a request to exit rather than an error.</summary>
    public int? ExitCode { get; }
}

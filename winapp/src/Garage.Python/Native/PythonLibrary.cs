using System.Reflection;
using System.Runtime.InteropServices;

namespace Garage.Python.Native;

/// <summary>
/// Loads the interpreter DLL the host chose and points every <see cref="CPython"/> import at it.
/// </summary>
/// <remarks>
/// The DLL is loaded by absolute path, so its own dependencies (<c>vcruntime140.dll</c>) resolve
/// from its folder and nothing on <c>PATH</c> can stand in for it. A process loads one interpreter
/// for its lifetime; asking for a different one afterwards is an error.
/// </remarks>
internal static class PythonLibrary
{
    private static readonly Lock Gate = new();
    private static nint _handle;
    private static string? _path;
    private static bool _resolverInstalled;

    /// <summary>The loaded interpreter DLL, or null before <see cref="Load"/>.</summary>
    internal static string? LoadedPath
    {
        get
        {
            lock (Gate)
            {
                return _path;
            }
        }
    }

    internal static void Load(string libraryPath)
    {
        string fullPath = Path.GetFullPath(libraryPath);
        lock (Gate)
        {
            if (_handle != 0)
            {
                if (!string.Equals(_path, fullPath, StringComparison.OrdinalIgnoreCase))
                {
                    throw new InvalidOperationException(
                        $"this process already loaded {_path}; it cannot switch to {fullPath}");
                }
                return;
            }
            if (!File.Exists(fullPath))
            {
                throw new FileNotFoundException("Python library not found", fullPath);
            }

            _handle = NativeLibrary.Load(fullPath);
            _path = fullPath;
            if (!_resolverInstalled)
            {
                NativeLibrary.SetDllImportResolver(typeof(PythonLibrary).Assembly, Resolve);
                _resolverInstalled = true;
            }
        }
    }

    private static nint Resolve(string libraryName, Assembly assembly, DllImportSearchPath? searchPath)
    {
        if (libraryName != CPython.Library)
        {
            return 0;
        }
        lock (Gate)
        {
            return _handle != 0
                ? _handle
                : throw new InvalidOperationException("the Python library is not loaded; call Python.Initialize first");
        }
    }
}

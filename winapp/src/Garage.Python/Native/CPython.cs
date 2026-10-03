using System.Runtime.InteropServices;

namespace Garage.Python.Native;

/// <summary>
/// The CPython C API functions this bridge calls, bound to <c>pythonXY.dll</c> through
/// source-generated P/Invoke. Every name is an exported function, not a macro (``Py_None`` is
/// <see cref="Py_GetConstantBorrowed"/>, ``Py_INCREF`` is <see cref="Py_IncRef"/>), so the bindings
/// hold on free-threaded builds too.
/// </summary>
/// <remarks>
/// <see cref="Library"/> is a placeholder name; <see cref="PythonLibrary"/> resolves it to the
/// interpreter the host chose before the first call. Pointers to <c>PyObject</c> are <see cref="nint"/>;
/// a function documented as returning a new reference must be paired with <see cref="Py_DecRef"/>.
/// </remarks>
internal static unsafe partial class CPython
{
    internal const string Library = "garage-python";

    // ---- PEP 741 initialization -----------------------------------------------------------

    [LibraryImport(Library)]
    internal static partial nint PyInitConfig_Create();

    [LibraryImport(Library)]
    internal static partial void PyInitConfig_Free(nint config);

    [LibraryImport(Library)]
    internal static partial int PyInitConfig_GetError(nint config, out nint errorMessage);

    [LibraryImport(Library)]
    internal static partial int PyInitConfig_GetExitCode(nint config, out int exitCode);

    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial int PyInitConfig_HasOption(nint config, string name);

    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial int PyInitConfig_GetInt(nint config, string name, out long value);

    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial int PyInitConfig_SetInt(nint config, string name, long value);

    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial int PyInitConfig_SetStr(nint config, string name, string value);

    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial int PyInitConfig_SetStrList(nint config, string name, nuint length, nint* items);

    [LibraryImport(Library)]
    internal static partial int Py_InitializeFromInitConfig(nint config);

    // ---- Lifecycle and threads ------------------------------------------------------------

    [LibraryImport(Library)]
    internal static partial int Py_IsInitialized();

    [LibraryImport(Library)]
    internal static partial int Py_FinalizeEx();

    [LibraryImport(Library)]
    internal static partial nint Py_GetVersion();

    [LibraryImport(Library)]
    internal static partial nint PyEval_SaveThread();

    [LibraryImport(Library)]
    internal static partial void PyEval_RestoreThread(nint threadState);

    [LibraryImport(Library)]
    internal static partial int PyGILState_Ensure();

    [LibraryImport(Library)]
    internal static partial void PyGILState_Release(int state);

    [LibraryImport(Library)]
    internal static partial int PyGILState_Check();

    // ---- Reference counting and constants -------------------------------------------------

    [LibraryImport(Library)]
    internal static partial void Py_IncRef(nint obj);

    [LibraryImport(Library)]
    internal static partial void Py_DecRef(nint obj);

    /// <summary>Borrowed reference to None, True, False, ... (<c>Py_CONSTANT_*</c>).</summary>
    [LibraryImport(Library)]
    internal static partial nint Py_GetConstantBorrowed(uint constantId);

    internal const uint Py_CONSTANT_NONE = 0;
    internal const uint Py_CONSTANT_FALSE = 1;
    internal const uint Py_CONSTANT_TRUE = 2;

    // ---- Objects --------------------------------------------------------------------------

    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial nint PyImport_ImportModule(string name);

    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial nint PyObject_GetAttrString(nint obj, string name);

    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial int PyObject_SetAttrString(nint obj, string name, nint value);

    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial int PyObject_HasAttrStringWithError(nint obj, string name);

    [LibraryImport(Library)]
    internal static partial nint PyObject_Call(nint callable, nint args, nint kwargs);

    [LibraryImport(Library)]
    internal static partial nint PyObject_Str(nint obj);

    [LibraryImport(Library)]
    internal static partial nint PyObject_Repr(nint obj);

    [LibraryImport(Library)]
    internal static partial int PyObject_IsTrue(nint obj);

    [LibraryImport(Library)]
    internal static partial int PyObject_IsInstance(nint obj, nint cls);

    [LibraryImport(Library)]
    internal static partial int PyObject_RichCompareBool(nint a, nint b, int op);

    internal const int Py_EQ = 2;

    [LibraryImport(Library)]
    internal static partial nint PyObject_Hash(nint obj);

    [LibraryImport(Library)]
    internal static partial nint PyObject_Type(nint obj);

    [LibraryImport(Library)]
    internal static partial nint PyObject_GetItem(nint obj, nint key);

    [LibraryImport(Library)]
    internal static partial int PyObject_SetItem(nint obj, nint key, nint value);

    [LibraryImport(Library)]
    internal static partial nint PyObject_Size(nint obj);

    [LibraryImport(Library)]
    internal static partial nint PyObject_GetIter(nint obj);

    [LibraryImport(Library)]
    internal static partial nint PyIter_Next(nint iterator);

    // ---- Numbers, strings, bytes ----------------------------------------------------------

    [LibraryImport(Library)]
    internal static partial nint PyLong_FromLongLong(long value);

    [LibraryImport(Library)]
    internal static partial nint PyLong_FromUnsignedLongLong(ulong value);

    [LibraryImport(Library)]
    internal static partial long PyLong_AsLongLong(nint obj);

    [LibraryImport(Library)]
    internal static partial nint PyFloat_FromDouble(double value);

    [LibraryImport(Library)]
    internal static partial double PyFloat_AsDouble(nint obj);

    [LibraryImport(Library)]
    internal static partial nint PyBool_FromLong(int value);

    [LibraryImport(Library)]
    internal static partial nint PyUnicode_FromStringAndSize(byte* utf8, nint size);

    [LibraryImport(Library)]
    internal static partial byte* PyUnicode_AsUTF8AndSize(nint obj, out nint size);

    [LibraryImport(Library)]
    internal static partial nint PyBytes_FromStringAndSize(byte* bytes, nint size);

    [LibraryImport(Library)]
    internal static partial int PyBytes_AsStringAndSize(nint obj, out byte* buffer, out nint length);

    // ---- Containers -----------------------------------------------------------------------

    [LibraryImport(Library)]
    internal static partial nint PyTuple_New(nint size);

    /// <summary>Steals the reference to <paramref name="item"/>, even on failure.</summary>
    [LibraryImport(Library)]
    internal static partial int PyTuple_SetItem(nint tuple, nint position, nint item);

    [LibraryImport(Library)]
    internal static partial nint PyList_New(nint size);

    [LibraryImport(Library)]
    internal static partial int PyList_Append(nint list, nint item);

    [LibraryImport(Library)]
    internal static partial nint PyDict_New();

    [LibraryImport(Library)]
    internal static partial int PyDict_SetItem(nint dict, nint key, nint value);

    // ---- Errors ---------------------------------------------------------------------------

    [LibraryImport(Library)]
    internal static partial nint PyErr_Occurred();

    [LibraryImport(Library)]
    internal static partial nint PyErr_GetRaisedException();

    [LibraryImport(Library)]
    internal static partial void PyErr_Clear();
}

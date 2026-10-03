using Garage.Python.Native;

namespace Garage.Python;

/// <summary>
/// A Python exception raised into C#: what PythonKit's <c>.throwing</c> calls surface as
/// <c>PythonError.exception</c>.
/// </summary>
public sealed class PythonException : Exception
{
    /// <summary>Creates an exception with a message and no Python details.</summary>
    public PythonException(string message)
        : this(message, "Exception", message, null, null)
    {
    }

    /// <summary>Creates an exception with a message and an inner exception, and no Python details.</summary>
    public PythonException(string message, Exception innerException)
        : base(message, innerException)
    {
        PythonType = "Exception";
        PythonMessage = message;
    }

    /// <summary>Creates an exception with no message.</summary>
    public PythonException()
        : this("a Python exception was raised")
    {
    }

    private PythonException(string message, string pythonType, string pythonMessage, string? traceback, PythonObject? value)
        : base(message)
    {
        PythonType = pythonType;
        PythonMessage = pythonMessage;
        PythonTraceback = traceback;
        Value = value;
    }

    /// <summary>The exception's qualified type name, e.g. <c>ValueError</c> or <c>garage_rag.inference.bridge.BridgeError</c>.</summary>
    public string PythonType { get; }

    /// <summary><c>str(exception)</c>.</summary>
    public string PythonMessage { get; }

    /// <summary>The formatted traceback, as <c>traceback.format_exception</c> gives it; null when it could not be formatted.</summary>
    public string? PythonTraceback { get; }

    /// <summary>The exception object itself, for callers that need its attributes.</summary>
    public PythonObject? Value { get; }

    /// <summary>
    /// Takes the exception Python has raised (clearing the error indicator) and returns it as a
    /// <see cref="PythonException"/>. Call with the GIL held, right after a C API call failed.
    /// </summary>
    internal static PythonException FromRaised(string context)
    {
        nint raised = CPython.PyErr_GetRaisedException();
        if (raised == 0)
        {
            return new PythonException($"{context} failed, but Python reported no exception");
        }

        var value = PythonObject.Steal(raised);
        string type = Describe(() => QualifiedTypeName(value), "Exception");
        string message = Describe(value.ToString, "");
        string? traceback = Describe(() => FormatTraceback(value), null);
        string summary = message.Length == 0 ? type : $"{type}: {message}";
        return new PythonException(summary, type, message, traceback, value);
    }

    private static string QualifiedTypeName(PythonObject exception)
    {
        using PythonObject type = exception.GetAttr("__class__");
        string name = type.GetAttr("__qualname__").ToString();
        string module = type.GetAttr("__module__").ToString();
        return module is "builtins" or "" ? name : $"{module}.{name}";
    }

    private static string FormatTraceback(PythonObject exception)
    {
        using PythonObject traceback = Python.Import("traceback");
        using PythonObject lines = traceback.Invoke("format_exception", exception);
        return string.Concat(lines.Select(line => line.ToString()));
    }

    // Formatting an exception runs Python code, which can itself fail; never let that hide the original.
    private static T Describe<T>(Func<T> describe, T fallback)
    {
        try
        {
            return describe();
        }
        catch (PythonException)
        {
            return fallback;
        }
    }
}

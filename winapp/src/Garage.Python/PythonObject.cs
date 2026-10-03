using System.Collections;
using System.Dynamic;
using System.Text;
using Garage.Python.Native;

namespace Garage.Python;

/// <summary>
/// A strong reference to a Python object: the C# counterpart of PythonKit's <c>PythonObject</c>.
/// </summary>
/// <remarks>
/// <para>
/// Used through <c>dynamic</c> it reads like Python, keyword arguments included:
/// <code>
/// dynamic server = Python.Import("garage_rag.service.server");
/// dynamic created = server.create_grpc_server(host: "127.0.0.1", port: 50051);
/// </code>
/// Static members of this class win over Python attributes of the same name, so a Python
/// attribute called <c>Call</c> or <c>ToString</c> is reached with <see cref="GetAttr"/>. Every
/// public member is PascalCase for that reason.
/// </para>
/// <para>
/// Every operation takes the GIL itself (re-entrantly), so a <see cref="PythonObject"/> may be
/// used from any thread. <see cref="Dispose"/> releases the reference at once; an object left to
/// the garbage collector is released the next time any thread takes the GIL, since a finalizer
/// must never block waiting for it.
/// </para>
/// </remarks>
public sealed class PythonObject : DynamicObject, IDisposable, IEnumerable<PythonObject>
{
    private nint _handle;

    private PythonObject(nint handle) => _handle = handle;

    /// <summary>Queues the reference for release; see the class remarks.</summary>
    ~PythonObject() => Python.DeferDecRef(_handle);

    /// <summary>The raw <c>PyObject*</c>; valid while this object is alive and not disposed.</summary>
    internal nint Handle => _handle != 0 ? _handle : throw new ObjectDisposedException(nameof(PythonObject));

    /// <summary>Whether this is Python's <c>None</c>.</summary>
    public bool IsNone
    {
        get
        {
            using GilScope gil = Python.Gil();
            return Handle == CPython.Py_GetConstantBorrowed(CPython.Py_CONSTANT_NONE);
        }
    }

    /// <summary>The qualified name of the object's type, e.g. <c>str</c> or <c>OrderedDict</c>.</summary>
    public string TypeName
    {
        get
        {
            using GilScope gil = Python.Gil();
            using PythonObject type = Checked(CPython.PyObject_Type(Handle), "type()");
            return type.GetAttr("__qualname__").ToString();
        }
    }

    // ---- Construction ---------------------------------------------------------------------

    /// <summary>Takes ownership of a new reference.</summary>
    internal static PythonObject Steal(nint handle) =>
        handle != 0 ? new PythonObject(handle) : throw new ArgumentNullException(nameof(handle));

    /// <summary>Wraps a borrowed reference, taking a reference of its own. Call with the GIL held.</summary>
    internal static PythonObject Borrow(nint handle)
    {
        ArgumentOutOfRangeException.ThrowIfZero(handle);
        CPython.Py_IncRef(handle);
        return new PythonObject(handle);
    }

    /// <summary>
    /// Takes ownership of <paramref name="handle"/>, the result of a C API call that returns a new
    /// reference, or raises the pending Python exception when it is null. Call with the GIL held.
    /// </summary>
    internal static PythonObject Checked(nint handle, string context) =>
        handle != 0 ? new PythonObject(handle) : throw PythonException.FromRaised(context);

    /// <summary>Converts a .NET value to a Python object; see <see cref="Python.ToPython"/>.</summary>
    public static PythonObject From(object? value)
    {
        using GilScope gil = Python.Gil();
        return Steal(NewReference(value));
    }

    /// <summary>Another reference to the same Python object, disposed independently.</summary>
    public PythonObject Clone()
    {
        using GilScope gil = Python.Gil();
        return Borrow(Handle);
    }

    // ---- Attributes, calls, items ---------------------------------------------------------

    /// <summary><c>getattr(self, name)</c>.</summary>
    public PythonObject GetAttr(string name)
    {
        using GilScope gil = Python.Gil();
        return Checked(CPython.PyObject_GetAttrString(Handle, name), $"getattr(..., '{name}')");
    }

    /// <summary><c>setattr(self, name, value)</c>.</summary>
    public void SetAttr(string name, object? value)
    {
        using GilScope gil = Python.Gil();
        nint converted = NewReference(value);
        try
        {
            Check(CPython.PyObject_SetAttrString(Handle, name, converted), $"setattr(..., '{name}')");
        }
        finally
        {
            CPython.Py_DecRef(converted);
        }
    }

    /// <summary><c>hasattr(self, name)</c>.</summary>
    public bool HasAttr(string name)
    {
        using GilScope gil = Python.Gil();
        int result = CPython.PyObject_HasAttrStringWithError(Handle, name);
        return result >= 0 ? result == 1 : throw PythonException.FromRaised($"hasattr(..., '{name}')");
    }

    /// <summary>Calls this object with positional arguments.</summary>
    public PythonObject Call(params object?[] args) => Call(args, null);

    /// <summary>Calls this object with positional and keyword arguments.</summary>
    public PythonObject Call(IReadOnlyList<object?> args, IEnumerable<KeyValuePair<string, object?>>? kwargs)
    {
        ArgumentNullException.ThrowIfNull(args);
        using GilScope gil = Python.Gil();
        nint tuple = BuildTuple(args);
        nint dict = 0;
        try
        {
            dict = kwargs is null ? 0 : BuildKwargs(kwargs);
            return Checked(CPython.PyObject_Call(Handle, tuple, dict), "call");
        }
        finally
        {
            CPython.Py_DecRef(tuple);
            if (dict != 0)
            {
                CPython.Py_DecRef(dict);
            }
        }
    }

    /// <summary>Calls the method <paramref name="name"/> with positional arguments.</summary>
    public PythonObject Invoke(string name, params object?[] args)
    {
        using PythonObject method = GetAttr(name);
        return method.Call(args);
    }

    /// <summary>Calls the method <paramref name="name"/> with positional and keyword arguments.</summary>
    public PythonObject Invoke(string name, IReadOnlyList<object?> args, IEnumerable<KeyValuePair<string, object?>>? kwargs)
    {
        using PythonObject method = GetAttr(name);
        return method.Call(args, kwargs);
    }

    /// <summary><c>self[key]</c>.</summary>
    public PythonObject this[object? key]
    {
        get
        {
            using GilScope gil = Python.Gil();
            nint k = NewReference(key);
            try
            {
                return Checked(CPython.PyObject_GetItem(Handle, k), "getitem");
            }
            finally
            {
                CPython.Py_DecRef(k);
            }
        }
    }

    /// <summary><c>self[key] = value</c>.</summary>
    public void SetItem(object? key, object? value)
    {
        using GilScope gil = Python.Gil();
        nint k = NewReference(key);
        nint v = 0;
        try
        {
            v = NewReference(value);
            Check(CPython.PyObject_SetItem(Handle, k, v), "setitem");
        }
        finally
        {
            CPython.Py_DecRef(k);
            if (v != 0)
            {
                CPython.Py_DecRef(v);
            }
        }
    }

    /// <summary>A Python <c>tuple</c> of <paramref name="items"/>, each converted as <see cref="From"/> does.</summary>
    public static PythonObject Tuple(params object?[] items)
    {
        ArgumentNullException.ThrowIfNull(items);
        using GilScope gil = Python.Gil();
        return Steal(BuildTuple(items));
    }

    /// <summary><c>len(self)</c>.</summary>
    public long Length
    {
        get
        {
            using GilScope gil = Python.Gil();
            nint size = CPython.PyObject_Size(Handle);
            return size >= 0 ? size : throw PythonException.FromRaised("len()");
        }
    }

    /// <summary><c>self == other</c>, by Python's rules.</summary>
    public bool PythonEquals(object? other)
    {
        using GilScope gil = Python.Gil();
        nint o = NewReference(other);
        try
        {
            int result = CPython.PyObject_RichCompareBool(Handle, o, CPython.Py_EQ);
            return result >= 0 ? result == 1 : throw PythonException.FromRaised("==");
        }
        finally
        {
            CPython.Py_DecRef(o);
        }
    }

    /// <summary><c>bool(self)</c>.</summary>
    public bool IsTrue()
    {
        using GilScope gil = Python.Gil();
        int result = CPython.PyObject_IsTrue(Handle);
        return result >= 0 ? result == 1 : throw PythonException.FromRaised("bool()");
    }

    /// <summary><c>repr(self)</c>.</summary>
    public string Repr()
    {
        using GilScope gil = Python.Gil();
        using PythonObject repr = Checked(CPython.PyObject_Repr(Handle), "repr()");
        return repr.As<string>();
    }

    /// <summary><c>str(self)</c>; when that raises, a placeholder naming the failure.</summary>
    public override string ToString()
    {
        if (_handle == 0)
        {
            return "<disposed PythonObject>";
        }
        try
        {
            using GilScope gil = Python.Gil();
            using PythonObject str = Checked(CPython.PyObject_Str(Handle), "str()");
            return str.As<string>();
        }
        catch (PythonException ex)
        {
            return $"<Python object: str() raised {ex.PythonType}>";
        }
    }

    // ---- Conversion to .NET ---------------------------------------------------------------

    /// <summary>
    /// Converts to a .NET value. Supported: <see cref="string"/> (a <c>str</c>), <see cref="long"/>,
    /// <see cref="int"/>, <see cref="nint"/> (an <c>int</c>), <see cref="double"/> (anything
    /// <c>float()</c> accepts), <see cref="bool"/> (truthiness), <c>byte[]</c> (a
    /// <c>bytes</c>), and <see cref="PythonObject"/> (a new reference).
    /// </summary>
    /// <exception cref="PythonException">The object is not of a kind the target type accepts.</exception>
    public T As<T>() => (T)As(typeof(T));

    private object As(Type type)
    {
        using GilScope gil = Python.Gil();
        if (type == typeof(string))
        {
            return AsString();
        }
        if (type == typeof(long))
        {
            return AsInt64();
        }
        if (type == typeof(int))
        {
            return checked((int)AsInt64());
        }
        if (type == typeof(nint))
        {
            return checked((nint)AsInt64());
        }
        if (type == typeof(double))
        {
            double value = CPython.PyFloat_AsDouble(Handle);
            return value == -1.0 && CPython.PyErr_Occurred() != 0 ? throw PythonException.FromRaised("float()") : value;
        }
        if (type == typeof(bool))
        {
            return IsTrue();
        }
        if (type == typeof(byte[]))
        {
            return AsBytes();
        }
        if (type == typeof(PythonObject) || type == typeof(object))
        {
            return Clone();
        }
        throw new InvalidCastException($"cannot convert a Python object to {type}");
    }

    private unsafe string AsString()
    {
        byte* utf8 = CPython.PyUnicode_AsUTF8AndSize(Handle, out nint size);
        return utf8 != null
            ? Encoding.UTF8.GetString(utf8, checked((int)size))
            : throw PythonException.FromRaised("str conversion");
    }

    private long AsInt64()
    {
        long value = CPython.PyLong_AsLongLong(Handle);
        return value == -1 && CPython.PyErr_Occurred() != 0 ? throw PythonException.FromRaised("int conversion") : value;
    }

    private unsafe byte[] AsBytes()
    {
        Check(CPython.PyBytes_AsStringAndSize(Handle, out byte* buffer, out nint length), "bytes conversion");
        return new ReadOnlySpan<byte>(buffer, checked((int)length)).ToArray();
    }

    // ---- Iteration ------------------------------------------------------------------------

    /// <summary>Iterates <c>iter(self)</c>, yielding a new reference per item.</summary>
    public IEnumerator<PythonObject> GetEnumerator()
    {
        PythonObject iterator;
        using (Python.Gil())
        {
            iterator = Checked(CPython.PyObject_GetIter(Handle), "iter()");
        }
        using (iterator)
        {
            while (true)
            {
                PythonObject? item;
                using (Python.Gil())
                {
                    nint next = CPython.PyIter_Next(iterator.Handle);
                    if (next == 0)
                    {
                        if (CPython.PyErr_Occurred() != 0)
                        {
                            throw PythonException.FromRaised("next()");
                        }
                        yield break;
                    }
                    item = Steal(next);
                }
                yield return item;
            }
        }
    }

    IEnumerator IEnumerable.GetEnumerator() => GetEnumerator();

    // ---- dynamic --------------------------------------------------------------------------

    /// <inheritdoc/>
    public override bool TryGetMember(GetMemberBinder binder, out object? result)
    {
        result = GetAttr(binder.Name);
        return true;
    }

    /// <inheritdoc/>
    public override bool TrySetMember(SetMemberBinder binder, object? value)
    {
        SetAttr(binder.Name, value);
        return true;
    }

    /// <inheritdoc/>
    public override bool TryInvokeMember(InvokeMemberBinder binder, object?[]? args, out object? result)
    {
        using PythonObject method = GetAttr(binder.Name);
        result = method.CallDynamic(binder.CallInfo, args ?? []);
        return true;
    }

    /// <inheritdoc/>
    public override bool TryInvoke(InvokeBinder binder, object?[]? args, out object? result)
    {
        result = CallDynamic(binder.CallInfo, args ?? []);
        return true;
    }

    /// <inheritdoc/>
    public override bool TryGetIndex(GetIndexBinder binder, object?[] indexes, out object? result)
    {
        ArgumentNullException.ThrowIfNull(indexes);
        result = indexes.Length == 1 ? this[indexes[0]] : this[Tuple(indexes)];
        return true;
    }

    /// <inheritdoc/>
    public override bool TrySetIndex(SetIndexBinder binder, object?[] indexes, object? value)
    {
        ArgumentNullException.ThrowIfNull(indexes);
        SetItem(indexes.Length == 1 ? indexes[0] : Tuple(indexes), value);
        return true;
    }

    /// <inheritdoc/>
    public override bool TryConvert(ConvertBinder binder, out object? result)
    {
        ArgumentNullException.ThrowIfNull(binder);
        result = As(binder.Type);
        return true;
    }

    // C# puts named arguments last; CallInfo names them.
    private PythonObject CallDynamic(CallInfo callInfo, object?[] args)
    {
        int named = callInfo.ArgumentNames.Count;
        int positional = args.Length - named;
        List<KeyValuePair<string, object?>> kwargs = [];
        for (int i = 0; i < named; i++)
        {
            kwargs.Add(new(callInfo.ArgumentNames[i], args[positional + i]));
        }
        return Call(args[..positional], named == 0 ? null : kwargs);
    }

    // ---- Lifetime -------------------------------------------------------------------------

    /// <summary>Releases the reference now.</summary>
    public void Dispose()
    {
        nint handle = Interlocked.Exchange(ref _handle, 0);
        if (handle != 0 && Python.IsRunning)
        {
            using GilScope gil = Python.Gil();
            CPython.Py_DecRef(handle);
        }
        GC.SuppressFinalize(this);
    }

    // ---- Conversion from .NET (GIL held) --------------------------------------------------

    /// <summary>
    /// A new reference for <paramref name="value"/>: <c>None</c> for null, <c>bool</c>,
    /// <c>int</c> (every integer type, <see cref="nint"/> and enums), <c>float</c>, <c>str</c>
    /// (<see cref="string"/>, <see cref="char"/>), <c>bytes</c> (<c>byte[]</c>,
    /// <see cref="ReadOnlyMemory{T}"/> of bytes), <c>dict</c> (<see cref="IDictionary"/>),
    /// <c>list</c> (any other <see cref="IEnumerable"/>), and a <see cref="PythonObject"/> as itself.
    /// </summary>
    internal static unsafe nint NewReference(object? value)
    {
        switch (value)
        {
            case null:
                return Borrowed(CPython.Py_GetConstantBorrowed(CPython.Py_CONSTANT_NONE));
            case PythonObject obj:
                return Borrowed(obj.Handle);
            case bool b:
                return CPython.PyBool_FromLong(b ? 1 : 0);
            case string s:
                return FromUtf8(Encoding.UTF8.GetBytes(s), "str");
            case char c:
                return FromUtf8(Encoding.UTF8.GetBytes(c.ToString()), "str");
            case byte[] bytes:
                return FromBytes(bytes, "bytes");
            case ReadOnlyMemory<byte> memory:
                return FromBytes(memory.Span, "bytes");
            case Enum e:
                return NewOrThrow(CPython.PyLong_FromLongLong(Convert.ToInt64(e, System.Globalization.CultureInfo.InvariantCulture)), "int");
            case ulong u:
                return NewOrThrow(CPython.PyLong_FromUnsignedLongLong(u), "int");
            case nuint nu:
                return NewOrThrow(CPython.PyLong_FromUnsignedLongLong(nu), "int");
            case nint n:
                return NewOrThrow(CPython.PyLong_FromLongLong(n), "int");
            case sbyte or byte or short or ushort or int or uint or long:
                return NewOrThrow(CPython.PyLong_FromLongLong(Convert.ToInt64(value, System.Globalization.CultureInfo.InvariantCulture)), "int");
            case float or double:
                return NewOrThrow(CPython.PyFloat_FromDouble(Convert.ToDouble(value, System.Globalization.CultureInfo.InvariantCulture)), "float");
            case IDictionary dictionary:
                return BuildDict(dictionary);
            case IEnumerable sequence:
                return BuildList(sequence);
            default:
                throw new ArgumentException($"cannot convert {value.GetType()} to a Python object", nameof(value));
        }
    }

    private static nint Borrowed(nint handle)
    {
        CPython.Py_IncRef(handle);
        return handle;
    }

    private static unsafe nint FromUtf8(ReadOnlySpan<byte> utf8, string context)
    {
        fixed (byte* p = utf8)
        {
            return NewOrThrow(CPython.PyUnicode_FromStringAndSize(p, utf8.Length), context);
        }
    }

    private static unsafe nint FromBytes(ReadOnlySpan<byte> bytes, string context)
    {
        fixed (byte* p = bytes)
        {
            return NewOrThrow(CPython.PyBytes_FromStringAndSize(p, bytes.Length), context);
        }
    }

    private static nint BuildTuple(IReadOnlyList<object?> items)
    {
        nint tuple = NewOrThrow(CPython.PyTuple_New(items.Count), "tuple");
        try
        {
            for (int i = 0; i < items.Count; i++)
            {
                // PyTuple_SetItem steals the item's reference, even when it fails.
                Check(CPython.PyTuple_SetItem(tuple, i, NewReference(items[i])), "tuple item");
            }
            return tuple;
        }
        catch
        {
            CPython.Py_DecRef(tuple);
            throw;
        }
    }

    private static nint BuildList(IEnumerable items)
    {
        nint list = NewOrThrow(CPython.PyList_New(0), "list");
        try
        {
            foreach (object? item in items)
            {
                nint converted = NewReference(item);
                try
                {
                    Check(CPython.PyList_Append(list, converted), "list append");
                }
                finally
                {
                    CPython.Py_DecRef(converted);
                }
            }
            return list;
        }
        catch
        {
            CPython.Py_DecRef(list);
            throw;
        }
    }

    private static nint BuildDict(IDictionary entries)
    {
        nint dict = NewOrThrow(CPython.PyDict_New(), "dict");
        try
        {
            foreach (DictionaryEntry entry in entries)
            {
                SetDictItem(dict, entry.Key, entry.Value);
            }
            return dict;
        }
        catch
        {
            CPython.Py_DecRef(dict);
            throw;
        }
    }

    private static nint BuildKwargs(IEnumerable<KeyValuePair<string, object?>> kwargs)
    {
        nint dict = NewOrThrow(CPython.PyDict_New(), "dict");
        try
        {
            foreach (KeyValuePair<string, object?> pair in kwargs)
            {
                SetDictItem(dict, pair.Key, pair.Value);
            }
            return dict;
        }
        catch
        {
            CPython.Py_DecRef(dict);
            throw;
        }
    }

    private static void SetDictItem(nint dict, object? key, object? value)
    {
        nint k = NewReference(key);
        nint v = 0;
        try
        {
            v = NewReference(value);
            Check(CPython.PyDict_SetItem(dict, k, v), "dict item");
        }
        finally
        {
            CPython.Py_DecRef(k);
            if (v != 0)
            {
                CPython.Py_DecRef(v);
            }
        }
    }

    /// <summary>Returns a new reference, or raises the pending Python exception when it is null.</summary>
    internal static nint NewOrThrow(nint handle, string context) =>
        handle != 0 ? handle : throw PythonException.FromRaised(context);

    /// <summary>Raises the pending Python exception when a C API call returned -1.</summary>
    internal static void Check(int status, string context)
    {
        if (status < 0)
        {
            throw PythonException.FromRaised(context);
        }
    }
}

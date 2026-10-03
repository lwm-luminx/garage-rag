using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace Garage.Python.Tests;

public sealed class ObjectTests(PythonFixture fixture)
{
    [Fact]
    public void Calls_with_positional_arguments_through_dynamic()
    {
        fixture.RequirePython();
        dynamic math = Python.Import("math");
        Assert.Equal(4.0, (double)math.sqrt(16.0));
    }

    [Fact]
    public void Calls_with_keyword_arguments_through_dynamic()
    {
        fixture.RequirePython();
        dynamic builtins = Python.Import("builtins");
        Assert.Equal(255L, (long)builtins.@int("ff", @base: 16));
    }

    [Fact]
    public void Calls_with_keyword_arguments_through_the_explicit_api()
    {
        fixture.RequirePython();
        using PythonObject builtins = Python.Import("builtins");
        using PythonObject sorted = builtins.Invoke("sorted", [new[] { 3, 1, 2 }], [new("reverse", true)]);
        Assert.Equal([3L, 2L, 1L], sorted.Select(item => item.As<long>()));
    }

    public static TheoryData<object?> RoundTrips => new()
    {
        "plain",
        "héllo — ✓ 🐍",
        "",
        long.MaxValue,
        long.MinValue,
        -1L,
        0L,
        0.5,
        -1.0,
        true,
        false,
    };

    [Theory]
    [MemberData(nameof(RoundTrips))]
    public void Values_round_trip(object? value)
    {
        fixture.RequirePython();
        using PythonObject converted = PythonObject.From(value);
        object back = value switch
        {
            string => converted.As<string>(),
            long => converted.As<long>(),
            double => converted.As<double>(),
            bool => converted.As<bool>(),
            _ => throw new InvalidOperationException(),
        };
        Assert.Equal(value, back);
    }

    [Fact]
    public void Bytes_round_trip_including_nul()
    {
        fixture.RequirePython();
        byte[] data = [0, 1, 2, 0, 255];
        using PythonObject converted = PythonObject.From(data);
        Assert.Equal("bytes", converted.TypeName);
        Assert.Equal(data, converted.As<byte[]>());
    }

    [Fact]
    public void Null_is_none()
    {
        fixture.RequirePython();
        using PythonObject none = PythonObject.From(null);
        Assert.True(none.IsNone);
        using PythonObject pythonNone = Python.None;
        Assert.True(pythonNone.PythonEquals(none));
    }

    [Fact]
    public void Collections_convert_to_lists_and_dicts()
    {
        fixture.RequirePython();
        using PythonObject list = PythonObject.From(new List<object?> { 1, "two", null });
        Assert.Equal("list", list.TypeName);
        Assert.Equal(3, list.Length);

        using PythonObject dict = PythonObject.From(new Dictionary<string, object?> { ["a"] = 1, ["b"] = new[] { 2, 3 } });
        Assert.Equal("dict", dict.TypeName);
        Assert.Equal(1L, dict["a"].As<long>());
        Assert.Equal(2, dict["b"].Length);
    }

    [Fact]
    public void Multiple_indexes_become_a_tuple_key()
    {
        fixture.RequirePython();
        dynamic table = Python.Evaluate("{(1, 2): 'x'}");
        Assert.Equal("x", (string)table[1, 2]);
        table[3, 4] = "y";
        using PythonObject lookedUp = ((PythonObject)table)[PythonObject.Tuple(3, 4)];
        Assert.Equal("y", lookedUp.As<string>());
    }

    [Fact]
    public void Iterates_python_iterables()
    {
        fixture.RequirePython();
        using PythonObject range = Python.Evaluate("range(5)");
        Assert.Equal([0L, 1L, 2L, 3L, 4L], range.Select(item => item.As<long>()));
    }

    [Fact]
    public void Gets_sets_and_tests_attributes()
    {
        fixture.RequirePython();
        using PythonObject ns = Python.Import("types").Invoke("SimpleNamespace");
        Assert.False(ns.HasAttr("slug"));
        ns.SetAttr("slug", "nomic-embed-text");
        Assert.True(ns.HasAttr("slug"));
        dynamic d = ns;
        Assert.Equal("nomic-embed-text", (string)d.slug);
        d.dims = 768;
        Assert.Equal(768, (int)d.dims);
    }

    [Fact]
    public void Python_exceptions_surface_with_type_message_and_traceback()
    {
        fixture.RequirePython();
        dynamic builtins = Python.Import("builtins");
        PythonException error = Assert.Throws<PythonException>(() => (object)builtins.@int("not a number"));
        Assert.Equal("ValueError", error.PythonType);
        Assert.Contains("invalid literal", error.PythonMessage, StringComparison.Ordinal);
        Assert.Contains("ValueError", error.PythonTraceback, StringComparison.Ordinal);
        Assert.NotNull(error.Value);
    }

    [Fact]
    public void Exceptions_from_modules_carry_their_qualified_type()
    {
        fixture.RequirePython();
        using PythonObject json = Python.Import("json");
        PythonException error = Assert.Throws<PythonException>(() => json.Invoke("loads", "{").Dispose());
        Assert.Equal("json.decoder.JSONDecodeError", error.PythonType);
    }

    [Fact]
    public void A_missing_attribute_is_an_attribute_error()
    {
        fixture.RequirePython();
        dynamic math = Python.Import("math");
        PythonException error = Assert.Throws<PythonException>(() => (object)math.no_such_function);
        Assert.Equal("AttributeError", error.PythonType);
    }

    [Fact]
    public void A_failing_str_does_not_throw_from_ToString()
    {
        fixture.RequirePython();
        using PythonObject globals = Python.Exec("""
            class Broken:
                def __str__(self):
                    raise RuntimeError("no")
            value = Broken()
            """);
        Assert.Equal("<Python object: str() raised RuntimeError>", globals["value"].ToString());
    }

    [Fact]
    public void Dispose_releases_the_reference()
    {
        fixture.RequirePython();
        using PythonObject sys = Python.Import("sys");
        using PythonObject list = Python.Evaluate("[]");
        long baseline = RefCount(sys, list);
        PythonObject clone = list.Clone();
        Assert.Equal(baseline + 1, RefCount(sys, list));
        clone.Dispose();
        Assert.Equal(baseline, RefCount(sys, list));
    }

    [Fact]
    public void Objects_left_to_the_collector_are_released_on_the_next_gil()
    {
        fixture.RequirePython();
        using PythonObject weakref = WeakRefToAbandonedObject();
        for (int attempt = 0; attempt < 10; attempt++)
        {
            GC.Collect();
            GC.WaitForPendingFinalizers();
            using PythonObject referent = weakref.Call();  // takes the GIL first, draining the queue
            if (referent.IsNone)
            {
                return;
            }
        }
        Assert.Fail("the abandoned object was never released");
    }

    [Fact]
    public unsafe void Python_calls_a_host_function_through_ctypes()
    {
        fixture.RequirePython();
        using PythonObject globals = Python.Exec(
            """
            import ctypes
            twice = ctypes.CFUNCTYPE(ctypes.c_int64, ctypes.c_int64)(address)
            result = twice(21)
            """,
            new Dictionary<string, object?> { ["address"] = (nint)(delegate* unmanaged[Cdecl]<long, long>)&Twice });
        Assert.Equal(42L, globals["result"].As<long>());
    }

    [Fact]
    public unsafe void A_host_callback_can_call_back_into_python()
    {
        fixture.RequirePython();
        // ctypes releases the GIL around the call, so the callback must take it again itself.
        using PythonObject globals = Python.Exec(
            """
            import ctypes
            answer = ctypes.CFUNCTYPE(ctypes.c_int64)(address)
            result = answer()
            """,
            new Dictionary<string, object?> { ["address"] = (nint)(delegate* unmanaged[Cdecl]<long>)&EvaluateInPython });
        Assert.Equal(42L, globals["result"].As<long>());
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static long Twice(long value) => value * 2;

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static long EvaluateInPython()
    {
        using PythonObject value = Python.Evaluate("6 * 7");
        return value.As<long>();
    }

    private static long RefCount(PythonObject sys, PythonObject obj)
    {
        using PythonObject count = sys.Invoke("getrefcount", obj);
        return count.As<long>();
    }

    // Separate and not inlined, so nothing on the test's stack keeps the wrapper alive.
    [MethodImpl(MethodImplOptions.NoInlining)]
    private static PythonObject WeakRefToAbandonedObject()
    {
        using PythonObject globals = Python.Exec("class Referent: pass");
        PythonObject abandoned = globals["Referent"].Call();
        using PythonObject weakref = Python.Import("weakref");
        return weakref.Invoke("ref", abandoned);
    }
}

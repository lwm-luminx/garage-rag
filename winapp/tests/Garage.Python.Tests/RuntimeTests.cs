namespace Garage.Python.Tests;

public sealed class RuntimeTests(PythonFixture fixture)
{
    [Fact]
    public void Starts_isolated_in_utf8_mode_without_bytecode()
    {
        fixture.RequirePython();
        dynamic sys = Python.Import("sys");
        Assert.Equal(1L, (long)sys.flags.isolated);
        Assert.Equal(1L, (long)sys.flags.utf8_mode);
        Assert.True((bool)sys.flags.safe_path);
        Assert.True((bool)sys.dont_write_bytecode);
        Assert.Equal(1L, (long)sys.flags.no_user_site);
    }

    [Fact]
    public void Sys_path_is_the_search_paths_plus_only_the_bundles_pth_entries()
    {
        fixture.RequirePython();
        PythonEnvironment environment = fixture.Environment_!;
        using PythonObject sys = Python.Import("sys");
        List<string> path = [.. sys.GetAttr("path").Select(entry => entry.As<string>())];

        Assert.True(sys.GetAttr("modules").Invoke("__contains__", "site").IsTrue());
        Assert.Equal(environment.SearchPaths, path.Take(environment.SearchPaths.Count), StringComparer.OrdinalIgnoreCase);
        // Anything after them came from a .pth file in the bundle's site-packages (pywin32's
        // win32, win32\lib, pythonwin), never from the interpreter's own site directories.
        Assert.All(path.Skip(environment.SearchPaths.Count), entry =>
            Assert.StartsWith(environment.SitePackagesDir + Path.DirectorySeparatorChar, entry, StringComparison.OrdinalIgnoreCase));
        Assert.DoesNotContain(environment.Home, path, StringComparer.OrdinalIgnoreCase);
    }

    [Fact]
    public void Environment_variables_do_not_reach_the_interpreter()
    {
        fixture.RequirePython();
        // PYTHONPATH, PYTHONHOME, ... are read only when use_environment is on; isolation turns it off.
        dynamic sys = Python.Import("sys");
        Assert.Equal(1L, (long)sys.flags.ignore_environment);
    }

    [Fact]
    public void Reports_the_3_14_runtime()
    {
        fixture.RequirePython();
        Assert.StartsWith("3.14", Python.Version, StringComparison.Ordinal);
    }

    [Fact]
    public void Initializing_twice_is_refused()
    {
        fixture.RequirePython();
        Assert.Throws<InvalidOperationException>(() => Python.Initialize(fixture.Environment_!));
    }

    [Fact]
    public void Python_threads_run_while_no_host_thread_holds_the_gil()
    {
        fixture.RequirePython();
        // If start-up had kept the GIL on the initializing thread, this Python thread could
        // never run and the event would never be set.
        using PythonObject globals = Python.Exec("""
            import threading
            done = threading.Event()
            threading.Thread(target=done.set).start()
            """);
        using PythonObject done = globals["done"];
        bool set = false;
        for (int attempt = 0; attempt < 500 && !set; attempt++)
        {
            using PythonObject result = done.Invoke("is_set");
            set = result.IsTrue();
            if (!set)
            {
                Thread.Sleep(10);
            }
        }
        Assert.True(set);
    }

    [Fact]
    public void Many_host_threads_call_in_concurrently()
    {
        fixture.RequirePython();
        long[] results = new long[64];
        Parallel.For(0, results.Length, i =>
        {
            using PythonObject math = Python.Import("math");
            using PythonObject value = math.Invoke("factorial", 20);
            results[i] = value.As<long>();
        });
        Assert.All(results, value => Assert.Equal(2_432_902_008_176_640_000L, value));
    }

    [Fact]
    public void Allow_threads_lets_python_run_while_the_host_waits()
    {
        fixture.RequirePython();
        using PythonObject globals = Python.Exec("""
            import threading
            ready = threading.Event()
            def work():
                ready.set()
            """);
        using GilScope gil = Python.Gil();
        using (PythonObject thread = Python.Import("threading").Invoke(
            "Thread", [], [new("target", globals["work"])]))
        {
            thread.Invoke("start").Dispose();
            using (Python.AllowThreads())
            {
                // Holding the GIL here would stall the thread; released, it finishes.
                Thread.Sleep(50);
            }
            thread.Invoke("join").Dispose();
        }
        using PythonObject ready = globals["ready"].Invoke("is_set");
        Assert.True(ready.IsTrue());
    }

    [Fact]
    public void Allow_threads_without_the_gil_is_an_error()
    {
        fixture.RequirePython();
        Exception? error = null;
        Thread thread = new(() => error = Record.Exception(() =>
        {
            using AllowThreadsScope scope = Python.AllowThreads();
        }));
        thread.Start();
        thread.Join();
        Assert.IsType<InvalidOperationException>(error);
    }
}

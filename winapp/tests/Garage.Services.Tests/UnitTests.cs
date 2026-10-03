using System.Diagnostics;
using Garage.App.Core.Services;

namespace Garage.Services.Tests;

public sealed class ServiceOptionsTests
{
    private static string? Env(string name) => name switch
    {
        "GARAGE_PYTHON_HOME" => @"C:\Python314",
        "GARAGE_PYTHON_SITE_PACKAGES" => @"C:\venv\Lib\site-packages",
        "GARAGE_PYTHON_PATH" => @"C:\src\garage_python\src; C:\extra ;",
        _ => null,
    };

    [Fact]
    public void A_full_command_line_parses()
    {
        ServiceOptions options = ServiceOptions.Parse(
            ["--service", "ingest", "--pipe", "Garage-x-ingest", "--parent", "4242", "--grpc-port", "50123", "--data-dir", @"C:\data"], Env);
        Assert.Equal(ServiceRole.Ingest, options.Role);
        Assert.Equal("ingest", options.ServiceId);
        Assert.Equal(("Garage-x-ingest", 4242, 50123, @"C:\data"), (options.PipeName, options.ParentPid, options.GrpcPort, options.DataDirectory));
        Assert.Equal(@"C:\Python314", options.PythonHome);
        Assert.Equal([@"C:\src\garage_python\src", @"C:\extra"], options.ExtraPythonPaths);
    }

    [Theory]
    [InlineData("--service mail --pipe p --parent 1 --grpc-port 1", "unknown service 'mail'")]
    [InlineData("--service core --parent 1 --grpc-port 1", "--pipe is required")]
    [InlineData("--service core --pipe p --parent 1 --grpc-port 70000", "--grpc-port must be a number from 1 to 65535")]
    [InlineData("--service core --pipe p --parent -1 --grpc-port 1", "--parent must be a number")]
    [InlineData("--service", "expected '--name value'")]
    public void Bad_command_lines_say_what_is_wrong(string commandLine, string expected)
    {
        ArgumentException error = Assert.Throws<ArgumentException>(() => ServiceOptions.Parse(commandLine.Split(' '), Env));
        Assert.Contains(expected, error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void No_python_home_is_an_error_not_a_guess()
    {
        ArgumentException error = Assert.Throws<ArgumentException>(() =>
            ServiceOptions.Parse(["--service", "core", "--pipe", "p", "--parent", "1", "--grpc-port", "1"], _ => null));
        Assert.Contains("GARAGE_PYTHON_HOME", error.Message, StringComparison.Ordinal);
    }
}

public sealed class ServiceLogTests
{
    [Fact]
    public async Task Recent_keeps_the_newest_and_subscribers_see_what_follows()
    {
        using var log = new ServiceLog("core", null);
        for (int i = 0; i < ServiceLog.Capacity + 5; i++)
        {
            log.Info($"line {i}");
        }
        IReadOnlyList<Garage.Grpc.Services.LogEntry> recent = log.Recent(3);
        Assert.Equal(["line 2002", "line 2003", "line 2004"], recent.Select(e => e.Message));
        Assert.Equal(ServiceLog.Capacity, log.Recent(0).Count);

        using ServiceLog.Subscription subscription = log.Subscribe();
        log.Append(40, "boom", "python");
        Garage.Grpc.Services.LogEntry entry = await subscription.Reader.ReadAsync(TestContext.Current.CancellationToken);
        Assert.Equal(("boom", 40, "python"), (entry.Message, entry.Level, entry.Source));
    }

    [Fact]
    public void The_file_gets_one_line_per_entry()
    {
        string dir = Path.Combine(Path.GetTempPath(), "garage-log-test-" + Guid.NewGuid().ToString("N")[..8]);
        try
        {
            using (var log = new ServiceLog("ingest", Path.Combine(dir, "logs", "ingest.log")))
            {
                Assert.True(log.HasFile);
                log.Warning("slow disk");
            }
            string text = File.ReadAllText(Path.Combine(dir, "logs", "ingest.log"));
            Assert.Contains("WARNING [ingest] slow disk", text, StringComparison.Ordinal);
        }
        finally
        {
            ServiceFixture.Delete(dir);
        }
    }

    [Theory]
    [InlineData(10, "DEBUG")]
    [InlineData(20, "INFO")]
    [InlineData(30, "WARNING")]
    [InlineData(40, "ERROR")]
    [InlineData(50, "CRITICAL")]
    public void Levels_are_named_as_python_names_them(int level, string name) => Assert.Equal(name, ServiceLog.LevelName(level));
}

public sealed class PeerCheckTests
{
    [Fact]
    public void The_parent_is_allowed_and_an_unrelated_process_is_not()
    {
        using var log = new ServiceLog("core", null);
        var check = new PeerCheck(Environment.ProcessId, log);
        Assert.True(check.IsAllowed(Environment.ProcessId, out _));

        using Process other = Process.Start(new ProcessStartInfo("cmd.exe", ["/c", "ping -n 30 127.0.0.1 >nul"])
        {
            UseShellExecute = false,
            CreateNoWindow = true,
        })!;
        try
        {
            Assert.False(check.IsAllowed(other.Id, out string? image));
            Assert.EndsWith("cmd.exe", image, StringComparison.OrdinalIgnoreCase);
        }
        finally
        {
            other.Kill(entireProcessTree: true);
        }
    }
}

public sealed class ServiceHostLayoutTests
{
    [Fact]
    public void Environment_variables_win()
    {
        ServiceHostLayout layout = ServiceHostLayout.Locate(Path.GetTempPath(), name => name switch
        {
            "GARAGE_SERVICES_EXE" => @"C:\app\services\Garage.Services.exe",
            "GARAGE_PYTHON_HOME" => @"C:\app\python",
            "GARAGE_PYTHON_SITE_PACKAGES" => @"C:\app\site-packages",
            "GARAGE_PYTHON_PATH" => @"C:\a;C:\b",
            "GARAGE_DATA_DIR" => @"C:\data",
            _ => null,
        });
        Assert.Equal(@"C:\app\services\Garage.Services.exe", layout.ServicesExecutable);
        Assert.Equal((@"C:\app\python", @"C:\app\site-packages", @"C:\data"), (layout.PythonHome, layout.SitePackages, layout.DataDirectory));
        Assert.Equal([@"C:\a", @"C:\b"], layout.PythonPath);
    }

    [Fact]
    public void A_checkout_supplies_the_development_layout()
    {
        string? checkout = ServiceHostLayout.FindCheckout(AppContext.BaseDirectory);
        Assert.NotNull(checkout);
        ServiceHostLayout layout = ServiceHostLayout.Locate(AppContext.BaseDirectory, name => name == "GARAGE_PYTHON_HOME" ? @"C:\Python314" : null);
        Assert.EndsWith(ServiceHostLayout.ExecutableName, layout.ServicesExecutable, StringComparison.Ordinal);
        Assert.Equal([Path.Combine(checkout, "garage_python", "src")], layout.PythonPath);
        Assert.Equal(ServiceHostLayout.DefaultDataDirectory(), layout.DataDirectory);
    }
}

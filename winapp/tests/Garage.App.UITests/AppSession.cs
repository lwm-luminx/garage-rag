using System.Diagnostics;
using FlaUI.Core;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;
using FlaUI.Core.Tools;
using FlaUI.UIA3;

namespace Garage.App.UITests;

/// <summary>
/// One run of the built app against a <see cref="FakeBackend"/>, in a throwaway data folder: the
/// development backend (<c>--dev-backend</c>), so no services or Postgres start, and nothing of the
/// person's own Garage is touched.
/// </summary>
public sealed class AppSession : IAsyncDisposable
{
    /// <summary>How long a step may take to show.</summary>
    public static readonly TimeSpan Timeout = TimeSpan.FromSeconds(30);

    private readonly Application _app;
    private readonly string _exe;

    private AppSession(string exe, FakeBackend backend, string data, Application app, UIA3Automation automation)
    {
        _exe = exe;
        Backend = backend;
        DataDirectory = data;
        _app = app;
        Automation = automation;
    }

    /// <summary>The backend the app talks to.</summary>
    public FakeBackend Backend { get; }

    /// <summary>The throwaway data folder.</summary>
    public string DataDirectory { get; }

    /// <summary>UI Automation.</summary>
    public UIA3Automation Automation { get; }

    /// <summary>The main window.</summary>
    public Window Main => Retry.WhileNull(() => FindWindow("Garage"), Timeout, throwOnTimeout: true).Result!;

    /// <summary>
    /// Skips unless UI tests are asked for (<c>GARAGE_UI_TESTS=1</c>) and the app is built, and refuses
    /// to share the desktop with a running Garage, which would take the launch over.
    /// </summary>
    public static string RequireApp()
    {
        Assert.SkipUnless(Environment.GetEnvironmentVariable("GARAGE_UI_TESTS") == "1",
            "UI tests drive the desktop; set GARAGE_UI_TESTS=1 in an interactive session to run them");
        string? exe = Environment.GetEnvironmentVariable("GARAGE_APP_EXE") is { Length: > 0 } given ? given : FindBuiltApp();
        Assert.SkipWhen(exe is null || !File.Exists(exe), "Garage.exe is not built; run dotnet build Garage.slnx first, or set GARAGE_APP_EXE");
        Assert.True(Process.GetProcessesByName("Garage").Length == 0, "Quit Garage before running the UI tests: a running instance takes the test's launch over");
        return exe!;
    }

    /// <summary>Starts the app; <paramref name="firstRunDone"/> skips the setup assistant.</summary>
    public static async Task<AppSession> StartAsync(int documents = 2, bool firstRunDone = true, IReadOnlyDictionary<string, string>? environment = null)
    {
        string exe = RequireApp();
        FakeBackend backend = await FakeBackend.StartAsync(documents);
        string data = Path.Combine(Path.GetTempPath(), "garage-uitest-" + Guid.NewGuid().ToString("N")[..10]);
        Directory.CreateDirectory(data);
        if (firstRunDone)
        {
            File.WriteAllText(Path.Combine(data, "app-settings.json"), """{"firstRun.completed": true}""");
        }
        Application app = Application.Launch(StartInfo(exe, backend, data, environment, "--dev-backend"));
        return new AppSession(exe, backend, data, app, new UIA3Automation());
    }

    /// <summary>A second launch with <paramref name="arguments"/>, which hands them to this one and exits (the jump list's tasks).</summary>
    public void Relaunch(params string[] arguments)
    {
        using Process? second = Process.Start(StartInfo(_exe, Backend, DataDirectory, null, ["--dev-backend", .. arguments]));
        Assert.True(second?.WaitForExit(TimeSpan.FromSeconds(20)) ?? false, "the second launch did not hand over and exit");
    }

    /// <summary>A top-level window of the app by name.</summary>
    public Window? FindWindow(string name) =>
        _app.GetAllTopLevelWindows(Automation).FirstOrDefault(w => w.Name == name);

    /// <summary>The element with <paramref name="automationId"/> under <paramref name="root"/>, waiting for it.</summary>
    public static AutomationElement Find(AutomationElement root, string automationId) =>
        Retry.WhileNull(() => root.FindFirstDescendant(cf => cf.ByAutomationId(automationId)), Timeout, throwOnTimeout: true,
            timeoutMessage: $"{automationId} did not appear").Result!;

    /// <summary>Waits until <paramref name="condition"/> holds.</summary>
    public static void Until(Func<bool> condition, string what) =>
        Retry.WhileFalse(condition, Timeout, throwOnTimeout: true, timeoutMessage: what);

    /// <summary>Shows a page by its navigation title.</summary>
    public void ShowPage(string title)
    {
        AutomationElement item = Retry.WhileNull(
            () => Main.FindFirstDescendant(cf => cf.ByName(title).And(cf.ByControlType(ControlType.ListItem))), Timeout, throwOnTimeout: true).Result!;
        item.Patterns.SelectionItem.Pattern.Select();
    }

    /// <inheritdoc/>
    public async ValueTask DisposeAsync()
    {
        try
        {
            if (!_app.HasExited)
            {
                _app.Kill();
            }
        }
        finally
        {
            _app.Dispose();
            Automation.Dispose();
            await Backend.DisposeAsync();
            for (int i = 0; i < 20 && Directory.Exists(DataDirectory); i++)
            {
                try
                {
                    Directory.Delete(DataDirectory, recursive: true);
                }
                catch (IOException)
                {
                    await Task.Delay(250);
                }
            }
        }
    }

    private static ProcessStartInfo StartInfo(string exe, FakeBackend backend, string data, IReadOnlyDictionary<string, string>? environment, params string[] arguments)
    {
        var info = new ProcessStartInfo(exe) { UseShellExecute = false };
        foreach (string argument in arguments)
        {
            info.ArgumentList.Add(argument);
        }
        info.Environment["GARAGE_GRPC_HOST"] = "127.0.0.1";
        info.Environment["GARAGE_GRPC_PORT"] = backend.GrpcPort.ToString(System.Globalization.CultureInfo.InvariantCulture);
        info.Environment["GARAGE_GRPC_TOKEN"] = "ui-test-token";
        info.Environment["GARAGE_MCP_URL"] = backend.McpUrl.ToString();
        info.Environment["GARAGE_DATA_DIR"] = data;
        foreach ((string key, string value) in environment ?? new Dictionary<string, string>())
        {
            info.Environment[key] = value;
        }
        return info;
    }

    private static string? FindBuiltApp()
    {
        for (DirectoryInfo? folder = new(AppContext.BaseDirectory); folder is not null; folder = folder.Parent)
        {
            string app = Path.Combine(folder.FullName, "src", "Garage.App", "bin");
            if (Directory.Exists(app))
            {
                return Directory.EnumerateFiles(app, "Garage.exe", SearchOption.AllDirectories)
                    .OrderByDescending(File.GetLastWriteTimeUtc).FirstOrDefault();
            }
        }
        return null;
    }
}

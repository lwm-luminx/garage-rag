using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;

namespace Garage.App;

/// <summary>
/// Entry point. Garage runs once per user: a second launch hands its activation to the running
/// instance, which brings its window forward, and exits (the Mac's single app instance).
/// </summary>
public static class Program
{
    /// <summary>The key every Garage instance registers under.</summary>
    public const string InstanceKey = "GarageApp";

    [STAThread]
    private static int Main()
    {
        WinRT.ComWrappersSupport.InitializeComWrappers();
        WaitForResetInstance();
        if (RedirectedToRunningInstance())
        {
            return 0;
        }

        Application.Start(callback =>
        {
            var context = new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread());
            SynchronizationContext.SetSynchronizationContext(context);
            _ = new App();
        });
        return 0;
    }

    // A relaunch after Reset Database waits for the instance that started it to exit, which it does at
    // once; otherwise the single-instance check would hand this launch back to it.
    private static void WaitForResetInstance()
    {
        string[] args = Environment.GetCommandLineArgs();
        int at = Array.IndexOf(args, App.AfterDatabaseResetArgument);
        if (at < 0 || at + 1 >= args.Length || !int.TryParse(args[at + 1], System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out int pid))
        {
            return;
        }
        try
        {
            using var old = System.Diagnostics.Process.GetProcessById(pid);
            old.WaitForExit(TimeSpan.FromSeconds(30));
        }
        catch (ArgumentException)
        {
            // Already gone.
        }
    }

    private static bool RedirectedToRunningInstance()
    {
        AppInstance registered = AppInstance.FindOrRegisterForKey(InstanceKey);
        if (registered.IsCurrent)
        {
            // A second launch's command line (the jump list's tasks) comes with its activation.
            registered.Activated += (_, args) =>
            {
                string commandLine = args.Data is Windows.ApplicationModel.Activation.ILaunchActivatedEventArgs launched ? launched.Arguments : "";
                App.Current?.OnRedirected(commandLine);
            };
            return false;
        }

        // Redirect off the STA thread: waiting on it here would block the COM call the redirect makes.
        AppActivationArguments arguments = AppInstance.GetCurrent().GetActivatedEventArgs();
        Task.Run(() => registered.RedirectActivationToAsync(arguments).AsTask()).Wait();
        return true;
    }
}

using Garage.App.Core.Navigation;
using Garage.App.Core.Settings;
using Garage.App.Core.Store;
using Microsoft.Win32;
using Windows.ApplicationModel;
using Windows.Services.Store;
using Windows.Storage;
using Windows.Storage.Pickers;

namespace Garage.App.Platform;

/// <summary>
/// Launch at sign-in for the unpackaged builds (the MSI, a build folder): a value under the account's
/// <c>Run</c> key that starts Garage with <c>--background</c>, so it comes up in the notification
/// area only. The MSIX builds use <see cref="PackagedStartup"/> instead.
/// </summary>
internal sealed class RunKeyStartup : IStartupRegistration
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "Garage";

    private static string Command => $"\"{Environment.ProcessPath}\" {LaunchCommand.BackgroundSwitch}";

    public bool IsAvailable => Environment.ProcessPath is not null;

    public bool IsEnabled
    {
        get
        {
            using RegistryKey? key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(ValueName) is string value && value.Equals(Command, StringComparison.OrdinalIgnoreCase);
        }
    }

    public bool SetEnabled(bool enabled)
    {
        try
        {
            using RegistryKey key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (enabled)
            {
                key.SetValue(ValueName, Command, RegistryValueKind.String);
            }
            else
            {
                key.DeleteValue(ValueName, throwOnMissingValue: false);
            }
        }
        catch (Exception ex) when (ex is UnauthorizedAccessException or System.Security.SecurityException or IOException)
        {
            return false;
        }
        return IsEnabled == enabled;
    }
}

/// <summary>
/// Launch at sign-in for the MSIX builds: the manifest's <c>StartupTask</c>
/// (<c>winapp/packaging/msix/AppxManifest.xml</c>), which the person also controls in Settings &gt; Apps &gt;
/// Startup. A packaged app's writes to the <c>Run</c> key land in the package's private registry, which
/// Windows never reads at sign-in. Windows starts the task with no command line, so
/// <see cref="Distribution.LaunchedAtSignIn"/> tells the app to start in the notification area.
/// </summary>
internal sealed class PackagedStartup : IStartupRegistration
{
    /// <summary>The task's id in the manifest.</summary>
    public const string TaskId = "GarageStartup";

    private readonly StartupTask? _task;
    private StartupTaskState _state;

    public PackagedStartup()
    {
        try
        {
            _task = Wait(StartupTask.GetAsync(TaskId).AsTask());
            _state = _task.State;
        }
        catch (Exception ex) when (ex is ArgumentException or System.Runtime.InteropServices.COMException)
        {
            // The manifest declares no such task.
            _task = null;
        }
    }

    // Turned off in Settings or by policy, only Settings or the policy can turn it back on.
    public bool IsAvailable => _task is not null && _state is StartupTaskState.Disabled or StartupTaskState.Enabled;

    public bool IsEnabled => _state is StartupTaskState.Enabled or StartupTaskState.EnabledByPolicy;

    public bool SetEnabled(bool enabled)
    {
        if (_task is null)
        {
            return false;
        }
        if (enabled)
        {
            _state = Wait(_task.RequestEnableAsync().AsTask());
        }
        else
        {
            _task.Disable();
            _state = _task.State;
        }
        return IsEnabled == enabled;
    }

    // A full-trust app is never prompted, so nothing needs the UI thread: wait off it, as Program's
    // redirect does, so the call cannot need the thread this one blocks.
    private static T Wait<T>(Task<T> task) => Task.Run(() => task).GetAwaiter().GetResult();
}

/// <summary>How this copy was installed, from its package identity.</summary>
internal static class Distribution
{
    /// <summary>
    /// The file the MSI installs beside <c>Garage.exe</c> (<c>winapp/packaging/msi</c>), which tells its
    /// installs from a build folder.
    /// </summary>
    public const string InstalledByMsiMarker = "installed-by-msi";

    public static AppDistribution Current { get; } = Detect();

    /// <summary>Whether Windows started this launch from the MSIX's <c>StartupTask</c>.</summary>
    public static bool LaunchedAtSignIn()
    {
        try
        {
            return Microsoft.Windows.AppLifecycle.AppInstance.GetCurrent().GetActivatedEventArgs().Kind
                == Microsoft.Windows.AppLifecycle.ExtendedActivationKind.StartupTask;
        }
        catch (System.Runtime.InteropServices.COMException)
        {
            return false;
        }
    }

    /// <summary>How this copy starts at sign-in: the manifest's task when packaged, else the <c>Run</c> key.</summary>
    public static IStartupRegistration Startup() =>
        Current is AppDistribution.Store or AppDistribution.AppInstaller ? new PackagedStartup() : new RunKeyStartup();

    private static AppDistribution Detect()
    {
        try
        {
            Windows.ApplicationModel.Package package = Windows.ApplicationModel.Package.Current;
            return package.SignatureKind == Windows.ApplicationModel.PackageSignatureKind.Store ? AppDistribution.Store : AppDistribution.AppInstaller;
        }
        catch (InvalidOperationException)
        {
            // No package identity: installed by the MSI, or run from a build folder.
            return Unpackaged();
        }
        catch (System.Runtime.InteropServices.COMException)
        {
            return Unpackaged();
        }
    }

    private static AppDistribution Unpackaged() =>
        File.Exists(Path.Combine(AppContext.BaseDirectory, InstalledByMsiMarker)) ? AppDistribution.WindowsInstaller : AppDistribution.Unpackaged;

    public static string Title(this AppDistribution distribution) => distribution switch
    {
        AppDistribution.Store => "Microsoft Store",
        AppDistribution.AppInstaller => "App Installer",
        AppDistribution.WindowsInstaller => "Windows Installer",
        _ => "Unpackaged",
    };
}

/// <summary>The Microsoft Store's add-ons, for the Store build's tip jar.</summary>
internal sealed class StoreTipStore(nint window) : ITipStore
{
    private StoreContext? _context;

    private StoreContext Context
    {
        get
        {
            if (_context is null)
            {
                _context = StoreContext.GetDefault();
                // A desktop app names the window the Store's purchase dialog belongs to.
                WinRT.Interop.InitializeWithWindow.Initialize(_context, window);
            }
            return _context;
        }
    }

    public async Task<IReadOnlyList<TipProduct>> LoadAsync()
    {
        try
        {
            StoreProductQueryResult result = await Context.GetAssociatedStoreProductsAsync(["Consumable", "UnmanagedConsumable"]);
            return result.ExtendedError is null
                ? [.. result.Products.Values.Where(p => TipProducts.Contains(p.InAppOfferToken)).Select(p => new TipProduct(p.StoreId, p.InAppOfferToken, p.Price.FormattedPrice))]
                : [];
        }
        catch (Exception ex) when (ex is System.Runtime.InteropServices.COMException or InvalidOperationException)
        {
            return [];
        }
    }

    public async Task<(TipPurchaseOutcome Outcome, string? Message)> PurchaseAsync(TipProduct product)
    {
        try
        {
            StorePurchaseResult purchase = await Context.RequestPurchaseAsync(product.StoreId);
            switch (purchase.Status)
            {
                case StorePurchaseStatus.Succeeded:
                case StorePurchaseStatus.AlreadyPurchased:
                    // A tip unlocks nothing: it is consumed at once, so it can be bought again.
                    await Context.ReportConsumableFulfillmentAsync(product.StoreId, 1, Guid.NewGuid());
                    return (TipPurchaseOutcome.Succeeded, null);
                case StorePurchaseStatus.NotPurchased:
                    return (TipPurchaseOutcome.Cancelled, null);
                default:
                    return (TipPurchaseOutcome.Failed, purchase.ExtendedError?.Message ?? purchase.Status.ToString());
            }
        }
        catch (Exception ex) when (ex is System.Runtime.InteropServices.COMException or InvalidOperationException)
        {
            return (TipPurchaseOutcome.Failed, ex.Message);
        }
    }
}

/// <summary>The system pickers, owned by the main window.</summary>
internal static class Pickers
{
    public static async Task<string?> FolderAsync()
    {
        var picker = new FolderPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, App.Current!.MainWindowHandle);
        StorageFolder? folder = await picker.PickSingleFolderAsync();
        return folder?.Path;
    }

    public static async Task<string?> SaveFileAsync(string suggestedName, string typeName, string extension)
    {
        var picker = new FileSavePicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary, SuggestedFileName = Path.GetFileNameWithoutExtension(suggestedName) };
        picker.FileTypeChoices.Add(typeName, [extension]);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, App.Current!.MainWindowHandle);
        StorageFile? file = await picker.PickSaveFileAsync();
        return file?.Path;
    }
}

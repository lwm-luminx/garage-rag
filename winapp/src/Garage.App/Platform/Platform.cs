using Garage.App.Core.Navigation;
using Garage.App.Core.Settings;
using Garage.App.Core.Store;
using Microsoft.Win32;
using Windows.Services.Store;
using Windows.Storage;
using Windows.Storage.Pickers;

namespace Garage.App.Platform;

/// <summary>
/// Launch at sign-in for the unpackaged and App Installer builds: a value under the account's
/// <c>Run</c> key that starts Garage with <c>--background</c>, so it comes up in the notification
/// area only. (A packaged build declares a <c>StartupTask</c> in its manifest instead; windows.md §6.)
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

/// <summary>How this copy was installed, from its package identity.</summary>
internal static class Distribution
{
    public static AppDistribution Current { get; } = Detect();

    private static AppDistribution Detect()
    {
        try
        {
            Windows.ApplicationModel.Package package = Windows.ApplicationModel.Package.Current;
            return package.SignatureKind == Windows.ApplicationModel.PackageSignatureKind.Store ? AppDistribution.Store : AppDistribution.AppInstaller;
        }
        catch (InvalidOperationException)
        {
            // No package identity: run from a build folder.
            return AppDistribution.Unpackaged;
        }
        catch (System.Runtime.InteropServices.COMException)
        {
            return AppDistribution.Unpackaged;
        }
    }

    public static string Title(this AppDistribution distribution) => distribution switch
    {
        AppDistribution.Store => "Microsoft Store",
        AppDistribution.AppInstaller => "App Installer",
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

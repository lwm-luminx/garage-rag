using CommunityToolkit.Mvvm.ComponentModel;
using Garage.App.Core.State;

namespace Garage.App.Core.Settings;

/// <summary>Which builds a direct-download install updates to (the Mac's Sparkle beta channel).</summary>
public enum UpdateChannel
{
    /// <summary>Releases.</summary>
    Stable,

    /// <summary>Betas as well.</summary>
    Beta,
}

/// <summary>How this copy of Garage was installed, which decides how it updates.</summary>
public enum AppDistribution
{
    /// <summary>Built and run from a checkout: it does not update.</summary>
    Unpackaged,

    /// <summary>The MSIX from <c>garagerag.app</c>, updated by App Installer from its feed.</summary>
    AppInstaller,

    /// <summary>The Microsoft Store, which updates it (betas through package flights).</summary>
    Store,

    /// <summary>The MSI (<c>winapp/packaging</c>): a newer installer, run or deployed, updates it.</summary>
    WindowsInstaller,
}

/// <summary>The update feeds (windows.md §6).</summary>
public static class UpdateFeeds
{
    /// <summary>The stable feed.</summary>
    public static Uri Stable { get; } = new("https://garagerag.app/windows/garage.appinstaller");

    /// <summary>The beta feed.</summary>
    public static Uri Beta { get; } = new("https://garagerag.app/windows/garage-beta.appinstaller");

    /// <summary>The feed for a channel.</summary>
    public static Uri For(UpdateChannel channel) => channel == UpdateChannel.Beta ? Beta : Stable;

    /// <summary>The channel picker's label.</summary>
    public static string Title(this UpdateChannel channel) => channel == UpdateChannel.Beta ? "Beta" : "Stable";

    /// <summary>What Settings says about updates for this distribution.</summary>
    public static string Explanation(AppDistribution distribution, UpdateChannel channel) => distribution switch
    {
        AppDistribution.Store => "The Microsoft Store keeps Garage up to date. Betas come through the Store's own flights.",
        AppDistribution.AppInstaller => channel == UpdateChannel.Beta
            ? "Garage checks for betas and releases each time it starts."
            : "Garage checks for new releases each time it starts.",
        AppDistribution.WindowsInstaller => "Garage updates when a newer installer is run, by you or by your organization.",
        _ => "This copy of Garage runs from a build folder and does not update itself.",
    };

    /// <summary>Whether the channel can be chosen: only the App Installer build follows a feed.</summary>
    public static bool CanChooseChannel(AppDistribution distribution) => distribution == AppDistribution.AppInstaller;
}

/// <summary>Starting Garage when the person signs in to Windows.</summary>
public interface IStartupRegistration
{
    /// <summary>Whether it can be changed (a policy may forbid it).</summary>
    bool IsAvailable { get; }

    /// <summary>Whether Garage starts at sign-in.</summary>
    bool IsEnabled { get; }

    /// <summary>Turns it on or off; returns whether it is now as asked.</summary>
    bool SetEnabled(bool enabled);
}

/// <summary>A registration kept in memory, for tests.</summary>
public sealed class MemoryStartupRegistration : IStartupRegistration
{
    /// <inheritdoc/>
    public bool IsAvailable { get; init; } = true;

    /// <inheritdoc/>
    public bool IsEnabled { get; private set; }

    /// <inheritdoc/>
    public bool SetEnabled(bool enabled)
    {
        if (IsAvailable)
        {
            IsEnabled = enabled;
        }
        return IsEnabled == enabled;
    }
}

/// <summary>
/// The app's own options on the Settings page: launch at sign-in and the update channel. They live
/// in <c>app-settings.json</c>, not <c>garage.json</c>, which says what Garage indexes, not how the app behaves.
/// </summary>
public sealed partial class AppOptionsViewModel : ObservableObject
{
    /// <summary>The preference holding the channel.</summary>
    public const string ChannelKey = "updates.channel";

    private readonly IPreferences _preferences;
    private readonly IStartupRegistration _startup;
    private bool _loading;

    /// <summary>Creates the options over their stores.</summary>
    public AppOptionsViewModel(IPreferences preferences, IStartupRegistration startup, AppDistribution distribution)
    {
        _preferences = preferences ?? throw new ArgumentNullException(nameof(preferences));
        _startup = startup ?? throw new ArgumentNullException(nameof(startup));
        Distribution = distribution;
        _loading = true;
        LaunchAtStartup = startup.IsEnabled;
        Channel = Enum.TryParse(preferences.Read(ChannelKey, nameof(UpdateChannel.Stable)), out UpdateChannel channel) ? channel : UpdateChannel.Stable;
        _loading = false;
    }

    /// <summary>How this copy was installed.</summary>
    public AppDistribution Distribution { get; }

    /// <summary>Whether launch at sign-in can be changed.</summary>
    public bool CanLaunchAtStartup => _startup.IsAvailable;

    /// <summary>Whether the channel can be chosen.</summary>
    public bool CanChooseChannel => UpdateFeeds.CanChooseChannel(Distribution);

    /// <summary>Start Garage at sign-in, in the notification area.</summary>
    [ObservableProperty]
    public partial bool LaunchAtStartup { get; set; }

    /// <summary>The update channel.</summary>
    [ObservableProperty]
    public partial UpdateChannel Channel { get; set; }

    /// <summary>Why a change did not take.</summary>
    [ObservableProperty]
    public partial string? ErrorMessage { get; private set; }

    /// <summary>The line under the channel picker.</summary>
    public string UpdateExplanation => UpdateFeeds.Explanation(Distribution, Channel);

    /// <summary>The feed the channel follows.</summary>
    public Uri Feed => UpdateFeeds.For(Channel);

    partial void OnLaunchAtStartupChanged(bool value)
    {
        if (_loading)
        {
            return;
        }
        ErrorMessage = _startup.SetEnabled(value) ? null : "Windows did not let Garage change whether it starts at sign-in.";
        if (_startup.IsEnabled != value)
        {
            // Back to what Windows has, without asking it again.
            _loading = true;
            LaunchAtStartup = _startup.IsEnabled;
            _loading = false;
        }
    }

    partial void OnChannelChanged(UpdateChannel value)
    {
        OnPropertyChanged(nameof(UpdateExplanation));
        OnPropertyChanged(nameof(Feed));
        if (!_loading)
        {
            _preferences.Write(ChannelKey, value.ToString());
        }
    }
}

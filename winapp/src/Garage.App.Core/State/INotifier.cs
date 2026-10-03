namespace Garage.App.Core.State;

/// <summary>
/// Tells the person a long operation finished while they may be looking elsewhere: an app
/// notification (toast) in the Windows app, nothing in tests.
/// </summary>
public interface INotifier
{
    /// <summary>Shows a notification.</summary>
    void Notify(string title, string message, bool isError = false);
}

/// <summary>Drops every notification: the default until the app installs a real one.</summary>
public sealed class SilentNotifier : INotifier
{
    /// <summary>The shared instance.</summary>
    public static SilentNotifier Instance { get; } = new();

    /// <inheritdoc/>
    public void Notify(string title, string message, bool isError = false)
    {
    }
}

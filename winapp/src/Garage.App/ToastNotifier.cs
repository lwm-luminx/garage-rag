using Garage.App.Core.State;
using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;

namespace Garage.App;

/// <summary>
/// App notifications (toasts) for long operations that finish while the person may be looking
/// elsewhere: a scan, an embedding backfill, a Glean. If Windows will not register the app for
/// notifications (policy, or Focus Assist settings), notifications are dropped rather than failing
/// the operation that finished.
/// </summary>
internal sealed class ToastNotifier : INotifier, IDisposable
{
    private readonly bool _registered;

    public ToastNotifier()
    {
        try
        {
            AppNotificationManager.Default.Register();
            _registered = true;
        }
        catch (Exception ex) when (ex is System.Runtime.InteropServices.COMException or InvalidOperationException or UnauthorizedAccessException)
        {
            _registered = false;
        }
    }

    public void Notify(string title, string message, bool isError = false)
    {
        if (!_registered)
        {
            return;
        }
        try
        {
            AppNotification notification = new AppNotificationBuilder()
                .AddText(title)
                .AddText(string.IsNullOrWhiteSpace(message) ? " " : message)
                .BuildNotification();
            AppNotificationManager.Default.Show(notification);
        }
        catch (System.Runtime.InteropServices.COMException)
        {
            // A notification is a courtesy; the operation already finished and logged.
        }
    }

    public void Dispose()
    {
        if (_registered)
        {
            try
            {
                AppNotificationManager.Default.Unregister();
            }
            catch (System.Runtime.InteropServices.COMException)
            {
            }
        }
    }
}

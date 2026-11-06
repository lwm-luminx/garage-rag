using System.Runtime.InteropServices;
using Garage.App.Core.Tray;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;

namespace Garage.App.Tray;

/// <summary>
/// The window the tray flyout lives in: borderless, on top, out of Alt+Tab, at the corner of the
/// screen beside the notification area, sized to its content. It hides when it loses focus, as the
/// Mac's popover closes when focus moves.
/// </summary>
internal sealed partial class TrayFlyoutWindow : Window
{
    private const int Margin = 12;
    private const int MaxHeight = 720;
    private const int DefaultHeight = 360;

    private readonly TrayFlyout _flyout;
    private bool _allowClose;
    private DateTime _hiddenAt = DateTime.MinValue;

    public TrayFlyoutWindow(TrayViewModel model, TrayActions actions)
    {
        Title = Strings.Get("Code_TrayFlyoutWindow_GarageSearch");
        _flyout = new TrayFlyout(model, actions with { Dismiss = () => { actions.Dismiss(); Hide(); } });
        Content = new ScrollViewer
        {
            Content = _flyout,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        };
        SystemBackdrop = new DesktopAcrylicBackdrop();
        var presenter = OverlappedPresenter.Create();
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        presenter.IsAlwaysOnTop = true;
        presenter.SetBorderAndTitleBar(hasBorder: true, hasTitleBar: false);
        AppWindow.SetPresenter(presenter);
        AppWindow.IsShownInSwitchers = false;
        AppWindow.Closing += (sender, args) =>
        {
            if (!_allowClose)
            {
                args.Cancel = true;
                Hide();
            }
        };
        Activated += (_, args) =>
        {
            if (args.WindowActivationState == WindowActivationState.Deactivated && AppWindow.IsVisible)
            {
                Hide();
            }
        };
        _flyout.Loaded += (_, _) => Fit();
        _flyout.ContentChanged += (_, _) =>
        {
            if (AppWindow.IsVisible)
            {
                Fit();
            }
        };
    }

    /// <summary>Shows the flyout, or hides it when it is showing (a second click on the icon).</summary>
    public void Toggle()
    {
        // The click that hid it by taking focus away arrives just after; it must not show it again.
        if (AppWindow.IsVisible || DateTime.UtcNow - _hiddenAt < TimeSpan.FromMilliseconds(300))
        {
            Hide();
            return;
        }
        ShowFlyout();
    }

    /// <summary>Shows the flyout at the corner of the screen the pointer is on, with the cursor in the field.</summary>
    public void ShowFlyout()
    {
        Fit();
        AppWindow.Show();
        Activate();
        _ = SetForegroundWindow(WinRT.Interop.WindowNative.GetWindowHandle(this));
        _flyout.FocusField();
    }

    public void Hide()
    {
        if (AppWindow.IsVisible)
        {
            _hiddenAt = DateTime.UtcNow;
            AppWindow.Hide();
        }
    }

    /// <summary>Lets the next close really close (Quit).</summary>
    public void AllowClose() => _allowClose = true;

    // Sizes the window to the flyout and anchors it above the notification area.
    private void Fit()
    {
        nint hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        double scale = GetDpiForWindow(hwnd) / 96.0;
        // Content is measured only once it is in a live tree (Measure throws before the window first
        // shows); until then the flyout takes a default height and is fitted when it has loaded.
        double contentHeight = DefaultHeight;
        if (_flyout.IsLoaded)
        {
            try
            {
                _flyout.Measure(new Windows.Foundation.Size(_flyout.Width, double.PositiveInfinity));
                contentHeight = _flyout.DesiredSize.Height;
            }
            catch (COMException)
            {
                // Mid-layout; the next change fits it.
            }
        }
        int width = (int)Math.Ceiling((_flyout.Width + 2) * scale);
        _ = GetCursorPos(out POINT cursor);
        DisplayArea display = DisplayArea.GetFromPoint(new PointInt32(cursor.X, cursor.Y), DisplayAreaFallback.Primary);
        RectInt32 work = display.WorkArea;
        int height = (int)Math.Ceiling(Math.Min(contentHeight + 2, MaxHeight) * scale);
        height = Math.Min(height, work.Height - (2 * Margin));
        AppWindow.MoveAndResize(new RectInt32(work.X + work.Width - width - Margin, work.Y + work.Height - height - Margin, width, height));
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT
    {
        public int X;
        public int Y;
    }

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetCursorPos(out POINT point);

    [LibraryImport("user32.dll")]
    private static partial uint GetDpiForWindow(nint window);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetForegroundWindow(nint window);
}

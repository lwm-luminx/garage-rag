using CommunityToolkit.Mvvm.Input;
using Garage.App.Core.Tray;
using H.NotifyIcon;
using H.NotifyIcon.Core;
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace Garage.App.Tray;

/// <summary>What the icon's right-click menu does.</summary>
internal sealed record TrayMenu(Action Open, Action Ask, Action ToggleAutomaticUpdates, Func<bool> AutomaticUpdatesOn, Action ReportBug, Action Quit);

/// <summary>
/// The notification-area icon, the counterpart of the Mac's menu-bar extra. A left click opens the
/// flyout; a right click offers Open Garage, Ask Garage, pausing Automatic Updates, Report a Bug and
/// Quit. The picture follows <see cref="TrayStatus.Icon"/>: the Mac's open door is a blue "G", its
/// closed door a grey one, a warning an orange "!"; it pulses while the pipeline works.
/// </summary>
internal sealed class TrayIcon : IDisposable
{
    private static readonly Color Open = Colors.SteelBlue;
    private static readonly Color Pulse = Color.FromArgb(0xFF, 0x6C, 0xA6, 0xE0);

    private readonly TaskbarIcon _icon;
    private readonly DispatcherQueueTimer _pulse;
    private readonly MenuFlyoutItem _automatic;
    private readonly Func<bool> _automaticOn;
    private TrayIconKind? _kind;
    private bool _pulsing;
    private bool _bright;

    public TrayIcon(Action toggleFlyout, TrayMenu menu)
    {
        var flyout = new MenuFlyout();
        flyout.Items.Add(new MenuFlyoutItem { Text = "Open Garage", Command = new RelayCommand(menu.Open) });
        flyout.Items.Add(new MenuFlyoutItem { Text = "Ask Garage…", Command = new RelayCommand(menu.Ask) });
        flyout.Items.Add(new MenuFlyoutSeparator());
        _automaticOn = menu.AutomaticUpdatesOn;
        _automatic = new MenuFlyoutItem { Command = new RelayCommand(menu.ToggleAutomaticUpdates) };
        flyout.Items.Add(_automatic);
        flyout.Items.Add(new MenuFlyoutItem { Text = "Report a Bug…", Command = new RelayCommand(menu.ReportBug) });
        flyout.Items.Add(new MenuFlyoutSeparator());
        flyout.Items.Add(new MenuFlyoutItem { Text = "Quit Garage", Command = new RelayCommand(menu.Quit) });
        flyout.Opening += (_, _) => _automatic.Text = _automaticOn() ? "Pause Automatic Updates" : "Resume Automatic Updates";
        _automatic.Text = _automaticOn() ? "Pause Automatic Updates" : "Resume Automatic Updates";

        _icon = new TaskbarIcon
        {
            ToolTipText = "Garage",
            IconSource = Picture(TrayIconKind.Closed, bright: false),
            ContextMenuMode = ContextMenuMode.PopupMenu,
            ContextFlyout = flyout,
            LeftClickCommand = new RelayCommand(toggleFlyout),
            NoLeftClickDelay = true,
        };
        _icon.ForceCreate();

        _pulse = DispatcherQueue.GetForCurrentThread().CreateTimer();
        _pulse.Interval = TimeSpan.FromMilliseconds(700);
        _pulse.Tick += (_, _) =>
        {
            _bright = !_bright;
            _icon.IconSource = Picture(_kind ?? TrayIconKind.Open, _bright);
        };
    }

    /// <summary>Shows <paramref name="status"/>: the picture, the motion and the tooltip (also the icon's accessible name).</summary>
    public void Show(TrayStatus status)
    {
        if (_kind != status.Icon)
        {
            _kind = status.Icon;
            _bright = false;
            _icon.IconSource = Picture(status.Icon, bright: false);
        }
        if (_pulsing != status.IsPulsing)
        {
            _pulsing = status.IsPulsing;
            if (_pulsing)
            {
                _pulse.Start();
            }
            else
            {
                _pulse.Stop();
                _bright = false;
                _icon.IconSource = Picture(status.Icon, bright: false);
            }
        }
        string tip = status.AccessibilityLabel;
        if (_icon.ToolTipText != tip)
        {
            _icon.ToolTipText = tip;
        }
    }

    public void Dispose()
    {
        _pulse.Stop();
        _icon.Dispose();
    }

    private static GeneratedIconSource Picture(TrayIconKind kind, bool bright) => kind switch
    {
        TrayIconKind.Warning => new GeneratedIconSource
        {
            Text = "!",
            Foreground = new SolidColorBrush(Colors.White),
            Background = new SolidColorBrush(Colors.DarkOrange),
        },
        TrayIconKind.Closed => new GeneratedIconSource
        {
            Text = "G",
            Foreground = new SolidColorBrush(Colors.White),
            Background = new SolidColorBrush(Colors.Gray),
        },
        _ => new GeneratedIconSource
        {
            Text = "G",
            Foreground = new SolidColorBrush(Colors.White),
            Background = new SolidColorBrush(bright ? Pulse : Open),
        },
    };
}

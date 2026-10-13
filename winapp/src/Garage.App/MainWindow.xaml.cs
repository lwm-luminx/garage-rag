using System.Runtime.InteropServices;
using Garage.App.Core.Navigation;
using Garage.App.Core.Presentation;
using Garage.App.FirstRun;
using Garage.App.Core.State;
using Garage.App.Pages;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Windows.Graphics;
using Windows.System;

namespace Garage.App;

/// <summary>
/// The main window: a <see cref="NavigationView"/> with Status on top, then the Configuration,
/// Data and Advanced groups, and Settings in the footer (docs/plans/windows-ui.md §3). Closing it
/// hides it to the notification area, as closing the Mac window leaves the menu-bar app running.
/// </summary>
public sealed partial class MainWindow : Microsoft.UI.Xaml.Window
{
    private readonly AppState _state;
    private readonly PageModels _pages;
    private bool _allowClose;

    /// <summary>Creates the window over the app state and the pages' view models.</summary>
    public MainWindow(PageModels pages)
    {
        ArgumentNullException.ThrowIfNull(pages);
        _pages = pages;
        _state = pages.State;
        InitializeComponent();

        Title = Strings.Get("Code_MainWindow_Garage");
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        AppWindow.Closing += OnClosing;

        BuildNavigation();
        AddShortcuts();
        Select(AppSections.Top);

        // The assistant shows from the first frame when it is due, so the pages never flash first.
        FirstRunHost.Content = new FirstRunView(pages.FirstRun);
        pages.FirstRun.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(Core.Onboarding.FirstRunCoordinator.IsActive))
            {
                ShowFirstRun(pages.FirstRun.IsActive);
                ResizeForFirstRun(pages.FirstRun.IsActive);
            }
        };
        ShowFirstRun(pages.FirstRun.IsActive);
        OpenAtInitialSize(pages.FirstRun.IsActive);

        // A display with another scale changes what the minimum is in physical pixels; a theme change
        // recolours the caption buttons.
        if (Content is Microsoft.UI.Xaml.FrameworkElement root)
        {
            root.Loaded += (_, _) => root.XamlRoot.Changed += (_, _) => ApplyMinimumSize();
            root.ActualThemeChanged += (_, _) => ApplyCaptionColors();
        }
        ApplyCaptionColors();
    }

    // Minimise, maximise and close in the design system's ink on the chrome, with surface-sunken behind
    // them on hover. Windows colours them for its own theme, which the app's need not match
    // (--appearance); in high contrast they keep the system's colours.
    private void ApplyCaptionColors()
    {
        AppWindowTitleBar bar = AppWindow.TitleBar;
        bool dark = Content is Microsoft.UI.Xaml.FrameworkElement { ActualTheme: Microsoft.UI.Xaml.ElementTheme.Dark };
        if (new Windows.UI.ViewManagement.AccessibilitySettings().HighContrast
            || Microsoft.UI.Xaml.Application.Current.Resources.MergedDictionaries
                .FirstOrDefault(d => d.Source?.AbsolutePath.EndsWith("/GarageTheme.xaml", StringComparison.Ordinal) == true) is not { } theme
            || theme.ThemeDictionaries[dark ? "Dark" : "Light"] is not Microsoft.UI.Xaml.ResourceDictionary tokens)
        {
            bar.ButtonForegroundColor = bar.ButtonHoverForegroundColor = bar.ButtonPressedForegroundColor = bar.ButtonInactiveForegroundColor = null;
            bar.ButtonBackgroundColor = bar.ButtonInactiveBackgroundColor = bar.ButtonHoverBackgroundColor = bar.ButtonPressedBackgroundColor = null;
            return;
        }
        Windows.UI.Color Token(string name) => ((SolidColorBrush)tokens[name]).Color;
        bar.ButtonBackgroundColor = bar.ButtonInactiveBackgroundColor = Microsoft.UI.Colors.Transparent;
        bar.ButtonForegroundColor = bar.ButtonHoverForegroundColor = bar.ButtonPressedForegroundColor = Token("GarageInkBrush");
        bar.ButtonInactiveForegroundColor = Token("GarageInkFaintBrush");
        bar.ButtonHoverBackgroundColor = Token("GarageSurfaceSunkenBrush");
        bar.ButtonPressedBackgroundColor = Token("GarageLineBrush");
    }

    // ---- Size (MainWindowSizing): effective pixels there, physical pixels in AppWindow.

    // The window, its display's work area and its title bar and borders, in effective pixels.
    private readonly record struct Geometry(WindowFrame Current, WindowFrame Visible, WindowSize Chrome, double Scale);

    private Geometry Measure()
    {
        uint dpi = GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this));
        double scale = dpi == 0 ? 1 : dpi / 96.0;
        RectInt32 work = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Nearest).WorkArea;
        PointInt32 position = AppWindow.Position;
        SizeInt32 size = AppWindow.Size;
        SizeInt32 client = AppWindow.ClientSize;
        return new Geometry(
            new WindowFrame(position.X, position.Y, size.Width, size.Height).Scaled(1 / scale),
            new WindowFrame(work.X, work.Y, work.Width, work.Height).Scaled(1 / scale),
            new WindowSize((size.Width - client.Width) / scale, (size.Height - client.Height) / scale),
            scale);
    }

    private void Place(WindowFrame frame, double scale)
    {
        WindowFrame physical = frame.Scaled(scale);
        AppWindow.MoveAndResize(new RectInt32(
            (int)Math.Round(physical.X), (int)Math.Round(physical.Y), (int)Math.Round(physical.Width), (int)Math.Round(physical.Height)));
    }

    // The assistant's size or the working size, centred on the display the window opens on.
    private void OpenAtInitialSize(bool assistant)
    {
        Geometry geometry = Measure();
        WindowSize content = assistant ? MainWindowSizing.AssistantSize : MainWindowSizing.WorkingSize;
        Place(MainWindowSizing.InitialFrame(content.Plus(geometry.Chrome), geometry.Visible), geometry.Scale);
        ApplyMinimumSize();
    }

    // The Mac's: to the assistant's size when it opens, and up to the working size when it closes.
    private void ResizeForFirstRun(bool active)
    {
        if (AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Maximized })
        {
            return;
        }
        Geometry geometry = Measure();
        WindowFrame? frame = active
            ? MainWindowSizing.FrameForFirstRun(geometry.Current, geometry.Visible, MainWindowSizing.AssistantSize.Plus(geometry.Chrome))
            : MainWindowSizing.FrameAfterFirstRun(geometry.Current, geometry.Visible, MainWindowSizing.WorkingSize.Plus(geometry.Chrome));
        if (frame is { } target)
        {
            Place(target, geometry.Scale);
        }
    }

    private void ApplyMinimumSize()
    {
        if (AppWindow.Presenter is not OverlappedPresenter presenter)
        {
            return;
        }
        Geometry geometry = Measure();
        WindowSize minimum = MainWindowSizing.MinimumFrame(MainWindowSizing.MinimumSize.Plus(geometry.Chrome), geometry.Visible);
        presenter.PreferredMinimumWidth = (int)Math.Ceiling(minimum.Width * geometry.Scale);
        presenter.PreferredMinimumHeight = (int)Math.Ceiling(minimum.Height * geometry.Scale);
    }

    [LibraryImport("user32.dll")]
    private static partial uint GetDpiForWindow(nint window);

    private void ShowFirstRun(bool active)
    {
        FirstRunHost.Visibility = active ? Microsoft.UI.Xaml.Visibility.Visible : Microsoft.UI.Xaml.Visibility.Collapsed;
        Nav.Visibility = active ? Microsoft.UI.Xaml.Visibility.Collapsed : Microsoft.UI.Xaml.Visibility.Visible;
        if (!active)
        {
            // Back from the assistant: show the pages it changed as they are now.
            Refresh();
        }
    }

    /// <summary>F5: reads the current page again, as navigating back to it does.</summary>
    public void Refresh()
    {
        if (ContentFrame.CurrentSourcePageType is { } page)
        {
            ContentFrame.Navigate(page, _pages, new SuppressNavigationTransitionInfo());
            ContentFrame.BackStack.Clear();
        }
    }

    /// <summary>The jump list's Add Source: the Sources page with its dialog open.</summary>
    public void OpenAddSource()
    {
        Select(AppSection.Sources);
        if (ContentFrame.Content is SourcesPage page)
        {
            page.OpenAddSourceWhenLoaded();
        }
    }

    /// <summary>Report a Bug, over the window.</summary>
    public async Task ShowBugReportAsync()
    {
        if (Content.XamlRoot is { } root)
        {
            await Dialogs.BugReportDialog.ShowAsync(root, await _pages.NewBugReportAsync().ConfigureAwait(true)).ConfigureAwait(true);
        }
    }

    /// <summary>Lets the next close really close (Quit).</summary>
    internal void AllowClose() => _allowClose = true;

    /// <summary>Shows the window if hidden and brings it to the front.</summary>
    internal void ShowAndActivate()
    {
        AppWindow.Show();
        Activate();
    }

    private void OnClosing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (!_allowClose)
        {
            args.Cancel = true;
            sender.Hide();
        }
    }

    private void BuildNavigation()
    {
        Nav.MenuItems.Add(Item(AppSections.Top));
        foreach (SidebarGroup group in AppSections.Groups)
        {
            Nav.MenuItems.Add(new NavigationViewItemHeader { Content = group.Title() });
            foreach (AppSection section in AppSections.SectionsIn(group))
            {
                Nav.MenuItems.Add(Item(section));
            }
        }
    }

    private static NavigationViewItem Item(AppSection section) => new()
    {
        Content = section.Title(),
        Tag = section,
        Icon = new FontIcon { Glyph = SectionGlyphs.For(section) },
    };

    // Ctrl+1…9 open the pages in navigation order (the Mac's Cmd+number); Ctrl+, opens Settings.
    private void AddShortcuts()
    {
        for (int number = 1; number <= AppSections.NavigationOrder.Count; number++)
        {
            AppSection section = AppSections.ForShortcut(number)!.Value;
            var accelerator = new KeyboardAccelerator { Modifiers = VirtualKeyModifiers.Control, Key = VirtualKey.Number0 + number };
            accelerator.Invoked += (_, e) =>
            {
                Select(section);
                e.Handled = true;
            };
            Nav.KeyboardAccelerators.Add(accelerator);
        }

        // F5 reads the current page again; Ctrl+F goes to Search, with the cursor in its field.
        var refresh = new KeyboardAccelerator { Key = VirtualKey.F5 };
        refresh.Invoked += (_, e) =>
        {
            Refresh();
            e.Handled = true;
        };
        Nav.KeyboardAccelerators.Add(refresh);
        var find = new KeyboardAccelerator { Modifiers = VirtualKeyModifiers.Control, Key = VirtualKey.F };
        find.Invoked += (_, e) =>
        {
            Select(AppSection.Search);
            e.Handled = true;
        };
        Nav.KeyboardAccelerators.Add(find);

        var settings = new KeyboardAccelerator { Modifiers = VirtualKeyModifiers.Control, Key = (VirtualKey)188 };
        settings.Invoked += (_, e) =>
        {
            Nav.SelectedItem = Nav.SettingsItem;
            e.Handled = true;
        };
        Nav.KeyboardAccelerators.Add(settings);
    }

    /// <summary>Shows <paramref name="section"/>, as picking it in the sidebar does.</summary>
    public void Select(AppSection section)
    {
        NavigationViewItem item = Nav.MenuItems.OfType<NavigationViewItem>().First(item => item.Tag is AppSection s && s == section);
        if (ReferenceEquals(Nav.SelectedItem, item))
        {
            Refresh();
        }
        else
        {
            Nav.SelectedItem = item;
        }
    }

    /// <summary>Shows Settings.</summary>
    public void SelectSettings() => Nav.SelectedItem = Nav.SettingsItem;

    private void OnSelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.IsSettingsSelected)
        {
            ContentFrame.Navigate(typeof(SettingsPage), _pages);
        }
        else if (args.SelectedItem is NavigationViewItem { Tag: AppSection section })
        {
            _ = section switch
            {
                AppSection.Status => ContentFrame.Navigate(typeof(StatusPage), _pages),
                AppSection.Sources => ContentFrame.Navigate(typeof(SourcesPage), _pages),
                AppSection.Models => ContentFrame.Navigate(typeof(ModelsPage), _pages),
                AppSection.Mcp => ContentFrame.Navigate(typeof(McpPage), _pages),
                AppSection.Search => ContentFrame.Navigate(typeof(SearchPage), _pages),
                AppSection.Documents => ContentFrame.Navigate(typeof(DocumentsPage), _pages),
                AppSection.Facts => ContentFrame.Navigate(typeof(FactsPage), _pages),
                AppSection.Database => ContentFrame.Navigate(typeof(DatabasePage), _pages),
                AppSection.Logs => ContentFrame.Navigate(typeof(LogsPage), _pages),
                _ => ContentFrame.Navigate(typeof(StatusPage), _pages),
            };
        }
    }
}

/// <summary>Segoe Fluent Icons glyphs standing in for the Mac's SF Symbols.</summary>
internal static class SectionGlyphs
{
    public static string For(AppSection section) => section switch
    {
        AppSection.Status => "",     // Diagnostic   (gauge)
        AppSection.Sources => "",    // Folder       (tray.and.arrow.down)
        AppSection.Models => "",     // Component    (cpu)
        AppSection.Mcp => "",        // Connect      (server.rack)
        AppSection.Documents => "",  // Document     (doc.text.magnifyingglass)
        AppSection.Facts => "",      // Lightbulb    (lightbulb)
        AppSection.Search => "",     // Search       (magnifyingglass)
        AppSection.Database => "",   // Library      (cylinder.split.1x2)
        AppSection.Logs => "",       // CommandPrompt (terminal)
        _ => "",
    };
}

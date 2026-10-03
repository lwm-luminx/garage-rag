using System.ComponentModel;
using Garage.App.Core.Library;
using Garage.App.Core.Navigation;
using Garage.App.Core.Presentation;
using Garage.App.Core.Services;
using Garage.App.Core.State;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;

namespace Garage.App.Pages;

/// <summary>
/// The Status page: the backend connection, the Library box with Update Everything or Stop, Automatic
/// Updates, and the Services box. Wording comes from Core (<see cref="ConnectionPresentation"/>,
/// <see cref="LibraryPresentation"/>, <see cref="ServiceRowPresentation"/>).
/// </summary>
public sealed partial class StatusPage : Page
{
    private readonly Dictionary<string, ServiceRowView> _rows = new(StringComparer.Ordinal);
    private readonly HashSet<string> _expanded = new(StringComparer.Ordinal);
    private PageModels? _pages;
    private bool _showing;

    /// <summary>Creates the page.</summary>
    public StatusPage() => InitializeComponent();

    private StatusViewModel Model => _pages!.Status;

    /// <inheritdoc/>
    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        ArgumentNullException.ThrowIfNull(e);
        _pages = (PageModels)e.Parameter;
        _pages.State.PropertyChanged += OnChanged;
        Model.PropertyChanged += OnChanged;
        Model.Library.PropertyChanged += OnChanged;
        Model.Services.CollectionChanged += OnServicesChanged;
        IntervalBox.ItemsSource = LibraryCoordinator.Intervals.Select(IntervalTitle).ToList();
        ShowConnection();
        ShowLibrary();
        ShowAutomaticUpdates();
        ShowServices();
        _ = Model.LoadAsync();
    }

    /// <inheritdoc/>
    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        if (_pages is null)
        {
            return;
        }
        _pages.State.PropertyChanged -= OnChanged;
        Model.PropertyChanged -= OnChanged;
        Model.Library.PropertyChanged -= OnChanged;
        Model.Services.CollectionChanged -= OnServicesChanged;
    }

    private void OnChanged(object? sender, PropertyChangedEventArgs e)
    {
        ShowConnection();
        ShowLibrary();
        ShowAutomaticUpdates();
    }

    private void OnServicesChanged(object? sender, System.Collections.Specialized.NotifyCollectionChangedEventArgs e) => ShowServices();

    private void ShowConnection()
    {
        ConnectionPresentation shown = ConnectionPresentation.From(_pages!.State);
        Connection.Title = shown.Title;
        Connection.Message = shown.Detail;
        Connection.Severity = shown.Severity switch
        {
            StatusSeverity.Success => InfoBarSeverity.Success,
            StatusSeverity.Warning => InfoBarSeverity.Warning,
            StatusSeverity.Error => InfoBarSeverity.Error,
            _ => InfoBarSeverity.Informational,
        };
        RefreshButton.IsEnabled = _pages.State.Connection != BackendConnection.Connecting;
    }

    private void ShowLibrary()
    {
        LibraryHeadline headline = Model.Headline;
        LibraryCircle.Background = headline.IsActive ? Look.TintBrush(headline.Tint) : Look.TintBrush(Tint.Secondary);
        LibraryGlyph.Glyph = Look.StatusGlyph(headline.Symbol);
        if (LibraryTitle.Text != headline.Title)
        {
            LibraryTitle.Text = headline.Title;
            // Narrator reads the change ("Reading notes", "Up to date") without the person moving focus.
            Microsoft.UI.Xaml.Automation.Peers.FrameworkElementAutomationPeer.FromElement(LibraryTitle)?
                .RaiseAutomationEvent(Microsoft.UI.Xaml.Automation.Peers.AutomationEvents.LiveRegionChanged);
        }
        LibraryPercent.Text = headline.Percent ?? "";
        LibraryBar.Visibility = headline.Progress is not null || headline.IsIndeterminate ? Visibility.Visible : Visibility.Collapsed;
        LibraryBar.IsIndeterminate = headline.IsIndeterminate;
        LibraryBar.Value = headline.Progress ?? 0;
        LibraryDetail.Text = headline.Detail ?? "";
        LibraryDetail.Foreground = headline.DetailIsError
            ? Look.TintBrush(Tint.Red)
            : (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
        LibraryItem.Text = headline.CurrentItem ?? "";
        LibraryItem.Visibility = headline.CurrentItem is null ? Visibility.Collapsed : Visibility.Visible;
        LibraryTrail.Text = Model.IsRunning && Model.Library.Stage is { } stage ? Trail(stage) : "";
        LibraryTrail.Visibility = LibraryTrail.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;

        UpdateEverythingButton.Visibility = Model.Action == LibraryAction.UpdateEverything ? Visibility.Visible : Visibility.Collapsed;
        UpdateEverythingButton.IsEnabled = Model.CanUpdateEverything;
        if (Model.Library.IngestUnavailable is { } why)
        {
            ToolTipService.SetToolTip(UpdateEverythingButton, why);
        }
        StopButton.Visibility = Model.Action == LibraryAction.Stop ? Visibility.Visible : Visibility.Collapsed;
        StopButton.IsEnabled = !Model.IsStopping;
        StopText.Text = Model.IsStopping ? "Stopping…" : "Stop";
        AddSourceButton.Visibility = Model.Action == LibraryAction.AddSource ? Visibility.Visible : Visibility.Collapsed;
    }

    // "Scan › Read › Index › Glean", the current step in brackets.
    private static string Trail(LibraryStage current) => string.Join(" › ",
        Enum.GetValues<LibraryStage>().Select(stage => stage == current ? $"[{stage}]" : stage.ToString()));

    private void ShowAutomaticUpdates()
    {
        LibraryCoordinator library = Model.Library;
        _showing = true;
        AutomaticSwitch.IsOn = library.AutomaticUpdatesEnabled;
        int index = LibraryCoordinator.Intervals.ToList().IndexOf(library.AutomaticUpdatesInterval);
        IntervalBox.SelectedIndex = index >= 0 ? index : 1;
        IntervalBox.IsEnabled = library.AutomaticUpdatesEnabled;
        AtLaunchBox.IsChecked = library.RunsAtLaunch;
        AtLaunchBox.IsEnabled = library.AutomaticUpdatesEnabled;
        _showing = false;
    }

    private static string IntervalTitle(TimeSpan interval) =>
        interval.TotalHours >= 1 ? (interval.TotalHours == 1 ? "hour" : $"{interval.TotalHours:0} hours") : $"{interval.TotalMinutes:0} minutes";

    private void ShowServices()
    {
        ServicesSection.Visibility = Model.HasServices ? Visibility.Visible : Visibility.Collapsed;
        DevBackendNote.Visibility = Model.HasServices ? Visibility.Collapsed : Visibility.Visible;
        foreach (ServiceRowPresentation row in Model.Services)
        {
            if (!_rows.TryGetValue(row.Id, out ServiceRowView? view))
            {
                view = new ServiceRowView(row.Id, this);
                _rows[row.Id] = view;
                if (ServiceRows.Children.Count > 0)
                {
                    ServiceRows.Children.Add(new MenuFlyoutSeparator { Margin = new Thickness(0, 4, 0, 4) });
                }
                ServiceRows.Children.Add(view.Root);
            }
            view.Show(row, Model.SelfTests(row.Id), _expanded.Contains(row.Id));
        }
    }

    private void Toggle(string id)
    {
        if (!_expanded.Remove(id))
        {
            _expanded.Add(id);
        }
        ShowServices();
    }

    private async void OnRefresh(object sender, RoutedEventArgs e)
    {
        await _pages!.State.RefreshAsync().ConfigureAwait(true);
        await Model.LoadAsync().ConfigureAwait(true);
    }

    private async void OnUpdateEverything(object sender, RoutedEventArgs e) => await Model.UpdateEverythingAsync().ConfigureAwait(true);

    private void OnStop(object sender, RoutedEventArgs e) => Model.Stop();

    private void OnAddSource(object sender, RoutedEventArgs e) => App.Current?.ShowSection(AppSection.Sources);

    private void OnAutomaticToggled(object sender, RoutedEventArgs e)
    {
        if (!_showing)
        {
            Model.Library.AutomaticUpdatesEnabled = AutomaticSwitch.IsOn;
        }
    }

    private void OnIntervalChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_showing && IntervalBox.SelectedIndex >= 0)
        {
            Model.Library.AutomaticUpdatesInterval = LibraryCoordinator.Intervals[IntervalBox.SelectedIndex];
        }
    }

    private void OnAtLaunchClicked(object sender, RoutedEventArgs e) => Model.Library.RunsAtLaunch = AtLaunchBox.IsChecked == true;

    private async void OnTestAll(object sender, RoutedEventArgs e)
    {
        foreach (ServiceRowPresentation row in Model.Services)
        {
            _expanded.Add(row.Id);
        }
        await Model.TestAllAsync().ConfigureAwait(true);
        ShowServices();
    }

    private async void OnRefreshServices(object sender, RoutedEventArgs e) => await Model.RefreshServicesAsync().ConfigureAwait(true);

    /// <summary>One service's row: its state, Test, Restart, and the self tests under it.</summary>
    private sealed class ServiceRowView
    {
        private readonly Border _dot = new() { Width = 9, Height = 9, CornerRadius = new CornerRadius(4.5), BorderThickness = new Thickness(1.5) };
        private readonly ProgressRing _ring = new() { Width = 14, Height = 14, IsActive = true };
        private readonly TextBlock _name = new() { FontWeight = Microsoft.UI.Text.FontWeights.SemiBold };
        private readonly TextBlock _detail = new() { TextWrapping = TextWrapping.Wrap, FontSize = 12, IsTextSelectionEnabled = true };
        private readonly Button _test = new() { Content = new FontIcon { Glyph = "", FontSize = 14 } };
        private readonly Button _restart = new() { Content = new FontIcon { Glyph = "", FontSize = 14 } };
        private readonly Button _toggle = new() { Content = new FontIcon { Glyph = "", FontSize = 12 } };
        private readonly StackPanel _details = new() { Spacing = 4, Margin = new Thickness(26, 6, 0, 4) };

        public ServiceRowView(string id, StatusPage page)
        {
            AutomationProperties_Set(_test, $"status.service.{id}.test", "Test");
            AutomationProperties_Set(_restart, $"status.service.{id}.restart", "Restart");
            AutomationProperties_Set(_toggle, $"status.service.{id}.details", "Details");
            ToolTipService.SetToolTip(_test, Strings.Get("Code_StatusPage_RunThisServiceSSelfTests"));
            ToolTipService.SetToolTip(_restart, Strings.Get("Code_StatusPage_StopTheProcessAndStartIt"));
            _test.Click += async (_, _) =>
            {
                page._expanded.Add(id);
                _test.IsEnabled = false;
                await page.Model.TestAsync(id).ConfigureAwait(true);
                _test.IsEnabled = true;
                page.ShowServices();
            };
            _restart.Click += async (_, _) => await page.Model.RestartAsync(id).ConfigureAwait(true);
            _toggle.Click += (_, _) => page.Toggle(id);

            var header = new Grid { ColumnSpacing = 10 };
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(16) });
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var indicator = new Grid { VerticalAlignment = VerticalAlignment.Center };
            indicator.Children.Add(_dot);
            indicator.Children.Add(_ring);
            header.Children.Add(indicator);
            var text = new StackPanel { Spacing = 2 };
            text.Children.Add(_name);
            text.Children.Add(_detail);
            Grid.SetColumn(text, 1);
            header.Children.Add(text);
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
            actions.Children.Add(_test);
            actions.Children.Add(_restart);
            actions.Children.Add(_toggle);
            Grid.SetColumn(actions, 2);
            header.Children.Add(actions);

            Root = new StackPanel { Padding = new Thickness(0, 6, 0, 6) };
            AutomationProperties_Set(Root, $"status.service.{id}", null);
            Root.Children.Add(header);
            Root.Children.Add(_details);
        }

        public StackPanel Root { get; }

        public void Show(ServiceRowPresentation row, IReadOnlyList<SelfTestLine> tests, bool expanded)
        {
            _ring.Visibility = row.IsBusy ? Visibility.Visible : Visibility.Collapsed;
            _dot.Visibility = row.IsBusy ? Visibility.Collapsed : Visibility.Visible;
            Brush tint = Look.TintBrush(row.Tint);
            _dot.BorderBrush = tint;
            _dot.Background = row.IsActive ? tint : null;
            _name.Text = row.Name;
            _detail.Text = row.Detail;
            _detail.Foreground = row.DetailIsError ? Look.TintBrush(Tint.Red) : (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
            _test.IsEnabled = row.State == ServiceState.Running;
            _restart.IsEnabled = !row.IsBusy;
            _restart.Foreground = row.RestartTint is { } restart ? Look.TintBrush(restart) : (Brush)Application.Current.Resources["TextFillColorPrimaryBrush"];
            ((FontIcon)_toggle.Content).Glyph = expanded ? "" : "";

            _details.Visibility = expanded ? Visibility.Visible : Visibility.Collapsed;
            _details.Children.Clear();
            _details.Children.Add(new TextBlock
            {
                Text = ServiceRowPresentation.RoleFor(row.Id),
                TextWrapping = TextWrapping.Wrap,
                FontSize = 12,
                Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
            });
            if (tests.Count == 0)
            {
                _details.Children.Add(new TextBlock { Text = Strings.Get("Code_StatusPage_TestRunsTheServiceSSelf"), FontSize = 12 });
            }
            foreach (SelfTestLine test in tests)
            {
                var line = new Grid { ColumnSpacing = 8 };
                line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(180) });
                line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                var name = new TextBlock { Text = test.Name, FontSize = 12, Foreground = Look.TintBrush(test.Tint) };
                var summary = new TextBlock { Text = test.Summary, FontSize = 12, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
                var duration = new TextBlock { Text = test.Duration, FontSize = 12, Foreground = (Brush)Application.Current.Resources["TextFillColorTertiaryBrush"] };
                Grid.SetColumn(summary, 1);
                Grid.SetColumn(duration, 2);
                line.Children.Add(name);
                line.Children.Add(summary);
                line.Children.Add(duration);
                _details.Children.Add(line);
            }
        }

        private static void AutomationProperties_Set(UIElement element, string id, string? name)
        {
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(element, id);
            if (name is not null)
            {
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(element, name);
            }
        }
    }
}

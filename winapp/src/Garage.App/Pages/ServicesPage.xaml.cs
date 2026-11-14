using System.Collections.Specialized;
using Garage.App.Core.Presentation;
using Garage.App.Core.Services;
using Garage.App.Core.State;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;

namespace Garage.App.Pages;

/// <summary>
/// The Services page (Advanced): one row per service process, with its state, Test, Restart and its self
/// tests, plus Test All and Restart All. The Mac's <c>ServicesView</c>; the rows come from
/// <see cref="StatusViewModel.Services"/> (<see cref="ServiceRowPresentation"/>), and the Status page names a
/// service only when it needs attention.
/// </summary>
public sealed partial class ServicesPage : Page
{
    private readonly Dictionary<string, ServiceRowView> _rows = new(StringComparer.Ordinal);
    private readonly HashSet<string> _expanded = new(StringComparer.Ordinal);
    private PageModels? _pages;

    /// <summary>Creates the page.</summary>
    public ServicesPage() => InitializeComponent();

    private StatusViewModel Model => _pages!.Status;

    /// <inheritdoc/>
    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        ArgumentNullException.ThrowIfNull(e);
        _pages = (PageModels)e.Parameter;
        Model.Services.CollectionChanged += OnServicesChanged;
        ShowServices();
    }

    /// <inheritdoc/>
    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        if (_pages is not null)
        {
            Model.Services.CollectionChanged -= OnServicesChanged;
        }
    }

    private void OnServicesChanged(object? sender, NotifyCollectionChangedEventArgs e) => ShowServices();

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

    private async void OnRestartAll(object sender, RoutedEventArgs e)
    {
        RestartAllButton.IsEnabled = false;
        try
        {
            await Model.RestartAllAsync().ConfigureAwait(true);
        }
        finally
        {
            RestartAllButton.IsEnabled = true;
        }
    }

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

        public ServiceRowView(string id, ServicesPage page)
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

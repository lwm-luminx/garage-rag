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
/// The Status page: the backend connection, the services that need attention (the rows themselves are on
/// the Services page), the Library box with Update Everything or Stop, and Automatic Updates. Wording comes
/// from Core (<see cref="ConnectionPresentation"/>, <see cref="ServiceIssues"/>, <see cref="LibraryPresentation"/>).
/// </summary>
public sealed partial class StatusPage : Page
{
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
        IntervalBox.ItemsSource = LibraryCoordinator.Intervals.Select(IntervalTitle).ToList();
        ShowConnection();
        ShowLibrary();
        ShowAutomaticUpdates();
        ShowServiceIssues();
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
    }

    private void OnChanged(object? sender, PropertyChangedEventArgs e)
    {
        ShowConnection();
        ShowLibrary();
        ShowAutomaticUpdates();
        ShowServiceIssues();
    }

    private void ShowServiceIssues()
    {
        IReadOnlyList<ServiceIssue> issues = Model.ServiceProblems;
        ServiceIssuesBar.IsOpen = issues.Count > 0;
        ServiceIssuesBar.Title = ServiceIssues.Title(issues);
        ServiceIssuesBar.Message = ServiceIssues.Message(issues);
        ServiceIssuesBar.Severity = ServiceIssues.Severity(issues) == StatusSeverity.Error ? InfoBarSeverity.Error : InfoBarSeverity.Warning;
    }

    private void OnShowServices(object sender, RoutedEventArgs e) => App.Current?.ShowSection(AppSection.Services);

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
}

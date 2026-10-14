using System.ComponentModel;
using Garage.App.Core.Logging;
using Garage.App.Core.Operations;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

namespace Garage.App.Pages;

/// <summary>The Logs page (the Mac's <c>LogsView</c>): a buffer, text and level filters, and the status bar.</summary>
public sealed partial class LogsPage : Page
{
    private PageModels _pages = null!;
    private LogsViewModel _model = null!;
    private bool _loading;

    /// <summary>Creates the page.</summary>
    public LogsPage() => InitializeComponent();

    /// <inheritdoc/>
    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        ArgumentNullException.ThrowIfNull(e);
        _pages = (PageModels)e.Parameter;
        _model = _pages.Logs;
        _loading = true;
        SourceBox.ItemsSource = _model.Sources;
        SourceBox.SelectedItem = _model.Source;
        FilterBox.Text = _model.SearchText;
        LevelBox.ItemsSource = _model.Levels.Select(l => l.Title()).ToList();
        LevelBox.SelectedIndex = _model.Levels.ToList().IndexOf(_model.Level);
        NewestFirstToggle.IsChecked = _model.NewestFirst;
        Rows.ItemsSource = _model.Rows;
        _loading = false;
        _model.PropertyChanged += OnModelChanged;
        _model.Recompute();
        Show();
    }

    /// <inheritdoc/>
    protected override void OnNavigatedFrom(NavigationEventArgs e) => _model.PropertyChanged -= OnModelChanged;

    private void OnSourceChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_loading && SourceBox.SelectedItem is LogBuffer buffer)
        {
            _model.Source = buffer;
        }
    }

    private void OnFilterChanged(object sender, TextChangedEventArgs e)
    {
        if (!_loading)
        {
            _model.SearchText = FilterBox.Text;
        }
    }

    private void OnLevelChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_loading && LevelBox.SelectedIndex >= 0)
        {
            _model.Level = _model.Levels[LevelBox.SelectedIndex];
        }
    }

    private void OnNewestFirst(object sender, RoutedEventArgs e) => _model.NewestFirst = NewestFirstToggle.IsChecked == true;

    // With rows selected, copy those; otherwise every row shown (as the Mac's Copy does).
    private void OnCopy(object sender, RoutedEventArgs e)
    {
        List<LogLine> selected = [.. Rows.SelectedItems.OfType<LogLine>()];
        Clipboard.Copy(selected.Count > 0
            ? string.Join(Environment.NewLine, selected.Select(line => $"{line.Time}  {line.LevelName,-7}  {line.Source}  {line.Text}"))
            : _model.CopyText());
    }

    private void OnClear(object sender, RoutedEventArgs e) => _model.Clear();

    // Report a Bug with this source's recent lines attached (read them in the preview before sending).
    private async void OnReportBug(object sender, RoutedEventArgs e)
    {
        if (_pages.ReportBug is { } report)
        {
            string? source = _model.Source?.Source;
            await report(bug =>
            {
                bug.IncludeLogs = true;
                if (source is not null && bug.LogSources.Contains(source))
                {
                    bug.LogSource = source;
                }
            }).ConfigureAwait(true);
        }
    }

    // One row selected: the inspector shows it in full.
    private void OnRowsSelected(object sender, SelectionChangedEventArgs e)
    {
        if (Rows.SelectedItems.Count == 1 && Rows.SelectedItem is LogLine line)
        {
            Inspector.Visibility = Visibility.Visible;
            DetailMeta.Text = $"{line.Timestamp.LocalDateTime:yyyy-MM-dd HH:mm:ss.fff} · {line.LevelName} · {line.Source} · {line.Channel.Name()}";
            DetailText.Text = line.Text;
        }
        else
        {
            Inspector.Visibility = Visibility.Collapsed;
        }
    }

    private void OnCloseDetails(object sender, RoutedEventArgs e)
    {
        Inspector.Visibility = Visibility.Collapsed;
        Rows.SelectedItems.Clear();
    }

    private void OnCopyDetail(object sender, RoutedEventArgs e) => Clipboard.Copy(DetailText.Text);

    private void OnModelChanged(object? sender, PropertyChangedEventArgs e) => Show();

    private void Show() => CountText.Text = _model.CountText;
}

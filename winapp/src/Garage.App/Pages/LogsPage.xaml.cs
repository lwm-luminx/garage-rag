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
    private LogsViewModel _model = null!;
    private bool _loading;

    /// <summary>Creates the page.</summary>
    public LogsPage() => InitializeComponent();

    /// <inheritdoc/>
    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        ArgumentNullException.ThrowIfNull(e);
        _model = ((PageModels)e.Parameter).Logs;
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

    private void OnModelChanged(object? sender, PropertyChangedEventArgs e) => Show();

    private void Show() => CountText.Text = _model.CountText;
}

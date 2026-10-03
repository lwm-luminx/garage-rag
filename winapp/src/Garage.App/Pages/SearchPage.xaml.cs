using System.ComponentModel;
using Garage.App.Core.Search;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Navigation;
using Windows.System;

namespace Garage.App.Pages;

/// <summary>The Search page (the Mac's <c>SearchView</c>): query, mode, limit, filters, results and an inspector.</summary>
public sealed partial class SearchPage : Page
{
    private SearchViewModel _model = null!;
    private bool _loading;

    /// <summary>Creates the page.</summary>
    public SearchPage() => InitializeComponent();

    /// <inheritdoc/>
    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        ArgumentNullException.ThrowIfNull(e);
        _model = ((PageModels)e.Parameter).Search;
        _loading = true;
        QueryBox.Text = _model.Query;
        ModeBox.ItemsSource = SearchMode.All;
        ModeBox.SelectedItem = _model.Mode;
        LimitBox.Value = _model.Limit;
        ClassBox.ItemsSource = _model.CorpusClasses;
        TrustBox.ItemsSource = _model.TrustTiers;
        SourceBox.ItemsSource = _model.Sources;
        SelectFilters();
        ResultsList.ItemsSource = _model.Results;
        ResultsList.SelectedItem = _model.SelectedResult;
        _loading = false;
        _model.PropertyChanged += OnModelChanged;
        Show();
        _ = LoadSourcesAsync();
        QueryBox.Focus(FocusState.Programmatic);
    }

    /// <inheritdoc/>
    protected override void OnNavigatedFrom(NavigationEventArgs e) => _model.PropertyChanged -= OnModelChanged;

    private async Task LoadSourcesAsync()
    {
        string selected = _model.Source;
        await _model.LoadSourcesAsync().ConfigureAwait(true);
        _loading = true;
        SourceBox.SelectedItem = _model.Sources.Contains(selected) ? selected : _model.Sources[0];
        _loading = false;
    }

    private void SelectFilters()
    {
        ClassBox.SelectedItem = _model.CorpusClass;
        TrustBox.SelectedItem = _model.TrustTier;
        SourceBox.SelectedItem = _model.Source;
    }

    private async void OnSearch(object sender, RoutedEventArgs e)
    {
        _model.Query = QueryBox.Text;
        await _model.SearchAsync().ConfigureAwait(true);
        ResultsList.SelectedItem = _model.SelectedResult;
    }

    private void OnQueryKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Enter)
        {
            e.Handled = true;
            OnSearch(sender, e);
        }
    }

    private void OnModeChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_loading && ModeBox.SelectedItem is SearchMode mode)
        {
            _model.Mode = mode;
        }
    }

    private void OnLimitChanged(NumberBox sender, NumberBoxValueChangedEventArgs args)
    {
        if (!_loading && !double.IsNaN(args.NewValue))
        {
            _model.Limit = Math.Clamp((int)args.NewValue, SearchViewModel.MinLimit, SearchViewModel.MaxLimit);
        }
    }

    private void OnFilterChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading)
        {
            return;
        }
        _model.CorpusClass = ClassBox.SelectedItem as string ?? _model.CorpusClass;
        _model.TrustTier = TrustBox.SelectedItem as string ?? _model.TrustTier;
        _model.Source = SourceBox.SelectedItem as string ?? _model.Source;
    }

    private void OnResetFilters(object sender, RoutedEventArgs e)
    {
        _model.ResetFilters();
        _loading = true;
        SelectFilters();
        _loading = false;
    }

    private void OnResultSelected(object sender, SelectionChangedEventArgs e) =>
        _model.SelectedResult = ResultsList.SelectedItem as SearchResultItem;

    private void OnModelChanged(object? sender, PropertyChangedEventArgs e) => Show();

    private void Show()
    {
        StatusBar.Text = _model.StatusText;
        SearchButton.IsEnabled = !_model.IsSearching;

        if (_model.EmptyState is { } empty)
        {
            EmptyPanel.Visibility = Visibility.Visible;
            ResultsList.Visibility = Visibility.Collapsed;
            EmptyTitle.Text = empty.Title;
            EmptyDetail.Text = empty.Detail;
            RetryButton.Visibility = _model.ErrorMessage is null ? Visibility.Collapsed : Visibility.Visible;
        }
        else
        {
            EmptyPanel.Visibility = Visibility.Collapsed;
            ResultsList.Visibility = Visibility.Visible;
        }

        SearchResultItem? hit = _model.SelectedResult;
        Inspector.Visibility = hit is null ? Visibility.Collapsed : Visibility.Visible;
        if (hit is null)
        {
            return;
        }
        HitTitle.Text = hit.DisplayTitle;
        HitScore.Text = $"Rank #{hit.Rank} • {hit.ScoreText}";
        HitTags.Text = string.Join("  ·  ", new[] { $"Matched: {hit.MatchedBy}", hit.CorpusClass, hit.TrustTier }.Where(t => t.Length > 0));
        HeadingPanel.Visibility = hit.HeadingPath.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        HitHeading.Text = hit.HeadingPath;
        AuthorsPanel.Visibility = hit.Authors.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        HitAuthors.Text = hit.AuthorsList;
        HitUri.Text = hit.Uri;
        SnippetPanel.Visibility = hit.HasDistinctSnippet ? Visibility.Visible : Visibility.Collapsed;
        HitSnippet.Text = hit.Snippet;
        HitContent.Text = hit.Content;
    }

    private void OnCopyUri(object sender, RoutedEventArgs e) => Clipboard.Copy(_model.SelectedResult?.Uri);

    private void OnCopyContent(object sender, RoutedEventArgs e) => Clipboard.Copy(_model.SelectedResult?.Content);
}

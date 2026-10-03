using System.ComponentModel;
using System.Globalization;
using Garage.App.Core.Documents;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Navigation;
using Windows.System;

namespace Garage.App.Pages;

/// <summary>The Documents page (the Mac's <c>DocumentsView</c>): filters, the list and the selected document's chunks.</summary>
public sealed partial class DocumentsPage : Page
{
    private DocumentsViewModel _model = null!;
    private bool _loading;

    /// <summary>Creates the page.</summary>
    public DocumentsPage() => InitializeComponent();

    /// <inheritdoc/>
    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        ArgumentNullException.ThrowIfNull(e);
        _model = ((PageModels)e.Parameter).Documents;
        _loading = true;
        FilterBox.Text = _model.SearchText;
        SourceBox.ItemsSource = _model.Sources;
        ClassBox.ItemsSource = _model.CorpusClasses;
        TrustBox.ItemsSource = _model.TrustTiers;
        SourceBox.SelectedItem = _model.Source;
        ClassBox.SelectedItem = _model.CorpusClass;
        TrustBox.SelectedItem = _model.TrustTier;
        DocumentsList.ItemsSource = _model.Documents;
        DocumentsList.ContainerContentChanging -= OnRowRealized;
        DocumentsList.ContainerContentChanging += OnRowRealized;
        DocumentsList.SelectedItem = _model.Selected;
        _loading = false;
        _model.PropertyChanged += OnModelChanged;
        Show();

        string source = _model.Source;
        await _model.LoadSourcesAsync().ConfigureAwait(true);
        _loading = true;
        SourceBox.SelectedItem = _model.Sources.Contains(source) ? source : _model.Sources[0];
        _loading = false;
        await _model.RefreshAsync().ConfigureAwait(true);
    }

    /// <inheritdoc/>
    protected override void OnNavigatedFrom(NavigationEventArgs e) => _model.PropertyChanged -= OnModelChanged;

    private async void OnFilterChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading)
        {
            return;
        }
        _model.Source = SourceBox.SelectedItem as string ?? _model.Source;
        _model.CorpusClass = ClassBox.SelectedItem as string ?? _model.CorpusClass;
        _model.TrustTier = TrustBox.SelectedItem as string ?? _model.TrustTier;
        await _model.RefreshAsync().ConfigureAwait(true);
    }

    private async void OnFilterKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Enter)
        {
            e.Handled = true;
            _model.SearchText = FilterBox.Text;
            await _model.RefreshAsync().ConfigureAwait(true);
        }
    }

    private async void OnRefresh(object sender, RoutedEventArgs e)
    {
        _model.SearchText = FilterBox.Text;
        await _model.RefreshAsync().ConfigureAwait(true);
    }

    private async void OnDocumentSelected(object sender, SelectionChangedEventArgs e)
    {
        if (_loading || Equals(DocumentsList.SelectedItem, _model.Selected))
        {
            return;
        }
        _model.Selected = DocumentsList.SelectedItem as DocumentListItem;
        await _model.LoadDetailAsync().ConfigureAwait(true);
    }

    private void OnModelChanged(object? sender, PropertyChangedEventArgs e) => Show();

    private void Show()
    {
        CountText.Text = _model.CountText;
        if (_model.EmptyState is { } empty)
        {
            EmptyPanel.Visibility = Visibility.Visible;
            EmptyTitle.Text = empty.Title;
            EmptyDetail.Text = empty.Detail;
        }
        else
        {
            EmptyPanel.Visibility = Visibility.Collapsed;
        }

        DetailProgress.IsActive = _model.IsLoadingDetail;
        Garage.App.Core.Documents.DocumentDetail? detail = _model.Detail;
        Placeholder.Visibility = _model.Selected is null ? Visibility.Visible : Visibility.Collapsed;
        DetailPanel.Visibility = detail is null ? Visibility.Collapsed : Visibility.Visible;
        DetailErrorBar.IsOpen = _model.DetailError is not null || (detail is not null && detail.Error.Length > 0);
        DetailErrorBar.Title = _model.DetailError is not null ? "Failed to Load Document" : "Extraction error";
        DetailErrorBar.Message = _model.DetailError ?? detail?.Error ?? "";
        if (detail is null)
        {
            return;
        }
        DetailTitle.Text = detail.DisplayTitle;
        DetailSummary.Text = detail.Summary;
        DetailUri.Text = detail.Uri;
        DetailExtracted.Text = detail.ExtractedBy;
        DetailAuthors.Text = detail.Authors.Count > 0 ? "By " + string.Join(", ", detail.Authors) : "";
        FactsHeader.Text = string.Create(CultureInfo.CurrentCulture, $"Facts ({detail.Facts.Count:N0})");
        FactsHeader.Visibility = FactsList.Visibility = detail.Facts.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        FactsList.ItemsSource = detail.Facts;
        ChunksHeader.Text = string.Create(CultureInfo.CurrentCulture, $"Chunks ({detail.Chunks.Count:N0})");
        ChunksList.ItemsSource = detail.Chunks;
    }

    // Incremental loading: a row within a screenful of the end asks for the next page.
    private async void OnRowRealized(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (!args.InRecycleQueue && args.ItemIndex >= _model.Documents.Count - 40 && _model.CanLoadMore)
        {
            await _model.LoadMoreAsync().ConfigureAwait(true);
        }
    }
}

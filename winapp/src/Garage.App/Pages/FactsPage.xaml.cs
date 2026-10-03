using System.ComponentModel;
using Garage.App.Core.Corpus;
using Garage.App.Core.Facts;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Navigation;
using Windows.System;

namespace Garage.App.Pages;

/// <summary>The Facts page (the Mac's <c>FactsView</c>): search, filters, the list with Load More, and grounding.</summary>
public sealed partial class FactsPage : Page
{
    private FactsViewModel _model = null!;
    private Garage.App.Core.Operations.OperationRunner _runner = null!;
    private Garage.App.Core.State.INotifier _notifier = null!;
    private bool _loading;

    /// <summary>Creates the page.</summary>
    public FactsPage() => InitializeComponent();

    /// <inheritdoc/>
    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        ArgumentNullException.ThrowIfNull(e);
        var pages = (PageModels)e.Parameter;
        _model = pages.Facts;
        _runner = pages.State.Facts;
        _notifier = pages.State.Notifier;
        _runner.PropertyChanged += OnModelChanged;
        _loading = true;
        SearchBox.Text = _model.SearchText;
        SourceBox.ItemsSource = _model.Sources;
        ClassBox.ItemsSource = _model.CorpusClasses;
        SourceBox.SelectedItem = _model.Source;
        ClassBox.SelectedItem = _model.CorpusClass;
        FillKinds();
        FactsList.ItemsSource = _model.Facts;
        FactsList.SelectedItem = _model.Selected;
        _loading = false;
        _model.PropertyChanged += OnModelChanged;
        Show();

        string source = _model.Source;
        await _model.LoadSourcesAsync().ConfigureAwait(true);
        _loading = true;
        SourceBox.SelectedItem = _model.Sources.Contains(source) ? source : _model.Sources[0];
        _loading = false;
        await RefreshAsync().ConfigureAwait(true);
    }

    /// <inheritdoc/>
    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        _model.PropertyChanged -= OnModelChanged;
        _runner.PropertyChanged -= OnModelChanged;
    }

    private async void OnGlean(object sender, RoutedEventArgs e)
    {
        await _model.GleanAsync(_runner, _notifier).ConfigureAwait(true);
        _loading = true;
        FillKinds();
        _loading = false;
    }

    private void OnStopGlean(object sender, RoutedEventArgs e) => _runner.Cancel();

    private async Task RefreshAsync()
    {
        await _model.RefreshAsync().ConfigureAwait(true);
        _loading = true;
        FillKinds();
        _loading = false;
    }

    // The Kind picker: "all", then the classes on offer under the other filters with their counts.
    private void FillKinds()
    {
        List<KindChoice> kinds = [new(CorpusTaxonomy.All, "all"), .. _model.Classes.Select(c => new KindChoice(c.FactClass, c.Label))];
        if (kinds.All(k => k.Value != _model.FactClass))
        {
            kinds.Add(new(_model.FactClass, _model.FactClass));
        }
        KindBox.ItemsSource = kinds;
        KindBox.DisplayMemberPath = nameof(KindChoice.Label);
        KindBox.SelectedItem = kinds.First(k => k.Value == _model.FactClass);
    }

    private async void OnFilterChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading)
        {
            return;
        }
        _model.Source = SourceBox.SelectedItem as string ?? _model.Source;
        _model.CorpusClass = ClassBox.SelectedItem as string ?? _model.CorpusClass;
        _model.FactClass = (KindBox.SelectedItem as KindChoice)?.Value ?? _model.FactClass;
        await RefreshAsync().ConfigureAwait(true);
    }

    private async void OnSearchKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Enter)
        {
            e.Handled = true;
            _model.SearchText = SearchBox.Text;
            await RefreshAsync().ConfigureAwait(true);
        }
    }

    private async void OnLoadMore(object sender, RoutedEventArgs e) => await _model.LoadMoreAsync().ConfigureAwait(true);

    private void OnFactSelected(object sender, SelectionChangedEventArgs e)
    {
        if (!_loading)
        {
            _model.Selected = FactsList.SelectedItem as FactListItem;
        }
    }

    private void OnModelChanged(object? sender, PropertyChangedEventArgs e) => Show();

    private void Show()
    {
        GleanButton.IsEnabled = !_runner.IsRunning;
        StopGleanButton.Visibility = Look.VisibleWhen(_runner.IsRunning);
        GleanPanel.Visibility = Look.VisibleIf(_model.GleanProgress);
        GleanText.Text = _model.GleanProgress ?? "";
        GleanBar.IsIndeterminate = _model.GleanFraction is null;
        GleanBar.Value = Look.Percent(_model.GleanFraction);
        CountText.Text = _model.CountText;
        LoadMoreButton.Visibility = _model.CanLoadMore ? Visibility.Visible : Visibility.Collapsed;
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

        FactListItem? fact = _model.Selected;
        Inspector.Visibility = fact is null ? Visibility.Collapsed : Visibility.Visible;
        if (fact is null)
        {
            return;
        }
        FactText.Text = fact.Fact;
        FactMeta.Text = string.Join(" · ", new[] { fact.FactClass, fact.CorpusClass, fact.ExtractorModel, fact.CreatedAt }.Where(s => s.Length > 0));

        GroundedExcerpt? grounded = fact.Grounded;
        GroundingPanel.Visibility = grounded is null ? Visibility.Collapsed : Visibility.Visible;
        GroundingText.Blocks.Clear();
        if (grounded is not null)
        {
            var paragraph = new Paragraph();
            paragraph.Inlines.Add(new Run { Text = grounded.Before });
            paragraph.Inlines.Add(new Run { Text = grounded.Span, FontWeight = FontWeights.SemiBold });
            paragraph.Inlines.Add(new Run { Text = grounded.After });
            GroundingText.Blocks.Add(paragraph);
        }

        IReadOnlyList<FactField> attributes = fact.Attributes;
        AttributesPanel.Visibility = attributes.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        AttributesList.ItemsSource = attributes;
        DocumentTitle.Text = $"{fact.DocumentDisplayTitle} ({fact.SourceSlug})";
        DocumentUri.Text = fact.DocumentUri;
    }

    private sealed record KindChoice(string Value, string Label);
}

using System.ComponentModel;
using Garage.App.Core.Corpus;
using Garage.App.Core.Facts;
using Garage.App.Core.Graph;
using Garage.App.Core.Tray;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Navigation;
using Windows.System;

namespace Garage.App.Pages;

/// <summary>
/// The Facts page (the Mac's <c>FactsView</c>): search, filters, the list with Load More, and
/// grounding. Distill Facts groups the facts that restate one claim; Group Restatements then lists
/// each claim once, and Show All Statements lists one claim's restatements.
/// </summary>
public sealed partial class FactsPage : Page
{
    private PageModels _pages = null!;
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
        _pages = (PageModels)e.Parameter;
        _model = _pages.Facts;
        _runner = _pages.State.Facts;
        _notifier = _pages.State.Notifier;
        _runner.PropertyChanged += OnModelChanged;
        _loading = true;
        SearchBox.Text = _model.SearchText;
        SourceBox.ItemsSource = _model.Sources;
        ClassBox.ItemsSource = _model.CorpusClasses;
        SourceBox.SelectedItem = _model.Source;
        ClassBox.SelectedItem = _model.CorpusClass;
        GroupBox.IsChecked = _model.GroupRestatements;
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

    private async void OnDistill(SplitButton sender, SplitButtonClickEventArgs args) =>
        await _model.DistillAsync(_runner, full: false, _notifier).ConfigureAwait(true);

    private async void OnRegroup(object sender, RoutedEventArgs e) =>
        await _model.DistillAsync(_runner, full: true, _notifier).ConfigureAwait(true);

    private void OnStopGlean(object sender, RoutedEventArgs e) => _runner.Cancel();

    private async void OnRefresh(object sender, RoutedEventArgs e)
    {
        _model.SearchText = SearchBox.Text;
        await RefreshAsync().ConfigureAwait(true);
    }

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

    private async void OnGroupChanged(object sender, RoutedEventArgs e)
    {
        _model.GroupRestatements = GroupBox.IsChecked == true;
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

    private async void OnClearDocumentFilter(InfoBar sender, object args)
    {
        _model.DocumentFilter = null;
        await RefreshAsync().ConfigureAwait(true);
    }

    private async void OnClearDistilledFilter(InfoBar sender, object args)
    {
        _model.DistilledFilter = null;
        await RefreshAsync().ConfigureAwait(true);
    }

    private void OnCopyFact(object sender, RoutedEventArgs e) => Clipboard.Copy(_model.Selected?.Fact);

    private async void OnShowStatements(object sender, RoutedEventArgs e)
    {
        if (_model.Selected is { DistilledFactId: { } id } fact)
        {
            _model.DistilledFilter = new FactsDistilledFilter(id, fact.DistilledStatement);
            await RefreshAsync().ConfigureAwait(true);
        }
    }

    private void OnOpenDocument(object sender, RoutedEventArgs e)
    {
        if (_model.Selected is { } fact)
        {
            _pages.OpenDocument(fact.DocumentId, fact.DocumentUri);
        }
    }

    private async void OnFactsFromDocument(object sender, RoutedEventArgs e)
    {
        if (_model.Selected is { } fact)
        {
            _model.DocumentFilter = new FactsDocumentFilter(fact.DocumentId, fact.DocumentDisplayTitle);
            await RefreshAsync().ConfigureAwait(true);
        }
    }

    private void OnShowInExplorer(object sender, RoutedEventArgs e) =>
        Shell.ShowInExplorer(_model.Selected is { } fact ? QuickSearch.FilePathForUri(fact.DocumentUri) : null);

    private void OnShowInGraph(object sender, RoutedEventArgs e)
    {
        if (_model.Selected is { } fact)
        {
            _pages.ShowInGraph(new GraphFocus("PotentialFact", fact.Id));
        }
    }

    private void OnModelChanged(object? sender, PropertyChangedEventArgs e) => Show();

    private void Show()
    {
        bool running = _runner.IsRunning;
        GleanButton.IsEnabled = !running;
        DistillButton.IsEnabled = !running;
        StopGleanButton.Visibility = Look.VisibleWhen(running);
        GleanPanel.Visibility = Look.VisibleIf(_model.GleanProgress);
        GleanText.Text = _model.GleanProgress ?? "";
        GleanBar.IsIndeterminate = _model.GleanFraction is null;
        GleanBar.Value = Look.Percent(_model.GleanFraction);
        CountText.Text = _model.CountText;
        LoadMoreButton.Visibility = _model.CanLoadMore ? Visibility.Visible : Visibility.Collapsed;
        GroupBox.IsEnabled = _model.DistilledFilter is null;

        DocumentFilterBar.IsOpen = _model.DocumentFilterTitle is not null;
        DocumentFilterBar.Title = _model.DocumentFilterTitle ?? "";
        DistilledFilterBar.IsOpen = _model.DistilledFilterTitle is not null;
        DistilledFilterBar.Title = _model.DistilledFilterTitle ?? "";

        if (_model.EmptyState is { } empty)
        {
            EmptyPanel.Visibility = Visibility.Visible;
            EmptyTitle.Text = empty.Title;
            EmptyDetail.Text = empty.Detail;
            RetryButton.Visibility = Look.VisibleWhen(_model.ErrorMessage is not null);
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
        FactMeta.Text = string.Join(" · ", new[] { fact.FactClass, fact.CorpusClass, fact.Extractor, fact.ExtractorModel, fact.CreatedAt }.Where(s => s.Length > 0));

        DistilledPanel.Visibility = Look.VisibleWhen(fact.HasRestatements);
        DistilledTitle.Text = fact.StatedTitle;
        DistilledText.Text = fact.DistilledStatement;
        GeneratedNote.Visibility = Look.VisibleWhen(fact.DistilledGenerated);
        AgreementText.Text = fact.AgreementText ?? "";
        AgreementText.Visibility = Look.VisibleIf(fact.AgreementText);
        ShowStatementsButton.IsEnabled = fact.DistilledFactId is { } distilled && _model.DistilledFilter?.Id != distilled;

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
        FromDocumentButton.IsEnabled = _model.DocumentFilter?.Id != fact.DocumentId;
        ShowInExplorerButton.Visibility = Look.VisibleWhen(QuickSearch.FilePathForUri(fact.DocumentUri) is not null);
    }

    private sealed record KindChoice(string Value, string Label);
}

using System.ComponentModel;
using Garage.App.Core.Corpus;
using Garage.App.Core.Graph;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;
using Windows.System;

namespace Garage.App.Pages;

/// <summary>
/// The Graph page (the Mac's <c>GraphView</c>): search on the left, the chosen vertex's neighbourhood
/// drawn in the middle (a radial <see cref="GraphLayout"/>, one ring per hop), and the selected
/// vertex's connections and properties on the right. Click a vertex to inspect it, double-click to
/// make it the center.
/// </summary>
public sealed partial class GraphPage : Page
{
    private PageModels _pages = null!;
    private GraphViewModel _model = null!;
    private GraphLayout? _layout;
    private long? _hoveredId;
    private bool _loading;

    /// <summary>Creates the page.</summary>
    public GraphPage() => InitializeComponent();

    /// <inheritdoc/>
    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        ArgumentNullException.ThrowIfNull(e);
        _pages = (PageModels)e.Parameter;
        _model = _pages.Graph;
        _loading = true;
        SearchBox.Text = _model.SearchText;
        DepthBox.Value = _model.Depth;
        ResultsList.ItemsSource = _model.Results;
        FillKinds();
        _loading = false;
        _model.PropertyChanged += OnModelChanged;
        Show();

        if (_model.Labels is null || !_model.Labels.Available)
        {
            await _model.LoadLabelsAsync().ConfigureAwait(true);
        }
        if (_model.PendingFocus is { } focus)
        {
            await _model.ShowAsync(focus).ConfigureAwait(true);
        }
    }

    /// <inheritdoc/>
    protected override void OnNavigatedFrom(NavigationEventArgs e) => _model.PropertyChanged -= OnModelChanged;

    private void OnModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(GraphViewModel.Labels))
        {
            _loading = true;
            FillKinds();
            _loading = false;
        }
        Show();
    }

    // The Kind picker: any kind, then the graph's vertex labels.
    private void FillKinds()
    {
        List<KindChoice> kinds = [new(CorpusTaxonomy.All, "Any Kind"), .. (_model.Labels?.VertexLabels ?? []).Select(l => new KindChoice(l.Label, GraphLabelStyle.Vertex(l.Label).Name))];
        if (kinds.All(k => k.Value != _model.SearchLabel))
        {
            kinds.Add(new(_model.SearchLabel, GraphLabelStyle.Vertex(_model.SearchLabel).Name));
        }
        KindBox.ItemsSource = kinds;
        KindBox.DisplayMemberPath = nameof(KindChoice.Label);
        KindBox.SelectedItem = kinds.First(k => k.Value == _model.SearchLabel);
    }

    private async void OnSearchKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Enter)
        {
            e.Handled = true;
            _model.SearchText = SearchBox.Text;
            await _model.SearchAsync().ConfigureAwait(true);
        }
        else if (e.Key == VirtualKey.Escape && SearchBox.Text.Length > 0)
        {
            e.Handled = true;
            SearchBox.Text = "";
            _model.ClearSearch();
        }
    }

    private async void OnKindChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading || KindBox.SelectedItem is not KindChoice kind)
        {
            return;
        }
        _model.SearchLabel = kind.Value;
        if (_model.HasSearched)
        {
            await _model.SearchAsync().ConfigureAwait(true);
        }
    }

    private async void OnDepthChanged(NumberBox sender, NumberBoxValueChangedEventArgs args)
    {
        if (_loading || double.IsNaN(args.NewValue))
        {
            return;
        }
        _model.Depth = (int)Math.Clamp(args.NewValue, 1, GraphPagePresentation.MaxDepth);
        await _model.LoadNeighborhoodAsync().ConfigureAwait(true);
    }

    private async void OnRefresh(object sender, RoutedEventArgs e) => await _model.RefreshAsync().ConfigureAwait(true);

    private async void OnResultSelected(object sender, SelectionChangedEventArgs e)
    {
        if (!_loading && ResultsList.SelectedItem is GraphVertexItem vertex && vertex.Id != _model.CenterId)
        {
            await _model.CenterAsync(vertex.Id).ConfigureAwait(true);
        }
    }

    private void OnCopyTitle(object sender, RoutedEventArgs e) => Clipboard.Copy(_model.SelectedVertex?.Title);

    private async void OnCenterHere(object sender, RoutedEventArgs e)
    {
        if (_model.SelectedVertex is { } vertex)
        {
            await _model.CenterAsync(vertex.Id).ConfigureAwait(true);
        }
    }

    private void OnOpenDocument(object sender, RoutedEventArgs e)
    {
        if (_model.SelectedVertex is { DocumentId: { } id } vertex)
        {
            _pages.OpenDocument(id, vertex.DocumentUri);
        }
    }

    // MARK: the picture

    private void OnPictureSizeChanged(object sender, SizeChangedEventArgs e) => Draw();

    private void OnPicturePointerMoved(object sender, PointerRoutedEventArgs e)
    {
        long? hovered = VertexUnder(e.GetCurrentPoint(Picture).Position);
        if (hovered != _hoveredId)
        {
            _hoveredId = hovered;
            Draw();
        }
    }

    private void OnPicturePointerExited(object sender, PointerRoutedEventArgs e)
    {
        if (_hoveredId is not null)
        {
            _hoveredId = null;
            Draw();
        }
    }

    private void OnPictureTapped(object sender, TappedRoutedEventArgs e)
    {
        if (VertexUnder(e.GetPosition(Picture)) is { } id)
        {
            _model.SelectedVertexId = id;
        }
    }

    private async void OnPictureDoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        if (VertexUnder(e.GetPosition(Picture)) is { } id)
        {
            await _model.CenterAsync(id).ConfigureAwait(true);
        }
    }

    private long? VertexUnder(Point point) =>
        _layout?.VertexAt(new GraphPoint(point.X, point.Y), NodeRadius + 6);

    private double NodeRadius => GraphPagePresentation.NodeRadius(_model.Neighborhood?.Vertices.Count ?? 0);

    // Edges as arrows, vertices as tinted circles, titles under them while the picture is sparse
    // enough to read, and always for the center, the hovered and the selected vertex.
    private void Draw()
    {
        Picture.Children.Clear();
        _layout = null;
        if (_model.Neighborhood is not { Center: { } center } neighborhood || Picture.ActualWidth <= 0 || Picture.ActualHeight <= 0)
        {
            return;
        }
        var layout = new GraphLayout(neighborhood, Picture.ActualWidth, Picture.ActualHeight);
        _layout = layout;
        double nodeRadius = NodeRadius;
        HashSet<long> highlighted = [.. new[] { _model.SelectedVertexId, _hoveredId }.OfType<long>()];

        foreach (GraphEdgeItem edge in neighborhood.Edges)
        {
            if (!layout.Positions.TryGetValue(edge.SourceId, out GraphPoint from) || !layout.Positions.TryGetValue(edge.TargetId, out GraphPoint to))
            {
                continue;
            }
            bool touches = highlighted.Contains(edge.SourceId) || highlighted.Contains(edge.TargetId);
            Brush tint = Look.GraphBrush(GraphLabelStyle.Edge(edge.Label).Tint, touches ? 0.95 : 0.45);
            Picture.Children.Add(new Line { X1 = from.X, Y1 = from.Y, X2 = to.X, Y2 = to.Y, Stroke = tint, StrokeThickness = touches ? 2 : 1.2 });
            IReadOnlyList<GraphPoint> head = GraphPagePresentation.Arrowhead(from, to, nodeRadius + 1);
            if (head.Count > 0)
            {
                var arrow = new Polygon { Fill = tint };
                foreach (GraphPoint p in head)
                {
                    arrow.Points.Add(new Point(p.X, p.Y));
                }
                Picture.Children.Add(arrow);
            }
        }

        Brush halo = Look.TintBrush(Core.Presentation.Tint.Blue);
        foreach (GraphVertexItem vertex in neighborhood.Vertices)
        {
            if (!layout.Positions.TryGetValue(vertex.Id, out GraphPoint position))
            {
                continue;
            }
            bool isCenter = vertex.Id == center.Id;
            double radius = isCenter ? nodeRadius * 1.35 : nodeRadius;
            if (highlighted.Contains(vertex.Id))
            {
                Place(new Ellipse { Width = 2 * radius + 8, Height = 2 * radius + 8, Stroke = halo, StrokeThickness = 2 }, position, radius + 4);
            }
            Place(new Ellipse
            {
                Width = 2 * radius,
                Height = 2 * radius,
                Fill = Look.GraphBrush(GraphLabelStyle.Vertex(vertex.Label).Tint),
                Stroke = new SolidColorBrush(Colors.White) { Opacity = 0.9 },
                StrokeThickness = isCenter ? 2 : 1,
            }, position, radius);
        }

        bool titleAll = neighborhood.Vertices.Count <= GraphPagePresentation.TitledVertexLimit;
        foreach (GraphVertexItem vertex in neighborhood.Vertices)
        {
            bool isCenter = vertex.Id == center.Id;
            bool isHighlighted = highlighted.Contains(vertex.Id);
            if (!layout.Positions.TryGetValue(vertex.Id, out GraphPoint position) || !(titleAll || isCenter || isHighlighted))
            {
                continue;
            }
            double radius = isCenter ? nodeRadius * 1.35 : nodeRadius;
            var title = new TextBlock
            {
                Text = GraphPagePresentation.ShortTitle(vertex.Title),
                FontSize = isCenter || isHighlighted ? 12 : 10,
                FontWeight = isCenter || isHighlighted ? FontWeights.SemiBold : FontWeights.Normal,
                Foreground = (Brush)Application.Current.Resources[isHighlighted ? "TextFillColorPrimaryBrush" : "TextFillColorSecondaryBrush"],
                IsHitTestVisible = false,
            };
            title.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            Canvas.SetLeft(title, position.X - title.DesiredSize.Width / 2);
            Canvas.SetTop(title, position.Y + radius + 2);
            Picture.Children.Add(title);
        }

        void Place(FrameworkElement element, GraphPoint at, double half)
        {
            element.IsHitTestVisible = false;
            Canvas.SetLeft(element, at.X - half);
            Canvas.SetTop(element, at.Y - half);
            Picture.Children.Add(element);
        }
    }

    // MARK: state

    private void Show()
    {
        RefreshButton.IsEnabled = !_model.IsLoading && _model.DatabaseRunning;

        // The whole page: an error, the first load, or nothing to browse.
        GraphPagePresentation.Empty? pageEmpty = _model.PageEmptyState;
        bool failed = _model.ErrorMessage is not null;
        bool firstLoad = _model.Labels is null && _model.IsLoading;
        bool browsing = !failed && !firstLoad && pageEmpty is null;
        Browser.Visibility = Look.VisibleWhen(browsing);
        FilterBar.Visibility = Look.VisibleWhen(_model.Labels?.Available == true);
        PageMessage.Visibility = Look.HiddenWhen(browsing);
        PageProgress.IsActive = firstLoad;
        RetryButton.Visibility = Look.VisibleWhen(failed);
        PageMessageGlyph.Glyph = failed ? "" : "";
        PageMessageTitle.Text = failed ? "Failed to Load the Graph" : firstLoad ? "Loading the graph…" : pageEmpty?.Title ?? "";
        PageMessageText.Text = failed ? _model.ErrorMessage! : firstLoad ? "" : pageEmpty?.Message ?? "";
        FillFilters();
        if (!browsing)
        {
            return;
        }

        // Results.
        _loading = true;
        ResultsList.SelectedItem = _model.Results.FirstOrDefault(r => r.Id == _model.CenterId);
        _loading = false;
        ResultsEmpty.Visibility = Look.VisibleWhen(_model.Results.Count == 0);
        SearchProgress.IsActive = _model.IsSearching;
        ResultsEmptyText.Text = _model.IsSearching ? "" : _model.ResultsEmptyState.Message;
        ResultsCount.Text = GraphPagePresentation.Matches(_model.Results.Count);

        // Picture.
        bool hasPicture = _model.Neighborhood?.Center is not null;
        PictureEmpty.Visibility = Look.VisibleWhen(!hasPicture && !_model.IsLoading);
        PictureEmptyTitle.Text = _model.PictureEmptyState.Title;
        PictureEmptyText.Text = _model.PictureEmptyState.Message;
        PictureProgress.IsActive = _model.IsLoading;
        SummaryText.Text = hasPicture ? _model.Summary : "";
        AutomationProperties.SetName(Picture, hasPicture ? $"Graph of {_model.Neighborhood!.Center!.Title}" : "Graph");
        Draw();

        // Inspector.
        GraphVertexItem? vertex = _model.SelectedVertex;
        Inspector.Visibility = Look.VisibleWhen(vertex is not null);
        InspectorEmpty.Visibility = Look.VisibleWhen(vertex is null);
        if (vertex is null || _model.Neighborhood is not { } neighborhood)
        {
            return;
        }
        GraphLabelStyle style = GraphLabelStyle.Vertex(vertex.Label);
        DetailBadge.Background = Look.GraphBrush(style.Tint);
        DetailLabel.Text = style.Name;
        DetailKey.Text = vertex.KeyText;
        bool isCenter = vertex.Id == neighborhood.Center?.Id;
        CenterBadge.Visibility = Look.VisibleWhen(isCenter);
        DetailTitle.Text = vertex.Title;
        CenterButton.Visibility = Look.HiddenWhen(isCenter);
        OpenDocumentButton.Visibility = Look.VisibleWhen(vertex.DocumentId is not null);
        OpenDocumentButton.Content = vertex.Label == "Document" ? "Open Document" : "Open Its Document";

        IReadOnlyList<GraphConnection> connections = neighborhood.Connections(vertex.Id);
        ConnectionsHeader.Text = connections.Count == 0 ? "No Connections Shown" : "Connections";
        ConnectionsPanel.Children.Clear();
        foreach (IGrouping<string, GraphConnection> group in connections.GroupBy(c => c.Edge.Label).OrderBy(g => g.Key, StringComparer.Ordinal))
        {
            GraphLabelStyle edgeStyle = GraphLabelStyle.Edge(group.Key);
            var section = new StackPanel { Spacing = 2 };
            section.Children.Add(new TextBlock
            {
                Text = $"{edgeStyle.Name} · {group.Count()}",
                FontWeight = FontWeights.SemiBold,
                Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
                Foreground = Look.GraphBrush(edgeStyle.Tint),
            });
            foreach (GraphConnection connection in group.OrderBy(c => c.Other.Title, StringComparer.Ordinal))
            {
                bool outgoing = connection.Edge.SourceId == vertex.Id;
                var row = new HyperlinkButton
                {
                    Content = $"{(outgoing ? "→" : "←")} {connection.Other.Title}",
                    Padding = new Thickness(2, 0, 2, 0),
                    Tag = connection.Other.Id,
                };
                ToolTipService.SetToolTip(row, $"{(outgoing ? "→" : "←")} {edgeStyle.Name}: {connection.Other.Title}");
                row.Click += (_, _) => _model.SelectedVertexId = (long)row.Tag;
                section.Children.Add(row);
            }
            ConnectionsPanel.Children.Add(section);
        }

        IReadOnlyList<GraphProperty> properties = vertex.Properties;
        PropertiesHeader.Visibility = Look.VisibleWhen(properties.Count > 0);
        PropertiesList.ItemsSource = properties;
    }

    // The filter chips: each vertex and edge label, tinted when on.
    private void FillFilters()
    {
        FilterPanel.Children.Clear();
        if (_model.Labels is not { Available: true } labels)
        {
            return;
        }
        FilterPanel.Children.Add(Caption("Show"));
        foreach (GraphLabelCountItem option in labels.VertexLabels)
        {
            FilterPanel.Children.Add(Chip(option, GraphLabelStyle.Vertex(option.Label), _model.IsVertexLabelOn(option.Label),
                () => _model.ToggleVertexLabelAsync(option.Label), $"graph.vertex.{option.Label}"));
        }
        FilterPanel.Children.Add(Caption("linked by"));
        foreach (GraphLabelCountItem option in labels.EdgeLabels)
        {
            FilterPanel.Children.Add(Chip(option, GraphLabelStyle.Edge(option.Label), _model.IsEdgeLabelOn(option.Label),
                () => _model.ToggleEdgeLabelAsync(option.Label), $"graph.edge.{option.Label}"));
        }

        static TextBlock Caption(string text) => new()
        {
            Text = text,
            VerticalAlignment = VerticalAlignment.Center,
            Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
            Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
        };
    }

    private static ToggleButton Chip(GraphLabelCountItem option, GraphLabelStyle style, bool isOn, Func<Task> toggle, string automationId)
    {
        var dot = new Microsoft.UI.Xaml.Shapes.Rectangle
        {
            Width = style.Symbol == GraphSymbol.None ? 10 : 8,
            Height = style.Symbol == GraphSymbol.None ? 2 : 8,
            RadiusX = style.Symbol == GraphSymbol.None ? 0 : 4,
            RadiusY = style.Symbol == GraphSymbol.None ? 0 : 4,
            Fill = Look.GraphBrush(style.Tint),
            VerticalAlignment = VerticalAlignment.Center,
        };
        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 5 };
        content.Children.Add(dot);
        content.Children.Add(new TextBlock { Text = style.Name, FontSize = 12 });
        content.Children.Add(new TextBlock
        {
            Text = option.Count.ToString("N0", System.Globalization.CultureInfo.CurrentCulture),
            FontSize = 11,
            FontFamily = new FontFamily("Consolas"),
            Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
            VerticalAlignment = VerticalAlignment.Center,
        });
        var chip = new ToggleButton { Content = content, IsChecked = isOn, Padding = new Thickness(8, 2, 8, 2), CornerRadius = new CornerRadius(12) };
        ToolTipService.SetToolTip(chip, GraphPagePresentation.ChipHelp(style, isOn));
        AutomationProperties.SetName(chip, style.Name);
        AutomationProperties.SetAutomationId(chip, automationId);
        chip.Click += async (_, _) => await toggle().ConfigureAwait(true);
        return chip;
    }

    private sealed record KindChoice(string Value, string Label);
}

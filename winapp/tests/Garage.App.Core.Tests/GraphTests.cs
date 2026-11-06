using Garage.App.Core.Corpus;
using Garage.App.Core.Graph;
using Garage.App.Core.Tests.TestSupport;

namespace Garage.App.Core.Tests;

// Ported from macapp/Tests/GarageAppUnitTests/GraphLayoutTests.swift, GraphPresentationTests.swift and
// GraphItemsTests.swift, plus the page's loading.
public sealed class GraphTests
{
    private static GraphVertexItem Vertex(long id, string label = "Fact", string title = "") =>
        new(id, label, id, title.Length == 0 ? $"v{id}" : title);

    private static GraphEdgeItem Edge(long id, long source, long target, string label = "SUPPORTS") =>
        new(id, label, source, target);

    // A document with two chunks and an author, and a fact two hops away through a potential fact.
    private static GraphNeighborhood Sample => new(
        true,
        Vertex(1, "Document", "House"),
        [
            Vertex(1, "Document", "House"),
            Vertex(2, "Chunk", "Chunk 0"),
            Vertex(3, "Chunk", "Chunk 1"),
            Vertex(4, "Author", "Ada"),
            Vertex(5, "PotentialFact", "The roof is slate."),
            Vertex(7, "Fact", "The roof is slate."),
        ],
        [
            Edge(100, 1, 2, "HAS_CHUNK"),
            Edge(101, 1, 3, "HAS_CHUNK"),
            Edge(102, 4, 1, "WROTE"),
            Edge(103, 1, 5, "STATES"),
            Edge(105, 5, 7),
        ]);

    private const double Width = 400, Height = 300;

    private static double Distance(GraphPoint a, GraphPoint b) => Math.Sqrt(Math.Pow(a.X - b.X, 2) + Math.Pow(a.Y - b.Y, 2));

    private static double Angle(GraphPoint point, GraphPoint origin) => Math.Atan2(point.Y - origin.Y, point.X - origin.X);

    [Fact]
    public void The_center_sits_in_the_middle_and_rings_follow_hops()
    {
        var layout = new GraphLayout(Sample, Width, Height);
        Assert.Equal(new GraphPoint(200, 150), layout.Origin);
        Assert.Equal(layout.Origin, layout.Positions[1]);
        Assert.Equal(new Dictionary<long, int> { [1] = 0, [2] = 1, [3] = 1, [4] = 1, [5] = 1, [7] = 2 }, layout.Rings.ToDictionary());
        Assert.Equal(2, layout.Depth);
    }

    [Fact]
    public void Ring_radii_share_the_available_space()
    {
        var layout = new GraphLayout(Sample, Width, Height, margin: 32);
        // Half the short side less the margin is the outer ring; the first ring is halfway out.
        const double outer = 150 - 32;
        foreach (long id in new long[] { 2, 3, 4, 5 })
        {
            Assert.Equal(outer / 2, Distance(layout.Positions[id], layout.Origin), 3);
        }
        Assert.Equal(outer, Distance(layout.Positions[7], layout.Origin), 3);
    }

    [Fact]
    public void The_first_ring_is_evenly_spaced_with_like_labels_together()
    {
        var layout = new GraphLayout(Sample, Width, Height);
        // Sorted by label then title: Author, Chunk 0, Chunk 1, PotentialFact; a quarter turn apart from the top.
        double[] angles = [.. new long[] { 4, 2, 3, 5 }.Select(id => Angle(layout.Positions[id], layout.Origin))];
        Assert.Equal(-Math.PI / 2, angles[0], 3);
        for (int i = 1; i < angles.Length; i++)
        {
            Assert.Equal(Math.PI / 2, angles[i] - angles[i - 1], 3);
        }
    }

    [Fact]
    public void A_second_ring_vertex_sits_on_its_parents_side()
    {
        var layout = new GraphLayout(Sample, Width, Height);
        Assert.Equal(Angle(layout.Positions[5], layout.Origin), Angle(layout.Positions[7], layout.Origin), 3);
    }

    [Fact]
    public void A_vertex_no_edge_reaches_goes_on_the_outermost_ring()
    {
        GraphNeighborhood stray = Sample with { Vertices = [.. Sample.Vertices, Vertex(9, "Author", "Nobody")] };
        var layout = new GraphLayout(stray, Width, Height);
        Assert.Equal(3, layout.Rings[9]);
        Assert.Equal(3, layout.Depth);
        Assert.True(layout.Positions.ContainsKey(9));
    }

    [Fact]
    public void A_lone_center_has_no_rings()
    {
        var layout = new GraphLayout(new GraphNeighborhood(true, Vertex(1), [Vertex(1)], []), Width, Height);
        Assert.Equal(0, layout.Depth);
        Assert.Equal(new Dictionary<long, GraphPoint> { [1] = layout.Origin }, layout.Positions.ToDictionary());
        Assert.Empty(new GraphLayout(new GraphNeighborhood(false, null, [], []), Width, Height).Positions);
    }

    [Fact]
    public void The_same_neighborhood_always_lays_out_the_same()
    {
        Assert.Equal(new GraphLayout(Sample, Width, Height).Positions.ToDictionary(), new GraphLayout(Sample, Width, Height).Positions.ToDictionary());
    }

    [Fact]
    public void Hit_testing_finds_the_nearest_vertex_within_its_circle()
    {
        var layout = new GraphLayout(Sample, Width, Height);
        GraphPoint ada = layout.Positions[4];
        Assert.Equal(4, layout.VertexAt(new GraphPoint(ada.X + 3, ada.Y - 2), 8));
        Assert.Equal(1, layout.VertexAt(layout.Origin, 8));
        Assert.Null(layout.VertexAt(new GraphPoint(1, 1), 8));
    }

    [Fact]
    public void Colliding_vertices_are_pushed_apart_around_where_they_wanted()
    {
        Assert.Equal([1.0], GraphLayout.SpreadApart([1.0]));
        // Two vertices wanting the same angle end up either side of it, a separation apart.
        IReadOnlyList<double> pair = GraphLayout.SpreadApart([1.0, 1.0]);
        Assert.Equal(Math.PI / 6, pair[1] - pair[0], 3);
        Assert.Equal(1.0, (pair[0] + pair[1]) / 2, 3);
        // Vertices already far enough apart stay put.
        Assert.Equal([0.0, 1.0, 2.0], GraphLayout.SpreadApart([0.0, 1.0, 2.0]));
        // A ring too crowded to honour anyone's wish is spaced evenly instead.
        IReadOnlyList<double> crowded = GraphLayout.SpreadApart([.. Enumerable.Repeat(0.0, 12), .. Enumerable.Repeat(3.0, 12)]);
        Assert.Equal(GraphLayout.EvenlySpaced(24, 0), crowded);
    }

    [Fact]
    public void The_mean_angle_wraps_around_the_circle()
    {
        // 170° and -170° average to 180°, not to 0°.
        Assert.Equal(Math.PI, Math.Abs(GraphLayout.MeanAngle([170 * Math.PI / 180, -170 * Math.PI / 180])), 3);
        Assert.Equal(Math.PI / 4, GraphLayout.MeanAngle([0, Math.PI / 2]), 3);
    }

    [Theory]
    [InlineData("HAS_CHUNK", "Has chunk")]
    [InlineData("PotentialFact", "Potential fact")]
    [InlineData("RESTATES", "Restates")]
    [InlineData("Fact", "Fact")]
    [InlineData("URLRef", "Urlref")]
    public void Labels_read_as_words(string label, string words) => Assert.Equal(words, GraphLabelStyle.Humanize(label));

    [Fact]
    public void Known_labels_have_their_own_style_and_unknown_ones_a_neutral_one()
    {
        Assert.Equal(new GraphLabelStyle("Potential fact", GraphTint.Orange, GraphSymbol.Lightbulb), GraphLabelStyle.Vertex("PotentialFact"));
        Assert.Equal(GraphTint.Purple, GraphLabelStyle.Vertex("Fact").Tint);
        Assert.Equal(new GraphLabelStyle("Supports", GraphTint.Purple, GraphSymbol.None), GraphLabelStyle.Edge("SUPPORTS"));
        Assert.Equal("Restates", GraphLabelStyle.Edge("RESTATES").Name);
        Assert.Equal(new GraphLabelStyle("Entity", GraphLabelStyle.ConfiguredTint("Entity"), GraphSymbol.Circle), GraphLabelStyle.Vertex("Entity"));
        Assert.Equal(new GraphLabelStyle("Mentions", GraphLabelStyle.ConfiguredTint("MENTIONS"), GraphSymbol.None), GraphLabelStyle.Edge("MENTIONS"));
    }

    [Fact]
    public void Configured_labels_keep_a_colour_of_their_own()
    {
        Assert.Equal(GraphLabelStyle.ConfiguredTint("Person"), GraphLabelStyle.ConfiguredTint("Person"));
        Assert.Contains(GraphLabelStyle.ConfiguredTint("WORKS_AT"), GraphLabelStyle.ConfiguredPalette);
        // Different labels spread over the palette rather than all landing on one colour.
        string[] labels = ["Person", "Organization", "Place", "Project", "WORKS_AT", "MEMBER_OF", "RELATED_TO"];
        Assert.True(labels.Select(GraphLabelStyle.ConfiguredTint).Distinct().Count() > 1);
    }

    [Fact]
    public void The_empty_state_names_what_is_missing()
    {
        Assert.Equal("Database Offline", GraphPagePresentation.EmptyState(false, false, false, false).Title);
        GraphPagePresentation.Empty noGraph = GraphPagePresentation.EmptyState(true, false, false, false);
        Assert.Equal("No Graph Yet", noGraph.Title);
        Assert.Contains("Distill Facts", noGraph.Message, StringComparison.Ordinal);
        Assert.Equal("Nothing Found", GraphPagePresentation.EmptyState(true, true, false, true).Title);
        Assert.Equal("Pick a Starting Point", GraphPagePresentation.EmptyState(true, true, false, false).Title);
        Assert.Equal("Nothing Connected", GraphPagePresentation.EmptyState(true, true, true, false).Title);
    }

    [Fact]
    public void The_summary_counts_and_says_when_it_was_cut()
    {
        Assert.Equal("1 vertex, 0 edges within 1 hop", GraphPagePresentation.Summary(1, 0, 1, false));
        Assert.Equal("12 vertices, 11 edges within 2 hops", GraphPagePresentation.Summary(12, 11, 2, false));
        Assert.EndsWith("(cut at the limit; filter or look nearer)", GraphPagePresentation.Summary(150, 200, 3, true), StringComparison.Ordinal);
    }

    [Fact]
    public void Titles_under_vertices_are_cut_on_a_word_where_one_is_near()
    {
        Assert.Equal("The roof is slate.", GraphPagePresentation.ShortTitle("The roof is slate."));
        Assert.Equal("The heat pump was installed…", GraphPagePresentation.ShortTitle("The heat pump was installed in March 2024 by the previous owner"));
        Assert.Equal(new string('x', 28) + "…", GraphPagePresentation.ShortTitle(new string('x', 40)));
    }

    [Fact]
    public void Arrowheads_need_room_between_the_circles()
    {
        Assert.Empty(GraphPagePresentation.Arrowhead(new(0, 0), new(10, 0), 8));
        IReadOnlyList<GraphPoint> arrow = GraphPagePresentation.Arrowhead(new(0, 0), new(100, 0), 10);
        Assert.Equal(3, arrow.Count);
        // The tip stops at the clearance, short of the target.
        Assert.Equal(90, arrow.Max(p => p.X), 3);
    }

    [Fact]
    public void Circles_shrink_as_the_picture_fills()
    {
        Assert.Equal(11, GraphPagePresentation.NodeRadius(5));
        Assert.Equal(8, GraphPagePresentation.NodeRadius(30));
        Assert.Equal(5.5, GraphPagePresentation.NodeRadius(150));
    }

    [Fact]
    public void Maps_a_vertex_and_reads_its_key_as_optional()
    {
        GraphVertexItem item = GraphVertexItem.From(new GraphVertex { Id = 1, Label = "Document", Key = 10, Title = "House", PropertiesJson = """{"document_id": 10, "title": "House", "uri": "/h.md"}""" });
        Assert.Equal(1, item.Id);
        Assert.Equal(10, item.Key);
        Assert.Equal(10, item.DocumentId);
        Assert.Equal("/h.md", item.DocumentUri);
        Assert.Equal(["document_id", "title", "uri"], item.Properties.Select(p => p.Key));
        Assert.Null(GraphVertexItem.From(new GraphVertex { Id = 2, Label = "Entity" }).Key);
    }

    [Fact]
    public void A_potential_fact_points_at_its_document_and_an_author_at_none()
    {
        GraphVertexItem fact = GraphVertexItem.From(new GraphVertex { Id = 5, Label = "PotentialFact", Key = 40, PropertiesJson = """{"fact_id": 40, "document_id": 10}""" });
        Assert.Equal(10, fact.DocumentId);
        Assert.Equal("", fact.DocumentUri);
        GraphVertexItem author = GraphVertexItem.From(new GraphVertex { Id = 4, Label = "Author", Key = 30, PropertiesJson = """{"author_id": 30, "is_self": true}""" });
        Assert.Null(author.DocumentId);
        Assert.Equal([new GraphProperty("author_id", "30"), new GraphProperty("is_self", "true")], author.Properties);
    }

    [Fact]
    public void Properties_render_every_json_type()
    {
        IReadOnlyList<GraphProperty> properties = GraphProperty.Parse("""{"n": 0.9, "s": "x", "b": false, "z": null, "list": [1, 2], "map": {"k": "v"}}""");
        Assert.Equal(["b", "list", "map", "n", "s", "z"], properties.Select(p => p.Key));
        Assert.Equal(["false", "[1,2]", """{"k":"v"}""", "0.9", "x", ""], properties.Select(p => p.Value));
        Assert.Empty(GraphProperty.Parse(""));
        Assert.Empty(GraphProperty.Parse("not json"));
    }

    [Fact]
    public void A_neighborhood_knows_each_vertexs_connections()
    {
        var center = new GraphVertex { Id = 1, Label = "Document", Key = 10, Title = "House" };
        var response = new GraphNeighborhoodResponse
        {
            Available = true,
            Center = center,
            Vertices = { center, new GraphVertex { Id = 4, Label = "Author", Key = 30, Title = "Ada" }, new GraphVertex { Id = 5, Label = "PotentialFact", Key = 40, Title = "The roof is slate." } },
            Edges = { new GraphEdge { Id = 102, Label = "WROTE", SourceId = 4, TargetId = 1 }, new GraphEdge { Id = 103, Label = "STATES", SourceId = 1, TargetId = 5 } },
            Truncated = true,
        };
        GraphNeighborhood neighborhood = GraphNeighborhood.From(response);

        Assert.Equal("House", neighborhood.Center?.Title);
        Assert.True(neighborhood.Truncated);
        IReadOnlyList<GraphConnection> connections = neighborhood.Connections(1);
        Assert.Equal(["WROTE", "STATES"], connections.Select(c => c.Edge.Label));
        Assert.Equal(["Ada", "The roof is slate."], connections.Select(c => c.Other.Title));
        Assert.Equal([1L], neighborhood.Connections(5).Select(c => c.Other.Id));
        Assert.Equal(1, neighborhood.Edges[0].OtherEnd(4));
        Assert.Null(neighborhood.Edges[0].OtherEnd(5));
    }

    [Fact]
    public void An_unavailable_graph_has_no_center()
    {
        GraphNeighborhood neighborhood = GraphNeighborhood.From(new GraphNeighborhoodResponse { Available = false });
        Assert.False(neighborhood.Available);
        Assert.Null(neighborhood.Center);
        Assert.Empty(neighborhood.Vertices);
    }

    [Fact]
    public void Labels_map_with_counts()
    {
        GraphLabels labels = GraphLabels.From(new GraphLabelsResponse { Available = true, VertexLabels = { new GraphLabelCount { Label = "Fact", Count = 12 } } });
        Assert.True(labels.Available);
        Assert.Equal([new GraphLabelCountItem("Fact", 12)], labels.VertexLabels);
        Assert.Empty(labels.EdgeLabels);
    }

    private static GraphLabelsResponse TwoLabels() => new()
    {
        Available = true,
        VertexLabels = { new GraphLabelCount { Label = "Document", Count = 3 }, new GraphLabelCount { Label = "Author", Count = 2 } },
        EdgeLabels = { new GraphLabelCount { Label = "WROTE", Count = 2 } },
    };

    [Fact]
    public async Task Every_label_starts_on_and_an_all_on_filter_asks_for_everything()
    {
        var client = new FakeGarageClient { OnGraphLabels = _ => TwoLabels() };
        var page = new GraphViewModel(client);
        await page.LoadLabelsAsync(TestContext.Current.CancellationToken);
        Assert.True(page.IsVertexLabelOn("Document") && page.IsVertexLabelOn("Author") && page.IsEdgeLabelOn("WROTE"));
        Assert.Null(page.PageEmptyState);

        await page.ShowAsync(new GraphFocus("Document", 10));
        GraphNeighborhoodRequest request = client.Requests.OfType<GraphNeighborhoodRequest>().Single();
        Assert.Equal(("Document", 10L, 0L), (request.Label, request.Key, request.VertexId));
        Assert.False(request.FilterVertexLabels);
        Assert.False(request.FilterEdgeLabels);
        Assert.Equal(GraphPagePresentation.VertexLimit, request.Limit);
    }

    [Fact]
    public async Task Switching_a_label_off_asks_for_the_rest_by_name()
    {
        var center = new GraphVertex { Id = 1, Label = "Document", Key = 10, Title = "House" };
        var client = new FakeGarageClient
        {
            OnGraphLabels = _ => TwoLabels(),
            OnGraphNeighborhood = _ => new GraphNeighborhoodResponse { Available = true, Center = center, Vertices = { center } },
        };
        var page = new GraphViewModel(client);
        await page.LoadLabelsAsync(TestContext.Current.CancellationToken);
        await page.CenterAsync(1);

        await page.ToggleVertexLabelAsync("Author");
        GraphNeighborhoodRequest last = client.Requests.OfType<GraphNeighborhoodRequest>().Last();
        Assert.Equal(1, last.VertexId);
        Assert.True(last.FilterVertexLabels);
        Assert.Equal(["Document"], last.VertexLabels);
        Assert.False(last.FilterEdgeLabels);
        Assert.Equal("House", page.SelectedVertex?.Title);
        Assert.Equal("1 vertex, 0 edges within 1 hop", page.Summary);
    }

    [Fact]
    public async Task No_graph_says_how_to_make_one_and_search_says_nothing_found()
    {
        var client = new FakeGarageClient { OnGraphLabels = _ => new GraphLabelsResponse { Available = false } };
        var page = new GraphViewModel(client);
        await page.LoadLabelsAsync(TestContext.Current.CancellationToken);
        Assert.Equal("No Graph Yet", page.PageEmptyState?.Title);

        client.OnGraphLabels = _ => TwoLabels();
        await page.LoadLabelsAsync(TestContext.Current.CancellationToken);
        page.SearchText = "  nobody  ";
        page.SearchLabel = "Author";
        await page.SearchAsync(TestContext.Current.CancellationToken);
        FindGraphVerticesRequest search = client.Requests.OfType<FindGraphVerticesRequest>().Single();
        Assert.Equal(("nobody", "Author", 50), (search.Query, search.Label, search.Limit));
        Assert.Equal("Nothing Found", page.ResultsEmptyState.Title);

        page.SearchLabel = CorpusTaxonomy.All;
        await page.SearchAsync(TestContext.Current.CancellationToken);
        Assert.Equal("", client.Requests.OfType<FindGraphVerticesRequest>().Last().Label);
    }

    [Fact]
    public async Task A_stopped_database_asks_nothing()
    {
        var client = new FakeGarageClient();
        var page = new GraphViewModel(client, () => false);
        await page.LoadLabelsAsync(TestContext.Current.CancellationToken);
        await page.ShowAsync(new GraphFocus("Document", 1));
        Assert.Empty(client.Requests);
        Assert.Equal("Database Offline", page.PageEmptyState?.Title);
    }
}

using Garage.App.Core.Corpus;
using Garage.App.Core.Facts;
using Garage.App.Core.Tests.TestSupport;
using Grpc.Core;

namespace Garage.App.Core.Tests;

// Ported from macapp/Tests/GarageAppUnitTests/FactListItemTests.swift, plus the page's loading.
public sealed class FactsTests
{
    private static FactSummary Summary(string excerpt = "", int excerptStart = 0, (int, int)? span = null, string attributes = "")
    {
        var summary = new FactSummary
        {
            Id = 7,
            DocumentId = 3,
            Fact = "The heat pump was installed in March 2024.",
            FactClass = "event",
            DocumentUri = "/notes/house.md",
            SourceSlug = "notes",
            CorpusClass = "document",
            Excerpt = excerpt,
            ExcerptStart = excerptStart,
            AttributesJson = attributes,
        };
        if (span is var (start, end))
        {
            summary.CharStart = start;
            summary.CharEnd = end;
        }
        return summary;
    }

    [Fact]
    public void Maps_the_summary_and_falls_back_to_the_file_name_for_title()
    {
        FactListItem item = FactListItem.From(Summary());
        Assert.Equal(7, item.Id);
        Assert.Equal(3, item.DocumentId);
        Assert.Equal("event", item.FactClass);
        Assert.Null(item.CharStart);
        Assert.Equal("house.md", item.DocumentDisplayTitle);
    }

    [Fact]
    public void Grounded_excerpt_splits_around_the_span()
    {
        // The excerpt starts 100 characters into the document; the span is "heat pump".
        GroundedExcerpt grounded = FactListItem.From(Summary("Our heat pump works.", 100, (104, 113))).Grounded!;
        Assert.Equal("Our ", grounded.Before);
        Assert.Equal("heat pump", grounded.Span);
        Assert.Equal(" works.", grounded.After);
    }

    [Fact]
    public void Grounded_excerpt_counts_unicode_scalars_like_python()
    {
        // "é" written as e + combining accent is two scalars (and two Python indices).
        Assert.Equal("opens", FactListItem.From(Summary("Café opens at 8.", 0, (6, 11))).Grounded!.Span);
        // An emoji is one scalar but two UTF-16 units: counting chars would land two places late.
        Assert.Equal("opens", FactListItem.From(Summary("🏠🔥 opens at 8.", 0, (3, 8))).Grounded!.Span);
    }

    [Fact]
    public void No_grounded_excerpt_without_a_span_or_outside_the_excerpt()
    {
        Assert.Null(FactListItem.From(Summary("text")).Grounded);
        Assert.Null(FactListItem.From(Summary(span: (0, 4))).Grounded);
        Assert.Null(FactListItem.From(Summary("short", 10, (12, 40))).Grounded);
    }

    [Fact]
    public void Attributes_are_sorted_and_rendered_as_text()
    {
        FactListItem item = FactListItem.From(Summary(attributes: """{"when": "2024-03", "cost": 12000, "parts": ["pump", "valve"], "who": {"b": 1, "a": null}}"""));
        Assert.Equal(["cost", "parts", "when", "who"], item.Attributes.Select(a => a.Key));
        Assert.Equal(["12000", """["pump","valve"]""", "2024-03", """{"a":null,"b":1}"""], item.Attributes.Select(a => a.Value));
        Assert.Empty(FactListItem.From(Summary(attributes: "not json")).Attributes);
        Assert.Empty(FactListItem.From(Summary(attributes: "[1, 2]")).Attributes);
    }

    [Fact]
    public async Task Refresh_loads_a_page_the_classes_and_the_counts_under_the_filters()
    {
        var client = new FakeGarageClient
        {
            OnListFacts = r => new ListFactsResponse
            {
                TotalCount = 450,
                Facts = { Enumerable.Range(1, FactsViewModel.PageSize).Select(i => new FactSummary { Id = i, Fact = $"fact {i}" }) },
                Classes = { new Garage.FactClassCount { FactClass = "event", Count = 300 } },
            },
            OnFactStats = _ => new FactStatsResponse { Facts = 450, Documents = 87 },
        };
        var facts = new FactsViewModel(client) { SearchText = "  pump ", Source = "notes", FactClass = CorpusTaxonomy.All, CorpusClass = "document" };
        using var culture = new CultureScope("en-US");

        await facts.RefreshAsync(TestContext.Current.CancellationToken);

        ListFactsRequest sent = client.Requests.OfType<ListFactsRequest>().Single();
        Assert.Equal(("pump", "notes", "", "document", 200, 0), (sent.Query, sent.Source, sent.FactClass, sent.CorpusClass, sent.Limit, sent.Offset));
        Assert.Equal(200, facts.Facts.Count);
        Assert.Equal("450 facts from 87 documents", facts.CountText);
        Assert.Equal("event (300)", facts.Classes.Single().Label);
        Assert.True(facts.CanLoadMore);

        await facts.LoadMoreAsync(TestContext.Current.CancellationToken);
        Assert.Equal(200, client.Requests.OfType<ListFactsRequest>().Last().Offset);
    }

    [Fact]
    public async Task A_failed_load_says_why()
    {
        var client = new FakeGarageClient { OnListFacts = _ => throw FakeGarageClient.Failure(StatusCode.Unavailable, "server gone") };
        var facts = new FactsViewModel(client);
        await facts.RefreshAsync(TestContext.Current.CancellationToken);
        Assert.Equal(("Failed to Load Facts", "server gone"), facts.EmptyState);
        Assert.False(facts.CanLoadMore);
    }
}

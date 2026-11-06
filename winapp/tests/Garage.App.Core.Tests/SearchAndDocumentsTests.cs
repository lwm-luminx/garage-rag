using Garage.App.Core.Corpus;
using Garage.App.Core.Documents;
using Garage.App.Core.Search;
using Garage.App.Core.Tests.TestSupport;
using Grpc.Core;

namespace Garage.App.Core.Tests;

public sealed class SearchAndDocumentsTests
{
    [Theory]
    [InlineData("Design notes", "/a/b.md", "", "Design notes")]
    [InlineData("(untitled)", "/a/b.md", "Intro › Scope", "Intro › Scope")]
    [InlineData("", @"C:\Users\me\Notes\plan.docx", "", "plan.docx")]
    [InlineData("", "/notes/house.md/", "", "house.md")]
    [InlineData("", "", "", "(untitled)")]
    public void Display_titles_fall_back_as_on_the_mac(string title, string uri, string heading, string expected) =>
        Assert.Equal(expected, CorpusTaxonomy.DisplayTitle(title, uri, heading));

    [Fact]
    public void Filters_treat_all_and_blank_as_none()
    {
        Assert.Null(CorpusTaxonomy.Filter("all"));
        Assert.Null(CorpusTaxonomy.Filter(" "));
        Assert.Equal("code", CorpusTaxonomy.Filter("code"));
        Assert.Equal(["all", "document", "code", "communication"], CorpusTaxonomy.WithAll(CorpusTaxonomy.CorpusClasses));
    }

    [Fact]
    public async Task Search_sends_the_query_mode_limit_and_filters_and_opens_the_first_hit()
    {
        var client = new FakeGarageClient
        {
            OnSearch = _ => new SearchResponse
            {
                Hits =
                {
                    new SearchHit { Rank = 1, Title = "Consensus", Uri = "/n/raft.md", MatchedBy = "hybrid", Score = 0.0328f, Text = "full", Snippet = "snip" },
                    new SearchHit { Rank = 2, Uri = "/n/paxos.md" },
                },
            },
        };
        var search = new SearchViewModel(client)
        {
            Query = "  distributed consensus ",
            Mode = SearchMode.All[1],
            Limit = 500,
            CorpusClass = "document",
            TrustTier = CorpusTaxonomy.All,
            Source = "notes",
        };

        await search.SearchAsync(TestContext.Current.CancellationToken);

        SearchRequest sent = client.Requests.OfType<SearchRequest>().Single();
        Assert.Equal("distributed consensus", sent.Query);
        Assert.Equal("vector", sent.Mode);
        Assert.Equal(SearchViewModel.MaxLimit, sent.Limit);
        Assert.True(sent.Full);
        Assert.Equal(["document"], sent.CorpusClasses);
        Assert.Empty(sent.TrustTiers);
        Assert.Equal(["notes"], sent.Sources);

        Assert.Equal(2, search.Results.Count);
        Assert.Equal(search.Results[0], search.SelectedResult);
        Assert.Equal("Score: 0.0328", search.Results[0].ScoreText);
        Assert.True(search.Results[0].HasDistinctSnippet);
        Assert.Equal("paxos.md", search.Results[1].DisplayTitle);
        Assert.StartsWith("2 results for 'distributed consensus'", search.StatusText, StringComparison.Ordinal);
        Assert.Null(search.EmptyState);
    }

    [Fact]
    public async Task A_blank_query_does_nothing()
    {
        var client = new FakeGarageClient();
        var search = new SearchViewModel(client) { Query = "   " };
        await search.SearchAsync(TestContext.Current.CancellationToken);
        Assert.Empty(client.Requests);
        Assert.Equal("Search Knowledge Base", search.EmptyState!.Value.Title);
        Assert.Equal("Ready", search.StatusText);
    }

    [Fact]
    public async Task No_hits_and_failures_say_so_in_the_macs_words()
    {
        var client = new FakeGarageClient();
        var search = new SearchViewModel(client) { Query = "zebra" };
        await search.SearchAsync(TestContext.Current.CancellationToken);
        Assert.Equal(("No Results Found", "No documents matched 'zebra'. Try adjusting the search terms, mode, or filters."), search.EmptyState);

        client.OnSearch = _ => throw FakeGarageClient.Failure(StatusCode.Unavailable, "database is offline");
        await search.SearchAsync(TestContext.Current.CancellationToken);
        Assert.Equal(("Search Failed", "database is offline"), search.EmptyState);
        Assert.Equal("Ready", search.StatusText);
    }

    [Fact]
    public async Task Sources_fill_the_filter_sorted_after_all()
    {
        var client = new FakeGarageClient
        {
            OnListSources = _ => new ListSourcesResponse { Sources = { new SourceInfo { Slug = "notes" }, new SourceInfo { Slug = "code" } } },
        };
        var search = new SearchViewModel(client);
        await search.LoadSourcesAsync(TestContext.Current.CancellationToken);
        Assert.Equal(["all", "code", "notes"], search.Sources);
    }

    [Fact]
    public async Task Documents_list_under_the_filters_and_drop_a_selection_no_longer_listed()
    {
        var client = new FakeGarageClient
        {
            OnListDocuments = _ => new ListDocumentsResponse
            {
                TotalCount = 1204,
                Documents = { new DocumentSummary { Id = 1, Uri = "/n/a.md", ChunkCount = 12, FactCount = 3 }, new DocumentSummary { Id = 2, Title = "B", ChunkCount = 1 } },
            },
        };
        using var culture = new CultureScope("en-US");
        var documents = new DocumentsViewModel(client)
        {
            SearchText = " plan ",
            TrustTier = "authored",
            Selected = new DocumentListItem(99, "", "", "", "", "", "", 0, 0, 0, "", ""),
        };

        await documents.RefreshAsync(TestContext.Current.CancellationToken);

        ListDocumentsRequest sent = client.Requests.OfType<ListDocumentsRequest>().Single();
        Assert.Equal(("plan", "", "", "authored", 200), (sent.Query, sent.Source, sent.CorpusClass, sent.TrustTier, sent.Limit));
        Assert.Equal("2 of 1,204 documents", documents.CountText);
        Assert.Equal("12 chunks · 3 facts", documents.Documents[0].Counts);
        Assert.Equal("1 chunk", documents.Documents[1].Counts);
        Assert.Null(documents.Selected);
    }

    [Fact]
    public async Task Document_detail_orders_chunks_and_names_authors()
    {
        var client = new FakeGarageClient
        {
            OnGetDocument = r => new GetDocumentResponse
            {
                Document = new Garage.DocumentDetail
                {
                    Id = r.DocumentId,
                    Uri = "/n/a.md",
                    CorpusClass = "document",
                    TrustTier = "authored",
                    SourceSlug = "notes",
                    Mime = "text/markdown",
                    ByteSize = 4096,
                    Extractor = "markdown",
                    ExtractorVersion = "3",
                    Chunker = "recursive:1000/150",
                    Authors = { new DocumentAuthorInfo { Name = "Rick", Role = "author" }, new DocumentAuthorInfo { Name = "Ada", Role = "editor" } },
                },
                Chunks = { new DocumentChunkInfo { Ord = 1, Text = "second", TokenCount = 1 }, new DocumentChunkInfo { Ord = 0, Text = "first", TokenCount = 2, HeadingPath = "Intro" } },
            },
        };
        using var culture = new CultureScope("en-US");
        var documents = new DocumentsViewModel(client) { Selected = new DocumentListItem(5, "/n/a.md", "", "", "", "", "", 0, 0, 0, "", "") };

        await documents.LoadDetailAsync(TestContext.Current.CancellationToken);

        Garage.App.Core.Documents.DocumentDetail detail = documents.Detail!;
        Assert.Equal(["first", "second"], detail.Chunks.Select(c => c.Text));
        Assert.Equal("#0 · 2 tokens · Intro", detail.Chunks[0].Caption);
        Assert.Equal(["Rick", "Ada (editor)"], detail.Authors);
        Assert.Equal("document · authored · notes · text/markdown · 4 KB", detail.Summary);
        Assert.Equal("markdown 3 · recursive:1000/150", detail.ExtractedBy);
    }

    [Theory]
    [InlineData(0, "0 bytes")]
    [InlineData(1, "1 byte")]
    [InlineData(999, "999 bytes")]
    [InlineData(4096, "4 KB")]
    [InlineData(5_000_000, "5 MB")]
    [InlineData(1_234_000_000, "1.2 GB")]
    public void Sizes_use_decimal_units_like_the_mac(long bytes, string expected)
    {
        using var culture = new CultureScope("en-US");
        Assert.Equal(expected, Bytes.Format(bytes));
    }
}

using Garage.App.Core.Documents;
using Garage.App.Core.Tests.TestSupport;

namespace Garage.App.Core.Tests;

// Large corpora (windows-ui.md U5): the Documents list pages through the corpus as it scrolls,
// never asking for it all at once.
public sealed class DocumentsPagingTests
{
    private static FakeGarageClient Corpus(int total) => new()
    {
        OnListDocuments = r => new ListDocumentsResponse
        {
            TotalCount = total,
            Documents = { Enumerable.Range(r.Offset + 1, Math.Max(0, Math.Min(r.Limit, total - r.Offset))).Select(i => new DocumentSummary { Id = i, Title = $"Note {i}", Uri = $@"C:\n\{i}.md" }) },
        },
    };

    [Fact]
    public async Task Load_more_appends_the_next_page_until_the_corpus_is_listed()
    {
        FakeGarageClient client = Corpus(450);
        var documents = new DocumentsViewModel(client);
        await documents.RefreshAsync(TestContext.Current.CancellationToken);
        Assert.Equal(200, documents.Documents.Count);
        Assert.Equal("200 of 450 documents", documents.CountText);
        Assert.True(documents.CanLoadMore);

        await documents.LoadMoreAsync(TestContext.Current.CancellationToken);
        await documents.LoadMoreAsync(TestContext.Current.CancellationToken);
        Assert.Equal(450, documents.Documents.Count);
        Assert.Equal("450 documents", documents.CountText);
        Assert.False(documents.CanLoadMore);
        Assert.Equal([0, 200, 400], client.Requests.OfType<ListDocumentsRequest>().Select(r => r.Offset));

        // Nothing more is asked for once everything is listed.
        await documents.LoadMoreAsync(TestContext.Current.CancellationToken);
        Assert.Equal(3, client.Requests.OfType<ListDocumentsRequest>().Count());
    }

    [Fact]
    public async Task A_refresh_starts_again_from_the_first_page()
    {
        FakeGarageClient client = Corpus(25_000);
        var documents = new DocumentsViewModel(client);
        await documents.RefreshAsync(TestContext.Current.CancellationToken);
        await documents.LoadMoreAsync(TestContext.Current.CancellationToken);
        Assert.Equal(400, documents.Documents.Count);
        documents.SearchText = "note";
        await documents.RefreshAsync(TestContext.Current.CancellationToken);
        Assert.Equal(200, documents.Documents.Count);
        Assert.Equal("200 of 25,000 documents", documents.CountText);
        Assert.Equal(0, client.Requests.OfType<ListDocumentsRequest>().Last().Offset);
    }
}

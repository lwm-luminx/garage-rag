using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using Garage.Plugin.V1;
using Google.Protobuf;

namespace Garage.Plugins.Tests;

/// <summary>
/// The text reader through its C ABI. Needs the library built by <c>cargo build --release</c> in
/// <c>rust/</c>, named by <c>GARAGE_TEXT_FFI_LIBRARY</c>; every test skips without it.
/// </summary>
public sealed class NativeTextReaderTests
{
    private static readonly string? LibraryPath = Environment.GetEnvironmentVariable("GARAGE_TEXT_FFI_LIBRARY");

    static NativeTextReaderTests()
    {
        if (!string.IsNullOrEmpty(LibraryPath))
        {
            NativeLibrary.SetDllImportResolver(
                typeof(NativeTextReader).Assembly,
                (name, _, _) => name == NativeTextReader.LibraryName ? NativeLibrary.Load(LibraryPath) : IntPtr.Zero);
        }
    }

    private static NativeTextReader Reader()
    {
        Assert.SkipWhen(string.IsNullOrEmpty(LibraryPath), "GARAGE_TEXT_FFI_LIBRARY names no library");
        return new NativeTextReader();
    }

    private static ExtractResponse Extract(string fileName, string content, string extractor = "") =>
        Reader().Extract(new ExtractRequest
        {
            Extractor = extractor,
            FileName = fileName,
            Content = ByteString.CopyFrom(Encoding.UTF8.GetBytes(content)),
        });

    [Fact]
    public void SpeaksContractOne()
    {
        Reader();
        Assert.Equal(ContractVersion._1, NativeTextReader.Contract);
    }

    [Fact]
    public void DescribesItsThreeExtractors()
    {
        DescribeResponse described = Reader().Describe(new DescribeRequest { Contract = ContractVersion._1 });
        Assert.Equal("garage-text", described.Name);
        Assert.Equal(ContractVersion._1, described.Contract);
        Assert.Equal(["markdown", "plaintext", "code"], described.Extractors.Select(e => e.Name));
        Assert.Contains(".md", described.Extractors[0].Extensions);
        Assert.Contains("makefile", described.Extractors[2].FileNames);
        Assert.All(described.Extractors, e => Assert.Equal("1", e.Version));
    }

    [Fact]
    public void ReadsMarkdownWithFrontMatter()
    {
        ExtractResponse response = Extract("note.md", "---\r\ntitle: A Note\r\nauthors: [Ada, yes]\r\n---\r\n# Heading\r\n\r\n\r\n\r\nBody\r\n");
        Assert.Equal(ExtractResponse.OutcomeOneofCase.Document, response.OutcomeCase);
        Document document = response.Document;
        Assert.Equal("# Heading\n\n\nBody", document.Text);
        Assert.Equal(ContentKind.Markdown, document.Kind);
        Assert.Equal("markdown", document.Extractor);
        Assert.Equal("A Note", document.Title);
        Assert.Equal(["Ada", "True"], document.AuthorHints);
        using JsonDocument meta = JsonDocument.Parse(document.MetaJson);
        Assert.Equal("utf-8", meta.RootElement.GetProperty("encoding").GetString());
        Assert.Equal("A Note", meta.RootElement.GetProperty("frontmatter").GetProperty("title").GetString());
    }

    [Fact]
    public void ReadsCodeVerbatim()
    {
        Document document = Extract("Makefile", "all:\r\n\tcc main.c\r\n\r\n\r\n").Document;
        Assert.Equal(ContentKind.Code, document.Kind);
        Assert.Equal("all:\n\tcc main.c\n\n\n", document.Text);
        Assert.Equal("Makefile", document.Title);
    }

    [Fact]
    public void AnswersOutcomesInTheResponse()
    {
        Assert.Equal(ExtractResponse.OutcomeOneofCase.NoText, Extract("blank.txt", " \n\t").OutcomeCase);
        ExtractResponse unsupported = Extract("scan.pdf", "%PDF-1.7");
        Assert.Equal(ExtractResponse.OutcomeOneofCase.Failure, unsupported.OutcomeCase);
        Assert.Equal(Failure.Types.Code.Unsupported, unsupported.Failure.Code);
        Assert.Equal("plaintext", Extract("note.md", "# x", extractor: "plaintext").Document.Extractor);
    }

    [Fact]
    public void ThrowsWhenTheRequestDoesNotDecode()
    {
        // Field 31, length-delimited, with a length that runs past the end.
        Reader();
        var error = Assert.Throws<NativePluginException>(() => NativeTextReader.ExtractSerialized([0xFA, 0x01, 0x7F]));
        Assert.Equal(1, error.Status);
        Assert.StartsWith("request does not decode", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void IsSafeToCallFromManyThreads()
    {
        NativeTextReader reader = Reader();
        Parallel.For(0, 64, i =>
        {
            ExtractResponse response = reader.Extract(new ExtractRequest
            {
                FileName = $"n{i}.md",
                Content = ByteString.CopyFromUtf8($"# Title {i}\nbody"),
            });
            Assert.Equal($"Title {i}", response.Document.Title);
        });
    }
}

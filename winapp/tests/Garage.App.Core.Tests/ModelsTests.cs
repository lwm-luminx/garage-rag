using Garage.App.Core.Database;
using Garage.App.Core.Models;
using Garage.App.Core.Operations;
using Garage.App.Core.Tests.TestSupport;

namespace Garage.App.Core.Tests;

// Ported from macapp/Tests/GarageAppUnitTests/ModelsPresentationTests.swift. The llama rows (resident
// models, slots) follow the llama service (windows.md Phase 4).
public sealed class ModelsTests
{
    private static CorpusStats Stats(long totalChunks, params (string Slug, long Embedded)[] embedded) =>
        new(TotalChunks: totalChunks, ModelStats: [.. embedded.OrderBy(e => e.Slug, StringComparer.Ordinal).Select(e => new ModelEmbeddingStats(e.Slug, false, e.Embedded))]);

    [Fact]
    public void Required_and_missing_count_every_registered_model()
    {
        (long required, long missing) = ModelsPresentation.EmbeddingsRequiredAndMissing(["bge-m3", "nomic"], Stats(1000, ("bge-m3", 1000), ("nomic", 400)));
        Assert.Equal(2000, required);
        Assert.Equal(600, missing);
    }

    [Fact]
    public void A_model_the_stats_do_not_list_yet_is_wholly_unembedded() =>
        Assert.Equal((1000L, 500L), ModelsPresentation.EmbeddingsRequiredAndMissing(["bge-m3", "just-added"], Stats(500, ("bge-m3", 500))));

    [Fact]
    public void A_model_no_longer_registered_is_not_counted() =>
        Assert.Equal((500L, 0L), ModelsPresentation.EmbeddingsRequiredAndMissing(["bge-m3"], Stats(500, ("bge-m3", 500), ("dropped", 0))));

    [Fact]
    public void More_vectors_than_chunks_never_counts_below_zero() =>
        Assert.Equal(0, ModelsPresentation.EmbeddingsRequiredAndMissing(["bge-m3"], Stats(100, ("bge-m3", 120))).Missing);

    [Fact]
    public void Summary_lines()
    {
        using var culture = new CultureScope("en-US");
        Assert.StartsWith("Text embedding models turn each chunk into a vector", ModelsPresentation.EmbeddingSummary(0, 1000, 0, 0), StringComparison.Ordinal);
        Assert.Equal("1 model · no chunks to embed until a source is ingested", ModelsPresentation.EmbeddingSummary(1, 0, 0, 0));
        Assert.Equal("2 models · every chunk embedded", ModelsPresentation.EmbeddingSummary(2, 500, 1000, 0));
        Assert.Equal("2 models · 9,120 of 10,000 embeddings done", ModelsPresentation.EmbeddingSummary(2, 5000, 10000, 880));
    }

    [Fact]
    public void Which_rows_say_embedding()
    {
        Assert.False(ModelsPresentation.IsEmbedding("bge-m3", false, "bge-m3"));
        Assert.False(ModelsPresentation.IsEmbedding("bge-m3", false, "*"));
        Assert.True(ModelsPresentation.IsEmbedding("bge-m3", true, "bge-m3"));
        Assert.False(ModelsPresentation.IsEmbedding("nomic", true, "bge-m3"));
        Assert.True(ModelsPresentation.IsEmbedding("nomic", true, "*"));
        Assert.True(ModelsPresentation.IsEmbedding("nomic", true, null), "a run started elsewhere covers every model");
    }

    [Fact]
    public void Headline_kinds_in_the_macs_order()
    {
        Assert.Equal(EmbeddingHeadlineKind.NoModel, ModelsPresentation.HeadlineKind(0, [], 100, 0, false));
        Assert.Equal(EmbeddingHeadlineKind.FilesMissing, ModelsPresentation.HeadlineKind(2, ["BGE-M3"], 0, 0, true));
        Assert.Equal(EmbeddingHeadlineKind.WaitingForIngest, ModelsPresentation.HeadlineKind(1, [], 0, 0, false));
        Assert.Equal(EmbeddingHeadlineKind.Ready, ModelsPresentation.HeadlineKind(1, [], 100, 0, true));
        Assert.Equal(EmbeddingHeadlineKind.Embedding, ModelsPresentation.HeadlineKind(1, [], 100, 40, true));
        Assert.Equal(EmbeddingHeadlineKind.ToGo, ModelsPresentation.HeadlineKind(1, [], 100, 40, false));
    }

    [Fact]
    public void Headline_wording()
    {
        using var culture = new CultureScope("en-US");
        Assert.Equal("Search ready", ModelsPresentation.Headline(1, [], 2226, 2226, 0, false).Title);
        Assert.Equal("2,226 chunks embedded under 1 model.", ModelsPresentation.Headline(1, [], 2226, 2226, 0, false).Detail);
        ModelsHeadline toGo = ModelsPresentation.Headline(1, [], 2226, 2226, 2000, false);
        Assert.Equal("2,000 embeddings to go", toGo.Title);
        Assert.Equal(226.0 / 2226, toGo.Progress!.Value, 6);
        Assert.Equal("Embedding…", ModelsPresentation.Headline(1, [], 2226, 2226, 1, true).Title);
        Assert.Equal("1 embedding to go", ModelsPresentation.Headline(1, [], 2226, 2226, 1, false).Title);
    }

    [Fact]
    public void Providers_parse_as_on_the_mac()
    {
        Assert.Equal(ModelProvider.BuiltIn, ModelProviders.From("llama_xpc"));
        Assert.Equal(ModelProvider.Ollama, ModelProviders.From(" Ollama "));
        Assert.Equal(ModelProvider.LmStudio, ModelProviders.From("lmstudio"));
        Assert.Equal(ModelProvider.LmStudio, ModelProviders.From("LM Studio"));
        Assert.Equal(ModelProvider.BuiltIn, ModelProviders.From(null));
        Assert.Equal("lmstudio", ModelProvider.LmStudio.CliValue());
        Assert.Equal("llama_xpc", ModelProvider.BuiltIn.CliValue());
        Assert.Equal("Built-in engine", ModelProvider.BuiltIn.DisplayName());
    }

    [Fact]
    public async Task The_page_lists_models_with_their_progress_and_the_distillation_model()
    {
        var client = new FakeGarageClient
        {
            OnListModels = _ => new ListModelsResponse
            {
                Models =
                {
                    new ModelInfo { Slug = "nomic", Provider = "ollama", Dims = 768 },
                    new ModelInfo { Slug = "bge-m3", Provider = "ollama", ModelRef = "bge-m3", Dims = 1024, Distance = "cosine", IsDefault = true },
                },
            },
            OnStats = _ => new StatsResponse { Chunks = 2226, ChunksByModel = { ["bge-m3"] = 2226, ["nomic"] = 226 } },
            OnGetSetting = r => new GetSettingResponse { Name = r.Name, ValueJson = r.Name == "facts.provider" ? "\"ollama\"" : "\"gemma2:2b\"" },
        };
        var page = new ModelsViewModel(client, new OperationRunner(), new OperationRunner("backfill"));
        using var culture = new CultureScope("en-US");

        await page.LoadAsync(TestContext.Current.CancellationToken);

        Assert.Equal(["bge-m3", "nomic"], page.Models.Select(m => m.Slug));
        Assert.Equal("Ollama · bge-m3 · 1024 dims · cosine", page.Models[0].Detail);
        Assert.Equal("226 of 2,226 chunks embedded", page.Models[1].Progress);
        Assert.Equal("2 models · 2,452 of 4,452 embeddings done", page.Summary);
        Assert.Equal("2,000 embeddings to go", page.Headline!.Title);
        Assert.Equal(ModelProvider.Ollama, page.FactsProvider);
        Assert.Equal("gemma2:2b", page.FactsModel);
    }

    [Fact]
    public async Task Embed_streams_its_progress_on_the_backfill_runner()
    {
        var backfill = new OperationRunner("backfill");
        var operations = new OperationRunner("garage");
        List<string?> seen = [];
        var client = new FakeGarageClient
        {
            OnBackfill = _ =>
            [
                new BackfillStatus { ModelSlug = "bge-m3", Phase = "started", Total = 2226, Remaining = 2226 },
                new BackfillStatus { ModelSlug = "bge-m3", Phase = "progress", Total = 2226, Embedded = 1000, Remaining = 1226 },
                new BackfillStatus { ModelSlug = "bge-m3", Phase = "finished", Total = 2226, Embedded = 2226, Remaining = 0, Message = "embedded 2,226 chunks" },
            ],
        };
        var page = new ModelsViewModel(client, operations, backfill);
        page.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(ModelsViewModel.BackfillProgress))
            {
                seen.Add(page.BackfillProgress);
            }
        };
        using var culture = new CultureScope("en-US");

        OperationResult result = await page.EmbedAsync("bge-m3");

        Assert.Equal("bge-m3", client.Requests.OfType<BackfillRequest>().Single().Model);
        Assert.Equal(["Starting…", "bge-m3: 2,226 chunks to embed", "bge-m3: 1,000 of 2,226 embedded", "bge-m3: embedded 2,226 chunks", null], seen);
        Assert.Equal("bge-m3: embedded 2,226 chunks", result.Output);
        Assert.Contains(backfill.Logs, l => l.Text == "bge-m3: embedded 2,226 chunks");
        Assert.Empty(operations.Logs);
        Assert.Null(page.BackfillTarget);
    }

    [Fact]
    public async Task Register_set_default_and_drop()
    {
        var client = new FakeGarageClient { OnRegisterModel = r => new RegisterModelResponse { Message = $"registered {r.Slug}", Notes = { "created emb_bge_m3" } } };
        var page = new ModelsViewModel(client, new OperationRunner(), new OperationRunner("backfill"));

        OperationResult registered = await page.RegisterAsync(new NewModel(" bge-m3 ", ModelProvider.Ollama, 1024, MakeDefault: true));
        RegisterModelRequest sent = client.Requests.OfType<RegisterModelRequest>().Single();
        Assert.Equal(("bge-m3", "ollama", 1024, true), (sent.Slug, sent.Provider, sent.Dims, sent.MakeDefault));
        Assert.Equal("registered bge-m3\ncreated emb_bge_m3", registered.Output);

        Assert.Equal("default is nomic", (await page.SetDefaultAsync("nomic")).Output);
        Assert.Equal("dropped nomic", (await page.DropAsync("nomic")).Output);

        OperationResult saved = await page.SaveFactsModelAsync(ModelProvider.Ollama, " gemma2:2b ");
        Assert.Equal([("facts.provider", "ollama"), ("facts.model", "gemma2:2b")], client.Requests.OfType<SetSettingRequest>().Select(r => (r.Name, r.Value)));
        Assert.StartsWith("Distillation model: gemma2:2b via Ollama", saved.Output, StringComparison.Ordinal);
    }

    [Fact]
    public void A_message_that_names_its_model_is_not_prefixed_again()
    {
        Assert.Equal("bge-m3: embedded 3", ModelsViewModel.Describe(new BackfillStatus { ModelSlug = "bge-m3", Phase = "finished", Message = "bge-m3: embedded 3" }));
        Assert.Equal("bge-m3: embedded 3", ModelsViewModel.Describe(new BackfillStatus { ModelSlug = "bge-m3", Phase = "finished", Message = "embedded 3" }));
        Assert.Equal("embedded 3", ModelsViewModel.Describe(new BackfillStatus { Phase = "finished", Message = "embedded 3" }));
    }

    [Theory]
    [InlineData("\"ollama\"", "ollama")]
    [InlineData("[\"a\", \"b\"]", "a, b")]
    [InlineData("42", "42")]
    [InlineData("null", null)]
    [InlineData("", null)]
    public void Setting_values_read_as_text(string json, string? expected) => Assert.Equal(expected, SettingValue.Text(json));
}

using System.Text.Json.Nodes;
using Garage.App.Core.Facts;
using Garage.App.Core.Operations;
using Garage.App.Core.Tests.TestSupport;

namespace Garage.App.Core.Tests;

// Ported from macapp/Tests/GarageAppUnitTests/FactPromptConfigTests.swift, plus the section's saving.
public sealed class FactPromptTests
{
    private const string Examples = """[{"text": "Jane met Bob.", "extractions": [{"class": "person", "text": "Jane"}]}]""";

    private static List<JsonObject> Entries(string json) => FactPromptConfig.Parse(json);

    private static string? Name(JsonObject entry) => entry["name"]?.GetValue<string>();

    private static FactPromptItem People(bool enabled = true) =>
        new("people", "List every person named.", Examples, ["document"], [], enabled);

    [Fact]
    public void Saving_a_new_prompt_appends_it_in_full()
    {
        string json = FactPromptConfig.Saving(People(), null, """[{"name": "default", "enabled": false}]""", new HashSet<string> { "default" });
        List<JsonObject> saved = Entries(json);
        Assert.Equal(["default", "people"], saved.Select(Name));
        Assert.False(saved[0]["enabled"]!.GetValue<bool>());
        Assert.Equal("List every person named.", saved[1]["description"]!.GetValue<string>());
        Assert.Equal(["document"], saved[1]["corpus_classes"]!.AsArray().Select(c => c!.GetValue<string>()));
        Assert.True(saved[1]["enabled"]!.GetValue<bool>());
        Assert.Equal("Jane met Bob.", saved[1]["examples"]![0]!["text"]!.GetValue<string>());
    }

    [Fact]
    public void Saving_a_rename_replaces_the_old_entry()
    {
        string configured = FactPromptConfig.Saving(People(), null, "[]", new HashSet<string> { "default" });
        string json = FactPromptConfig.Saving(People() with { Name = "names" }, "people", configured, new HashSet<string> { "default" });
        Assert.Equal(["names"], Entries(json).Select(Name));
    }

    [Fact]
    public void Saving_keeps_the_graph_block_the_editor_does_not_show()
    {
        const string configured = """[{"name": "people", "description": "Old.", "examples": [], "graph": {"vertices": [{"class": "person", "label": "Person"}]}}]""";
        JsonObject saved = Entries(FactPromptConfig.Saving(People(), null, configured, new HashSet<string> { "default" })).Single();
        Assert.Equal("List every person named.", saved["description"]!.GetValue<string>());
        Assert.Equal("Person", saved["graph"]!["vertices"]![0]!["label"]!.GetValue<string>());
    }

    [Fact]
    public void Saving_refuses_bad_input()
    {
        var none = new HashSet<string>();
        Assert.Contains("not a valid prompt name", Assert.Throws<FactPromptConfigException>(() => FactPromptConfig.Saving(People() with { Name = "has space" }, null, "[]", none)).Message, StringComparison.Ordinal);
        Assert.Contains("already exists", Assert.Throws<FactPromptConfigException>(() => FactPromptConfig.Saving(People(), null, "[]", new HashSet<string> { "people" })).Message, StringComparison.Ordinal);
        Assert.Equal("The instructions must not be empty.", Assert.Throws<FactPromptConfigException>(() => FactPromptConfig.Saving(People() with { Description = "  \n" }, null, "[]", none)).Message);
        foreach (string broken in new[] { "not json", "[]", """{"text": "x"}""", """[{"extractions": []}]""", """[{"text": "x", "extractions": 3}]""" })
        {
            Assert.Throws<FactPromptConfigException>(() => FactPromptConfig.Saving(People() with { ExamplesJson = broken }, null, "[]", none));
        }
    }

    [Fact]
    public void Toggling_a_built_in_adds_a_minimal_override_and_keeps_other_keys()
    {
        List<JsonObject> disabled = Entries(FactPromptConfig.SettingEnabled(false, "default", "[]"));
        Assert.Single(disabled);
        Assert.Equal("default", Name(disabled[0]));
        Assert.False(disabled[0]["enabled"]!.GetValue<bool>());

        List<JsonObject> enabled = Entries(FactPromptConfig.SettingEnabled(true, "default", """[{"name": "default", "description": "Mine.", "enabled": false}]"""));
        Assert.Equal("Mine.", enabled[0]["description"]!.GetValue<string>());
        Assert.True(enabled[0]["enabled"]!.GetValue<bool>());
    }

    [Fact]
    public void Removing_drops_only_that_entry()
    {
        const string configured = """[{"name": "default", "enabled": false}, {"name": "people", "description": "d"}]""";
        Assert.Equal(["people"], Entries(FactPromptConfig.Removing("default", configured)).Select(Name));
        Assert.Empty(FactPromptConfig.Parse("garbage"));
    }

    [Fact]
    public void Item_from_proto_and_its_scope()
    {
        FactPromptItem item = FactPromptItem.From(new FactPrompt
        {
            Name = "default",
            Description = "Extract every standalone fact.",
            ExamplesJson = Examples,
            Enabled = true,
            Builtin = true,
            Sha256 = new string('a', 64),
        });
        Assert.Equal("default", item.Name);
        Assert.True(item.Builtin);
        Assert.False(item.Customized);
        Assert.Equal("BUILT-IN", item.Badge);
        Assert.Equal("all documents", item.ScopeSummary);
        Assert.Equal("all documents · aaaaaaaaaaaa", item.Caption);
        Assert.Equal("document", People().ScopeSummary);
        Assert.Equal("BUILT-IN, CUSTOMIZED", (item with { Customized = true }).Badge);
    }

    [Fact]
    public void A_blank_prompt_picks_a_free_name_and_valid_examples()
    {
        FactPromptItem blank = FactPromptItem.Blank(new HashSet<string> { "prompt", "prompt-2" });
        Assert.Equal("prompt-3", blank.Name);
        FactPromptConfig.ParseExamples(blank.ExamplesJson);
        Assert.Contains('\n', FactPromptConfig.PrettyExamples(Examples));
    }

    [Fact]
    public async Task The_section_writes_facts_prompts_whole_and_rereads()
    {
        var client = new FakeGarageClient
        {
            OnListFactPrompts = _ => new ListFactPromptsResponse
            {
                Prompts = { new FactPrompt { Name = "default", Description = "d", ExamplesJson = Examples, Enabled = true, Builtin = true } },
                ConfiguredJson = "[]",
            },
        };
        var section = new FactPromptsViewModel(client);
        await section.LoadAsync(TestContext.Current.CancellationToken);
        Assert.Single(section.Prompts);

        Assert.Null(await section.SetEnabledAsync("default", false));
        SetSettingRequest set = client.Requests.OfType<SetSettingRequest>().Single();
        Assert.Equal("facts.prompts", set.Name);
        Assert.Equal("""[{"enabled":false,"name":"default"}]""", set.Value);
        Assert.Equal(2, client.Requests.OfType<ListFactPromptsRequest>().Count());

        // A refused prompt never reaches the server, and says why.
        string? refused = await section.SaveAsync(People() with { Name = "default" }, null);
        Assert.Contains("already exists", refused, StringComparison.Ordinal);
        Assert.Single(client.Requests.OfType<SetSettingRequest>());
    }

    [Fact]
    public async Task Run_gleans_with_just_that_prompt()
    {
        var client = new FakeGarageClient { OnEnrichFacts = _ => [new EnrichFactsStatus { Phase = "finished", Message = "done" }] };
        await FactPromptsViewModel.RunAsync(new FactsViewModel(client), new OperationRunner(), "people");
        EnrichFactsRequest request = client.Requests.OfType<EnrichFactsRequest>().Single();
        Assert.Equal(["people"], request.Prompts);
        Assert.False(request.StaleOnly);
    }
}

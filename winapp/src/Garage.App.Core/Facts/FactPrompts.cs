using System.Collections.ObjectModel;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using CommunityToolkit.Mvvm.ComponentModel;
using Garage.App.Core.Backend;
using Garage.App.Core.Operations;
using Grpc.Core;

namespace Garage.App.Core.Facts;

/// <summary>
/// One effective fact-extraction prompt, as <c>ListFactPrompts</c> reports it: the built-in
/// <c>default</c> (possibly overridden in garage.json) or a configured one. The Mac's <c>FactPromptItem</c>.
/// </summary>
public sealed record FactPromptItem(
    string Name, string Description, string ExamplesJson, IReadOnlyList<string> CorpusClasses, IReadOnlyList<string> Sources,
    bool Enabled = true, bool Builtin = false, bool Customized = false, string Sha256 = "")
{
    /// <summary>From a <c>FactPrompt</c>.</summary>
    public static FactPromptItem From(FactPrompt prompt)
    {
        ArgumentNullException.ThrowIfNull(prompt);
        return new(prompt.Name, prompt.Description, prompt.ExamplesJson, [.. prompt.CorpusClasses], [.. prompt.Sources],
            prompt.Enabled, prompt.Builtin, prompt.Customized, prompt.Sha256);
    }

    /// <summary>"all documents", or the classes and sources the prompt is limited to.</summary>
    public string ScopeSummary
    {
        get
        {
            List<string> parts = [.. CorpusClasses, .. Sources.Select(s => $"source {s}")];
            return parts.Count == 0 ? "all documents" : string.Join(", ", parts);
        }
    }

    /// <summary>"all documents · 3f9a0c2b71de": the scope and the start of the prompt's hash.</summary>
    public string Caption => Sha256.Length > 0 ? $"{ScopeSummary} · {Sha256[..Math.Min(12, Sha256.Length)]}" : ScopeSummary;

    /// <summary>"BUILT-IN", "BUILT-IN, CUSTOMIZED", or "" for a configured prompt.</summary>
    public string Badge => !Builtin ? "" : Customized ? "BUILT-IN, CUSTOMIZED" : "BUILT-IN";

    /// <summary>A starting point for a new prompt, named so it clashes with none of <paramref name="existingNames"/>.</summary>
    public static FactPromptItem Blank(IReadOnlySet<string> existingNames)
    {
        ArgumentNullException.ThrowIfNull(existingNames);
        string name = "prompt";
        for (int suffix = 2; existingNames.Contains(name); suffix++)
        {
            name = $"prompt-{suffix}";
        }
        var example = new JsonArray(new JsonObject
        {
            ["extractions"] = new JsonArray(new JsonObject { ["class"] = "fact", ["text"] = "Jane Doe joined Acme Corp in 2019 as its CFO." }),
            ["text"] = "Jane Doe joined Acme Corp in 2019 as its CFO.",
        });
        return new(name, "", FactPromptConfig.Pretty(example), [], []);
    }
}

/// <summary>Why a prompt cannot be saved: the Mac's <c>FactPromptConfigError</c> wording.</summary>
public sealed class FactPromptConfigException : Exception
{
    /// <summary>Creates one with no message.</summary>
    public FactPromptConfigException() : base("The prompt is not valid.")
    {
    }

    /// <summary>Creates one saying why.</summary>
    public FactPromptConfigException(string message) : base(message)
    {
    }

    /// <summary>Creates one wrapping another.</summary>
    public FactPromptConfigException(string message, Exception inner) : base(message, inner)
    {
    }
}

/// <summary>
/// Edits <c>facts.prompts</c> as garage.json holds it: a JSON array of entries the app writes back
/// whole through <c>SetSetting facts.prompts</c>. An entry named after a built-in overrides it field by
/// field; any other entry adds a prompt. Entries stay JSON objects, so keys the app does not edit (a
/// prompt's <c>graph</c> block) survive. A port of the Mac's <c>FactPromptConfig</c>.
/// </summary>
public static partial class FactPromptConfig
{
    /// <summary>The corpus classes a prompt can be limited to, in order.</summary>
    public static IReadOnlyList<string> CorpusClasses { get; } = ["document", "code", "communication"];

    private static readonly JsonSerializerOptions Indented = new() { WriteIndented = true };

    /// <summary>The configured entries; anything that is not an array of objects is none.</summary>
    public static List<JsonObject> Parse(string configuredJson)
    {
        try
        {
            return JsonNode.Parse(string.IsNullOrWhiteSpace(configuredJson) ? "[]" : configuredJson) is JsonArray array
                ? [.. array.OfType<JsonObject>().Select(o => (JsonObject)o.DeepClone())]
                : [];
        }
        catch (JsonException)
        {
            return [];
        }
    }

    /// <summary>The entries as compact JSON with sorted keys, as the Mac writes them.</summary>
    public static string Serialize(IEnumerable<JsonObject> entries)
    {
        ArgumentNullException.ThrowIfNull(entries);
        return new JsonArray([.. entries.Select(e => Sorted(e))]).ToJsonString();
    }

    /// <summary>A JSON value indented, keys sorted, for editing.</summary>
    public static string Pretty(JsonNode value)
    {
        ArgumentNullException.ThrowIfNull(value);
        return Sorted(value)!.ToJsonString(Indented);
    }

    /// <summary>The examples text re-indented for editing; returned unchanged when it is not JSON.</summary>
    public static string PrettyExamples(string examplesJson)
    {
        try
        {
            return JsonNode.Parse(examplesJson) is { } node ? Pretty(node) : examplesJson;
        }
        catch (JsonException)
        {
            return examplesJson;
        }
    }

    [GeneratedRegex("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")]
    private static partial Regex NamePattern();

    /// <summary>Letters, digits, '.', '_' or '-', starting with a letter or digit, at most 64.</summary>
    public static bool IsValidName(string name) => NamePattern().IsMatch(name);

    /// <summary>
    /// The examples text as JSON, checked for the shape LangExtract needs; the server validates every
    /// field again before anything is written.
    /// </summary>
    public static JsonArray ParseExamples(string text)
    {
        JsonNode? value;
        try
        {
            value = JsonNode.Parse(text);
        }
        catch (JsonException)
        {
            throw Invalid("not valid JSON");
        }
        if (value is not JsonArray examples || examples.Count == 0 || examples.Any(e => e is not JsonObject))
        {
            throw Invalid("expected a non-empty array of objects");
        }
        foreach (JsonObject example in examples.Cast<JsonObject>())
        {
            if (example["text"] is not JsonValue text1 || text1.GetValueKind() != JsonValueKind.String)
            {
                throw Invalid("every example needs a \"text\" string");
            }
            if (example["extractions"] is { } extractions && (extractions is not JsonArray list || list.Any(x => x is not JsonObject)))
            {
                throw Invalid("\"extractions\" must be an array of objects");
            }
        }
        return examples;

        static FactPromptConfigException Invalid(string reason) =>
            new($"Examples must be a non-empty JSON array of {{\"text\", \"extractions\"}} objects: {reason}");
    }

    /// <summary>
    /// Writes <paramref name="prompt"/> in full, replacing the entry named <paramref name="originalName"/>
    /// (a rename) or the prompt's own name, else appending it. Throws <see cref="FactPromptConfigException"/>.
    /// </summary>
    public static string Saving(FactPromptItem prompt, string? originalName, string configuredJson, IReadOnlySet<string> existingNames)
    {
        ArgumentNullException.ThrowIfNull(prompt);
        ArgumentNullException.ThrowIfNull(existingNames);
        if (!IsValidName(prompt.Name))
        {
            throw new FactPromptConfigException($"\"{prompt.Name}\" is not a valid prompt name: use letters, digits, '.', '_' or '-', starting with a letter or digit.");
        }
        if (prompt.Name != originalName && existingNames.Contains(prompt.Name))
        {
            throw new FactPromptConfigException($"A prompt named \"{prompt.Name}\" already exists.");
        }
        if (string.IsNullOrWhiteSpace(prompt.Description))
        {
            throw new FactPromptConfigException("The instructions must not be empty.");
        }
        JsonArray examples = ParseExamples(prompt.ExamplesJson);
        List<JsonObject> entries = Parse(configuredJson);
        string target = originalName ?? prompt.Name;
        var entry = new JsonObject
        {
            ["name"] = prompt.Name,
            ["description"] = prompt.Description,
            ["examples"] = examples.DeepClone(),
            ["corpus_classes"] = new JsonArray([.. prompt.CorpusClasses.Select(c => (JsonNode?)JsonValue.Create(c))]),
            ["sources"] = new JsonArray([.. prompt.Sources.Select(s => (JsonNode?)JsonValue.Create(s))]),
            ["enabled"] = prompt.Enabled,
        };
        int index = entries.FindIndex(e => Name(e) == target);
        if (index >= 0)
        {
            // Keys this editor does not show (the prompt's graph block) stay as they were.
            foreach ((string key, JsonNode? value) in entries[index])
            {
                if (!entry.ContainsKey(key))
                {
                    entry[key] = value?.DeepClone();
                }
            }
            entries[index] = entry;
        }
        else
        {
            entries.Add(entry);
        }
        return Serialize(entries);
    }

    /// <summary>Turns <paramref name="name"/> on or off, keeping the rest of its entry; a built-in with no entry gets one with just its name and the flag.</summary>
    public static string SettingEnabled(bool enabled, string name, string configuredJson)
    {
        List<JsonObject> entries = Parse(configuredJson);
        int index = entries.FindIndex(e => Name(e) == name);
        if (index >= 0)
        {
            entries[index]["enabled"] = enabled;
        }
        else
        {
            entries.Add(new JsonObject { ["name"] = name, ["enabled"] = enabled });
        }
        return Serialize(entries);
    }

    /// <summary>Drops <paramref name="name"/>'s entry: deletes a configured prompt, or restores a built-in.</summary>
    public static string Removing(string name, string configuredJson) =>
        Serialize(Parse(configuredJson).Where(e => Name(e) != name));

    private static string? Name(JsonObject entry) =>
        entry["name"] is JsonValue value && value.TryGetValue(out string? name) ? name : null;

    private static JsonNode? Sorted(JsonNode? node) => node switch
    {
        JsonObject obj => new JsonObject(obj.OrderBy(p => p.Key, StringComparer.Ordinal)
            .Select(p => new KeyValuePair<string, JsonNode?>(p.Key, Sorted(p.Value)))),
        JsonArray array => new JsonArray([.. array.Select(Sorted)]),
        null => null,
        _ => node.DeepClone(),
    };
}

/// <summary>
/// The Fact Prompts section on the Models page (the Mac's <c>FactPromptsSection</c>): the built-in
/// <c>default</c> and any in <c>facts.prompts</c>, each with an on/off switch, an editor and a Run
/// button. Every change is written back whole through <c>SetSetting facts.prompts</c>, which
/// validates it before garage.json is touched.
/// </summary>
public sealed partial class FactPromptsViewModel(GarageService.GarageServiceClient client) : ObservableObject
{
    private static readonly TimeSpan CallTimeout = TimeSpan.FromSeconds(30);

    /// <summary>The section's explanation.</summary>
    public const string Explanation =
        "Glean Facts runs every enabled prompt that applies to a document; each fact records the prompt that produced it. Stored in garage.json under facts.prompts, merged by name with the built-in default.";

    /// <summary>The effective prompts, built-ins first.</summary>
    public ObservableCollection<FactPromptItem> Prompts { get; } = [];

    /// <summary><c>facts.prompts</c> as configured: what a save rewrites.</summary>
    public string ConfiguredJson { get; private set; } = "[]";

    /// <summary>Why the prompts could not be read or written.</summary>
    [ObservableProperty]
    public partial string? Error { get; private set; }

    /// <summary>Whether the prompts have been read.</summary>
    [ObservableProperty]
    public partial bool IsLoaded { get; private set; }

    /// <summary>Every prompt's name.</summary>
    public IReadOnlySet<string> Names => Prompts.Select(p => p.Name).ToHashSet(StringComparer.Ordinal);

    /// <summary>Reads the prompts.</summary>
    public async Task LoadAsync(CancellationToken cancellationToken = default)
    {
        try
        {
            ListFactPromptsResponse response = await client.ListFactPromptsAsync(new ListFactPromptsRequest(),
                new CallOptions(deadline: DateTime.UtcNow + CallTimeout, cancellationToken: cancellationToken)).ConfigureAwait(true);
            Prompts.Clear();
            foreach (FactPrompt prompt in response.Prompts)
            {
                Prompts.Add(FactPromptItem.From(prompt));
            }
            ConfiguredJson = string.IsNullOrEmpty(response.ConfiguredJson) ? "[]" : response.ConfiguredJson;
            Error = null;
            IsLoaded = true;
        }
        catch (RpcException ex)
        {
            Error = RpcErrors.Describe(ex);
        }
    }

    /// <summary>Writes <paramref name="configuredJson"/> as <c>facts.prompts</c> and rereads; returns the failure, or null.</summary>
    public async Task<string?> SaveAsync(string configuredJson)
    {
        try
        {
            await client.SetSettingAsync(new SetSettingRequest { Name = "facts.prompts", Value = configuredJson },
                new CallOptions(deadline: DateTime.UtcNow + CallTimeout)).ConfigureAwait(true);
        }
        catch (RpcException ex)
        {
            Error = RpcErrors.Describe(ex);
            return Error;
        }
        await LoadAsync().ConfigureAwait(true);
        return null;
    }

    /// <summary>Saves an edited or new prompt; returns why it could not be, or null.</summary>
    public Task<string?> SaveAsync(FactPromptItem prompt, string? originalName)
    {
        HashSet<string> names = [.. Names];
        if (originalName is not null)
        {
            names.Remove(originalName);
        }
        try
        {
            return SaveAsync(FactPromptConfig.Saving(prompt, originalName, ConfiguredJson, names));
        }
        catch (FactPromptConfigException ex)
        {
            return Task.FromResult<string?>(ex.Message);
        }
    }

    /// <summary>Turns a prompt on or off.</summary>
    public Task<string?> SetEnabledAsync(string name, bool enabled) => SaveAsync(FactPromptConfig.SettingEnabled(enabled, name, ConfiguredJson));

    /// <summary>Deletes a configured prompt, or restores a built-in.</summary>
    public Task<string?> RemoveAsync(string name) => SaveAsync(FactPromptConfig.Removing(name, ConfiguredJson));

    /// <summary>Glean Facts with just one prompt, on the facts runner.</summary>
    public static Task<OperationResult> RunAsync(FactsViewModel facts, OperationRunner runner, string name, State.INotifier? notifier = null)
    {
        ArgumentNullException.ThrowIfNull(facts);
        return facts.GleanAsync(runner, notifier, new GleanScope(Prompts: [name]));
    }
}

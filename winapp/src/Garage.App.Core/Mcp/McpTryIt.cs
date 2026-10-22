using System.Collections.ObjectModel;
using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using CommunityToolkit.Mvvm.ComponentModel;

namespace Garage.App.Core.Mcp;

/// <summary>One tool the MCP server lists (<c>tools/list</c>): the Mac's <c>MCPToolInfo</c>.</summary>
public sealed record McpToolInfo(string Name, string Description = "", string InputSchemaJson = "")
{
    /// <summary>The tools in a <c>tools/list</c> response.</summary>
    /// <exception cref="McpCallException">The response is a JSON-RPC error.</exception>
    public static IReadOnlyList<McpToolInfo> Parse(JsonObject response)
    {
        ArgumentNullException.ThrowIfNull(response);
        if (response["error"] is JsonObject error)
        {
            throw new McpCallException($"Listing tools failed: {error["message"]?.GetValue<string>() ?? "unknown error"}");
        }
        if (response["result"] is not JsonObject { } result || result["tools"] is not JsonArray tools)
        {
            return [];
        }
        return [.. tools.OfType<JsonObject>()
            .Where(t => t["name"] is JsonValue)
            .Select(t => new McpToolInfo(
                t["name"]!.GetValue<string>(),
                t["description"] is JsonValue d && d.TryGetValue(out string? description) ? description.Trim() : "",
                t["inputSchema"]?.ToJsonString() ?? ""))];
    }

    /// <summary>Whether the tool's schema lists no properties, so it takes no arguments.</summary>
    public bool TakesNoArguments
    {
        get
        {
            if (string.IsNullOrWhiteSpace(InputSchemaJson))
            {
                return false;
            }
            try
            {
                return JsonNode.Parse(InputSchemaJson) is JsonObject schema
                    && (schema["properties"] is not JsonObject properties || properties.Count == 0);
            }
            catch (JsonException)
            {
                return false;
            }
        }
    }
}

/// <summary>Try It's three ways to call the server, as on the Mac.</summary>
public enum TryItMode
{
    /// <summary><c>rag_ask</c>: retrieve, then answer with citations.</summary>
    Ask,

    /// <summary><c>rag_generate</c>: the raw prompt, nothing retrieved.</summary>
    Prompt,

    /// <summary>Any tool the server lists, with its arguments.</summary>
    Tool,
}

/// <summary>What the selected tool needs typed in.</summary>
public enum ToolArgumentKind
{
    /// <summary>Nothing.</summary>
    None,

    /// <summary>A search query (<c>rag_search</c>).</summary>
    Query,

    /// <summary>A document id (<c>rag_get_document</c>).</summary>
    DocumentId,

    /// <summary>A JSON object of arguments.</summary>
    Json,
}

/// <summary>A citation in a <c>rag_ask</c> answer: the Mac's <c>PlaygroundCitation</c>.</summary>
public sealed record PlaygroundCitation(
    [property: JsonPropertyName("n")] int N,
    [property: JsonPropertyName("document_id")] long? DocumentId,
    [property: JsonPropertyName("title")] string? Title,
    [property: JsonPropertyName("location")] string? Location,
    [property: JsonPropertyName("snippet")] string? Snippet,
    [property: JsonPropertyName("score")] double? Score)
{
    /// <summary>The title, or "Untitled".</summary>
    public string DisplayTitle => string.IsNullOrWhiteSpace(Title) ? "Untitled" : Title;

    /// <summary>The retrieval score to three places, or "".</summary>
    public string ScoreText => Score is { } score ? score.ToString("0.000", CultureInfo.InvariantCulture) : "";
}

/// <summary>What <c>rag_ask</c> or <c>rag_generate</c> returns: the Mac's <c>PlaygroundAnswer</c>.</summary>
public sealed record PlaygroundAnswer(
    [property: JsonPropertyName("answer")] string? Answer,
    [property: JsonPropertyName("text")] string? Text,
    [property: JsonPropertyName("model")] string? Model,
    [property: JsonPropertyName("provider")] string? Provider,
    [property: JsonPropertyName("citations")] IReadOnlyList<PlaygroundCitation>? Citations)
{
    /// <summary>The answer, else the completion.</summary>
    public string DisplayText => Answer ?? Text ?? "";

    /// <summary>"gemma2:2b via ollama", "gemma2:2b", or "".</summary>
    public string ModelLine => string.IsNullOrEmpty(Model) ? "" : string.IsNullOrEmpty(Provider) ? Model : $"{Model} via {Provider}";

    /// <summary>An answer when <paramref name="output"/> is one with text, else null (the output is shown as it is).</summary>
    public static PlaygroundAnswer? Parse(string output)
    {
        if (string.IsNullOrWhiteSpace(output))
        {
            return null;
        }
        try
        {
            PlaygroundAnswer? parsed = JsonSerializer.Deserialize<PlaygroundAnswer>(output);
            return parsed is { Answer: not null } or { Text: not null } ? parsed : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }
}

/// <summary>
/// The MCP page's Try It panel (the Mac's <c>MCPServerView+TryIt</c>): one place to call the running
/// server the way an assistant would. Ask the Corpus runs <c>rag_ask</c>, Prompt the Model runs
/// <c>rag_generate</c> on the raw prompt, and Call a Tool runs any tool the server lists.
/// </summary>
/// <param name="endpoint">The running HTTP server, or null while it is off.</param>
/// <param name="clientFactory">Makes the client; tests pass a fake server's.</param>
public sealed partial class McpTryItViewModel(Func<Uri?> endpoint, Func<Uri, McpHttpClient>? clientFactory = null) : ObservableObject
{
    /// <summary>The tools offered before the server has been checked: the ones taking at most one argument.</summary>
    public static IReadOnlyList<string> FallbackToolNames { get; } = ["rag_search", "rag_stats", "rag_list_sources", "rag_list_authors", "rag_get_document"];

    private readonly Func<Uri, McpHttpClient> _clientFactory = clientFactory ?? (uri => new McpHttpClient(uri));

    /// <summary>The mode.</summary>
    [ObservableProperty]
    public partial TryItMode Mode { get; set; } = TryItMode.Ask;

    /// <summary>The question or prompt.</summary>
    [ObservableProperty]
    public partial string Prompt { get; set; } = "";

    /// <summary>The answer's token budget.</summary>
    [ObservableProperty]
    public partial int MaxTokens { get; set; } = DefaultMaxTokens(TryItMode.Ask);

    /// <summary>The sampling temperature.</summary>
    [ObservableProperty]
    public partial double Temperature { get; set; } = DefaultTemperature(TryItMode.Ask);

    /// <summary>The tool Call a Tool runs.</summary>
    [ObservableProperty]
    public partial string ToolName { get; set; } = "rag_search";

    /// <summary><c>rag_search</c>'s query.</summary>
    [ObservableProperty]
    public partial string ToolQuery { get; set; } = "secure boot";

    /// <summary><c>rag_get_document</c>'s id, as typed.</summary>
    [ObservableProperty]
    public partial string ToolDocumentId { get; set; } = "1";

    /// <summary>Any other tool's arguments, as a JSON object.</summary>
    [ObservableProperty]
    public partial string ToolArgumentsJson { get; set; } = "{}";

    /// <summary>A call is in flight.</summary>
    [ObservableProperty]
    public partial bool IsRunning { get; private set; }

    /// <summary>Why the call failed.</summary>
    [ObservableProperty]
    public partial string? Error { get; private set; }

    /// <summary>The answer, when the reply is one.</summary>
    [ObservableProperty]
    public partial PlaygroundAnswer? Answer { get; private set; }

    /// <summary>The reply as it came, when it is not an answer.</summary>
    [ObservableProperty]
    public partial string? RawOutput { get; private set; }

    /// <summary>The tools the server listed at its last Test; empty before one.</summary>
    public ObservableCollection<McpToolInfo> ListedTools { get; } = [];

    /// <summary>The tools on offer: those listed, or the fallback list before a Test.</summary>
    public IReadOnlyList<McpToolInfo> AvailableTools => ListedTools.Count > 0
        ? ListedTools
        : [.. FallbackToolNames.Select(name => new McpToolInfo(name))];

    /// <summary>Whether the server is up to try.</summary>
    public bool ServerRunning => endpoint() is not null;

    /// <summary>The default budget per mode.</summary>
    public static int DefaultMaxTokens(TryItMode mode) => mode == TryItMode.Ask ? 512 : 256;

    /// <summary>The default temperature per mode.</summary>
    public static double DefaultTemperature(TryItMode mode) => mode == TryItMode.Ask ? 0.2 : 0.7;

    /// <summary>The mode's title, as the Mac's segmented control reads.</summary>
    public static string Title(TryItMode mode) => mode switch
    {
        TryItMode.Ask => "Ask the Corpus",
        TryItMode.Prompt => "Prompt the Model",
        _ => "Call a Tool",
    };

    /// <summary>What the mode does, naming the model that answers (<paramref name="model"/>, or the distillation model when empty).</summary>
    public static string Explanation(TryItMode mode, string model)
    {
        string who = string.IsNullOrWhiteSpace(model) ? "the distillation model (pick one on the Models page)" : model;
        return mode switch
        {
            TryItMode.Ask => $"Searches your corpus and answers with citations, as rag_ask does for an assistant. Runs on {who}.",
            TryItMode.Prompt => $"Sends the prompt as it is to {who} through rag_generate, with nothing retrieved.",
            _ => "Calls one of the server's tools and shows exactly what an assistant would receive.",
        };
    }

    /// <summary>The input the selected tool needs.</summary>
    public ToolArgumentKind ArgumentKind => ToolName switch
    {
        "rag_search" => ToolArgumentKind.Query,
        "rag_get_document" => ToolArgumentKind.DocumentId,
        "rag_stats" or "rag_list_sources" or "rag_list_authors" => ToolArgumentKind.None,
        _ => AvailableTools.FirstOrDefault(t => t.Name == ToolName) is { TakesNoArguments: true } ? ToolArgumentKind.None : ToolArgumentKind.Json,
    };

    /// <summary>The selected tool's description.</summary>
    public string ToolDescription => AvailableTools.FirstOrDefault(t => t.Name == ToolName)?.Description ?? "";

    /// <summary>The JSON arguments as an object; null when they are not one.</summary>
    public JsonObject? ParsedArguments
    {
        get
        {
            string text = ToolArgumentsJson.Trim();
            if (text.Length == 0)
            {
                return [];
            }
            try
            {
                return JsonNode.Parse(text) as JsonObject;
            }
            catch (JsonException)
            {
                return null;
            }
        }
    }

    /// <summary>Whether Run has what it needs.</summary>
    public bool CanRun => ServerRunning && !IsRunning && (Mode == TryItMode.Tool
        ? ArgumentKind switch
        {
            ToolArgumentKind.Query => ToolQuery.Trim().Length > 0,
            ToolArgumentKind.DocumentId => long.TryParse(ToolDocumentId.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out _),
            ToolArgumentKind.Json => ParsedArguments is not null,
            _ => true,
        }
        : Prompt.Trim().Length > 0);

    /// <summary>The tool and arguments Run sends.</summary>
    public (string Tool, Dictionary<string, object?> Arguments) Request()
    {
        if (Mode != TryItMode.Tool)
        {
            Dictionary<string, object?> args = new() { ["max_tokens"] = MaxTokens, ["temperature"] = Temperature };
            if (Mode == TryItMode.Ask)
            {
                args["question"] = Prompt.Trim();
                args["limit"] = 6;
                return ("rag_ask", args);
            }
            args["prompt"] = Prompt.Trim();
            return ("rag_generate", args);
        }
        Dictionary<string, object?> arguments = ArgumentKind switch
        {
            ToolArgumentKind.Query => new() { ["query"] = ToolQuery },
            ToolArgumentKind.DocumentId => new() { ["document_id"] = long.Parse(ToolDocumentId.Trim(), CultureInfo.InvariantCulture) },
            ToolArgumentKind.Json => ParsedArguments!.ToDictionary(p => p.Key, p => (object?)p.Value?.DeepClone()),
            _ => [],
        };
        return (ToolName, arguments);
    }

    /// <summary>Sends the request as an MCP <c>tools/call</c>, the path an assistant takes.</summary>
    public async Task RunAsync(CancellationToken cancellationToken = default)
    {
        if (!CanRun || endpoint() is not { } url)
        {
            return;
        }
        (string tool, Dictionary<string, object?> arguments) = Request();
        TryItMode mode = Mode;
        IsRunning = true;
        Error = null;
        Answer = null;
        RawOutput = null;
        Notify();
        try
        {
            using McpHttpClient client = _clientFactory(url);
            string output = await client.CallToolAsync(tool, arguments,
                mode == TryItMode.Tool ? McpHttpClient.ToolCallTimeout : McpHttpClient.GenerationTimeout, cancellationToken).ConfigureAwait(true);
            if (mode != TryItMode.Tool && PlaygroundAnswer.Parse(output) is { } answer)
            {
                Answer = answer;
            }
            else
            {
                RawOutput = output;
            }
        }
        catch (McpCallException ex)
        {
            Error = ex.Message;
        }
        finally
        {
            IsRunning = false;
            Notify();
        }
    }

    /// <summary>Test: lists the server's tools; returns a line for the page, and the tools Try It offers.</summary>
    public async Task<string> TestAsync(CancellationToken cancellationToken = default)
    {
        if (endpoint() is not { } url)
        {
            return "Start the server to test it.";
        }
        try
        {
            using McpHttpClient client = _clientFactory(url);
            IReadOnlyList<McpToolInfo> tools = await client.ListToolsAsync(cancellationToken).ConfigureAwait(true);
            ListedTools.Clear();
            foreach (McpToolInfo tool in tools)
            {
                ListedTools.Add(tool);
            }
            Notify();
            return string.Create(CultureInfo.CurrentCulture, $"The server answered at {url} with {tools.Count} {(tools.Count == 1 ? "tool" : "tools")}: {string.Join(", ", tools.Select(t => t.Name))}");
        }
        catch (McpCallException ex)
        {
            return ex.Message;
        }
    }

    partial void OnModeChanged(TryItMode value)
    {
        MaxTokens = DefaultMaxTokens(value);
        Temperature = DefaultTemperature(value);
        Error = null;
        Answer = null;
        RawOutput = null;
        Notify();
    }

    partial void OnToolNameChanged(string value) => Notify();

    /// <summary>Raises the computed properties after a change the page made.</summary>
    public void Notify()
    {
        OnPropertyChanged(nameof(CanRun));
        OnPropertyChanged(nameof(ArgumentKind));
        OnPropertyChanged(nameof(ToolDescription));
        OnPropertyChanged(nameof(AvailableTools));
        OnPropertyChanged(nameof(ServerRunning));
    }
}

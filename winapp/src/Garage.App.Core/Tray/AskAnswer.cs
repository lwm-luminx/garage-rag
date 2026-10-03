using System.Text.Json;
using System.Text.Json.Serialization;

namespace Garage.App.Core.Tray;

/// <summary>
/// What <c>rag_agent</c> returns: the local model's answer, the tools it called on the way and the
/// documents it saw (the Mac's <c>MenuBarAnswer</c>). Decoded from the text of the MCP tool result
/// Ask Garage gets back.
/// </summary>
public sealed record AskAnswer(
    string Answer,
    string Model = "",
    string Provider = "",
    string Question = "",
    IReadOnlyList<AskAnswer.ToolCall>? Steps = null,
    IReadOnlyList<AskAnswer.Citation>? Citations = null)
{
    private static readonly JsonSerializerOptions Json = new() { PropertyNameCaseInsensitive = false };

    /// <summary>The tool calls, in order.</summary>
    public IReadOnlyList<ToolCall> Trail => Steps ?? [];

    /// <summary>The documents the answer rests on.</summary>
    public IReadOnlyList<Citation> Sources => Citations ?? [];

    /// <summary>One tool call the model made.</summary>
    public sealed record ToolCall(int N, string Tool, string Summary, bool Ok = true);

    /// <summary>A document the model saw.</summary>
    public sealed record Citation(int N, long DocumentId, string? Title, string Location, string Snippet, string CorpusClass)
    {
        /// <summary>The title, or the file name when the document has none.</summary>
        public string DisplayTitle
        {
            get
            {
                if (!string.IsNullOrWhiteSpace(Title))
                {
                    return Title;
                }
                string name = Location.Split('/', '\\')[^1];
                return name.Length == 0 ? "Untitled" : name;
            }
        }

        /// <summary>The file behind the citation, when it is one; <c>rag_agent</c> folds the home folder to <c>~</c>.</summary>
        public string? FilePath(string home) => QuickSearch.FilePathForUri(ExpandHome(Location, home));

        private static string ExpandHome(string location, string home) =>
            location == "~" ? home
            : location.StartsWith("~/", StringComparison.Ordinal) || location.StartsWith("~\\", StringComparison.Ordinal)
                ? Path.Join(home, location[2..].Replace('/', Path.DirectorySeparatorChar))
                : location;
    }

    /// <summary>The caption under the answer: "Searched twice and read 1 document · gemma2-2b".</summary>
    public string Footnote
    {
        get
        {
            List<string> parts = [];
            int searches = Trail.Count(s => s.Ok && s.Tool == "rag_search");
            int reads = Trail.Count(s => s.Ok && s.Tool == "rag_get_document");
            int other = Trail.Count(s => s.Ok && s.Tool is not "rag_search" and not "rag_get_document");
            if (searches > 0)
            {
                parts.Add($"Searched {Times(searches)}");
            }
            if (reads > 0)
            {
                parts.Add($"read {reads} {(reads == 1 ? "document" : "documents")}");
            }
            if (other > 0)
            {
                parts.Add($"looked up the corpus {Times(other)}");
            }
            string text = parts.Count switch
            {
                0 => "Answered without searching",
                1 => parts[0],
                _ => string.Join(", ", parts.Take(parts.Count - 1)) + " and " + parts[^1],
            };
            text = char.ToUpperInvariant(text[0]) + text[1..];
            return Model.Length > 0 ? $"{text} · {Model}" : text;
        }
    }

    /// <summary>Decodes the text a <c>tools/call</c> returned; null when it is not an answer (an error string, or a result with no answer).</summary>
    public static AskAnswer? Parse(string toolOutput)
    {
        if (string.IsNullOrWhiteSpace(toolOutput))
        {
            return null;
        }
        try
        {
            Wire? wire = JsonSerializer.Deserialize<Wire>(toolOutput, Json);
            if (wire?.Answer is not { } answer || string.IsNullOrWhiteSpace(answer))
            {
                return null;
            }
            return new AskAnswer(
                answer,
                wire.Model ?? "",
                wire.Provider ?? "",
                wire.Question ?? "",
                [.. (wire.Steps ?? []).Where(s => s.Tool is not null).Select(s => new ToolCall(s.N, s.Tool!, s.Summary ?? "", s.Ok ?? true))],
                [.. (wire.Citations ?? []).Select(c => new Citation(c.N, c.DocumentId, c.Title, c.Location ?? "", c.Snippet ?? "", c.CorpusClass ?? "document"))]);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static string Times(int count) => count switch
    {
        1 => "once",
        2 => "twice",
        _ => $"{count} times",
    };

    private sealed record Wire(
        [property: JsonPropertyName("answer")] string? Answer,
        [property: JsonPropertyName("model")] string? Model,
        [property: JsonPropertyName("provider")] string? Provider,
        [property: JsonPropertyName("question")] string? Question,
        [property: JsonPropertyName("steps")] List<WireStep>? Steps,
        [property: JsonPropertyName("citations")] List<WireCitation>? Citations);

    private sealed record WireStep(
        [property: JsonPropertyName("n")] int N,
        [property: JsonPropertyName("tool")] string? Tool,
        [property: JsonPropertyName("summary")] string? Summary,
        [property: JsonPropertyName("ok")] bool? Ok);

    private sealed record WireCitation(
        [property: JsonPropertyName("n")] int N,
        [property: JsonPropertyName("document_id")] long DocumentId,
        [property: JsonPropertyName("title")] string? Title,
        [property: JsonPropertyName("location")] string? Location,
        [property: JsonPropertyName("snippet")] string? Snippet,
        [property: JsonPropertyName("corpus_class")] string? CorpusClass);
}

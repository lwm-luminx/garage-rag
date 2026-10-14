using System.Text;
using System.Text.Json;

namespace Garage.App.Core.Graph;

/// <summary>One property of a vertex or edge, rendered as text: the Mac's <c>GraphProperty</c>.</summary>
public sealed record GraphProperty(string Key, string Value)
{
    /// <summary>The properties in a JSON object, sorted by key; anything unparseable is no properties.</summary>
    public static IReadOnlyList<GraphProperty> Parse(string json)
    {
        if (string.IsNullOrEmpty(json))
        {
            return [];
        }
        try
        {
            using JsonDocument document = JsonDocument.Parse(json);
            if (document.RootElement.ValueKind != JsonValueKind.Object)
            {
                return [];
            }
            return [.. document.RootElement.EnumerateObject()
                .OrderBy(p => p.Name, StringComparer.Ordinal)
                .Select(p => new GraphProperty(p.Name, Render(p.Value)))];
        }
        catch (JsonException)
        {
            return [];
        }
    }

    // Strings as they are, booleans as true/false, containers as compact JSON with sorted keys, null as "".
    private static string Render(JsonElement value) => value.ValueKind switch
    {
        JsonValueKind.String => value.GetString() ?? "",
        JsonValueKind.Null or JsonValueKind.Undefined => "",
        JsonValueKind.True => "true",
        JsonValueKind.False => "false",
        JsonValueKind.Object or JsonValueKind.Array => Compact(value),
        _ => value.GetRawText(),
    };

    private static string Compact(JsonElement value)
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream))
        {
            Write(writer, value);
        }
        return Encoding.UTF8.GetString(stream.ToArray());

        static void Write(Utf8JsonWriter writer, JsonElement element)
        {
            switch (element.ValueKind)
            {
                case JsonValueKind.Object:
                    writer.WriteStartObject();
                    foreach (JsonProperty property in element.EnumerateObject().OrderBy(p => p.Name, StringComparer.Ordinal))
                    {
                        writer.WritePropertyName(property.Name);
                        Write(writer, property.Value);
                    }
                    writer.WriteEndObject();
                    break;
                case JsonValueKind.Array:
                    writer.WriteStartArray();
                    foreach (JsonElement item in element.EnumerateArray())
                    {
                        Write(writer, item);
                    }
                    writer.WriteEndArray();
                    break;
                default:
                    element.WriteTo(writer);
                    break;
            }
        }
    }
}

/// <summary>
/// One vertex of the <c>garage</c> graph, as GetGraphNeighborhood and FindGraphVertices return it:
/// the Mac's <c>GraphVertexItem</c>.
/// </summary>
/// <param name="Id">The graph id: unique across labels, and what edges refer to.</param>
/// <param name="Label">Document, Chunk, Author, PotentialFact, Fact, ...</param>
/// <param name="Key">The relational id (documents.id, facts.id, ...); null for a label without one.</param>
/// <param name="Title">What to call it: the title, name, fact or statement.</param>
/// <param name="PropertiesJson">Every property, as a JSON object.</param>
public sealed record GraphVertexItem(long Id, string Label, long? Key, string Title, string PropertiesJson = "")
{
    /// <summary>From a <c>GraphVertex</c>.</summary>
    public static GraphVertexItem From(GraphVertex vertex)
    {
        ArgumentNullException.ThrowIfNull(vertex);
        return new(vertex.Id, vertex.Label, vertex.Key == 0 ? null : vertex.Key, vertex.Title, vertex.PropertiesJson);
    }

    /// <summary>The properties, sorted by key, values rendered as text.</summary>
    public IReadOnlyList<GraphProperty> Properties => GraphProperty.Parse(PropertiesJson);

    /// <summary>
    /// The document behind this vertex: itself for a Document, the stating document for a
    /// PotentialFact or Chunk (both carry <c>document_id</c>), nothing otherwise.
    /// </summary>
    public long? DocumentId
    {
        get
        {
            if (Label == "Document")
            {
                return Key;
            }
            string? value = Properties.FirstOrDefault(p => p.Key == "document_id")?.Value;
            return long.TryParse(value, System.Globalization.NumberStyles.Integer, System.Globalization.CultureInfo.InvariantCulture, out long id) ? id : null;
        }
    }

    /// <summary>The document's URI, which a Document vertex carries.</summary>
    public string DocumentUri => Properties.FirstOrDefault(p => p.Key == "uri")?.Value ?? "";

    /// <summary>"#12" for a vertex with a relational id, else "".</summary>
    public string KeyText => Key is { } key ? string.Create(System.Globalization.CultureInfo.InvariantCulture, $"#{key}") : "";

    /// <summary>How the label reads: "Potential fact".</summary>
    public string LabelName => GraphLabelStyle.Vertex(Label).Name;
}

/// <summary>One edge between two vertices' graph ids: the Mac's <c>GraphEdgeItem</c>.</summary>
public sealed record GraphEdgeItem(long Id, string Label, long SourceId, long TargetId, string PropertiesJson = "")
{
    /// <summary>From a <c>GraphEdge</c>.</summary>
    public static GraphEdgeItem From(GraphEdge edge)
    {
        ArgumentNullException.ThrowIfNull(edge);
        return new(edge.Id, edge.Label, edge.SourceId, edge.TargetId, edge.PropertiesJson);
    }

    /// <summary>The properties, sorted by key.</summary>
    public IReadOnlyList<GraphProperty> Properties => GraphProperty.Parse(PropertiesJson);

    /// <summary>The vertex at the other end of this edge from <paramref name="vertexId"/>, or null when the edge does not touch it.</summary>
    public long? OtherEnd(long vertexId) =>
        SourceId == vertexId ? TargetId : TargetId == vertexId ? SourceId : null;
}

/// <summary>A label and how many vertices or edges carry it, for the Graph page's filters.</summary>
public sealed record GraphLabelCountItem(string Label, long Count);

/// <summary>The graph's labels, or <see cref="Available"/> false where the server has no AGE or no graph yet.</summary>
public sealed record GraphLabels(bool Available, IReadOnlyList<GraphLabelCountItem> VertexLabels, IReadOnlyList<GraphLabelCountItem> EdgeLabels)
{
    /// <summary>No graph.</summary>
    public static GraphLabels Unavailable { get; } = new(false, [], []);

    /// <summary>From a <c>GraphLabelsResponse</c>.</summary>
    public static GraphLabels From(GraphLabelsResponse response)
    {
        ArgumentNullException.ThrowIfNull(response);
        return new(
            response.Available,
            [.. response.VertexLabels.Select(c => new GraphLabelCountItem(c.Label, c.Count))],
            [.. response.EdgeLabels.Select(c => new GraphLabelCountItem(c.Label, c.Count))]);
    }
}

/// <summary>One edge at a vertex, with the vertex at its other end.</summary>
public sealed record GraphConnection(GraphEdgeItem Edge, GraphVertexItem Other);

/// <summary>A vertex and everything within a few hops of it: the Mac's <c>GraphNeighborhood</c>.</summary>
/// <param name="Available">False where the server has no AGE or no graph yet.</param>
/// <param name="Center">The vertex in the middle.</param>
/// <param name="Vertices">The center included.</param>
/// <param name="Edges">Both ends of every edge are in <paramref name="Vertices"/>.</param>
/// <param name="Truncated">The vertex limit cut the walk short.</param>
public sealed record GraphNeighborhood(
    bool Available, GraphVertexItem? Center, IReadOnlyList<GraphVertexItem> Vertices, IReadOnlyList<GraphEdgeItem> Edges, bool Truncated = false)
{
    /// <summary>From a <c>GraphNeighborhoodResponse</c>.</summary>
    public static GraphNeighborhood From(GraphNeighborhoodResponse response)
    {
        ArgumentNullException.ThrowIfNull(response);
        return new(
            response.Available,
            response.Center is { } center ? GraphVertexItem.From(center) : null,
            [.. response.Vertices.Select(GraphVertexItem.From)],
            [.. response.Edges.Select(GraphEdgeItem.From)],
            response.Truncated);
    }

    /// <summary>The vertex with this graph id, or null.</summary>
    public GraphVertexItem? Vertex(long id) => Vertices.FirstOrDefault(v => v.Id == id);

    /// <summary>The edges touching a vertex, with the vertex at each one's other end.</summary>
    public IReadOnlyList<GraphConnection> Connections(long vertexId) =>
        [.. Edges.Select(e => (Edge: e, Other: e.OtherEnd(vertexId) is { } other ? Vertex(other) : null))
            .Where(c => c.Other is not null)
            .Select(c => new GraphConnection(c.Edge, c.Other!))];
}

/// <summary>A vertex another page asks the Graph page to center on, by label and relational id.</summary>
public sealed record GraphFocus(string Label, long Key);

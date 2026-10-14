using System.Globalization;
using System.Text;

namespace Garage.App.Core.Graph;

/// <summary>The colours the Graph page tints labels with: the Mac's SwiftUI colours by name.</summary>
public enum GraphTint
{
    /// <summary>Documents.</summary>
    Blue,

    /// <summary>Chunks.</summary>
    Teal,

    /// <summary>Authors.</summary>
    Green,

    /// <summary>Received.</summary>
    Mint,

    /// <summary>Potential facts.</summary>
    Orange,

    /// <summary>Facts.</summary>
    Purple,

    /// <summary>Restatements.</summary>
    Pink,

    /// <summary>A configured label's colour.</summary>
    Indigo,

    /// <summary>A configured label's colour.</summary>
    Cyan,

    /// <summary>A configured label's colour.</summary>
    Brown,

    /// <summary>A configured label's colour.</summary>
    Red,

    /// <summary>A configured label's colour.</summary>
    Yellow,

    /// <summary>A configured label's colour.</summary>
    Gray,
}

/// <summary>What a vertex label's icon shows, named for its meaning rather than a platform glyph.</summary>
public enum GraphSymbol
{
    /// <summary>No icon: edges.</summary>
    None,

    /// <summary>A document.</summary>
    Document,

    /// <summary>Lines of text: a chunk.</summary>
    Text,

    /// <summary>A person.</summary>
    Person,

    /// <summary>A lightbulb outline: a potential fact.</summary>
    Lightbulb,

    /// <summary>A filled lightbulb: a fact.</summary>
    LightbulbFilled,

    /// <summary>A circle: a configured label.</summary>
    Circle,
}

/// <summary>How a vertex or edge label reads and looks: the Mac's <c>GraphLabelStyle</c>.</summary>
/// <param name="Name">The label as a heading: "Potential fact", "Supports".</param>
/// <param name="Tint">Its colour.</param>
/// <param name="Symbol">The icon for the label's vertices; edges have none.</param>
public sealed record GraphLabelStyle(string Name, GraphTint Tint, GraphSymbol Symbol)
{
    /// <summary>Tints for labels a fact prompt's <c>graph</c> block adds, none of them a built-in label's.</summary>
    public static IReadOnlyList<GraphTint> ConfiguredPalette { get; } =
        [GraphTint.Indigo, GraphTint.Cyan, GraphTint.Brown, GraphTint.Red, GraphTint.Yellow, GraphTint.Gray];

    /// <summary>The style for a vertex label; one the app does not know gets a neutral style and its own name.</summary>
    public static GraphLabelStyle Vertex(string label) => label switch
    {
        "Document" => new("Document", GraphTint.Blue, GraphSymbol.Document),
        "Chunk" => new("Chunk", GraphTint.Teal, GraphSymbol.Text),
        "Author" => new("Author", GraphTint.Green, GraphSymbol.Person),
        "PotentialFact" => new("Potential fact", GraphTint.Orange, GraphSymbol.Lightbulb),
        "Fact" => new("Fact", GraphTint.Purple, GraphSymbol.LightbulbFilled),
        _ => new(Humanize(label), ConfiguredTint(label), GraphSymbol.Circle),
    };

    /// <summary>The style for an edge label.</summary>
    public static GraphLabelStyle Edge(string label) => label switch
    {
        "HAS_CHUNK" => new("Has chunk", GraphTint.Teal, GraphSymbol.None),
        "WROTE" => new("Wrote", GraphTint.Green, GraphSymbol.None),
        "RECEIVED" => new("Received", GraphTint.Mint, GraphSymbol.None),
        "STATES" => new("States", GraphTint.Orange, GraphSymbol.None),
        "SUPPORTS" => new("Supports", GraphTint.Purple, GraphSymbol.None),
        "RESTATES" => new("Restates", GraphTint.Pink, GraphSymbol.None),
        _ => new(Humanize(label), ConfiguredTint(label), GraphSymbol.None),
    };

    /// <summary>
    /// A configured label's tint, picked from its name (FNV-1a over its UTF-8, as on the Mac), so it
    /// keeps its colour across launches and matches the Mac app's.
    /// </summary>
    public static GraphTint ConfiguredTint(string label)
    {
        ArgumentNullException.ThrowIfNull(label);
        uint hash = 2_166_136_261;
        foreach (byte b in Encoding.UTF8.GetBytes(label))
        {
            hash = unchecked((hash ^ b) * 16_777_619);
        }
        return ConfiguredPalette[(int)(hash % (uint)ConfiguredPalette.Count)];
    }

    /// <summary><c>HAS_CHUNK</c> → "Has chunk", <c>PotentialFact</c> → "Potential fact".</summary>
    public static string Humanize(string label)
    {
        ArgumentNullException.ThrowIfNull(label);
        var words = new List<string>();
        foreach (string part in label.Split('_'))
        {
            var word = new StringBuilder();
            for (int i = 0; i < part.Length; i++)
            {
                char c = part[i];
                if (i > 0 && char.IsUpper(c) && word.Length > 0 && char.IsLower(word[^1]))
                {
                    words.Add(word.ToString());
                    word.Clear();
                }
                word.Append(c);
            }
            words.Add(word.ToString());
        }
        List<string> lowered = [.. words.Where(w => w.Length > 0).Select(w => w.ToLowerInvariant())];
        if (lowered.Count == 0)
        {
            return label;
        }
        lowered[0] = char.ToUpperInvariant(lowered[0][0]) + lowered[0][1..];
        return string.Join(' ', lowered);
    }
}

/// <summary>A point in the Graph picture's coordinates.</summary>
public readonly record struct GraphPoint(double X, double Y);

/// <summary>What the Graph page says: the Mac's <c>GraphPagePresentation</c>, plus its canvas's sizing rules.</summary>
public static class GraphPagePresentation
{
    /// <summary>The page title.</summary>
    public const string Title = "Graph";

    /// <summary>The search field's placeholder.</summary>
    public const string SearchPlaceholder = "Find a document, author, fact or statement…";

    /// <summary>Titles are drawn under every vertex up to this many; beyond it only the center, hovered and selected ones.</summary>
    public const int TitledVertexLimit = 40;

    /// <summary>How long a title under a vertex may be.</summary>
    public const int TitleLength = 28;

    /// <summary>The most vertices a neighbourhood asks for.</summary>
    public const int VertexLimit = 150;

    /// <summary>The farthest out the page looks.</summary>
    public const int MaxDepth = 4;

    /// <summary>The page's empty state.</summary>
    public sealed record Empty(string Title, string Message, bool Searched);

    /// <summary>The page's empty state, from what it knows.</summary>
    public static Empty EmptyState(bool databaseRunning, bool available, bool hasSelection, bool searched)
    {
        if (!databaseRunning)
        {
            return new("Database Offline", "Start the database to browse the graph.", false);
        }
        if (!available)
        {
            return new("No Graph Yet",
                "The graph is built when facts are distilled: choose Distill Facts on the Facts page. It needs the Apache AGE extension, which Garage's own database has.", false);
        }
        if (searched)
        {
            return new("Nothing Found",
                "No document, author, fact or statement matched. Titles and statements are searched; a number finds a record by id.", true);
        }
        if (!hasSelection)
        {
            return new("Pick a Starting Point",
                "Search for a document, author, fact or statement, then choose one to see what it is connected to.", false);
        }
        return new("Nothing Connected",
            "Nothing within reach passes the current filters. Turn more vertex or edge types on, or look further out.", false);
    }

    /// <summary>The footer under the picture: what is drawn, and whether the limit cut it.</summary>
    public static string Summary(int vertices, int edges, int depth, bool truncated)
    {
        string hops = depth == 1 ? "1 hop" : string.Create(CultureInfo.InvariantCulture, $"{depth} hops");
        string counts = string.Create(CultureInfo.InvariantCulture,
            $"{vertices} {(vertices == 1 ? "vertex" : "vertices")}, {edges} {(edges == 1 ? "edge" : "edges")} within {hops}");
        return truncated ? counts + " (cut at the limit; filter or look nearer)" : counts;
    }

    /// <summary>"1 hop", "3 hops".</summary>
    public static string Hops(int depth) => depth == 1 ? "1 hop" : string.Create(CultureInfo.InvariantCulture, $"{depth} hops");

    /// <summary>"No matches", "1 match", "12 matches".</summary>
    public static string Matches(int count) => count == 0
        ? "No matches"
        : string.Create(CultureInfo.InvariantCulture, $"{count} {(count == 1 ? "match" : "matches")}");

    /// <summary>Smaller circles as the picture fills up.</summary>
    public static double NodeRadius(int vertexCount) => vertexCount switch
    {
        < 25 => 11,
        < 60 => 8,
        _ => 5.5,
    };

    /// <summary>A title cut to fit under a circle, on a word boundary where one is near.</summary>
    public static string ShortTitle(string title)
    {
        ArgumentNullException.ThrowIfNull(title);
        string trimmed = title.Trim();
        if (trimmed.Length <= TitleLength)
        {
            return trimmed;
        }
        string cut = trimmed[..TitleLength];
        int space = cut.LastIndexOf(' ');
        return space > TitleLength / 2 ? cut[..space] + "…" : cut + "…";
    }

    /// <summary>
    /// A small triangle pointing along the edge, stopped short of the target's circle; empty when the
    /// circles leave no room for it.
    /// </summary>
    public static IReadOnlyList<GraphPoint> Arrowhead(GraphPoint from, GraphPoint to, double clearance, double size = 6)
    {
        double dx = to.X - from.X;
        double dy = to.Y - from.Y;
        double length = Math.Sqrt(dx * dx + dy * dy);
        if (length <= clearance + size)
        {
            return [];
        }
        double ux = dx / length;
        double uy = dy / length;
        var tip = new GraphPoint(to.X - ux * clearance, to.Y - uy * clearance);
        var b = new GraphPoint(tip.X - ux * size, tip.Y - uy * size);
        return [tip, new(b.X - uy * size / 2, b.Y + ux * size / 2), new(b.X + uy * size / 2, b.Y - ux * size / 2)];
    }

    /// <summary>The tooltip of a label filter chip: "Hide potential fact vertices".</summary>
    public static string ChipHelp(GraphLabelStyle style, bool isOn)
    {
        ArgumentNullException.ThrowIfNull(style);
        string what = style.Symbol == GraphSymbol.None ? "edges" : "vertices";
        return $"{(isOn ? "Hide" : "Show")} {style.Name.ToLowerInvariant()} {what}";
    }
}

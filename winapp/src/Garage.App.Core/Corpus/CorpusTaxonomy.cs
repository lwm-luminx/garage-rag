namespace Garage.App.Core.Corpus;

/// <summary>
/// The corpus taxonomy the Python side enforces (<c>db/models.py</c>: <c>CorpusClass</c>,
/// <c>TrustTier</c>), with the "all" sentinel the pickers offer: the Mac's <c>CorpusTaxonomy</c>.
/// </summary>
public static class CorpusTaxonomy
{
    /// <summary>What a document is.</summary>
    public static IReadOnlyList<string> CorpusClasses { get; } = ["document", "code", "communication"];

    /// <summary>How far it is trusted.</summary>
    public static IReadOnlyList<string> TrustTiers { get; } = ["authored", "reference", "received"];

    /// <summary>The picker value that means "no filter".</summary>
    public const string All = "all";

    /// <summary><paramref name="values"/> with <see cref="All"/> first.</summary>
    public static IReadOnlyList<string> WithAll(IEnumerable<string> values) => [All, .. values];

    /// <summary>The filter value for a picker selection: null for <see cref="All"/> or blank.</summary>
    public static string? Filter(string? selection) =>
        string.IsNullOrWhiteSpace(selection) || selection == All ? null : selection;

    /// <summary>
    /// A title to show: the title, else the heading path, else the file name from the URI, else
    /// "(untitled)" (the Mac's <c>displayTitle</c>). Handles both <c>/</c> and <c>\</c> in URIs.
    /// </summary>
    public static string DisplayTitle(string? title, string? uri, string? headingPath = null)
    {
        if (!string.IsNullOrEmpty(title) && title != "(untitled)")
        {
            return title;
        }
        if (!string.IsNullOrEmpty(headingPath))
        {
            return headingPath;
        }
        if (!string.IsNullOrEmpty(uri))
        {
            string trimmed = uri.TrimEnd('/', '\\');
            int slash = trimmed.LastIndexOfAny(['/', '\\']);
            string last = slash >= 0 ? trimmed[(slash + 1)..] : trimmed;
            if (last.Length > 0)
            {
                return last;
            }
        }
        return "(untitled)";
    }
}

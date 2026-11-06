using System.Globalization;
using System.Text;
using Garage.App.Core.Presentation;

namespace Garage.App.Core.Sources;

/// <summary>The colour a status line or badge takes (the Mac's <c>SourceTone</c>).</summary>
public enum SourceTone
{
    /// <summary>Nothing to say.</summary>
    Neutral,

    /// <summary>Work in progress.</summary>
    Active,

    /// <summary>All well.</summary>
    Good,

    /// <summary>Needs attention.</summary>
    Warning,

    /// <summary>Failed or unreadable.</summary>
    Bad,
}

/// <summary>What a source row's glyph shows (the Mac's SF Symbols, by meaning).</summary>
public enum SourceSymbol
{
    /// <summary>A plain folder.</summary>
    Folder,

    /// <summary>Documents.</summary>
    Documents,

    /// <summary>The desktop.</summary>
    Desktop,

    /// <summary>Downloads.</summary>
    Downloads,

    /// <summary>A cloud-synced folder (OneDrive, Dropbox, Google Drive, iCloud).</summary>
    Cloud,

    /// <summary>Code or a git repository.</summary>
    Code,

    /// <summary>A database file.</summary>
    Database,

    /// <summary>Messages.</summary>
    Message,

    /// <summary>Mail.</summary>
    Mail,

    /// <summary>A feed.</summary>
    Feed,
}

/// <summary>Where a source is declared: the database, <c>garage.json</c>, or both.</summary>
public enum SourceOrigin
{
    /// <summary>In both: the ordinary case once synced.</summary>
    Both,

    /// <summary>Only in the database (added here, not in <c>garage.json</c>).</summary>
    Database,

    /// <summary>Only in <c>garage.json</c>: nothing indexes it until a sync.</summary>
    Config,
}

/// <summary>A source as the page knows it (the Mac's <c>RegisteredSource</c>).</summary>
public sealed record RegisteredSource(
    string Slug,
    string Kind,
    string Root,
    string CorpusClass,
    string TrustTier = "authored",
    bool Enabled = true,
    SourceOrigin Origin = SourceOrigin.Both,
    long DocumentCount = 0,
    long ExpectedElements = 0)
{
    /// <summary>From a <c>SourceInfo</c>.</summary>
    public static RegisteredSource From(SourceInfo info, SourceOrigin origin = SourceOrigin.Both)
    {
        ArgumentNullException.ThrowIfNull(info);
        return new(info.Slug, info.Kind, info.Root, info.CorpusClass, info.TrustTier, info.Enabled, origin, info.DocumentCount, info.ExpectedElements);
    }
}

/// <summary>Whether this PC can read a source's root: checked locally, as the Mac's access check does.</summary>
public sealed record SourceAccess(bool Exists, bool IsReadable, string Description)
{
    /// <summary>Whether the folder can be walked.</summary>
    public bool IsAccessible => Exists && IsReadable;
}

/// <summary>What the pipeline is doing to one source.</summary>
public enum SourceActivity
{
    /// <summary>Nothing.</summary>
    Idle,

    /// <summary>Waiting in the ingest queue: the run over every source has not reached it yet.</summary>
    Queued,

    /// <summary>A scan is counting its items.</summary>
    Scanning,

    /// <summary>An ingest is reading it; the row shows the run's <see cref="SourceIngestSnapshot"/>.</summary>
    Ingesting,

    /// <summary>It is being removed.</summary>
    Removing,
}

/// <summary>
/// What a running ingest has done to one source so far (the Mac's <c>SourceIngestSnapshot</c>).
/// <c>Fraction</c> is 0…1 when the scan gave a total, and null when it did not: the bar moves without one.
/// </summary>
public sealed record SourceIngestSnapshot(
    string Phase,
    double? Fraction,
    string Percent,
    long Seen,
    long Total,
    long Indexed,
    long Skipped,
    long Failed,
    string ItemType,
    string? CurrentItem,
    string Message,
    bool IsCancelling)
{
    /// <summary>From one progress update of <c>garage_rag.ingest</c>.</summary>
    public static SourceIngestSnapshot From(Garage.Grpc.Services.IngestProgress progress, bool isCancelling = false)
    {
        ArgumentNullException.ThrowIfNull(progress);
        double clamped = Math.Clamp(progress.Progress, 0, 1);
        return new(
            progress.Phase,
            progress.TotalItems > 0 ? clamped : null,
            string.Create(CultureInfo.InvariantCulture, $"{Math.Round(clamped * 100):0}%"),
            progress.Seen,
            progress.TotalItems,
            progress.Indexed,
            progress.Skipped,
            progress.Failed,
            string.IsNullOrEmpty(progress.ItemType) ? "items" : progress.ItemType,
            string.IsNullOrEmpty(progress.CurrentItem) ? null : progress.CurrentItem,
            progress.Message,
            isCancelling);
    }
}

/// <summary>How the last ingest that covered a source ended (the Mac's <c>SourceLastRun</c>).</summary>
public sealed record SourceLastRun(long Indexed, long Skipped, long Failed, string? Error, bool WasCancelled);

/// <summary>A small label after a source's title.</summary>
public sealed record SourceBadge(string Text, SourceTone Tone);

/// <summary>
/// One row on the Sources page: a port of the Mac's <c>SourceRowPresentation</c>. With <c>ShowsCancel</c>,
/// Cancel replaces Scan &amp; Ingest while the source is queued, scanned, read or removed.
/// </summary>
public sealed record SourceRowPresentation(
    SourceSymbol Symbol,
    Tint Tint,
    string Title,
    string Path,
    IReadOnlyList<SourceBadge> Badges,
    string Status,
    SourceTone StatusTone,
    double? Progress,
    bool IsIndeterminate,
    string? Counts,
    string? CurrentItem = null,
    string? Error = null,
    bool ShowsCancel = false,
    string CancelTitle = "Cancel",
    bool CancelDisabled = false)
{
    /// <summary>
    /// The row for <paramref name="source"/>, given its access check, what is running, the running
    /// ingest's snapshot when <paramref name="activity"/> is <see cref="SourceActivity.Ingesting"/>, and
    /// how its last ingest ended.
    /// </summary>
    public static SourceRowPresentation Make(
        RegisteredSource source,
        SourceAccess? access,
        SourceActivity activity,
        long scanFound = 0,
        SourceIngestSnapshot? run = null,
        SourceLastRun? lastRun = null,
        bool isCancellingAll = false)
    {
        ArgumentNullException.ThrowIfNull(source);
        List<SourceBadge> badges = [];
        if (!source.Enabled)
        {
            badges.Add(new("DISABLED", SourceTone.Neutral));
        }
        // Declared in garage.json but not yet in the database: nothing indexes it until a sync.
        if (source.Origin == SourceOrigin.Config)
        {
            badges.Add(new("NOT SYNCED", SourceTone.Warning));
        }
        if (access is { IsAccessible: false })
        {
            badges.Add(new("UNREADABLE", SourceTone.Bad));
        }

        double? indexedFraction = source.ExpectedElements > 0
            ? Math.Min(1, (double)source.DocumentCount / Math.Max(source.DocumentCount, source.ExpectedElements))
            : null;

        string status;
        SourceTone tone;
        double? progress = null;
        bool indeterminate = false;
        string? counts = null;
        string? currentItem = null;
        string? error = null;
        bool showsCancel = false;
        string cancelTitle = "Cancel";
        bool cancelDisabled = false;

        switch (activity)
        {
            case SourceActivity.Removing:
                status = "Removing…";
                tone = SourceTone.Bad;
                indeterminate = true;
                showsCancel = true;
                cancelTitle = "Cancelling…";
                cancelDisabled = true;
                break;
            case SourceActivity.Ingesting when run is not null:
                status = run.IsCancelling ? "Stopping…" : $"Reading {run.Percent}";
                tone = SourceTone.Active;
                progress = run.Fraction;
                indeterminate = run.Fraction is null;
                counts = RunCounts(run.Seen, run.Total, run.Indexed, run.Skipped, run.Failed, run.ItemType);
                currentItem = run.CurrentItem;
                showsCancel = true;
                cancelTitle = run.IsCancelling ? "Cancelling…" : "Cancel";
                cancelDisabled = run.IsCancelling || isCancellingAll;
                break;
            case SourceActivity.Scanning:
            case SourceActivity.Ingesting:
                // An ingest's first update has not arrived yet: it starts by counting, too.
                status = scanFound > 0
                    ? string.Create(CultureInfo.CurrentCulture, $"Counting items… {scanFound:N0} so far")
                    : "Counting items…";
                tone = SourceTone.Active;
                indeterminate = true;
                showsCancel = true;
                cancelDisabled = isCancellingAll;
                break;
            case SourceActivity.Queued:
                status = "Waiting for its turn";
                tone = SourceTone.Neutral;
                progress = indexedFraction;
                counts = IndexedCounts(source);
                showsCancel = true;
                cancelDisabled = isCancellingAll;
                break;
            default:
                if (access is { IsAccessible: false })
                {
                    status = $"Can't be read: {access.Description}";
                    tone = SourceTone.Bad;
                    progress = indexedFraction;
                    counts = IndexedCounts(source);
                }
                else if (lastRun is { Error.Length: > 0 })
                {
                    status = "Last ingest failed";
                    tone = SourceTone.Bad;
                    error = lastRun.Error;
                    progress = indexedFraction;
                    counts = IndexedCounts(source);
                }
                else if (!source.Enabled)
                {
                    status = "Disabled: skipped by every scan and ingest";
                    tone = SourceTone.Neutral;
                    counts = IndexedCounts(source);
                }
                else if (source.DocumentCount == 0)
                {
                    status = source.ExpectedElements > 0
                        ? string.Create(CultureInfo.CurrentCulture, $"{source.ExpectedElements:N0} {Plural("item", source.ExpectedElements)} found, none indexed yet")
                        : "Not indexed yet";
                    tone = SourceTone.Neutral;
                    progress = indexedFraction;
                }
                else if (source.ExpectedElements > source.DocumentCount)
                {
                    long remaining = source.ExpectedElements - source.DocumentCount;
                    status = string.Create(CultureInfo.CurrentCulture, $"{remaining:N0} {Plural("item", remaining)} to go");
                    tone = SourceTone.Active;
                    progress = indexedFraction;
                    counts = IndexedCounts(source);
                }
                else
                {
                    status = "Up to date";
                    tone = SourceTone.Good;
                    counts = IndexedCounts(source);
                    if (lastRun is { WasCancelled: true })
                    {
                        status = "Last ingest was cancelled";
                        tone = SourceTone.Neutral;
                    }
                }
                // A row with nothing to count still draws a bar: full with documents, empty without.
                progress ??= source.DocumentCount > 0 ? 1 : 0;
                break;
        }

        return new(SymbolFor(source), TintFor(source.CorpusClass), source.Slug, source.Root, badges, status, tone, progress, indeterminate, counts,
            currentItem, error, showsCancel, cancelTitle, cancelDisabled);
    }

    /// <summary>"1,204 of 2,860 documents · 1,180 indexed · 24 skipped": a running ingest's counts.</summary>
    public static string RunCounts(long seen, long total, long indexed, long skipped, long failed, string itemType)
    {
        List<string> parts =
        [
            total > 0
                ? string.Create(CultureInfo.CurrentCulture, $"{seen:N0} of {total:N0} {itemType}")
                : string.Create(CultureInfo.CurrentCulture, $"{seen:N0} {itemType}"),
            string.Create(CultureInfo.CurrentCulture, $"{indexed:N0} indexed"),
        ];
        if (skipped > 0)
        {
            parts.Add(string.Create(CultureInfo.CurrentCulture, $"{skipped:N0} skipped"));
        }
        if (failed > 0)
        {
            parts.Add(string.Create(CultureInfo.CurrentCulture, $"{failed:N0} failed"));
        }
        return string.Join(" · ", parts);
    }

    /// <summary>"1,180 of 1,204 documents" when a scan counted the folder, "1,204 documents" otherwise.</summary>
    public static string IndexedCounts(RegisteredSource source)
    {
        ArgumentNullException.ThrowIfNull(source);
        return source.ExpectedElements > 0
            ? string.Create(CultureInfo.CurrentCulture, $"{source.DocumentCount:N0} of {source.ExpectedElements:N0} documents")
            : string.Create(CultureInfo.CurrentCulture, $"{source.DocumentCount:N0} {Plural("document", source.DocumentCount)}");
    }

    /// <summary>"item" or "items".</summary>
    public static string Plural(string noun, long count) => count == 1 ? noun : noun + "s";

    /// <summary>What the source is, from its kind and, for a folder, where it points (Windows folders included).</summary>
    public static SourceSymbol SymbolFor(RegisteredSource source)
    {
        ArgumentNullException.ThrowIfNull(source);
        string root = source.Root.ToLowerInvariant().Replace('\\', '/').TrimEnd('/');
        string slug = source.Slug.ToLowerInvariant();
        switch (source.Kind.ToLowerInvariant())
        {
            case "sqlite":
                return slug.Contains("sms", StringComparison.Ordinal) || root.Contains("/messages", StringComparison.Ordinal) ? SourceSymbol.Message : SourceSymbol.Database;
            case "maildir":
                return SourceSymbol.Mail;
            case "git":
                return SourceSymbol.Code;
            case "feed":
                return SourceSymbol.Feed;
        }
        string last = root[(root.LastIndexOf('/') + 1)..];
        switch (last)
        {
            case "documents": return SourceSymbol.Documents;
            case "desktop": return SourceSymbol.Desktop;
            case "downloads": return SourceSymbol.Downloads;
            case "developer" or "source" or "repos" or "src": return SourceSymbol.Code;
        }
        if (last.StartsWith("onedrive", StringComparison.Ordinal) || last is "dropbox" or "my drive" or "google drive" or "icloud drive"
            || root.Contains("mobile documents", StringComparison.Ordinal) || root.Contains("icloud", StringComparison.Ordinal))
        {
            return SourceSymbol.Cloud;
        }
        return source.CorpusClass == "code" ? SourceSymbol.Code : SourceSymbol.Folder;
    }

    /// <summary>The circle's colour follows the corpus class.</summary>
    public static Tint TintFor(string corpusClass) => corpusClass.ToLowerInvariant() switch
    {
        "code" => Tint.Purple,
        "communication" => Tint.Green,
        _ => Tint.Blue,
    };
}

/// <summary>The one-line summary at the top of the list (the Mac's <c>SourcesSummary</c>).</summary>
public static class SourcesSummary
{
    /// <summary>"1,234 documents in 3 sources", or "No sources yet".</summary>
    public static string Line(long sources, long documents) => sources == 0
        ? "No sources yet"
        : string.Create(CultureInfo.CurrentCulture,
            $"{documents:N0} {SourceRowPresentation.Plural("document", documents)} in {sources:N0} {SourceRowPresentation.Plural("source", sources)}");
}

/// <summary>
/// The name the Add Source form suggests (the Mac's <c>SourceSlugSuggestion</c>): the folder's name
/// (a database file's name without its extension; a feed's host) folded to <c>[a-z0-9-]</c>, made
/// unique with "-2", "-3", … Windows paths and drive roots are understood.
/// </summary>
public static class SourceSlugSuggestion
{
    /// <summary>The suggested slug; empty for a blank root.</summary>
    public static string Suggest(string root, string kind, IReadOnlySet<string> taken)
    {
        ArgumentNullException.ThrowIfNull(root);
        ArgumentNullException.ThrowIfNull(taken);
        string trimmed = root.Trim();
        if (trimmed.Length == 0)
        {
            return "";
        }
        string name;
        switch (kind.ToLowerInvariant())
        {
            case "feed":
                name = Uri.TryCreate(trimmed, UriKind.Absolute, out Uri? uri) ? uri.Host : trimmed;
                break;
            case "sqlite":
                string file = LastComponent(trimmed);
                string stem = System.IO.Path.GetFileNameWithoutExtension(file);
                name = stem.Length > 0 ? stem : file;
                break;
            default:
                name = LastComponent(trimmed);
                if (name is "~" or "" or "/")
                {
                    name = "home";
                }
                else if (name == "com~apple~CloudDocs")
                {
                    name = "icloud-drive";
                }
                else if (name.Length == 2 && name[1] == ':')
                {
                    name = $"drive-{char.ToLowerInvariant(name[0])}";  // "D:\" → drive-d
                }
                break;
        }
        return UniqueSlug(SlugForFolderNamed(name), taken);
    }

    /// <summary>A name folded to lowercase ASCII letters and digits joined by single dashes; "folder" when nothing is left.</summary>
    public static string SlugForFolderNamed(string name)
    {
        ArgumentNullException.ThrowIfNull(name);
        string folded = RemoveDiacritics(name).ToLowerInvariant();
        var output = new StringBuilder();
        bool pendingDash = false;
        foreach (char c in folded)
        {
            if (char.IsAsciiLetterOrDigit(c))
            {
                if (pendingDash && output.Length > 0)
                {
                    output.Append('-');
                }
                pendingDash = false;
                output.Append(c);
            }
            else
            {
                pendingDash = true;
            }
        }
        return output.Length == 0 ? "folder" : output.ToString();
    }

    /// <summary><paramref name="baseSlug"/>, or it with the first free "-N" (N from 2).</summary>
    public static string UniqueSlug(string baseSlug, IReadOnlySet<string> taken)
    {
        ArgumentNullException.ThrowIfNull(taken);
        if (!taken.Contains(baseSlug))
        {
            return baseSlug;
        }
        int counter = 2;
        while (taken.Contains(string.Create(CultureInfo.InvariantCulture, $"{baseSlug}-{counter}")))
        {
            counter++;
        }
        return string.Create(CultureInfo.InvariantCulture, $"{baseSlug}-{counter}");
    }

    private static string LastComponent(string path)
    {
        string trimmed = path.Length > 1 ? path.TrimEnd('/', '\\') : path;
        if (trimmed.Length == 2 && trimmed[1] == ':')
        {
            return trimmed;  // a drive root
        }
        int slash = trimmed.LastIndexOfAny(['/', '\\']);
        return slash >= 0 && trimmed.Length > 1 ? trimmed[(slash + 1)..] : trimmed;
    }

    private static string RemoveDiacritics(string text)
    {
        string decomposed = text.Normalize(NormalizationForm.FormD);
        var builder = new StringBuilder(decomposed.Length);
        foreach (char c in decomposed)
        {
            if (CharUnicodeInfo.GetUnicodeCategory(c) != UnicodeCategory.NonSpacingMark)
            {
                builder.Append(c);
            }
        }
        return builder.ToString().Normalize(NormalizationForm.FormC);
    }
}
